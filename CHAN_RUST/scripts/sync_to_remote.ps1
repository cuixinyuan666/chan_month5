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
#   # 只看清单（默认）：本机默认的远端是 192.168.1.6 的 D:\2\chan_month5 共享
#   powershell -NoProfile -File CHAN_RUST\scripts\sync_to_remote.ps1 -DryRun
#   # 真同步
#   powershell -NoProfile -File CHAN_RUST\scripts\sync_to_remote.ps1 -Apply
#   # 只推源码 / 只推产物
#   ... -Apply -Include code
#   ... -Apply -Include build
#
# 退出码：0 成功；2 共享不可达；3 远端 exe/dll 被占用；4 robocopy 失败；5 指纹不一致
param(
    [string]$SharePath = '\\192.168.1.6\D$\2\chan_month5',
    [string]$LocalRoot = '',
    [ValidateSet('all', 'code', 'build')][string]$Include = 'all',
    [switch]$DryRun,
    [switch]$Apply,
    [bool]$AutoCloseRemoteApp = $true,
    [switch]$RestartRemoteApp,
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'

if ($LocalRoot -eq '') {
    # PSScriptRoot = <repo>\CHAN_RUST\scripts -> 两级向上 = 仓库根
    $LocalRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

# 默认只看不动：既没给 -Apply 也没给 -DryRun 时，按 DryRun 处理（防手滑）
if (-not $Apply) { $DryRun = $true }

$FlutterDir = Join-Path $LocalRoot 'CHAN_RUST\flutter\chan_kline'
$LocalArtifact = Join-Path $FlutterDir 'build\windows\x64\runner\Debug'
$RemoteArtifact = Join-Path $SharePath 'CHAN_RUST\flutter\chan_kline\build\windows\x64\runner\Debug'

$ExcludeDirs = @(
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
) | ForEach-Object { Join-Path $LocalRoot $_ }

$ExcludeFiles = @(
    '*.log', '*.log.err', 'build_launch_user.*', 'tmp_build_launch_*',
    '.chan_telegram_settings.json', '.chan_chip_config.json', '.chan_trend_model_config.json',
    '*.locked*', '*.bak*'
)

function Write-Say([string]$m) { Write-Host ">> $m" }

# ---------- ① 共享可达 ----------
if (-not (Test-Path -LiteralPath $SharePath)) {
    Write-Host "!! 共享不可达：$SharePath"
    exit 2
}
Write-Say "远端根：$SharePath"
Write-Say ("本机根：$LocalRoot" + $(if ($DryRun) { '   [试运行，不写]' } else { '   [真写]' }))

# ---------- ② 产物占用探测 ----------
function Test-Locked([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $fs = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
        $fs.Close()
        return $false
    } catch { return $true }
}

$script:RemoteAppStopped = $false
$artifactLocked = $false
foreach ($n in @('chan_kline.exe', 'chan_ffi.dll')) {
    if (Test-Locked (Join-Path $RemoteArtifact $n)) { $artifactLocked = $true }
}
if ($artifactLocked) {
    Write-Host "!! 远端 chan_kline.exe / chan_ffi.dll 正被占用（那台 App 在跑）"
    $needBuild = ($Include -eq 'build' -or $Include -eq 'all')
    if ($DryRun) {
        if ($needBuild) { Write-Say '试运行：真跑(-Apply)时会先关掉「代理拉起的那一个」App 再推产物' }
        else { Write-Say '产物层被占用：本次只推源码' }
    } elseif ($needBuild -and $AutoCloseRemoteApp) {
        # 只关代理 state.json 记录在案的实例；手开的窗口它一概不碰（stop 自己会校验 exe 路径）
        $ctl = Join-Path $PSScriptRoot 'remote_ctl.ps1'
        if (-not (Test-Path -LiteralPath $ctl)) {
            Write-Host "!! 找不到 remote_ctl.ps1，无法自动关闭远端 App；请手动关闭后重跑（-AutoCloseRemoteApp 0 可关掉本行为）"
            exit 3
        }
        $psExe = (Get-Process -Id $PID).Path
        if ($null -eq $psExe -or $psExe -eq '') { $psExe = 'powershell.exe' }
        Write-Say '远端 App 占着产物，先关它（仅代理记录在案的 pid）……'
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $ctl -Action stop -SharePath $SharePath -TimeoutSec 60 | Out-Null
        $rc = $LASTEXITCODE
        if ($rc -ne 0) {
            Write-Host "!! 远端关闭失败（remote_ctl 退出码 $rc）：那台跑的可能是你手动开的 App，本脚本不替你关"
            exit 3
        }
        Start-Sleep -Seconds 2
        $artifactLocked = $false
        foreach ($n in @('chan_kline.exe', 'chan_ffi.dll')) {
            if (Test-Locked (Join-Path $RemoteArtifact $n)) { $artifactLocked = $true }
        }
        if ($artifactLocked) { Write-Host "!! 关闭后产物仍被占用，中止（不改远端任何文件）"; exit 3 }
        $script:RemoteAppStopped = $true
        Write-Say '远端 App 已关闭，继续推产物'
    } elseif ($needBuild) {
        Write-Host "!! -Include=$Include 需要产物层，已中止（不改远端任何文件）。加 -Apply 时默认会自动关远端 App；想手动关就加 -AutoCloseRemoteApp 0"
        exit 3
    } else {
        Write-Say '产物层被占用：本次只推源码，不动产物'
    }
}

# ---------- ③ 源码层 ----------
function Invoke-RobocopyLayer {
    param([string]$Name, [string]$Src, [string]$Dst, [string]$LogPath, [switch]$AsDryRun)

    $rcArgs = @($Src, $Dst, '/E', '/XJ', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($Name -eq 'code') {
        $rcArgs += '/XD'
        $rcArgs += $ExcludeDirs
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

if ($Include -eq 'all' -or $Include -eq 'code') {
    $c = Invoke-RobocopyLayer -Name 'code' -Src $LocalRoot -Dst $SharePath `
        -LogPath (Join-Path $logDir 'sync_code.log') -AsDryRun:$DryRun
    if ($c -ge 8) { Write-Host "!! 源码层失败（退出码 $c），日志：$(Join-Path $logDir 'sync_code.log')"; $fail = $true }
}

# ---------- ④ 产物层 ----------
if ((-not $fail) -and (-not $artifactLocked) -and ($Include -eq 'all' -or $Include -eq 'build')) {
    if (-not (Test-Path -LiteralPath $LocalArtifact)) {
        Write-Host "!! 本机没有产物目录：$LocalArtifact（先跑 build_rust.ps1）"
        $fail = $true
    } else {
        $c = Invoke-RobocopyLayer -Name 'build' -Src $LocalArtifact -Dst $RemoteArtifact `
            -LogPath (Join-Path $logDir 'sync_build.log') -AsDryRun:$DryRun
        if ($c -ge 8) { Write-Host "!! 产物层失败（退出码 $c），日志：$(Join-Path $logDir 'sync_build.log')"; $fail = $true }
    }
}

# ---------- ⑤ 只读的配置模板（robot_verify 只放模板，不放运行现场） ----------
if ((-not $fail) -and (-not $DryRun) -and ($Include -eq 'all' -or $Include -eq 'code')) {
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

# ---------- ⑤b 远端运行脚本重编码为 UTF-8 BOM ----------
# 远端用 Windows PowerShell 5.1 跑 remote_app_agent.ps1：UTF-8 无 BOM + 中文会被误读，
# 甚至直接解析失败、静默退出（2026-11-09 踩过）。每次复制后统一补 BOM。
if ((-not $DryRun) -and ($Include -eq 'all' -or $Include -eq 'code')) {
    $rp = Join-Path $SharePath 'CHAN_RUST\scripts\remote_app_agent.ps1'
    if (Test-Path -LiteralPath $rp) {
        $t = [IO.File]::ReadAllText($rp, (New-Object Text.UTF8Encoding($false, $true)))
        [IO.File]::WriteAllText($rp, $t, (New-Object Text.UTF8Encoding($true)))
        Write-Say 'remote_app_agent.ps1 已重编码为 UTF-8 BOM（远端 5.1 才能正确读中文）'
    }
}

# ---------- ⑥ 指纹与清单校验 ----------
if ($fail) { exit 4 }

if ($DryRun) {
    Write-Say '试运行结束：没有任何远端文件被修改。加 -Apply 才会真写。'
    exit 0
}

$hashBad = 0
foreach ($n in @('chan_kline.exe', 'chan_ffi.dll')) {
    $s = Join-Path $LocalArtifact $n
    $d = Join-Path $RemoteArtifact $n
    if (-not (Test-Path -LiteralPath $s) -or -not (Test-Path -LiteralPath $d)) {
        Write-Host "!! 缺少产物：$n"; $hashBad++; continue
    }
    $h1 = (Get-FileHash -LiteralPath $s -Algorithm SHA256).Hash
    $h2 = (Get-FileHash -LiteralPath $d -Algorithm SHA256).Hash
    if ($h1 -ne $h2) { Write-Host "!! 指纹不一致：$n"; $hashBad++ }
    else { Write-Say ("$n 指纹一致（" + (Get-Item -LiteralPath $s).Length + ' 字节）') }
}

foreach ($rel in @('CHAN_RUST\flutter\chan_kline\lib', 'CHAN_RUST\rust\chan_data', 'a_Data\002003')) {
    $ls = @(Get-ChildItem -LiteralPath (Join-Path $LocalRoot $rel) -Recurse -File -ErrorAction SilentlyContinue)
    $ds = @(Get-ChildItem -LiteralPath (Join-Path $SharePath $rel) -Recurse -File -ErrorAction SilentlyContinue)
    Write-Say ("$rel  本机=" + $ls.Count + "  远端=" + $ds.Count)
}

if ($hashBad -gt 0) { Write-Host "!! 指纹校验未通过（$hashBad 项）"; exit 5 }

Write-Say '同步完成。'

# ---------- ⑦ 可选：把刚才关掉的远端 App 再拉起来 ----------
if ($RestartRemoteApp -and $script:RemoteAppStopped) {
    $ctl = Join-Path $PSScriptRoot 'remote_ctl.ps1'
    if (Test-Path -LiteralPath $ctl) {
        $psExe = (Get-Process -Id $PID).Path
        if ($null -eq $psExe -or $psExe -eq '') { $psExe = 'powershell.exe' }
        Write-Say '按 -RestartRemoteApp 重新拉起远端 App……'
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $ctl -Action start -Mode ui -SharePath $SharePath -TimeoutSec 180 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Say '远端 App 已重新拉起（进度用 remote_ctl.ps1 -Action status 读）' }
        else { Write-Host "!! 重新拉起失败（remote_ctl 退出码 $LASTEXITCODE）" }
    }
}
exit 0
