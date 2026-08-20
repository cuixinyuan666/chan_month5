#!/usr/bin/env bash
# 把 Flutter Linux Release bundle 打成 tar.gz，并带上 a_Data（GitHub Releases 解压即用）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$ROOT")"
FLUTTER_DIR="$ROOT/flutter/chan_kline"
BUNDLE_DIR="$FLUTTER_DIR/build/linux/x64/release/bundle"
OUT_PARENT="$REPO_ROOT/dist"
OUT_DIR="$OUT_PARENT/chan_kline-linux-x64"
TGZ="$OUT_PARENT/chan_kline-linux-x64.tar.gz"
DATA_SRC="$REPO_ROOT/a_Data"
README_SRC="$SCRIPT_DIR/release_readme.txt"

if [ ! -x "$BUNDLE_DIR/chan_kline" ]; then
    echo "未找到发布目录: $BUNDLE_DIR ，请先 flutter build linux --release" >&2
    exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
echo ">> 复制 Flutter Linux bundle"
cp -a "$BUNDLE_DIR"/. "$OUT_DIR"/

if [ ! -f "$OUT_DIR/lib/libchan_ffi.so" ]; then
    echo "发布目录缺少 lib/libchan_ffi.so（Rust 动态库须在 bundle/lib）" >&2
    exit 1
fi

if [ -d "$DATA_SRC" ]; then
    echo ">> 复制 a_Data 到可执行文件同级"
    cp -a "$DATA_SRC" "$OUT_DIR/a_Data"
else
    echo "警告: 未找到 $DATA_SRC ，包内将不含行情数据" >&2
fi

cp -f "$README_SRC" "$OUT_DIR/使用说明.txt"

mkdir -p "$OUT_PARENT"
rm -f "$TGZ"
echo ">> 打包 $TGZ"
tar -C "$OUT_PARENT" -czf "$TGZ" "chan_kline-linux-x64"
echo ">> 完成 $TGZ"
