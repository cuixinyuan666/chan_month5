# -*- coding: utf-8 -*-
"""Init/session load stage timing via perf_counter."""

from __future__ import annotations

import os
import threading
import time
from contextlib import contextmanager
from typing import Any, Callable, Iterator, Optional

_ENV_ENABLE = os.environ.get("INIT_PERF", "1").strip().lower() not in ("0", "false", "no", "off")
_tls = threading.local()
# 可选：init 阶段进入/退出回调（供前端轮询进度与历史记录）
_stage_listener: Optional[Callable[[str, str], None]] = None


def init_perf_enabled() -> bool:
    return _ENV_ENABLE


def set_init_stage_listener(fn: Optional[Callable[[str, str], None]]) -> None:
    """注册 init 阶段监听：fn(event, stage)，event 为 enter|exit。"""
    global _stage_listener
    _stage_listener = fn


def _collector() -> Optional[dict[str, Any]]:
    return getattr(_tls, "collector", None)


@contextmanager
def init_perf_stage(name: str) -> Iterator[None]:
    col = _collector()
    if col is None:
        yield
        return
    t0 = time.perf_counter()
    listener = _stage_listener
    if listener is not None:
        try:
            listener("enter", str(name))
        except Exception:
            pass
    try:
        yield
    finally:
        ms = (time.perf_counter() - t0) * 1000.0
        stages: dict[str, float] = col.setdefault("stages", {})
        stages[str(name)] = round(stages.get(str(name), 0.0) + ms, 3)
        if listener is not None:
            try:
                listener("exit", str(name))
            except Exception:
                pass


@contextmanager
def init_perf_run(label: str = "api_init") -> Iterator[dict[str, Any]]:
    if not init_perf_enabled():
        yield {}
        return
    col: dict[str, Any] = {"label": label, "stages": {}, "started_at": time.perf_counter()}
    prev = getattr(_tls, "collector", None)
    _tls.collector = col
    t0 = float(col["started_at"])
    try:
        yield col
    finally:
        col["total_ms"] = round((time.perf_counter() - t0) * 1000.0, 3)
        _tls.collector = prev


def init_perf_report(extra: Optional[dict[str, Any]] = None) -> dict[str, Any]:
    col = _collector()
    if not col:
        return {}
    stages: dict[str, float] = dict(col.get("stages") or {})
    total = float(col.get("total_ms") or 0.0)
    if total <= 0.0:
        started_at = col.get("started_at")
        if isinstance(started_at, (int, float)):
            # init 结束前也可能生成报告，此时用实时墙钟，避免漏掉未包 stage 的等待。
            total = max(sum(stages.values()), (time.perf_counter() - float(started_at)) * 1000.0)
    total = total or sum(stages.values()) or 1.0
    ranked = sorted(stages.items(), key=lambda x: -x[1])
    out: dict[str, Any] = {
        "label": col.get("label"),
        "total_ms": round(total, 3),
        "stages_ms": stages,
        "rank": [{"stage": k, "ms": v, "pct": round(100.0 * v / total, 1)} for k, v in ranked],
    }
    if extra:
        out.update(extra)
    return out
