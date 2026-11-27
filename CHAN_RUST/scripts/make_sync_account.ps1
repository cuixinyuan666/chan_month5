# make_sync_account.ps1 —— 建一个只给「双机同步」用的本地账号，并只授权仓库目录
#
# 背景：PCA 上的 86185 是微软账号绑定的账户，SMB 网络登录会 1326（用户名/密码不对），
# 用它做跨机共享不稳定；所以单独建一个本地账号 chansync，只给仓库目录 Modify 权限。
#
# 需要管理员（建本地账号必须提权）。可回滚：删除该账号 + 去掉目录上的那条 ACE：
#   Remove-LocalUser -Name chansync
#   icacls <仓库根> /remove:g "chansync"
#
# 退出码：0 成功；1 非管理员；3 失败

param(
    [string]$Account = 'chansync',
    [string]$Password = 'ChanSync2026!',
    [string]$Path = ''
)

$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '!! 需要管理员权限；请双击 开同步账号_双击这里.bat（会弹一次用户账户控制）'
    exit 1
}

if ($Path -eq '') { $Path = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
if (-not (Test-Path -LiteralPath $Path)) { Write-Host "!! 仓库路径不存在：$Path"; exit 3 }
$Path = (Resolve-Path -LiteralPath $Path).Path

$existing = Get-LocalUser -Name $Account -ErrorAction SilentlyContinue
if ($null -eq $existing) {
    $sec = ConvertTo-SecureString $Password -AsPlainText -Force
    New-LocalUser -Name $Account -Password $sec -PasswordNeverExpires -Description 'chan_month5 双机同步专用' -ErrorAction Stop | Out-Null
    Write-Host (">> 已建本地账号：$Account")
} else {
    Write-Host (">> 账号已存在：$Account")
    $sec = ConvertTo-SecureString $Password -AsPlainText -Force
    Set-LocalUser -Name $Account -Password $sec -ErrorAction SilentlyContinue
}

# 只给目录 Modify（含子目录/文件），不加管理员组
$grant = $Account + ':(OI)(CI)M'
icacls $Path /grant $grant /T /C /Q | Out-Null
Write-Host (">> 已授权 $Account 对 $Path 的修改权限")

Write-Host ''
Write-Host '>> 复核：'
Get-LocalUser -Name $Account | Select-Object Name, Enabled, Description | Format-List | Out-String | Write-Host
$ac = (Get-Acl -LiteralPath $Path).Access | Where-Object { $_.IdentityReference -match $Account } | Select-Object -First 1
if ($null -ne $ac) { Write-Host ('   ACL：' + $ac.IdentityReference + ' ' + $ac.FileSystemRights) } else { Write-Host '   !! 没查到 ACL 条目' }

Write-Host ''
Write-Host (">> 对端连接命令（PCB 上用）：")
Write-Host ("   net use \\<本机IP>\chan_month5 /user:" + $Account + ' ' + $Password + ' /persistent:yes')
exit 0
