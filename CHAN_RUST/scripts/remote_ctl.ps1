# remote_ctl.ps1 —— 本机向「另一台」的常驻代理发一个白名单动作，并等结果
#
# 依赖远端已启动 remote_app_agent.ps1（必须在它已登录的桌面会话里跑，
# 否则 GUI 起不来；代理不在线时本脚本会明确报「代理未响应」，不会假装成功）。
#
# 用法：
#   powershell -NoProfile -File CHAN_RUST\scripts\remote_ctl.ps1 -Action ping
#   ... -Action start -Mode ui          # 主界面模式（带 CHAN_AGENT_API=1，可查状态/发命令）
#   ... -Action start -Mode verify -SuiteId early_dynamic_20261105
#   ... -Action status                  # 当前股票/周期/步进位置
#   ... -Action screenshot              # 存一张图到远端 remote_ctl\shots（App 自己截的那块）
#   ... -Action screenshot -Source desktop   # 抓真人看到的整屏（看得到分笔太极/窗口）
#   ... -Action click                   # 点那台 App 窗口正中（收起分笔太极）
#   ... -Action click -X 800 -Y 500     # 指定屏幕坐标点一下
#   ... -Action command -Command '{"type":"step","dir":1}'
#   ... -Action report                  # 把远端验证报告收进 inbox 并解析 ok
#   ... -Action stop                    # 只关代理启动的那个 pid
#
# 退出码：0 结果 ok；1 结果 ok=false（远端返回失败）；2 超时/代理未响应；3 共享不可达
param(
    [string]$SharePath = '\\192.168.1.6\D$\2\chan_month5',
    [Parameter(Mandatory = $true)]
    [ValidateSet('ping', 'start', 'stop', 'status', 'snapshot', 'screenshot', 'command', 'report', 'reload', 'ps', 'click', 'windows')]
    [string]$Action,
    [ValidateSet('ui', 'verify')][string]$Mode = 'ui',
    [string]$SuiteId = '',
    [string]$Command = '',
    [ValidateSet('app', 'desktop')][string]$Source = 'app',
    [int]$X = -1,
    [int]$Y = -1,
    [int]$TimeoutSec = 60,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$CtlDir = Join-Path $SharePath 'a_Data\remote_ctl'
$ReqDir = Join-Path $CtlDir 'requests'
$ResDir = Join-Path $CtlDir 'results'
$TokenFile = Join-Path $CtlDir 'token.txt'
$InboxRoot = Join-Path $SharePath 'a_Data\robot_verify_inbox'

if (-not (Test-Path -LiteralPath $SharePath)) { Write-Host "!! 共享不可达：$SharePath"; exit 3 }
if (-not (Test-Path -LiteralPath $ReqDir)) {
    Write-Host "!! 远端还没有 remote_ctl 目录：$ReqDir"
    Write-Host "!! 先在远端启动 remote_app_agent.ps1，它会自动建目录并生成令牌"
    exit 3
}
if (-not (Test-Path -LiteralPath $TokenFile)) {
    Write-Host "!! 找不到令牌文件：$TokenFile（先启动远端代理）"
    exit 3
}
$token = ([IO.File]::ReadAllText($TokenFile)).Trim()

if ($Action -eq 'start' -and $TimeoutSec -eq 60) { $TimeoutSec = 120 }

$reqId = (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + (Get-Random -Minimum 1000 -Maximum 9999)
$argsObj = @{}
if ($Action -eq 'start') {
    $argsObj['mode'] = $Mode
    if ($SuiteId -ne '') { $argsObj['suiteId'] = $SuiteId }
}
if ($Action -eq 'command') {
    if ($Command -eq '') { Write-Host '!! -Action command 需要 -Command "<JSON>"'; exit 1 }
    try { $argsObj['body'] = ($Command | ConvertFrom-Json) } catch { Write-Host "!! -Command 不是合法 JSON：$Command"; exit 1 }
}
if ($Action -eq 'screenshot') { $argsObj['source'] = $Source }
if ($Action -eq 'click') {
    if ($X -ge 0) { $argsObj['x'] = $X }
    if ($Y -ge 0) { $argsObj['y'] = $Y }
}

$req = [pscustomobject]@{
    id        = $reqId
    action    = $Action
    token     = $token
    args      = $argsObj
    createdAt = (Get-Date).ToString('s')
}

$enc = New-Object Text.UTF8Encoding($false)
$reqPath = Join-Path $ReqDir ($reqId + '.json')
[IO.File]::WriteAllText($reqPath, ($req | ConvertTo-Json -Depth 8), $enc)
if (-not $Json) { Write-Host ">> 已下发 $Action（id=$reqId），等待远端代理……" }

$resPath = Join-Path $ResDir ($reqId + '.json')
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$got = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $resPath) {
        try { $got = ([IO.File]::ReadAllText($resPath) | ConvertFrom-Json) } catch { $got = $null }
        if ($null -ne $got) { break }
    }
}

if ($null -eq $got) {
    Write-Host "!! 超时 ${TimeoutSec} 秒：远端代理未响应（远端 Agent API 未启用、或代理没启动）"
    Write-Host "!! 检查：远端桌面已登录 且 已运行 remote_app_agent.ps1"
    Write-Host "!! 请求文件仍留在：$reqPath"
    exit 2
}

# 远端动作自己也有 ok（stop/screenshot/report 等），以它为准，别把「什么都没做」报成成功
$effectiveOk = $true
if (-not $got.ok) { $effectiveOk = $false }
if ($null -ne $got.data) {
    $names = @($got.data.PSObject.Properties.Name)
    if (($names -contains 'ok') -and ($got.data.ok -eq $false)) { $effectiveOk = $false }
}

if ($Json) {
    $got | ConvertTo-Json -Depth 10
    if ($effectiveOk) { exit 0 } else { exit 1 }
}

if ($got.ok) { Write-Host ">> 远端返回成功（动作 $($got.action)）" }
else { Write-Host "!! 远端返回失败（动作 $($got.action)）：$($got.error)" }

if ($null -ne $got.data) {
    $got.data | ConvertTo-Json -Depth 10
}

if ($Action -eq 'report' -and $got.ok) {
    $host_ = "$($got.data.inbox)".Split('\')[-1]
    $rep = Join-Path $InboxRoot ((Join-Path $host_ 'last_report.json'))
    if (Test-Path -LiteralPath $rep) {
        try {
            $r = ([IO.File]::ReadAllText($rep) | ConvertFrom-Json)
            Write-Host ''
            Write-Host '==================== 远端验收结论 ===================='
            Write-Host ('总判定 ok = ' + $r.ok)
            foreach ($p in $r.phases) {
                $tag = 'OK  '
                if ($p.skipped) { $tag = 'SKIP' } elseif (-not $p.ok) { $tag = 'FAIL' }
                Write-Host ('  [' + $tag + '] ' + $p.id)
            }
            Write-Host '======================================================'
        } catch { Write-Host "!! 报告不是合法 JSON：$rep" }
    }
}

if ($effectiveOk) { exit 0 } else { exit 1 }
