# share_repo.ps1 —— 给本机仓库开一个 SMB 共享（双机同步反向要用）
#
# 为什么需要管理员：New-SmbShare 属于系统级操作，普通权限 shell 会「拒绝访问」。
# 本脚本只做三件事：确认管理员 → 共享不存在就建、已存在就核对 → 打印网络路径。
#
# 用法（管理员 PowerShell）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File CHAN_RUST\scripts\share_repo.ps1
#   ... -ShareName chan_month5 -Path <仓库根>
#
# 退出码：0 成功（新建或已就绪）；1 不是管理员；2 路径不对；3 建共享失败

param(
    [string]$ShareName = 'chan_month5',
    [string]$Path = ''
)

$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '!! 这个窗口没有管理员权限，建共享会被拒绝。'
    Write-Host '   请用「开共享_双击这里.bat」双击运行（会弹一次用户账户控制）。'
    exit 1
}

if ($Path -eq '') { $Path = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "!! 仓库路径不存在：$Path"
    exit 2
}
$Path = (Resolve-Path -LiteralPath $Path).Path
Write-Host (">> 仓库路径：$Path")

$existing = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
if ($null -ne $existing) {
    Write-Host (">> 共享已存在：$ShareName → $($existing.Path)")
    if ($existing.Path -ne $Path) {
        Write-Host "!! 已有同名共享指向别处（$($existing.Path)），本脚本不擅自改，请手动处理。"
        exit 3
    }
    try { Grant-SmbShareAccess -Name $ShareName -AccountName 'Everyone' -AccessRight Full -Force -ErrorAction Stop | Out-Null } catch { }
} else {
    try {
        New-SmbShare -Name $ShareName -Path $Path -FullAccess 'Everyone' -Description 'chan_month5 双机同步' -ErrorAction Stop | Out-Null
        Write-Host (">> 已建共享：$ShareName → $Path（Everyone 读写）")
    } catch {
        Write-Host ("!! 建共享失败：" + $_.Exception.Message)
        exit 3
    }
}

try {
    # 让 SMB 侧允许匿名/去密码访问读写（不达标时对端会 401）
    Set-SmbShare -Name $ShareName -EncryptData $false -Force -ErrorAction Stop | Out-Null
} catch { }

$ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.*' } |
    Sort-Object -Property @{Expression = { if ($_.IPAddress -like '192.168.*') { 0 } else { 1 } } } |
    Select-Object -ExpandProperty IPAddress)
Write-Host ''
Write-Host '>> 对外网络路径（把这一行填进对端 App 的「对端项目路径」）：'
foreach ($ip in $ips) { Write-Host ("   \\" + $ip + "\" + $ShareName) }
Write-Host ''
Write-Host '>> 复核：'
net share $ShareName
exit 0
