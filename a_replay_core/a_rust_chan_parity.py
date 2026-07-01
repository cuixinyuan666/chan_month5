# -*- coding: utf-8 -*-
"""Rust Chan parity: per-step structure signatures and BSP terminal hashes."""

from __future__ import annotations

import hashlib
import json
from typing import Any, Optional

from Common.CEnum import FX_TYPE


def bsp_key_for(level: str, x: int, is_buy: bool) -> str:
    return f"{level}|{int(x)}|{1 if is_buy else 0}"


def _stable_json(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _fx_name(fx: Any) -> str:
    if fx is None:
        return "UNKNOWN"
    name = getattr(fx, "name", None)
    if name:
        return str(name)
    if fx == FX_TYPE.TOP:
        return "TOP"
    if fx == FX_TYPE.BOTTOM:
        return "BOTTOM"
    return "UNKNOWN"


def _line_tail_sig(lines: Any, tail: int = 5) -> tuple[Any, ...]:
    try:
        arr = list(lines)
    except Exception:
        return (0,)
    sig: list[Any] = [len(arr)]
    for line in arr[-max(1, int(tail)):]:
        try:
            direction = getattr(line, "dir", None)
            sig.append(
                (
                    int(line.get_begin_klu().idx),
                    int(line.get_end_klu().idx),
                    bool(getattr(line, "is_sure", False)),
                    float(line.get_begin_val()),
                    float(line.get_end_val()),
                    getattr(direction, "name", str(direction)),
                )
            )
        except Exception:
            sig.append(("?", bool(getattr(line, "is_sure", False))))
    return tuple(sig)


def _klc_fx_tail(kl_list: Any, tail: int = 3) -> tuple[Any, ...]:
    try:
        lst = list(kl_list.lst)
    except Exception:
        return (0,)
    sig: list[Any] = [len(lst)]
    for klc in lst[-max(1, int(tail)):]:
        sig.append((int(klc.idx), _fx_name(getattr(klc, "fx", None)), float(klc.high), float(klc.low)))
    return tuple(sig)


def _bsp_keys_from_lists(kl_list: Any) -> tuple[str, ...]:
    keys: list[str] = []
    for level, bsp_list in (
        ("bi", getattr(kl_list, "bs_point_lst", None)),
        ("seg", getattr(kl_list, "seg_bs_point_lst", None)),
    ):
        if bsp_list is None:
            continue
        try:
            for bsp in bsp_list.bsp_iter():
                try:
                    klu = bsp.klu
                    x = int(klu.idx)
                    is_buy = bool(bsp.is_buy)
                    keys.append(bsp_key_for(level, x, is_buy))
                except Exception:
                    continue
        except Exception:
            continue
    return tuple(sorted(set(keys)))


def structure_step_signature(kl_list: Any, *, bi_tail: int = 5, seg_tail: int = 3) -> tuple[Any, ...]:
    return (
        _klc_fx_tail(kl_list, 3),
        _line_tail_sig(getattr(kl_list, "bi_list", None), bi_tail),
        _line_tail_sig(getattr(kl_list, "seg_list", None), seg_tail),
        _line_tail_sig(getattr(kl_list, "segseg_list", None), seg_tail),
        int(getattr(kl_list, "last_sure_seg_start_bi_idx", -1)),
        int(getattr(kl_list, "last_sure_segseg_start_bi_idx", -1)),
        _bsp_keys_from_lists(kl_list),
    )


def structure_step_hash(kl_list: Any) -> str:
    return hashlib.sha256(_stable_json(structure_step_signature(kl_list)).encode("utf-8")).hexdigest()


def bsp_history_hash(history: list[dict[str, Any]]) -> str:
    rows = []
    for item in history or []:
        key = str(item.get("key", ""))
        if not key:
            level = str(item.get("level", ""))
            x = int(item.get("x", -1))
            if level and x >= 0:
                key = bsp_key_for(level, x, bool(item.get("is_buy")))
        rows.append(
            {
                "key": key,
                "x": int(item.get("x", -1)),
                "anchor_x": int(item.get("anchor_x", item.get("x", -1))),
                "level": str(item.get("level", "")),
                "is_buy": bool(item.get("is_buy")),
                "label": str(item.get("label", "")),
            }
        )
    rows.sort(key=lambda r: (r["key"], r["x"], r["level"]))
    return hashlib.sha256(_stable_json(rows).encode("utf-8")).hexdigest()


def chart_bsp_hash(chart: dict[str, Any]) -> str:
    rows = []
    for item in chart.get("bsp", []) or []:
        level = str(item.get("level", ""))
        x = int(item.get("x", -1))
        is_buy = bool(item.get("is_buy"))
        key = str(item.get("key", "")) or (bsp_key_for(level, x, is_buy) if level and x >= 0 else "")
        rows.append(
            {
                "key": key,
                "x": x,
                "level": level,
                "is_buy": is_buy,
                "label": str(item.get("label", "")),
            }
        )
    rows.sort(key=lambda r: (r["key"], r["x"], r["level"]))
    return hashlib.sha256(_stable_json(rows).encode("utf-8")).hexdigest()


def compare_step_signatures(
    py_sig: tuple[Any, ...],
    rust_sig: tuple[Any, ...],
    *,
    step_idx: int,
) -> Optional[str]:
    if py_sig == rust_sig:
        return None
    return f"step={step_idx} py!=rust py={py_sig!r} rust={rust_sig!r}"


def signature_to_jsonable(sig: tuple[Any, ...]) -> Any:
    return sig


def normalized_structure_from_kl_list(kl_list: Any) -> dict[str, Any]:
    sig = structure_step_signature(kl_list)
    return {
        "klc_count": sig[0][0] if sig[0] else 0,
        "fx_tail": list(sig[0][1:]),
        "bi_tail": list(sig[1][1:]),
        "seg_tail": list(sig[2][1:]),
        "segseg_tail": list(sig[3][1:]),
        "last_sure_seg_start_bi_idx": sig[4],
        "last_sure_segseg_start_bi_idx": sig[5],
        "bsp_keys": list(sig[6]),
    }


def compare_structure_with_rust(kl_list: Any, rust_sig_text: Optional[str]) -> Optional[str]:
    if not rust_sig_text:
        return "rust signature empty"
    try:
        rust_obj = json.loads(rust_sig_text)
    except Exception as exc:
        return f"rust signature json error: {exc}"
    py_obj = normalized_structure_from_kl_list(kl_list)
    # POC：先对齐 K 线合并+分型+笔尾；段/BSP 逐步扩。
    for key in ("klc_count", "fx_tail", "bi_tail"):
        if py_obj.get(key) != rust_obj.get(key):
            return f"{key} py={py_obj.get(key)!r} rust={rust_obj.get(key)!r}"
    return None
