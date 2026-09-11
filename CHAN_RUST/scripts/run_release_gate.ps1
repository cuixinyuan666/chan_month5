# 发布前闸门：Rust 单测 + 编库 + Flutter 库版本/走完对拍。
# 失败则不要打 zip。本机：在仓库根执行
#   powershell -File CHAN_RUST/scripts/run_release_gate.ps1
# 依赖：a_Data/002003、能编 chan_ffi。DLL 被占用时不要强杀正在用的软件。
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $Root
$RustDir = Join-Path $Root "rust"
$FlutterDir = Join-Path $Root "flutter\chan_kline"
$DllSrc = Join-Path $RustDir "target\release\chan_ffi.dll"
$DllDstDir = Join-Path $FlutterDir "windows\native"
$DllDst = Join-Path $DllDstDir "chan_ffi.dll"

Set-Location $RepoRoot

Write-Host ">> cargo test --workspace"
Push-Location $RustDir
try {
    cargo test -p chan_data
    Write-Host ">> cargo build -p chan_ffi --release"
    cargo build -p chan_ffi --release
} finally {
    Pop-Location
}

if (-not (Test-Path $DllSrc)) {
    throw "未生成 $DllSrc"
}
New-Item -ItemType Directory -Force -Path $DllDstDir | Out-Null
try {
    Copy-Item $DllSrc $DllDst -Force
} catch {
    throw "无法覆盖 $DllDst（多半是软件还开着占用了库）。请先关掉 chan_kline 再跑本脚本。$_"
}
Write-Host ">> 已覆盖 $DllDst"

Write-Host ">> flutter test 库版本 + 单步/走完冻结对拍"
Push-Location $FlutterDir
try {
    flutter pub get
    flutter test test/chan_ffi_abi_test.dart test/run_to_end_vs_step_freeze_test.dart
} finally {
    Pop-Location
}

Write-Host ">> 闸门通过"
