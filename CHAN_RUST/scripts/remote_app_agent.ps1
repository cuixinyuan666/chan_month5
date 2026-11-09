# remote_app_agent.ps1 —— 远端常驻代理（跑在「另一台」的已登录桌面会话里）
#
# 为什么必须跑在桌面会话：chan_kline 是 GUI 程序。远程 PowerShell / WinRM 落在 session 0，
# 拉起的窗口看不见也起不来。所以这个代理要在那台的桌面上启动（双击或「登录时运行」计划任务）。
#
# 它只做白名单动作，不执行任意命令：
#   ping / start / stop / status / snapshot / screenshot / command / report
#
# 协议（全部在仓库内 a_Data\remote_ctl 下）：
#   本机写 requests\<id>.json  ->  代理读 -> 执行 -> 写 results\<id>.json -> 请求移入 done\
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File remote_app_agent.ps1 -RepoRoot D:\2\chan_month5
#   ... -Once        只处理一轮（联调用）
param(
    [string]$RepoRoot = 'D:\2\chan_month5',
    [switch]$Once,
    [int]$PollMs = 1000
)

$ErrorActionPreference = 'Stop'
$AgentVersion = '1.1.3'
$CtlDir = Join-Path $RepoRoot 'a_Data\remote_ctl'
$ReqDir = Join-Path $CtlDir 'requests'
$ResDir = Join-Path $CtlDir 'results'
$DoneDir = Join-Path $CtlDir 'done'
$ShotDir = Join-Path $CtlDir 'shots'
$LogDir = Join-Path $CtlDir 'log'
$TokenFile = Join-Path $CtlDir 'token.txt'
$StateFile = Join-Path $CtlDir 'state.json'
$LockFile = Join-Path $CtlDir 'agent.lock'

$ExePath = Join-Path $RepoRoot 'CHAN_RUST\flutter\chan_kline\build\windows\x64\runner\Debug\chan_kline.exe'
$ApiTokenFile = Join-Path $RepoRoot 'a_Data\agent_live\agent_api_token.txt'
$VerifyDir = Join-Path $RepoRoot 'a_Data\robot_verify'
$InboxDir = Join-Path $RepoRoot 'a_Data\robot_verify_inbox'
$ApiBase = 'http://127.0.0.1:12321'

foreach ($d in @($CtlDir, $ReqDir, $ResDir, $DoneDir, $ShotDir, $LogDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Write-Log([string]$msg) {
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg
    $file = Join-Path $LogDir ((Get-Date -Format 'yyyy-MM-dd') + '.log')
    Add-Content -LiteralPath $file -Value $line -Encoding UTF8
    Write-Host $line
}

function Write-JsonFile([string]$path, $obj) {
    $json = $obj | ConvertTo-Json -Depth 8
    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($path, $json, $enc)
}

function Read-Token() {
    if (-not (Test-Path -LiteralPath $TokenFile)) { return '' }
    return ([IO.File]::ReadAllText($TokenFile)).Trim()
}

function Get-ApiToken {
    if (-not (Test-Path -LiteralPath $ApiTokenFile)) { return $null }
    return ([IO.File]::ReadAllText($ApiTokenFile)).Trim()
}

function Invoke-Api([string]$relPath, [string]$method, $body) {
    $tok = Get-ApiToken
    if ($null -eq $tok -or $tok -eq '') { throw '远端 Agent API 未启用：找不到 a_Data\agent_live\agent_api_token.txt（App 启动时需 CHAN_AGENT_API=1）' }
    $h = @{ 'X-Agent-Token' = $tok }
    if ($method -eq 'GET') {
        return Invoke-RestMethod -Uri ($ApiBase + $relPath) -Headers $h -TimeoutSec 20
    }
    $json = $body | ConvertTo-Json -Depth 8 -Compress
    return Invoke-RestMethod -Uri ($ApiBase + $relPath) -Method Post -Headers $h -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 30
}

function Get-ProcState([int]$procId) {
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return [pscustomobject]@{ pid = $p.Id; responding = $p.Responding; start = $p.StartTime.ToString('s') }
}

function Save-AppState($obj) {
    Write-JsonFile $StateFile $obj
}

function Get-AppState() {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try { return ([IO.File]::ReadAllText($StateFile) | ConvertFrom-Json) } catch { return $null }
}

# ---------------- 动作实现 ----------------

function Do-Ping($a) {
    $sessionId = 0
    try { $sessionId = (Get-Process -Id $PID).SessionId } catch { }
    return [pscustomobject]@{
        host          = $env:COMPUTERNAME
        agent_version = $AgentVersion
        agent_pid     = $PID
        session_id    = $sessionId
        desktop       = ($sessionId -ne 0)
        time          = (Get-Date).ToString('s')
        repo_root     = $RepoRoot
        exe_exists    = (Test-Path -LiteralPath $ExePath)
        api_token_exists = (Test-Path -LiteralPath $ApiTokenFile)
    }
}

function Do-Start($a) {
    $mode = 'ui'
    if ($null -ne $a -and $null -ne $a.mode -and "$($a.mode)" -ne '') { $mode = "$($a.mode)" }
    if (-not (Test-Path -LiteralPath $ExePath)) { throw "找不到 exe：$ExePath" }

    # 已有代理启动的实例在跑：先按 stop 处理，避免两个窗口
    $st = Get-AppState
    if ($null -ne $st -and $null -ne $st.pid) {
        if ($null -ne (Get-ProcState ([int]$st.pid))) {
            Stop-Process -Id ([int]$st.pid) -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }

    # 按模式控制 session.json：verify 才置 active=true
    $sessPath = Join-Path $VerifyDir 'session.json'
    if (-not (Test-Path -LiteralPath $VerifyDir)) { New-Item -ItemType Directory -Path $VerifyDir -Force | Out-Null }
    $suiteId = 'early_dynamic_20261105'
    if ($null -ne $a -and $null -ne $a.suiteId -and "$($a.suiteId)" -ne '') { $suiteId = "$($a.suiteId)" }
    $sess = [ordered]@{
        active       = ($mode -eq 'verify')
        mode         = 'auto'
        suiteId      = $suiteId
        taskTitle    = 'remote_agent'
        authorizedAt = (Get-Date).ToString('s')
        authorizedBy = 'agent(remote)'
    }
    Write-JsonFile $sessPath $sess

    # 三个环境变量必须一起给对，否则远端会算错根目录：
    #   CHAN_REPO_ROOT  仓库根（resolveRepoRoot 最高优先级）
    #   CHAN_KLINE_ROOT 必须指向 chan_kline 目录（代码里拿它 parent×3 得仓库根）
    #   CHAN_DATA_ROOT  a_Data 绝对路径（chan_ffi.dll 默认根是编译期常量，跨机器必须覆盖）
    $env:CHAN_REPO_ROOT = $RepoRoot
    $env:CHAN_KLINE_ROOT = (Join-Path $RepoRoot 'CHAN_RUST\flutter\chan_kline')
    $env:CHAN_DATA_ROOT = (Join-Path $RepoRoot 'a_Data')
    if ($mode -eq 'ui') { $env:CHAN_AGENT_API = '1' } else { $env:CHAN_AGENT_API = '0' }

    $work = Split-Path -Parent $ExePath
    $p = Start-Process -FilePath $ExePath -WorkingDirectory $work -PassThru
    $deadline = (Get-Date).AddSeconds(60)
    $responding = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        $p.Refresh()
        if ($p.HasExited) { break }
        if ($p.Responding) { $responding = $true; break }
    }

    Save-AppState ([pscustomobject]@{
            pid       = $p.Id
            mode      = $mode
            exe       = $ExePath
            suite_id  = $suiteId
            started   = (Get-Date).ToString('s')
            responding = $responding
        })

    $title = ''
    $exitCode = $null
    try { $p.Refresh() } catch { }
    if ($p.HasExited) { try { $exitCode = $p.ExitCode } catch { } } else { try { $title = $p.MainWindowTitle } catch { } }

    return [pscustomobject]@{
        pid         = $p.Id
        mode        = $mode
        suite_id    = $suiteId
        responding  = $responding
        exited      = $p.HasExited
        exit_code   = $exitCode
        window_title = $title
        exe         = $ExePath
    }
}

function Do-Stop($a) {
    $st = Get-AppState
    if ($null -eq $st -or $null -eq $st.pid) {
        return [pscustomobject]@{ ok = $false; message = '没有任何由代理启动的实例记录' }
    }
    $procId = [int]$st.pid
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($null -eq $p) {
        return [pscustomobject]@{ ok = $true; message = '该 pid 已不在运行'; pid = $procId }
    }
    $sameExe = $false
    try { $sameExe = ($p.Path -eq $st.exe) } catch { $sameExe = $false }
    if (-not $sameExe) {
        return [pscustomobject]@{ ok = $false; message = 'pid 对应进程不是代理记录的那个 exe，拒绝关闭（避免误杀你手动开的窗口）'; pid = $procId }
    }
    Stop-Process -Id $procId -Force
    Start-Sleep -Seconds 2
    $still = Get-Process -Id $procId -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ok = ($null -eq $still); pid = $procId; message = '已关闭' }
}

function Do-Status($a) {
    $st = Get-AppState
    $live = Invoke-Api '/state' 'GET' $null
    return [pscustomobject]@{
        ok      = $true
        app     = $live
        agent_state = $st
    }
}

function Do-Snapshot($a) {
    return (Invoke-Api '/snapshot' 'GET' $null)
}

function Do-Screenshot($a) {
    $name = 'shot_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.png'
    $out = Join-Path $ShotDir $name
    # 先走 App 自己的 /screenshot
    try {
        $tok = Get-ApiToken
        if ($null -ne $tok -and $tok -ne '') {
            $h = @{ 'X-Agent-Token' = $tok }
            Invoke-WebRequest -Uri ($ApiBase + '/screenshot') -Headers $h -OutFile $out -TimeoutSec 30 | Out-Null
            $size = 0
            if (Test-Path -LiteralPath $out) { $size = (Get-Item -LiteralPath $out).Length }
            if ($size -gt 0) { return [pscustomobject]@{ ok = $true; method = 'agent_api'; file = $out; bytes = $size } }
        }
    } catch {
        # API 没起（12321 未监听 / K 线没加载），落到桌面抓图
    }
    # 兜底：抓整个虚拟桌面（多显示器也能一次抓全）
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, (New-Object System.Drawing.Size $vs.Width, $vs.Height))
        $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose()
        $bmp.Dispose()
        $size = 0
        if (Test-Path -LiteralPath $out) { $size = (Get-Item -LiteralPath $out).Length }
        return [pscustomobject]@{ ok = ($size -gt 0); method = 'gdi_desktop'; file = $out; bytes = $size; session = (Get-Process -Id $PID).SessionId; screens = [System.Windows.Forms.Screen]::AllScreens.Count }
    } catch {
        return [pscustomobject]@{ ok = $false; method = 'none'; error = "$($_.Exception.Message)" }
    }
}

function Do-Ps($a) {
    $list = @()
    $procs = @(Get-Process -Name 'chan_kline' -ErrorAction SilentlyContinue)
    foreach ($pr in $procs) {
        $title = ''
        $responding = $null
        $start = ''
        try { $title = $pr.MainWindowTitle } catch { }
        try { $responding = $pr.Responding } catch { }
        try { $start = $pr.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { }
        $list += [pscustomobject]@{
            pid = $pr.Id; responding = $responding; window_title = $title
            session = $pr.SessionId; started = $start; ws = $pr.WorkingSet64
        }
    }
    return [pscustomobject]@{ ok = $true; count = $list.Count; processes = $list }
}

function Do-Reload($a) {
    $script:NeedReload = $true
    return [pscustomobject]@{ ok = $true; pid = $PID; message = '本实例即将退出，由新实例接手' }
}

function Do-Command($a) {
    if ($null -eq $a -or $null -eq $a.body) { throw 'command 需要 args.body（命令对象）' }
    return (Invoke-Api '/command' 'POST' $a.body)
}

function Do-Report($a) {
    if (-not (Test-Path -LiteralPath $InboxDir)) { New-Item -ItemType Directory -Path $InboxDir -Force | Out-Null }
    $dest = Join-Path $InboxDir $env:COMPUTERNAME
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    $copied = @()
    foreach ($f in @('status.json', 'last_report.json', 'last_report.txt')) {
        $s = Join-Path $VerifyDir $f
        if (Test-Path -LiteralPath $s) {
            $d = Join-Path $dest $f
            Copy-Item -LiteralPath $s -Destination $d -Force
            $stamp = Join-Path $dest ($f + '.' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Copy-Item -LiteralPath $s -Destination $stamp -Force
            $copied += $d
        }
    }
    $ok = $null
    $rep = Join-Path $dest 'last_report.json'
    if (Test-Path -LiteralPath $rep) {
        try { $ok = ([IO.File]::ReadAllText($rep) | ConvertFrom-Json).ok } catch { $ok = $null }
    }
    return [pscustomobject]@{ ok = $ok; copied = $copied; inbox = $dest }
}

function Invoke-Action([string]$action, $a) {
    switch ($action) {
        'ping' { return (Do-Ping $a) }
        'start' { return (Do-Start $a) }
        'stop' { return (Do-Stop $a) }
        'status' { return (Do-Status $a) }
        'snapshot' { return (Do-Snapshot $a) }
        'screenshot' { return (Do-Screenshot $a) }
        'command' { return (Do-Command $a) }
        'report' { return (Do-Report $a) }
        'reload' { return (Do-Reload $a) }
        'ps' { return (Do-Ps $a) }
        default { throw "未知动作：$action（只接受 ping/start/stop/status/snapshot/screenshot/command/report/reload/ps）" }
    }
}

# 令牌：没有就生成（本机只读它，从不改写；远端这边由代理自己造一次）
if (-not (Test-Path -LiteralPath $TokenFile)) {
    $t = [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($TokenFile, $t, (New-Object Text.UTF8Encoding($false)))
    Write-Log '已生成令牌文件（以后本机请求都要带它）'
}
$script:AgentToken = (Read-Token).Trim()
if ($script:AgentToken -eq '') { Write-Log '!! 令牌为空，本代理拒绝所有请求'; exit 1 }
# ---------------- 单实例锁 ----------------
$lockHandle = $null
try {
    $lockHandle = [IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    Write-Host '!! 已有代理实例在跑（锁被占用），本实例退出'
    exit 0
}

Write-Log ('代理启动：host=' + $env:COMPUTERNAME + ' pid=' + $PID + ' repo=' + $RepoRoot + ' version=' + $AgentVersion)
$sessionId = 0
try { $sessionId = (Get-Process -Id $PID).SessionId } catch { }
if ($sessionId -eq 0) {
    Write-Log '!! 警告：当前在 session 0，GUI 程序拉不起来。请在已登录的桌面上启动本代理'
} else {
    Write-Log ('会话 id=' + $sessionId + '，可以拉起 GUI')
}

# ---------------- 主循环 ----------------
while ($true) {
    try {
        $reqs = @(Get-ChildItem -LiteralPath $ReqDir -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
        foreach ($rf in $reqs) {
            $id = $rf.BaseName
            $req = $null
            try { $req = ([IO.File]::ReadAllText($rf.FullName) | ConvertFrom-Json) } catch { $req = $null }

            $result = $null
            if ($null -eq $req) {
                $result = [pscustomobject]@{ ok = $false; action = ''; id = $id; error = '请求不是合法 JSON' }
            } else {
                $tokOk = (($script:AgentToken -ne '') -and ($req.token -eq $script:AgentToken))
                if (-not $tokOk) {
                    Write-Log "拒绝：$id 令牌不符"
                    $result = [pscustomobject]@{ ok = $false; action = "$($req.action)"; id = $id; error = '令牌不符，已拒绝' }
                } else {
                    try {
                        $data = Invoke-Action "$($req.action)" $req.args
                        $result = [pscustomobject]@{ ok = $true; action = "$($req.action)"; id = $id; host = $env:COMPUTERNAME; data = $data }
                        Write-Log "执行：$id 动作=$($req.action) 成功"
                    } catch {
                        $result = [pscustomobject]@{ ok = $false; action = "$($req.action)"; id = $id; error = "$($_.Exception.Message)" }
                        Write-Log "执行：$id 动作=$($req.action) 失败：$($_.Exception.Message)"
                    }
                }
            }

            $resPath = Join-Path $ResDir ($id + '.json')
            try { Write-JsonFile $resPath $result } catch { Write-Log "写结果失败：$id $($_.Exception.Message)" }
            try { Move-Item -LiteralPath $rf.FullName -Destination (Join-Path $DoneDir $rf.Name) -Force } catch { }

            # reload：先释放锁，再拉起自己，然后退出，避免新实例撞锁
            if ($script:NeedReload) {
                try { $lockHandle.Close() } catch { }
                $self = $MyInvocation.MyCommand.Path
                if ($null -eq $self -or $self -eq '') { $self = Join-Path $RepoRoot 'CHAN_RUST\scripts\remote_app_agent.ps1' }
                $psExe = Join-Path $PSHOME 'powershell.exe'
                Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self, '-RepoRoot', $RepoRoot) -WindowStyle Hidden
                Write-Log 'reload：已拉起新实例，本实例退出'
                exit 0
            }
        }
    } catch {
        Write-Log ('主循环异常：' + $_.Exception.Message)
    }

    if ($Once) { break }
    Start-Sleep -Milliseconds $PollMs
}

if ($null -ne $lockHandle) { $lockHandle.Close() }
Write-Log '代理退出'
