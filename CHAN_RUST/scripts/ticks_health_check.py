#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""分笔数据台账与健康检查（全量 A 股）。

读：
  - 每日增量索引 <daily-index-dir>/ticks_daily_*.json（files[code][yyyymmdd] = {file_id, rows, ...}）
  - 股票清单 exports/a_shares_daily/summary.csv（仅用于统计全市场股票数）
写：
  - 台账 JSON（默认写到共享进度目录，App「全市场分笔上传 · 进度」弹窗直接读）

健康检查口径（自校准交易日，不需要节假日表）：
  - 候选日 = 数据首日 ~ 数据末日之间的所有工作日（周一~周五）；
  - 某候选日全市场没有一只股票有数据 → 视为休市/节假日，不算缺口；
  - 某候选日至少有 1 只股票有数据 → 视为交易日，当天缺数据的股票记「空缺日」；
  - 每只股票只从它「首次出现数据的那天」开始查，避免把未上市期误判为缺口；
  - rows == 0 → 空数据；rows < 该股票行数中位数的 10%（且中位数 >= 1000）→ 行数异常。

用法：
  python ticks_health_check.py                 # 默认路径
  python ticks_health_check.py --daily-index-dir DIR --share-dir DIR
"""
from __future__ import annotations

import argparse
import csv
import json
import statistics
import time
from datetime import date, timedelta
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_SUMMARY = REPO / "exports" / "a_shares_daily" / "summary.csv"
DEFAULT_INDEX_DIR = Path(r"G:\chan_month5_data\state\ticks_daily")
DEFAULT_SHARE_DIR = Path(r"D:\chan_ticks_share\live")
RECORD_NAME = "ticks_health_record.json"


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def _weekdays(begin: date, end: date) -> list[str]:
    """[begin, end] 闭区间内的所有工作日（YYYYMMDD）。"""
    out: list[str] = []
    d = begin
    one = timedelta(days=1)
    while d <= end:
        if d.weekday() < 5:
            out.append(d.strftime("%Y%m%d"))
        d += one
    return out


def load_daily_indexes(index_dir: Path) -> dict[str, dict[str, dict]]:
    """合并各月索引：code -> {yyyymmdd -> entry}。"""
    merged: dict[str, dict[str, dict]] = {}
    files = sorted(index_dir.glob("ticks_daily_*.json"))
    for fp in files:
        try:
            obj = json.loads(fp.read_text(encoding="utf-8"))
        except Exception as e:
            log(f"索引损坏跳过 {fp.name}: {e}")
            continue
        for code, days in (obj.get("files") or {}).items():
            if not isinstance(days, dict):
                continue
            dst = merged.setdefault(code, {})
            for tag, entry in days.items():
                if isinstance(entry, dict) and entry.get("file_id"):
                    dst[tag] = entry
    log(f"合并 {len(files)} 个月度索引，覆盖 {len(merged)} 只股票")
    return merged


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--daily-index-dir", default=str(DEFAULT_INDEX_DIR))
    ap.add_argument("--summary", default=str(DEFAULT_SUMMARY))
    ap.add_argument("--share-dir", default=str(DEFAULT_SHARE_DIR))
    ap.add_argument("--out", default="", help="台账输出路径，默认 <share-dir>/ticks_health_record.json")
    ap.add_argument("--top", type=int, default=50, help="各类清单最多保留条数")
    args = ap.parse_args()

    index_dir = Path(args.daily_index_dir)
    if not index_dir.is_dir():
        log(f"找不到每日索引目录：{index_dir}（本机可能不是跑每日更新的机器）")
        return 2

    summary_codes = 0
    sp = Path(args.summary)
    if sp.is_file():
        with sp.open("r", encoding="utf-8", errors="replace") as f:
            summary_codes = sum(1 for _ in csv.reader(f)) - 1

    data = load_daily_indexes(index_dir)
    if not data:
        log("每日索引里没有任何数据，无法生成台账")
        return 2

    all_dates = sorted({tag for days in data.values() for tag in days})
    begin, end = date(*map(int, (all_dates[0][:4], all_dates[0][4:6], all_dates[0][6:]))), \
                 date(*map(int, (all_dates[-1][:4], all_dates[-1][4:6], all_dates[-1][6:])))
    candidates = _weekdays(begin, end)

    # 自校准交易日：当天至少有 1 只股票有数据才算开市
    present_by_day: dict[str, int] = {}
    for days in data.values():
        for tag in days:
            present_by_day[tag] = present_by_day.get(tag, 0) + 1
    trading_days = [d for d in candidates if present_by_day.get(d, 0) > 0]
    holiday_days = len(candidates) - len(trading_days)
    trading_set = set(trading_days)
    log(f"区间 {all_dates[0]}~{all_dates[-1]}：候选工作日 {len(candidates)}，"
        f"交易日 {len(trading_days)}，休市 {holiday_days}")

    # 逐股检查
    missing_pairs = 0
    covered_pairs = 0
    expected_pairs = 0
    missing_by_day: dict[str, int] = {}
    empty_list: list[dict] = []
    low_list: list[dict] = []
    empty_count = 0
    low_count = 0
    for code, days in data.items():
        have = set(days)
        first = min(have)
        expected = [d for d in trading_days if d >= first]
        expected_pairs += len(expected)
        covered_pairs += len(have & trading_set)
        miss = [d for d in expected if d not in have]
        missing_pairs += len(miss)
        for d in miss:
            missing_by_day[d] = missing_by_day.get(d, 0) + 1
        rows_map = {d: int(days[d].get("rows") or 0) for d in have}
        for d, r in rows_map.items():
            if r == 0:
                empty_count += 1
                if len(empty_list) < args.top:
                    empty_list.append({"code": code, "date": d})
        vals = sorted(r for r in rows_map.values() if r > 0)
        if len(vals) >= 5:
            med = statistics.median(vals)
            if med >= 1000:
                for d, r in rows_map.items():
                    if 0 < r < med * 0.1:
                        low_count += 1
                        if len(low_list) < args.top:
                            low_list.append({"code": code, "date": d, "rows": r, "median": int(med)})

    missing_days = sorted(missing_by_day)
    gap_days_top = sorted(
        ({"date": d, "missing": n, "present": present_by_day.get(d, 0)}
         for d, n in missing_by_day.items()),
        key=lambda x: -x["missing"],
    )[:20]
    coverage = (covered_pairs * 100.0 / expected_pairs) if expected_pairs else 100.0

    record = {
        "version": 1,
        "kind": "ticks_health_record",
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "range": {"begin": all_dates[0], "end": all_dates[-1]},
        "stocks_total": summary_codes or len(data),
        "stocks_with_data": len(data),
        "trading_days": len(trading_days),
        "holiday_days": holiday_days,
        "expected_pairs": expected_pairs,
        "covered_pairs": covered_pairs,
        "missing_pairs": missing_pairs,
        "coverage_pct": round(coverage, 2),
        "missing_days": missing_days,
        "gap_days_top": gap_days_top,
        "empty_data_count": empty_count,
        "empty_data_top": empty_list,
        "low_rows_count": low_count,
        "low_rows_top": low_list,
        "notes": [
            "交易日自校准：全市场当天无数据视为休市，不按节假日表。",
            "每只股票只从首次有数据的日子查起，未上市期不算缺口。",
            "行数异常：当天行数 < 该股票中位数的 10%（中位数需 >= 1000）。",
            "全历史年包只按年核对 file_id，未做逐日校验。",
        ],
    }

    out = Path(args.out) if args.out else Path(args.share_dir) / RECORD_NAME
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(record, ensure_ascii=False, indent=1), encoding="utf-8")
    log(f"台账已写入 {out}")
    log(f"覆盖率 {coverage:.2f}%，缺 {missing_pairs} 个（股票×日），涉及 {len(missing_days)} 天；"
        f"空数据 {empty_count} 处，行数异常 {low_count} 处")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
