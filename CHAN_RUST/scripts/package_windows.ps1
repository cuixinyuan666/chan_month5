# 把 Flutter Windows Release 目录打成 zip，并带上 a_Data（GitHub Releases 解压即用）
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $Root
$FlutterDir = Join-Path $Root "flutter\chan_kline"
$ReleaseDir = Join-Path $FlutterDir "build\windows\x64\runner\Release"
$OutParent = Join-Path $RepoRoot "dist"
$OutDir = Join-Path $OutParent "chan_kline-windows-x64"
$ZipPath = Join-Path $OutParent "chan_kline-windows-x64.zip"
$DataSrc = Join-Path $RepoRoot "a_Data"
$ReadmeSrc = Join-Path $PSScriptRoot "release_readme.txt"
$MinDataFiles = 5000

if (-not (Test-Path (Join-Path $ReleaseDir "chan_kline.exe"))) {
    throw "未找到发布目录: $ReleaseDir ，请先 flutter build windows --release"
}

if (-not (Test-Path $DataSrc)) {
    throw "未找到 a_Data 源目录: $DataSrc ，无法打发布包"
}

$dataFileCount = (Get-ChildItem -Path $DataSrc -Recurse -File | Measure-Object).Count
if ($dataFileCount -lt $MinDataFiles) {
    throw "a_Data 文件过少（$dataFileCount < $MinDataFiles），请检查仓库数据是否完整检出"
}
Write-Host ">> a_Data 校验通过：$dataFileCount 个文件"

if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host ">> 复制 Flutter Windows 产物"
Copy-Item -Path (Join-Path $ReleaseDir "*") -Destination $OutDir -Recurse -Force

if (-not (Test-Path (Join-Path $OutDir "chan_ffi.dll"))) {
    throw "发布目录缺少 chan_ffi.dll（exe 旁边必须有 Rust 动态库）"
}

Write-Host ">> 复制 a_Data 到 exe 同级（解压即可加载默认股票）"
$dataDst = Join-Path $OutDir "a_Data"
New-Item -ItemType Directory -Force -Path $dataDst | Out-Null
& robocopy $DataSrc $dataDst /E /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
if ($LASTEXITCODE -ge 8) {
    throw "复制 a_Data 失败，robocopy exit=$LASTEXITCODE"
}

$packedDataCount = (Get-ChildItem -Path $dataDst -Recurse -File | Measure-Object).Count
if ($packedDataCount -lt $MinDataFiles) {
    throw "打包后 a_Data 文件过少（$packedDataCount），复制可能不完整"
}
Write-Host ">> 打包目录 a_Data 共 $packedDataCount 个文件"

# 启动脚本：自动把同目录 a_Data 喂给程序（无需手设环境变量）
$LauncherPath = Join-Path $OutDir "启动 chan_kline.bat"
@'
@echo off
chcp 65001 >nul
set "CHAN_DATA_ROOT=%~dp0a_Data"
start "" "%~dp0chan_kline.exe"
'@ | Set-Content -Path $LauncherPath -Encoding UTF8

Copy-Item $ReadmeSrc (Join-Path $OutDir "使用说明.txt") -Force

if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Write-Host ">> 打包 $ZipPath"
Push-Location $OutParent
try {
    tar.exe -a -c -f "chan_kline-windows-x64.zip" "chan_kline-windows-x64"
} finally {
    Pop-Location
}

$zipSizeMb = [math]::Round((Get-Item $ZipPath).Length / 1MB, 1)
Write-Host ">> 完成 $ZipPath （${zipSizeMb} MB，含 a_Data $packedDataCount 文件）"
