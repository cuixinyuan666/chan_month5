#!/usr/bin/env bash
# 编译 chan_ffi 并复制到 Flutter Linux 目录（WSL / 原生 Linux 通用）
# 对应 Windows 版：build_rust.ps1；Linux 下产物为 libchan_ffi.so（而非 .dll）
set -euo pipefail

# 脚本所在目录 -> CHAN_RUST 根目录（scripts 的上一级）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$ROOT/rust"
# Linux 动态库产物名：lib<crate>.so
SO_SRC="$RUST_DIR/target/release/libchan_ffi.so"
# 工程内开发态目录（与 windows/native 对齐，供 Flutter 开发态加载）
SO_DST_DIR="$ROOT/flutter/chan_kline/linux/native"
SO_DST="$SO_DST_DIR/libchan_ffi.so"
# Flutter Linux 运行时 bundle 的 lib 目录（可执行文件旁）
BUNDLE_LIB_DIR="$ROOT/flutter/chan_kline/build/linux/x64/debug/bundle/lib"
BUNDLE_SO_DST="$BUNDLE_LIB_DIR/libchan_ffi.so"

echo ">> cargo build -p chan_ffi --release"
pushd "$RUST_DIR" >/dev/null
cargo build -p chan_ffi --release
popd >/dev/null

if [ ! -f "$SO_SRC" ]; then
    echo "未找到动态库: $SO_SRC" >&2
    exit 1
fi

# 复制到工程内开发态目录
mkdir -p "$SO_DST_DIR"
cp -f "$SO_SRC" "$SO_DST"
echo ">> 已复制到 $SO_DST"

# 若存在 Flutter Linux debug bundle，则一并更新（可执行文件旁的 lib/）
if [ -d "$BUNDLE_LIB_DIR" ]; then
    if cp -f "$SO_SRC" "$BUNDLE_SO_DST" 2>/dev/null; then
        echo ">> 已复制到 $BUNDLE_SO_DST"
    else
        echo "警告: bundle 动态库被占用，请先关闭正在运行的 chan_kline 再重试 build_rust.sh" >&2
    fi
fi
