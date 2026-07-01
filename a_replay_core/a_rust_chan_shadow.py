# -*- coding: utf-8 -*-
"""Rust Chan shadow / primary helpers."""

from __future__ import annotations

import hashlib
import os
import uuid
from typing import Any, Optional

from a_replay_core.a_perf_engine import APP_PERF_ENGINE
from a_replay_core.a_rust_chan_parity import compare_structure_with_rust, structure_step_hash


def rust_chan_shadow_enabled() -> bool:
    return str(os.environ.get("RUST_CHAN_SHADOW", "")).strip().lower() in {"1", "true", "yes", "on"}


def rust_chan_primary_enabled() -> bool:
    return str(os.environ.get("RUST_CHAN_PRIMARY", "")).strip().lower() in {"1", "true", "yes", "on"}


def rust_trace_prefix(status: str) -> str:
    return f"rust<{status}>"


def rust_chan_mode_text() -> str:
    shadow = rust_chan_shadow_enabled()
    primary = rust_chan_primary_enabled()
    if primary:
        return "\u0070\u0072\u0069\u006d\u0061\u0072\u0079=\u5f00\uff08\u4e00\u6b21\u6027\u5448\u73b0\u8df3\u8fc7\u0050\u0079\u0074\u0068\u006f\u006e\u9012\u63a8\uff0c\u672b\u6839\u0062\u0075\u006c\u006b\u56de\u704c\uff09"
    if shadow:
        return "\u0073\u0068\u0061\u0064\u006f\u0077=\u5f00\uff08\u0050\u0079\u0074\u0068\u006f\u006e\u9012\u63a8\u540e\u0052\u0075\u0073\u0074\u65c1\u8def\u6bd4\u5bf9\uff09"
    return "\u0073\u0068\u0061\u0064\u006f\u0077=\u5173\uff1b\u0070\u0072\u0069\u006d\u0061\u0072\u0079=\u5173\uff08\u4ec5\u6027\u80fd\u5f15\u64ce\u002b\u0042\u0053\u0050\u589e\u91cf\uff09"


def rust_session_env_trace_lines() -> list[str]:
    avail = bool(getattr(APP_PERF_ENGINE, "rust_available", False))
    mode = str(getattr(APP_PERF_ENGINE, "requested_mode", "rust_auto") or "rust_auto")
    lines = [
        f"{rust_trace_prefix('\u8bf4\u660e')}\uff1a\u0052\u0075\u0073\u0074\u4ecb\u5165\u603b\u89c8\u2014\u2014\u6027\u80fd\u5f15\u64ce({mode})={'\u53ef\u7528' if avail else '\u4e0d\u53ef\u7528'}\uff1b{rust_chan_mode_text()}",
    ]
    if avail:
        lines.append(
            f"{rust_trace_prefix('\u8bf4\u660e')}\uff1a\u8282\u70b9\u0041 \u6027\u80fd\u5f15\u64ce load_session=\u5217\u5f0f\u5316\u004b\u7ebf/\u7b79\u7801+\u4f1a\u8bdd\u6307\u7eb9\uff08\u0069\u006e\u0069\u0074 \u9636\u6bb5 38%\uff09"
        )
        lines.append(
            f"{rust_trace_prefix('\u8bf4\u660e')}\uff1a\u8282\u70b9\u0042 \u6b65\u8fdb\u0041\u0050\u0049 next_step_delta/chip_profile=\u6309\u6b65\u5207\u7247\uff08\u666e\u901a\u6b65\u8fdb/\u7b79\u7801\u7528\uff09"
        )
        lines.append(
            f"{rust_trace_prefix('\u8bf4\u660e')}\uff1a\u8282\u70b9\u0043 \u4e00\u6b21\u6027\u5448\u73b0 \u0042\u0053\u0050\u589e\u91cf=bsp_delta_collect \u53bb\u91cd\u8d26\u672c\uff08\u975e\u7f20\u8bba\u9012\u63a8\uff09"
        )
        if rust_chan_shadow_enabled() or rust_chan_primary_enabled():
            mode_d = "\u4e3b\u9012\u63a8" if rust_chan_primary_enabled() else "shadow\u53cc\u8dd1"
            lines.append(
                f"{rust_trace_prefix('\u8bf4\u660e')}\uff1a\u8282\u70b9\u0044 \u0043\u0068\u0061\u006e\u72b6\u6001\u673a \u0050\u004f\u0043=feed_bar+\u7ed3\u6784\u7b7e\u540d\uff08{mode_d}\uff09"
            )
        else:
            lines.append(
                f"{rust_trace_prefix('\u8bf4\u660e')}\uff1a\u8282\u70b9\u0044 \u0043\u0068\u0061\u006e\u72b6\u6001\u673a \u0050\u004f\u0043=\u672a\u542f\u7528\uff08\u8bbe \u0052\u0055\u0053\u0054\u005f\u0043\u0048\u0041\u004e\u005f\u0053\u0048\u0041\u0044\u004f\u0057=1 \u6216 \u0052\u0055\u0053\u0054\u005f\u0043\u0048\u0041\u004e\u005f\u0050\u0052\u0049\u004d\u0041\u0052\u0059=1\uff09"
            )
    else:
        lines.append(f"{rust_trace_prefix('\u8bf4\u660e')}\uff1a\u0052\u0075\u0073\u0074\u6269\u5c55\u672a\u52a0\u8f7d\uff0c\u5168\u90e8\u56de\u9000 \u0050\u0079\u0074\u0068\u006f\u006e")
    return lines


def rust_perf_engine_loaded_lines(*, engine_mode: str, bar_count: int, chip_bar_count: int) -> list[str]:
    return [
        f"{rust_trace_prefix('\u6210\u529f')}\uff1a\u8282\u70b9\u0041 \u6027\u80fd\u5f15\u64ce load_session \u5b8c\u6210 mode={engine_mode} \u004b\u7ebf={bar_count} \u7b79\u7801={chip_bar_count}",
        f"{rust_trace_prefix('\u8bf4\u660e')}\uff1a\u8282\u70b9\u0041 \u4e0d\u53c2\u4e0e\u7f20\u8bba\u7b14/\u6bb5/\u4e2d\u67a2\u8ba1\u7b97\uff0c\u4ec5\u670d\u52a1 step \u589e\u91cf\u4e0e\u7b79\u7801 profile",
    ]


def rust_chan_state_created_lines(stepper: Any) -> list[str]:
    if not getattr(APP_PERF_ENGINE, "rust_available", False):
        return []
    sid = str(getattr(stepper, "rust_chan_state_id", None) or "")
    if not sid:
        return []
    short = sid if len(sid) <= 20 else (sid[:20] + "\u2026")
    return [
        f"{rust_trace_prefix('\u6210\u529f')}\uff1a\u8282\u70b9\u0044 \u0043\u0068\u0061\u006e\u72b6\u6001\u673a\u5df2\u521b\u5efa state_id={short}\uff1b{rust_chan_mode_text()}",
    ]


def rust_presentation_begin_lines(stepper: Any) -> list[str]:
    lines = [
        f"{rust_trace_prefix('\u8fdb\u884c\u4e2d')}\uff1a\u4e00\u6b21\u6027\u5448\u73b0\u5f00\u59cb\u2014\u2014\u9010\u004b step \u5faa\u73af {rust_chan_mode_text()}",
    ]
    if rust_chan_primary_enabled():
        lines.append(
            f"{rust_trace_prefix('\u8bf4\u660e')}\uff1aprimary \u6a21\u5f0f\u672c\u9636\u6bb5 \u0050\u0079\u0074\u0068\u006f\u006e next(_iter) \u5173\u95ed\uff0c\u672b\u6839 bulk_present \u56de\u704c chan"
        )
    elif rust_chan_shadow_enabled():
        lines.append(
            f"{rust_trace_prefix('\u8bf4\u660e')}\uff1ashadow \u6a21\u5f0f\u6bcf\u6b65 \u0050\u0079\u0074\u0068\u006f\u006e \u9012\u63a8\u540e \u0052\u0075\u0073\u0074 feed_bar \u5e76\u6bd4\u5bf9 klc/fx/bi \u5c3e\u7b7e\u540d"
        )
    else:
        lines.append(
            f"{rust_trace_prefix('\u8bf4\u660e')}\uff1a\u672c\u9636\u6bb5\u7f20\u8bba\u9012\u63a8=\u0050\u0079\u0074\u0068\u006f\u006e\uff1b\u0052\u0075\u0073\u0074 \u4ec5\u53c2\u4e0e \u0042\u0053\u0050 \u589e\u91cf\u53bb\u91cd\uff08\u82e5\u542f\u7528\uff09"
        )
    if getattr(stepper, "perf_session_id", None):
        lines.append(
            f"{rust_trace_prefix('\u8bf4\u660e')}\uff1a\u8282\u70b9\u0042 \u672c\u6a21\u5f0f step API \u4e0d\u9010\u6839\u8c03\u7528\uff1b\u4f1a\u8bdd id \u5df2\u6ce8\u518c\u4f9b\u540e\u7eed\u6b65\u8fdb"
        )
    return lines


def rust_presentation_detail_lines(
    perf: dict[str, Any],
    step_detail: dict[str, Any],
    *,
    stepper: Any,
) -> list[str]:
    detail1 = step_detail.get("stepper1", {}) if isinstance(step_detail, dict) else {}
    rust_bsp_s = float(perf.get("rust_collect_ms", 0.0)) / 1000.0
    rust_bsp_n = int(perf.get("rust_collect_calls", 0))
    rust_bsp_items = int(perf.get("rust_items", 0))
    rust_shadow_s = float(perf.get("rust_shadow_ms", 0.0)) / 1000.0
    rust_shadow_n = int(perf.get("rust_shadow_calls", 0))
    py_iter_s = float(detail1.get("iter_ms", 0.0)) / 1000.0
    step_shadow_s = float(detail1.get("rust_shadow_ms", 0.0)) / 1000.0
    mismatch = perf.get("rust_shadow_mismatch_step")
    primary_used = bool(perf.get("rust_chan_primary_used"))

    lines = [
        f"{rust_trace_prefix('\u6210\u529f')}\uff1a\u8282\u70b9\u0043 \u0042\u0053\u0050\u589e\u91cf\u53bb\u91cd {rust_bsp_s:.2f}s/{rust_bsp_n}\u6b21 \u65b0\u589e{rust_bsp_items}\u6761\uff08\u0050\u0079\u0074\u0068\u006f\u006e\u9012\u63a8\u4ecd\u8d1f\u8d23\u7ed3\u6784\uff09",
    ]
    shadow_on = rust_chan_shadow_enabled()
    if shadow_on and (rust_shadow_n > 0 or step_shadow_s > 0):
        lines.append(
            f"{rust_trace_prefix('\u6210\u529f')}\uff1a\u8282\u70b9\u0044 \u0043\u0068\u0061\u006e shadow\u53cc\u8dd1 {max(rust_shadow_s, step_shadow_s):.2f}s/{rust_shadow_n}\u6b21"
            f"{'' if mismatch is None else f'\uff1b\u9996\u9519step={mismatch}'}"
        )
    if primary_used:
        lines.append(
            f"{rust_trace_prefix('\u6210\u529f')}\uff1a\u8282\u70b9\u0044 \u0043\u0068\u0061\u006e primary \u5df2\u7528\u4e8e\u672c\u5448\u73b0\uff08\u672b\u6839 bulk \u56de\u704c \u0050\u0079\u0074\u0068\u006f\u006e chan\uff09"
        )
    elif py_iter_s > 0:
        lines.append(
            f"{rust_trace_prefix('\u8bf4\u660e')}\uff1a\u7f20\u8bba\u9012\u63a8\u4ecd\u7531 \u0050\u0079\u0074\u0068\u006f\u006e next(_iter) {py_iter_s:.2f}s\uff08\u4e3b\u70ed\u70b9\uff09\uff1b\u0052\u0075\u0073\u0074 \u672a\u66ff\u6362\u4e3b\u8def\u5f84"
        )
    if mismatch is not None:
        lines.append(
            f"{rust_trace_prefix('\u8bf4\u660e')}\uff1ashadow \u5df2\u56e0 step={mismatch} \u4e0d\u5bf9\u9f50\u81ea\u52a8\u505c\u7528\u540e\u7eed\u6bd4\u5bf9"
        )
    return lines


def new_rust_chan_state_id(prefix: str = "chan") -> str:
    return f"{prefix}-{uuid.uuid4().hex[:16]}"


def ensure_rust_chan_state(stepper: Any) -> Optional[str]:
    state_id = getattr(stepper, "rust_chan_state_id", None)
    if not state_id:
        state_id = new_rust_chan_state_id()
        stepper.rust_chan_state_id = state_id
    if not APP_PERF_ENGINE.chan_create(state_id):
        return None
    return str(state_id)


def feed_rust_chan_bar(stepper: Any, *, idx: int, high: float, low: float, close: float) -> bool:
    state_id = ensure_rust_chan_state(stepper)
    if not state_id:
        return False
    return APP_PERF_ENGINE.chan_feed_bar(state_id, idx=idx, high=high, low=low, close=close)


def rust_signature_hash(signature_text: Optional[str]) -> Optional[str]:
    if not signature_text:
        return None
    return hashlib.sha256(signature_text.encode("utf-8")).hexdigest()


def run_rust_chan_shadow(stepper: Any, *, step_idx: int) -> Optional[str]:
    if getattr(stepper, "_rust_chan_shadow_disabled", False):
        return None
    if not rust_chan_shadow_enabled() and not rust_chan_primary_enabled():
        return None
    try:
        kl_list = stepper.chan[0]
    except Exception:
        return "shadow: no kl_list"
    py_hash = structure_step_hash(kl_list)
    state_id = ensure_rust_chan_state(stepper)
    if not state_id:
        return "shadow: rust state unavailable"
    rust_sig = APP_PERF_ENGINE.chan_structure_signature(state_id)
    mismatch = compare_structure_with_rust(kl_list, rust_sig)
    if mismatch:
        stepper._rust_chan_shadow_disabled = True
        return f"shadow mismatch step={step_idx} {mismatch} py_hash={py_hash}"
    return None


def reset_rust_chan_state(stepper: Any) -> None:
    state_id = getattr(stepper, "rust_chan_state_id", None)
    if state_id:
        APP_PERF_ENGINE.chan_reset(str(state_id))
    stepper._rust_chan_shadow_disabled = False


def destroy_rust_chan_state(stepper: Any) -> None:
    state_id = getattr(stepper, "rust_chan_state_id", None)
    if state_id:
        APP_PERF_ENGINE.chan_destroy(str(state_id))
    stepper.rust_chan_state_id = None
