#!/usr/bin/env bash
# 打包 Android 内置 a_Data 种子（002003 2025Q1 + test），供 APK assets 解压
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
REPO_A_DATA="$(cd "$ROOT/../a_Data" && pwd)"
OUT_ZIP="$ROOT/flutter/chan_kline/assets/a_data_seed.zip"
WORK="$(mktemp -d)"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

SEED_ROOT="$WORK/a_Data"
mkdir -p "$SEED_ROOT/002003" "$SEED_ROOT/test"

echo ">> 复制 002003 2025Q1 分笔"
shopt -s nullglob
for f in "$REPO_A_DATA/002003"/202501*.txt "$REPO_A_DATA/002003"/202502*.txt "$REPO_A_DATA/002003"/202503*.txt; do
  cp "$f" "$SEED_ROOT/002003/"
done
shopt -u nullglob

count_002003=$(find "$SEED_ROOT/002003" -type f | wc -l)
if [ "$count_002003" -lt 1 ]; then
  echo "未找到 002003 2025Q1 分笔，请检查 $REPO_A_DATA/002003" >&2
  exit 1
fi

echo ">> 复制 test（custom.ohlc.csv + demos）"
if [ -d "$REPO_A_DATA/test" ]; then
  cp -a "$REPO_A_DATA/test/." "$SEED_ROOT/test/"
fi

mkdir -p "$(dirname "$OUT_ZIP")"
rm -f "$OUT_ZIP"
(
  cd "$WORK"
  zip -qr "$OUT_ZIP" a_Data
)

echo ">> 已生成 $OUT_ZIP ($(du -h "$OUT_ZIP" | awk '{print $1}'))，002003 文件数=$count_002003"
