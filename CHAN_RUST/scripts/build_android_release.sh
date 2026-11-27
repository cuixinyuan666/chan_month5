#!/usr/bin/env bash
# Android 发布包一键构建：种子数据 + Rust jniLibs + Release APK
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
APP_DIR="$ROOT/flutter/chan_kline"

bash "$SCRIPT_DIR/prepare_android_a_data_seed.sh"
bash "$SCRIPT_DIR/build_rust_android.sh"

pushd "$APP_DIR" >/dev/null
flutter pub get
flutter build apk --release
popd >/dev/null

echo ">> APK: $APP_DIR/build/app/outputs/flutter-apk/app-release.apk"
