# register_ticks_full_upload.ps1
# Register Chan\TicksFullUpload ONLOGON and run once. No token on command line.
param(
    [Parameter(Mandatory = $true)]
    [string]$JobPath,

    [Parameter(Mandatory = $true)]
    [string]$ScriptsDir,

    [string]$PythonExe = '',

    [string]$ResultPath = ''
)

$ErrorActionPreference = 'Stop'
$taskName = 'Chan\TicksFullUpload'
$schtasksExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\schtasks.exe' } else { 'C:\Windows\System32\schtasks.exe' }

function Write-Result {
    param(
        [bool]$Ok,
        [string]$Code,
        [string]$Message,
        [int]$ExitCode,
        [int]$RunExit = -1
    )
    $clean = ($Message -replace '[\r\n]+', ' ').Trim()
    if ($clean.Length -gt 300) {
        $clean = $clean.Substring(0, 300)
    }
    $payload = @{
        ok       = [bool]$Ok
        code     = $Code
        message  = $clean
        exitCode = $ExitCode
    }
    if ($RunExit -ge 0) {
        $payload.runExit = $RunExit
    }
    $json = $payload | ConvertTo-Json -Compress
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        try {
            $parent = Split-Path -Parent $ResultPath
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }
            $utf8 = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($ResultPath, $json, $utf8)
        } catch {
        }
    }
    Write-Output $json
}

function Find-Pythonw {
    param([string]$Explicit)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        $name = [System.IO.Path]::GetFileName($Explicit).ToLowerInvariant()
        if ($name -eq 'pythonw.exe' -and (Test-Path -LiteralPath $Explicit)) {
            return $Explicit
        }
        $folder = Split-Path -Parent $Explicit
        if ($folder) {
            $besideExplicit = Join-Path $folder 'pythonw.exe'
            if (Test-Path -LiteralPath $besideExplicit) { return $besideExplicit }
        }
    }
    $cmd = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $py = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($py -and $py.Source) {
        $beside = Join-Path (Split-Path -Parent $py.Source) 'pythonw.exe'
        if (Test-Path -LiteralPath $beside) { return $beside }
    }
    return $null
}

function Test-SupervisorAlive {
    param([string]$DataRoot)
    if ([string]::IsNullOrWhiteSpace($DataRoot)) { return $false }
    $lock = Join-Path $DataRoot 'local\supervisor.lock'
    if (-not (Test-Path -LiteralPath $lock)) { return $false }
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $text = [System.IO.File]::ReadAllText($lock, $utf8)
        $meta = $text | ConvertFrom-Json
        $procId = 0
        [void][int]::TryParse([string]$meta.pid, [ref]$procId)
        if ($procId -le 0) { return $false }
        return $null -ne (Get-Process -Id $procId -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

try {
    if (-not (Test-Path -LiteralPath $JobPath)) {
        throw ('job not found: ' + $JobPath)
    }
    if (-not (Test-Path -LiteralPath $ScriptsDir)) {
        throw ('scripts dir not found: ' + $ScriptsDir)
    }

    $supervisor = Join-Path $ScriptsDir 'pipeline_ticks_supervisor.py'
    if (-not (Test-Path -LiteralPath $supervisor)) {
        Write-Result -Ok $false -Code 'no_supervisor' -Message $supervisor -ExitCode 5
        exit 5
    }

    $utf8 = New-Object System.Text.UTF8Encoding $false
    $jobText = [System.IO.File]::ReadAllText($JobPath, $utf8)
    $jobObj = $jobText | ConvertFrom-Json
    $share = [string]$jobObj.shareDir
    if ([string]::IsNullOrWhiteSpace($share) -or -not (Test-Path -LiteralPath $share)) {
        Write-Result -Ok $false -Code 'share_missing' -Message $share -ExitCode 2
        exit 2
    }

    $pythonw = Find-Pythonw -Explicit $PythonExe
    if ([string]::IsNullOrWhiteSpace($pythonw)) {
        Write-Result -Ok $false -Code 'no_pythonw' -Message 'pythonw not found' -ExitCode 4
        exit 4
    }

    $dataRoot = [string]$jobObj.dataRoot
    $alive = Test-SupervisorAlive -DataRoot $dataRoot
    $tr = ('"{0}" "{1}" --job "{2}"' -f $pythonw, $supervisor, $JobPath)

    $createArgs = @(
        '/Create', '/TN', $taskName,
        '/SC', 'ONLOGON',
        '/RL', 'LIMITED',
        '/IT', '/F',
        '/TR', $tr
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $createText = (& $schtasksExe @createArgs 2>&1 | Out-String)
    $createCode = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($null -eq $createCode -or $createCode -ne 0) {
        if ($null -eq $createCode) { $createCode = 1 }
        # 非管理员会话无法用 /Create /F 覆盖已有任务（拒绝访问）。
        # 若任务已存在且指向同一 supervisor + job，则复用，继续走后面的 /Run。
        $reuseOk = $false
        try {
            $existing = Get-ScheduledTask -TaskPath '\Chan\' -TaskName 'TicksFullUpload' -ErrorAction Stop
        } catch {
            $existing = $null
        }
        if ($existing) {
            $act = $existing.Actions | Select-Object -First 1
            if ($act -and $act.Arguments -like ('*' + $supervisor + '*') -and $act.Arguments -like ('*' + $JobPath + '*')) {
                $reuseOk = $true
            }
        }
        if (-not $reuseOk) {
            Write-Result -Ok $false -Code 'schtasks_create' -Message $createText -ExitCode ([int]$createCode) -RunExit ([int]$createCode)
            exit 1
        }
        Write-Output ('reuse_existing_task: ' + ($createText -replace '[\r\n]+', ' '))
    }

    if ($alive) {
        Write-Result -Ok $true -Code 'already_running' -Message 'supervisor lock held' -ExitCode 0
        exit 0
    }

    $ErrorActionPreference = 'Continue'
    $runText = (& $schtasksExe /Run /TN $taskName 2>&1 | Out-String)
    $runCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($null -eq $runCode -or $runCode -ne 0) {
        if ($null -eq $runCode) { $runCode = 1 }
        $detail = ('schtasks /Run exit=' + $runCode + ' ' + $runText)
        Write-Result -Ok $false -Code 'run_failed' -Message $detail -ExitCode 3 -RunExit ([int]$runCode)
        exit 3
    }

    Write-Result -Ok $true -Code 'started' -Message 'registered and started' -ExitCode 0 -RunExit 0
    exit 0
}
catch {
    $msg = [string]$_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = [string]$_ }
    Write-Result -Ok $false -Code 'error' -Message $msg -ExitCode 1
    exit 1
}
