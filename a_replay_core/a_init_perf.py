# -*- coding: utf-8 -*-
"""Init/session load stage timing via perf_counter."""

from __future__ import annotations

import os
import threading
import time
from contextlib import contextmanager
from typing import Any, Iterator, Optional

_ENV_ENABLE = os.environ.get("INIT_PERF", "1").strip().lower() not in ("0", "false", "no", "off")
_tls = threading.local()


def init_perf_enabled() -> bool:
    return _ENV_ENABLE


def _collector() -> Optional[dict[str, Any]]:
    return getattr(_tls, "collector", None)


@contextmanager
def init_perf_stage(name: str) -> Iterator[None]:
    col = _collector()
    if col is None:
        yield
        return
    t0 = time.perf_counter()
    try:
        yield
    finally:
        ms = (time.perf_counter() - t0) * 1000.0
        stages: dict[str, float] = col.setdefault("stages", {})
        stages[str(name)] = round(stages.get(str(name), 0.0) + ms, 3)


@contextmanager
def init_perf_run(label: str = "api_init") -> Iterator[dict[str, Any]]:
    if not init_perf_enabled():
        yield {}
        return
    col: dict[str, Any] = {"label": label, "stages": {}}
    prev = getattr(_tls, "collector", None)
    _tls.collector = col
    t0 = time.perf_counter()
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
    total = float(col.get("total_ms") or 0.0) or sum(stages.values()) or 1.0
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
