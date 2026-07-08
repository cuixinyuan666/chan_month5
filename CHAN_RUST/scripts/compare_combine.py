#!/usr/bin/env python3
"""Rust K 线包含合并 vs 旧版 CKLine_List 逐前缀比对。

通过子进程调用 chan_compare（避免 Windows ctypes 调 cdylib 崩溃）。
用法（在 chan.py 根目录）:
  python CHAN_RUST/scripts/compare_combine.py
  python CHAN_RUST/scripts/compare_combine.py --sample-every 50
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ChanConfig import CChanConfig
from Common.CEnum import DATA_FIELD, FX_TYPE, KL_TYPE
from Common.CTime import CTime
from KLine.KLine_List import CKLine_List
from KLine.KLine_Unit import CKLine_Unit

PERIOD_TO_KL = {
    "1m": KL_TYPE.K_1M,
    "5m": KL_TYPE.K_5M,
    "15m": KL_TYPE.K_15M,
    "60m": KL_TYPE.K_60M,
    "day": KL_TYPE.K_DAY,
    "week": KL_TYPE.K_WEEK,
    "month": KL_TYPE.K_MON,
}


def _bin_path() -> Path:
    candidates = [
        ROOT / "CHAN_RUST" / "rust" / "target" / "release" / "chan_compare.exe",
        ROOT / "CHAN_RUST" / "rust" / "target" / "debug" / "chan_compare.exe",
    ]
    for p in candidates:
        if p.is_file():
            return p
    raise FileNotFoundError(
        "未找到 chan_compare，请先: cargo build -p chan_ffi --release --bin chan_compare"
    )


def _parse_ctime(text: str) -> CTime:
    text = text.strip()
    if " " in text:
        d, tm = text.split(" ", 1)
        y, mo, dd = [int(x) for x in d.replace("-", "/").split("/")]
        hh, mm = [int(x) for x in tm.split(":")[:2]]
        return CTime(y, mo, dd, hh, mm, auto=False)
    y, mo, dd = [int(x) for x in text.replace("-", "/").split("/")]
    return CTime(y, mo, dd, 0, 0, auto=False)


def _rust_load(bin_p: Path, code: str, begin: str, end: str, period: str) -> list[dict[str, Any]]:
    r = subprocess.run(
        [str(bin_p), "load", code, begin, end, period],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "Rust load 失败")
    return json.loads(r.stdout)


def _rust_combine(bin_p: Path, bars: list[dict[str, Any]]) -> Any:
    r = subprocess.run(
        [str(bin_p), "combine"],
        input=json.dumps(bars),
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "Rust combine 失败")
    return json.loads(r.stdout)


def _rust_combine_frames(bin_p: Path, bars: list[dict[str, Any]]) -> list[dict[str, Any]]:
    raw = _rust_combine(bin_p, bars)
    if isinstance(raw, dict):
        return raw.get("frames") or []
    return raw


def _py_combine(bars: list[dict[str, Any]], kl_type: KL_TYPE) -> list[dict[str, Any]]:
    kl_list = CKLine_List(kl_type, CChanConfig())
    for i, b in enumerate(bars):
        klu = CKLine_Unit(
            {
                DATA_FIELD.FIELD_TIME: _parse_ctime(str(b["time_text"])),
                DATA_FIELD.FIELD_OPEN: float(b["open"]),
                DATA_FIELD.FIELD_HIGH: float(b["high"]),
                DATA_FIELD.FIELD_LOW: float(b["low"]),
                DATA_FIELD.FIELD_CLOSE: float(b["close"]),
                DATA_FIELD.FIELD_VOLUME: float(b["volume"]),
                DATA_FIELD.FIELD_TURNOVER: float(b["amount"]),
            }
        )
        klu.set_idx(int(b.get("idx", i)))
        kl_list.add_single_klu(klu)

    out: list[dict[str, Any]] = []
    for klc in kl_list.lst:
        if not klc.lst:
            continue
        fx = klc.fx.name if isinstance(klc.fx, FX_TYPE) else str(klc.fx)
        out.append(
            {
                "x1": int(klc.lst[0].idx),
                "x2": int(klc.lst[-1].idx),
                "high": float(klc.high),
                "low": float(klc.low),
                "fx": fx,
                "count": len(klc.lst),
            }
        )
    return out


def _norm_fx(fx: str) -> str:
    s = str(fx).upper()
    if "TOP" in s:
        return "TOP"
    if "BOTTOM" in s:
        return "BOTTOM"
    return "UNKNOWN"


def _norm_frames(frames: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "x1": int(f["x1"]),
            "x2": int(f["x2"]),
            "high": round(float(f["high"]), 10),
            "low": round(float(f["low"]), 10),
            "fx": _norm_fx(f.get("fx", "UNKNOWN")),
            "count": int(f.get("count", 1)),
        }
        for f in frames
    ]


def main() -> int:
    ap = argparse.ArgumentParser(description="Rust vs 旧版 K 线包含合并比对")
    ap.add_argument("--code", default="002003")
    ap.add_argument("--begin", default="2004/06/25")
    ap.add_argument("--end", default="2004/07/29")
    ap.add_argument("--period", default="1m")
    ap.add_argument("--sample-every", type=int, default=1)
    args = ap.parse_args()

    bin_p = _bin_path()
    kl_type = PERIOD_TO_KL.get(args.period.lower(), KL_TYPE.K_1M)
    bars = _rust_load(bin_p, args.code, args.begin, args.end, args.period)
    if not bars:
        print("无 K 线数据")
        return 1

    mismatches = 0
    checked = 0
    first_err: str | None = None
    step = max(1, args.sample_every)

    for n in range(1, len(bars) + 1, step):
        prefix = bars[:n]
        py_f = _norm_frames(_py_combine(prefix, kl_type))
        rs_f = _norm_frames(_rust_combine_frames(bin_p, prefix))
        checked += 1
        if py_f != rs_f:
            mismatches += 1
            if first_err is None:
                first_err = f"前缀 n={n}: py={py_f!r} rust={rs_f!r}"

    print(f"股票 {args.code}  周期 {args.period}  共 {len(bars)} 根 K")
    print(f"前缀比对 {checked} 次，不一致 {mismatches} 次")
    if mismatches:
        print(f"首个差异: {first_err}")
        return 1
    print("全部一致")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
