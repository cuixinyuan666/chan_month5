"""?????? txt???? B/S ??????????????/????????????"""
from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Any

from Common.CTime import CTime
from Common.func_util import str2float


@dataclass
class OfflineTickRow:
    """????????price_lo/hi ????????? K ??????????"""

    t: CTime
    price: float
    vol: float
    side: str  # B/S???? BS ?????????
    has_bs: bool
    price_lo: float | None = None
    price_hi: float | None = None

    def lo(self) -> float:
        return float(self.price_lo if self.price_lo is not None else self.price)

    def hi(self) -> float:
        return float(self.price_hi if self.price_hi is not None else self.price)


def normalize_offline_data_custom(raw: Any) -> str:
    """native=原生；merge_no_bs=合并头尾无 BS 分笔。"""
    m = str(raw or "native").strip().lower()
    compact = re.sub(r"\s+", "", m)
    if compact in (
        "merge_no_bs",
        "merge",
        "no_bs",
        "无bs",
        "无b/s",
        "无bs向上或者向下合并",
        "无bs向上或向下合并",
    ) or ("无bs" in compact and "合并" in compact):
        return "merge_no_bs"
    return "native"


def _parse_line_has_bs(parts: list[str]) -> tuple[str, bool]:
    side = ""
    for tok in parts[3:]:
        s = str(tok).strip().upper()
        if s in ("B", "S"):
            return s, True
    return "", False


def parse_offline_tick_line(line: str, y: int, mo: int, d0: int) -> OfflineTickRow | None:
    line = line.strip()
    if not line:
        return None
    parts = re.split(r"\s+", line)
    if len(parts) < 3:
        return None
    if parts[0] in ("???", "---") or parts[0].startswith("???"):
        return None
    if not re.match(r"^\d{1,2}:\d{2}$", parts[0]):
        return None
    a, b = parts[0].split(":", 1)
    hh, mm = int(a), int(b)
    price = str2float(parts[1])
    vol = str2float(parts[2])
    side, has_bs = _parse_line_has_bs(parts)
    return OfflineTickRow(CTime(y, mo, d0, hh, mm, auto=False), price, vol, side, has_bs)


def _merge_vol_price_into(target: OfflineTickRow, src: OfflineTickRow) -> None:
    """?????????????????????????????"""
    target.vol += src.vol
    t_lo, t_hi = target.lo(), target.hi()
    s_lo, s_hi = src.lo(), src.hi()
    new_lo = min(t_lo, s_lo)
    new_hi = max(t_hi, s_hi)
    if new_lo < t_lo or new_hi > t_hi:
        target.price_lo = new_lo
        target.price_hi = new_hi


def merge_no_bs_offline_ticks(rows: list[OfflineTickRow]) -> list[OfflineTickRow]:
    """
    按交易日处理无 B/S 分笔：
    - 当天开盘侧连续无 B/S，向下合并到当天下一根有 B/S 的分笔。
    - 当天收盘侧连续无 B/S，向上合并到当天上一根有 B/S 的分笔。
    - 当天中间仍无 B/S 的行，保留并按 B 处理。
    """
    if not rows:
        return []
    sorted_rows = sorted(rows, key=lambda x: x.t.ts)
    out: list[OfflineTickRow] = []
    day_rows: list[OfflineTickRow] = []
    cur_day: tuple[int, int, int] | None = None

    def flush_day(src: list[OfflineTickRow]) -> None:
        if not src:
            return
        day = [OfflineTickRow(r.t, r.price, r.vol, r.side, r.has_bs, r.price_lo, r.price_hi) for r in src]
        n = len(day)
        i = 0
        while i < n and not day[i].has_bs:
            i += 1
        if i > 0 and i < n:
            target = day[i]
            for j0 in range(i):
                _merge_vol_price_into(target, day[j0])
            day = day[i:]
            n = len(day)
        elif i >= n:
            # 全日都无 B/S 时无法判断方向，丢弃这一天的无效分笔。
            return

        j = n - 1
        while j >= 0 and not day[j].has_bs:
            j -= 1
        if j >= 0 and j < n - 1:
            target = day[j]
            for k0 in range(j + 1, n):
                _merge_vol_price_into(target, day[k0])
            day = day[: j + 1]

        for r0 in day:
            if not r0.has_bs:
                r0.side = "B"
                r0.has_bs = True
        out.extend(day)

    for row in sorted_rows:
        day_key = (row.t.year, row.t.month, row.t.day)
        if cur_day is None:
            cur_day = day_key
        if day_key != cur_day:
            flush_day(day_rows)
            day_rows = []
            cur_day = day_key
        day_rows.append(row)
    flush_day(day_rows)
    out.sort(key=lambda x: x.t.ts)
    return out


def rows_to_legacy_ticks(rows: list[OfflineTickRow], *, native_default_side: bool = True) -> list[tuple[CTime, float, float, str]]:
    """?? (t, price, vol, side) ?????native ????? BS ??????? B??"""
    ticks: list[tuple[CTime, float, float, str]] = []
    for r in rows:
        side = r.side if r.side in ("B", "S") else ("B" if native_default_side else "B")
        if not r.has_bs and native_default_side:
            side = "B"
        elif not r.side:
            side = "B"
        ticks.append((r.t, r.price, r.vol, side))
    ticks.sort(key=lambda x: x[0].ts)
    return ticks


def tick_price_range(t: CTime, price: float, vol: float, side: str) -> tuple[float, float]:
    """?? 1 ??????????? (lo, hi)??"""
    return float(price), float(price)


def tick_row_price_range(row: OfflineTickRow) -> tuple[float, float]:
    return row.lo(), row.hi()
