"""多周期同图：将 overlay 周期图表坐标映射到 driver（最细周期）K 线索引域。"""

from __future__ import annotations

import copy
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
    """粗周期第 idx 根 K：时间区间为 [t_i, t_next)；末根无上界时用 +1 日近似。"""
    if not coarse_kline or idx < 0 or idx >= len(coarse_kline):
        return (float("nan"), float("nan"))
    t0 = _parse_chart_time_ms(str(coarse_kline[idx].get("t", "")))
    if idx + 1 < len(coarse_kline):
        t1 = _parse_chart_time_ms(str(coarse_kline[idx + 1].get("t", "")))
    else:
        t1 = t0 + 86400000.0 * 400.0  # 末根：宽右界以包含全部 driver bar
    if not (t1 == t1) or t1 <= t0:  # noqa: PLR0124
        t1 = t0 + 86400000.0 * 400.0
    return (t0, t1)


def _driver_x_span_for_time_window(driver_kline: list[dict[str, Any]], t_lo_ms: float, t_hi_ms: float) -> tuple[float, float]:
    """driver K 线中时间落在 [t_lo, t_hi) 的 bar x 最小/最大。"""
    xs: list[float] = []
    for k in driver_kline or []:
        try:
            x = float(k.get("x", 0))
        except (TypeError, ValueError):
            continue
        tm = _parse_chart_time_ms(str(k.get("t", "")))
        if not (tm == tm):  # noqa: PLR0124
            continue
        if tm >= t_lo_ms and tm < t_hi_ms:
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
        "kline_combine",
        "indicators",
        "trend_lines",
    )
    for key in keys:
        if key not in root:
            continue
        root[key] = _walk_remap(root.get(key), coarse_kline, driver_kline)
    return root
