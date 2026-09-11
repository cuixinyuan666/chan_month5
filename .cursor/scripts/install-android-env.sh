#!/usr/bin/env bash
# CHAN_RUST Android 开发环境安装（幂等，Cloud Agent install 入口）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
ANDROID_SDK_ROOT="$ANDROID_HOME"
CMDLINE_TOOLS_ZIP_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
# 与 Flutter 3.47 默认 ndkVersion 对齐（FlutterExtension.kt）
ANDROID_NDK_PKG="ndk;28.2.13676358"
ANDROID_PLATFORM_PKG="platforms;android-36"
ANDROID_BUILD_TOOLS_PKG="build-tools;36.0.0"

export ANDROID_HOME ANDROID_SDK_ROOT
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

echo ">> [android-env] ANDROID_HOME=$ANDROID_HOME"

# 基础依赖：解压 cmdline-tools、接受 sdkmanager 许可
if ! command -v unzip >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends unzip
fi

mkdir -p "$ANDROID_HOME/cmdline-tools"
if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  echo ">> [android-env] 安装 Android cmdline-tools"
  tmp_dir="$(mktemp -d)"
  curl -fsSL -o "$tmp_dir/cmdline-tools.zip" "$CMDLINE_TOOLS_ZIP_URL"
  unzip -qo "$tmp_dir/cmdline-tools.zip" -d "$tmp_dir"
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mv "$tmp_dir/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
  rm -rf "$tmp_dir"
fi

echo ">> [android-env] sdkmanager 安装 platform-tools / SDK / NDK"
yes | sdkmanager --sdk_root="$ANDROID_HOME" \
  "platform-tools" \
  "$ANDROID_PLATFORM_PKG" \
  "$ANDROID_BUILD_TOOLS_PKG" \
  "$ANDROID_NDK_PKG"

# 写入 shell 配置，便于交互式终端复用
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  if [ -f "$rc" ] && ! grep -q 'CHAN_RUST Android SDK' "$rc" 2>/dev/null; then
    cat >>"$rc" <<EOF

# CHAN_RUST Android SDK
export ANDROID_HOME="$ANDROID_HOME"
export ANDROID_SDK_ROOT="\$ANDROID_HOME"
export PATH="\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$PATH"
EOF
  fi
done

if command -v flutter >/dev/null 2>&1; then
  flutter config --android-sdk "$ANDROID_HOME"
  yes | flutter doctor --android-licenses >/dev/null 2>&1 || true
fi

if command -v rustup >/dev/null 2>&1; then
  rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
fi

if command -v cargo >/dev/null 2>&1 && ! command -v cargo-ndk >/dev/null 2>&1; then
  cargo install cargo-ndk --locked
fi

if [ -d "$REPO_ROOT/CHAN_RUST/rust" ]; then
  echo ">> [android-env] cargo fetch (chan_ffi)"
  (cd "$REPO_ROOT/CHAN_RUST/rust" && cargo fetch -p chan_ffi)
fi

if [ -d "$REPO_ROOT/CHAN_RUST/flutter/chan_kline" ]; then
  echo ">> [android-env] flutter pub get"
  (cd "$REPO_ROOT/CHAN_RUST/flutter/chan_kline" && flutter pub get)
fi

if [ -x "$REPO_ROOT/CHAN_RUST/scripts/build_rust_android.sh" ]; then
  echo ">> [android-env] 预编译 Android libchan_ffi.so"
  bash "$REPO_ROOT/CHAN_RUST/scripts/build_rust_android.sh"
fi

if [ -x "$REPO_ROOT/CHAN_RUST/scripts/prepare_android_a_data_seed.sh" ]; then
  echo ">> [android-env] 打包 Android a_Data 种子"
  bash "$REPO_ROOT/CHAN_RUST/scripts/prepare_android_a_data_seed.sh"
fi

echo ">> [android-env] 完成"
