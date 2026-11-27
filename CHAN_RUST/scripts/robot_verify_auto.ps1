# robot_verify_auto.ps1 —— 机器人验证「全自动化」入口（agent 专用）
#
# 2026-10-10 起按用户要求放开：默认由 agent 全程负责，不再需要用户在场。
# 链路：写 session.json -> (可选)后台编译 -> 启动 App(自动进入验证模式) -> 轮询 status.json
#       -> 自动关 App -> 读 last_report.json -> 打印验收结论
#
# 唯一硬约束：不得关闭「用户正在手动使用」的 App。
#   - 脚本启动前若已存在 chan_kline 进程，视为用户手动在用 -> 默认拒绝继续（除非 -Force）。
#   - -Force 仅在用户明确要求时使用。
param(
    [string]$SuiteId = '',
    [switch]$SkipBuild,
    [switch]$NoClose,
    [switch]$Force,
    [switch]$Attach,
    [int]$TimeoutSec = 1800,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot            # CHAN_RUST
$RepoRoot = Split-Path -Parent $Root                 # 仓库根
$FlutterDir = Join-Path $Root 'flutter\chan_kline'
$ExePath = Join-Path $FlutterDir 'build\windows\x64\runner\Debug\chan_kline.exe'
$VerifyDir = Join-Path $RepoRoot 'a_Data\robot_verify'
$SessionPath = Join-Path $VerifyDir 'session.json'
$StatusPath = Join-Path $VerifyDir 'status.json'
$ReportJson = Join-Path $VerifyDir 'last_report.json'
$ReportTxt = Join-Path $VerifyDir 'last_report.txt'
$BuildLog = Join-Path $FlutterDir 'build_rust_run.log'

function Say([string]$m) { if (-not $Json) { Write-Host ">> $m" } }

New-Item -ItemType Directory -Force -Path $VerifyDir | Out-Null

# ---------- ① 安全检查：是否已有 App 在跑（可能是用户手动在用） ----------
# -Attach：App 已在跑验证（或上一轮编排中断），**不杀不重编**，直接接管轮询。
$pre = @(Get-Process -Name chan_kline -ErrorAction SilentlyContinue)
if ($pre.Count -gt 0 -and -not $Attach) {
    if (-not $Force) {
        Write-Host "!! 检测到 chan_kline 已在运行 (PID: $($pre.Id -join ','))。"
        Write-Host "!! 这可能意味着用户正在手动使用 —— 按规则不得擅自关闭。"
        Write-Host "!! 处理：请先关闭该 App，或加 -Force 强制接管，或加 -Attach 只接管轮询。"
        exit 2
    }
    Say "强制接管：先关闭已运行的 chan_kline (PID: $($pre.Id -join ','))"
    $pre | Stop-Process -Force
    Start-Sleep -Seconds 2
} elseif ($pre.Count -gt 0) {
    Say "-Attach：接管已在运行的 chan_kline (PID: $($pre.Id -join ','))，不关闭不重编"
}

# ---------- ② 写 session.json（先于启动，否则 App 不会进验证模式） ----------
$sess = [ordered]@{
    active       = $true
    mode         = 'auto'
    suiteId      = $SuiteId
    taskTitle    = 'auto'
    authorizedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    authorizedBy = 'agent(auto)'
}
if ([string]::IsNullOrWhiteSpace($sess.suiteId)) {
    if (Test-Path $SessionPath) {
        $old = Get-Content $SessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sess.suiteId = $old.suiteId
    } else {
        Write-Host "!! 未指定 -SuiteId，且 $SessionPath 不存在。"
        exit 3
    }
}
$sessionText = $sess | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText($SessionPath, $sessionText, (New-Object Text.UTF8Encoding($false)))
Say "session.json: suiteId=$($sess.suiteId) active=true"

# ---------- ③ 清掉上一轮报告，避免读到陈旧结果 ----------
# ⚠ 只在「本次真的要启动 App」时才清。
# 踩过：-Attach 接管已在跑的验证时也清了一遍，把 App 刚写下的异常报告擦掉了，
# 结果只看到 status.json 的 message:exception，真正的原因（error/stack）没了。
if (-not $Attach) {
    foreach ($f in @($StatusPath, $ReportJson, $ReportTxt)) {
        if (Test-Path $f) { Remove-Item $f -Force }
    }
}

# ---------- ④ 编译（可选） ----------
if ($Attach) {
    Say "-Attach：跳过编译，直接进入轮询"
} elseif (-not $SkipBuild) {
    $buildScript = Join-Path $PSScriptRoot 'build_rust.ps1'
    if (-not (Test-Path $buildScript)) { Write-Host "!! 找不到 build_rust.ps1"; exit 4 }
    if (Test-Path $BuildLog) { Remove-Item $BuildLog -Force }
    Say "后台启动编译 build_rust.ps1（日志：$BuildLog）……"
    # 必须 detached：build_rust.ps1 末尾前台拉起 exe，会一直阻塞到 App 关闭。
    # 关键：**输出重定向由本脚本负责** —— build_rust.ps1 自己不写日志，
    # 不重定向的话下面的「等 Launch 行」会永远等不到（踩过）。
    Start-Process -FilePath 'powershell' `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$buildScript`"" `
        -WorkingDirectory $FlutterDir -WindowStyle Hidden `
        -RedirectStandardOutput $BuildLog `
        -RedirectStandardError "$BuildLog.err" | Out-Null

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $launched = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        # 兜底一：进程已经起来了就算编译完成（比等日志更可靠）
        if (@(Get-Process -Name chan_kline -ErrorAction SilentlyContinue).Count -gt 0) {
            $launched = $true
            break
        }
        if (Test-Path $BuildLog) {
            $log = Get-Content $BuildLog -Raw -ErrorAction SilentlyContinue
            if ($log -match 'Launch \(no flutter run\)') { $launched = $true; break }
            if ($log -match 'flutter build windows failed|EXE missing after build') {
                Write-Host "!! 编译失败，日志尾部："
                Get-Content $BuildLog -Tail 30
                exit 5
            }
        }
    }
    if (-not $launched) { Write-Host "!! 等待编译超时或未看到 Launch 行"; exit 5 }
    Say "编译完成，App 已由 build_rust.ps1 拉起"
} else {
    if (-not (Test-Path $ExePath)) { Write-Host "!! -SkipBuild 但找不到 exe：$ExePath"; exit 4 }
    $env:CHAN_REPO_ROOT = $RepoRoot
    $env:CHAN_KLINE_ROOT = $FlutterDir
    Say "跳过编译，直接启动 $ExePath"
    Start-Process -FilePath $ExePath -WorkingDirectory $FlutterDir | Out-Null
}

# ---------- ⑤ 轮询等待完成 ----------
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
$lastPhase = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    if (Test-Path $StatusPath) {
        try {
            $st = Get-Content $StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $cur = "$($st.phase)"
            if ($cur -ne $lastPhase) { Say "status: $cur"; $lastPhase = $cur }
            if ($cur -eq 'done') { $done = $true; break }
            if ($cur -eq 'error') { Say "status: error"; break }
        } catch { }
    }
}

# ---------- ⑥ 关闭 App ----------
$app = @(Get-Process -Name chan_kline -ErrorAction SilentlyContinue)
if ($app.Count -gt 0) {
    if ($NoClose) { Say "保留 App 窗口（-NoClose）" }
    else { Say "关闭 App (PID: $($app.Id -join ','))"; $app | Stop-Process -Force }
}

# ---------- ⑦ 取报告 ----------
$src = $null
foreach ($f in @($ReportJson, $ReportTxt)) { if (Test-Path $f) { $src = $f; break } }
if ($null -eq $src) {
    Write-Host "!! 未产出报告（done=$done）。status.json 存在：$(Test-Path $StatusPath)"
    if (Test-Path $StatusPath) { Get-Content $StatusPath -Raw }
    exit 6
}
Say "报告：$src"
$payload = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8).Trim()

# ---------- ⑧ 打印结论 ----------
try {
    $rep = $payload | ConvertFrom-Json
} catch {
    Write-Host "!! 报告不是合法 JSON：$payload"
    exit 7
}

if ($Json) { Write-Output $payload }

$failed = @($rep.phases | Where-Object { -not $_.ok -and -not $_.skipped })
$skipped = @($rep.phases | Where-Object { $_.skipped })

Write-Host ""
Write-Host "==================== 验收结论 ===================="
Write-Host ("总判定 ok = " + $rep.ok)
Write-Host ("阶段数 = " + @($rep.phases).Count + "  失败 = " + $failed.Count + "  跳过 = " + $skipped.Count)
foreach ($p in $rep.phases) {
    $tag = if ($p.skipped) { 'SKIP' } elseif ($p.ok) { 'OK  ' } else { 'FAIL' }
    Write-Host ("  [$tag] " + $p.id)
}
if ($skipped.Count -gt 0) {
    Write-Host "-- 被跳过的阶段（如实列出，不可当作已验证）--"
    foreach ($p in $skipped) { Write-Host ("  " + $p.id + " : " + $p.skipReason) }
}
if ($failed.Count -gt 0) {
    Write-Host "-- 失败明细（agent 须逐条如实报告，不得放宽判据）--"
    foreach ($p in $failed) {
        Write-Host ("  !! " + $p.id)
        if ($null -ne $p.details) {
            Write-Host ("     " + ($p.details | ConvertTo-Json -Depth 6 -Compress))
        }
    }
}
Write-Host "==================================================="

if ($rep.ok) { exit 0 } else { exit 1 }