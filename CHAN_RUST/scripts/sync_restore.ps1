# sync_restore.ps1 —— 按对端最近一份快照回退（只回退快照里有的文件）
#
# 背景：sync_to_remote.ps1 -Backup 在覆盖前把「将被覆盖的文件」存到对端的
#   <对端>\a_Data\remote_ctl\sync_backup\<时间戳>\code|build\<相对路径>
# 本脚本按同一结构反向拷回，只覆盖那些文件，不删别的。
#
# 用法：
#   powershell -NoProfile -File CHAN_RUST\scripts\sync_restore.ps1            # 对端最近一份
#   ... -Stamp 20261109_104713                                                # 指定一份
#   ... -Json                                                                # 给 App 解析
#
# 语义：把「对端」被上次同步覆盖掉的文件，从对端自己的快照里拷回去（撤销那次覆盖）。
#       只覆盖快照里存在的文件，不删别的。本机仓库不动。
# 退出码：0 成功；2 共享/快照不可达；4 拷贝失败
param(
    [string]$SharePath = '\\192.168.1.6\D$\2\chan_month5',
    [string]$Stamp = '',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

if ($Json) {
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $OutputEncoding = [Console]::OutputEncoding
    } catch { }
}

$BackupRoot = Join-Path $SharePath 'a_Data\remote_ctl\sync_backup'
$Result = [ordered]@{ ok = $false; peer = $SharePath; stamp = ''; restored = 0; skipped = 0; error = '' }

function Finish([int]$code, [string]$err) {
    $Result.ok = ($code -eq 0)
    if ($err -ne '') { $Result.error = $err }
    if ($Json) {
        Write-Host '===JSON==='
        Write-Host ($Result | ConvertTo-Json -Depth 5)
        Write-Host '===END==='
    }
    exit $code
}

if (-not (Test-Path -LiteralPath $BackupRoot)) { Write-Host "!! 没有快照目录：$BackupRoot"; Finish 2 '没有快照目录' }

if ($Stamp -eq '') {
    $latest = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($latest.Count -eq 0) { Write-Host '!! 快照目录是空的'; Finish 2 '没有可用快照' }
    $Stamp = $latest[0].Name
}
$srcDir = Join-Path $BackupRoot $Stamp
if (-not (Test-Path -LiteralPath $srcDir)) { Write-Host "!! 找不到快照：$srcDir"; Finish 2 "找不到快照 $Stamp" }
$Result.stamp = $Stamp
Write-Host ">> 回退用快照：$Stamp"

$map = @(
    @{ layer = 'code'; target = $SharePath },
    @{ layer = 'build'; target = (Join-Path $SharePath 'CHAN_RUST\flutter\chan_kline\build\windows\x64\runner\Debug') }
)

foreach ($m in $map) {
    $base = Join-Path $srcDir $m.layer
    if (-not (Test-Path -LiteralPath $base)) { continue }
    $files = @(Get-ChildItem -LiteralPath $base -Recurse -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($base.Length).TrimStart('\')
        $dst = Join-Path $m.target $rel
        $ddir = Split-Path -Parent $dst
        try {
            if (-not (Test-Path -LiteralPath $ddir)) { New-Item -ItemType Directory -Path $ddir -Force | Out-Null }
            Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
            $Result.restored++
        } catch {
            Write-Host "!! 回退失败：$rel（$($_.Exception.Message)）"
            $Result.skipped++
        }
    }
}

Write-Host (">> 已回退 " + $Result.restored + " 个文件" + $(if ($Result.skipped -gt 0) { "，失败 $($Result.skipped) 个" } else { '' }))
if ($Result.skipped -gt 0) { Finish 4 "有 $($Result.skipped) 个文件回退失败" }
Finish 0 ''
