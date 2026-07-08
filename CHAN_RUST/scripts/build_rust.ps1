# 编译 chan_ffi 并复制到 Flutter Windows 目录
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$RustDir = Join-Path $Root "rust"
$DllSrc = Join-Path $RustDir "target\release\chan_ffi.dll"
$DllDstDir = Join-Path $Root "flutter\chan_kline\windows\native"
$DllDst = Join-Path $DllDstDir "chan_ffi.dll"
$DebugDst = Join-Path $Root "flutter\chan_kline\build\windows\x64\runner\Debug\chan_ffi.dll"

Write-Host ">> cargo build -p chan_ffi --release"
Push-Location $RustDir
cargo build -p chan_ffi --release
Pop-Location

if (-not (Test-Path $DllSrc)) {
    throw "未找到 DLL: $DllSrc"
}

New-Item -ItemType Directory -Force -Path $DllDstDir | Out-Null
Copy-Item $DllSrc $DllDst -Force
Write-Host ">> 已复制到 $DllDst"
if (Test-Path (Split-Path $DebugDst -Parent)) {
    try {
        Copy-Item $DllSrc $DebugDst -Force
        Write-Host ">> 已复制到 $DebugDst"
    } catch {
        Write-Warning "Debug DLL 被占用，请先关闭正在运行的 chan_kline 再重试 build_rust.ps1"
    }
}
