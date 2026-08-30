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

if (-not (Test-Path (Join-Path $ReleaseDir "chan_kline.exe"))) {
    throw "未找到发布目录: $ReleaseDir ，请先 flutter build windows --release"
}

if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host ">> 复制 Flutter Windows 产物"
Copy-Item -Path (Join-Path $ReleaseDir "*") -Destination $OutDir -Recurse -Force

if (-not (Test-Path (Join-Path $OutDir "chan_ffi.dll"))) {
    throw "发布目录缺少 chan_ffi.dll（exe 旁边必须有 Rust 动态库）"
}

if (Test-Path $DataSrc) {
    Write-Host ">> 复制 a_Data 到 exe 同级（解压即可加载默认股票）"
    $dataDst = Join-Path $OutDir "a_Data"
    New-Item -ItemType Directory -Force -Path $dataDst | Out-Null
    & robocopy $DataSrc $dataDst /E /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "复制 a_Data 失败，robocopy exit=$LASTEXITCODE"
    }
} else {
    Write-Warning "未找到 $DataSrc ，zip 将不含行情数据"
}

Copy-Item $ReadmeSrc (Join-Path $OutDir "使用说明.txt") -Force

if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Write-Host ">> 打包 $ZipPath"
Push-Location $OutParent
try {
    tar.exe -a -c -f "chan_kline-windows-x64.zip" "chan_kline-windows-x64"
} finally {
    Pop-Location
}

Write-Host ">> 完成 $ZipPath"
