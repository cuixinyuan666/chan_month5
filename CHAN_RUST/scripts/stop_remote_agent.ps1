# stop_remote_agent.ps1 —— 停掉远端代理的旧实例（供 bat 换代使用）
# 只按命令行匹配 remote_app_agent.ps1，且排除自己，不动其他 PowerShell 进程。
$me = $PID
$targets = Get-CimInstance Win32_Process | Where-Object {
    $_.CommandLine -like '*remote_app_agent.ps1*' -and $_.ProcessId -ne $me
}
foreach ($t in $targets) {
    try { Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
}
Start-Sleep -Milliseconds 800
