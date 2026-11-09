# check_reverse.ps1 —— 在 PCB 上建立到 PCA 的连接，并自检「能不能把本机项目推到 PCA」
#
# 做四件事，全程写日志到 a_Data\remote_ctl\reverse_check.log：
#   1. 清掉到 192.168.1.5 的旧会话与旧凭据（旧会话会挡住换身份）
#   2. 用专用本地账号 chansync 建立到 \\192.168.1.5\chan_month5 的映射（持久）
#   3. dir 校验；4. 只算差异（-DiffOnly，不动任何文件）
#
# 用法：双击 连上PCA_双击这里.bat，或
#   powershell -NoProfile -ExecutionPolicy Bypass -File CHAN_RUST\scripts\check_reverse.ps1

param(
    [string]$PeerHost = '192.168.1.5',
    [string]$ShareName = 'chan_month5',
    [string]$User = 'chansync',
    [string]$Pwd = 'ChanSync2026!',
    [switch]$SkipConnect
)

$ErrorActionPreference = 'Continue'

$RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SyncScript = Join-Path $RepoRoot 'CHAN_RUST\scripts\sync_to_remote.ps1'
$LogFile    = Join-Path $RepoRoot 'a_Data\remote_ctl\reverse_check.log'
$Share      = '\\' + $PeerHost + '\' + $ShareName

function W([string]$s) {
    Write-Host $s
    Add-Content -LiteralPath $LogFile -Value ($s + "`r`n") -Encoding UTF8
}

$dir = Split-Path -Parent $LogFile
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
Set-Content -LiteralPath $LogFile -Value ("==== 反向自检 " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " ====") -Encoding UTF8

W ("本机：" + $env:COMPUTERNAME)
W ("对端共享：" + $Share + "  账号：" + $User)

if (-not $SkipConnect) {
    W '--- 1/4 清理到对端的旧会话 ---'
    foreach ($p in @(('\\' + $PeerHost + '\IPC$'), $Share, ('\\' + $PeerHost + '\chan_ticks_state'))) {
        $r = net use $p /delete 2>&1 | Out-String
        W ('  ' + $p + ' → ' + ($r.Trim() -replace "`r`n", ' / '))
    }
    $r = cmdkey /delete:$PeerHost 2>&1 | Out-String
    W ('  cmdkey /delete:' + $PeerHost + ' → ' + ($r.Trim() -replace "`r`n", ' / '))

    W '--- 2/4 用 chansync 建立映射 ---'
    try {
        Remove-SmbMapping -RemotePath $Share -Force -ErrorAction SilentlyContinue
        New-SmbMapping -RemotePath $Share -UserName $User -Password $Pwd -Persistent $true -ErrorAction Stop | Out-Null
        W '  New-SmbMapping 成功'
    } catch {
        W ('  New-SmbMapping 失败：' + $_.Exception.Message)
    }
}

W '--- 3/4 校验共享可达 ---'
if (Test-Path -LiteralPath $Share) {
    W '  共享可达：是'
    try { Get-ChildItem -LiteralPath $Share -Force -ErrorAction Stop | Select-Object -First 10 | ForEach-Object { W ('    ' + $_.Name) } } catch { W ('  列目录失败：' + $_.Exception.Message) }
} else {
    W '  共享可达：否'
    W '结论：反向链路不通（共享没连上），看上面 2/4 的报错'
    exit 2
}

if (-not (Test-Path -LiteralPath $SyncScript)) { W ("!! 找不到脚本：$SyncScript"); exit 3 }

W '--- 4/4 只算差异（不动任何文件） ---'
$outFile = Join-Path $env:TEMP 'reverse_check_stdout.txt'
$errFile = $outFile + '.err'
$p = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$SyncScript,'-SharePath',$Share,'-DiffOnly','-Json','-Include','all') `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile -WindowStyle Hidden -Wait -PassThru
if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile | ForEach-Object { W $_ } }
if (Test-Path -LiteralPath $errFile) { $e = Get-Content -LiteralPath $errFile; if ($e) { W '--- stderr ---'; $e | ForEach-Object { W $_ } } }

W ('脚本退出码 = ' + $p.ExitCode)
if ($p.ExitCode -eq 0) { W '结论：反向链路可用（差异已算出；正式推用 App 里的「立即同步到对端」）' }
else { W '结论：反向链路不可用，看上面的退出码与报错' }
exit $p.ExitCode
