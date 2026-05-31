# -*- coding: utf-8 -*-
"""Disk cache for K-line / chip kline_all to skip refetch on reload."""

from __future__ import annotations

import hashlib
import json
import os
import pickle
import sys
import threading
from dataclasses import dataclass
from typing import Any, Optional

_CACHE_VERSION = 3
_PICKLE_RECURSION = 0x100000
_ENV_DISABLE = os.environ.get("KLINE_SESSION_CACHE", "1").strip().lower() in ("0", "false", "no", "off")
_lock = threading.Lock()


def kline_session_cache_enabled() -> bool:
    return not _ENV_DISABLE


def _cache_root() -> str:
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, "a_replay_cache", "kline_sessions")


def _stable_json(obj: Any) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, default=str)


def build_cache_key(
    *,
    code: str,
    begin_date: str,
    end_date: Optional[str],
    autype_key: str,
    k_type_key: str,
    use_for: str,
    offline_data_custom: str,
    priority: Optional[list[str]],
    confirm_offline: bool,
) -> str:
    body = {
        "v": _CACHE_VERSION,
        "code": str(code or "").strip(),
        "begin": str(begin_date or "").strip(),
        "end": str(end_date or "").strip(),
        "autype": str(autype_key or "").strip().lower(),
        "k_type": str(k_type_key or "").strip().lower(),
        "use_for": str(use_for or "kline").strip().lower(),
        "offline_custom": str(offline_data_custom or "native").strip(),
        "priority": list(priority or []),
        "confirm_offline": bool(confirm_offline),
    }
    return hashlib.sha256(_stable_json(body).encode("utf-8")).hexdigest()[:24]


@dataclass
class KlineSessionCacheHit:
    replay_klus_master: list
    kline_all: list
    stock_name: Optional[str]
    cache_path: str
    data_src_label: str = ""


def _paths(key: str) -> tuple[str, str, str]:
    folder = os.path.join(_cache_root(), key)
    return folder, os.path.join(folder, "bundle.pkl"), os.path.join(folder, "meta.json")


def _with_pickle_recursion(fn: Any) -> Any:
    pre = sys.getrecursionlimit()
    sys.setrecursionlimit(_PICKLE_RECURSION)
    try:
        return fn()
    finally:
        sys.setrecursionlimit(pre)


def try_load_kline_session(key: str) -> Optional[KlineSessionCacheHit]:
    if not kline_session_cache_enabled():
        return None
    _folder, pkl_path, meta_path = _paths(key)
    if not os.path.isfile(pkl_path) or not os.path.isfile(meta_path):
        return None
    try:
        with open(meta_path, "r", encoding="utf-8") as f:
            meta = json.load(f)
        if int(meta.get("version", 0)) != _CACHE_VERSION:
            return None

        def _read() -> Any:
            with open(pkl_path, "rb") as fp:
                return pickle.load(fp)

        raw = _with_pickle_recursion(_read)
        if not isinstance(raw, dict):
            return None
        master = raw.get("replay_klus_master") or []
        kline_all = raw.get("kline_all") or []
        if not master:
            return None
        return KlineSessionCacheHit(
            replay_klus_master=master,
            kline_all=list(kline_all),
            stock_name=raw.get("stock_name"),
            cache_path=pkl_path,
            data_src_label=str(meta.get("data_src_label", "") or raw.get("data_src_label", "")),
        )
    except Exception as exc:
        print(f"[KlineSessionCache] load failed {pkl_path}: {exc}")
        return None


def save_kline_session(
    key: str,
    *,
    replay_klus_master: list,
    kline_all: list,
    stock_name: Optional[str],
    meta_extra: Optional[dict[str, Any]] = None,
) -> None:
    if not kline_session_cache_enabled() or not replay_klus_master:
        return
    folder, pkl_path, meta_path = _paths(key)
    meta = {"version": _CACHE_VERSION, "bar_count": len(replay_klus_master), "kline_all_count": len(kline_all or [])}
    if meta_extra:
        meta.update(meta_extra)

    def _write() -> None:
        os.makedirs(folder, exist_ok=True)
        payload = {
            "replay_klus_master": replay_klus_master,
            "kline_all": list(kline_all or []),
            "stock_name": stock_name,
        }
        tmp = pkl_path + ".tmp"
        with open(tmp, "wb") as fp:
            pickle.dump(payload, fp, protocol=pickle.HIGHEST_PROTOCOL)
        os.replace(tmp, pkl_path)
        tmp_meta = meta_path + ".tmp"
        with open(tmp_meta, "w", encoding="utf-8") as f:
            json.dump(meta, f, ensure_ascii=False, indent=2)
        os.replace(tmp_meta, meta_path)

    with _lock:
        try:
            _with_pickle_recursion(_write)
            print(f"[KlineSessionCache] saved {pkl_path} bars={len(replay_klus_master)}")
        except Exception as exc:
            print(f"[KlineSessionCache] save failed: {exc}")
