#!/usr/bin/env bash
# 打包 Android 内置 a_Data 种子（test 演示 + 股票代码目录；不含导出分笔 txt）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
REPO_A_DATA="$(cd "$ROOT/../a_Data" && pwd)"
OUT_ZIP="$ROOT/flutter/chan_kline/assets/a_data_seed.zip"
WORK="$(mktemp -d)"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

SEED_ROOT="$WORK/a_Data"
mkdir -p "$SEED_ROOT"

echo ">> 复制 a_Data 到种子包（排除协议缓存与 ml_exports）"
cp -a "$REPO_A_DATA/." "$SEED_ROOT/"
rm -rf "$SEED_ROOT/.tdx_protocol_cache" "$SEED_ROOT/ml_exports"

file_count=$(find "$SEED_ROOT" -type f | wc -l)
if [ "$file_count" -lt 1 ]; then
  echo "a_Data 为空，请检查 $REPO_A_DATA" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_ZIP")"
rm -f "$OUT_ZIP"
(
  cd "$WORK"
  zip -qr "$OUT_ZIP" a_Data
)

echo ">> 已生成 $OUT_ZIP ($(du -h "$OUT_ZIP" | awk '{print $1}'))，文件数=$file_count"
