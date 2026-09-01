#!/usr/bin/env bash
# 交叉编译 chan_ffi 并复制到 Flutter Android jniLibs（arm64 / armv7 / x86_64）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$ROOT/rust"
JNI_DIR="$ROOT/flutter/chan_kline/android/app/src/main/jniLibs"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_HOME
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"

if ! command -v cargo-ndk >/dev/null 2>&1; then
  echo "缺少 cargo-ndk，请先运行: bash .cursor/scripts/install-android-env.sh" >&2
  exit 1
fi

if [ ! -d "$ANDROID_HOME/ndk" ]; then
  echo "未找到 Android NDK，请先运行: bash .cursor/scripts/install-android-env.sh" >&2
  exit 1
fi

echo ">> cargo ndk build -p chan_ffi --release"
pushd "$RUST_DIR" >/dev/null
cargo ndk \
  -t arm64-v8a \
  -t armeabi-v7a \
  -t x86_64 \
  -o "$JNI_DIR" \
  build --release -p chan_ffi
popd >/dev/null

echo ">> 已输出到 $JNI_DIR"
find "$JNI_DIR" -name 'libchan_ffi.so' -print
