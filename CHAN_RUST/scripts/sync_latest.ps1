# sync_latest.ps1 —— 双向「以最新一方为准」同步（PCA ↔ PCB 对等）
#
# 与 sync_to_remote.ps1 的区别：
#   sync_to_remote：固定「本机 -> 对端」，只看一层的差异。
#   本脚本：先把两边的文件清单摆在一起比，判断哪一边更新，然后把旧的一边对齐到新的一边。
#           方向是自动判的，不需要人工选「推」还是「拉」。
#
# 判「最新」的口径（逐文件投票，不看整体时间戳）：
#   1. 两边都有、内容不同 -> 谁的 LastWriteTime 更晚，票投给谁；
#   2. 只有一边有        -> 票投给有它的那一边（按「新增」处理）；
#   3. 票数相等          -> 比两侧清单里的最大修改时间，晚的一侧为准；
#   4. 仍相等            -> 比两侧 git 最近提交的时间，晚的一侧为准；
#   5. 还相等            -> 放弃自动判定，要求显式给 -Direction。
#
# 旧的一侧里「对方没有」的文件不直接删：移动到该侧的
#   a_Data\remote_ctl\sync_backup\latest_<时间戳>\
# 备份目录（该目录本身在排除表里，不会被下次比对算进差异）。
#
# 用法：
#   # 只判方向、列清单，不动任何文件
#   powershell -NoProfile -File CHAN_RUST\scripts\sync_latest.ps1 -Json
#   # 真同步（方向自动判）
#   ... -Apply -Json
#   # 顶层明确方向（auto 判不出来时用）
#   ... -Apply -Direction toLocal -Json
#   # 同步完顺手把「被更新的那一台」重编并重启 App（cargo 编 chan_ffi.dll + flutter build --debug）
#   ... -Apply -Build -Json
#
# 退出码：0 成功（含「已一致」）；2 对端不可达；4 复制/移出失败；5 同步后复核仍有差异；6 方向判不出来；
#         7 同步成功但编译没出成品（看 buildLog）

param(
    [string]$PeerPath = '\\192.168.1.6\D$\2\chan_month5',
    [string]$LocalRoot = '',
    [ValidateSet('auto', 'toPeer', 'toLocal')][string]$Direction = 'auto',
    [switch]$Apply,
    [switch]$Build,
    [int]$BuildTimeoutSec = 900,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

if ($Json) {
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $OutputEncoding = [Console]::OutputEncoding
    } catch { }
}

if ($LocalRoot -eq '') {
    $LocalRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

# 与 sync_to_remote.ps1 保持同一份排除口径：.git、各家工具的缓存、构建产物、本机运行现场
$RelExcludeDirs = @(
    '.git', '.kilo', '.kilocode', '.workbuddy', '.codebuddy', '.wt', 'exports', 'dist',
    'CHAN_RUST\rust\target', 'CHAN_RUST\rust\target_alt',
    'CHAN_RUST\flutter\chan_kline\build',
    'CHAN_RUST\flutter\chan_kline\.dart_tool',
    'CHAN_RUST\flutter\chan_kline\windows\flutter\ephemeral',
    'CHAN_RUST\flutter\chan_kline\linux\flutter\ephemeral',
    'CHAN_RUST\flutter\chan_kline\macos\flutter\ephemeral',
    'CHAN_RUST\flutter\chan_kline\android\.gradle',
    'a_Data\.tdx_protocol_cache', 'a_Data\.telegram_cache', 'a_Data\agent_live',
    'a_Data\ml_exports', 'a_Data\remote_ctl', 'a_Data\robot_verify', 'a_Data\robot_verify_inbox'
)
$ExcludeFiles = @(
    '*.log', '*.log.err', 'build_launch_user.*', 'tmp_build_launch_*',
    '.chan_telegram_settings.json', '.chan_chip_config.json', '.chan_trend_model_config.json',
    '.chan_sync_settings.json',
    '*.locked*', '*.bak*',
    '*.pyc', '*.pyo', '*.tmp', '*.orig', '*.rej', 'Thumbs.db', '.DS_Store',
    # 编译产物：chan_ffi.dll 是 cargo 现编出来的，没入库（git ls-files 查不到），
    # 哪一侧刚编过就更"新"，会把方向判反、把对端的 DLL 拷回来。编译由 -Build 各自负责。
    '*.dll', '*.pdb', '*.ilk'
)

# 按「目录名」排除的运行时/工具缓存：出现在任意层级都排（__pycache__ 常嵌在 scripts 下面）。
# 这些目录里的一侧独有文件曾经把方向判错（2026-11-09 试跑：对端 73 个 .remember\tmp +
# __pycache__ 被算成「对端更新」，方向判反），所以必须在投票前排掉。
$ExcludeDirNames = @(
    '__pycache__', '.remember', '.pytest_cache', '.mypy_cache', '.ruff_cache',
    '.idea', '.vscode', 'node_modules', '.git'
)

function Write-Say([string]$m) { Write-Host ">> $m" }

$script:Result = [ordered]@{
    ok          = $false
    peer        = $PeerPath
    local       = $LocalRoot
    applied     = [bool]$Apply
    direction   = ''          # local-to-peer / peer-to-local / same
    source      = ''
    target      = ''
    newerSide   = ''
    votesLocal  = 0
    votesPeer   = 0
    diffFiles   = 0
    onlyLocal   = 0
    onlyPeer    = 0
    bothDiff    = 0
    copied      = 0
    movedAside  = 0
    backupDir   = ''
    verifyLeft  = 0
    samples     = @()
    buildSide   = ''
    buildOk     = $null
    buildNote   = ''
    buildLog    = ''
    buildSec    = 0
    error       = ''
}

function Finish([int]$code, [string]$err) {
    $script:Result.ok = (($code -eq 0) -or ($code -eq 7))
    if ($err -ne '') { $script:Result.error = $err }
    if ($Json) {
        Write-Host '===JSON==='
        Write-Host ($script:Result | ConvertTo-Json -Depth 6)
        Write-Host '===END==='
    }
    exit $code
}

if (-not (Test-Path -LiteralPath $PeerPath)) {
    Write-Host "!! 对端不可达：$PeerPath"
    Finish 2 "对端不可达：$PeerPath"
}

Write-Say "本机根：$LocalRoot"
Write-Say "对端根：$PeerPath"
Write-Say $(if ($Apply) { '模式：真写' } else { '模式：只看不写（判方向 + 列清单）' })

# ---------------- 清单 ----------------
function Test-ExcludedDir([string]$rel) {
    foreach ($p in $RelExcludeDirs) {
        if ($rel -eq $p) { return $true }
        if ($rel.StartsWith($p + '\')) { return $true }
    }
    return $false
}

function Test-ExcludedFile([string]$name) {
    foreach ($p in $ExcludeFiles) {
        if ($name -like $p) { return $true }
    }
    return $false
}

function Get-Sha256([string]$path) {
    $fs = [IO.File]::OpenRead($path)
    try {
        $algo = [Security.Cryptography.SHA256]::Create()
        $bytes = $algo.ComputeHash($fs)
        return ([BitConverter]::ToString($bytes) -replace '-', '')
    } finally { $fs.Dispose() }
}

function Get-Manifest([string]$root, [string]$rel = '') {
    $map = @{}
    if (-not (Test-Path -LiteralPath $root)) { return $map }
    $dirs = @()
    try { $dirs = @([IO.Directory]::EnumerateDirectories($root)) } catch { $dirs = @() }
    foreach ($d in $dirs) {
        $dn = [IO.Path]::GetFileName($d)
        if ($ExcludeDirNames -contains $dn) { continue }
        $dr = $dn
        if ($rel -ne '') { $dr = "$rel\$dn" }
        if (Test-ExcludedDir $dr) { continue }
        $sub = Get-Manifest $d $dr
        foreach ($k in $sub.Keys) { $map[$k] = $sub[$k] }
    }
    $files = @()
    try { $files = @([IO.Directory]::EnumerateFiles($root)) } catch { $files = @() }
    foreach ($f in $files) {
        $fi = New-Object IO.FileInfo($f)
        if (Test-ExcludedFile $fi.Name) { continue }
        $fr = $fi.Name
        if ($rel -ne '') { $fr = "$rel\$($fi.Name)" }
        $map[$fr] = [pscustomobject]@{
            size = $fi.Length
            time = $fi.LastWriteTimeUtc
            full = $f
        }
    }
    return $map
}

Write-Say '递归列本机清单……'
$localMap = Get-Manifest $LocalRoot
Write-Say ('本机文件 ' + $localMap.Count + ' 个')
Write-Say '递归列对端清单……'
$peerMap = Get-Manifest $PeerPath
Write-Say ('对端文件 ' + $peerMap.Count + ' 个')

# ---------------- 差异 + 投票 ----------------
$onlyLocal = New-Object System.Collections.Generic.List[string]
$onlyPeer = New-Object System.Collections.Generic.List[string]
$bothDiff = New-Object System.Collections.Generic.List[string]
$voteLocal = 0
$votePeer = 0
$maxTimeLocal = [DateTime]::MinValue
$maxTimePeer = [DateTime]::MinValue

foreach ($rel in $localMap.Keys) {
    if ($localMap[$rel].time -gt $maxTimeLocal) { $maxTimeLocal = $localMap[$rel].time }
}
foreach ($rel in $peerMap.Keys) {
    if ($peerMap[$rel].time -gt $maxTimePeer) { $maxTimePeer = $peerMap[$rel].time }
}

foreach ($rel in $localMap.Keys) {
    if (-not $peerMap.ContainsKey($rel)) {
        $onlyLocal.Add($rel)
        $voteLocal += 1
        continue
    }
    $a = $localMap[$rel]
    $b = $peerMap[$rel]
    $dt = [Math]::Abs(($a.time - $b.time).TotalSeconds)
    if ($a.size -ne $b.size) {
        $bothDiff.Add($rel)
        if ($a.time -gt $b.time) { $voteLocal += 2 } else { $votePeer += 2 }
        continue
    }
    if ($dt -le 2) { continue }   # 大小同、时间差 ≤2 秒：视为同一份
    # 大小相同但时间差大于 2 秒：再看内容，内容一样就不算差异（同步脚本会修正时间戳）
    if ((Get-Sha256 $a.full) -eq (Get-Sha256 $b.full)) { continue }
    $bothDiff.Add($rel)
    if ($a.time -gt $b.time) { $voteLocal += 2 } else { $votePeer += 2 }
}

foreach ($rel in $peerMap.Keys) {
    if (-not $localMap.ContainsKey($rel)) {
        $onlyPeer.Add($rel)
        $votePeer += 1
    }
}

$diffCount = $onlyLocal.Count + $onlyPeer.Count + $bothDiff.Count
$script:Result.onlyLocal = $onlyLocal.Count
$script:Result.onlyPeer = $onlyPeer.Count
$script:Result.bothDiff = $bothDiff.Count
$script:Result.diffFiles = $diffCount
$script:Result.votesLocal = $voteLocal
$script:Result.votesPeer = $votePeer

# 差异项的「最后改动时间」：哪边最近改过，哪边就是最新的（这是主判据）
$diffTimeLocal = [DateTime]::MinValue
$diffTimePeer = [DateTime]::MinValue
foreach ($rel in $onlyLocal) { if ($localMap[$rel].time -gt $diffTimeLocal) { $diffTimeLocal = $localMap[$rel].time } }
foreach ($rel in $bothDiff) {
    if ($localMap[$rel].time -gt $diffTimeLocal) { $diffTimeLocal = $localMap[$rel].time }
    if ($peerMap[$rel].time -gt $diffTimePeer) { $diffTimePeer = $peerMap[$rel].time }
}
foreach ($rel in $onlyPeer) { if ($peerMap[$rel].time -gt $diffTimePeer) { $diffTimePeer = $peerMap[$rel].time } }

Write-Say ("差异：仅本机 " + $onlyLocal.Count + "，仅对端 " + $onlyPeer.Count + "，双方内容不同 " + $bothDiff.Count)
Write-Say ("最后改动时间：本机 " + $(if ($diffTimeLocal -eq [DateTime]::MinValue) { '无' } else { $diffTimeLocal.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') }) +
    "，对端 " + $(if ($diffTimePeer -eq [DateTime]::MinValue) { '无' } else { $diffTimePeer.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') }))
Write-Say ("辅助计数：本机更新 $voteLocal 项，对端更新 $votePeer 项")

if ($diffCount -eq 0) {
    $script:Result.direction = 'same'
    $script:Result.newerSide = '两边一致'
    Write-Say '两边文件已经一致，不需要同步。'
    Finish 0 ''
}

# ---------------- 判方向 ----------------
$decided = ''
if ($Direction -eq 'toPeer') { $decided = 'local-to-peer' }
elseif ($Direction -eq 'toLocal') { $decided = 'peer-to-local' }
else {
    # 第一层：差异项的最后改动时间，差 60 秒以上才有意义（同步本身会带时间戳，误差就在秒级）
    $gapSec = 0
    $lt = [DateTime]::MinValue; $rt = [DateTime]::MinValue
    if ($diffTimeLocal -ne [DateTime]::MinValue) { $lt = $diffTimeLocal }
    if ($diffTimePeer -ne [DateTime]::MinValue) { $rt = $diffTimePeer }
    if ($lt -ne [DateTime]::MinValue -and $rt -eq [DateTime]::MinValue) { $decided = 'local-to-peer' }
    elseif ($rt -ne [DateTime]::MinValue -and $lt -eq [DateTime]::MinValue) { $decided = 'peer-to-local' }
    elseif ($lt -ne [DateTime]::MinValue -and $rt -ne [DateTime]::MinValue) {
        $gapSec = ($lt - $rt).TotalSeconds
        if ($gapSec -gt 60) { $decided = 'local-to-peer' }
        elseif ($gapSec -lt -60) { $decided = 'peer-to-local' }
    }
    # 第二层：时间打平看计数
    if ($decided -eq '' -and $voteLocal -ne $votePeer) {
        if ($voteLocal -gt $votePeer) { $decided = 'local-to-peer' } else { $decided = 'peer-to-local' }
    }
    # 第三层：整体最大时间
    if ($decided -eq '' -and $maxTimeLocal -ne $maxTimePeer) {
        if ($maxTimeLocal -gt $maxTimePeer) { $decided = 'local-to-peer' } else { $decided = 'peer-to-local' }
    }
    # 第四层：git 最近提交时间
    if ($decided -eq '') {
        $gtLocal = ''
        $gtPeer = ''
        try {
            $g = Join-Path $LocalRoot '.git'
            if (Test-Path -LiteralPath $g) {
                $gtLocal = (& git --git-dir=$g log -1 --format=%ci 2>$null | Out-String).Trim()
            }
        } catch { }
        try {
            $g2 = Join-Path $PeerPath '.git'
            if (Test-Path -LiteralPath $g2) {
                $gtPeer = (& git --git-dir=$g2 log -1 --format=%ci 2>$null | Out-String).Trim()
            }
        } catch { }
        if ($gtLocal -ne '' -and $gtPeer -ne '' -and $gtLocal -ne $gtPeer) {
            if ([string]::CompareOrdinal($gtLocal, $gtPeer) -gt 0) { $decided = 'local-to-peer' }
            else { $decided = 'peer-to-local' }
        }
    }
}

if ($decided -eq '') {
    Write-Host '!! 判不出哪边更新（票数与时间都打平）：请显式给 -Direction toPeer / toLocal'
    Finish 6 '判不出哪边更新，请显式指定方向'
}

$script:Result.direction = $decided
if ($decided -eq 'local-to-peer') {
    $script:Result.newerSide = '本机'
    $script:Result.source = $LocalRoot
    $script:Result.target = $PeerPath
} else {
    $script:Result.newerSide = '对端'
    $script:Result.source = $PeerPath
    $script:Result.target = $LocalRoot
}

$sample = @()
$sample += @($onlyLocal | Select-Object -First 3 | ForEach-Object { "仅本机  $_" })
$sample += @($onlyPeer | Select-Object -First 3 | ForEach-Object { "仅对端  $_" })
$sample += @($bothDiff | Select-Object -First 3 | ForEach-Object { "内容不同 $_" })
$script:Result.samples = $sample
foreach ($s in $sample) { Write-Host "   $s" }

Write-Say ("判定：以" + $script:Result.newerSide + "为准，同步到另一侧")

if (-not $Apply) {
    Write-Say '只看不写结束：加 -Apply 才真正对齐。'
    Finish 0 ''
}

# ---------------- 执行 ----------------
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupDir = Join-Path (Join-Path (Join-Path $script:Result.target 'a_Data') 'remote_ctl') ("sync_backup\latest_" + $stamp)
$script:Result.backupDir = $backupDir

$copied = 0
$moved = 0
$failures = New-Object System.Collections.Generic.List[string]

$toCopy = @()
if ($decided -eq 'local-to-peer') {
    $toCopy += $onlyLocal
    $toCopy += $bothDiff
    $onlyTargetSide = $onlyPeer   # 对端独有 -> 移入对端备份
} else {
    $toCopy += $onlyPeer
    $toCopy += $bothDiff
    $onlyTargetSide = $onlyLocal
}

foreach ($rel in $toCopy) {
    $src = Join-Path $script:Result.source $rel
    $dst = Join-Path $script:Result.target $rel
    $dir = Split-Path -Parent $dst
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $copied++
    } catch {
        $failures.Add("$rel -> $($_.Exception.Message)")
    }
}
Write-Say ("复制完成：$copied 个文件")

foreach ($rel in $onlyTargetSide) {
    $src = Join-Path $script:Result.target $rel
    if (-not (Test-Path -LiteralPath $src)) { continue }
    $dst = Join-Path $backupDir $rel
    $dir = Split-Path -Parent $dst
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Move-Item -LiteralPath $src -Destination $dst -Force
        $moved++
    } catch {
        $failures.Add("移出 $rel -> $($_.Exception.Message)")
    }
}
Write-Say ("移出旧侧独有文件：$moved 个 → $backupDir")
$script:Result.copied = $copied
$script:Result.movedAside = $moved

# 推到对端时，对端的远端代理脚本必须补 UTF-8 BOM，否则那台的 5.1 会读坏中文
if ($decided -eq 'local-to-peer') {
    $rp = Join-Path $PeerPath 'CHAN_RUST\scripts\remote_app_agent.ps1'
    if (Test-Path -LiteralPath $rp) {
        try {
            $t = [IO.File]::ReadAllText($rp, (New-Object Text.UTF8Encoding($false, $true)))
            [IO.File]::WriteAllText($rp, $t, (New-Object Text.UTF8Encoding($true)))
            Write-Say '对端 remote_app_agent.ps1 已重编码为 UTF-8 BOM'
        } catch { }
    }
}

if ($failures.Count -gt 0) {
    foreach ($f in ($failures | Select-Object -First 10)) { Write-Host "!! $f" }
    Finish 4 ("有 " + $failures.Count + " 个文件处理失败")
}

# ---------------- 复核 ----------------
Write-Say '复核：重新列两侧清单……'
$local2 = Get-Manifest $LocalRoot
$peer2 = Get-Manifest $PeerPath
$left = 0
$leftFiles = New-Object System.Collections.Generic.List[string]
foreach ($rel in $local2.Keys) {
    if (-not $peer2.ContainsKey($rel)) { $left++; if ($leftFiles.Count -lt 10) { $leftFiles.Add($rel) }; continue }
    $a = $local2[$rel]; $b = $peer2[$rel]
    if ($a.size -ne $b.size) { $left++; if ($leftFiles.Count -lt 10) { $leftFiles.Add($rel) }; continue }
    if ([Math]::Abs(($a.time - $b.time).TotalSeconds) -gt 2) {
        if ((Get-Sha256 $a.full) -ne (Get-Sha256 $b.full)) { $left++; if ($leftFiles.Count -lt 10) { $leftFiles.Add($rel) } }
    }
}
foreach ($rel in $peer2.Keys) {
    if (-not $local2.ContainsKey($rel)) { $left++; if ($leftFiles.Count -lt 10) { $leftFiles.Add($rel) } }
}
$script:Result.verifyLeft = $left

if ($left -gt 0) {
    foreach ($f in $leftFiles) { Write-Host "!! 仍有差异：$f" }
    Finish 5 ("同步后仍有 $left 处差异（多为对端被占用或写入失败）")
}

Write-Say '同步完成：两边文件已一致。'

# ---------------- 编译（-Build） ----------------
# 只编「刚被更新的那一侧」：最新方本来就是刚编过的，被对齐的那台才需要重编才生效。
# 编译用的是仓库里固定的 build_rust.ps1（cargo 编 chan_ffi.dll → 拷 DLL → flutter build --debug → 拉起 App）。
if ($Build) {
    if (($decided -eq 'same') -or (($copied + $moved) -le 0)) {
        $script:Result.buildNote = '没有文件变化，跳过编译'
        $script:Result.buildOk = $true
        Write-Say '没有文件变化，跳过编译'
    } else {
        $side = $(if ($decided -eq 'local-to-peer') { 'peer' } else { 'local' })
        $root = $(if ($side -eq 'local') { $LocalRoot } else { $PeerPath })
        $script:Result.buildSide = $side
        $who = $(if ($side -eq 'local') { '本机' } else { '对端' })
        Write-Say "开始编译被更新的那一侧（$who）：编 chan_ffi.dll + flutter build + 重启 App"

        $kernel = Join-Path $root 'CHAN_RUST\flutter\chan_kline\build\windows\x64\runner\Debug\data\flutter_assets\kernel_blob.bin'
        $dllPath = Join-Path $root 'CHAN_RUST\flutter\chan_kline\windows\native\chan_ffi.dll'
        $t0 = Get-Date
        $started = $false

        if ($side -eq 'local') {
            $bs = Join-Path $LocalRoot 'CHAN_RUST\scripts\build_rust.ps1'
            if (-not (Test-Path -LiteralPath $bs)) {
                $script:Result.buildOk = $false
                $script:Result.buildNote = "找不到 build_rust.ps1：$bs"
            } else {
                $bdir = Join-Path $LocalRoot 'a_Data\remote_ctl\build'
                if (-not (Test-Path -LiteralPath $bdir)) { New-Item -ItemType Directory -Path $bdir -Force | Out-Null }
                $blog = Join-Path $bdir ((Get-Date -Format 'yyyyMMdd_HHmmss') + '_local.log')
                $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                if (-not (Test-Path -LiteralPath $ps51)) { $ps51 = 'powershell.exe' }
                $p = Start-Process -FilePath $ps51 -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bs) `
                    -WorkingDirectory $LocalRoot -WindowStyle Hidden -PassThru `
                    -RedirectStandardOutput $blog -RedirectStandardError ($blog + '.err')
                $script:Result.buildLog = $blog
                Write-Say ("本机编译已启动 pid=" + $p.Id + "，日志 " + $blog)
                $started = $true
            }
        } else {
            # 让对端代理跑同一套固定脚本（代理只认 build 这个白名单动作）
            $ctl = Join-Path $PeerPath 'a_Data\remote_ctl'
            $reqDir = Join-Path $ctl 'requests'
            $resDir = Join-Path $ctl 'results'
            $tokFile = Join-Path $ctl 'token.txt'
            if ((-not (Test-Path -LiteralPath $reqDir)) -or (-not (Test-Path -LiteralPath $tokFile))) {
                $script:Result.buildOk = $false
                $script:Result.buildNote = '对端代理没在跑（缺 requests 目录或 token.txt），没触发编译'
            } else {
                $tok = ([IO.File]::ReadAllText($tokFile)).Trim()
                $rid = (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + (Get-Random -Minimum 1000 -Maximum 9999)
                $req = [pscustomobject]@{ id = $rid; action = 'build'; token = $tok; args = @{}; createdAt = (Get-Date).ToString('s') }
                $enc = New-Object Text.UTF8Encoding($false)
                [IO.File]::WriteAllText((Join-Path $reqDir ($rid + '.json')), ($req | ConvertTo-Json -Depth 6), $enc)
                $resPath = Join-Path $resDir ($rid + '.json')
                $dl = (Get-Date).AddSeconds(40)
                $got = $null
                while ((Get-Date) -lt $dl) {
                    Start-Sleep -Milliseconds 500
                    if (Test-Path -LiteralPath $resPath) {
                        try { $got = ([IO.File]::ReadAllText($resPath) | ConvertFrom-Json) } catch { $got = $null }
                        if ($null -ne $got) { break }
                    }
                }
                if ($null -eq $got -or -not $got.ok) {
                    $why = $(if ($null -eq $got) { '对端代理 40 秒没响应（可能没启动）' } else { "对端代理拒绝：$($got.error)" })
                    $script:Result.buildOk = $false
                    $script:Result.buildNote = $why
                } else {
                    # 代理回的是对端本机路径（D:\...），本机读不到，换成共享路径再盯着看
                    $leaf = Split-Path -Leaf ([string]$got.data.log)
                    $script:Result.buildLog = Join-Path (Join-Path $PeerPath 'a_Data\remote_ctl\build') $leaf
                    Write-Say ("对端编译已启动 pid=" + $got.data.pid + "，日志 " + $script:Result.buildLog)
                    $started = $true
                }
            }
        }

        if ($started) {
            $dl = (Get-Date).AddSeconds($BuildTimeoutSec)
            $lastSay = Get-Date
            $okBuild = $false
            # 完成判据三条任一命中：
            #   1) 构建日志出现 "Launch (no flutter run)"（build_rust.ps1 打完 App 必打这行）；
            #   2) kernel_blob.bin 比开始时间新（Dart 有改动时才会刷新）；
            #   3) chan_ffi.dll 比开始时间新（Rust 有改动时才会刷新）。
            # 只改了非 Dart 文件（比如 task-log）时 flutter 复用缓存、kernel 不刷新，单看 2) 会一直等到超时。
            while ((Get-Date) -lt $dl) {
                Start-Sleep -Seconds 5
                $logDone = $false
                $logPath = $script:Result.buildLog
                if ($logPath -ne '' -and (Test-Path -LiteralPath $logPath)) {
                    try {
                        $logDone = Select-String -LiteralPath $logPath -Pattern 'Launch \(no flutter run\)' -SimpleMatch:$false -Quiet -ErrorAction Stop
                    } catch { $logDone = $false }
                }
                $kbOk = (Test-Path -LiteralPath $kernel) -and ((Get-Item -LiteralPath $kernel).LastWriteTime -gt $t0)
                $dllOk = (Test-Path -LiteralPath $dllPath) -and ((Get-Item -LiteralPath $dllPath).LastWriteTime -gt $t0)
                if ($logDone -or $kbOk -or $dllOk) { $okBuild = $true; break }
                if (((Get-Date) - $lastSay).TotalSeconds -ge 25) {
                    Write-Say ("编译中（" + [int]((Get-Date) - $t0).TotalSeconds + " 秒）：正在编…")
                    $lastSay = Get-Date
                }
            }
            $script:Result.buildSec = [int]((Get-Date) - $t0).TotalSeconds
            $script:Result.buildOk = $okBuild
            if ($okBuild) {
                $script:Result.buildNote = "编译完成并已重启 App（用时 $($script:Result.buildSec) 秒）"
                Write-Say $script:Result.buildNote
            } else {
                $script:Result.buildNote = "编译超时或没出成品（>$BuildTimeoutSec 秒），看日志：$($script:Result.buildLog)"
                Write-Host "!! $($script:Result.buildNote)"
                Finish 7 $script:Result.buildNote
            }
        }
    }
}

Finish 0 ''
