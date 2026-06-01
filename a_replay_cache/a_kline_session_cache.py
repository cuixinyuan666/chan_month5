# -*- coding: utf-8 -*-
"""K 线会话历史缓存已禁用。

保留函数名是为了兼容 a_replay_trainer.py 的调用点；所有接口都只返回空结果，
加载会话时固定从 a_Data 重新取数并计算，不创建 bundle.pkl / meta.json。
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any, Optional


def kline_session_cache_enabled() -> bool:
    """硬禁用 K 线会话磁盘缓存。"""
    return False


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
    """生成稳定键仅用于日志/兼容，不再对应任何磁盘文件。"""
    body = {
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


def try_load_kline_session(key: str) -> Optional[KlineSessionCacheHit]:
    """不读历史缓存。"""
    return None


def save_kline_session(
    key: str,
    *,
    replay_klus_master: list,
    kline_all: list,
    stock_name: Optional[str],
    meta_extra: Optional[dict[str, Any]] = None,
) -> None:
    """不写历史缓存。"""
    return None
