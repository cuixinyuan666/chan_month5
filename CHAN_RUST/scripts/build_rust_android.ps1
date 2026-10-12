# Cross-compile chan_ffi into Flutter Android jniLibs (arm64 / armv7 / x86_64)
# 对应 Linux：build_rust_android.sh
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$RustDir = Join-Path $Root "rust"
$JniDir = Join-Path $Root "flutter\chan_kline\android\app\src\main\jniLibs"
$LocalProps = Join-Path $Root "flutter\chan_kline\android\local.properties"

function Get-SdkDir {
    if ($env:ANDROID_HOME -and (Test-Path $env:ANDROID_HOME)) { return $env:ANDROID_HOME }
    if ($env:ANDROID_SDK_ROOT -and (Test-Path $env:ANDROID_SDK_ROOT)) { return $env:ANDROID_SDK_ROOT }
    if (Test-Path $LocalProps) {
        $line = Get-Content $LocalProps | Where-Object { $_ -match '^\s*sdk\.dir=' } | Select-Object -First 1
        if ($line) {
            $dir = ($line -replace '^\s*sdk\.dir=', '').Trim() -replace '\\\\', '\'
            if (Test-Path $dir) { return $dir }
        }
    }
    $fallback = "D:\android_sdk"
    if (Test-Path $fallback) { return $fallback }
    throw "Android SDK not found. Set ANDROID_HOME or sdk.dir in android/local.properties."
}

$Sdk = Get-SdkDir
$env:ANDROID_HOME = $Sdk
$env:ANDROID_SDK_ROOT = $Sdk

$PreferredNdk = Join-Path $Sdk (Join-Path "ndk" "28.2.13676358")
if (Test-Path $PreferredNdk) {
    $Ndk = $PreferredNdk
} else {
    $ndkRoot = Join-Path $Sdk "ndk"
    if (-not (Test-Path $ndkRoot)) {
        throw "Android NDK not found under $ndkRoot. Install ndk 28.2.13676358."
    }
    $Ndk = Get-ChildItem $ndkRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}
$env:ANDROID_NDK_HOME = $Ndk
$env:ANDROID_NDK_ROOT = $Ndk

if (-not (Get-Command cargo-ndk -ErrorAction SilentlyContinue)) {
    throw "cargo-ndk missing. Run: cargo install cargo-ndk --locked"
}

Write-Host ">> ANDROID_HOME=$Sdk"
Write-Host ">> ANDROID_NDK_HOME=$Ndk"
Write-Host ">> cargo ndk build -p chan_ffi --release"

Push-Location $RustDir
try {
    cargo ndk `
        -t arm64-v8a `
        -t armeabi-v7a `
        -t x86_64 `
        -o $JniDir `
        build --release -p chan_ffi
    if ($LASTEXITCODE -ne 0) { throw "cargo ndk failed with exit $LASTEXITCODE" }
} finally {
    Pop-Location
}

Write-Host ">> output: $JniDir"
Get-ChildItem -Path $JniDir -Recurse -Filter "libchan_ffi.so" | ForEach-Object { Write-Host $_.FullName }