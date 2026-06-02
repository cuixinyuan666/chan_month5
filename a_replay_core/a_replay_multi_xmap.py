"""多周期同图：将 overlay 周期图表坐标映射到 driver（最细周期）K 线索引域。"""

from __future__ import annotations

import copy
import math
from datetime import datetime
from typing import Any, Optional


def _parse_chart_time_ms(text: str) -> float:
    """与复盘 K 线 t 字段常见格式一致。"""
    s = str(text or "").strip()
    if not s:
        return float("nan")
    for fmt in ("%Y/%m/%d %H:%M:%S", "%Y/%m/%d %H:%M", "%Y/%m/%d"):
        try:
            return float(datetime.strptime(s, fmt).timestamp() * 1000.0)
        except Exception:
            continue
    s2 = s.replace("/", "-")
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return float(datetime.strptime(s2[:19], fmt).timestamp() * 1000.0)
        except Exception:
            continue
    return float("nan")


def _coarse_bar_time_span_ms(coarse_kline: list[dict[str, Any]], idx: int) -> tuple[float, float]:
    """粗周期第 idx 根：合成 K 的 t 为桶内最后一根子 K 时刻，driver 匹配 (t_{idx-1}, t_idx]（左开右闭）。"""
    if not coarse_kline or idx < 0 or idx >= len(coarse_kline):
        return (float("nan"), float("nan"))
    t_hi = _parse_chart_time_ms(str(coarse_kline[idx].get("t", "")))
    if not (t_hi == t_hi):  # noqa: PLR0124
        return (float("nan"), float("nan"))
    if idx > 0:
        t_lo = _parse_chart_time_ms(str(coarse_kline[idx - 1].get("t", "")))
        if not (t_lo == t_lo):  # noqa: PLR0124
            t_lo = float("-inf")
        elif t_lo >= t_hi:
            t_lo = float("-inf")
    else:
        t_lo = float("-inf")
    return (t_lo, t_hi)


def _driver_x_span_closed_time_inclusive(
    driver_kline: list[dict[str, Any]], t_lo_ms: float, t_hi_ms: float
) -> Optional[tuple[float, float]]:
    """driver 在闭区间 [t_lo, t_hi]（毫秒，含端点）内的 x 最小/最大；与叠层蜡烛按时间取 span 一致。无命中返回 None。"""
    if not (t_lo_ms == t_lo_ms) or not (t_hi_ms == t_hi_ms):  # noqa: PLR0124
        return None
    if t_lo_ms > t_hi_ms:
        t_lo_ms, t_hi_ms = t_hi_ms, t_lo_ms
    xs: list[float] = []
    for k in driver_kline or []:
        try:
            x = float(k.get("x", 0))
        except (TypeError, ValueError):
            continue
        tm = _parse_chart_time_ms(str(k.get("t", "")))
        if not (tm == tm):  # noqa: PLR0124
            continue
        if tm >= t_lo_ms and tm <= t_hi_ms:
            xs.append(x)
    if not xs:
        return None
    return (min(xs), max(xs))


def _driver_x_span_for_time_window(driver_kline: list[dict[str, Any]], t_lo_ms: float, t_hi_ms: float) -> tuple[float, float]:
    """driver K 线：时间在 (t_lo, t_hi]（t_lo=-inf 时退化为 <= t_hi）的 bar x 最小/最大。"""
    xs: list[float] = []
    lo_open = math.isinf(t_lo_ms) and t_lo_ms < 0
    for k in driver_kline or []:
        try:
            x = float(k.get("x", 0))
        except (TypeError, ValueError):
            continue
        tm = _parse_chart_time_ms(str(k.get("t", "")))
        if not (tm == tm):  # noqa: PLR0124
            continue
        if lo_open:
            in_win = tm <= t_hi_ms
        else:
            in_win = tm > t_lo_ms and tm <= t_hi_ms
        if in_win:
            xs.append(x)
    if not xs:
        return (0.0, 0.0)
    return (min(xs), max(xs))


def _map_coarse_x_to_driver(coarse_x: float, coarse_kline: list[dict[str, Any]], driver_kline: list[dict[str, Any]]) -> float:
    """粗周期 bar 索引（可小数）→ driver 横轴浮点。"""
    if not coarse_kline or not driver_kline:
        return float(coarse_x)
    n = len(coarse_kline)
    lo = max(0, min(n - 1, int(coarse_x // 1)))
    hi = max(0, min(n - 1, lo + 1))
    frac = float(coarse_x) - float(lo)
    t_lo0, t_hi0 = _coarse_bar_time_span_ms(coarse_kline, lo)
    x0a, x0b = _driver_x_span_for_time_window(driver_kline, t_lo0, t_hi0)
    c0 = (x0a + x0b) * 0.5
    if hi != lo:
        t_lo1, t_hi1 = _coarse_bar_time_span_ms(coarse_kline, hi)
        x1a, x1b = _driver_x_span_for_time_window(driver_kline, t_lo1, t_hi1)
        c1 = (x1a + x1b) * 0.5
        return c0 + frac * (c1 - c0)
    return c0


def _remap_x_value(v: Any, coarse_kline: list[dict[str, Any]], driver_kline: list[dict[str, Any]]) -> Any:
    if isinstance(v, bool) or v is None:
        return v
    try:
        xf = float(v)
    except (TypeError, ValueError):
        return v
    if not (xf == xf):  # noqa: PLR0124
        return v
    return _map_coarse_x_to_driver(xf, coarse_kline, driver_kline)


def _walk_remap(obj: Any, coarse_kline: list[dict[str, Any]], driver_kline: list[dict[str, Any]]) -> Any:
    if isinstance(obj, dict):
        out = {}
        for k, val in obj.items():
            if k in ("x", "x1", "x2"):
                out[k] = _remap_x_value(val, coarse_kline, driver_kline)
            else:
                out[k] = _walk_remap(val, coarse_kline, driver_kline)
        return out
    if isinstance(obj, list):
        return [_walk_remap(it, coarse_kline, driver_kline) for it in obj]
    return obj


def _remap_kline_combine_list(
    frames: list[dict[str, Any]],
    coarse_kline: list[dict[str, Any]],
    driver_kline: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """叠层合并框：用 t1/t2 在 driver 上取闭区间 x 跨度，与叠层蜡烛按时间 span 一致；无 t1/t2 时回退中心插值。"""
    out: list[dict[str, Any]] = []
    for fr in frames:
        if not isinstance(fr, dict):
            continue
        row = dict(fr)
        t1 = str(row.get("t1") or "").strip()
        t2 = str(row.get("t2") or "").strip()
        if t1 and t2 and driver_kline:
            a = _parse_chart_time_ms(t1)
            b = _parse_chart_time_ms(t2)
            if a == a and b == b:  # noqa: PLR0124
                sp = _driver_x_span_closed_time_inclusive(driver_kline, a, b)
                if sp is not None:
                    x_lo, x_hi = sp[0], sp[1]
                    row["x1"], row["x2"] = (int(x_lo) if x_lo == int(x_lo) else x_lo), (int(x_hi) if x_hi == int(x_hi) else x_hi)
                    out.append(row)
                    continue
        out.append(_walk_remap(fr, coarse_kline, driver_kline))
    return out


def remap_overlay_chart_to_driver_x(chart: dict[str, Any], *, coarse_kline: list[dict[str, Any]], driver_kline: list[dict[str, Any]]) -> dict[str, Any]:
    """深拷贝 chart 并将 x/x1/x2 从 overlay 周期索引域映射到 driver 域。"""
    root = copy.deepcopy(chart)
    keys = (
        "kline",
        "fract",
        "bi",
        "seg",
        "segseg",
        "fract_zs",
        "bi_zs",
        "seg_zs",
        "segseg_zs",
        "bsp",
        "bsp_bi",
        "bsp_seg",
        "bsp_segseg",
        "fx_lines",
        "rhythm_lines",
        "rhythm_hits",
        "indicators",
        "trend_lines",
    )
    for key in keys:
        if key not in root:
            continue
        root[key] = _walk_remap(root.get(key), coarse_kline, driver_kline)
    for group_key in ("extra_levels", "extra_zs", "extra_bsp"):
        group = root.get(group_key)
        if isinstance(group, dict):
            root[group_key] = {k: _walk_remap(v, coarse_kline, driver_kline) for k, v in group.items()}
    kc = root.get("kline_combine")
    if isinstance(kc, list):
        root["kline_combine"] = _remap_kline_combine_list(kc, coarse_kline, driver_kline)
    return root
