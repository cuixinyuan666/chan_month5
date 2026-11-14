# sync_to_remote.ps1 —— 本机 -> 局域网另一台（白名单镜像，只覆盖不删除）
#
# 设计要点（踩过的坑都写在这里）：
#   1. 不用 /MIR：远端有它自己的报告、调试产物、数据，全盘镜像会把它们删掉。
#   2. 必须 /XJ：flutter 的 <platform>\flutter\ephemeral\.plugin_symlinks 是符号链接，
#      SMB 上建不了链接，robocopy 会重试到上限并以退出码 11 失败（2026-11-09 实测）。
#   3. a_Data\robot_verify 必须排除：那是「本机跑验证的现场」，推过去会把远端
#      session.json / status.json / last_report.* 覆盖掉（2026-11-09 已发生一次）。
#   4. 推产物前先探 exe/dll 占用：远端 App 在跑就不推，不静默跳过。
#
# 用法：
#   # 只看清单（默认）：默认远端是 192.168.1.6 的 D:\2\chan_month5 共享
#   powershell -NoProfile -File CHAN_RUST\scripts\sync_to_remote.ps1 -DryRun
#   # 只算差异（不写任何文件，给 App 弹确认用）
#   ... -DiffOnly -Json
#   # 真同步（覆盖前把被覆盖的文件存一份快照到对端）
#   ... -Apply -Backup
#   # 只推源码 / 只推产物
#   ... -Apply -Include code
#   ... -Apply -Include build
#   # 给 App 解析用：结尾输出 ===JSON=== {...} ===END===
#   ... -Apply -Backup -RestartRemoteApp -Json
#
# 退出码：0 成功；2 共享不可达；3 远端 exe/dll 被占用；4 robocopy 失败；5 指纹不一致；6 备份/差异失败
param(
    [string]$SharePath = '\\192.168.1.6\D$\2\chan_month5',
    [string]$LocalRoot = '',
    [ValidateSet('all', 'code', 'build')][string]$Include = 'all',
    [switch]$DryRun,
    [switch]$Apply,
    [switch]$DiffOnly,
    [switch]$Backup,
    [switch]$Json,
    [bool]$AutoCloseRemoteApp = $true,
    [switch]$RestartRemoteApp,
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'

# App 通过管道读输出：5.1 默认按控制台代码页写，中文会成乱码。给 -Json 时强制 UTF-8。
if ($Json) {
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $OutputEncoding = [Console]::OutputEncoding
    } catch { }
}

if ($LocalRoot -eq '') {
    # PSScriptRoot = <repo>\CHAN_RUST\scripts -> 两级向上 = 仓库根
    $LocalRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

# 默认只看不动：既没给 -Apply 也没给 -DryRun 时，按 DryRun 处理（防手滑）
if (-not $Apply) { $DryRun = $true }
if ($DiffOnly) { $DryRun = $true }

$FlutterDir = Join-Path $LocalRoot 'CHAN_RUST\flutter\chan_kline'
$LocalArtifact = Join-Path $FlutterDir 'build\windows\x64\runner\Debug'
$RemoteArtifact = Join-Path $SharePath 'CHAN_RUST\flutter\chan_kline\build\windows\x64\runner\Debug'
$BackupRoot = Join-Path $SharePath 'a_Data\remote_ctl\sync_backup'

# 相对路径形式（差异遍历与 robocopy 的绝对路径排除表要保持同一口径）
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
$ExcludeDirs = $RelExcludeDirs | ForEach-Object { Join-Path $LocalRoot $_ }

$ExcludeFiles = @(
    '*.log', '*.log.err', 'build_launch_user.*', 'tmp_build_launch_*',
    '.chan_telegram_settings.json', '.chan_chip_config.json', '.chan_trend_model_config.json',
    '.chan_sync_settings.json',
    '*.locked*', '*.bak*'
)

function Write-Say([string]$m) { Write-Host ">> $m" }

# 不依赖 Get-FileHash：App 用 -File 拉起子进程时，某些 PowerShell（5.1/商店版 pwsh）
# 模块路径不完整，Get-FileHash 会报 CommandNotFoundException（2026-11-09 在 App 内踩到）。
function Get-Sha256([string]$path) {
    $fs = [IO.File]::OpenRead($path)
    try {
        $algo = [Security.Cryptography.SHA256]::Create()
        $bytes = $algo.ComputeHash($fs)
        return ([BitConverter]::ToString($bytes) -replace '-', '')
    } finally { $fs.Dispose() }
}

# ---------------- 结构化结论 ----------------
$script:Result = [ordered]@{
    ok            = $false
    peer          = $SharePath
    local         = $LocalRoot
    include       = $Include
    dryRun        = [bool]$DryRun
    diffOnly      = [bool]$DiffOnly
    new           = 0
    overwrite     = 0
    same          = 0
    onlyInPeer    = 0
    backupDir     = ''
    backupFiles   = 0
    peerAppWasLocked = $false
    peerAppStopped   = $false
    peerAppRestarted = $false
    peerAppPid       = 0
    hashes        = @()
    error         = ''
}

$script:Result['psExe'] = (Get-Process -Id $PID).Path
$script:Result['psVersion'] = $PSVersionTable.PSVersion.ToString()

function Finish([int]$code, [string]$err) {
    $script:Result.ok = ($code -eq 0)
    if ($err -ne '') { $script:Result.error = $err }
    if ($Json) {
        Write-Host '===JSON==='
        Write-Host ($script:Result | ConvertTo-Json -Depth 6)
        Write-Host '===END==='
    }
    exit $code
}

# ---------------- ① 共享可达 ----------------
if (-not (Test-Path -LiteralPath $SharePath)) {
    Write-Host "!! 共享不可达：$SharePath"
    Finish 2 "共享不可达：$SharePath"
}
Write-Say "远端根：$SharePath"
Write-Say ("本机根：$LocalRoot" + $(if ($DryRun) { '   [只看不写]' } else { '   [真写]' }))

# ---------------- 差异遍历 ----------------
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

function Walk-FileMap([string]$root, [string]$excludeMode, [string]$rel = '') {
    # excludeMode: all=目录+文件都排；files=只排文件（产物层没有仓库根相对路径，只能按文件名排）；none=不排
    $map = @{}
    if (-not (Test-Path -LiteralPath $root)) { return $map }
    $dirs = @()
    try { $dirs = @([IO.Directory]::EnumerateDirectories($root)) } catch { $dirs = @() }
    foreach ($d in $dirs) {
        $dn = [IO.Path]::GetFileName($d)
        $dr = $(if ($rel -eq '') { $dn } else { "$rel\$dn" })
        if ($excludeMode -eq 'all' -and (Test-ExcludedDir $dr)) { continue }
        $sub = Walk-FileMap $d $excludeMode $dr
        foreach ($k in $sub.Keys) { $map[$k] = $sub[$k] }
    }
    $files = @()
    try { $files = @([IO.Directory]::EnumerateFiles($root)) } catch { $files = @() }
    foreach ($f in $files) {
        $fn = [IO.Path]::GetFileName($f)
        if ($excludeMode -ne 'none' -and (Test-ExcludedFile $fn)) { continue }
        $fr = $(if ($rel -eq '') { $fn } else { "$rel\$fn" })
        $map[$fr] = [pscustomobject]@{
            size = (New-Object IO.FileInfo($f)).Length
            time = (New-Object IO.FileInfo($f)).LastWriteTimeUtc
            full = $f
        }
    }
    return $map
}

# 与 robocopy 默认判据一致：大小相同且时间差 ≤ 2 秒才算「相同」
function Measure-Layer([string]$name, [string]$src, [string]$dst, [string]$excludeMode) {
    $s = Walk-FileMap $src $excludeMode
    $d = Walk-FileMap $dst $excludeMode
    $new = @(); $over = @(); $same = 0
    foreach ($rel in $s.Keys) {
        if (-not $d.ContainsKey($rel)) { $new += $rel; continue }
        $a = $s[$rel]; $b = $d[$rel]
        $dt = [Math]::Abs(($a.time - $b.time).TotalSeconds)
        if ($a.size -eq $b.size -and $dt -le 2) { $same++ } else { $over += $rel }
    }
    $only = 0
    foreach ($rel in $d.Keys) { if (-not $s.ContainsKey($rel)) { $only++ } }
    return [pscustomobject]@{
        name = $name; new = $new; overwrite = $over; same = $same; onlyInPeer = $only
    }
}

function Show-Diff($layer) {
    Write-Say ("差异[$($layer.name)]：新增=" + $layer.new.Count + "  覆盖=" + $layer.overwrite.Count +
        "  相同=" + $layer.same + "  对端独有(不删)=" + $layer.onlyInPeer)
    $sample = @()
    $sample += @($layer.new | Select-Object -First 5 | ForEach-Object { "  新增 " + $_ })
    $sample += @($layer.overwrite | Select-Object -First 5 | ForEach-Object { "  覆盖 " + $_ })
    foreach ($l in $sample) { Write-Host $l }
    if (($layer.new.Count + $layer.overwrite.Count) -gt 10) { Write-Host '  （只列前 5 个，完整数量见上行）' }
}

$layers = @()
$needCode = ($Include -eq 'all' -or $Include -eq 'code')
$needBuild = ($Include -eq 'all' -or $Include -eq 'build')

if ($needCode) {
    $lc = Measure-Layer 'code' $LocalRoot $SharePath 'all'
    Show-Diff $lc; $layers += $lc
    $script:Result.new += $lc.new.Count
    $script:Result.overwrite += $lc.overwrite.Count
    $script:Result.same += $lc.same
    $script:Result.onlyInPeer += $lc.onlyInPeer
}
if ($needBuild) {
    if (-not (Test-Path -LiteralPath $LocalArtifact)) {
        Write-Host "!! 本机没有产物目录：$LocalArtifact（先跑 build_rust.ps1）"
        if ($DiffOnly) { Finish 6 '本机没有产物目录' }
        $script:Result.error = '本机没有产物目录'
    } else {
        $lb = Measure-Layer 'build' $LocalArtifact $RemoteArtifact 'files'
        Show-Diff $lb; $layers += $lb
        $script:Result.new += $lb.new.Count
        $script:Result.overwrite += $lb.overwrite.Count
        $script:Result.same += $lb.same
        $script:Result.onlyInPeer += $lb.onlyInPeer
    }
}

if ($DiffOnly) {
    Write-Say '差异统计完成：没有写任何文件。'
    Finish 0 ''
}

# ---------------- ② 产物占用探测 ----------------
function Test-Locked([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $fs = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
        $fs.Close()
        return $false
    } catch { return $true }
}

$artifactLocked = $false
foreach ($n in @('chan_kline.exe', 'chan_ffi.dll')) {
    if (Test-Locked (Join-Path $RemoteArtifact $n)) { $artifactLocked = $true }
}
$script:Result.peerAppWasLocked = $artifactLocked

if ($artifactLocked) {
    Write-Host "!! 远端 chan_kline.exe / chan_ffi.dll 正被占用（那台 App 在跑）"
    if ($DryRun) {
        if ($needBuild) { Write-Say '试运行：真跑(-Apply)时会先关掉「代理拉起的那一个」App 再推产物' }
        else { Write-Say '产物层被占用：本次只推源码' }
    } elseif ($needBuild -and $AutoCloseRemoteApp) {
        # 只关代理 state.json 记录在案的实例；手开的窗口它一概不碰（stop 自己会校验 exe 路径）
        $ctl = Join-Path $PSScriptRoot 'remote_ctl.ps1'
        if (-not (Test-Path -LiteralPath $ctl)) {
            Finish 3 '找不到 remote_ctl.ps1，无法自动关闭远端 App（可加 -AutoCloseRemoteApp 0 手关）'
        }
        $psExe = (Get-Process -Id $PID).Path
        if ($null -eq $psExe -or $psExe -eq '') { $psExe = 'powershell.exe' }
        Write-Say '远端 App 占着产物，先关它（仅代理记录在案的 pid）……'
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $ctl -Action stop -SharePath $SharePath -TimeoutSec 60 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Finish 3 ("远端关闭失败（remote_ctl 退出码 $LASTEXITCODE）：那台跑的可能是你手动开的 App，本脚本不替你关")
        }
        Start-Sleep -Seconds 2
        $artifactLocked = $false
        foreach ($n in @('chan_kline.exe', 'chan_ffi.dll')) {
            if (Test-Locked (Join-Path $RemoteArtifact $n)) { $artifactLocked = $true }
        }
        if ($artifactLocked) { Finish 3 '关闭后产物仍被占用，中止（不改远端任何文件）' }
        $script:Result.peerAppStopped = $true
        Write-Say '远端 App 已关闭，继续推产物'
    } elseif ($needBuild) {
        Finish 3 ("-Include=$Include 需要产物层，已中止（不改远端任何文件）。加 -Apply 默认会自动关远端 App；想手动关加 -AutoCloseRemoteApp 0")
    } else {
        Write-Say '产物层被占用：本次只推源码，不动产物'
    }
}

# ---------------- ②b 覆盖前快照（只备份将被覆盖的文件） ----------------
if ($Backup -and -not $DryRun) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $bdir = Join-Path $BackupRoot $stamp
    if (-not (Test-Path -LiteralPath $bdir)) { New-Item -ItemType Directory -Path $bdir -Force | Out-Null }
    $copied = 0
    $failed = @()
    foreach ($layer in $layers) {
        $dstRoot = $(if ($layer.name -eq 'code') { $SharePath } else { $RemoteArtifact })
        foreach ($rel in $layer.overwrite) {
            $srcFile = Join-Path $dstRoot $rel
            if (-not (Test-Path -LiteralPath $srcFile)) { continue }
            $target = Join-Path (Join-Path $bdir $layer.name) $rel
            $tdir = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $tdir)) { New-Item -ItemType Directory -Path $tdir -Force | Out-Null }
            try { Copy-Item -LiteralPath $srcFile -Destination $target -Force; $copied++ }
            catch { $failed += $rel }
        }
    }
    $script:Result.backupDir = $bdir
    $script:Result.backupFiles = $copied
    Write-Say ("快照完成：$copied 个被覆盖文件 → $bdir" + $(if ($failed.Count -gt 0) { "（失败 $($failed.Count) 个）" } else { '' }))
    # 只留最近 3 份
    try {
        $dirs = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($dirs.Count -gt 3) {
            $dirs | Select-Object -Skip 3 | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
}

# ---------------- ③ 源码层 ----------------
function Invoke-RobocopyLayer {
    param([string]$Name, [string]$Src, [string]$Dst, [string]$LogPath, [switch]$AsDryRun)

    $rcArgs = @($Src, $Dst, '/E', '/XJ', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($Name -eq 'code') {
        $rcArgs += '/XD'
        $rcArgs += $ExcludeDirs
        $rcArgs += '/XF'
        $rcArgs += $ExcludeFiles
    }
    if ($Name -eq 'build') {
        $rcArgs += '/XF'
        $rcArgs += $ExcludeFiles
    }
    if ($AsDryRun) { $rcArgs += '/L' }
    else { $rcArgs += "/LOG:$LogPath" }

    & robocopy @rcArgs | Out-Null
    $code = $LASTEXITCODE
    Write-Say ("$Name 层 robocopy 退出码=$code" + $(if ($AsDryRun) { '（试运行）' } else { '' }))
    return $code
}

$fail = $false
$logDir = Join-Path $env:TEMP 'chan_sync_logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

if ($needCode) {
    $c = Invoke-RobocopyLayer -Name 'code' -Src $LocalRoot -Dst $SharePath `
        -LogPath (Join-Path $logDir 'sync_code.log') -AsDryRun:$DryRun
    if ($c -ge 8) {
        Write-Host "!! 源码层失败（退出码 $c），日志：$(Join-Path $logDir 'sync_code.log')"
        Finish 4 "源码层 robocopy 失败（$c）"
    }
}

# ---------------- ④ 产物层 ----------------
if ((-not $fail) -and (-not $artifactLocked) -and $needBuild) {
    if (Test-Path -LiteralPath $LocalArtifact) {
        $c = Invoke-RobocopyLayer -Name 'build' -Src $LocalArtifact -Dst $RemoteArtifact `
            -LogPath (Join-Path $logDir 'sync_build.log') -AsDryRun:$DryRun
        if ($c -ge 8) {
            Write-Host "!! 产物层失败（退出码 $c），日志：$(Join-Path $logDir 'sync_build.log')"
            Finish 4 "产物层 robocopy 失败（$c）"
        }
    }
}

# ---------------- ⑤ 只读的配置模板（robot_verify 只放模板，不放运行现场） ----------------
if ((-not $DryRun) -and $needCode) {
    $rvSrc = Join-Path $LocalRoot 'a_Data\robot_verify'
    $rvDst = Join-Path $SharePath 'a_Data\robot_verify'
    if ((Test-Path -LiteralPath $rvSrc) -and (Test-Path -LiteralPath $rvDst)) {
        foreach ($f in @('README.md', 'session.json.example')) {
            $s = Join-Path $rvSrc $f
            if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $rvDst $f) -Force }
        }
        Write-Say 'robot_verify：仅同步 README.md 与 session.json.example（运行现场不动）'
    }
}

# ---------------- ⑤b 远端运行脚本重编码为 UTF-8 BOM ----------------
# 远端用 Windows PowerShell 5.1 跑 remote_app_agent.ps1：UTF-8 无 BOM + 中文会被误读，
# 甚至直接解析失败、静默退出（2026-11-09 踩过）。每次复制后统一补 BOM。
if ((-not $DryRun) -and $needCode) {
    $rp = Join-Path $SharePath 'CHAN_RUST\scripts\remote_app_agent.ps1'
    if (Test-Path -LiteralPath $rp) {
        $t = [IO.File]::ReadAllText($rp, (New-Object Text.UTF8Encoding($false, $true)))
        [IO.File]::WriteAllText($rp, $t, (New-Object Text.UTF8Encoding($true)))
        Write-Say 'remote_app_agent.ps1 已重编码为 UTF-8 BOM（远端 5.1 才能正确读中文）'
    }
}

# ---------------- ⑥ 指纹与清单校验 ----------------
if ($fail) { Finish 4 '未知失败' }

if ($DryRun) {
    Write-Say '试运行结束：没有任何远端文件被修改。加 -Apply 才会真写。'
    Finish 0 ''
}

$hashBad = 0
$hashInfo = @()
foreach ($n in @('chan_kline.exe', 'chan_ffi.dll')) {
    $s = Join-Path $LocalArtifact $n
    $d = Join-Path $RemoteArtifact $n
    if (-not (Test-Path -LiteralPath $s) -or -not (Test-Path -LiteralPath $d)) {
        Write-Host "!! 缺少产物：$n"; $hashBad++
        $hashInfo += [ordered]@{ file = $n; ok = $false; reason = '缺少文件' }
        continue
    }
    $h1 = Get-Sha256 $s
    $h2 = Get-Sha256 $d
    if ($h1 -ne $h2) {
        Write-Host "!! 指纹不一致：$n"
        $hashBad++
        $hashInfo += [ordered]@{ file = $n; ok = $false; local = $h1; peer = $h2 }
    } else {
        Write-Say ("$n 指纹一致（" + (Get-Item -LiteralPath $s).Length + ' 字节）')
        $hashInfo += [ordered]@{ file = $n; ok = $true; sha256 = $h1 }
    }
}
$script:Result.hashes = $hashInfo

foreach ($rel in @('CHAN_RUST\flutter\chan_kline\lib', 'CHAN_RUST\rust\chan_data', 'a_Data\002003')) {
    $ls = @(Get-ChildItem -LiteralPath (Join-Path $LocalRoot $rel) -Recurse -File -ErrorAction SilentlyContinue)
    $ds = @(Get-ChildItem -LiteralPath (Join-Path $SharePath $rel) -Recurse -File -ErrorAction SilentlyContinue)
    Write-Say ("$rel  本机=" + $ls.Count + "  远端=" + $ds.Count)
}

if ($hashBad -gt 0) { Finish 5 ("指纹校验未通过（$hashBad 项）") }

Write-Say '同步完成。'

# ---------------- ⑦ 可选：把刚才关掉的远端 App 再拉起来 ----------------
if ($RestartRemoteApp -and $script:Result.peerAppStopped) {
    $ctl = Join-Path $PSScriptRoot 'remote_ctl.ps1'
    if (Test-Path -LiteralPath $ctl) {
        $psExe = (Get-Process -Id $PID).Path
        if ($null -eq $psExe -or $psExe -eq '') { $psExe = 'powershell.exe' }
        Write-Say '按 -RestartRemoteApp 重新拉起远端 App……'
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $ctl -Action start -Mode ui -SharePath $SharePath -TimeoutSec 180 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $script:Result.peerAppRestarted = $true
            Write-Say '远端 App 已重新拉起（进度用 remote_ctl.ps1 -Action status 读）'
        } else {
            Write-Host "!! 重新拉起失败（remote_ctl 退出码 $LASTEXITCODE）"
        }
    }
}

Finish 0 ''
