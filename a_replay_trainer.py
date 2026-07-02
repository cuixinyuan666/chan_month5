import copy
import inspect
import json
import os
import re
import threading
import time
import warnings
from bisect import bisect_right
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from functools import lru_cache
from typing import Any, Iterator, Optional

# 可选数据源：未安装时统一提示（与下方 RuntimeError 文案一致）
# 说明：PyPI 无 ashare 包，开源封装多为 pip install ashares（import ashares）
_OPT_DEP_HINT_ASHARE = "未安装 Ashare 行情库（ashare 单文件或 PyPI 的 ashares），请执行: pip install ashares"
_OPT_DEP_HINT_ADATA = "未安装 adata（AData 数据源），请执行: pip install adata"
_OPT_DEP_HINT_PYTDX = "未安装 pytdx（通达信数据源），请执行: pip install pytdx"
_OPT_DEP_HINT_YFINANCE = "未安装 yfinance（雅虎财经），请执行: pip install yfinance"

import akshare as ak
import pandas as pd
import tushare as ts
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from starlette.concurrency import run_in_threadpool
from a_replay_core.a_replay_api_models import (
    BackNReq,
    GotoStepReq,
    IndicatorBacktestReq,
    InitReq,
    JudgeBspReq,
    LoadChartLayersReq,
    ReconfigReq,
    SessionKlineViewReq,
    StepReq,
)
from a_replay_core.a_replay_multi_xmap import remap_overlay_chart_to_driver_x
from a_replay_cache.a_step_rollback import (
    AppLightSnapshot,
    AppRollbackSnapshot,
    capture_stepper_snapshot,
    restore_stepper_snapshot,
)
from a_replay_cache.a_step_rollback_fast import (
    AppStepDelta,
    capture_app_step_delta,
    overlay_app_step_delta,
)
from a_replay_cache.a_kline_session_cache import (
    build_cache_key,
    kline_session_cache_enabled,
    save_kline_session,
    try_load_kline_session,
)
from a_replay_core.a_init_perf import (
    init_perf_enabled,
    init_perf_report,
    init_perf_run,
    init_perf_stage,
    set_init_stage_listener,
)
from a_replay_core.a_replay_kline_view import kline_view_rows_filtered
from a_replay_core.a_replay_presenters import (
    msg_buy,
    msg_cover,
    msg_sell,
    msg_short,
    trade_events_same_bar_flip,
)
from a_replay_core.a_replay_serializers import serialize_chan_with_cache, serialize_klu_iter_fast
from a_replay_core.a_replay_step_utils import serialize_klu_unit_fast
from a_replay_core.a_perf_engine import PerfEngine
from a_replay_core.a_rust_chan_shadow import (
    destroy_rust_chan_state,
    ensure_rust_chan_state,
    feed_rust_chan_bar,
    reset_rust_chan_state,
    run_rust_chan_shadow,
    rust_chan_primary_enabled,
    rust_chan_shadow_enabled,
    rust_chan_state_created_lines,
    rust_perf_engine_loaded_lines,
    rust_presentation_begin_lines,
    rust_presentation_detail_lines,
    rust_session_env_trace_lines,
)

# 尝试导入其他数据源库（缺失时启动阶段给出明确安装提示）
ASHARE_MOD = None  # ashare 或 PyPI 的 ashares，供 get_price 使用
try:
    import ashares as ASHARE_MOD  # PyPI 包名 ashares，API 与 Ashare 一致
    HAS_ASHARE = True
except ImportError:
    HAS_ASHARE = False
    warnings.warn(_OPT_DEP_HINT_ASHARE, ImportWarning, stacklevel=1)
try:
    import adata
    HAS_ADATA = True
except ImportError:
    HAS_ADATA = False
    warnings.warn(_OPT_DEP_HINT_ADATA, ImportWarning, stacklevel=1)
try:
    import pytdx
    HAS_PYTDX = True
except ImportError:
    HAS_PYTDX = False
    warnings.warn(_OPT_DEP_HINT_PYTDX, ImportWarning, stacklevel=1)
try:
    import yfinance as yf
    HAS_YFINANCE = True
except ImportError:
    HAS_YFINANCE = False
    warnings.warn(_OPT_DEP_HINT_YFINANCE, ImportWarning, stacklevel=1)
import requests
from bs4 import BeautifulSoup

from Bi.Bi import CBi
from BuySellPoint.BSPointList import CBSPointList
from Chan import CChan
from ChanConfig import CChanConfig
from Common.CEnum import AUTYPE, BI_DIR, DATA_FIELD, DATA_SRC, FX_TYPE, KL_TYPE, KLINE_DIR, SEG_TYPE, TREND_LINE_SIDE
from Common.ChanException import CChanException, ErrCode
from Common.CTime import CTime
from DataAPI.BaoStockAPI import CBaoStock
from DataAPI.CommonStockAPI import CCommonStockApi
from Common.func_util import str2float
from a_replay_core.a_offline_tick_merge import (
    OfflineTickRow,
    merge_no_bs_offline_ticks,
    normalize_offline_data_custom,
    parse_offline_tick_line,
    rows_to_legacy_ticks,
)
from a_replay_record import (
    ChanRecordApplyResult,
    build_chan_config_fingerprint,
    drain_record_trace,
    peek_record_trace,
    push_record_trace,
    schedule_chan_record_save,
    try_apply_chan_record,
)
from KLine.KLine import CKLine
from KLine.KLine_List import cal_seg, get_seglist_instance, update_zs_in_seg
from KLine.KLine_Unit import CKLine_Unit
from Math.BOLL import BollModel
from Math.Demark import CDemarkEngine
from Math.KDJ import KDJ
from Math.MACD import CMACD
from Math.RSI import RSI
from Math.TrendLine import CTrendLine
from Seg.Seg import CSeg
from ZS.ZSList import CZSList


class ReplayChan(CChan):
    """使用会话内缓存的日线 K 线单元重建缠论计算，避免重复请求行情。

    trigger_step 模式下每次 load() 从内存快照 deepcopy 后喂给 load_iterator，
    笔/线段/中枢/买卖点均随 ChanConfig 重新计算；数据层与配置层解耦。
    """

    def __init__(self, *args: Any, replay_klus_master: Optional[list] = None, **kwargs: Any) -> None:
        self._replay_klus_master: Optional[list] = replay_klus_master
        # 复盘由 load/step_load 显式喂 K；禁止 CChan.__init__ 在 trigger_step=False 时自动全量 load（unified 曾因此重复喂入）
        conf = kwargs.get("config")
        if conf is not None:
            conf.trigger_step = True
        super().__init__(*args, **kwargs)

    def load(self, step: bool = False):
        if self._replay_klus_master is None:
            yield from super().load(step)
            return
        # 重载前清空级别数据，避免 re-load / 误触二次 load 叠加重复 K 线
        self.do_init()
        self.g_kl_iter = defaultdict(list)
        frozen = copy.deepcopy(self._replay_klus_master)
        self.klu_cache = [None for _ in self.lv_list]
        self.klu_last_t = [CTime(1980, 1, 1, 0, 0) for _ in self.lv_list]
        self.add_lv_iter(0, iter(frozen))
        yield from self.load_iterator(lv_idx=0, parent_klu=None, step=step)
        if not step:
            for lv in self.lv_list:
                self.kl_datas[lv].cal_seg_and_zs()
        if len(self[0]) == 0:
            raise CChanException("最高级别没有获得任何数据", ErrCode.NO_DATA)


CHAN_ALGO_CLASSIC = "classic"
CHAN_ALGO_NEW = "new"
VISIBLE_BSP_LEVELS = ("bi", "seg", "segseg")
LEVEL_ORDER = {level: idx for idx, level in enumerate(VISIBLE_BSP_LEVELS)}


@lru_cache(maxsize=128)
def _custom_seg_level_num_text(text: str) -> Optional[int]:
    """热路径级别解析：不用正则，避免百万次 fullmatch。"""
    if text == "segseg":
        return 2
    if len(text) <= 3 or not text.startswith("seg"):
        return None
    tail = text[3:]
    if not tail.isdecimal():
        return None
    n = int(tail)
    return n if n >= 3 else None


def custom_seg_level_num(level: Any) -> Optional[int]:
    text = str(level or "").strip().lower()
    return _custom_seg_level_num_text(text)


def seg_level_id(num: int) -> str:
    n = int(num)
    return "segseg" if n == 2 else f"seg{n}"


def is_bsp_level(level: Any) -> bool:
    text = str(level or "").strip().lower()
    return text in ("bi", "seg") or custom_seg_level_num(text) is not None


@lru_cache(maxsize=128)
def _bsp_level_sort_order_text(text: str) -> int:
    if text == "bi":
        return 0
    if text == "seg":
        return 1
    n = custom_seg_level_num(text)
    if n is not None:
        return n
    return 999


def bsp_level_sort_order(level: Any) -> int:
    text = str(level or "").strip().lower()
    return _bsp_level_sort_order_text(text)


def extra_seg_levels_from_layers(layers: Any) -> list[str]:
    if (
        isinstance(layers, dict)
        and isinstance(layers.get("line_levels"), dict)
        and isinstance(layers.get("bsp_levels"), dict)
        and isinstance(layers.get("zs_levels"), dict)
    ):
        cfg = layers
    else:
        cfg = normalize_chart_lazy_layers(layers, default_enabled=False)
    levels: set[str] = set()
    for group_name in ("line_levels", "bsp_levels", "zs_levels"):
        group = cfg.get(group_name) or {}
        for level, enabled in group.items():
            n = custom_seg_level_num(level)
            if enabled and n is not None and n >= 3:
                levels.add(seg_level_id(n))
    return sorted(levels, key=bsp_level_sort_order)


def extra_bsp_levels_from_layers(layers: Any) -> list[str]:
    if isinstance(layers, dict) and isinstance(layers.get("bsp_levels"), dict):
        cfg = layers
    else:
        cfg = normalize_chart_lazy_layers(layers, default_enabled=False)
    levels: set[str] = set()
    for level, enabled in (cfg.get("bsp_levels") or {}).items():
        n = custom_seg_level_num(level)
        if enabled and n is not None and n >= 3:
            levels.add(seg_level_id(n))
    return sorted(levels, key=bsp_level_sort_order)


def bsp_levels_from_layers(layers: Any = None) -> list[str]:
    if isinstance(layers, dict) and isinstance(layers.get("bsp_levels"), dict):
        cfg = layers
    else:
        cfg = normalize_chart_lazy_layers(layers)
    bsp_cfg = cfg.get("bsp_levels") or {}
    levels = [level for level in ("bi", "seg", "segseg") if bool(bsp_cfg.get(level, True))]
    for level in extra_bsp_levels_from_layers(layers):
        if level not in levels:
            levels.append(level)
    return levels


def normalize_chart_lazy_layers(raw: Any, default_enabled: bool = True) -> dict[str, Any]:
    """首包/懒加载图层策略：未传按旧逻辑全开。"""
    src = raw if isinstance(raw, dict) else {}
    bsp_src = src.get("bsp_levels") if isinstance(src.get("bsp_levels"), dict) else {}
    zs_src = src.get("zs_levels") if isinstance(src.get("zs_levels"), dict) else {}
    line_src = src.get("line_levels") if isinstance(src.get("line_levels"), dict) else {}
    if isinstance(src.get("line_levels"), list):
        line_src = {str(level): True for level in src.get("line_levels") or []}
    line_levels: dict[str, bool] = {}
    bsp_levels = {
        "bi": bool(bsp_src.get("bi", default_enabled)),
        "seg": bool(bsp_src.get("seg", default_enabled)),
        "segseg": bool(bsp_src.get("segseg", default_enabled)),
    }
    zs_levels = {
        "fract": bool(zs_src.get("fract", default_enabled)),
        "bi": bool(zs_src.get("bi", default_enabled)),
        "seg": bool(zs_src.get("seg", default_enabled)),
        "segseg": bool(zs_src.get("segseg", default_enabled)),
    }
    for level, enabled in bsp_src.items():
        if custom_seg_level_num(level) is not None:
            bsp_levels[str(level)] = bool(enabled)
    for level, enabled in zs_src.items():
        if custom_seg_level_num(level) is not None:
            zs_levels[str(level)] = bool(enabled)
    for level, enabled in line_src.items():
        if custom_seg_level_num(level) is not None:
            line_levels[str(level)] = bool(enabled)
    return {
        "rhythm": bool(src.get("rhythm", default_enabled)),
        "rhythm_hits": bool(src.get("rhythm_hits", src.get("rhythm", default_enabled))),
        "line_levels": dict(sorted(line_levels.items(), key=lambda kv: bsp_level_sort_order(kv[0]))),
        "bsp_levels": dict(sorted(bsp_levels.items(), key=lambda kv: bsp_level_sort_order(kv[0]))),
        "zs_levels": dict(sorted(zs_levels.items(), key=lambda kv: bsp_level_sort_order(kv[0]))),
    }


def merge_chart_lazy_layers(base: Any, extra: Any) -> dict[str, Any]:
    """图层开关只增不减；已加载过的图层保持可用。"""
    out = normalize_chart_lazy_layers(base)
    add = normalize_chart_lazy_layers(extra, default_enabled=False)
    out["rhythm"] = bool(out.get("rhythm")) or bool(add.get("rhythm"))
    out["rhythm_hits"] = bool(out.get("rhythm_hits")) or bool(add.get("rhythm_hits"))
    for level in sorted({*out["line_levels"].keys(), *add["line_levels"].keys()}, key=bsp_level_sort_order):
        out["line_levels"][level] = bool(out["line_levels"].get(level)) or bool(add["line_levels"].get(level))
    for level in sorted({*out["bsp_levels"].keys(), *add["bsp_levels"].keys()}, key=bsp_level_sort_order):
        out["bsp_levels"][level] = bool(out["bsp_levels"].get(level)) or bool(add["bsp_levels"].get(level))
    for level in sorted({*out["zs_levels"].keys(), *add["zs_levels"].keys()}, key=bsp_level_sort_order):
        out["zs_levels"][level] = bool(out["zs_levels"].get(level)) or bool(add["zs_levels"].get(level))
    return out


def chart_lazy_bsp_enabled(layers: Any, level: str) -> bool:
    if isinstance(layers, dict):
        group = layers.get("bsp_levels")
        if isinstance(group, dict):
            return bool(group.get(level, True))
        if group is None:
            return True
    cfg = normalize_chart_lazy_layers(layers)
    return bool((cfg.get("bsp_levels") or {}).get(level, True))


def chart_lazy_zs_enabled(layers: Any, level: str) -> bool:
    if isinstance(layers, dict):
        group = layers.get("zs_levels")
        if isinstance(group, dict):
            return bool(group.get(level, True))
        if group is None:
            return True
    cfg = normalize_chart_lazy_layers(layers)
    return bool((cfg.get("zs_levels") or {}).get(level, True))
LEVEL_LABELS = {"bi": "笔", "seg": "段", "segseg": "2段"}
STRUCTURE_LEVEL_LABELS = {"fract": "分型", **LEVEL_LABELS}
RHYTHM_LEVEL_LABELS = {"fract": "分型", "bi": "笔", "seg": "线段", "segseg": "二段"}
JUDGE_TRIGGER_LEVELS = {"bi": "seg", "seg": "segseg", "segseg": "segsegseg"}


def dynamic_level_label(level: Any) -> str:
    text = str(level or "").strip().lower()
    n = custom_seg_level_num(text)
    if n is not None:
        return f"{n}段"
    return LEVEL_LABELS.get(text, str(level))


def judge_trigger_level(level: Any) -> str:
    text = str(level or "").strip().lower()
    if text in JUDGE_TRIGGER_LEVELS:
        return JUDGE_TRIGGER_LEVELS[text]
    n = custom_seg_level_num(text)
    if n is not None:
        return seg_level_id(n + 1)
    return ""
RHYTHM_CALC_MODE_NORMAL = "normal"
RHYTHM_CALC_MODE_TRANSITION = "transition"
RHYTHM_CALC_MODE_STRICT_1382 = "strict1382"
RHYTHM_CALC_MODES = {RHYTHM_CALC_MODE_NORMAL, RHYTHM_CALC_MODE_TRANSITION, RHYTHM_CALC_MODE_STRICT_1382}
DEFAULT_TUSHARE_TOKEN = "0de8d8ce7b0d4758c52959230694d55e0571d57c9b1f37ef3ffe72ca"
AKSHARE_INLINE_SRC = "inline:akshare"
TUSHARE_INLINE_SRC = "inline:tushare"
PYTDX_INLINE_SRC = "inline:pytdx"
SINA_INLINE_SRC = "inline:sina"
TENCENT_INLINE_SRC = "inline:tencent"
YAHOO_INLINE_SRC = "inline:yahoo"
EASTMONEY_INLINE_SRC = "inline:eastmoney"
AKTX_INLINE_SRC = "inline:aktx"
GITHUB_CSV_INLINE_SRC = "inline:github_csv"
# 本地 a_Data 离线包：仅分笔 txt（a_Data/六位代码/YYYYMMDD_六位代码.txt），内存中聚合成各周期 K
OFFLINE_INLINE_SRC = "inline:offline"
# 可配置的数据源优先级（从系统配置读取）
CONFIG_DATA_SRC_PRIORITY: list = []
CONFIG_OHLC_SRC: Any = None  # 开高低收数据源，默认第一个可用
CONFIG_VOL_SRC: Any = None   # 成交量数据源，默认第一个可用

# 默认只走本地 a_Data 离线包；加载会话不再读取历史缓存或联网兜底。
DEFAULT_DATA_SOURCE_PRIORITY_NAMES: list[str] = [
    "离线数据",
]

# 显示名 -> (列表展示名, data_src 键)
_DATA_SOURCE_NAME_TO_PAIR: dict[str, tuple[str, Any]] = {
    "AKShare": ("AKShare", AKSHARE_INLINE_SRC),
    "AKShare-腾讯历史": ("AKShare-腾讯历史", AKTX_INLINE_SRC),
    "GitHub-CSV": ("GitHub-CSV", GITHUB_CSV_INLINE_SRC),
    "Ashare": ("Ashare", "inline:ashare"),
    "AData": ("AData", "inline:adata"),
    "pytdx": ("pytdx", PYTDX_INLINE_SRC),
    "BaoStock": ("BaoStock", DATA_SRC.BAO_STOCK),
    "Tushare": ("Tushare", TUSHARE_INLINE_SRC),
    "新浪财经": ("新浪财经", SINA_INLINE_SRC),
    "腾讯财经": ("腾讯财经", TENCENT_INLINE_SRC),
    "雅虎财经": ("雅虎财经", YAHOO_INLINE_SRC),
    "东方财富": ("东方财富", EASTMONEY_INLINE_SRC),
    "离线数据": ("离线数据", OFFLINE_INLINE_SRC),
}

# K 线拉取与筹码全历史拉取各用一份链（顺序由同一套优先级生成，回退结果可不同）
DATA_SOURCE_CHAIN_KLINE: list[tuple[str, Any]] = []
DATA_SOURCE_CHAIN_CHIP: list[tuple[str, Any]] = []
# BaoStock 网络异常时的会话级冷却（避免 WinError 10057 连续刷屏）
_BAOSTOCK_COOLDOWN_UNTIL: Optional[datetime] = None
_BAOSTOCK_LAST_ERROR: str = ""


def chains_from_priority(names: list[str]) -> list[tuple[str, Any]]:
    """将优先级显示名列表转为 (label, data_src)，跳过未知项。"""
    out: list[tuple[str, Any]] = []
    for name in names:
        pair = _DATA_SOURCE_NAME_TO_PAIR.get(str(name).strip())
        if pair:
            out.append(pair)
    return out


def apply_data_source_priority(names: list[str] | None) -> None:
    """按同一套优先级更新 K 线链与筹码链（两套独立回退，顺序相同）。"""
    global DATA_SOURCE_CHAIN_KLINE, DATA_SOURCE_CHAIN_CHIP
    chain = chains_from_priority(names or [])
    if not chain:
        chain = chains_from_priority(DEFAULT_DATA_SOURCE_PRIORITY_NAMES)
    DATA_SOURCE_CHAIN_KLINE = list(chain)
    DATA_SOURCE_CHAIN_CHIP = list(chain)


# 数据源显示名称映射
DATA_SOURCE_LABELS = {
    AKSHARE_INLINE_SRC: "AKShare",
    AKTX_INLINE_SRC: "AKShare-腾讯历史",
    GITHUB_CSV_INLINE_SRC: "GitHub-CSV",
    "inline:ashare": "Ashare",
    "inline:adata": "AData",
    PYTDX_INLINE_SRC: "pytdx",
    DATA_SRC.BAO_STOCK: "BaoStock",
    TUSHARE_INLINE_SRC: "Tushare",
    SINA_INLINE_SRC: "新浪财经",
    TENCENT_INLINE_SRC: "腾讯财经",
    YAHOO_INLINE_SRC: "雅虎财经",
    EASTMONEY_INLINE_SRC: "东方财富",
    OFFLINE_INLINE_SRC: "离线数据",
}

apply_data_source_priority(DEFAULT_DATA_SOURCE_PRIORITY_NAMES)


def parse_k_type(raw: str) -> KL_TYPE:
    """将字符串周期转换为KL_TYPE枚举"""
    raw = raw.strip().lower()
    mapping = {
        "1min": KL_TYPE.K_1M,
        "5min": KL_TYPE.K_5M,
        "15min": KL_TYPE.K_15M,
        "30min": KL_TYPE.K_30M,
        "60min": KL_TYPE.K_60M,
        "daily": KL_TYPE.K_DAY,
        "weekly": KL_TYPE.K_WEEK,
        "monthly": KL_TYPE.K_MON,
        "quarterly": KL_TYPE.K_QUARTER,
        "yearly": KL_TYPE.K_YEAR,
        "3min": KL_TYPE.K_3M,
    }
    if raw not in mapping:
        raise ValueError(f"不支持的周期类型：{raw}，可选：{list(mapping.keys())}")
    return mapping[raw]


def k_type_to_api_key(kl: KL_TYPE) -> str:
    """KL_TYPE → 与 parse_k_type 对称的周期键（供前端历史文案等）。"""
    inv = {
        KL_TYPE.K_1M: "1min",
        KL_TYPE.K_3M: "3min",
        KL_TYPE.K_5M: "5min",
        KL_TYPE.K_15M: "15min",
        KL_TYPE.K_30M: "30min",
        KL_TYPE.K_60M: "60min",
        KL_TYPE.K_DAY: "daily",
        KL_TYPE.K_WEEK: "weekly",
        KL_TYPE.K_MON: "monthly",
        KL_TYPE.K_QUARTER: "quarterly",
        KL_TYPE.K_YEAR: "yearly",
    }
    return inv.get(kl, "daily")


def normalize_data_form_mode(raw: Any) -> str:
    mode = str(raw or "traditional").strip().lower()
    allow = {"traditional", "quantity", "tick_traditional", "tick_quantity"}
    return mode if mode in allow else "traditional"


# 当前会话离线分笔解析模式（ChanStepper.init 写入）
_ACTIVE_OFFLINE_DATA_CUSTOM = "native"
_OFFLINE_TICK_FILE_CACHE_LOCK = threading.Lock()
_OFFLINE_TICK_FILE_CACHE: dict[tuple[str, int, int], list[OfflineTickRow]] = {}
_OFFLINE_TICK_FILE_CACHE_MAX = 256


def set_active_offline_data_custom(mode: Any) -> None:
    global _ACTIVE_OFFLINE_DATA_CUSTOM
    _ACTIVE_OFFLINE_DATA_CUSTOM = normalize_offline_data_custom(mode)

def normalize_data_feed_mode(raw: Any) -> str:
    """统一数据喂入模式：step=逐步喂入，unified=统一喂入。"""
    mode = str(raw or "step").strip().lower()
    return "unified" if mode == "unified" else "step"


def normalize_replay_chart_mode(raw: Any) -> str:
    m = str(raw or "single").strip().lower()
    if m == "dual":
        return "dual"
    if m == "multi":
        return "multi"
    return "single"


MULTI_CHART_MAX_LAYERS = 5


def kl_granularity_rank(k_type: KL_TYPE) -> int:
    """周期粒度：值越大越粗。"""
    rank_map = {
        KL_TYPE.K_1M: 1,
        KL_TYPE.K_3M: 2,
        KL_TYPE.K_5M: 3,
        KL_TYPE.K_15M: 4,
        KL_TYPE.K_30M: 5,
        KL_TYPE.K_60M: 6,
        KL_TYPE.K_DAY: 7,
        KL_TYPE.K_WEEK: 8,
        KL_TYPE.K_MON: 9,
        KL_TYPE.K_QUARTER: 10,
        KL_TYPE.K_YEAR: 11,
    }
    return int(rank_map.get(k_type, 10_000))


def resolve_multi_k_types_from_request(k_types_multi: Any) -> tuple[str, list[str]]:
    """(driver_api_key, passive_api_keys)；驱动为最细周期，passives 从细到粗。"""
    if not isinstance(k_types_multi, list) or len(k_types_multi) < 2:
        raise ValueError("单品种多周期单图须勾选至少 2 个时间周期")
    seen: set[KL_TYPE] = set()
    pairs: list[tuple[KL_TYPE, str]] = []
    for raw in k_types_multi:
        kt = parse_k_type(str(raw).strip())
        if kt in seen:
            continue
        seen.add(kt)
        pairs.append((kt, k_type_to_api_key(kt)))
    if len(pairs) < 2:
        raise ValueError("单品种多周期单图至少需要 2 个不同周期")
    if len(pairs) > MULTI_CHART_MAX_LAYERS:
        raise ValueError(f"单品种多周期单图最多勾选 {MULTI_CHART_MAX_LAYERS} 个周期")
    pairs.sort(key=lambda it: kl_granularity_rank(it[0]))
    return pairs[0][1], [p[1] for p in pairs[1:]]


def is_data_form_quantity_mode(mode: Any) -> bool:
    """数量类数据形式：普通数量 + 分笔价格合成数量。"""
    m = normalize_data_form_mode(mode)
    return m in {"quantity", "tick_quantity"}


def is_data_form_tick_synth_mode(mode: Any) -> bool:
    """分笔价格合成类数据形式。"""
    m = normalize_data_form_mode(mode)
    return m in {"tick_traditional", "tick_quantity"}


def stepper_needs_chip_kline_all(st: Any) -> bool:
    """筹码分布需要 kline_all；有全历史底座时 reconfig/step 也应下发。"""
    if len(getattr(st, "kline_all", None) or []) > 0:
        return True
    return is_data_form_tick_synth_mode(getattr(st, "data_form_mode", "")) or is_data_form_quantity_mode(
        getattr(st, "data_form_mode", "")
    )


def _kline_all_likely_full_history(stepper: Any) -> bool:
    """粗判 kline_all 是否已是全历史底座（避免 cache_hit 重复拉 1990~）。"""
    arr = list(getattr(stepper, "kline_all", None) or [])
    if len(arr) < 800:
        return False
    begin = str(getattr(stepper, "_session_begin_date", "") or "").strip()
    if begin and arr:
        first_t = str(arr[0].get("t", "") or "")
        if first_t and begin[:7] not in first_t and first_t[:10] > begin:
            return False
    return True


def _ensure_offline_chip_bins_enriched(stepper: Any) -> None:
    """懒加载：仅在需要下发筹码时补全 chip_tick_bins。"""
    if getattr(stepper, "_chip_bins_enriched", False):
        return
    code = getattr(stepper, "code", None)
    k_type = getattr(stepper, "k_type", None)
    if (
        not code
        or k_type is None
        or getattr(stepper, "data_src_used", None) != OFFLINE_INLINE_SRC
        or not (getattr(stepper, "kline_all", None) or [])
        or k_type not in _offline_chip_supported_ktypes()
        or not offline_tick_files_exist_for_range(code, "1990-01-01", None)
    ):
        stepper._chip_bins_enriched = True
        return
    _enrich_kline_all_offline_chip_non_triangle(code, stepper.kline_all, None, k_type)
    stepper._chip_bins_enriched = True


def _chip_kline_all_with_x(bars: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """为 kline_all 补 x 序号，便于与主图 K 线按 x/时间对齐截断筹码。"""
    out: list[dict[str, Any]] = []
    for i, bar in enumerate(bars or []):
        b = dict(bar)
        if int(b.get("x", -1)) < 0:
            b["x"] = i
        out.append(b)
    return out


def _fetch_offline_chip_kline_all(
    code: str,
    k_type: KL_TYPE,
    autype: AUTYPE,
    end_date: Optional[str] = None,
) -> list[dict[str, Any]]:
    """离线筹码底座：只拉 A~C（上市首根到会话结束日），避免把未来 Z 段载入。"""
    t0_ms = int(time.time() * 1000)
    api_cls = COfflineInline
    safe_api_do_init(api_cls, OFFLINE_INLINE_SRC)
    try:
        api = api_cls(
            code=normalize_code(code),
            k_type=k_type,
            begin_date="1990-01-01",
            end_date=end_date,
            autype=autype,
        )
        out = serialize_klu_iter(list(api.get_kl_data()))
        # #region agent log
        _agent_debug_log_backend(
            "P1",
            "a_replay_trainer.py:_fetch_offline_chip_kline_all",
            "离线全历史直拉耗时",
            {
                "code": str(code),
                "kType": str(getattr(k_type, "name", k_type)),
                "endDate": str(end_date or ""),
                "bars": len(out),
                "costMs": int(time.time() * 1000) - t0_ms,
            },
            run_id="perf-check",
        )
        # #endregion
        return out
    finally:
        api_cls.do_close()


def _refresh_stepper_chip_kline_all_base(stepper: Any, autype: AUTYPE) -> None:
    """尽力拉齐筹码全历史底座（上市首根~最新），避免仅会话区间。"""
    t0_ms = int(time.time() * 1000)
    code = getattr(stepper, "code", None)
    k_type = getattr(stepper, "k_type", None)
    if not code or k_type is None:
        return
    refresh_reason = "noop"
    candidates: list[list[dict[str, Any]]] = [list(getattr(stepper, "kline_all", None) or [])]
    if k_type in _offline_chip_supported_ktypes() and offline_tick_files_exist_for_range(
        code, "1990-01-01", None
    ):
        try:
            candidates.insert(
                0,
                _fetch_offline_chip_kline_all(
                    code,
                    k_type,
                    autype,
                    getattr(stepper, "_session_end_date", None),
                ),
            )
            refresh_reason = "offline-full-fetch"
        except Exception as exc:
            print(f"[Chip] refresh offline full kline_all failed: {format_source_error(exc)}")
            refresh_reason = "offline-full-fetch-failed"
    wider = _pick_wider_kline_all_for_chip(candidates)
    if not wider:
        return
    cur = list(getattr(stepper, "kline_all", None) or [])
    if len(wider) <= len(cur):
        if cur and wider:
            cur_first = str(cur[0].get("t", "") or "")
            wide_first = str(wider[0].get("t", "") or "")
            if not (wide_first and cur_first and wide_first < cur_first):
                return
        elif cur:
            return
    stepper.kline_all = wider
    if (
        getattr(stepper, "data_src_used", None) == OFFLINE_INLINE_SRC
        and stepper.kline_all
        and k_type in _offline_chip_supported_ktypes()
        and offline_tick_files_exist_for_range(code, "1990-01-01", None)
    ):
        _enrich_kline_all_offline_chip_non_triangle(code, stepper.kline_all, None, k_type)
    # #region agent log
    _agent_debug_log_backend(
        "P2",
        "a_replay_trainer.py:_refresh_stepper_chip_kline_all_base",
        "刷新筹码全历史底座耗时",
        {
            "reason": refresh_reason,
            "beforeCount": len(cur),
            "afterCount": len(stepper.kline_all or []),
            "costMs": int(time.time() * 1000) - t0_ms,
        },
        run_id="perf-check",
    )
    # #endregion


def _pick_wider_kline_all_for_chip(candidates: list[list[dict[str, Any]]]) -> list[dict[str, Any]]:
    """在多个 kline_all 候选里取时间跨度更宽的一份（供筹码全历史累计）。"""
    best: list[dict[str, Any]] = []
    best_key: tuple = ("", "", 0)
    for arr in candidates:
        if not arr:
            continue
        first_t = str(arr[0].get("t", "") or "")
        last_t = str(arr[-1].get("t", "") or "")
        key = (first_t, last_t, len(arr))
        if not best:
            best, best_key = list(arr), key
            continue
        if key[2] > best_key[2]:
            best, best_key = list(arr), key
        elif key[2] == best_key[2] and key[0] and best_key[0] and key[0] < best_key[0]:
            best, best_key = list(arr), key
    return best


def _parse_bar_time_ms(t: Any) -> Optional[int]:
    """K 线时间转毫秒（与前端 chipTimeComparable 对齐）。"""
    s = str(t or "").strip()
    if not s:
        return None
    m = re.match(r"^(\d{4})/(\d{1,2})/(\d{1,2})(?:\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?", s)
    if m:
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        hh = int(m.group(4)) if m.group(4) is not None else 0
        mm = int(m.group(5)) if m.group(5) is not None else 0
        ss = int(m.group(6)) if m.group(6) is not None else 0
        return int(datetime(y, mo, d, hh, mm, ss).timestamp() * 1000)
    try:
        iso = datetime.fromisoformat(s.replace("/", "-").replace(" ", "T", 1))
        return int(iso.timestamp() * 1000)
    except ValueError:
        return None


def _session_end_ms(end_date: Optional[str]) -> Optional[int]:
    if not end_date:
        return None
    d = str(end_date).replace("/", "-").strip()[:10]
    try:
        dt = datetime.strptime(d, "%Y-%m-%d").replace(hour=23, minute=59, second=59)
        return int(dt.timestamp() * 1000)
    except ValueError:
        return None


def _kline_all_for_chip_payload(
    kline_all: list[dict[str, Any]],
    session_end_date: Optional[str],
) -> list[dict[str, Any]]:
    """
    下发给前端的筹码底座：上市首根 ~ 会话结束日（含），避免 10万+ 根撑爆 JSON。
    累计筹码仍从首根截到十字线，满足「上市日 -> 当前 K」。
    """
    if not kline_all:
        return []
    end_ms = _session_end_ms(session_end_date)
    if end_ms is None:
        return _chip_kline_all_with_x(kline_all)
    out: list[dict[str, Any]] = []
    for bar in kline_all:
        bt = _parse_bar_time_ms(bar.get("t"))
        if bt is not None and bt > end_ms:
            break
        out.append(bar)
    if not out:
        out = list(kline_all)
    return _chip_kline_all_with_x(out)


def _chip_range_text(kline_all: list[dict[str, Any]], session_begin_date: Optional[str], session_end_date: Optional[str]) -> str:
    """用于历史记录：展示「底座范围 / 用户配置范围 / 实际默认显示范围」三者关系。

    约定：
    - 底座范围：stepper.kline_all 的首尾时间（服务端内存态，可能比首包/懒加载下发更宽）
    - 用户配置范围：会话 begin_date ~ end_date（前端可配）
    - 实际默认显示范围：筹码渲染按「底座从首根开始累计」+「截至当前参考K（默认会话末根）」截断
    """
    if not kline_all:
        return "筹码范围：底座为空"
    base_a = str((kline_all[0] or {}).get("t") or "-")
    base_z = str((kline_all[-1] or {}).get("t") or "-")
    user_b = str(session_begin_date or "-")
    user_c = str(session_end_date or "-")
    # 默认参考K为会话末根（或当前可视末根），因此“实际显示”截至 C；起点仍来自底座 A。
    return f"筹码范围：底座 {base_a}~{base_z}；配置 {user_b}~{user_c}；显示(默认) {base_a}~{user_c}"


def _chip_bars_for_perf_session(
    kline_all: list[dict[str, Any]],
    chart_bars: list[dict[str, Any]],
    session_end_date: Optional[str],
) -> list[dict[str, Any]]:
    """性能引擎筹码底座：裁掉未来，并把 x 对齐主图会话轴。"""
    if not kline_all:
        return []
    session_bars = _kline_all_for_chip_payload(kline_all, session_end_date)
    if not session_bars:
        return []
    x_by_t = {str(bar.get("t", "")): int(bar.get("x", i)) for i, bar in enumerate(chart_bars or [])}
    out: list[dict[str, Any]] = []
    for i, bar in enumerate(session_bars):
        b = dict(bar)
        t = str(b.get("t", ""))
        if t in x_by_t:
            b["x"] = x_by_t[t]
        elif int(b.get("x", -1)) < 0:
            b["x"] = i
        out.append(b)
    return out


def normalize_data_form_quantity(raw: Any, total: int) -> int:
    total_n = max(1, int(total))
    try:
        q = int(raw)
    except (TypeError, ValueError):
        q = total_n
    if q < 1:
        q = 1
    if q > total_n:
        q = total_n
    return q


def normalize_data_form_quantity_alloc(raw: Any) -> str:
    """数量分配原则：front=靠前分配（余数优先给前方组）；back=靠后分配。"""
    m = str(raw or "front").strip().lower()
    if m in {"back", "rear", "后", "靠后", "靠后分配"}:
        return "back"
    return "front"


def normalize_kline_presentation_mode(raw: Any) -> str:
    """K 线图呈现：step=步进；instant=一次性呈现末根完整图。"""
    m = str(raw or "step").strip().lower()
    if m in {"instant", "oneshot", "once", "一次性", "一次性呈现"}:
        return "instant"
    return "step"


def _quantity_group_sizes(total: int, q: int, alloc: str) -> list[int]:
    """将 total 根原生 K 线划分为 q 组，返回每组根数列表。"""
    if total <= 0 or q <= 0:
        return []
    if q >= total:
        return [1] * total
    base = total // q
    rem = total % q
    if normalize_data_form_quantity_alloc(alloc) == "back":
        return [base + (rem if i == q - 1 else 0) for i in range(q)]
    # 靠前：余数 1 根依次分给最前几组（例：99/4 → 25,25,25,24）
    return [base + (1 if i < rem else 0) for i in range(q)]


def _ensure_klu_deepcopy_attrs(klus: list[Any]) -> None:
    """兼容旧会话/聚合K线：补齐 CKLine_Unit.__deepcopy__ 依赖字段。"""
    for klu in klus:
        # CKLine_Unit.__deepcopy__ 会直接访问 macd/boll，缺失会在重配时报错
        if not hasattr(klu, "macd"):
            klu.macd = None
        if not hasattr(klu, "boll"):
            klu.boll = None


def _klu_float_trade_metric(klu: Any, field: str) -> float:
    """读 K 线量额：引擎里在 trade_info.metric，不是顶层 .volume；部分封装可能直接挂属性。"""
    raw = getattr(klu, field, None)
    if raw is not None:
        return float(raw or 0.0)
    if field == DATA_FIELD.FIELD_VOLUME:
        raw_v = getattr(klu, "vol", None)
        if raw_v is not None:
            return float(raw_v or 0.0)
    ti = getattr(klu, "trade_info", None)
    if ti and getattr(ti, "metric", None):
        mv = ti.metric.get(field)
        if mv is not None:
            return float(mv or 0.0)
    return 0.0


def aggregate_klu_by_quantity(
    klus: list[Any], quantity: int, quantity_alloc: str = "front"
) -> list[Any]:
    """按数量 Q 聚合 K 线；quantity_alloc 控制余数靠前/靠后分配。"""
    _ensure_klu_deepcopy_attrs(klus)
    total = len(klus)
    if total == 0:
        return []
    q = normalize_data_form_quantity(quantity, total)
    if q >= total:
        return list(copy.deepcopy(klus))

    sizes = _quantity_group_sizes(total, q, quantity_alloc)
    out: list[Any] = []
    start = 0
    for seg_len in sizes:
        end = start + seg_len
        chunk = klus[start:end]
        start = end
        if not chunk:
            continue
        first = chunk[0]
        last = chunk[-1]
        high = max(float(getattr(k, "high", 0.0)) for k in chunk)
        low = min(float(getattr(k, "low", 0.0)) for k in chunk)
        volume = sum(_klu_float_trade_metric(k, DATA_FIELD.FIELD_VOLUME) for k in chunk)
        turnover = sum(_klu_float_trade_metric(k, DATA_FIELD.FIELD_TURNOVER) for k in chunk)
        merged = CKLine_Unit(
            {
                DATA_FIELD.FIELD_TIME: getattr(last, "time"),
                DATA_FIELD.FIELD_OPEN: float(getattr(first, "open", 0.0)),
                DATA_FIELD.FIELD_HIGH: high,
                DATA_FIELD.FIELD_LOW: low,
                DATA_FIELD.FIELD_CLOSE: float(getattr(last, "close", 0.0)),
                DATA_FIELD.FIELD_VOLUME: volume,
                DATA_FIELD.FIELD_TURNOVER: turnover,
            }
        )
        # 避免后续 ReplayChan.load 深拷贝时访问不存在属性
        merged.macd = None
        merged.boll = None
        out.append(merged)
    return out


def _bars_to_klu_list(bars: list[dict[str, Any]]) -> list[Any]:
    """离线合成 bars -> CKLine_Unit 列表。"""
    out: list[Any] = []
    for r in bars:
        klu = CKLine_Unit(
            {
                DATA_FIELD.FIELD_TIME: r["t"],
                DATA_FIELD.FIELD_OPEN: float(r["o"]),
                DATA_FIELD.FIELD_HIGH: float(r["h"]),
                DATA_FIELD.FIELD_LOW: float(r["l"]),
                DATA_FIELD.FIELD_CLOSE: float(r["c"]),
                DATA_FIELD.FIELD_VOLUME: float(r["v"]),
                DATA_FIELD.FIELD_TURNOVER: float(r["amt"]),
            }
        )
        klu.macd = None
        klu.boll = None
        out.append(klu)
    return out


def _build_tick_rows_by_bucket(
    ticks: list[tuple[CTime, float, float, str]], k_type: KL_TYPE
) -> dict[tuple, list[tuple[float, float, str]]]:
    """把分笔按目标周期分桶，保留每桶逐笔价量。"""
    from collections import defaultdict

    by_bucket: dict[tuple, list[tuple[float, float, str]]] = defaultdict(list)
    for t, price, vol, side in ticks:
        try:
            bk = _offline_chip_bar_bucket_key(t, k_type)
        except ValueError:
            continue
        by_bucket[bk].append((float(price), float(vol), str(side)))
    return by_bucket


def _aggregate_kline_dicts_by_quantity(
    bars: list[dict[str, Any]], quantity: int, quantity_alloc: str = "front"
) -> list[dict[str, Any]]:
    """数量聚合 kline_all（含 chip_tick_bins 累加）。"""
    total = len(bars)
    if total == 0:
        return []
    q = normalize_data_form_quantity(quantity, total)
    if q >= total:
        return [dict(x) for x in bars]
    sizes = _quantity_group_sizes(total, q, quantity_alloc)
    out: list[dict[str, Any]] = []
    start = 0
    for seg_len in sizes:
        end = start + seg_len
        chunk = bars[start:end]
        start = end
        if not chunk:
            continue
        merged: dict[str, Any] = {
            "t": chunk[-1].get("t"),
            "o": float(chunk[0].get("o", 0.0)),
            "h": max(float(k.get("h", 0.0)) for k in chunk),
            "l": min(float(k.get("l", 0.0)) for k in chunk),
            "c": float(chunk[-1].get("c", 0.0)),
            "v": sum(float(k.get("v", 0.0) or 0.0) for k in chunk),
        }
        from collections import defaultdict

        s_acc: dict[float, float] = defaultdict(float)
        b_acc: dict[float, float] = defaultdict(float)
        for k in chunk:
            tb = k.get("chip_tick_bins")
            if tb and isinstance(tb, dict):
                ps = tb.get("p") or []
                if not isinstance(ps, list) or not ps:
                    continue

                s_arr = tb.get("s")
                b_arr = tb.get("b")
                w_arr = tb.get("w")

                if (
                    isinstance(s_arr, list)
                    and isinstance(b_arr, list)
                    and len(s_arr) == len(ps)
                    and len(b_arr) == len(ps)
                ):
                    for p_raw, s_raw, b_raw in zip(ps, s_arr, b_arr):
                        try:
                            p = round(float(p_raw), 4)
                            s_v = float(s_raw)
                            b_v = float(b_raw)
                        except (TypeError, ValueError):
                            continue
                        if not (p > 0) or not (s_v == s_v and b_v == b_v) or (s_v <= 0 and b_v <= 0):
                            continue
                        if s_v > 0:
                            s_acc[p] += s_v
                        if b_v > 0:
                            b_acc[p] += b_v
                elif isinstance(w_arr, list) and len(w_arr) == len(ps):
                    # 兼容旧字段：无 s/b 时把总量都当作 B(右红)
                    for p_raw, w_raw in zip(ps, w_arr):
                        try:
                            p = round(float(p_raw), 4)
                            w = float(w_raw)
                        except (TypeError, ValueError):
                            continue
                        if not (p > 0) or w <= 0 or not (w == w):
                            continue
                        b_acc[p] += w

        if s_acc or b_acc:
            ps2 = sorted({*s_acc.keys(), *b_acc.keys()})
            if ps2:
                s_ws2 = [float(s_acc[p]) for p in ps2]
                b_ws2 = [float(b_acc[p]) for p in ps2]
                ws2 = [float(sv + bv) for sv, bv in zip(s_ws2, b_ws2)]
                merged["chip_tick_bins"] = {"p": ps2, "s": s_ws2, "b": b_ws2, "w": ws2}
        out.append(merged)
    return out


def build_tick_synth_session_data(
    code: str,
    k_type: KL_TYPE,
    begin_date: Optional[str],
    end_date: Optional[str],
    mode: str,
    quantity: Optional[int],
    quantity_alloc: str = "front",
    offline_data_custom: Any | None = None,
) -> tuple[list[Any], list[dict[str, Any]], int, list[Any]]:
    """
    分笔价格合成会话数据：
    - tick_traditional：分笔价格合成传统
    - tick_quantity：分笔价格合成数量
    返回 (喂入/展示用 master, kline_all, 聚合前根数, 聚合前 master)。
    """
    folder = os.path.join(_offline_root_dir(), offline_folder_from_code(code))
    if not os.path.isdir(folder):
        raise ValueError(f"未找到离线目录：{folder}")
    code6 = _strip_market_prefix(code)
    b8, e8 = _offline_date_bounds(begin_date, end_date)
    tick_paths = _offline_list_tick_paths(folder, code6, b8, e8)
    if not tick_paths:
        raise ValueError("分笔价格合成模式要求 a_Data 下存在分笔文件（当前日期区间未找到 YYYYMMDD_代码.txt）")
    tick_rows = _offline_load_tick_rows(tick_paths, offline_data_custom)
    if not tick_rows:
        raise ValueError("分笔文件在日期区间内无有效成交行")
    ticks = rows_to_legacy_ticks(tick_rows)

    rows_1m = _offline_ticks_to_1m_from_rows(tick_rows)
    bars = _offline_rows_to_ktype(rows_1m, k_type)
    if not bars:
        raise ValueError("分笔价格合成后 K 线为空")

    by_bucket = _build_tick_rows_by_bucket(ticks, k_type)
    kline_all = serialize_klu_iter(_bars_to_klu_list(bars))
    for bar in kline_all:
        ct = _parse_kline_bar_ctime(str(bar.get("t", "")))
        if ct is None:
            continue
        try:
            bk = _offline_chip_bar_bucket_key(ct, k_type)
        except ValueError:
            continue
        rows = by_bucket.get(bk, [])
        if not rows:
            continue
        ps, s_ws, b_ws = _fold_price_side_vols(rows)
        if ps:
            ws = [float(s_ws[i] + b_ws[i]) for i in range(len(ps))]
            bar["chip_tick_bins"] = {"p": ps, "s": s_ws, "b": b_ws, "w": ws}

    # 数量聚合前根数：供 raw_kline_count / 前端数量上限（勿用聚合后根数）
    pre_agg_count = len(kline_all)
    pre_agg_master = _bars_to_klu_list(
        [
            {
                "t": _parse_kline_bar_ctime(str(k.get("t", ""))),
                "o": k.get("o", 0.0),
                "h": k.get("h", 0.0),
                "l": k.get("l", 0.0),
                "c": k.get("c", 0.0),
                "v": k.get("v", 0.0),
                "amt": float(k.get("amt", 0.0) or 0.0),
            }
            for k in kline_all
            if _parse_kline_bar_ctime(str(k.get("t", ""))) is not None
        ]
    )
    if mode == "tick_quantity":
        q = normalize_data_form_quantity(quantity, pre_agg_count)
        kline_all = _aggregate_kline_dicts_by_quantity(kline_all, q, quantity_alloc)

    replay_klus_master = _bars_to_klu_list(
        [
            {
                "t": _parse_kline_bar_ctime(str(k.get("t", ""))),
                "o": k.get("o", 0.0),
                "h": k.get("h", 0.0),
                "l": k.get("l", 0.0),
                "c": k.get("c", 0.0),
                "v": k.get("v", 0.0),
                "amt": float(k.get("amt", 0.0) or 0.0),
            }
            for k in kline_all
            if _parse_kline_bar_ctime(str(k.get("t", ""))) is not None
        ]
    )
    if not replay_klus_master:
        raise ValueError("分笔价格合成后会话 K 线为空")
    return replay_klus_master, kline_all, pre_agg_count, pre_agg_master


def normalize_chan_algo(raw: Any) -> str:
    text = str(raw or CHAN_ALGO_CLASSIC).strip().lower()
    return CHAN_ALGO_NEW if text == CHAN_ALGO_NEW else CHAN_ALGO_CLASSIC


def data_source_label(data_src: Any) -> str:
    """统一用 DATA_SOURCE_LABELS 解析，避免遗漏 inline 源。"""
    if isinstance(data_src, DATA_SRC):
        return DATA_SOURCE_LABELS.get(data_src, data_src.name)
    return DATA_SOURCE_LABELS.get(data_src, str(data_src))


def create_stock_api_instance(data_src: Any, code: str, begin_date: Optional[str], end_date: Optional[str], autype: AUTYPE, k_type: Optional[KL_TYPE] = None) -> CCommonStockApi:
    api_cls = get_stock_api_cls(data_src)
    safe_api_do_init(api_cls, data_src)
    try:
        return api_cls(code=code, k_type=k_type or KL_TYPE.K_DAY, begin_date=begin_date, end_date=end_date, autype=autype)
    except Exception:
        api_cls.do_close()
        raise


def format_source_error(exc: Exception) -> str:
    text = str(exc or exc.__class__.__name__).strip()
    if not text:
        text = exc.__class__.__name__
    return " ".join(text.split())


def _is_baostock_source(data_src: Any) -> bool:
    return data_src == DATA_SRC.BAO_STOCK


def _is_baostock_network_error(exc: Exception) -> bool:
    """识别 BaoStock 常见网络故障关键字。"""
    low = str(exc or "").lower()
    return any(
        key in low
        for key in (
            "10057",  # WinError 10057: socket 未连接
            "网络接收错误",
            "接收数据异常",
            "服务器连接失败",
            "network",
            "connection",
            "socket",
            "timed out",
            "timeout",
        )
    )


def _baostock_cooldown_guard() -> None:
    """冷却期内直接失败，避免同类网络错误反复刷屏。"""
    global _BAOSTOCK_COOLDOWN_UNTIL
    if _BAOSTOCK_COOLDOWN_UNTIL is None:
        return
    now = datetime.now()
    if now >= _BAOSTOCK_COOLDOWN_UNTIL:
        _BAOSTOCK_COOLDOWN_UNTIL = None
        return
    left = int((_BAOSTOCK_COOLDOWN_UNTIL - now).total_seconds())
    raise RuntimeError(f"BaoStock 网络连接异常，冷却中（剩余约 {max(left, 1)} 秒）")


def _mark_baostock_failure(exc: Exception, cooldown_sec: int = 90) -> None:
    """命中网络类故障后进入短冷却，减少重复初始化与日志噪音。"""
    global _BAOSTOCK_COOLDOWN_UNTIL, _BAOSTOCK_LAST_ERROR
    if not _is_baostock_network_error(exc):
        return
    _BAOSTOCK_LAST_ERROR = format_source_error(exc)
    _BAOSTOCK_COOLDOWN_UNTIL = datetime.now() + timedelta(seconds=max(10, int(cooldown_sec)))


def safe_api_do_init(api_cls: Any, data_src: Any) -> None:
    """统一数据源初始化；BaoStock 增加重置与一次重试。"""
    if not _is_baostock_source(data_src):
        api_cls.do_init()
        return

    _baostock_cooldown_guard()
    # 先尝试清理残留连接状态（忽略异常）
    try:
        api_cls.do_close()
    except Exception:
        pass
    try:
        api_cls.do_init()
    except Exception as first_exc:
        _mark_baostock_failure(first_exc)
        # 轻量重试一次，处理临时连接抖动
        try:
            api_cls.do_close()
        except Exception:
            pass
        time.sleep(0.2)
        try:
            api_cls.do_init()
        except Exception as second_exc:
            _mark_baostock_failure(second_exc)
            raise


class OfflineDataConfirmRequired(Exception):
    """在线源失败后、即将尝试离线源前，交给前端 confirm 的专用异常。"""

    def __init__(self, display_code: str, failed_label: str, reason_tag: str, reason_detail: str) -> None:
        self.display_code = display_code
        self.failed_label = failed_label
        self.reason_tag = reason_tag
        self.reason_detail = reason_detail
        super().__init__(reason_detail)


def classify_fetch_error_tag(exc: Exception) -> str:
    """将异常归类为简短中文桶，用于弹窗【原因为 xxx】。"""
    low = str(exc).lower()
    cls_name = exc.__class__.__name__.lower()
    if isinstance(exc, (TimeoutError, ConnectionError, OSError)):
        if "timed out" in low or "timeout" in cls_name:
            return "网络问题"
        if any(x in low for x in ("connection", "network", "resolve", "getaddrinfo", "10060", "10054")):
            return "网络问题"
    if any(x in low for x in ("connection aborted", "remote end closed", "ssl", "certificate", "403", "404", "502", "503")):
        return "网络问题"
    if "网络" in str(exc) or "连接" in str(exc):
        return "网络问题"
    return "数据源异常"


def _offline_root_dir() -> str:
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "a_Data")


def offline_folder_from_code(code: str) -> str:
    """证券代码 -> a_Data 子目录名：纯 6 位数字（与分笔文件名 YYYYMMDD_xxxxxx.txt 后缀一致）。"""
    sym = str(_strip_market_prefix(code or "")).strip()
    digits = "".join(ch for ch in sym if ch.isdigit())
    if len(digits) >= 6:
        return digits[:6]
    if digits:
        return digits.zfill(6)
    # 无数字时兜底，避免非法路径
    return "000000"


def _offline_date_bounds(begin_date: Optional[str], end_date: Optional[str]) -> tuple[int, int]:
    """返回 YYYYMMDD 整数闭区间，便于与分笔文件名比较。"""
    b = (begin_date or "1990-01-01").replace("/", "-").strip()
    e = (end_date or "2099-12-31").replace("/", "-").strip()
    b8 = int(b[:4] + b[5:7] + b[8:10]) if len(b) >= 10 else 19900101
    e8 = int(e[:4] + e[5:7] + e[8:10]) if len(e) >= 10 else 20991231
    return b8, e8


def offline_bundle_exists(code: str, begin_date: Optional[str], end_date: Optional[str]) -> bool:
    """会话加载前探测：a_Data/六位代码/ 下日期闭区间内是否存在分笔文件。"""
    folder = os.path.join(_offline_root_dir(), offline_folder_from_code(code))
    if not os.path.isdir(folder):
        return False
    code6 = _strip_market_prefix(code)
    b8, e8 = _offline_date_bounds(begin_date, end_date)
    return len(_offline_list_tick_paths(folder, code6, b8, e8)) > 0


def offline_tick_files_exist_for_range(code: str, begin_date: Optional[str], end_date: Optional[str]) -> bool:
    """指定日期闭区间内是否存在可分笔文件（与 offline_bundle_exists 判定一致）。"""
    folder = os.path.join(_offline_root_dir(), offline_folder_from_code(code))
    if not os.path.isdir(folder):
        return False
    code6 = _strip_market_prefix(code)
    b8, e8 = _offline_date_bounds(begin_date, end_date)
    return len(_offline_list_tick_paths(folder, code6, b8, e8)) > 0


def _offline_chip_supported_ktypes() -> frozenset:
    """离线合成支持的周期：均可写 chip_tick_bins，避免前端三角分摊。"""
    return frozenset(
        {
            KL_TYPE.K_1M,
            KL_TYPE.K_3M,
            KL_TYPE.K_5M,
            KL_TYPE.K_15M,
            KL_TYPE.K_30M,
            KL_TYPE.K_60M,
            KL_TYPE.K_DAY,
            KL_TYPE.K_WEEK,
            KL_TYPE.K_MON,
            KL_TYPE.K_QUARTER,
            KL_TYPE.K_YEAR,
        }
    )


def _parse_kline_bar_ctime(bar_t: str) -> Optional[CTime]:
    """解析 serialize_klu_iter 的时间串（与 CTime.to_str 一致：YYYY/MM/DD 或带 HH:MM）。"""
    s = str(bar_t or "").strip()
    if len(s) < 10 or s[4] != "/" or s[7] != "/":
        return None
    try:
        y, mo, d = int(s[0:4]), int(s[5:7]), int(s[8:10])
    except (ValueError, TypeError):
        return None
    if len(s) >= 16 and s[10] == " ":
        tail = s[11:].strip()
        if ":" in tail:
            a, b = tail.split(":", 1)
            try:
                hh = int(a)
                mm = int(b[:2]) if len(b) >= 2 else 0
            except (ValueError, TypeError):
                return CTime(y, mo, d, 0, 0, auto=False)
            return CTime(y, mo, d, hh, mm, auto=False)
    return CTime(y, mo, d, 0, 0, auto=False)


def _offline_chip_bar_bucket_key(ct: CTime, k_type: KL_TYPE) -> tuple:
    """与 Offline 合成 K 的分桶一致：分笔时刻归入对应周期 K 根。"""
    from datetime import date as _date

    if k_type == KL_TYPE.K_DAY:
        return ("d", ct.year, ct.month, ct.day)
    minute_like = {
        KL_TYPE.K_1M,
        KL_TYPE.K_3M,
        KL_TYPE.K_5M,
        KL_TYPE.K_15M,
        KL_TYPE.K_30M,
        KL_TYPE.K_60M,
    }
    if k_type in minute_like:
        pm = _offline_kl_minutes(k_type)
        slot = (ct.hour * 60 + ct.minute) // pm
        return ("m", ct.year, ct.month, ct.day, slot)
    if k_type == KL_TYPE.K_WEEK:
        iy, iw, _ = _date(ct.year, ct.month, ct.day).isocalendar()
        return ("w", iy, iw)
    if k_type == KL_TYPE.K_MON:
        return ("mo", ct.year, ct.month)
    if k_type == KL_TYPE.K_QUARTER:
        q = (ct.month - 1) // 3 + 1
        return ("q", ct.year, q)
    if k_type == KL_TYPE.K_YEAR:
        return ("y", ct.year)
    raise ValueError(f"离线筹码分桶不支持的周期: {k_type}")


def _fold_price_vols(rows: list[tuple[float, float]]) -> tuple[list[float], list[float]]:
    from collections import defaultdict

    pr_acc: dict[float, float] = defaultdict(float)
    for p, v in rows:
        if v <= 0 or not (p > 0) or not (v == v):
            continue
        rp = round(float(p), 4)
        pr_acc[rp] += float(v)
    if not pr_acc:
        return [], []
    ps = sorted(pr_acc.keys())
    ws = [float(pr_acc[p]) for p in ps]
    return ps, ws


def _fold_price_side_vols(
    rows: list[tuple[float, float, str]],
) -> tuple[list[float], list[float], list[float]]:
    """
    将分笔按价位累计，拆成两侧：
    - 左侧绿色 S
    - 右侧红色 B
    """
    from collections import defaultdict

    pr_acc_s: dict[float, float] = defaultdict(float)
    pr_acc_b: dict[float, float] = defaultdict(float)
    for p, v, side in rows:
        if v <= 0 or not (p > 0) or not (v == v):
            continue
        rp = round(float(p), 4)
        s = str(side).strip().upper()
        if s == "S":
            pr_acc_s[rp] += float(v)
        else:
            # 方向缺失/异常 -> 统一当作 B(右红)
            pr_acc_b[rp] += float(v)

    ps = sorted(set(pr_acc_s.keys()) | set(pr_acc_b.keys()))
    if not ps:
        return [], [], []
    s_ws = [float(pr_acc_s[p]) for p in ps]
    b_ws = [float(pr_acc_b[p]) for p in ps]
    return ps, s_ws, b_ws


def _enrich_kline_all_offline_chip_non_triangle(
    code: str, kline_all: list[dict[str, Any]], end_date: Optional[str], k_type: KL_TYPE
) -> None:
    """
    离线任意支持周期：写入 chip_tick_bins（分笔价量直加），前端不走 OHLC 三角分摊。
    """
    from collections import defaultdict

    if k_type not in _offline_chip_supported_ktypes():
        return
    folder = os.path.join(_offline_root_dir(), offline_folder_from_code(code))
    if not kline_all or not os.path.isdir(folder):
        return
    code6 = _strip_market_prefix(code)
    b8, e8 = _offline_date_bounds("1990-01-01", end_date)
    key_to_rows: dict[tuple, list[tuple[float, float, str]]] = defaultdict(list)

    paths = _offline_list_tick_paths(folder, code6, b8, e8)
    if not paths:
        return
    ticks = _offline_load_ticks(paths)
    if not ticks:
        return
    for t, price, vol, side in ticks:
        try:
            bk = _offline_chip_bar_bucket_key(t, k_type)
        except ValueError:
            continue
        key_to_rows[bk].append((float(price), float(vol), str(side)))

    if not key_to_rows:
        return
    key_to_bins: dict[tuple, tuple[list[float], list[float], list[float]]] = {}
    for bk, arr in key_to_rows.items():
        ps, s_ws, b_ws = _fold_price_side_vols(arr)
        if ps:
            key_to_bins[bk] = (ps, s_ws, b_ws)

    for bar in kline_all:
        ct = _parse_kline_bar_ctime(str(bar.get("t", "")))
        if ct is None:
            continue
        try:
            bk = _offline_chip_bar_bucket_key(ct, k_type)
        except ValueError:
            continue
        tup = key_to_bins.get(bk)
        if not tup or not tup[0]:
            continue
        ps, s_ws, b_ws = tup
        ws = [float(s_ws[i] + b_ws[i]) for i in range(len(ps))]
        bar["chip_tick_bins"] = {"p": ps, "s": s_ws, "b": b_ws, "w": ws}

def _strip_market_prefix(code: str) -> str:
    text = str(code or "").strip().lower()
    if text.startswith("sh.") or text.startswith("sz.") or text.startswith("bj."):
        return text.split(".", 1)[1]
    if text.startswith("sh") or text.startswith("sz") or text.startswith("bj"):
        return text[2:]
    return text


def _detect_market(code: str) -> str:
    symbol = _strip_market_prefix(code)
    return "sh" if symbol.startswith(("5", "6", "9")) else "sz"


def _to_tencent_symbol(code: str) -> str:
    symbol = _strip_market_prefix(code)
    return f"{_detect_market(symbol)}{symbol}"


def _to_eastmoney_secid(code: str) -> str:
    symbol = _strip_market_prefix(code)
    market_id = "1" if _detect_market(symbol) == "sh" else "0"
    return f"{market_id}.{symbol}"


def _parse_inline_datetime(value: Any, *, default_time: tuple[int, int] = (0, 0)) -> tuple[CTime, datetime]:
    """解析常见日期/时间格式，统一用于线上数据源。"""
    if isinstance(value, pd.Timestamp):
        dt = value.to_pydatetime()
        return CTime(dt.year, dt.month, dt.day, dt.hour, dt.minute), dt
    text = str(value or "").strip().replace("/", "-")
    if re.match(r"^\d{8}$", text):
        dt = datetime(int(text[:4]), int(text[4:6]), int(text[6:8]), default_time[0], default_time[1])
        return CTime(dt.year, dt.month, dt.day, dt.hour, dt.minute), dt
    if re.match(r"^\d{4}-\d{2}-\d{2}$", text):
        dt = datetime(int(text[:4]), int(text[5:7]), int(text[8:10]), default_time[0], default_time[1])
        return CTime(dt.year, dt.month, dt.day, dt.hour, dt.minute), dt
    if re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}", text):
        dt = datetime.strptime(text[:16], "%Y-%m-%d %H:%M")
        return CTime(dt.year, dt.month, dt.day, dt.hour, dt.minute), dt
    if re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", text):
        dt = datetime.strptime(text[:19], "%Y-%m-%d %H:%M:%S")
        return CTime(dt.year, dt.month, dt.day, dt.hour, dt.minute), dt
    raise ValueError(f"unknown date value: {value}")


def _request_json_with_headers(url: str, *, params: Optional[dict[str, Any]] = None) -> Any:
    """统一请求 JSON，给线上源一个稳定 UA。"""
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/136.0.0.0 Safari/537.36"
        )
    }
    resp = requests.get(url, params=params, headers=headers, timeout=20)
    resp.raise_for_status()
    return resp.json()


def _parse_inline_date(value) -> CTime:
    if isinstance(value, pd.Timestamp):
        return CTime(value.year, value.month, value.day, 0, 0)
    text = str(value or "").strip()
    if len(text) >= 10 and "-" in text:
        return CTime(int(text[:4]), int(text[5:7]), int(text[8:10]), 0, 0)
    if len(text) >= 8 and text[:8].isdigit():
        return CTime(int(text[:4]), int(text[4:6]), int(text[6:8]), 0, 0)
    raise ValueError(f"unknown date format: {value}")


def _parse_trade_date_8(value: str) -> CTime:
    text = str(value or "").strip()
    if len(text) != 8 or not text.isdigit():
        raise ValueError(f"invalid trade date: {value}")
    return CTime(int(text[:4]), int(text[4:6]), int(text[6:8]), 0, 0)


def _k_type_label_cn(k_type: KL_TYPE) -> str:
    """周期中文标签，用于错误提示。"""
    mapping = {
        KL_TYPE.K_1M: "1分钟",
        KL_TYPE.K_3M: "3分钟",
        KL_TYPE.K_5M: "5分钟",
        KL_TYPE.K_15M: "15分钟",
        KL_TYPE.K_30M: "30分钟",
        KL_TYPE.K_60M: "60分钟",
        KL_TYPE.K_DAY: "日线",
        KL_TYPE.K_WEEK: "周线",
        KL_TYPE.K_MON: "月线",
        KL_TYPE.K_QUARTER: "季线",
        KL_TYPE.K_YEAR: "年线",
    }
    return mapping.get(k_type, str(k_type))


class CAkshareInline(CCommonStockApi):
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.symbol = _strip_market_prefix(code)
        super(CAkshareInline, self).__init__(code, k_type, begin_date, end_date, autype)

    def get_kl_data(self):
        adjust_map = {AUTYPE.QFQ: "qfq", AUTYPE.HFQ: "hfq", AUTYPE.NONE: ""}
        # AKShare stock_zh_a_hist 支持的周期
        period_map = {
            KL_TYPE.K_1M: "1min",
            KL_TYPE.K_5M: "5min",
            KL_TYPE.K_15M: "15min",
            KL_TYPE.K_30M: "30min",
            KL_TYPE.K_60M: "60min",
            KL_TYPE.K_DAY: "daily",
            KL_TYPE.K_WEEK: "weekly",
            KL_TYPE.K_MON: "monthly",
            KL_TYPE.K_3M: "3min",
        }
        if self.k_type not in period_map:
            raise ValueError(f"AKShare 暂不支持 {self.k_type} 级别，仅支持1/5/15/30/60分钟、日线、周线、月线、3分钟")
        
        start_date = (self.begin_date or "1990-01-01").replace("-", "")
        end_date = (self.end_date or "2099-12-31").replace("-", "")
        
        # 指数数据仅支持日线
        if not self.is_stock:
            if self.k_type != KL_TYPE.K_DAY:
                raise ValueError(f"指数数据仅支持日线级别，当前选择：{self.k_type}")
            market = "sh" if str(self.code).lower().startswith("sh") else "sz"
            raw_df = ak.stock_zh_index_daily(symbol=f"{market}{self.symbol}")
            df = raw_df.rename(columns={"date": "日期", "open": "开盘", "high": "最高", "low": "最低", "close": "收盘", "volume": "成交量", "amount": "成交额"})
            df["日期"] = df["日期"].astype(str).str.replace("-", "", regex=False)
            df = df[(df["日期"] >= start_date) & (df["日期"] <= end_date)]
        else:
            df = ak.stock_zh_a_hist(
                symbol=self.symbol,
                period=period_map[self.k_type],
                start_date=start_date,
                end_date=end_date,
                adjust=adjust_map.get(self.autype, "qfq"),
            )
        
        if df is None or df.empty:
            return
        
        for _, row in df.iterrows():
            item = {
                DATA_FIELD.FIELD_TIME: _parse_inline_date(row["日期"]),
                DATA_FIELD.FIELD_OPEN: str2float(row["开盘"]),
                DATA_FIELD.FIELD_HIGH: str2float(row["最高"]),
                DATA_FIELD.FIELD_LOW: str2float(row["最低"]),
                DATA_FIELD.FIELD_CLOSE: str2float(row["收盘"]),
                DATA_FIELD.FIELD_VOLUME: str2float(row.get("成交量", 0)),
                DATA_FIELD.FIELD_TURNOVER: str2float(row.get("成交额", 0)),
            }
            yield CKLine_Unit(item)

    def SetBasciInfo(self):
        self.name = self.code
        raw = str(self.code or "").strip().lower()
        if raw.startswith(("sh.", "sz.")):
            symbol = raw.split(".", 1)[1]
            self.is_stock = not (symbol.startswith("000") or symbol.startswith("399"))
        else:
            self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass


class CAkTxInline(CCommonStockApi):
    """AKShare 腾讯历史接口封装：作为 AKShare 的补充回退源。"""

    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.symbol = _strip_market_prefix(code)
        super(CAkTxInline, self).__init__(code, k_type, begin_date, end_date, autype)

    def get_kl_data(self):
        period_map = {
            KL_TYPE.K_DAY: "day",
            KL_TYPE.K_WEEK: "week",
            KL_TYPE.K_MON: "month",
        }
        if self.k_type not in period_map:
            raise ValueError(f"AKShare-腾讯历史暂不支持 {self.k_type} 级别")
        start_date = (self.begin_date or "1990-01-01").replace("-", "")
        end_date = (self.end_date or "2099-12-31").replace("-", "")
        adjust = "qfq" if self.autype == AUTYPE.QFQ else ("hfq" if self.autype == AUTYPE.HFQ else "")
        symbol = ("sh" if str(self.code).lower().startswith("sh.") else ("sz" if str(self.code).lower().startswith("sz.") else ("sh" if self.symbol.startswith("6") else "sz")) ) + self.symbol
        try:
            df = ak.stock_zh_a_hist_tx(symbol=symbol, start_date=start_date, end_date=end_date, adjust=adjust)
        except Exception as e:
            if isinstance(e, IndexError):
                raise RuntimeError("AKShare-腾讯历史返回空结构（该标的可能无可用历史）")
            raise RuntimeError(f"AKShare-腾讯历史获取数据失败: {e}")
        if df is None or df.empty:
            return

        # 兼容列名差异：优先英文列（AKShare 常见）
        col_date = "date" if "date" in df.columns else ("日期" if "日期" in df.columns else None)
        col_open = "open" if "open" in df.columns else "开盘"
        col_high = "high" if "high" in df.columns else "最高"
        col_low = "low" if "low" in df.columns else "最低"
        col_close = "close" if "close" in df.columns else "收盘"
        col_vol = "volume" if "volume" in df.columns else "成交量"
        col_amt = "amount" if "amount" in df.columns else "成交额"
        for _, row in df.iterrows():
            raw_t = row.get(col_date) if col_date else None
            if raw_t is None:
                continue
            item = {
                DATA_FIELD.FIELD_TIME: _parse_inline_date(raw_t),
                DATA_FIELD.FIELD_OPEN: str2float(row.get(col_open, 0)),
                DATA_FIELD.FIELD_HIGH: str2float(row.get(col_high, 0)),
                DATA_FIELD.FIELD_LOW: str2float(row.get(col_low, 0)),
                DATA_FIELD.FIELD_CLOSE: str2float(row.get(col_close, 0)),
                DATA_FIELD.FIELD_VOLUME: str2float(row.get(col_vol, 0)),
                DATA_FIELD.FIELD_TURNOVER: str2float(row.get(col_amt, 0)),
            }
            yield CKLine_Unit(item)

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass


class CTushareInline(CCommonStockApi):
    pro = None
    token = None

    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.ts_code = self._to_ts_code(code)
        super(CTushareInline, self).__init__(code, k_type, begin_date, end_date, autype)

    @staticmethod
    def _to_ts_code(code: str) -> str:
        raw = str(code or "").strip().lower()
        if raw.startswith("sh.") or raw.startswith("sz."):
            market = raw[:2].upper()
            symbol = raw[3:]
            return f"{symbol}.{market}"
        if len(raw) == 6 and raw.isdigit():
            return f"{raw}.SH" if raw.startswith("6") else f"{raw}.SZ"
        raise ValueError(f"unsupported tushare code: {code}")

    @classmethod
    def do_init(cls):
        token = DEFAULT_TUSHARE_TOKEN
        if not token:
            raise RuntimeError("未配置 Tushare Token")
        if cls.pro is None or cls.token != token:
            ts.set_token(token)
            cls.pro = ts.pro_api(token)
            cls.token = token

    @classmethod
    def do_close(cls):
        cls.pro = None
        cls.token = None

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    def get_kl_data(self):
        # Tushare 支持 1/5/15/30/60分钟、日、周、月、季、年线
        self.do_init()
        if self.pro is None:
            raise RuntimeError("Tushare Pro 未初始化")
        start_date = (self.begin_date or "1990-01-01").replace("-", "")
        end_date = (self.end_date or "2099-12-31").replace("-", "")
        freq_map = {
            KL_TYPE.K_1M: "1MIN",
            KL_TYPE.K_5M: "5MIN",
            KL_TYPE.K_15M: "15MIN",
            KL_TYPE.K_30M: "30MIN",
            KL_TYPE.K_60M: "60MIN",
            KL_TYPE.K_DAY: "D",
            KL_TYPE.K_WEEK: "W",
            KL_TYPE.K_MON: "M",
            KL_TYPE.K_3M: "3MIN",
            KL_TYPE.K_QUARTER: "Q",
            KL_TYPE.K_YEAR: "Y",
        }
        adj_map = {AUTYPE.QFQ: "qfq", AUTYPE.HFQ: "hfq", AUTYPE.NONE: None}
        df = ts.pro_bar(
            ts_code=self.ts_code,
            adj=adj_map.get(self.autype),
            freq=freq_map[self.k_type],
            start_date=start_date,
            end_date=end_date,
        )
        if df is None or df.empty:
            return
        df = df.sort_values("trade_date", ascending=True)
        for _, row in df.iterrows():
            item = {
                DATA_FIELD.FIELD_TIME: _parse_trade_date_8(row["trade_date"]),
                DATA_FIELD.FIELD_OPEN: str2float(row["open"]),
                DATA_FIELD.FIELD_HIGH: str2float(row["high"]),
                DATA_FIELD.FIELD_LOW: str2float(row["low"]),
                DATA_FIELD.FIELD_CLOSE: str2float(row["close"]),
                DATA_FIELD.FIELD_VOLUME: str2float(row.get("vol", 0)),
                DATA_FIELD.FIELD_TURNOVER: str2float(row.get("amount", 0)),
            }
            yield CKLine_Unit(item)


class CAshareInline(CCommonStockApi):
    """使用 Ashare 库获取K线数据"""
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.symbol = _strip_market_prefix(code)
        super(CAshareInline, self).__init__(code, k_type, begin_date, end_date, autype)

    def get_kl_data(self):
        if not HAS_ASHARE:
            raise RuntimeError(_OPT_DEP_HINT_ASHARE)
        # Ashare/ashares 周期映射（ashares 常见写法是 1d/1w/1M）
        period_map = {
            KL_TYPE.K_1M: "1m",
            KL_TYPE.K_5M: "5m",
            KL_TYPE.K_15M: "15m",
            KL_TYPE.K_30M: "30m",
            KL_TYPE.K_60M: "60m",
            KL_TYPE.K_DAY: "1d",
            KL_TYPE.K_WEEK: "1w",
            KL_TYPE.K_MON: "1M",
        }
        if self.k_type not in period_map:
            raise ValueError(f"Ashare 暂不支持 {self.k_type} 级别")
        
        start_date = (self.begin_date or "1990-01-01").replace("/", "-")
        end_date = (self.end_date or "2099-12-31").replace("/", "-")
        # 兼容两类签名：
        # 1) get_price(code, start_date=..., end_date=..., frequency=..., fq=...)
        # 2) get_price(code, end_date='', count=10, frequency='1d', fields=[])
        try:
            get_price = ASHARE_MOD.get_price
            sig = inspect.signature(get_price)
            params = set(sig.parameters.keys())
            call_kwargs: dict[str, Any] = {"frequency": period_map[self.k_type]}
            if "start_date" in params:
                call_kwargs["start_date"] = start_date
            if "end_date" in params:
                call_kwargs["end_date"] = end_date
            if "fq" in params:
                call_kwargs["fq"] = self.autype.name.lower() if self.autype != AUTYPE.NONE else None
            if "count" in params and "start_date" not in params:
                call_kwargs["count"] = 10000
            df = get_price(self.symbol, **call_kwargs)
        except Exception as e:
            raise RuntimeError(f"Ashare 获取数据失败: {e}")
        
        if df is None or df.empty:
            return
        
        local_df = df.copy()
        if "date" not in local_df.columns and "time" not in local_df.columns:
            local_df["date"] = local_df.index
        s0 = start_date[:10]
        s1 = end_date[:10]
        for _, row in local_df.iterrows():
            dt_raw = row.get("date") if "date" in local_df.columns else row.get("time")
            ct = _parse_inline_date(dt_raw)
            ds = ct.toDateStr("-")
            if len(s0) == 10 and ds < s0:
                continue
            if len(s1) == 10 and ds > s1:
                continue
            item = {
                DATA_FIELD.FIELD_TIME: ct,
                DATA_FIELD.FIELD_OPEN: str2float(row.get("open", 0)),
                DATA_FIELD.FIELD_HIGH: str2float(row.get("high", 0)),
                DATA_FIELD.FIELD_LOW: str2float(row.get("low", 0)),
                DATA_FIELD.FIELD_CLOSE: str2float(row.get("close", 0)),
                DATA_FIELD.FIELD_VOLUME: str2float(row.get("volume", 0)),
                DATA_FIELD.FIELD_TURNOVER: str2float(row.get("amount", 0)),
            }
            yield CKLine_Unit(item)

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass


class CADataInline(CCommonStockApi):
    """使用 AData 库获取K线数据"""
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.symbol = _strip_market_prefix(code)
        super(CADataInline, self).__init__(code, k_type, begin_date, end_date, autype)

    def get_kl_data(self):
        if not HAS_ADATA:
            raise RuntimeError(_OPT_DEP_HINT_ADATA)
        period_map = {
            KL_TYPE.K_DAY: 1,
            KL_TYPE.K_WEEK: 2,
            KL_TYPE.K_MON: 3,
            KL_TYPE.K_QUARTER: 4,
            KL_TYPE.K_5M: 5,
            KL_TYPE.K_15M: 15,
            KL_TYPE.K_30M: 30,
            KL_TYPE.K_60M: 60,
        }
        minute_bar_only = self.k_type == KL_TYPE.K_1M
        start_date = (self.begin_date or "1990-01-01").replace("/", "-")
        end_date = (self.end_date or "2099-12-31").replace("/", "-")
        adj_val = 1 if self.autype == AUTYPE.QFQ else (2 if self.autype == AUTYPE.HFQ else 0)

        try:
            # 优先走新版 market.get_market，失败再回退旧 get_stock_price。
            if minute_bar_only:
                get_market_min = getattr(getattr(adata, "stock"), "market").get_market_min
                df = get_market_min(self.symbol)
            else:
                if self.k_type not in period_map:
                    raise ValueError(f"AData 暂不支持 {_k_type_label_cn(self.k_type)}")
                get_market = getattr(getattr(adata, "stock"), "market").get_market
                df = get_market(
                    self.symbol,
                    start_date=start_date,
                    end_date=end_date,
                    k_type=period_map[self.k_type],
                    adjust_type=adj_val,
                )
        except Exception as e:
            try:
                from adata import get_stock_price  # type: ignore
                if self.k_type == KL_TYPE.K_DAY:
                    freq = "d"
                elif self.k_type == KL_TYPE.K_WEEK:
                    freq = "w"
                elif self.k_type == KL_TYPE.K_MON:
                    freq = "m"
                else:
                    raise RuntimeError(f"AData 获取数据失败: {e}")
                df = get_stock_price(
                    code=self.symbol,
                    start_date=start_date.replace("-", ""),
                    end_date=end_date.replace("-", ""),
                    freq=freq,
                    adj="qfq" if self.autype == AUTYPE.QFQ else ("hfq" if self.autype == AUTYPE.HFQ else "none"),
                )
            except Exception:
                raise RuntimeError(f"AData 获取数据失败: {e}")

        if df is None or df.empty:
            return

        col_date = "trade_time" if "trade_time" in df.columns else ("trade_date" if "trade_date" in df.columns else ("date" if "date" in df.columns else None))
        col_open = "open" if "open" in df.columns else "开盘"
        col_high = "high" if "high" in df.columns else "最高"
        col_low = "low" if "low" in df.columns else "最低"
        col_close = "close" if "close" in df.columns else "收盘"
        col_vol = "volume" if "volume" in df.columns else ("vol" if "vol" in df.columns else "成交量")
        col_amt = "amount" if "amount" in df.columns else "成交额"
        for _, row in df.iterrows():
            raw_time = row.get(col_date) if col_date else (row.get("time") or row.get("date"))
            if minute_bar_only and str(raw_time or "").strip() and not re.search(r"\d{4}-\d{2}-\d{2}", str(raw_time)):
                # get_market_min 仅给时分，这里拼接结束日（或今天）补全日期。
                day = (self.end_date or datetime.now().strftime("%Y-%m-%d")).replace("/", "-")
                raw_time = f"{day} {str(raw_time).strip()[:5]}"
            ct, _ = _parse_inline_datetime(raw_time)
            item = {
                DATA_FIELD.FIELD_TIME: ct,
                DATA_FIELD.FIELD_OPEN: str2float(row.get(col_open, 0)),
                DATA_FIELD.FIELD_HIGH: str2float(row.get(col_high, 0)),
                DATA_FIELD.FIELD_LOW: str2float(row.get(col_low, 0)),
                DATA_FIELD.FIELD_CLOSE: str2float(row.get(col_close, 0)),
                DATA_FIELD.FIELD_VOLUME: str2float(row.get(col_vol, 0)),
                DATA_FIELD.FIELD_TURNOVER: str2float(row.get(col_amt, 0)),
            }
            yield CKLine_Unit(item)

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass


class CPytdxInline(CCommonStockApi):
    """使用 pytdx 库获取K线数据"""
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        # pytdx 使用纯 6 位代码，避免 sh./sz. 前缀导致市场判断错误
        self.symbol = _strip_market_prefix(code)
        super(CPytdxInline, self).__init__(code, k_type, begin_date, end_date, autype)

    def get_kl_data(self):
        if not HAS_PYTDX:
            raise RuntimeError(_OPT_DEP_HINT_PYTDX)
        
        period_map = {
            KL_TYPE.K_1M: 8,   # 1分钟
            KL_TYPE.K_5M: 0,   # 5分钟
            KL_TYPE.K_15M: 1,  # 15分钟
            KL_TYPE.K_30M: 2,  # 30分钟
            KL_TYPE.K_60M: 3,  # 60分钟
            KL_TYPE.K_DAY: 9,   # 日线
            KL_TYPE.K_WEEK: 5, # 周线
            KL_TYPE.K_MON: 6,   # 月线
        }
        if self.k_type not in period_map:
            raise ValueError(f"pytdx 暂不支持 {self.k_type} 级别")
        
        try:
            from pytdx.hq import TdxHq_API
            api = TdxHq_API()
            ok = api.connect('119.147.212.81', 7709)  # 标准行情服务器
            if not ok:
                raise RuntimeError("pytdx 行情服务器连接失败")
            
            # 确定市场代码
            market = 1 if str(self.code).lower().startswith("sz.") else (0 if str(self.symbol).startswith("6") else 1)
            symbol = str(self.symbol)
            
            # 获取数据
            data = api.get_security_bars(
                period_map[self.k_type],
                market,
                symbol,
                0,  # 起始位置
                800  # 获取数量
            )
            api.disconnect()
            
            if not data:
                return
            
            for bar in data:
                # pytdx 返回的数据格式转换
                dt_raw = bar.get('datetime')
                if isinstance(dt_raw, str):
                    text = dt_raw.strip()
                    if len(text) >= 16 and text[4] == "-" and text[7] == "-":
                        dt = CTime(int(text[:4]), int(text[5:7]), int(text[8:10]), int(text[11:13]), int(text[14:16]))
                    elif len(text) >= 10 and text[4] == "-" and text[7] == "-":
                        dt = CTime(int(text[:4]), int(text[5:7]), int(text[8:10]), 0, 0)
                    else:
                        continue
                else:
                    continue
                item = {
                    DATA_FIELD.FIELD_TIME: dt,
                    DATA_FIELD.FIELD_OPEN: float(bar['open']),
                    DATA_FIELD.FIELD_HIGH: float(bar['high']),
                    DATA_FIELD.FIELD_LOW: float(bar['low']),
                    DATA_FIELD.FIELD_CLOSE: float(bar['close']),
                    DATA_FIELD.FIELD_VOLUME: float(bar.get('vol', 0)),
                    DATA_FIELD.FIELD_TURNOVER: float(bar.get('amount', 0)),
                }
                yield CKLine_Unit(item)
                
        except Exception as e:
            raise RuntimeError(f"pytdx 获取数据失败: {e}")

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass


class CSinaInline(CCommonStockApi):
    """使用新浪财经爬虫获取K线数据"""
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.symbol = self._to_sina_code(code)
        super(CSinaInline, self).__init__(code, k_type, begin_date, end_date, autype)

    @staticmethod
    def _to_sina_code(code: str) -> str:
        """转换为新浪代码格式：sh000001 或 sz000001"""
        raw = str(code or "").strip().lower()
        if raw.startswith("sh.") or raw.startswith("sz."):
            return raw.replace(".", "")
        if len(raw) == 6 and raw.isdigit():
            return ("sh" if raw.startswith("6") else "sz") + raw
        return raw

    def get_kl_data(self):
        # 先走 money.finance 老接口，失败回退 quotes.sina.cn。
        period_map = {
            KL_TYPE.K_5M: "5",
            KL_TYPE.K_15M: "15",
            KL_TYPE.K_30M: "30",
            KL_TYPE.K_60M: "60",
            KL_TYPE.K_DAY: "240",
            KL_TYPE.K_WEEK: "1200",
            KL_TYPE.K_MON: "7200",
        }
        if self.k_type not in period_map:
            raise ValueError(f"新浪财经暂不支持 {self.k_type} 级别")

        start_d = (self.begin_date or "1990-01-01").replace("/", "-")[:10]
        end_d = (self.end_date or "2099-12-31").replace("/", "-")[:10]

        try:
            url = (
                "https://money.finance.sina.com.cn/quotes_service/api/json_v2.php/"
                "CN_MarketData.getKLineData"
            )
            payload = _request_json_with_headers(
                url,
                params={"symbol": self.symbol, "scale": period_map[self.k_type], "ma": "no", "datalen": "1023"},
            )
            rows = payload if isinstance(payload, list) else []
            if not rows:
                # 新接口兜底
                payload2 = _request_json_with_headers(
                    "https://quotes.sina.cn/cn/api/json_v2.php/CN_MarketDataService.getKLineData",
                    params={"symbol": self.symbol, "scale": period_map[self.k_type], "ma": "no", "datalen": "1023"},
                )
                rows = payload2 if isinstance(payload2, list) else []
        except Exception as e:
            raise RuntimeError(f"新浪财经获取数据失败: {e}")
        for item in rows:
            if not isinstance(item, dict):
                continue
            try:
                ct, dt_obj = _parse_inline_datetime(item.get("day"), default_time=(0, 0))
            except Exception:
                continue
            ds = dt_obj.strftime("%Y-%m-%d")
            if ds < start_d or ds > end_d:
                continue
            kline_item = {
                DATA_FIELD.FIELD_TIME: ct,
                DATA_FIELD.FIELD_OPEN: str2float(item.get("open", 0)),
                DATA_FIELD.FIELD_HIGH: str2float(item.get("high", 0)),
                DATA_FIELD.FIELD_LOW: str2float(item.get("low", 0)),
                DATA_FIELD.FIELD_CLOSE: str2float(item.get("close", 0)),
                DATA_FIELD.FIELD_VOLUME: str2float(item.get("volume", 0)) * 100.0,
                DATA_FIELD.FIELD_TURNOVER: str2float(item.get("amount", 0)),
            }
            yield CKLine_Unit(kline_item)

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass


class CTencentInline(CCommonStockApi):
    """腾讯 ifzq K 线接口（独立于新浪），优先复权通道。"""

    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.symbol = _to_tencent_symbol(code)
        super(CTencentInline, self).__init__(code, k_type, begin_date, end_date, autype)

    @staticmethod
    def _to_tx_code(code: str) -> str:
        raw = str(code or "").strip().lower()
        if raw.startswith("sh.") or raw.startswith("sz."):
            return raw.replace(".", "")
        if len(raw) == 6 and raw.isdigit():
            return ("sh" if raw.startswith("6") else "sz") + raw
        return raw

    def get_kl_data(self):
        day_period_map = {
            KL_TYPE.K_DAY: "day",
            KL_TYPE.K_WEEK: "week",
            KL_TYPE.K_MON: "month",
        }
        minute_map = {
            KL_TYPE.K_1M: 1,
            KL_TYPE.K_5M: 5,
            KL_TYPE.K_15M: 15,
            KL_TYPE.K_30M: 30,
            KL_TYPE.K_60M: 60,
        }
        if self.k_type not in day_period_map and self.k_type not in minute_map:
            raise ValueError(f"腾讯财经暂不支持 {_k_type_label_cn(self.k_type)}")
        start_d = (self.begin_date or "1990-01-01").replace("/", "-")[:10]
        end_d = (self.end_date or "2099-12-31").replace("/", "-")[:10]
        fq = "qfq" if self.autype == AUTYPE.QFQ else ("hfq" if self.autype == AUTYPE.HFQ else "")
        try:
            lines = []
            if self.k_type in day_period_map:
                k_period = day_period_map[self.k_type]
                end_token = "" if end_d == datetime.now().strftime("%Y-%m-%d") else end_d
                # 优先走 fqkline，结构为空时再走 kline。
                payload = _request_json_with_headers(
                    "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get",
                    params={"param": f"{self.symbol},{k_period},,{end_token},800,{fq or 'qfq'}"},
                )
                node = payload.get("data", {}).get(self.symbol, {}) if isinstance(payload, dict) else {}
                lines = node.get(f"{fq}{k_period}") if fq else None
                if not lines:
                    lines = node.get(f"qfq{k_period}") or node.get(k_period) or []
                if not lines:
                    payload2 = _request_json_with_headers(
                        "https://web.ifzq.gtimg.cn/appstock/app/kline/kline",
                        params={"param": f"{self.symbol},{k_period},{start_d},{end_d},800"},
                    )
                    node2 = payload2.get("data", {}).get(self.symbol, {}) if isinstance(payload2, dict) else {}
                    lines = node2.get(k_period) or []
            else:
                minute = minute_map[self.k_type]
                payload = _request_json_with_headers(
                    "https://ifzq.gtimg.cn/appstock/app/kline/mkline",
                    params={"param": f"{self.symbol},m{minute},,800"},
                )
                lines = payload.get("data", {}).get(self.symbol, {}).get(f"m{minute}") or []
            if not lines:
                return

            for row in lines:
                if not isinstance(row, (list, tuple)) or len(row) < 6:
                    continue
                try:
                    ct, dt_obj = _parse_inline_datetime(row[0])
                except Exception:
                    continue
                ds = dt_obj.strftime("%Y-%m-%d")
                if len(start_d) == 10 and ds < start_d:
                    continue
                if len(end_d) == 10 and ds > end_d:
                    continue
                item = {
                    DATA_FIELD.FIELD_TIME: ct,
                    DATA_FIELD.FIELD_OPEN: str2float(row[1]),
                    DATA_FIELD.FIELD_CLOSE: str2float(row[2]),
                    DATA_FIELD.FIELD_HIGH: str2float(row[3]),
                    DATA_FIELD.FIELD_LOW: str2float(row[4]),
                    DATA_FIELD.FIELD_VOLUME: str2float(row[5]) * 100.0,
                    DATA_FIELD.FIELD_TURNOVER: str2float(row[6]) if len(row) > 6 else 0,
                }
                yield CKLine_Unit(item)
        except Exception as e:
            raise RuntimeError(f"腾讯财经获取数据失败: {e}")

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass


class CYahooInline(CCommonStockApi):
    """使用 Yahoo Finance 获取K线数据"""
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.symbol = self._to_yahoo_code(code)
        super(CYahooInline, self).__init__(code, k_type, begin_date, end_date, autype)

    @staticmethod
    def _to_yahoo_code(code: str) -> str:
        """转换为Yahoo代码格式：600340.SS 或 000001.SZ"""
        raw = str(code or "").strip()
        if raw.startswith("sh."):
            return raw[3:] + ".SS"
        if raw.startswith("sz."):
            return raw[3:] + ".SZ"
        if len(raw) == 6 and raw.isdigit():
            return raw + (".SS" if raw.startswith("6") else ".SZ")
        return raw

    def get_kl_data(self):
        if not HAS_YFINANCE:
            raise RuntimeError(_OPT_DEP_HINT_YFINANCE)
        
        period_map = {
            KL_TYPE.K_1M: "1m",
            KL_TYPE.K_5M: "5m",
            KL_TYPE.K_15M: "15m",
            KL_TYPE.K_30M: "30m",
            KL_TYPE.K_60M: "60m",
            KL_TYPE.K_DAY: "1d",
            KL_TYPE.K_WEEK: "1wk",
            KL_TYPE.K_MON: "1mo",
        }
        if self.k_type not in period_map:
            raise ValueError(f"Yahoo Finance 暂不支持 {self.k_type} 级别")
        
        try:
            ticker = yf.Ticker(self.symbol)
            df = ticker.history(
                start=self.begin_date or "1990-01-01",
                end=self.end_date or "2099-12-31",
                interval=period_map[self.k_type]
            )
            
            if df is None or df.empty:
                return
            
            for idx, row in df.iterrows():
                item = {
                    DATA_FIELD.FIELD_TIME: CTime(idx.year, idx.month, idx.day, idx.hour if hasattr(idx, 'hour') else 0, idx.minute if hasattr(idx, 'minute') else 0),
                    DATA_FIELD.FIELD_OPEN: float(row['Open']),
                    DATA_FIELD.FIELD_HIGH: float(row['High']),
                    DATA_FIELD.FIELD_LOW: float(row['Low']),
                    DATA_FIELD.FIELD_CLOSE: float(row['Close']),
                    DATA_FIELD.FIELD_VOLUME: float(row['Volume']),
                    DATA_FIELD.FIELD_TURNOVER: float(row.get('Amount', 0)),
                }
                yield CKLine_Unit(item)
                
        except Exception as e:
            raise RuntimeError(f"Yahoo Finance 获取数据失败: {e}")

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass


class CEastmoneyInline(CCommonStockApi):
    """使用东方财富网爬虫获取K线数据"""
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.symbol = _strip_market_prefix(code)
        self.secid = _to_eastmoney_secid(code)
        super(CEastmoneyInline, self).__init__(code, k_type, begin_date, end_date, autype)

    def get_kl_data(self):
        # 东方财富 push2his 接口，支持分钟 + 日周月。
        period_map = {
            KL_TYPE.K_1M: 1,
            KL_TYPE.K_5M: 5,
            KL_TYPE.K_15M: 15,
            KL_TYPE.K_30M: 30,
            KL_TYPE.K_60M: 60,
            KL_TYPE.K_DAY: 101,
            KL_TYPE.K_WEEK: 102,
            KL_TYPE.K_MON: 103,
        }
        if self.k_type not in period_map:
            raise ValueError(f"东方财富暂不支持 {_k_type_label_cn(self.k_type)}")
        start_date = (self.begin_date or "1990-01-01").replace("-", "")
        end_date = (self.end_date or "2099-12-31").replace("-", "")
        try:
            payload = _request_json_with_headers(
                "https://push2his.eastmoney.com/api/qt/stock/kline/get",
                params={
                    "secid": self.secid,
                    "fields1": "f1,f2,f3",
                    "fields2": "f51,f52,f53,f54,f55,f56,f57,f58",
                    "klt": str(period_map[self.k_type]),
                    "fqt": "1" if self.autype == AUTYPE.QFQ else ("2" if self.autype == AUTYPE.HFQ else "0"),
                    "beg": start_date,
                    "end": end_date,
                    "lmt": "1200",
                },
            )
            lines = payload.get("data", {}).get("klines") if isinstance(payload, dict) else None
            if not lines:
                return
            for line in lines:
                parts = line.split(",")
                if len(parts) < 7:
                    continue
                try:
                    ct, _ = _parse_inline_datetime(parts[0], default_time=(0, 0))
                except Exception:
                    continue
                kline_item = {
                    DATA_FIELD.FIELD_TIME: ct,
                    DATA_FIELD.FIELD_OPEN: str2float(parts[1]),
                    DATA_FIELD.FIELD_CLOSE: str2float(parts[2]),
                    DATA_FIELD.FIELD_HIGH: str2float(parts[3]),
                    DATA_FIELD.FIELD_LOW: str2float(parts[4]),
                    DATA_FIELD.FIELD_VOLUME: str2float(parts[5]),
                    DATA_FIELD.FIELD_TURNOVER: str2float(parts[6]) if len(parts) > 6 else 0,
                }
                yield CKLine_Unit(kline_item)
                
        except Exception as e:
            raise RuntimeError(f"东方财富获取数据失败: {e}")

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass


class CGitHubCsvInline(CCommonStockApi):
    """GitHub Raw CSV 数据源（通过环境变量模板配置）。"""

    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.symbol = _strip_market_prefix(code)
        super(CGitHubCsvInline, self).__init__(code, k_type, begin_date, end_date, autype)

    def get_kl_data(self):
        if self.k_type not in {KL_TYPE.K_DAY, KL_TYPE.K_WEEK, KL_TYPE.K_MON}:
            raise ValueError(f"GitHub-CSV 暂不支持 {self.k_type} 级别")
        tpl = os.getenv("CHAN_GITHUB_RAW_CSV_TEMPLATE", "").strip()
        if not tpl:
            raise RuntimeError("未配置 GitHub CSV 模板，请设置环境变量 CHAN_GITHUB_RAW_CSV_TEMPLATE")
        market = "sh" if str(self.code).lower().startswith("sh.") or str(self.symbol).startswith("6") else "sz"
        url = tpl.format(code6=self.symbol, symbol=f"{market}{self.symbol}", market=market)
        try:
            df = pd.read_csv(url)
        except Exception as e:
            raise RuntimeError(f"GitHub-CSV 读取失败: {e}")
        if df is None or df.empty:
            return
        # 常见列名兼容
        def pick(*names: str) -> Optional[str]:
            for n in names:
                if n in df.columns:
                    return n
            return None
        c_date = pick("date", "日期", "Date", "trade_date")
        c_open = pick("open", "开盘", "Open")
        c_high = pick("high", "最高", "High")
        c_low = pick("low", "最低", "Low")
        c_close = pick("close", "收盘", "Close")
        c_vol = pick("volume", "vol", "成交量", "Volume")
        c_amt = pick("amount", "成交额", "Amount")
        if not all([c_date, c_open, c_high, c_low, c_close]):
            raise RuntimeError("GitHub-CSV 列名不匹配，至少需要 date/open/high/low/close")
        s0 = (self.begin_date or "1990-01-01").replace("/", "-")[:10]
        s1 = (self.end_date or "2099-12-31").replace("/", "-")[:10]
        for _, row in df.iterrows():
            ct = _parse_inline_date(row.get(c_date))
            ds = ct.toDateStr("-")
            if len(s0) == 10 and ds < s0:
                continue
            if len(s1) == 10 and ds > s1:
                continue
            item = {
                DATA_FIELD.FIELD_TIME: ct,
                DATA_FIELD.FIELD_OPEN: str2float(row.get(c_open, 0)),
                DATA_FIELD.FIELD_HIGH: str2float(row.get(c_high, 0)),
                DATA_FIELD.FIELD_LOW: str2float(row.get(c_low, 0)),
                DATA_FIELD.FIELD_CLOSE: str2float(row.get(c_close, 0)),
                DATA_FIELD.FIELD_VOLUME: str2float(row.get(c_vol, 0)) if c_vol else 0,
                DATA_FIELD.FIELD_TURNOVER: str2float(row.get(c_amt, 0)) if c_amt else 0,
            }
            yield CKLine_Unit(item)

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass


def _offline_kl_minutes(klt: KL_TYPE) -> int:
    m = {
        KL_TYPE.K_1M: 1,
        KL_TYPE.K_3M: 3,
        KL_TYPE.K_5M: 5,
        KL_TYPE.K_15M: 15,
        KL_TYPE.K_30M: 30,
        KL_TYPE.K_60M: 60,
    }
    if klt not in m:
        raise ValueError(f"离线数据不支持的分钟类周期：{klt}")
    return m[klt]


def _offline_list_tick_paths(folder: str, code6: str, b8: int, e8: int) -> list[str]:
    """枚举 a_Data/六位代码/ 下分笔：YYYYMMDD_六位代码.txt（自动 os.listdir，增删股票目录无需改代码）。"""
    digits = "".join(ch for ch in str(code6) if ch.isdigit())
    c6 = digits[:6] if len(digits) >= 6 else digits.zfill(6) if digits else ""
    if not c6 or len(c6) != 6:
        return []
    if not os.path.isdir(folder):
        return []
    pat = re.compile(r"^(\d{8})_" + re.escape(c6) + r"\.txt$", re.I)
    out: list[tuple[int, str]] = []
    try:
        names = os.listdir(folder)
    except OSError:
        return []
    for fn in names:
        m = pat.match(fn)
        if not m:
            continue
        d8 = int(m.group(1))
        if b8 <= d8 <= e8:
            out.append((d8, os.path.join(folder, fn)))
    out.sort(key=lambda x: x[0])
    return [p for _, p in out]


def _clone_offline_tick_row(row: OfflineTickRow) -> OfflineTickRow:
    return OfflineTickRow(row.t, row.price, row.vol, row.side, row.has_bs, row.price_lo, row.price_hi)


def _offline_load_tick_rows_from_file(path: str) -> list[OfflineTickRow]:
    """按文件缓存分笔解析结果；合并模式在区间层处理。"""
    try:
        st = os.stat(path)
        key = (os.path.abspath(path), int(st.st_mtime_ns), int(st.st_size))
    except OSError:
        key = (os.path.abspath(path), 0, -1)
    with _OFFLINE_TICK_FILE_CACHE_LOCK:
        cached = _OFFLINE_TICK_FILE_CACHE.get(key)
        if cached is not None:
            return [_clone_offline_tick_row(r) for r in cached]

    base = os.path.basename(path)
    d8 = int(base.split("_")[0])
    y, mo, d0 = d8 // 10000, (d8 // 100) % 100, d8 % 100
    rows: list[OfflineTickRow] = []
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            row = parse_offline_tick_line(line, y, mo, d0)
            if row is not None:
                rows.append(row)
    rows.sort(key=lambda x: x.t.ts)
    with _OFFLINE_TICK_FILE_CACHE_LOCK:
        if len(_OFFLINE_TICK_FILE_CACHE) >= _OFFLINE_TICK_FILE_CACHE_MAX:
            _OFFLINE_TICK_FILE_CACHE.pop(next(iter(_OFFLINE_TICK_FILE_CACHE)), None)
        _OFFLINE_TICK_FILE_CACHE[key] = [_clone_offline_tick_row(r) for r in rows]
    return rows


def _offline_load_tick_rows(
    paths: list[str], offline_data_custom: Any | None = None
) -> list[OfflineTickRow]:
    """读取离线分笔；merge_no_bs 时开盘向下/收盘向上合并无 B/S 行。"""
    mode = normalize_offline_data_custom(offline_data_custom or _ACTIVE_OFFLINE_DATA_CUSTOM)
    rows: list[OfflineTickRow] = []
    for p in paths:
        rows.extend(_offline_load_tick_rows_from_file(p))
    rows.sort(key=lambda x: x.t.ts)
    if mode == "merge_no_bs":
        return merge_no_bs_offline_ticks(rows)
    for r in rows:
        if not r.has_bs:
            r.side = "B"
    return rows


def _offline_load_ticks(
    paths: list[str], offline_data_custom: Any | None = None
) -> list[tuple[CTime, float, float, str]]:
    """兼容四元组接口；B/S 用于筹码 S(左绿)/B(右红)。"""
    return rows_to_legacy_ticks(_offline_load_tick_rows(paths, offline_data_custom))


def _offline_ticks_to_1m_from_rows(rows: list[OfflineTickRow]) -> list[dict[str, Any]]:
    # 单次扫描分钟桶，避免每桶列表+重复 max/min/sum。
    # 语义与旧实现一致：按输入顺序取该分钟首价/末价。
    buck: dict[tuple[int, int, int, int, int], list[float]] = {}
    for row in rows:
        t = row.t
        key = (t.year, t.month, t.day, t.hour, t.minute)
        price = float(row.price)
        vol = float(row.vol)
        hi = float(row.price_hi if row.price_hi is not None else price)
        lo = float(row.price_lo if row.price_lo is not None else price)
        cur = buck.get(key)
        if cur is None:
            # [open, close, high, low, vol, amount]
            buck[key] = [price, price, hi, lo, vol, price * vol]
            continue
        cur[1] = price
        if hi > cur[2]:
            cur[2] = hi
        if lo < cur[3]:
            cur[3] = lo
        cur[4] += vol
        cur[5] += price * vol
    out: list[dict[str, Any]] = []
    for y, mo, d, hh, mm in sorted(buck):
        o0, c0, hi, lo, v0, amt0 = buck[(y, mo, d, hh, mm)]
        out.append({"t": CTime(y, mo, d, hh, mm, auto=False), "o": o0, "h": hi, "l": lo, "c": c0, "v": v0, "amt": amt0})
    return out


def _offline_ticks_to_1m(ticks: list[tuple[CTime, float, float, str]]) -> list[dict[str, Any]]:
    """由四元组分笔聚合 1 分钟（兼容旧调用）。"""
    rows = [
        OfflineTickRow(t, price, vol, side, side in ("B", "S")) for t, price, vol, side in ticks
    ]
    return _offline_ticks_to_1m_from_rows(rows)


def _offline_merge_bar_group(lst: list[dict[str, Any]]) -> dict[str, Any]:
    o0, c0 = lst[0]["o"], lst[-1]["c"]
    hi = max(x["h"] for x in lst)
    lo = min(x["l"] for x in lst)
    v0 = sum(x["v"] for x in lst)
    amt0 = sum(x["amt"] for x in lst)
    return {"t": lst[-1]["t"], "o": o0, "h": hi, "l": lo, "c": c0, "v": v0, "amt": amt0}


def _offline_resample_minutes(rows: list[dict[str, Any]], period_m: int) -> list[dict[str, Any]]:
    if period_m <= 1:
        return rows
    from collections import defaultdict

    buck: dict[tuple[int, int, int, int], list[dict[str, Any]]] = defaultdict(list)
    for r in rows:
        t = r["t"]
        slot = (t.hour * 60 + t.minute) // period_m
        key = (t.year, t.month, t.day, slot)
        buck[key].append(r)
    out: list[dict[str, Any]] = []
    for key in sorted(buck):
        lst = sorted(buck[key], key=lambda x: x["t"].ts)
        out.append(_offline_merge_bar_group(lst))
    return out


def _offline_daily_from_1m(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    from collections import defaultdict

    by_d: dict[tuple[int, int, int], list[dict[str, Any]]] = defaultdict(list)
    for r in rows:
        t = r["t"]
        by_d[(t.year, t.month, t.day)].append(r)
    out: list[dict[str, Any]] = []
    for key in sorted(by_d):
        lst = sorted(by_d[key], key=lambda x: x["t"].ts)
        m = _offline_merge_bar_group(lst)
        y, mo, d = key
        m["t"] = CTime(y, mo, d, 15, 0, auto=False)
        out.append(m)
    return out


def _offline_weekly_from_daily(daily: list[dict[str, Any]]) -> list[dict[str, Any]]:
    from collections import defaultdict
    from datetime import date as _date

    by_w: dict[tuple[int, int], list[dict[str, Any]]] = defaultdict(list)
    for r in daily:
        t = r["t"]
        iy, iw, _ = _date(t.year, t.month, t.day).isocalendar()
        by_w[(iy, iw)].append(r)
    out: list[dict[str, Any]] = []
    for key in sorted(by_w):
        lst = sorted(by_w[key], key=lambda x: x["t"].ts)
        m = _offline_merge_bar_group(lst)
        m["t"] = lst[-1]["t"]
        out.append(m)
    return out


def _offline_monthly_from_daily(daily: list[dict[str, Any]]) -> list[dict[str, Any]]:
    from collections import defaultdict

    by_m: dict[tuple[int, int], list[dict[str, Any]]] = defaultdict(list)
    for r in daily:
        t = r["t"]
        by_m[(t.year, t.month)].append(r)
    out: list[dict[str, Any]] = []
    for key in sorted(by_m):
        lst = sorted(by_m[key], key=lambda x: x["t"].ts)
        m = _offline_merge_bar_group(lst)
        m["t"] = lst[-1]["t"]
        out.append(m)
    return out


def _offline_yearly_from_daily(daily: list[dict[str, Any]]) -> list[dict[str, Any]]:
    from collections import defaultdict

    by_y: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for r in daily:
        by_y[r["t"].year].append(r)
    out: list[dict[str, Any]] = []
    for y in sorted(by_y):
        lst = sorted(by_y[y], key=lambda x: x["t"].ts)
        m = _offline_merge_bar_group(lst)
        m["t"] = lst[-1]["t"]
        out.append(m)
    return out


def _offline_quarterly_from_daily(daily: list[dict[str, Any]]) -> list[dict[str, Any]]:
    from collections import defaultdict

    by_q: dict[tuple[int, int], list[dict[str, Any]]] = defaultdict(list)
    for r in daily:
        t = r["t"]
        q = (t.month - 1) // 3 + 1
        by_q[(t.year, q)].append(r)
    out: list[dict[str, Any]] = []
    for key in sorted(by_q):
        lst = sorted(by_q[key], key=lambda x: x["t"].ts)
        m = _offline_merge_bar_group(lst)
        m["t"] = lst[-1]["t"]
        out.append(m)
    return out


def _offline_rows_to_ktype(rows_1m: list[dict[str, Any]], k_type: KL_TYPE) -> list[dict[str, Any]]:
    if not rows_1m:
        return []
    # kltype_lt_day 不含 K_3M，此处显式列出所有分钟类
    minute_like = {
        KL_TYPE.K_1M,
        KL_TYPE.K_3M,
        KL_TYPE.K_5M,
        KL_TYPE.K_15M,
        KL_TYPE.K_30M,
        KL_TYPE.K_60M,
    }
    if k_type in minute_like:
        pm = _offline_kl_minutes(k_type)
        return _offline_resample_minutes(rows_1m, pm)
    if k_type == KL_TYPE.K_DAY:
        return _offline_daily_from_1m(rows_1m)
    daily = _offline_daily_from_1m(rows_1m)
    if k_type == KL_TYPE.K_WEEK:
        return _offline_weekly_from_daily(daily)
    if k_type == KL_TYPE.K_MON:
        return _offline_monthly_from_daily(daily)
    if k_type == KL_TYPE.K_YEAR:
        return _offline_yearly_from_daily(daily)
    if k_type == KL_TYPE.K_QUARTER:
        return _offline_quarterly_from_daily(daily)
    raise ValueError(f"离线数据不支持的周期：{k_type}")


class COfflineInline(CCommonStockApi):
    """读取 a_Data/六位代码/ 下分笔 txt，在内存中聚合成任意请求周期 K 线。"""

    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self._folder_name = offline_folder_from_code(code)
        self._base = os.path.join(_offline_root_dir(), self._folder_name)
        super().__init__(code, k_type, begin_date, end_date, autype)

    def SetBasciInfo(self):
        sym = _strip_market_prefix(self.code)
        self.is_stock = True
        self.name = self.code

    def get_kl_data(self) -> Iterator[CKLine_Unit]:
        code6 = _strip_market_prefix(self.code)
        b8, e8 = _offline_date_bounds(self.begin_date, self.end_date)
        tick_paths = _offline_list_tick_paths(self._base, code6, b8, e8)
        if not tick_paths:
            raise ValueError(
                f"未找到离线分笔数据：目录 {self._base} 下无日期区间内 YYYYMMDD_{self._folder_name}.txt，"
                f"当前请求周期：{_k_type_label_cn(self.k_type)}"
            )
        ticks = _offline_load_ticks(tick_paths)
        if not ticks:
            raise ValueError("分笔文件在日期区间内无有效成交行")
        rows_1m = _offline_ticks_to_1m(ticks)
        bars = _offline_rows_to_ktype(rows_1m, self.k_type)
        if not bars:
            raise ValueError("离线合成后 K 线为空")
        for r in bars:
            item = {
                DATA_FIELD.FIELD_TIME: r["t"],
                DATA_FIELD.FIELD_OPEN: r["o"],
                DATA_FIELD.FIELD_HIGH: r["h"],
                DATA_FIELD.FIELD_LOW: r["l"],
                DATA_FIELD.FIELD_CLOSE: r["c"],
                DATA_FIELD.FIELD_VOLUME: r["v"],
                DATA_FIELD.FIELD_TURNOVER: r["amt"],
            }
            yield CKLine_Unit(item)

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass


def get_stock_api_cls(data_src: Any):
    """根据数据源返回对应的API类"""
    if data_src == DATA_SRC.AKSHARE or data_src == AKSHARE_INLINE_SRC:
        return CAkshareInline
    if data_src == AKTX_INLINE_SRC:
        return CAkTxInline
    if data_src == GITHUB_CSV_INLINE_SRC:
        return CGitHubCsvInline
    if data_src == DATA_SRC.BAO_STOCK:
        return CBaoStock
    if data_src == TUSHARE_INLINE_SRC:
        return CTushareInline
    if data_src == "inline:ashare":
        return CAshareInline
    if data_src == "inline:adata":
        return CADataInline
    if data_src == PYTDX_INLINE_SRC:
        return CPytdxInline
    if data_src == SINA_INLINE_SRC:
        return CSinaInline
    if data_src == TENCENT_INLINE_SRC:
        return CTencentInline
    if data_src == YAHOO_INLINE_SRC:
        return CYahooInline
    if data_src == EASTMONEY_INLINE_SRC:
        return CEastmoneyInline
    if data_src == OFFLINE_INLINE_SRC:
        return COfflineInline
    raise ValueError(f"unsupported data source: {data_src}")


class ReplayDataChan(CChan):
    def GetStockAPI(self):
        if self.data_src == AKSHARE_INLINE_SRC:
            return CAkshareInline
        if self.data_src == AKTX_INLINE_SRC:
            return CAkTxInline
        if self.data_src == GITHUB_CSV_INLINE_SRC:
            return CGitHubCsvInline
        if self.data_src == TUSHARE_INLINE_SRC:
            return CTushareInline
        if self.data_src == "inline:ashare":
            return CAshareInline
        if self.data_src == "inline:adata":
            return CADataInline
        if self.data_src == PYTDX_INLINE_SRC:
            return CPytdxInline
        if self.data_src == SINA_INLINE_SRC:
            return CSinaInline
        if self.data_src == TENCENT_INLINE_SRC:
            return CTencentInline
        if self.data_src == YAHOO_INLINE_SRC:
            return CYahooInline
        if self.data_src == EASTMONEY_INLINE_SRC:
            return CEastmoneyInline
        if self.data_src == OFFLINE_INLINE_SRC:
            return COfflineInline
        return super().GetStockAPI()


class SimpleLineList(list):
    """为本文件内自定义线结构提供和 CSegListComm 兼容的最小接口。"""

    def exist_sure_seg(self) -> bool:
        return any(bool(getattr(seg, "is_sure", False)) for seg in self)


@dataclass
class NewKElement:
    item: Any
    source_index: int
    begin_x: int
    end_x: int
    high: float
    low: float
    high_klu: Any
    low_klu: Any


@dataclass
class NewKPoint:
    fx: FX_TYPE
    x: int
    y: float
    source_index: int
    source_item: Any
    anchor_klu: Any


@dataclass
class ChanStructureBundle:
    chan_algo: str
    fract_list: Any
    bi_list: Any
    seg_list: Any
    segseg_list: Any
    segsegseg_list: Any
    fractzs_list: Any
    zs_list: Any
    segzs_list: Any
    segsegzs_list: Any
    bs_point_lst: Any
    seg_bs_point_lst: Any
    segseg_bs_point_lst: Any
    trend_lines: list[dict[str, Any]]
    fx_lines: list[dict[str, Any]]
    rhythm_lines: list[dict[str, Any]]
    rhythm_hits: list[dict[str, Any]]
    extra_line_lists: dict[str, Any] = field(default_factory=dict)
    extra_zs_lists: dict[str, Any] = field(default_factory=dict)
    extra_bsp_lists: dict[str, Any] = field(default_factory=dict)


@dataclass
class DataSourceSelection:
    data_src: Any
    label: str
    logs: list[str]
    replay_klus_master: list
    kline_all: list[dict[str, Any]]
    stock_name: Optional[str]


class CombinedNewKBar:
    def __init__(self, element: NewKElement, _dir: KLINE_DIR) -> None:
        self.elements: list[NewKElement] = [element]
        self.high = float(element.high)
        self.low = float(element.low)
        self.dir = _dir
        self.fx = FX_TYPE.UNKNOWN

    def try_add(self, element: NewKElement) -> KLINE_DIR:
        _dir = test_combine_range(self.high, self.low, element.high, element.low)
        if _dir == KLINE_DIR.COMBINE:
            self.elements.append(element)
            if self.dir == KLINE_DIR.UP:
                if element.high != element.low or element.high != self.high:
                    self.high = max(self.high, float(element.high))
                    self.low = max(self.low, float(element.low))
            elif self.dir == KLINE_DIR.DOWN:
                if element.high != element.low or element.low != self.low:
                    self.high = min(self.high, float(element.high))
                    self.low = min(self.low, float(element.low))
        return _dir

    def update_fx(self, prev_bar: "CombinedNewKBar", next_bar: "CombinedNewKBar") -> None:
        self.fx = FX_TYPE.UNKNOWN
        if prev_bar.high < self.high and next_bar.high < self.high and prev_bar.low < self.low and next_bar.low < self.low:
            self.fx = FX_TYPE.TOP
        elif prev_bar.high > self.high and next_bar.high > self.high and prev_bar.low > self.low and next_bar.low > self.low:
            self.fx = FX_TYPE.BOTTOM

    def get_peak_element(self, *, is_high: bool) -> Optional[NewKElement]:
        target = self.high if is_high else self.low
        for element in reversed(self.elements):
            value = element.high if is_high else element.low
            if abs(float(value) - float(target)) <= 1e-9:
                return element
        return self.elements[-1] if self.elements else None


def test_combine_range(high_a: float, low_a: float, high_b: float, low_b: float) -> KLINE_DIR:
    if high_a >= high_b and low_a <= low_b:
        return KLINE_DIR.COMBINE
    if high_a <= high_b and low_a >= low_b:
        return KLINE_DIR.COMBINE
    if high_a > high_b and low_a > low_b:
        return KLINE_DIR.DOWN
    if high_a < high_b and low_a < low_b:
        return KLINE_DIR.UP
    raise CChanException("combine type unknown", ErrCode.COMBINER_ERR)


def get_line_peak_klu(item: Any, *, is_high: bool):
    if isinstance(item, CKLine):
        return item.get_peak_klu(is_high=is_high)
    if isinstance(item, CBi):
        if is_high:
            return item.get_end_klu() if item.is_up() else item.get_begin_klu()
        return item.get_begin_klu() if item.is_up() else item.get_end_klu()
    if isinstance(item, CSeg):
        if is_high:
            return item.get_end_klu() if item.is_up() else item.get_begin_klu()
        return item.get_begin_klu() if item.is_up() else item.get_end_klu()
    raise TypeError(f"unsupported line item: {type(item)!r}")


def make_new_k_element(item: Any, source_index: int) -> NewKElement:
    if isinstance(item, CKLine):
        return NewKElement(
            item=item,
            source_index=source_index,
            begin_x=int(item.lst[0].idx),
            end_x=int(item.lst[-1].idx),
            high=float(item.high),
            low=float(item.low),
            high_klu=item.get_peak_klu(is_high=True),
            low_klu=item.get_peak_klu(is_high=False),
        )
    if isinstance(item, (CBi, CSeg)):
        return NewKElement(
            item=item,
            source_index=source_index,
            begin_x=int(item.get_begin_klu().idx),
            end_x=int(item.get_end_klu().idx),
            high=float(item._high()),
            low=float(item._low()),
            high_klu=get_line_peak_klu(item, is_high=True),
            low_klu=get_line_peak_klu(item, is_high=False),
        )
    raise TypeError(f"unsupported new-k element source: {type(item)!r}")


def build_combined_newk_bars(items: list[Any]) -> list[CombinedNewKBar]:
    elements = [make_new_k_element(item, idx) for idx, item in enumerate(items)]
    bars: list[CombinedNewKBar] = []
    for element in elements:
        if not bars:
            bars.append(CombinedNewKBar(element, KLINE_DIR.UP))
            continue
        _dir = bars[-1].try_add(element)
        if _dir != KLINE_DIR.COMBINE:
            bars.append(CombinedNewKBar(element, _dir))
            if len(bars) >= 3:
                bars[-2].update_fx(bars[-3], bars[-1])
    return bars


def normalize_alternating_points(points: list[NewKPoint]) -> list[NewKPoint]:
    normalized: list[NewKPoint] = []
    for point in sorted(points, key=lambda item: (item.x, item.source_index)):
        if not normalized:
            normalized.append(point)
            continue
        last = normalized[-1]
        if point.fx == last.fx:
            if point.fx == FX_TYPE.TOP:
                if point.y > last.y or (abs(point.y - last.y) <= 1e-9 and point.x >= last.x):
                    normalized[-1] = point
            elif point.fx == FX_TYPE.BOTTOM:
                if point.y < last.y or (abs(point.y - last.y) <= 1e-9 and point.x >= last.x):
                    normalized[-1] = point
            continue
        if point.x == last.x and abs(point.y - last.y) <= 1e-9:
            continue
        normalized.append(point)
    return normalized


def empty_zs_list(zs_conf) -> CZSList:
    return CZSList(zs_config=zs_conf)


def extract_new_fractal_points(items: list[Any]) -> list[NewKPoint]:
    points: list[NewKPoint] = []
    for bar in build_combined_newk_bars(items):
        if bar.fx == FX_TYPE.TOP:
            element = bar.get_peak_element(is_high=True)
            if element is None:
                continue
            points.append(
                NewKPoint(
                    fx=FX_TYPE.TOP,
                    x=int(element.high_klu.idx),
                    y=float(element.high_klu.high),
                    source_index=element.source_index,
                    source_item=element.item,
                    anchor_klu=element.high_klu,
                )
            )
        elif bar.fx == FX_TYPE.BOTTOM:
            element = bar.get_peak_element(is_high=False)
            if element is None:
                continue
            points.append(
                NewKPoint(
                    fx=FX_TYPE.BOTTOM,
                    x=int(element.low_klu.idx),
                    y=float(element.low_klu.low),
                    source_index=element.source_index,
                    source_item=element.item,
                    anchor_klu=element.low_klu,
                )
            )
    return normalize_alternating_points(points)


def link_line_chain(lines: list[Any]) -> None:
    prev = None
    for idx, line in enumerate(lines):
        if isinstance(line, CSeg):
            line.idx = idx
        line.pre = prev
        line.next = None
        if prev is not None:
            prev.next = line
        prev = line


def assign_line_seg_idx(source_lines: list[Any], seg_lines: list[Any]) -> None:
    if len(seg_lines) == 0:
        for line in source_lines:
            line.set_seg_idx(0)
        return
    cur_seg = seg_lines[-1]
    line_idx = len(source_lines) - 1
    while line_idx >= 0:
        line = source_lines[line_idx]
        if line.idx > cur_seg.end_bi.idx:
            line.set_seg_idx(cur_seg.idx + 1)
            line_idx -= 1
            continue
        while line.idx < cur_seg.start_bi.idx and getattr(cur_seg, "pre", None) is not None:
            cur_seg = cur_seg.pre
        line.set_seg_idx(cur_seg.idx)
        line_idx -= 1


def resolve_boundary_line(source_lines: list[Any], point: NewKPoint, target_dir: BI_DIR):
    cur = source_lines[point.source_index]
    if cur.dir == target_dir:
        return cur
    if target_dir == BI_DIR.UP:
        candidate_idx = point.source_index + 1 if point.fx == FX_TYPE.BOTTOM else point.source_index - 1
    else:
        candidate_idx = point.source_index + 1 if point.fx == FX_TYPE.TOP else point.source_index - 1
    if 0 <= candidate_idx < len(source_lines):
        candidate = source_lines[candidate_idx]
        if candidate.dir == target_dir:
            return candidate
    return cur


def insert_gap_bridged_bi_pairs(pair_specs: list[tuple[Any, Any, str]]) -> list[tuple[Any, Any, str]]:
    bridged: list[tuple[Any, Any, str]] = []
    for begin_klc, end_klc, reason in pair_specs:
        if bridged:
            _, prev_end_klc, _ = bridged[-1]
            if getattr(prev_end_klc, "idx", -1) < getattr(begin_klc, "idx", -1):
                bridged.append((prev_end_klc, begin_klc, "new_chan_fract_gap_bridge"))
        bridged.append((begin_klc, end_klc, reason))
    return bridged


def build_new_bi_list(kl_list) -> list[CBi]:
    source_klc = [klc for klc in kl_list.lst if klc.fx in (FX_TYPE.TOP, FX_TYPE.BOTTOM)]
    points = extract_new_fractal_points(source_klc)
    pair_specs: list[tuple[Any, Any, str]] = []
    for start_point, end_point in zip(points, points[1:]):
        if start_point.fx == end_point.fx:
            continue
        begin_klc = start_point.source_item
        end_klc = end_point.source_item
        if begin_klc.idx >= end_klc.idx:
            continue
        pair_specs.append((begin_klc, end_klc, "new_chan_fract"))
    bi_list: list[CBi] = []
    for begin_klc, end_klc, reason in insert_gap_bridged_bi_pairs(pair_specs):
        try:
            bi = CBi(begin_klc, end_klc, idx=len(bi_list), is_sure=True)
            bi.reason = reason
            bi.is_gap_bridge = "gap_bridge" in reason
            bi_list.append(bi)
        except Exception:
            continue
    link_line_chain(bi_list)
    return bi_list


def build_gap_bridge_seg_spec(source_lines: list[Any], prev_end_line: Any, next_start_line: Any, reason_tag: str):
    gap_start_idx = int(prev_end_line.idx) + 1
    gap_end_idx = int(next_start_line.idx) - 1
    if gap_start_idx > gap_end_idx:
        return None
    gap_candidates = list(source_lines[gap_start_idx:gap_end_idx + 1])
    if not gap_candidates:
        return None
    bridge_dir = BI_DIR.UP if float(next_start_line.get_begin_val()) >= float(prev_end_line.get_end_val()) else BI_DIR.DOWN
    matching = [line for line in gap_candidates if getattr(line, "dir", None) == bridge_dir]
    if not matching:
        matching = [gap_candidates[0]]
        bridge_dir = matching[0].dir
    bridge_start = matching[0]
    bridge_end = matching[-1]
    if getattr(bridge_start, "idx", -1) > getattr(bridge_end, "idx", -1):
        return None
    return bridge_start, bridge_end, bridge_dir, f"{reason_tag}_gap_bridge"


def insert_gap_bridged_seg_specs(source_lines: list[Any], seg_specs: list[tuple[Any, Any, BI_DIR, str]], reason_tag: str):
    bridged: list[tuple[Any, Any, BI_DIR, str]] = []
    for start_line, end_line, target_dir, reason in seg_specs:
        if bridged:
            _, prev_end_line, _, _ = bridged[-1]
            if int(prev_end_line.idx) + 1 <= int(start_line.idx) - 1:
                bridge_spec = build_gap_bridge_seg_spec(source_lines, prev_end_line, start_line, reason_tag)
                if bridge_spec is not None:
                    bridged.append(bridge_spec)
        bridged.append((start_line, end_line, target_dir, reason))
    return bridged


def build_new_seg_list(source_lines: list[Any], reason_tag: str) -> SimpleLineList:
    points = extract_new_fractal_points(source_lines)
    seg_specs: list[tuple[Any, Any, BI_DIR, str]] = []
    for start_point, end_point in zip(points, points[1:]):
        if start_point.fx == end_point.fx:
            continue
        target_dir = BI_DIR.UP if start_point.fx == FX_TYPE.BOTTOM else BI_DIR.DOWN
        start_line = resolve_boundary_line(source_lines, start_point, target_dir)
        end_line = resolve_boundary_line(source_lines, end_point, target_dir)
        if start_line is None or end_line is None:
            continue
        if start_line.idx >= end_line.idx:
            continue
        if start_line.dir != target_dir or end_line.dir != target_dir:
            continue
        seg_specs.append((start_line, end_line, target_dir, reason_tag))
    seg_lines = SimpleLineList()
    for start_line, end_line, target_dir, reason in insert_gap_bridged_seg_specs(source_lines, seg_specs, reason_tag):
        try:
            seg = CSeg(len(seg_lines), start_line, end_line, is_sure=True, seg_dir=target_dir, reason=reason)
            if "gap_bridge" in reason:
                seg.is_sure = True
                seg.is_gap_bridge = True
            seg_lines.append(seg)
        except Exception:
            continue
    link_line_chain(seg_lines)
    for seg in seg_lines:
        seg.update_bi_list(source_lines, seg.start_bi.idx, seg.end_bi.idx)
    assign_line_seg_idx(source_lines, seg_lines)
    return seg_lines


def build_trend_lines_from_bi_list(bi_list: list[Any]) -> list[dict[str, Any]]:
    trend_lines: list[dict[str, Any]] = []
    if len(bi_list) < 3:
        return trend_lines
    try:
        tl_outside = CTrendLine(bi_list, side=TREND_LINE_SIDE.OUTSIDE)
        if tl_outside.line:
            trend_lines.append(
                {
                    "type": "OUTSIDE",
                    "x0": tl_outside.line.p.x,
                    "y0": tl_outside.line.p.y,
                    "slope": tl_outside.line.slope,
                }
            )
        tl_inside = CTrendLine(bi_list, side=TREND_LINE_SIDE.INSIDE)
        if tl_inside.line:
            trend_lines.append(
                {
                    "type": "INSIDE",
                    "x0": tl_inside.line.p.x,
                    "y0": tl_inside.line.p.y,
                    "slope": tl_inside.line.slope,
                }
            )
    except Exception:
        return []
    return trend_lines


def build_fx_lines(kl_list) -> list[dict[str, Any]]:
    fx_points = []
    for klc in kl_list.lst:
        if klc.fx == FX_TYPE.TOP:
            peak = max(klc.lst, key=lambda item: item.high)
            fx_points.append({"type": "TOP", "x": int(peak.idx), "y": float(peak.high)})
        elif klc.fx == FX_TYPE.BOTTOM:
            trough = min(klc.lst, key=lambda item: item.low)
            fx_points.append({"type": "BOTTOM", "x": int(trough.idx), "y": float(trough.low)})
    fx_lines: list[dict[str, Any]] = []
    last = None
    for point in fx_points:
        if last is not None and point["type"] != last["type"]:
            fx_lines.append({"x1": last["x"], "y1": last["y"], "x2": point["x"], "y2": point["y"]})
        last = point
    return fx_lines


def reverse_bi_dir(direction: BI_DIR) -> BI_DIR:
    return BI_DIR.DOWN if direction == BI_DIR.UP else BI_DIR.UP


def structure_level_label(level: str) -> str:
    return dynamic_level_label(level) if is_bsp_level(level) else STRUCTURE_LEVEL_LABELS.get(level, level)


def rhythm_level_label(level: str) -> str:
    return RHYTHM_LEVEL_LABELS.get(level, structure_level_label(level))


def line_begin_x(line: Any) -> int:
    return int(line.get_begin_klu().idx)


def line_end_x(line: Any) -> int:
    return int(line.get_end_klu().idx)


def make_line_key(level: str, line: Any) -> str:
    return f"{level}|{getattr(line, 'idx', -1)}|{line_begin_x(line)}|{line_end_x(line)}|{getattr(line, 'dir', '')}"


def child_lines_within_parent(parent: Any, child_lines: list[Any]) -> list[Any]:
    begin_x = line_begin_x(parent)
    end_x = line_end_x(parent)
    return sorted(
        [
            line for line in child_lines
            if line_begin_x(line) >= begin_x and line_end_x(line) <= end_x
        ],
        key=lambda item: (line_begin_x(item), line_end_x(item), getattr(item, "idx", -1)),
    )


def child_lines_for_parent_rhythm(parent: Any, child_lines: list[Any]) -> list[Any]:
    begin_x = line_begin_x(parent)
    end_x = line_end_x(parent)
    picked: dict[str, Any] = {}
    for line in child_lines:
        bx = line_begin_x(line)
        ex = line_end_x(line)
        # 节奏线允许多取一根跨父端点子线，用于补齐“前一拐点 -> 下一拐点”。
        if bx >= begin_x and (ex <= end_x or bx <= end_x):
            picked[make_line_key("child", line)] = line
    return sorted(
        picked.values(),
        key=lambda item: (line_begin_x(item), line_end_x(item), getattr(item, "idx", -1)),
    )


def build_alternating_child_sequence(child_lines: list[Any], parent_dir: BI_DIR) -> list[Any]:
    if not child_lines:
        return []
    seq: list[Any] = []
    expected = parent_dir
    started = False
    for child in child_lines:
        child_dir = getattr(child, "dir", None)
        if child_dir is None:
            continue
        if not started:
            if child_dir != parent_dir:
                continue
            started = True
        if child_dir != expected:
            continue
        seq.append(child)
        expected = reverse_bi_dir(expected)
    return seq


def normalize_rhythm_calc_mode(mode: Any) -> str:
    text = str(mode or RHYTHM_CALC_MODE_NORMAL).strip()
    return text if text in RHYTHM_CALC_MODES else RHYTHM_CALC_MODE_NORMAL


def rhythm_layer_index(round_current: int, round_ref: int) -> int:
    return max(0, int(round_current) - int(round_ref))


def make_rhythm_display_label(round_current: int, round_ref: int) -> str:
    return f"节奏线{round_ref}-{rhythm_layer_index(round_current, round_ref)}"


def rhythm_dir_text(direction: Any) -> str:
    if direction == BI_DIR.UP or str(direction).upper() == "UP":
        return "UP"
    if direction == BI_DIR.DOWN or str(direction).upper() == "DOWN":
        return "DOWN"
    return str(direction).upper()


def rhythm_1382_threshold(direction: Any, *, prev_same_val: float, opposite_val: float) -> float:
    """按 1382 提示同一套公式计算当前推进端点门槛。"""
    dir_text = rhythm_dir_text(direction)
    if dir_text == "UP":
        return float(opposite_val) + (float(prev_same_val) - float(opposite_val)) * 1.382
    if dir_text == "DOWN":
        return float(opposite_val) - (float(opposite_val) - float(prev_same_val)) * 1.382
    return float("nan")


def rhythm_retrace_allowed(mode: Any, direction: Any, *, b_val: float, d_val: float, threshold: float) -> bool:
    calc_mode = normalize_rhythm_calc_mode(mode)
    if calc_mode == RHYTHM_CALC_MODE_NORMAL:
        return True
    dir_text = rhythm_dir_text(direction)
    eps = 1e-12
    if dir_text == "UP":
        if d_val + eps < b_val:
            return False
        return calc_mode != RHYTHM_CALC_MODE_STRICT_1382 or d_val + eps >= threshold
    if dir_text == "DOWN":
        if d_val - eps > b_val:
            return False
        return calc_mode != RHYTHM_CALC_MODE_STRICT_1382 or d_val - eps <= threshold
    return True


def iter_klus(kl_list) -> list[Any]:
    return [klu for klu in kl_list.klu_iter()]


def format_rhythm_ratio(ratio: float) -> str:
    text = f"{float(ratio):.3f}"
    return text.rstrip("0").rstrip(".") if "." in text else text


def find_1382_hits(klus: list[Any], *, start_x: int, direction: BI_DIR, threshold: float) -> list[dict[str, Any]]:
    hits: list[dict[str, Any]] = []
    for klu in klus:
        x = int(klu.idx)
        if x <= start_x:
            continue
        if direction == BI_DIR.UP:
            high = float(klu.high)
            if high >= threshold:
                hits.append(
                    {
                        "x": x,
                        "y": high,
                        "time": klu.time.to_str(),
                        "price_field": "H",
                        "price_value": high,
                    }
                )
        else:
            low = float(klu.low)
            if low <= threshold:
                hits.append(
                    {
                        "x": x,
                        "y": low,
                        "time": klu.time.to_str(),
                        "price_field": "L",
                        "price_value": low,
                    }
                )
    return hits


def build_parent_rhythm_entries(
    *,
    level: str,
    parent_level: str,
    parent_line: Any,
    child_lines: list[Any],
    klus: list[Any],
    rhythm_calc_mode: str = RHYTHM_CALC_MODE_NORMAL,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Build rhythm lines for one parent structure.

    节奏线横向画在相邻回调拐点之间：
    - 下降：顶2 -> 顶3
    - 上升：底2 -> 底3
    纵向价格仍沿用历史回调比例。
    """
    parent_dir = getattr(parent_line, "dir", None)
    if parent_dir not in (BI_DIR.UP, BI_DIR.DOWN):
        return [], []
    seq = build_alternating_child_sequence(child_lines, parent_dir)
    if len(seq) < 4:
        return [], []

    calc_mode = normalize_rhythm_calc_mode(rhythm_calc_mode)
    parent_key = make_line_key(parent_level, parent_line)
    parent_label = rhythm_level_label(parent_level)
    level_label_cn = rhythm_level_label(level)
    a0 = float(parent_line.get_begin_val())
    lines: list[dict[str, Any]] = []
    hits: list[dict[str, Any]] = []
    max_round = max(0, (len(seq) - 2) // 2)

    for round_current in range(1, max_round + 1):
        d_line = seq[2 * round_current]
        line_start = seq[2 * round_current - 1]
        line_end = seq[2 * round_current + 1]
        d_val = float(d_line.get_end_val())
        gate_b_line = seq[2 * (round_current - 1)]
        gate_c_line = seq[2 * (round_current - 1) + 1]
        gate_b_val = float(gate_b_line.get_end_val())
        gate_c_val = float(gate_c_line.get_end_val())
        gate_threshold = rhythm_1382_threshold(parent_dir, prev_same_val=gate_b_val, opposite_val=gate_c_val)
        if not abs(gate_threshold) < float("inf"):
            continue
        if not rhythm_retrace_allowed(calc_mode, parent_dir, b_val=gate_b_val, d_val=d_val, threshold=float(gate_threshold)):
            continue
        has_self_line_for_hit = False
        for round_ref in range(1, round_current + 1):
            b_line = seq[2 * (round_ref - 1)]
            c_line = seq[2 * (round_ref - 1) + 1]
            b_val = float(b_line.get_end_val())
            c_val = float(c_line.get_end_val())
            if parent_dir == BI_DIR.UP:
                denom = b_val - a0
                ratio = (b_val - c_val) / denom if abs(denom) > 1e-12 else None
                rhythm_price = d_val - (d_val - a0) * ratio if ratio is not None else None
                threshold = rhythm_1382_threshold(parent_dir, prev_same_val=b_val, opposite_val=c_val) if ratio is not None else None
            else:
                denom = a0 - b_val
                ratio = (c_val - b_val) / denom if abs(denom) > 1e-12 else None
                rhythm_price = d_val + (a0 - d_val) * ratio if ratio is not None else None
                threshold = rhythm_1382_threshold(parent_dir, prev_same_val=b_val, opposite_val=c_val) if ratio is not None else None
            if ratio is None or rhythm_price is None or threshold is None:
                continue
            if not (ratio >= 0 and abs(rhythm_price) < float("inf") and abs(threshold) < float("inf")):
                continue
            layer_idx = rhythm_layer_index(round_current, round_ref)
            label_left = f"{round_ref}-{layer_idx}"
            label_right = format_rhythm_ratio(ratio)
            color_group = f"rhythm{round_ref}"
            lines.append(
                {
                    "key": f"{parent_key}|line|{round_ref}|{layer_idx}",
                    "level": level,
                    "parent_level": parent_level,
                    "parent_key": parent_key,
                    "parent_label": parent_label,
                    "display_label": make_rhythm_display_label(round_current, round_ref),
                    "round_current": round_current,
                    "round_ref": round_ref,
                    "layer": layer_idx,
                    "calc_mode": calc_mode,
                    "color_group": color_group,
                    "dir": "UP" if parent_dir == BI_DIR.UP else "DOWN",
                    "ratio": float(ratio),
                    "label_left": label_left,
                    "label_right": label_right,
                    "x1": line_end_x(line_start),
                    "y1": float(rhythm_price),
                    "x2": line_end_x(line_end),
                    "y2": float(rhythm_price),
                }
            )
            if round_ref == round_current:
                gate_c_line = c_line
                gate_threshold = float(threshold)
                has_self_line_for_hit = True
        if not has_self_line_for_hit:
            continue
        for hit in find_1382_hits(klus, start_x=line_end_x(gate_c_line), direction=parent_dir, threshold=float(gate_threshold)):
            hit_key = f"{parent_key}|1382|{level}|{round_current}|{int(hit['x'])}"
            hits.append(
                {
                    "key": hit_key,
                    "x": int(hit["x"]),
                    "y": float(hit["y"]),
                    "level": level,
                    "parent_level": parent_level,
                    "parent_key": parent_key,
                    "display_label": f"{level_label_cn}1382",
                    "round_ref": round_current,
                    "color_group": f"rhythm{round_current}",
                    "dir": "UP" if parent_dir == BI_DIR.UP else "DOWN",
                    "threshold": float(threshold),
                    "time": hit["time"],
                    "detail": (
                        f"{level_label_cn}1382\n"
                        f"时间：{hit['time']}\n"
                        f"父结构：{parent_label}\n"
                        f"方向：{'上升' if parent_dir == BI_DIR.UP else '下降'}\n"
                        f"轮次：第{round_current}次回调\n"
                        f"阈值价：{float(threshold):.3f}\n"
                        f"触发价：{hit['price_field']}={float(hit['price_value']):.3f}"
                    ),
                }
            )
    return lines, hits


def build_rhythm_structures(
    *,
    kl_list: Any,
    fract_children: list[Any],
    bi_children: list[Any],
    seg_children: list[Any],
    bi_parents: Any,
    seg_parents: Any,
    segseg_parents: Any,
    rhythm_calc_mode: str = RHYTHM_CALC_MODE_NORMAL,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    all_lines: list[dict[str, Any]] = []
    all_hits: list[dict[str, Any]] = []
    klus = iter_klus(kl_list)
    mappings = [
        ("fract", "bi", fract_children, list(bi_parents)),
        ("bi", "seg", bi_children, list(seg_parents)),
        ("seg", "segseg", seg_children, list(segseg_parents)),
    ]
    for level, parent_level, source_children, parents in mappings:
        for parent_line in parents:
            parent_children = child_lines_for_parent_rhythm(parent_line, source_children)
            lines, hits = build_parent_rhythm_entries(
                level=level,
                parent_level=parent_level,
                parent_line=parent_line,
                child_lines=parent_children,
                klus=klus,
                rhythm_calc_mode=rhythm_calc_mode,
            )
            all_lines.extend(lines)
            all_hits.extend(hits)
    all_lines.sort(key=lambda item: (int(item["x1"]), int(item["round_ref"]), int(item["round_current"]), str(item["display_label"])))
    dedup_hits: dict[str, dict[str, Any]] = {}
    for item in sorted(all_hits, key=lambda entry: (int(entry["x"]), int(entry["round_ref"]), str(entry["level"]))):
        dedup_hits[str(item["key"])] = item
    return all_lines, list(dedup_hits.values())


def build_level_zs(base_lines: Any, upper_lines: Any, zs_conf) -> CZSList:
    zs_list = CZSList(zs_config=zs_conf)
    try:
        zs_list.cal_bi_zs(base_lines, upper_lines)
        update_zs_in_seg(base_lines, upper_lines, zs_list)
    except Exception:
        return CZSList(zs_config=zs_conf)
    return zs_list


def empty_zs_list(zs_conf) -> CZSList:
    return CZSList(zs_config=zs_conf)


def build_level_bsp(base_lines: Any, upper_lines: Any, bsp_conf) -> CBSPointList:
    bsp_list = CBSPointList(bs_point_config=bsp_conf)
    try:
        bsp_list.cal(base_lines, upper_lines)
    except Exception:
        return CBSPointList(bs_point_config=bsp_conf)
    return bsp_list


def empty_bsp_list(bsp_conf) -> CBSPointList:
    return CBSPointList(bs_point_config=bsp_conf)


def ensure_recursive_seg_klc_anchors(line: Any) -> None:
    """a_高阶适配：给 CSeg[CSeg] 补官方 cal_seg 需要的 begin_klc/end_klc。"""
    if not isinstance(line, CSeg):
        return
    start = getattr(line, "start_bi", None)
    end = getattr(line, "end_bi", None)
    ensure_recursive_seg_klc_anchors(start)
    ensure_recursive_seg_klc_anchors(end)
    begin_klc = getattr(start, "begin_klc", None)
    end_klc = getattr(end, "end_klc", None)
    if begin_klc is not None:
        line.begin_klc = begin_klc
    if end_klc is not None:
        line.end_klc = end_klc


def prepare_recursive_seg_source(source_lines: Any) -> None:
    # 官方 Combine_Item 在高阶递推时会访问 start_bi.begin_klc/end_bi.end_klc。
    for line in source_lines or []:
        ensure_recursive_seg_klc_anchors(line)


def build_hidden_seg_layer(source_lines: Any, conf: CChanConfig):
    # 经典递推：仿照 KLine_List 中「段 -> 2段」，继续用 cal_seg 做 N段 -> N+1段。
    hidden_seg_list = get_seglist_instance(seg_config=conf.seg_conf, lv=SEG_TYPE.SEG)
    try:
        prepare_recursive_seg_source(source_lines)
        cal_seg(source_lines, hidden_seg_list, -1)
    except Exception:
        return get_seglist_instance(seg_config=conf.seg_conf, lv=SEG_TYPE.SEG)
    return hidden_seg_list


def _max_extra_level_needed(lazy: dict[str, Any]) -> int:
    max_n = 0
    for level, enabled in (lazy.get("line_levels") or {}).items():
        n = custom_seg_level_num(level)
        if enabled and n is not None and n >= 3:
            max_n = max(max_n, n)
    for group_name in ("bsp_levels", "zs_levels"):
        for level, enabled in (lazy.get(group_name) or {}).items():
            n = custom_seg_level_num(level)
            if enabled and n is not None and n >= 3:
                # BSP/中枢需要上一级结构作为 parents。
                max_n = max(max_n, n + 1)
    return max_n


def build_extra_seg_chain(base_segseg: Any, conf: CChanConfig, lazy: dict[str, Any], *, new_algo: bool = False) -> dict[str, Any]:
    max_n = _max_extra_level_needed(lazy)
    if max_n < 3:
        return {}
    out: dict[str, Any] = {}
    prev = base_segseg
    for n in range(3, max_n + 1):
        level = seg_level_id(n)
        prev = build_new_seg_list(prev, f"new_chan_{level}") if new_algo else build_hidden_seg_layer(prev, conf)
        out[level] = prev
    return out


def build_extra_zs_and_bsp(extra_lines: dict[str, Any], conf: CChanConfig, lazy: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    extra_zs: dict[str, Any] = {}
    extra_bsp: dict[str, Any] = {}
    for level, base in sorted(extra_lines.items(), key=lambda kv: bsp_level_sort_order(kv[0])):
        n = custom_seg_level_num(level)
        if n is None:
            continue
        upper = extra_lines.get(seg_level_id(n + 1))
        if upper is None:
            continue
        if chart_lazy_zs_enabled(lazy, level):
            extra_zs[level] = build_level_zs(base, upper, conf.zs_conf)
        if chart_lazy_bsp_enabled(lazy, level):
            extra_bsp[level] = build_level_bsp(base, upper, conf.seg_bs_point_conf)
    return extra_zs, extra_bsp


def _line_list_raw_items(lines: Any) -> Any:
    """结构列表原始容器：少复制整表，只看尾巴。"""
    if lines is None:
        return []
    raw = getattr(lines, "lst", None)
    if isinstance(raw, (list, tuple)):
        return raw
    raw = getattr(lines, "bi_list", None)
    if isinstance(raw, (list, tuple)):
        return raw
    try:
        return list(lines)
    except Exception:
        return []


def line_list_light_signature(lines: Any, tail: int = 2) -> tuple[Any, ...]:
    try:
        arr = _line_list_raw_items(lines)
    except Exception:
        return (0,)
    sig: list[Any] = [len(arr)]
    for line in arr[-max(1, int(tail)):]:
        try:
            sig.append(
                (
                    int(line.get_begin_klu().idx),
                    int(line.get_end_klu().idx),
                    bool(getattr(line, "is_sure", False)),
                    float(line.get_begin_val()),
                    float(line.get_end_val()),
                )
            )
        except Exception:
            sig.append(("?", bool(getattr(line, "is_sure", False))))
    return tuple(sig)


def line_list_structural_signature(lines: Any, tail: int = 3) -> tuple[Any, ...]:
    """结构签名：段数 + 尾部端点 idx/确认态；忽略形成中价位浮动，减少逐K无效重算。"""
    try:
        arr = _line_list_raw_items(lines)
    except Exception:
        return (0,)
    sig: list[Any] = [len(arr)]
    for line in arr[-max(1, int(tail)):]:
        try:
            sig.append(
                (
                    int(line.get_begin_klu().idx),
                    int(line.get_end_klu().idx),
                    bool(getattr(line, "is_sure", False)),
                )
            )
        except Exception:
            sig.append(("?", bool(getattr(line, "is_sure", False))))
    return tuple(sig)


def _bsp_list_flat_len(bsp_list: Any) -> int:
    """BSP 列表扁平长度：用于判断是否有新增买卖点。"""
    if bsp_list is None:
        return 0
    try:
        return int(len(bsp_list))
    except Exception:
        return 0


def _bsp_raw_freeze_key(level: str, bsp: Any) -> str:
    """逐K冻结key：只看级别、锚点、方向，不让未来组合标签回写。"""
    klu = getattr(bsp, "klu", None)
    if klu is None:
        bi = getattr(bsp, "bi", None)
        try:
            klu = bi.get_end_klu() if bi is not None else None
        except Exception:
            klu = None
    x = int(getattr(klu, "idx", -1))
    return f"{level}|{x}|{1 if bool(getattr(bsp, 'is_buy', False)) else 0}"


def _bsp_type_key(bsp_type: Any) -> str:
    return str(getattr(bsp_type, "value", getattr(bsp_type, "name", bsp_type)))


def line_list_full_signature(lines: Any) -> tuple[Any, ...]:
    """完整结构签名：少猜一点，结构没变才复用 BSP。"""
    try:
        arr = _line_list_raw_items(lines)
    except Exception:
        return (0,)
    sig: list[Any] = [len(arr)]
    for line in arr:
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


def build_classic_bundle(
    chan: CChan,
    rhythm_calc_mode: str = RHYTHM_CALC_MODE_NORMAL,
    chart_lazy_layers: Optional[dict[str, Any]] = None,
) -> ChanStructureBundle:
    kl_list = chan[0]
    conf = chan.conf
    lazy = normalize_chart_lazy_layers(chart_lazy_layers)
    need_hidden_upper = chart_lazy_zs_enabled(lazy, "segseg") or chart_lazy_bsp_enabled(lazy, "segseg") or _max_extra_level_needed(lazy) >= 3
    segsegseg_list = build_hidden_seg_layer(kl_list.segseg_list, conf) if need_hidden_upper else SimpleLineList()
    extra_lines = build_extra_seg_chain(kl_list.segseg_list, conf, lazy, new_algo=False)
    if need_hidden_upper and "seg3" not in extra_lines:
        extra_lines["seg3"] = segsegseg_list
    extra_zs, extra_bsp = build_extra_zs_and_bsp(extra_lines, conf, lazy)
    requested_extra_lines = set(extra_seg_levels_from_layers(lazy))
    for level in extra_bsp_levels_from_layers(lazy):
        trig = judge_trigger_level(level)
        if custom_seg_level_num(trig) is not None:
            requested_extra_lines.add(trig)
    fract_list = SimpleLineList()
    # 与「新缠」分型层一致：由分型端点构造的简笔链，再相对官方 bi_list 计算分型中枢
    need_fract_children = chart_lazy_zs_enabled(lazy, "fract") or bool(lazy.get("rhythm")) or bool(lazy.get("rhythm_hits"))
    rhythm_fract_children = build_new_bi_list(kl_list) if need_fract_children else []
    fractzs_list = (
        build_level_zs(rhythm_fract_children, kl_list.bi_list, conf.zs_conf)
        if chart_lazy_zs_enabled(lazy, "fract")
        else empty_zs_list(conf.zs_conf)
    )
    segsegzs_list = (
        build_level_zs(kl_list.segseg_list, segsegseg_list, conf.zs_conf)
        if chart_lazy_zs_enabled(lazy, "segseg")
        else empty_zs_list(conf.zs_conf)
    )
    segseg_bs_point_lst = (
        build_level_bsp(kl_list.segseg_list, segsegseg_list, conf.seg_bs_point_conf)
        if chart_lazy_bsp_enabled(lazy, "segseg")
        else empty_bsp_list(conf.seg_bs_point_conf)
    )
    if bool(lazy.get("rhythm")) or bool(lazy.get("rhythm_hits")):
        rhythm_lines, rhythm_hits = build_rhythm_structures(
            kl_list=kl_list,
            fract_children=rhythm_fract_children,
            bi_children=list(kl_list.bi_list),
            seg_children=list(kl_list.seg_list),
            bi_parents=kl_list.bi_list,
            seg_parents=kl_list.seg_list,
            segseg_parents=kl_list.segseg_list,
            rhythm_calc_mode=rhythm_calc_mode,
        )
        if not bool(lazy.get("rhythm")):
            rhythm_lines = []
        if not bool(lazy.get("rhythm_hits")):
            rhythm_hits = []
    else:
        rhythm_lines, rhythm_hits = [], []
    return ChanStructureBundle(
        chan_algo=CHAN_ALGO_CLASSIC,
        fract_list=fract_list,
        bi_list=kl_list.bi_list,
        seg_list=kl_list.seg_list,
        segseg_list=kl_list.segseg_list,
        segsegseg_list=segsegseg_list,
        fractzs_list=fractzs_list,
        zs_list=kl_list.zs_list if chart_lazy_zs_enabled(lazy, "bi") else empty_zs_list(conf.zs_conf),
        segzs_list=kl_list.segzs_list if chart_lazy_zs_enabled(lazy, "seg") else empty_zs_list(conf.zs_conf),
        segsegzs_list=segsegzs_list,
        bs_point_lst=kl_list.bs_point_lst if chart_lazy_bsp_enabled(lazy, "bi") else empty_bsp_list(conf.bs_point_conf),
        seg_bs_point_lst=kl_list.seg_bs_point_lst if chart_lazy_bsp_enabled(lazy, "seg") else empty_bsp_list(conf.seg_bs_point_conf),
        segseg_bs_point_lst=segseg_bs_point_lst,
        trend_lines=build_trend_lines_from_bi_list(list(kl_list.bi_list)),
        fx_lines=build_fx_lines(kl_list),
        rhythm_lines=rhythm_lines,
        rhythm_hits=rhythm_hits,
        extra_line_lists={k: v for k, v in extra_lines.items() if k in requested_extra_lines},
        extra_zs_lists=extra_zs,
        extra_bsp_lists=extra_bsp,
    )


def build_new_bundle(
    chan: CChan,
    rhythm_calc_mode: str = RHYTHM_CALC_MODE_NORMAL,
    chart_lazy_layers: Optional[dict[str, Any]] = None,
) -> ChanStructureBundle:
    kl_list = chan[0]
    conf = chan.conf
    lazy = normalize_chart_lazy_layers(chart_lazy_layers)
    # 新缠论：分型端点 -> 新K线 -> 分型 -> 笔 -> 段 -> 2段；额外再递推一层隐藏结构支撑 2段 中枢/BSP。
    fract_list = build_new_bi_list(kl_list)
    bi_list = build_new_seg_list(fract_list, "new_chan_bi")
    seg_list = build_new_seg_list(bi_list, "new_chan_seg")
    segseg_list = build_new_seg_list(seg_list, "new_chan_segseg")
    need_hidden_upper = chart_lazy_zs_enabled(lazy, "segseg") or chart_lazy_bsp_enabled(lazy, "segseg") or _max_extra_level_needed(lazy) >= 3
    segsegseg_list = build_new_seg_list(segseg_list, "new_chan_hidden_upper") if need_hidden_upper else SimpleLineList()
    extra_lines = build_extra_seg_chain(segseg_list, conf, lazy, new_algo=True)
    if need_hidden_upper and "seg3" not in extra_lines:
        extra_lines["seg3"] = segsegseg_list
    extra_zs, extra_bsp = build_extra_zs_and_bsp(extra_lines, conf, lazy)
    requested_extra_lines = set(extra_seg_levels_from_layers(lazy))
    for level in extra_bsp_levels_from_layers(lazy):
        trig = judge_trigger_level(level)
        if custom_seg_level_num(trig) is not None:
            requested_extra_lines.add(trig)
    fractzs_list = build_level_zs(fract_list, bi_list, conf.zs_conf) if chart_lazy_zs_enabled(lazy, "fract") else empty_zs_list(conf.zs_conf)
    zs_list = build_level_zs(bi_list, seg_list, conf.zs_conf) if chart_lazy_zs_enabled(lazy, "bi") else empty_zs_list(conf.zs_conf)
    segzs_list = build_level_zs(seg_list, segseg_list, conf.zs_conf) if chart_lazy_zs_enabled(lazy, "seg") else empty_zs_list(conf.zs_conf)
    segsegzs_list = (
        build_level_zs(segseg_list, segsegseg_list, conf.zs_conf)
        if chart_lazy_zs_enabled(lazy, "segseg")
        else empty_zs_list(conf.zs_conf)
    )
    bs_point_lst = build_level_bsp(bi_list, seg_list, conf.bs_point_conf) if chart_lazy_bsp_enabled(lazy, "bi") else empty_bsp_list(conf.bs_point_conf)
    seg_bs_point_lst = build_level_bsp(seg_list, segseg_list, conf.seg_bs_point_conf) if chart_lazy_bsp_enabled(lazy, "seg") else empty_bsp_list(conf.seg_bs_point_conf)
    segseg_bs_point_lst = build_level_bsp(segseg_list, segsegseg_list, conf.seg_bs_point_conf) if chart_lazy_bsp_enabled(lazy, "segseg") else empty_bsp_list(conf.seg_bs_point_conf)
    if bool(lazy.get("rhythm")) or bool(lazy.get("rhythm_hits")):
        rhythm_lines, rhythm_hits = build_rhythm_structures(
            kl_list=kl_list,
            fract_children=list(fract_list),
            bi_children=list(bi_list),
            seg_children=list(seg_list),
            bi_parents=bi_list,
            seg_parents=seg_list,
            segseg_parents=segseg_list,
            rhythm_calc_mode=rhythm_calc_mode,
        )
        if not bool(lazy.get("rhythm")):
            rhythm_lines = []
        if not bool(lazy.get("rhythm_hits")):
            rhythm_hits = []
    else:
        rhythm_lines, rhythm_hits = [], []
    return ChanStructureBundle(
        chan_algo=CHAN_ALGO_NEW,
        fract_list=fract_list,
        bi_list=bi_list,
        seg_list=seg_list,
        segseg_list=segseg_list,
        segsegseg_list=segsegseg_list,
        fractzs_list=fractzs_list,
        zs_list=zs_list,
        segzs_list=segzs_list,
        segsegzs_list=segsegzs_list,
        bs_point_lst=bs_point_lst,
        seg_bs_point_lst=seg_bs_point_lst,
        segseg_bs_point_lst=segseg_bs_point_lst,
        trend_lines=build_trend_lines_from_bi_list(bi_list),
        fx_lines=build_fx_lines(kl_list),
        rhythm_lines=rhythm_lines,
        rhythm_hits=rhythm_hits,
        extra_line_lists={k: v for k, v in extra_lines.items() if k in requested_extra_lines},
        extra_zs_lists=extra_zs,
        extra_bsp_lists=extra_bsp,
    )


def build_structure_bundle(
    chan: CChan,
    chan_algo: str,
    rhythm_calc_mode: str = RHYTHM_CALC_MODE_NORMAL,
    chart_lazy_layers: Optional[dict[str, Any]] = None,
) -> ChanStructureBundle:
    algo = normalize_chan_algo(chan_algo)
    return (
        build_new_bundle(chan, rhythm_calc_mode, chart_lazy_layers)
        if algo == CHAN_ALGO_NEW
        else build_classic_bundle(chan, rhythm_calc_mode, chart_lazy_layers)
    )


def get_bundle_line_list(bundle: ChanStructureBundle, level: str):
    if str(level) in (bundle.extra_line_lists or {}):
        return bundle.extra_line_lists[str(level)]
    mapping = {
        "fract": bundle.fract_list,
        "bi": bundle.bi_list,
        "seg": bundle.seg_list,
        "segseg": bundle.segseg_list,
        "segsegseg": bundle.segsegseg_list,
    }
    return mapping[level]


def get_bundle_bsp_list(bundle: ChanStructureBundle, level: str):
    if str(level) in (bundle.extra_bsp_lists or {}):
        return bundle.extra_bsp_lists[str(level)]
    mapping = {
        "bi": bundle.bs_point_lst,
        "seg": bundle.seg_bs_point_lst,
        "segseg": bundle.segseg_bs_point_lst,
    }
    return mapping[level]


def level_label(level: str) -> str:
    return dynamic_level_label(level)


def make_bsp_item(level: str, bsp) -> dict[str, Any]:
    label = bsp.type2str()
    display_label = f"{level_label(level)}{label}"
    return {
        "x": int(bsp.klu.idx),
        "y": float(bsp.klu.low if bsp.is_buy else bsp.klu.high),
        "is_buy": bool(bsp.is_buy),
        "label": label,
        "level": level,
        "level_label": level_label(level),
        "display_label": display_label,
    }


def serialize_line_collection(lines: Any) -> list[dict[str, Any]]:
    arr = []
    for line in lines:
        arr.append(
            {
                "x1": int(line.get_begin_klu().idx),
                "y1": float(line.get_begin_val()),
                "x2": int(line.get_end_klu().idx),
                "y2": float(line.get_end_val()),
                "is_sure": bool(line.is_sure),
            }
        )
    return arr


def serialize_zs_collection(zs_list: Any) -> list[dict[str, Any]]:
    arr = []
    for zs in zs_list:
        arr.append(
            {
                "x1": int(zs.begin.idx),
                "x2": int(zs.end.idx),
                "low": float(zs.low),
                "high": float(zs.high),
                "is_sure": bool(zs.is_sure),
                "is_one_bi_zs": bool(zs.is_one_bi_zs()),
            }
        )
    return arr


def serialize_bsp_collection(level: str, bsp_list: Any) -> list[dict[str, Any]]:
    return [make_bsp_item(level, bsp) for bsp in bsp_list.bsp_iter()]


def normalize_code(raw: str) -> str:
    raw = raw.strip()
    if len(raw) == 0:
        raise ValueError("代码不能为空")
    if raw.startswith("sh.") or raw.startswith("sz."):
        return raw
    if len(raw) != 6 or not raw.isdigit():
        raise ValueError("代码必须为6位数字，例如 000001")
    return ("sh." if raw.startswith("6") else "sz.") + raw


@dataclass
class PaperAccount:
    initial_cash: float
    cash: float
    position: int = 0
    avg_cost: float = 0.0
    # 最近一次开仓步（多/空通用），用于与原有做多一致的 T+1 平仓限制
    last_open_step: Optional[int] = None
    last_trade_step: Optional[int] = None
    # 本 K 步内刚平多→仅允许再开空；刚平空→仅允许再开多（与「每步一笔」叠加）
    same_step_flip_side: Optional[str] = None
    same_step_flip_at_idx: Optional[int] = None

    def _sync_flip_scope(self, step_idx: int) -> None:
        if self.same_step_flip_at_idx is None:
            return
        if step_idx != self.same_step_flip_at_idx:
            self.same_step_flip_side = None
            self.same_step_flip_at_idx = None

    def reset(self, initial_cash: float) -> None:
        self.initial_cash = initial_cash
        self.cash = initial_cash
        self.position = 0
        self.avg_cost = 0.0
        self.last_open_step = None
        self.last_trade_step = None
        self.same_step_flip_side = None
        self.same_step_flip_at_idx = None

    def buy_with_all_cash(self, price: float, step_idx: int) -> dict[str, Any]:
        self._sync_flip_scope(step_idx)
        if self.position != 0:
            raise ValueError("当前已有持仓，需先平仓后再开多。")
        if self.last_trade_step == step_idx:
            if not (self.same_step_flip_side == "buy" and self.same_step_flip_at_idx == step_idx):
                raise ValueError("每一步最多允许一笔成交。")
        hand_cost = price * 100
        hands = int(self.cash // hand_cost)
        if hands <= 0:
            raise ValueError("余额不足一手。")
        cost = hands * hand_cost
        if cost > self.cash + 1e-8:
            raise ValueError("余额不足。")
        self.cash -= cost
        self.position = hands * 100
        self.avg_cost = price
        self.last_open_step = step_idx
        self.last_trade_step = step_idx
        self.same_step_flip_side = None
        self.same_step_flip_at_idx = None
        return {"hands": hands, "shares": self.position, "cost": round(cost, 2)}

    def can_sell(self, step_idx: int) -> bool:
        if self.position <= 0:
            return False
        if self.last_open_step is None:
            return False
        return step_idx >= self.last_open_step + 1

    def sell_all(self, price: float, step_idx: int) -> dict[str, Any]:
        self._sync_flip_scope(step_idx)
        if self.position <= 0:
            return {"noop": True, "message": "当前无持仓。"}
        if self.last_trade_step == step_idx:
            raise ValueError("每一步最多允许一笔成交。")
        if not self.can_sell(step_idx):
            raise ValueError("受T+1限制，下一根K线后才能卖出。")
        shares = self.position
        proceeds = shares * price
        pnl = (price - self.avg_cost) * shares
        self.cash += proceeds
        self.position = 0
        self.avg_cost = 0.0
        self.last_open_step = None
        self.last_trade_step = step_idx
        # 平多当步可反手开空
        self.same_step_flip_side = "short"
        self.same_step_flip_at_idx = step_idx
        return {
            "shares": shares,
            "proceeds": round(proceeds, 2),
            "pnl": round(pnl, 2),
        }

    def short_with_all_cash(self, price: float, step_idx: int) -> dict[str, Any]:
        """做空开仓：逻辑与做多开仓一致（单持仓 + 每步仅一笔 + 全仓按整手）。"""
        self._sync_flip_scope(step_idx)
        if self.position != 0:
            raise ValueError("当前已有持仓，需先平仓后再开空。")
        if self.last_trade_step == step_idx:
            if not (self.same_step_flip_side == "short" and self.same_step_flip_at_idx == step_idx):
                raise ValueError("每一步最多允许一笔成交。")
        hand_cost = price * 100
        hands = int(self.cash // hand_cost)
        if hands <= 0:
            raise ValueError("余额不足一手。")
        shares = hands * 100
        proceeds = shares * price
        # 简化撮合：做空卖出所得计入现金，权益用 cash + position*price 统一核算
        self.cash += proceeds
        self.position = -shares
        self.avg_cost = price
        self.last_open_step = step_idx
        self.last_trade_step = step_idx
        self.same_step_flip_side = None
        self.same_step_flip_at_idx = None
        return {
            "shares": shares,
            "proceeds": round(proceeds, 2),
        }

    def can_cover(self, step_idx: int) -> bool:
        if self.position >= 0:
            return False
        if self.last_open_step is None:
            return False
        return step_idx >= self.last_open_step + 1

    def cover_all(self, price: float, step_idx: int) -> dict[str, Any]:
        """平空：逻辑与做多平仓一致（每步仅一笔 + T+1）。"""
        self._sync_flip_scope(step_idx)
        if self.position >= 0:
            return {"noop": True, "message": "当前无空仓。"}
        if self.last_trade_step == step_idx:
            raise ValueError("每一步最多允许一笔成交。")
        if not self.can_cover(step_idx):
            raise ValueError("受T+1限制，下一根K线后才能平空。")
        shares = -self.position
        cost = shares * price
        pnl = (self.avg_cost - price) * shares
        self.cash -= cost
        self.position = 0
        self.avg_cost = 0.0
        self.last_open_step = None
        self.last_trade_step = step_idx
        # 平空当步可反手开多
        self.same_step_flip_side = "buy"
        self.same_step_flip_at_idx = step_idx
        return {
            "shares": shares,
            "cost": round(cost, 2),
            "pnl": round(pnl, 2),
        }

    def equity(self, price: float) -> float:
        return self.cash + self.position * price


class ChanStepper:
    def __init__(self) -> None:
        self.chan: Optional[CChan] = None
        self._iter = None
        self.step_idx = -1
        self.code = ""
        self.chan_algo = CHAN_ALGO_CLASSIC
        self.rhythm_calc_mode = RHYTHM_CALC_MODE_NORMAL
        self.k_type = KL_TYPE.K_DAY  # 默认日线
        self.effective_cfg_dict: dict[str, Any] = {}
        # Full history K-lines (used by chip distribution).
        self.kline_all: list[dict[str, Any]] = []
        self.indicators = {
            "macd": CMACD(),
            "kdj": KDJ(),
            "rsi": RSI(),
            "boll": BollModel(),
            "demark": CDemarkEngine(),
        }
        self.indicator_history = []
        self.trend_lines = []
        # 实际选用的源：K 线主序列与筹码全历史可不同，均由各自优先级链回退得到
        self.data_src_chip_used: Any = None
        # 会话级行情缓存：同一股票代码与日期区间下只拉取一次，缠论/BSP 配置变更时仅重算结构。
        self._data_session_key: Optional[tuple[Any, ...]] = None
        self._replay_klus_master: Optional[list] = None
        self._replay_klus_master_raw: Optional[list] = None
        self.data_src_used: Any = None
        self.data_src_logs: list[str] = []
        self.stock_name: Optional[str] = None
        self.structure_bundle: Optional[ChanStructureBundle] = None
        self._bundle_cache_step_idx: Optional[int] = None
        self._suppress_step_bundle_refresh = False
        self.data_form_mode: str = "traditional"
        self.data_form_quantity: int = 0
        self.data_form_quantity_alloc: str = "front"
        self.data_feed_mode: str = "step"
        self.offline_data_custom: str = "native"
        self.raw_kline_count: int = 0
        # 步进增量缓存：避免每次 payload 全量遍历 klu_iter()
        self._serialized_klu_cache: list[dict[str, Any]] = []
        # 同一步下的图表序列化缓存：键为是否包含 kline_all
        self._chart_payload_cache: dict[bool, tuple[int, dict[str, Any]]] = {}
        self.chart_lazy_layers = normalize_chart_lazy_layers(None)
        self._segseg_bsp_cache_key: Optional[tuple[Any, ...]] = None
        self._segseg_bsp_cache_value: Any = None
        self._hidden_seg_layer_cache: dict[str, dict[str, Any]] = {}
        self._level_zs_cache: dict[str, dict[str, Any]] = {}
        self._level_bsp_cache: dict[str, dict[str, Any]] = {}
        self._extra_bsp_cache_key: Optional[tuple[Any, ...]] = None
        self._extra_bsp_cache_value: dict[str, Any] = {}
        self._extra_lines_cache_key: Optional[tuple[Any, ...]] = None
        self._extra_lines_cache_value: dict[str, Any] = {}
        self._bsp_cache_stats: dict[str, Any] = {}
        self._step_perf_stats: dict[str, Any] = {}
        # unified 模式：全量一次性计算后，仅按 step_idx 切片显示
        self._unified_full_payload: Optional[dict[str, Any]] = None
        self._chan_record_apply: ChanRecordApplyResult = ChanRecordApplyResult()
        self._chan_record_fingerprint: str = ""
        self._chan_record_enabled: bool = False
        # Rust/Python 高性能过渡引擎会话：先接数据/筹码/步进增量层
        self.perf_session_id: Optional[str] = None
        self.perf_engine_mode: str = "rust-missing"
        self.rust_chan_state_id: Optional[str] = None
        self._rust_chan_shadow_disabled: bool = False
        self._rust_chan_primary_used: bool = False

    def _maybe_presentation_rust_shadow(self, ms: float, mismatch: Optional[str]) -> None:
        # shadow 关时只喂 bar 的旧路径已移除，此处再挡一层避免误记账
        if not rust_chan_shadow_enabled():
            return
        app = globals().get("APP_STATE")
        if app is None or not hasattr(app, "_presentation_perf_active"):
            return
        if not app._presentation_perf_active():
            return
        app._presentation_perf_add("rust_shadow_ms", ms)
        app._presentation_perf_inc("rust_shadow_calls")
        if mismatch:
            perf = getattr(app, "_presentation_perf", None)
            if isinstance(perf, dict) and perf.get("rust_shadow_mismatch_step") is None:
                perf["rust_shadow_mismatch_step"] = int(self.step_idx)
                push_record_trace(f"RustChan shadow: {mismatch}")

    def clear_bsp_signature_cache(self) -> None:
        """清掉结构签名 BSP 缓存：新会话、重配、图层变化才需要。"""
        self._segseg_bsp_cache_key = None
        self._segseg_bsp_cache_value = None
        self._hidden_seg_layer_cache = {}
        self._level_zs_cache = {}
        self._level_bsp_cache = {}
        self._extra_bsp_cache_key = None
        self._extra_bsp_cache_value = {}
        self._extra_lines_cache_key = None
        self._extra_lines_cache_value = {}

    def reset_bsp_cache_stats(self) -> None:
        """一次性呈现性能账本：只统计缓存命中，不参与计算。"""
        self._bsp_cache_stats = {
            "segseg_calls": 0,
            "segseg_hit": 0,
            "segseg_miss": 0,
            "segseg_ms": 0.0,
            "segseg_sig_ms": 0.0,
            "segseg_hidden_ms": 0.0,
            "segseg_zs_ms": 0.0,
            "segseg_bsp_ms": 0.0,
            "extra_calls": 0,
            "extra_empty": 0,
            "extra_hit": 0,
            "extra_miss": 0,
            "extra_ms": 0.0,
            "extra_sig_ms": 0.0,
            "extra_lines_hit": 0,
            "extra_lines_miss": 0,
            "extra_lines_ms": 0.0,
            "extra_lines_build_ms": 0.0,
            "extra_zs_bsp_ms": 0.0,
            "level_zs_hit": 0,
            "level_zs_miss": 0,
            "level_zs_ms": 0.0,
            "level_bsp_hit": 0,
            "level_bsp_miss": 0,
            "level_bsp_ms": 0.0,
        }

    def bsp_cache_stats_snapshot(self) -> dict[str, Any]:
        return dict(getattr(self, "_bsp_cache_stats", {}) or {})

    def reset_step_perf_stats(self) -> None:
        """一次性呈现 step 内部账本：只看热点，不参与计算。"""
        self._step_perf_stats = {
            "calls": 0,
            "iter_ms": 0.0,
            "clear_cache_ms": 0.0,
            "extract_klu_ms": 0.0,
            "kline_cache_ms": 0.0,
            "indicator_ms": 0.0,
            "demark_extract_ms": 0.0,
            "history_append_ms": 0.0,
            "bundle_ms": 0.0,
            "rust_shadow_ms": 0.0,
            "rust_shadow_calls": 0,
        }

    def step_perf_stats_snapshot(self) -> dict[str, Any]:
        return dict(getattr(self, "_step_perf_stats", {}) or {})

    def _step_perf_add(self, key: str, value: float) -> None:
        stats = getattr(self, "_step_perf_stats", None)
        if not isinstance(stats, dict) or not stats:
            return
        stats[key] = float(stats.get(key, 0.0)) + float(value)

    def _step_perf_inc(self, key: str, value: int = 1) -> None:
        stats = getattr(self, "_step_perf_stats", None)
        if not isinstance(stats, dict) or not stats:
            return
        stats[key] = int(stats.get(key, 0)) + int(value)

    def clear_structure_runtime_cache(self, *, clear_bsp_cache: bool = False) -> None:
        self.structure_bundle = None
        self._bundle_cache_step_idx = None
        self._chart_payload_cache = {}
        if clear_bsp_cache:
            self.clear_bsp_signature_cache()

    def hidden_seg_layer_cached(self, *, level: str, source_lines: Any, conf: CChanConfig, source_sig: Optional[tuple[Any, ...]] = None):
        """逐K隐藏级别复用官方增量段对象，避免每步全量重建。"""
        if source_lines is None:
            return get_seglist_instance(seg_config=conf.seg_conf, lv=SEG_TYPE.SEG)
        cache_key = str(level)
        entry = self._hidden_seg_layer_cache.get(cache_key)
        conf_id = id(conf.seg_conf)
        source_id = id(source_lines)
        if source_sig is None:
            source_sig = line_list_structural_signature(source_lines)
        if entry and entry.get("conf_id") == conf_id and entry.get("source_id") == source_id and entry.get("source_sig") == source_sig:
            return entry["lines"]
        if not entry or entry.get("conf_id") != conf_id or entry.get("source_id") != source_id:
            entry = {
                "conf_id": conf_id,
                "source_id": source_id,
                "source_sig": None,
                "lines": get_seglist_instance(seg_config=conf.seg_conf, lv=SEG_TYPE.SEG),
                "last_sure": -1,
            }
        hidden_seg_list = entry["lines"]
        try:
            prepare_recursive_seg_source(source_lines)
            entry["last_sure"] = cal_seg(source_lines, hidden_seg_list, int(entry.get("last_sure", -1)))
            entry["source_sig"] = source_sig
        except Exception:
            hidden_seg_list = get_seglist_instance(seg_config=conf.seg_conf, lv=SEG_TYPE.SEG)
            entry = {"conf_id": conf_id, "source_id": source_id, "source_sig": None, "lines": hidden_seg_list, "last_sure": -1}
        self._hidden_seg_layer_cache[cache_key] = entry
        return hidden_seg_list

    def level_zs_snapshot_cached(
        self,
        *,
        level: str,
        base_lines: Any,
        upper_lines: Any,
        conf: CChanConfig,
        base_sig: Optional[tuple[Any, ...]] = None,
        upper_sig: Optional[tuple[Any, ...]] = None,
    ):
        """中枢增量复用：用官方 last_sure 游标，不再额外算签名。"""
        t0 = time.perf_counter()
        stats = getattr(self, "_bsp_cache_stats", None)
        cache_key = str(level)
        key = (id(conf.zs_conf), id(base_lines), id(upper_lines))
        entry = self._level_zs_cache.get(cache_key)
        reused = bool(entry and entry.get("key") == key)
        if not reused:
            entry = {"key": key, "zs": CZSList(zs_config=conf.zs_conf)}
        zs_list = entry["zs"]
        try:
            zs_list.cal_bi_zs(base_lines, upper_lines)
            update_zs_in_seg(base_lines, upper_lines, zs_list)
        except Exception:
            zs_list = CZSList(zs_config=conf.zs_conf)
            entry = {"key": key, "zs": zs_list}
            reused = False
        self._level_zs_cache[cache_key] = entry
        if isinstance(stats, dict):
            stat_key = "level_zs_hit" if reused else "level_zs_miss"
            stats[stat_key] = int(stats.get(stat_key, 0)) + 1
            stats["level_zs_ms"] = float(stats.get("level_zs_ms", 0.0)) + (time.perf_counter() - t0) * 1000.0
        return zs_list

    def level_bsp_snapshot_cached(
        self,
        *,
        level: str,
        base_lines: Any,
        upper_lines: Any,
        bsp_conf: Any,
        base_sig: Optional[tuple[Any, ...]] = None,
        upper_sig: Optional[tuple[Any, ...]] = None,
    ):
        """BSP增量复用：逐K冻结仍靠外层账本，内部只复用官方游标。"""
        t0 = time.perf_counter()
        stats = getattr(self, "_bsp_cache_stats", None)
        cache_key = str(level)
        key = (id(bsp_conf), id(base_lines), id(upper_lines))
        entry = self._level_bsp_cache.get(cache_key)
        reused = bool(entry and entry.get("key") == key)
        if not reused:
            entry = {"key": key, "bsp": CBSPointList(bs_point_config=bsp_conf)}
        bsp_list = entry["bsp"]
        try:
            bsp_list.cal(base_lines, upper_lines)
        except Exception:
            bsp_list = CBSPointList(bs_point_config=bsp_conf)
            entry = {"key": key, "bsp": bsp_list}
            reused = False
        self._level_bsp_cache[cache_key] = entry
        if isinstance(stats, dict):
            stat_key = "level_bsp_hit" if reused else "level_bsp_miss"
            stats[stat_key] = int(stats.get(stat_key, 0)) + 1
            stats["level_bsp_ms"] = float(stats.get("level_bsp_ms", 0.0)) + (time.perf_counter() - t0) * 1000.0
        return bsp_list

    def extra_seg_chain_cached(self, *, base_segseg: Any, conf: CChanConfig, lazy_layers: dict[str, Any], base_sig: Optional[tuple[Any, ...]] = None) -> dict[str, Any]:
        max_n = _max_extra_level_needed(lazy_layers)
        if max_n < 3:
            return {}
        out: dict[str, Any] = {}
        prev = base_segseg
        for n in range(3, max_n + 1):
            level = seg_level_id(n)
            prev = self.hidden_seg_layer_cached(level=level, source_lines=prev, conf=conf, source_sig=base_sig if n == 3 else None)
            out[level] = prev
        return out

    def extra_zs_and_bsp_cached(self, *, extra_lines: dict[str, Any], conf: CChanConfig, lazy_layers: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
        extra_zs: dict[str, Any] = {}
        extra_bsp: dict[str, Any] = {}
        for level, base in sorted(extra_lines.items(), key=lambda kv: bsp_level_sort_order(kv[0])):
            n = custom_seg_level_num(level)
            if n is None:
                continue
            upper = extra_lines.get(seg_level_id(n + 1))
            if upper is None:
                continue
            if chart_lazy_zs_enabled(lazy_layers, level):
                extra_zs[level] = self.level_zs_snapshot_cached(
                    level=f"extra_zs:{level}",
                    base_lines=base,
                    upper_lines=upper,
                    conf=conf,
                )
            if chart_lazy_bsp_enabled(lazy_layers, level):
                extra_bsp[level] = self.level_bsp_snapshot_cached(
                    level=f"extra_bsp:{level}",
                    base_lines=base,
                    upper_lines=upper,
                    bsp_conf=conf.seg_bs_point_conf,
                )
        return extra_zs, extra_bsp

    def extra_bsp_snapshot_cached(
        self,
        *,
        segseg_list: Any,
        conf: CChanConfig,
        lazy_layers: dict[str, Any],
        source_sig: Optional[tuple[Any, ...]] = None,
    ) -> dict[str, Any]:
        """逐K当下性缓存：输入只来自当前已喂入结构，签名没变才复用。"""
        t0 = time.perf_counter()
        stats = getattr(self, "_bsp_cache_stats", None)
        if isinstance(stats, dict):
            stats["extra_calls"] = int(stats.get("extra_calls", 0)) + 1
        if segseg_list is None:
            if isinstance(stats, dict):
                stats["extra_empty"] = int(stats.get("extra_empty", 0)) + 1
                stats["extra_ms"] = float(stats.get("extra_ms", 0.0)) + (time.perf_counter() - t0) * 1000.0
            return {}
        wanted = tuple(extra_seg_levels_from_layers({"bsp_levels": lazy_layers.get("bsp_levels", {})}))
        if not wanted:
            if isinstance(stats, dict):
                stats["extra_empty"] = int(stats.get("extra_empty", 0)) + 1
                stats["extra_ms"] = float(stats.get("extra_ms", 0.0)) + (time.perf_counter() - t0) * 1000.0
            return {}
        sig_t0 = time.perf_counter()
        segseg_sig = source_sig if source_sig is not None else line_list_structural_signature(segseg_list)
        if isinstance(stats, dict):
            stats["extra_sig_ms"] = float(stats.get("extra_sig_ms", 0.0)) + (time.perf_counter() - sig_t0) * 1000.0
        key = (
            "extra_bsp",
            wanted,
            id(conf),
            id(conf.seg_conf),
            id(conf.zs_conf),
            id(conf.seg_bs_point_conf),
            segseg_sig,
        )
        if key == self._extra_bsp_cache_key:
            if isinstance(stats, dict):
                stats["extra_hit"] = int(stats.get("extra_hit", 0)) + 1
                stats["extra_ms"] = float(stats.get("extra_ms", 0.0)) + (time.perf_counter() - t0) * 1000.0
            return self._extra_bsp_cache_value
        lines_key = (
            "extra_lines",
            wanted,
            id(conf),
            id(conf.seg_conf),
            segseg_sig,
        )
        lines_t0 = time.perf_counter()
        if lines_key == self._extra_lines_cache_key:
            extra_lines = self._extra_lines_cache_value
            if isinstance(stats, dict):
                stats["extra_lines_hit"] = int(stats.get("extra_lines_hit", 0)) + 1
                stats["extra_lines_ms"] = float(stats.get("extra_lines_ms", 0.0)) + (time.perf_counter() - lines_t0) * 1000.0
        else:
            extra_lines = self.extra_seg_chain_cached(base_segseg=segseg_list, conf=conf, lazy_layers=lazy_layers, base_sig=segseg_sig)
            self._extra_lines_cache_key = lines_key
            self._extra_lines_cache_value = extra_lines
            if isinstance(stats, dict):
                stats["extra_lines_miss"] = int(stats.get("extra_lines_miss", 0)) + 1
                lines_ms = (time.perf_counter() - lines_t0) * 1000.0
                stats["extra_lines_ms"] = float(stats.get("extra_lines_ms", 0.0)) + lines_ms
                stats["extra_lines_build_ms"] = float(stats.get("extra_lines_build_ms", 0.0)) + lines_ms
        build_t0 = time.perf_counter()
        _, extra_bsp = self.extra_zs_and_bsp_cached(extra_lines=extra_lines, conf=conf, lazy_layers=lazy_layers)
        if isinstance(stats, dict):
            stats["extra_zs_bsp_ms"] = float(stats.get("extra_zs_bsp_ms", 0.0)) + (time.perf_counter() - build_t0) * 1000.0
        self._extra_bsp_cache_key = key
        self._extra_bsp_cache_value = extra_bsp
        if isinstance(stats, dict):
            stats["extra_miss"] = int(stats.get("extra_miss", 0)) + 1
            stats["extra_ms"] = float(stats.get("extra_ms", 0.0)) + (time.perf_counter() - t0) * 1000.0
        return extra_bsp

    def segseg_bsp_snapshot_cached(self, *, segseg_list: Any, conf: CChanConfig, source_sig: Optional[tuple[Any, ...]] = None):
        """一次性逐K：2段结构没变时，复用隐藏上级和 BSP 结果。"""
        t0 = time.perf_counter()
        stats = getattr(self, "_bsp_cache_stats", None)
        if isinstance(stats, dict):
            stats["segseg_calls"] = int(stats.get("segseg_calls", 0)) + 1
        if segseg_list is None:
            if isinstance(stats, dict):
                stats["segseg_ms"] = float(stats.get("segseg_ms", 0.0)) + (time.perf_counter() - t0) * 1000.0
            return None
        sig_t0 = time.perf_counter()
        segseg_sig = source_sig if source_sig is not None else line_list_structural_signature(segseg_list)
        if isinstance(stats, dict):
            stats["segseg_sig_ms"] = float(stats.get("segseg_sig_ms", 0.0)) + (time.perf_counter() - sig_t0) * 1000.0
        key = (
            "segseg_bsp",
            id(conf),
            id(conf.seg_conf),
            id(conf.zs_conf),
            id(conf.seg_bs_point_conf),
            segseg_sig,
        )
        if key == self._segseg_bsp_cache_key:
            if isinstance(stats, dict):
                stats["segseg_hit"] = int(stats.get("segseg_hit", 0)) + 1
                stats["segseg_ms"] = float(stats.get("segseg_ms", 0.0)) + (time.perf_counter() - t0) * 1000.0
            return self._segseg_bsp_cache_value
        hidden_t0 = time.perf_counter()
        segsegseg_list = self.hidden_seg_layer_cached(level="seg3", source_lines=segseg_list, conf=conf, source_sig=segseg_sig)
        if isinstance(stats, dict):
            stats["segseg_hidden_ms"] = float(stats.get("segseg_hidden_ms", 0.0)) + (time.perf_counter() - hidden_t0) * 1000.0
        # 2段 BSP 先挂中枢，保持原来的当下性计算口径。
        zs_t0 = time.perf_counter()
        self.level_zs_snapshot_cached(
            level="segseg_zs",
            base_lines=segseg_list,
            upper_lines=segsegseg_list,
            conf=conf,
        )
        if isinstance(stats, dict):
            stats["segseg_zs_ms"] = float(stats.get("segseg_zs_ms", 0.0)) + (time.perf_counter() - zs_t0) * 1000.0
        bsp_t0 = time.perf_counter()
        bsp_list = self.level_bsp_snapshot_cached(
            level="segseg_bsp",
            base_lines=segseg_list,
            upper_lines=segsegseg_list,
            bsp_conf=conf.seg_bs_point_conf,
        )
        if isinstance(stats, dict):
            stats["segseg_bsp_ms"] = float(stats.get("segseg_bsp_ms", 0.0)) + (time.perf_counter() - bsp_t0) * 1000.0
        self._segseg_bsp_cache_key = key
        self._segseg_bsp_cache_value = bsp_list
        if isinstance(stats, dict):
            stats["segseg_miss"] = int(stats.get("segseg_miss", 0)) + 1
            stats["segseg_ms"] = float(stats.get("segseg_ms", 0.0)) + (time.perf_counter() - t0) * 1000.0
        return bsp_list

    def _cfg_without_chan_algo(self, cfg_dict: dict[str, Any]) -> dict[str, Any]:
        # 训练器 / API 自用键，勿传入 CChanConfig（否则会触发 unknown para）
        skip = frozenset(
            {
                "chan_algo",
                "data_source_priority",
                "confirm_offline",
                "chart_mode",
                "k_type",
                "k_type_2",
                "k_types_multi",
                "active_chart_id",
                "initial_cash",
                "data_form_mode",
                "data_form_quantity",
                "data_form_quantity_alloc",
                "offline_data_custom",
                "kline_presentation_mode",
                "rhythm_calc_mode",
            }
        )
        return {k: v for k, v in cfg_dict.items() if k not in skip}

    def _fetch_from_single_source(
        self,
        data_src: Any,
        begin_date: str,
        end_date: Optional[str],
        autype: AUTYPE,
        chan_cfg_dict: dict[str, Any],
        use_for: str = "kline",  # "kline" 或 "chip"
    ) -> tuple[list, list[dict[str, Any]], Optional[str]]:
        """从单一数据源获取K线数据。
        
        Args:
            use_for: "kline" 表示用于K线开高低收，"chip" 表示用于筹码成交量
        """
        cfg_fetch = CChanConfig({**chan_cfg_dict, "trigger_step": False})
        replay_klus_master: list = []
        # 先走 CChan 原生通道，若三方库在内部触发 IndexError 等异常，则回退到 API 直拉。
        try:
            fetch_chan = ReplayDataChan(
                code=self.code,
                begin_time=begin_date,
                end_time=end_date,
                data_src=data_src,
                lv_list=[self.k_type],
                config=cfg_fetch,
                autype=autype,
            )
            replay_klus_master = copy.deepcopy(list(fetch_chan[0].klu_iter()))
        except Exception as chan_exc:
            try:
                api_cls = get_stock_api_cls(data_src)
                safe_api_do_init(api_cls, data_src)
                try:
                    api = api_cls(code=self.code, k_type=self.k_type, begin_date=begin_date, end_date=end_date, autype=autype)
                    replay_klus_master = copy.deepcopy(list(api.get_kl_data()))
                finally:
                    api_cls.do_close()
            except Exception as api_exc:
                raise RuntimeError(f"CChan拉取失败: {format_source_error(chan_exc)}；API直拉失败: {format_source_error(api_exc)}")
        if not replay_klus_master:
            raise ValueError("未获取到任何K线数据")

        stock_name: Optional[str] = None
        try:
            api_cls = get_stock_api_cls(data_src)
            safe_api_do_init(api_cls, data_src)
            api = api_cls(code=self.code, k_type=self.k_type, begin_date=begin_date, end_date=end_date, autype=autype)
            stock_name = getattr(api, "name", None) or None
            api_cls.do_close()
        except Exception:
            stock_name = None

        # 筹码链：A~C（上市首根~会话结束日）；K 线链：kline_all 与会话区间一致
        chip_src = data_src
        chip_begin_date = "1990-01-01"
        chip_end_date: Optional[str] = end_date
        all_begin = chip_begin_date if use_for == "chip" else begin_date
        all_end = chip_end_date if use_for == "chip" else end_date
        try:
            cfg_all = CChanConfig({**chan_cfg_dict, "trigger_step": False})
            chan_all = ReplayDataChan(
                code=self.code,
                begin_time=all_begin,
                end_time=all_end,
                data_src=chip_src,
                lv_list=[self.k_type],
                config=cfg_all,
                autype=autype,
            )
            kline_all = serialize_klu_iter(chan_all[0].klu_iter())
        except Exception:
            # A~C 失败时勿回退会话 master（仅数日），改 API 直拉 1990~C
            try:
                api_cls = get_stock_api_cls(chip_src)
                safe_api_do_init(api_cls, chip_src)
                try:
                    api = api_cls(
                        code=self.code,
                        k_type=self.k_type,
                        begin_date=all_begin,
                        end_date=all_end,
                        autype=autype,
                    )
                    kline_all = serialize_klu_iter(list(api.get_kl_data()))
                finally:
                    api_cls.do_close()
            except Exception:
                kline_all = serialize_klu_iter(replay_klus_master)

        return replay_klus_master, kline_all, stock_name

    def _select_data_source_with_fallback(
        self,
        begin_date: str,
        end_date: Optional[str],
        autype: AUTYPE,
        chan_cfg_dict: dict[str, Any],
        use_for: str = "kline",  # "kline" 或 "chip"
        chain_override: Optional[list[tuple[str, Any]]] = None,
        offline_confirm_suppressed: bool = False,
        cache_context: Optional[dict[str, Any]] = None,
    ) -> DataSourceSelection:
        """按优先级链选择数据源；K 线与筹码共用排序逻辑，链独立故可选用不同实际源。"""
        logs: list[str] = []
        errors: list[str] = []
        _check_init_cancelled()
        if cache_context and kline_session_cache_enabled():
            autype_key = str(cache_context.get("autype_key", "") or getattr(autype, "name", str(autype))).lower()
            k_type_key = str(cache_context.get("k_type_key", "") or k_type_to_api_key(self.k_type))
            cache_key = build_cache_key(
                code=self.code,
                begin_date=begin_date,
                end_date=end_date,
                autype_key=autype_key,
                k_type_key=k_type_key,
                use_for=use_for,
                offline_data_custom=str(cache_context.get("offline_data_custom", "native")),
                priority=list(cache_context.get("priority") or []),
                confirm_offline=bool(cache_context.get("confirm_offline", False)),
            )
            with init_perf_stage(f"disk_cache_{use_for}"):
                disk_hit = try_load_kline_session(cache_key)
            if disk_hit is not None:
                label = disk_hit.data_src_label or "磁盘缓存"
                pair = _DATA_SOURCE_NAME_TO_PAIR.get(label)
                data_src = pair[1] if pair else OFFLINE_INLINE_SRC
                logs.append(f"K线磁盘缓存命中（{use_for}）：{label}")
                print(f"[DataSource] disk cache hit {use_for} {disk_hit.cache_path}")
                return DataSourceSelection(
                    data_src=data_src,
                    label=label,
                    logs=logs,
                    replay_klus_master=disk_hit.replay_klus_master,
                    kline_all=disk_hit.kline_all,
                    stock_name=disk_hit.stock_name,
                )
        data_chain = chain_override or (DATA_SOURCE_CHAIN_KLINE if use_for == "kline" else DATA_SOURCE_CHAIN_CHIP)
        for idx, (label, data_src) in enumerate(data_chain):
            _check_init_cancelled()
            print(f"[DataSource] try {label} for {self.code} {begin_date} -> {end_date or 'latest'}")
            try:
                with init_perf_stage(f"fetch_{use_for}_{label}"):
                    replay_klus_master, kline_all, stock_name = self._fetch_from_single_source(
                        data_src, begin_date, end_date, autype, chan_cfg_dict, use_for=use_for
                    )
                _check_init_cancelled()
                if cache_context and kline_session_cache_enabled():
                    autype_key = str(cache_context.get("autype_key", "") or getattr(autype, "name", str(autype))).lower()
                    k_type_key = str(cache_context.get("k_type_key", "") or k_type_to_api_key(self.k_type))
                    cache_key = build_cache_key(
                        code=self.code,
                        begin_date=begin_date,
                        end_date=end_date,
                        autype_key=autype_key,
                        k_type_key=k_type_key,
                        use_for=use_for,
                        offline_data_custom=str(cache_context.get("offline_data_custom", "native")),
                        priority=list(cache_context.get("priority") or []),
                        confirm_offline=bool(cache_context.get("confirm_offline", False)),
                    )
                    save_kline_session(
                        cache_key,
                        replay_klus_master=replay_klus_master,
                        kline_all=kline_all,
                        stock_name=stock_name,
                        meta_extra={
                            "data_src_label": label,
                            "code": self.code,
                            "use_for": use_for,
                        },
                    )
                if idx == 0:
                    logs.append(f"数据源已连接：{label}")
                else:
                    logs.append(f"数据源切换成功：{label}（前序源不可用，已自动降级）")
                print(f"[DataSource] selected {label}")
                return DataSourceSelection(
                    data_src=data_src,
                    label=label,
                    logs=logs + errors,
                    replay_klus_master=replay_klus_master,
                    kline_all=kline_all,
                    stock_name=stock_name,
                )
            except OfflineDataConfirmRequired:
                raise
            except Exception as exc:
                detail = format_source_error(exc)
                errors.append(f"{label} 失败：{detail}")
                logs.append(f"数据源尝试失败：{label}")
                print(f"[DataSource] failed {label}: {detail}")
                next_is_offline = idx + 1 < len(data_chain) and data_chain[idx + 1][1] == OFFLINE_INLINE_SRC
                if (
                    next_is_offline
                    and not offline_confirm_suppressed
                    and offline_bundle_exists(self.code, begin_date, end_date)
                ):
                    tag = classify_fetch_error_tag(exc)
                    disp = _strip_market_prefix(self.code)
                    raise OfflineDataConfirmRequired(disp, label, tag, detail)
        raise RuntimeError("全部数据源均不可用：" + "；".join(errors))

    def get_structure_bundle(self, *, force: bool = False, chan: Optional[CChan] = None) -> ChanStructureBundle:
        target_chan = chan or self.chan
        if target_chan is None:
            raise ValueError("会话未初始化")
        if chan is None and not force and self.structure_bundle is not None and self._bundle_cache_step_idx == self.step_idx:
            return self.structure_bundle
        bundle = build_structure_bundle(target_chan, self.chan_algo, self.rhythm_calc_mode, self.chart_lazy_layers)
        if chan is None:
            self.structure_bundle = bundle
            self._bundle_cache_step_idx = self.step_idx
            self.trend_lines = list(bundle.trend_lines)
        return bundle

    def init(
        self,
        code: str,
        begin_date: str,
        end_date: Optional[str],
        autype: AUTYPE,
        chan_config: Optional[dict[str, Any]] = None,
        k_type: str = "daily",
        confirm_offline: bool = False,
        data_source_priority: Optional[list[str]] = None,
        data_form_mode: str = "traditional",
        data_form_quantity: Optional[int] = None,
        data_form_quantity_alloc: str = "front",
        data_feed_mode: str = "step",
        offline_data_custom: str = "native",
        chan_record_enabled: bool = False,
        chart_lazy_layers: Optional[dict[str, Any]] = None,
    ) -> None:
        init_t0_ms = int(time.time() * 1000)
        stage_t0_ms = init_t0_ms
        _check_init_cancelled()
        # 解析并设置周期类型
        self.k_type = parse_k_type(k_type)
        # 本地 record 持久化缓存已禁用：每次加载都从 a_Data 重新计算。
        self._chan_record_enabled = False
        feed_mode = normalize_data_feed_mode(data_feed_mode)
        qty_alloc = normalize_data_form_quantity_alloc(data_form_quantity_alloc)
        off_custom = normalize_offline_data_custom(offline_data_custom)
        set_active_offline_data_custom(off_custom)
        self.offline_data_custom = off_custom
        self.chart_lazy_layers = normalize_chart_lazy_layers(chart_lazy_layers)
        self.clear_structure_runtime_cache(clear_bsp_cache=True)
        self._session_begin_date = begin_date
        self._session_end_date = end_date
        
        self.data_src_chip_used = None

        cfg_dict = {
            "chan_algo": CHAN_ALGO_CLASSIC,
            "bi_strict": True,
            "bi_algo": "normal",
            "bi_fx_check": "strict",
            "gap_as_kl": False,
            "bi_end_is_peak": True,
            "bi_allow_sub_peak": True,
            "seg_algo": "chan",
            "left_seg_method": "peak",
            "zs_combine": True,
            "zs_combine_mode": "zs",
            "one_bi_zs": False,
            "zs_algo": "normal",
            # 复盘统一 trigger_step=True，由 ReplayChan.load/step_load 显式喂 K（unified 用 load(step=False)）
            "trigger_step": True,
            "skip_step": 0,
            "kl_data_check": True,
            "print_warning": False,
            "print_err_time": False,
            "rhythm_calc_mode": RHYTHM_CALC_MODE_NORMAL,
            # BSP defaults
            "divergence_rate": float("inf"),
            "min_zs_cnt": 1,
            "bsp1_only_multibi_zs": True,
            "max_bs2_rate": 0.9999,
            "macd_algo": "peak",
            "bs1_peak": True,
            "bs_type": "1,1p,2,2s,3a,3b",
            "bsp2_follow_1": True,
            "bsp3_follow_1": True,
            "bsp3_peak": False,
            "bsp2s_follow_2": False,
            "max_bsp2s_lv": None,
            "strict_bsp3": False,
            "bsp3a_max_zs_cnt": 1,
        }
        if chan_config:
            for k, v in chan_config.items():
                if v is not None and v != "":
                    if k in ["divergence_rate", "max_bs2_rate"]:
                        try:
                            cfg_dict[k] = float(v)
                        except (ValueError, TypeError):
                            if isinstance(v, str) and v.lower() == "inf":
                                cfg_dict[k] = float("inf")
                    elif k in ["min_zs_cnt", "bsp3a_max_zs_cnt", "boll_n", "rsi_cycle", "kdj_cycle", "skip_step"]:
                        try:
                            cfg_dict[k] = int(v)
                        except (ValueError, TypeError):
                            pass
                    elif k in ["max_kl_misalgin_cnt", "max_kl_inconsistent_cnt"]:
                        try:
                            cfg_dict[k] = int(v)
                        except (ValueError, TypeError):
                            pass
                    elif k == "macd" and isinstance(v, dict):
                        macd_dict = cfg_dict.get("macd", {"fast": 12, "slow": 26, "signal": 9}).copy()
                        for mk, mv in v.items():
                            if mv is not None and mv != "":
                                try:
                                    macd_dict[mk] = int(mv)
                                except (ValueError, TypeError):
                                    pass
                        cfg_dict["macd"] = macd_dict
                    elif k == "demark" and isinstance(v, dict):
                        demark_dict = cfg_dict.get(
                            "demark",
                            {
                                "demark_len": 9,
                                "setup_bias": 4,
                                "countdown_bias": 2,
                                "max_countdown": 13,
                                "tiaokong_st": True,
                                "setup_cmp2close": True,
                                "countdown_cmp2close": True,
                            },
                        ).copy()
                        for dk, dv in v.items():
                            if dv is None or dv == "":
                                continue
                            if dk in {"tiaokong_st", "setup_cmp2close", "countdown_cmp2close"}:
                                demark_dict[dk] = bool(dv)
                            else:
                                try:
                                    demark_dict[dk] = int(dv)
                                except (ValueError, TypeError):
                                    pass
                        cfg_dict["demark"] = demark_dict
                    elif k in (
                        "data_src_kline",
                        "data_src_chip",
                        "data_source_priority",
                        "confirm_offline",
                        "chart_mode",
                        "k_type",
                        "k_type_2",
                        "k_types_multi",
                        "active_chart_id",
                        "initial_cash",
                        "data_form_mode",
                        "data_form_quantity",
                    ):
                        # 训练器/会话字段，勿写入 CChan 配置
                        pass
                    else:
                        cfg_dict[k] = v

        self.chan_algo = normalize_chan_algo(cfg_dict.get("chan_algo"))
        cfg_dict["chan_algo"] = self.chan_algo
        self.rhythm_calc_mode = normalize_rhythm_calc_mode(cfg_dict.get("rhythm_calc_mode"))
        cfg_dict["rhythm_calc_mode"] = self.rhythm_calc_mode
        self.effective_cfg_dict = cfg_dict.copy()
        chan_cfg_dict = self._cfg_without_chan_algo(cfg_dict)
        cfg = CChanConfig(chan_cfg_dict)
        self.code = normalize_code(code)
        self.stock_name = None
        # 全量禁用历史缓存后，加载会话固定从 a_Data 离线分笔取数。
        chain_override: Optional[list[tuple[str, Any]]] = [("离线数据", OFFLINE_INLINE_SRC)]
        confirm_offline = True
        prio_fp = (("离线数据",), True)
        session_key = (self.code, begin_date, end_date, autype, self.k_type, prio_fp, off_custom)
        cache_hit = session_key == self._data_session_key and self._replay_klus_master is not None
        autype_key = getattr(autype, "name", str(autype)).lower()
        k_type_key = k_type_to_api_key(self.k_type)
        cache_context = {
            "autype_key": autype_key,
            "k_type_key": k_type_key,
            "offline_data_custom": off_custom,
            "priority": list(data_source_priority or []),
            "confirm_offline": bool(confirm_offline),
        }

        if not cache_hit:
            with init_perf_stage("data_kline"):
                k_sel = self._select_data_source_with_fallback(
                    begin_date,
                    end_date,
                    autype,
                    chan_cfg_dict,
                    use_for="kline",
                    chain_override=chain_override,
                    offline_confirm_suppressed=confirm_offline,
                    cache_context=cache_context,
                )
            _check_init_cancelled()
            try:
                with init_perf_stage("data_chip"):
                    chip_sel = self._select_data_source_with_fallback(
                        begin_date,
                        end_date,
                        autype,
                        chan_cfg_dict,
                        use_for="chip",
                        chain_override=chain_override,
                        offline_confirm_suppressed=confirm_offline,
                        cache_context=cache_context,
                    )
                _check_init_cancelled()
            except OfflineDataConfirmRequired:
                raise
            except RuntimeError as exc:
                self._replay_klus_master_raw = copy.deepcopy(k_sel.replay_klus_master)
                self._replay_klus_master = self._replay_klus_master_raw
                self.kline_all = k_sel.kline_all
                self.data_src_used = k_sel.data_src
                self.data_src_chip_used = k_sel.data_src
                self.data_src_logs = list(k_sel.logs) + [f"筹码全历史与K线同源（筹码链不可用：{format_source_error(exc)}）"]
            else:
                self._replay_klus_master_raw = copy.deepcopy(k_sel.replay_klus_master)
                self._replay_klus_master = self._replay_klus_master_raw
                # 离线 K 线仅会话区间；init 不同步直拉全历史筹码，避免加载会话被大分笔拖慢。
                if k_sel.data_src == OFFLINE_INLINE_SRC:
                    chip_cached = list(chip_sel.kline_all or [])
                    self.kline_all = _pick_wider_kline_all_for_chip(
                        [
                            chip_cached,
                            list(k_sel.kline_all or []),
                        ]
                    )
                    self.data_src_chip_used = chip_sel.data_src
                    if chip_sel.data_src == OFFLINE_INLINE_SRC:
                        chip_logs_extra = [f"筹码底座：{chip_sel.label}（全历史按需懒加载）"] + list(chip_sel.logs)
                    else:
                        chip_logs_extra = [
                            f"筹码底座：{chip_sel.label}（离线K线会话区间 + 筹码链按需补全）"
                        ] + list(chip_sel.logs)
                else:
                    self.kline_all = chip_sel.kline_all
                    self.data_src_chip_used = chip_sel.data_src
                    chip_logs_extra = [f"筹码全历史：{chip_sel.label}"] + list(chip_sel.logs)
                self.data_src_used = k_sel.data_src
                self.data_src_logs = list(k_sel.logs) + chip_logs_extra
            self._data_session_key = session_key
            # #region agent log
            _agent_debug_log_backend(
                "P3",
                "a_replay_trainer.py:init:dataSourceSelect",
                "数据源选择与基础K线构建耗时",
                {
                    "cacheHit": bool(cache_hit),
                    "dataSrc": str(self.data_src_used),
                    "chipSrc": str(self.data_src_chip_used),
                    "costMs": int(time.time() * 1000) - stage_t0_ms,
                },
                run_id="perf-check",
            )
            # #endregion
            stage_t0_ms = int(time.time() * 1000)
            if k_sel.stock_name:
                self.stock_name = k_sel.stock_name
            self._chip_bins_enriched = False
            # #region agent log
            _agent_debug_log_backend(
                "P4",
                "a_replay_trainer.py:init:chipEnrich",
                "离线筹码分笔补全耗时",
                {
                    "enabled": bool(
                        self.data_src_used == OFFLINE_INLINE_SRC
                        and self.kline_all
                        and self.k_type in _offline_chip_supported_ktypes()
                        and offline_tick_files_exist_for_range(self.code, "1990-01-01", None)
                    ),
                    "klineAllCount": len(self.kline_all or []),
                    "costMs": int(time.time() * 1000) - stage_t0_ms,
                },
                run_id="perf-check",
            )
            # #endregion
            stage_t0_ms = int(time.time() * 1000)
        else:
            if self.data_src_logs:
                self.data_src_logs = [
                    "沿用已缓存：K线 "
                    + data_source_label(self.data_src_used)
                    + "，筹码 "
                    + data_source_label(self.data_src_chip_used or self.data_src_used)
                ]
            # 沿用内存 K 线缓存：仅当底座不像全历史时才重拉筹码
            if not _kline_all_likely_full_history(self):
                with init_perf_stage("chip_refresh"):
                    _refresh_stepper_chip_kline_all_base(self, autype)
            self._chip_bins_enriched = False
            # #region agent log
            _agent_debug_log_backend(
                "P3",
                "a_replay_trainer.py:init:dataSourceSelect",
                "沿用缓存路径耗时",
                {
                    "cacheHit": bool(cache_hit),
                    "dataSrc": str(self.data_src_used),
                    "chipSrc": str(self.data_src_chip_used),
                    "costMs": int(time.time() * 1000) - stage_t0_ms,
                },
                run_id="perf-check",
            )
            # #endregion
            stage_t0_ms = int(time.time() * 1000)

        raw_master = self._replay_klus_master_raw or self._replay_klus_master or []
        self.data_form_mode = normalize_data_form_mode(data_form_mode)
        self.data_feed_mode = feed_mode
        self.data_form_quantity_alloc = qty_alloc
        self.raw_kline_count = len(raw_master)
        self.data_form_quantity = normalize_data_form_quantity(
            data_form_quantity if data_form_quantity is not None else self.raw_kline_count,
            self.raw_kline_count if self.raw_kline_count > 0 else 1,
        )
        if is_data_form_tick_synth_mode(self.data_form_mode):
            push_record_trace("分笔价格合成：读取离线分笔并聚合K线…")
            chip_base_before_synth = copy.deepcopy(self.kline_all) if self.kline_all else []
            synth_master, synth_kline_all, tick_raw_count, tick_raw_master = build_tick_synth_session_data(
                self.code,
                self.k_type,
                begin_date,
                end_date,
                self.data_form_mode,
                self.data_form_quantity,
                self.data_form_quantity_alloc,
                self.offline_data_custom,
            )
            # tick_quantity：raw 保存聚合前 master，与 quantity 模式一致
            self._replay_klus_master_raw = copy.deepcopy(tick_raw_master)
            self._replay_klus_master = copy.deepcopy(synth_master)
            # 分笔合成仅覆盖会话区间，筹码底座保留更宽全历史
            self.kline_all = _pick_wider_kline_all_for_chip(
                [chip_base_before_synth, list(synth_kline_all or [])]
            )
            self.raw_kline_count = int(tick_raw_count)
            self.data_form_quantity = normalize_data_form_quantity(
                self.data_form_quantity,
                self.raw_kline_count if self.raw_kline_count > 0 else 1,
            )
        elif is_data_form_quantity_mode(self.data_form_mode) and self.raw_kline_count > 0:
            self._replay_klus_master = aggregate_klu_by_quantity(
                raw_master, self.data_form_quantity, self.data_form_quantity_alloc
            )
        else:
            self._replay_klus_master = copy.deepcopy(raw_master)

        autype_key = getattr(autype, "name", str(autype)).lower()
        k_type_key = k_type_to_api_key(self.k_type)
        self._chan_record_fingerprint = build_chan_config_fingerprint(
            code=self.code,
            k_type_key=k_type_key,
            autype_key=autype_key,
            chan_cfg_dict=chan_cfg_dict,
            data_form_mode=self.data_form_mode,
            data_form_quantity=self.data_form_quantity,
            data_form_quantity_alloc=self.data_form_quantity_alloc,
            offline_data_custom=self.offline_data_custom,
            data_feed_mode=self.data_feed_mode,
            data_source_priority=data_source_priority,
            confirm_offline=bool(confirm_offline),
        )
        # record 快照里的 kline_all 可能是旧会话区间；保留 init 拉到的更宽底座
        init_kline_all_for_chip = list(self.kline_all) if self.kline_all else []
        with init_perf_stage("chan_record"):
            _check_init_cancelled()
            self._chan_record_apply = try_apply_chan_record(
                self,
                enabled=self._chan_record_enabled,
                fingerprint=self._chan_record_fingerprint,
                code=self.code,
                k_type_key=k_type_key,
                autype_key=autype_key,
                begin_date=begin_date,
                end_date=end_date,
                new_master=self._replay_klus_master or [],
                create_replay_chan_fn=ReplayChan,
                cfg=cfg,
                autype=autype,
                k_type=self.k_type,
                data_src=self.data_src_used or DATA_SRC.AKSHARE,
                allow_end_snapshot_restore=False,
            )
        _check_init_cancelled()
        self.perf_session_id = None
        self.perf_engine_mode = "python-legacy" if str(APP_PERF_ENGINE.requested_mode) == "python_legacy" else "rust"
        with init_perf_stage("perf_engine_load"):
            perf_bars = serialize_klu_iter(self._replay_klus_master or [])
            perf_chip_bars = _chip_bars_for_perf_session(
                self.kline_all,
                perf_bars,
                end_date,
            )
            perf_session = APP_PERF_ENGINE.load_session(
                code=self.code,
                k_type=k_type_to_api_key(self.k_type),
                begin_date=begin_date,
                end_date=end_date,
                bars=perf_bars,
                chip_bars=perf_chip_bars or perf_bars,
            )
            self.perf_session_id = perf_session.session_id
            self.perf_engine_mode = perf_session.engine_mode
            for line in rust_perf_engine_loaded_lines(
                engine_mode=str(perf_session.engine_mode),
                bar_count=int(perf_session.bar_count),
                chip_bar_count=int(perf_session.chip_bar_count),
            ):
                push_record_trace(line)
        if self._chan_record_apply.applied and init_kline_all_for_chip:
            wider = _pick_wider_kline_all_for_chip(
                [init_kline_all_for_chip, list(self.kline_all or [])]
            )
            if wider:
                self.kline_all = wider
                self._chip_bins_enriched = False
        if self.kline_all:
            push_record_trace(
                f"筹码kline_all：{len(self.kline_all)} 根（{self.kline_all[0].get('t', '-')} ~ {self.kline_all[-1].get('t', '-')}）"
            )
            push_record_trace(
                _chip_range_text(
                    list(self.kline_all or []),
                    getattr(self, "_session_begin_date", None),
                    getattr(self, "_session_end_date", None),
                )
            )
            _agent_debug_log_backend(
                "H4",
                "a_replay_trainer.py:init:chipKlineAll",
                "init 后 stepper.kline_all 宽度",
                {
                    "count": len(self.kline_all),
                    "firstT": str(self.kline_all[0].get("t", "")),
                    "lastT": str(self.kline_all[-1].get("t", "")),
                    "dataSrc": str(getattr(self, "data_src_used", "")),
                    "cacheHit": bool(cache_hit),
                },
            )
        # #region agent log
        _agent_debug_log_backend(
            "P0",
            "a_replay_trainer.py:init",
            "会话初始化耗时总览",
            {
                "cacheHit": bool(cache_hit),
                "recordEnabled": bool(self._chan_record_enabled),
                "dataFeedMode": str(self.data_feed_mode),
                "masterCount": len(self._replay_klus_master or []),
                "klineAllCount": len(self.kline_all or []),
                "costMs": int(time.time() * 1000) - init_t0_ms,
            },
            run_id="perf-check",
        )
        # #endregion
        chan_bootstrapped = bool(self._chan_record_apply.applied)

        if not chan_bootstrapped:
            with init_perf_stage("chan_bootstrap"):
                self.chan = ReplayChan(
                    code=self.code,
                    begin_time=begin_date,
                    end_time=end_date,
                    data_src=self.data_src_used or DATA_SRC.AKSHARE,
                    lv_list=[self.k_type],
                    config=cfg,
                    autype=autype,
                    replay_klus_master=self._replay_klus_master,
                )
            self.indicators = {
                "macd": CMACD(),
                "kdj": KDJ(),
                "rsi": RSI(),
                "boll": BollModel(),
                "demark": CDemarkEngine(),
            }
            self.indicator_history = []
            self.trend_lines = []
            self._serialized_klu_cache = []
            self.clear_structure_runtime_cache(clear_bsp_cache=True)
            self._unified_full_payload = None
            if self.data_feed_mode == "unified":
                unified_t0_ms = int(time.time() * 1000)
                for _ in self.chan.load(step=False):
                    pass
                load_cost_ms = int(time.time() * 1000) - unified_t0_ms
                self.step_idx = -1
                self._iter = None
                self._rebuild_indicator_history_from_chan()
                bundle = self.get_structure_bundle(force=True)
                klu_chart = (
                    serialize_replay_master_klines(self._replay_klus_master)
                    if use_master_kline_for_chart(self.data_form_mode)
                    else None
                )
                self._unified_full_payload = serialize_chan(
                    self.chan,
                    self.indicator_history,
                    self.trend_lines,
                    chan_algo=self.chan_algo,
                    bundle=bundle,
                    kline_all=self.kline_all,
                    klu_arr_cache=klu_chart,
                )
                # #region agent log
                _agent_debug_log_backend(
                    "P5",
                    "a_replay_trainer.py:init:unifiedBuild",
                    "unified 全量load+序列化耗时",
                    {
                        "loadCostMs": load_cost_ms,
                        "totalCostMs": int(time.time() * 1000) - unified_t0_ms,
                        "indicatorCount": len(self.indicator_history or []),
                        "chartBars": len((self._unified_full_payload or {}).get("kline", []) or []),
                    },
                    run_id="perf-check",
                )
                # #endregion
            else:
                self._iter = self.chan.step_load()
                self.step_idx = -1
                destroy_rust_chan_state(self)
                # 仅 shadow/primary 开启时才创建 Rust Chan 状态机，避免关 shadow 仍逐根 feed_bar
                if rust_chan_shadow_enabled() or rust_chan_primary_enabled():
                    ensure_rust_chan_state(self)
                    for line in rust_chan_state_created_lines(self):
                        push_record_trace(line)

        if self._chan_record_enabled and not self._chan_record_apply.applied:
            push_record_trace("缠论record：未命中，将后台异步保存本次全量计算")
            schedule_chan_record_save(
                self,
                enabled=True,
                fingerprint=self._chan_record_fingerprint,
                code=self.code,
                k_type_key=k_type_key,
                autype_key=autype_key,
                begin_date=begin_date,
                end_date=end_date,
                warmup=True,
            )
        elif self._chan_record_enabled and self._chan_record_apply.mode in ("extend", "overlap_replay"):
            schedule_chan_record_save(
                self,
                enabled=True,
                fingerprint=self._chan_record_fingerprint,
                code=self.code,
                k_type_key=k_type_key,
                autype_key=autype_key,
                begin_date=begin_date,
                end_date=end_date,
                warmup=False,
            )

        if self.data_feed_mode == "unified" and chan_bootstrapped:
            self.ensure_unified_full_payload()

    def ensure_unified_full_payload(self) -> bool:
        """统一喂数据：record 复用或 overlap 重算后补齐序列化图表包。"""
        if str(self.data_feed_mode) != "unified":
            return False
        if self._unified_full_payload is not None:
            return True
        if self.chan is None:
            return False
        bundle = self.get_structure_bundle(force=True)
        klu_chart = (
            serialize_replay_master_klines(self._replay_klus_master)
            if use_master_kline_for_chart(self.data_form_mode)
            else None
        )
        self._unified_full_payload = serialize_chan(
            self.chan,
            self.indicator_history,
            self.trend_lines,
            chan_algo=self.chan_algo,
            bundle=bundle,
            kline_all=self.kline_all,
            klu_arr_cache=klu_chart,
        )
        return self._unified_full_payload is not None

    def _rebuild_indicator_history_from_chan(self) -> None:
        """基于当前 chan 全量重建指标序列（统一喂数据模式使用）。"""
        self.indicators = {
            "macd": CMACD(),
            "kdj": KDJ(),
            "rsi": RSI(),
            "boll": BollModel(),
            "demark": CDemarkEngine(),
        }
        self.indicator_history = []
        if self.chan is None or len(self.chan[0].lst) == 0:
            return
        for latest_klu in self.chan[0].klu_iter():
            h, l, c = float(latest_klu.high), float(latest_klu.low), float(latest_klu.close)
            vol = _klu_float_trade_metric(latest_klu, DATA_FIELD.FIELD_VOLUME)
            macd_item = self.indicators["macd"].add(c)
            kdj_item = self.indicators["kdj"].add(h, l, c)
            rsi_val = self.indicators["rsi"].add(c)
            boll_item = self.indicators["boll"].add(c)
            demark_idx = self.indicators["demark"].update(latest_klu.idx, c, h, l)
            demark_pts = []
            for item in demark_idx.data:
                demark_pts.append(
                    {
                        "type": item["type"],
                        "dir": "UP" if item["dir"].name == "UP" else "DOWN",
                        "val": item["idx"],
                        "x": item["idx_in_kl"] if "idx_in_kl" in item else latest_klu.idx,
                    }
                )
            self.indicator_history.append(
                {
                    "x": latest_klu.idx,
                    "macd": {"dif": macd_item.DIF, "dea": macd_item.DEA, "macd": macd_item.macd},
                    "kdj": {"k": kdj_item.k, "d": kdj_item.d, "j": kdj_item.j},
                    "rsi": rsi_val,
                    "boll": {"mid": boll_item.MID, "up": boll_item.UP, "down": boll_item.DOWN},
                    "vol": vol,
                    "demark": demark_pts,
                }
            )

    @staticmethod
    def _slice_chart_payload_to_x(payload: dict[str, Any], x_max: int) -> dict[str, Any]:
        """按 x 上限裁剪图表数据，保证 unified 模式仅展示当前步可见范围。"""
        out = dict(payload)
        out["kline"] = [it for it in payload.get("kline", []) if int(it.get("x", -1)) <= x_max]
        out["fract"] = [it for it in payload.get("fract", []) if int(it.get("x2", -1)) <= x_max]
        out["bi"] = [it for it in payload.get("bi", []) if int(it.get("x2", -1)) <= x_max]
        out["seg"] = [it for it in payload.get("seg", []) if int(it.get("x2", -1)) <= x_max]
        out["segseg"] = [it for it in payload.get("segseg", []) if int(it.get("x2", -1)) <= x_max]
        if isinstance(payload.get("extra_levels"), dict):
            out["extra_levels"] = {
                str(level): [it for it in items if int(it.get("x2", -1)) <= x_max]
                for level, items in payload.get("extra_levels", {}).items()
                if isinstance(items, list)
            }
        out["fract_zs"] = [it for it in payload.get("fract_zs", []) if int(it.get("x2", -1)) <= x_max]
        out["bi_zs"] = [it for it in payload.get("bi_zs", []) if int(it.get("x2", -1)) <= x_max]
        out["seg_zs"] = [it for it in payload.get("seg_zs", []) if int(it.get("x2", -1)) <= x_max]
        out["segseg_zs"] = [it for it in payload.get("segseg_zs", []) if int(it.get("x2", -1)) <= x_max]
        if isinstance(payload.get("extra_zs"), dict):
            out["extra_zs"] = {
                str(level): [it for it in items if int(it.get("x2", -1)) <= x_max]
                for level, items in payload.get("extra_zs", {}).items()
                if isinstance(items, list)
            }
        out["bsp_bi"] = [it for it in payload.get("bsp_bi", []) if int(it.get("x", -1)) <= x_max]
        out["bsp_seg"] = [it for it in payload.get("bsp_seg", []) if int(it.get("x", -1)) <= x_max]
        out["bsp_segseg"] = [it for it in payload.get("bsp_segseg", []) if int(it.get("x", -1)) <= x_max]
        if isinstance(payload.get("extra_bsp"), dict):
            out["extra_bsp"] = {
                str(level): [it for it in items if int(it.get("x", -1)) <= x_max]
                for level, items in payload.get("extra_bsp", {}).items()
                if isinstance(items, list)
            }
        out["bsp"] = [it for it in payload.get("bsp", []) if int(it.get("x", -1)) <= x_max]
        out["rhythm_hits"] = [it for it in payload.get("rhythm_hits", []) if int(it.get("x", -1)) <= x_max]
        out["indicators"] = [it for it in payload.get("indicators", []) if int(it.get("x", -1)) <= x_max]
        out["trend_lines"] = [it for it in payload.get("trend_lines", []) if int(it.get("x2", -1)) <= x_max]
        out["kline_combine"] = [it for it in payload.get("kline_combine", []) if int(it.get("x2", -1)) <= x_max]
        out["fx_lines"] = [it for it in payload.get("fx_lines", []) if int(it.get("x2", -1)) <= x_max]
        out["rhythm_lines"] = [it for it in payload.get("rhythm_lines", []) if int(it.get("x2", -1)) <= x_max]
        return out

    def bulk_present_to_step(self, target_step: int) -> None:
        """一次性呈现快路径：全量灌入 chan 并定位到 target_step。"""
        if self.chan is None:
            return
        master = self._replay_klus_master or []
        total = len(master)
        if total <= 0:
            return
        target_step = max(0, min(int(target_step), total - 1))
        _check_init_cancelled()
        for _ in self.chan.load(step=False):
            _check_init_cancelled()
        self._rebuild_indicator_history_from_chan()
        self.step_idx = target_step
        self.clear_structure_runtime_cache(clear_bsp_cache=True)
        if use_master_kline_for_chart(self.data_form_mode):
            self._serialized_klu_cache = serialize_replay_master_klines(master[: target_step + 1])
        else:
            self._serialized_klu_cache = []
            for latest_klu in self.chan[0].klu_iter():
                if latest_klu.idx > target_step:
                    break
                self._serialized_klu_cache.append(
                    serialize_klu_unit_fast(
                        latest_klu,
                        lambda x: _klu_float_trade_metric(x, DATA_FIELD.FIELD_VOLUME),
                    )
                )
        self.get_structure_bundle(force=True)
        self._iter = None

    def step(self) -> bool:
        if self.data_feed_mode == "unified":
            if self._unified_full_payload is None:
                raise ValueError("统一喂数据模式未完成初始化。")
            total = len(self._unified_full_payload.get("kline", []))
            if self.step_idx + 1 >= total:
                return False
            self.step_idx += 1
            self.clear_structure_runtime_cache()
            return True
        if self._iter is None:
            master = self._replay_klus_master or []
            if self.step_idx + 1 >= len(master):
                return False
            raise ValueError("全量呈现后会话已在末根，请回退后再步进")
        try:
            self._step_perf_inc("calls")
            primary = rust_chan_primary_enabled() and bool(self._suppress_step_bundle_refresh)
            master = self._replay_klus_master or []
            if primary:
                next_idx = self.step_idx + 1
                if next_idx >= len(master):
                    return False
                klu = master[next_idx]
                t0 = time.perf_counter()
                feed_rust_chan_bar(
                    self,
                    idx=int(getattr(klu, "idx", next_idx)),
                    high=float(klu.high),
                    low=float(klu.low),
                    close=float(klu.close),
                )
                self._step_perf_add("iter_ms", (time.perf_counter() - t0) * 1000.0)
                self._rust_chan_primary_used = True
                self.step_idx += 1
                latest_klu = klu
            else:
                t0 = time.perf_counter()
                next(self._iter)
                self._step_perf_add("iter_ms", (time.perf_counter() - t0) * 1000.0)
                self.step_idx += 1
                kl_list = self.chan[0]
                latest_klu = kl_list.lst[-1].lst[-1]
                # shadow 关：不 feed_bar、不比对，避免误记为「shadow 双跑」
                if rust_chan_shadow_enabled():
                    shadow_t0 = time.perf_counter()
                    feed_rust_chan_bar(
                        self,
                        idx=int(latest_klu.idx),
                        high=float(latest_klu.high),
                        low=float(latest_klu.low),
                        close=float(latest_klu.close),
                    )
                    mismatch = run_rust_chan_shadow(self, step_idx=int(self.step_idx))
                    shadow_ms = (time.perf_counter() - shadow_t0) * 1000.0
                    self._step_perf_add("rust_shadow_ms", shadow_ms)
                    self._maybe_presentation_rust_shadow(shadow_ms, mismatch)
            t0 = time.perf_counter()
            self.clear_structure_runtime_cache()
            self._step_perf_add("clear_cache_ms", (time.perf_counter() - t0) * 1000.0)
            # Update indicators
            t0 = time.perf_counter()
            if not primary:
                kl_list = self.chan[0]
            h, l, c = float(latest_klu.high), float(latest_klu.low), float(latest_klu.close)
            vol = _klu_float_trade_metric(latest_klu, DATA_FIELD.FIELD_VOLUME)
            self._step_perf_add("extract_klu_ms", (time.perf_counter() - t0) * 1000.0)
            t0 = time.perf_counter()
            if use_master_kline_for_chart(self.data_form_mode):
                master = self._replay_klus_master or []
                self._serialized_klu_cache = serialize_replay_master_klines(
                    master[: max(0, self.step_idx + 1)]
                )
            else:
                self._serialized_klu_cache.append(
                    serialize_klu_unit_fast(
                        latest_klu,
                        lambda x: _klu_float_trade_metric(x, DATA_FIELD.FIELD_VOLUME),
                    )
                )
            self._step_perf_add("kline_cache_ms", (time.perf_counter() - t0) * 1000.0)

            t0 = time.perf_counter()
            macd_item = self.indicators["macd"].add(c)
            kdj_item = self.indicators["kdj"].add(h, l, c)
            rsi_val = self.indicators["rsi"].add(c)
            boll_item = self.indicators["boll"].add(c)
            demark_idx = self.indicators["demark"].update(latest_klu.idx, c, h, l)
            self._step_perf_add("indicator_ms", (time.perf_counter() - t0) * 1000.0)

            # Extract current demark points
            t0 = time.perf_counter()
            demark_pts = []
            for item in demark_idx.data:
                demark_pts.append({
                    "type": item["type"],
                    "dir": "UP" if item["dir"].name == "UP" else "DOWN",
                    "val": item["idx"],
                    "x": item["idx_in_kl"] if "idx_in_kl" in item else latest_klu.idx # Fallback to current
                })
            self._step_perf_add("demark_extract_ms", (time.perf_counter() - t0) * 1000.0)

            t0 = time.perf_counter()
            self.indicator_history.append({
                "x": latest_klu.idx,
                "macd": {"dif": macd_item.DIF, "dea": macd_item.DEA, "macd": macd_item.macd},
                "kdj": {"k": kdj_item.k, "d": kdj_item.d, "j": kdj_item.j},
                "rsi": rsi_val,
                "boll": {"mid": boll_item.MID, "up": boll_item.UP, "down": boll_item.DOWN},
                "vol": vol,
                "demark": demark_pts
            })
            self._step_perf_add("history_append_ms", (time.perf_counter() - t0) * 1000.0)

            # 自动一次性呈现只收集 BSP，完整图表包留到末尾统一构建。
            if not self._suppress_step_bundle_refresh:
                t0 = time.perf_counter()
                self.get_structure_bundle(force=True)
                self._step_perf_add("bundle_ms", (time.perf_counter() - t0) * 1000.0)
            return True
        except StopIteration:
            return False

    def unified_set_step_idx(self, target_idx: int) -> int:
        """统一喂数据：直接设置切片游标（0=第一根），不重算缠论。"""
        if self.data_feed_mode != "unified":
            raise ValueError("仅统一喂数据模式支持 step 跳转切片")
        if self._unified_full_payload is None:
            raise ValueError("统一模式未完成初始化")
        bars = self._unified_full_payload.get("kline", [])
        total = len(bars)
        if total <= 0:
            self.step_idx = -1
            self.clear_structure_runtime_cache()
            return -1
        t = max(0, min(int(target_idx), total - 1))
        self.step_idx = t
        self.clear_structure_runtime_cache()
        return t

    def unified_sync_to_anchor_time(self, anchor_time: str) -> None:
        """统一喂数据：被动周期按锚点时间对齐 step_idx（可前进也可后退）。"""
        if self.data_feed_mode != "unified" or self._unified_full_payload is None:
            bt_sync_stepper_to_anchor(self, anchor_time)
            return
        t_anchor = bt_parse_time_safe(anchor_time)
        if t_anchor is None:
            return
        bars = self._unified_full_payload.get("kline", [])
        if not bars:
            self.step_idx = -1
            self.clear_structure_runtime_cache()
            return
        best = -1
        for i, bar in enumerate(bars):
            t_str = str(bar.get("t", "-"))
            cur_eff = bt_anchor_compare_effective_dt(self, t_str)
            if cur_eff is None:
                continue
            if cur_eff <= t_anchor:
                best = i
            else:
                break
        self.step_idx = max(0, best)
        self.clear_structure_runtime_cache()

    def current_price(self) -> float:
        if self.data_feed_mode == "unified":
            if self._unified_full_payload is None:
                raise ValueError("会话未初始化")
            bars = self._unified_full_payload.get("kline", [])
            if self.step_idx < 0 or self.step_idx >= len(bars):
                raise ValueError("当前无K线数据")
            return float(bars[self.step_idx].get("c", 0.0))
        if self.chan is None:
            raise ValueError("会话未初始化")
        kl_list = self.chan[0]
        if len(kl_list.lst) == 0:
            raise ValueError("当前无K线数据")
        return kl_list.lst[-1].lst[-1].close

    def current_time(self) -> str:
        if self.data_feed_mode == "unified":
            if self._unified_full_payload is None:
                return "-"
            bars = self._unified_full_payload.get("kline", [])
            if self.step_idx < 0 or self.step_idx >= len(bars):
                return "-"
            return str(bars[self.step_idx].get("t", "-"))
        if self.chan is None:
            return "-"
        kl_list = self.chan[0]
        if len(kl_list.lst) == 0:
            return "-"
        return kl_list.lst[-1].lst[-1].time.to_str()

    def build_chart_payload_cached(self, *, include_kline_all: bool) -> dict[str, Any]:
        """按 step 索引缓存图表序列化结果，减少同一步重复重算。"""
        if self.data_feed_mode == "unified":
            if self._unified_full_payload is None:
                raise ValueError("会话未初始化")
            cache = self._chart_payload_cache.get(include_kline_all)
            if cache is not None and cache[0] == self.step_idx:
                return cache[1]
            if self.step_idx < 0:
                payload = self._slice_chart_payload_to_x(self._unified_full_payload, -1)
            else:
                bars = self._unified_full_payload.get("kline", [])
                if self.step_idx >= len(bars):
                    raise ValueError("步进索引越界")
                x_max = int(bars[self.step_idx].get("x", -1))
                payload = self._slice_chart_payload_to_x(self._unified_full_payload, x_max)
            if not include_kline_all:
                payload.pop("kline_all", None)
            elif self.kline_all:
                payload["kline_all"] = _kline_all_for_chip_payload(
                    self.kline_all, getattr(self, "_session_end_date", None)
                )
            self._chart_payload_cache[include_kline_all] = (self.step_idx, payload)
            return payload
        if self.chan is None:
            raise ValueError("会话未初始化")
        cache = self._chart_payload_cache.get(include_kline_all)
        if cache is not None and cache[0] == self.step_idx:
            return cache[1]
        bundle = self.get_structure_bundle()
        klu_arr_cache = self._serialized_klu_cache
        if use_master_kline_for_chart(self.data_form_mode):
            master = self._replay_klus_master or []
            want = max(0, self.step_idx + 1)
            if want <= len(master):
                klu_arr_cache = serialize_replay_master_klines(master[:want])
        elif len(klu_arr_cache) != max(0, self.step_idx + 1):
            # 兜底：缓存与步进长度不一致时回退全量序列化。
            klu_arr_cache = None
        payload = serialize_chan(
            self.chan,
            self.indicator_history,
            self.trend_lines,
            chan_algo=self.chan_algo,
            bundle=bundle,
            kline_all=(self.kline_all if include_kline_all else None),
            klu_arr_cache=klu_arr_cache,
        )
        if include_kline_all and self.kline_all:
            _ensure_offline_chip_bins_enriched(self)
            chip_out = _kline_all_for_chip_payload(
                self.kline_all, getattr(self, "_session_end_date", None)
            )
            payload["kline_all"] = chip_out
            if not getattr(self, "_chip_payload_h4_logged", False):
                self._chip_payload_h4_logged = True
                _agent_debug_log_backend(
                    "H4",
                    "a_replay_trainer.py:build_chart_payload_cached",
                    "下发 payload kline_all",
                    {
                        "stepIdx": int(self.step_idx),
                        "rawCount": len(self.kline_all),
                        "outCount": len(chip_out),
                        "outFirstT": str(chip_out[0].get("t", "")) if chip_out else "",
                        "outLastT": str(chip_out[-1].get("t", "")) if chip_out else "",
                    },
                )
        self._chart_payload_cache[include_kline_all] = (self.step_idx, payload)
        return payload

    def rebuild_unified_full_payload_for_layers(self) -> None:
        """统一喂数据的懒加载：全量 payload 已缓存，图层变化后必须重建一次。"""
        if self.data_feed_mode != "unified" or self.chan is None:
            return
        bundle = self.get_structure_bundle(force=True)
        klu_chart = (
            serialize_replay_master_klines(self._replay_klus_master or [])
            if use_master_kline_for_chart(self.data_form_mode)
            else None
        )
        self._unified_full_payload = serialize_chan(
            self.chan,
            self.indicator_history,
            self.trend_lines,
            chan_algo=self.chan_algo,
            bundle=bundle,
            kline_all=self.kline_all,
            klu_arr_cache=klu_chart,
        )
        self._chart_payload_cache = {}


def _stepper_for_session_kline_view(chart_id: str, layer_k_type: Optional[str] = None) -> ChanStepper:
    """查看数据：双图按 chart_id；多周期单图可按 layer_k_type 选各周期步进器。"""
    lk = str(layer_k_type or "").strip().lower()
    cm = normalize_replay_chart_mode(getattr(APP_STATE, "chart_mode", "single"))
    if cm == "multi" and lk:
        want = parse_k_type(lk)
        for st in [APP_STATE.stepper, *(getattr(APP_STATE, "multi_steppers", None) or [])]:
            if st is not None and getattr(st, "k_type", None) == want:
                return st
        raise ValueError(f"当前会话未包含周期「{lk}」的 K 线缓存")
    cid = str(chart_id or "active").strip().lower()
    if cid == "chart2":
        if APP_STATE.chart_mode == "dual" and APP_STATE.stepper2 is not None:
            return APP_STATE.stepper2
        raise ValueError("当前为单图模式，无周期 2")
    if cid == "chart1":
        return APP_STATE.stepper
    if cid in ("active", "", "current"):
        return APP_STATE.get_active_stepper()
    raise ValueError("chart_id 须为 chart1、chart2 或 active")


def _kline_view_rows_filtered(bars: list[dict[str, Any]], view: str) -> list[dict[str, Any]]:
    return kline_view_rows_filtered(bars, view)


def _capture_bsp_history_with_status(bsp_history: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """为 bsp_history 抓取冻结快照（每个 item 都浅复制为新 dict）。

    bsp_history 每个 item 的 status 字段会被 _judge_bsp_against_all 原地改写，
    若直接 list(...) 浅拷贝会与实时态共享同一个 dict 引用，后续 status 改写"穿透"到快照。
    每个 item 的字段均为不可变类型（int/float/str/bool），用 `dict(it)` 浅拷贝即可隔离，
    且开销远低于 `copy.deepcopy`（无需走 protocol、构造 memo、递归走访）。
    """
    out: list[dict[str, Any]] = []
    for it in bsp_history or []:
        if isinstance(it, dict):
            out.append(dict(it))
        else:
            out.append(it)
    return out


def run_strategy_backtest(req: IndicatorBacktestReq) -> dict[str, Any]:
    """兼容旧路由名；实现见 run_indicator_backtest。"""
    return run_indicator_backtest(req)


class AppState:
    def __init__(self) -> None:
        self.stepper = ChanStepper()
        self.stepper2: Optional[ChanStepper] = None
        self.multi_steppers: list[ChanStepper] = []
        self.chart_mode: str = "single"
        self.active_chart_id: str = "chart1"
        self.account = PaperAccount(initial_cash=10_000, cash=10_000)
        self.ready = False
        self.finished = False
        self.session_params: Optional[dict[str, Any]] = None
        self.trade_events: list[dict[str, Any]] = []
        self.bsp_history: list[dict[str, Any]] = []
        self._bsp_history_seen_keys: set[str] = set()
        self._bsp_history_seen_list_id: int = id(self.bsp_history)
        self._bsp_history_seen_count: int = 0
        self._bsp_light_level_signatures: dict[str, tuple[Any, ...]] = {}
        self._bsp_level_scan_meta: dict[str, tuple[Any, ...]] = {}
        self._bsp_bucket_scan_meta: dict[str, dict[str, dict[str, Any]]] = {}
        self._bsp_delta_collector_id: str = ""
        self._presentation_perf: dict[str, Any] = {}
        # trigger_step==False 全量预计算的买卖点（基于当前缠论配置）
        self.bsp_all_snapshot: list[dict[str, Any]] = []
        # 用于检测各级别变向（不区分确定/不确定）
        self._last_level_dirs: dict[str, Optional[str]] = {level: None for level in set(JUDGE_TRIGGER_LEVELS.values())}
        # 判定步骤后台记录
        self.bsp_judge_logs: list[dict[str, Any]] = []
        # 1382 节奏命中历史与去重缓存
        self.rhythm_hit_history: list[dict[str, Any]] = []
        self.rhythm_hit_keys: set[str] = set()
        self._rhythm_notice_hits: list[dict[str, Any]] = []
        # 本次 payload 是否需要弹窗提醒
        self._judge_notice: bool = False
        # 最近一次判定统计（用于 payload 弹窗展示）
        self._last_judge_stats: Optional[dict[str, Any]] = None
        # 上次判定位置（用于弹窗展示区间）
        self._last_judge_x: Optional[int] = None
        self._last_judge_time: Optional[str] = None
        # 回退缓存参数（可由前端 init/reconfig 调整）
        self._rollback_max: int = 96
        # 默认全量快照间隔：>1 时每步只产生轻量 delta，间隔步才做一次全量 deepcopy，
        # 解决「步进多根 K 线后再继续步进越来越慢」的根因（每步 deepcopy 链式累积）。
        self._rollback_full_snapshot_interval: int = 8
        # 单根数据集很小（<= capture_max_bars）时强制每步全量；默认值大于常见股票全量根数，
        # 改为更小的阈值后默认走稀疏全量路径，单步只做零拷贝的轻量 delta。
        self._rollback_capture_max_bars: int = 800
        # 分层快照：每步轻量 + 稀疏全量
        self._rollback_light: deque[AppStepDelta] = deque(maxlen=self._rollback_max)
        self._rollback_full: dict[int, AppRollbackSnapshot] = {}
        self._rollback_full_order: deque[int] = deque()
        # 目标步精确命中表：记录已到达过的目标步全量快照，减少重复前向补步。
        self._rollback_target_hits: dict[int, AppRollbackSnapshot] = {}
        self._rollback_target_hit_order: deque[int] = deque()
        # BSP 全量快照前缀索引缓存：用内存换判定速度。
        self._bsp_all_prefix_x: list[int] = []
        self._bsp_all_prefix_keys: list[set[str]] = []

    def _reset_bsp_incremental_cache(self) -> None:
        """重置逐K BSP 增量小账本，避免回退/重配后串历史。"""
        self._bsp_history_seen_keys = set()
        self._bsp_history_seen_list_id = id(self.bsp_history)
        self._bsp_history_seen_count = len(self.bsp_history)
        self._bsp_light_level_signatures = {}
        self._bsp_level_scan_meta = {}
        self._bsp_bucket_scan_meta = {}
        self._reset_rust_bsp_delta_collector()

    def _current_bsp_delta_collector_id(self) -> str:
        try:
            stepper = self.get_active_stepper()
        except Exception:
            stepper = self.stepper
        sid = str(getattr(stepper, "perf_session_id", "") or id(stepper))
        return f"{id(self)}:{sid}:{self.active_chart_id}"

    def _reset_rust_bsp_delta_collector(self) -> None:
        self._bsp_delta_collector_id = self._current_bsp_delta_collector_id()
        try:
            APP_PERF_ENGINE.reset_bsp_delta_collector(self._bsp_delta_collector_id, self.bsp_history)
        except Exception:
            pass

    def _bsp_history_seen_keys_current(self) -> set[str]:
        """拿到已冻结 BSP key 集合；历史列表换过就重建一次。"""
        cur_id = id(self.bsp_history)
        cur_len = len(self.bsp_history)
        if (
            cur_id != getattr(self, "_bsp_history_seen_list_id", None)
            or cur_len != getattr(self, "_bsp_history_seen_count", -1)
        ):
            self._bsp_history_seen_keys = {
                str(item.get("key"))
                for item in self.bsp_history
                if isinstance(item, dict) and item.get("key")
            }
            self._bsp_history_seen_list_id = cur_id
            self._bsp_history_seen_count = cur_len
            self._bsp_light_level_signatures = {}
            self._bsp_level_scan_meta = {}
            self._bsp_bucket_scan_meta = {}
            self._reset_rust_bsp_delta_collector()
        return self._bsp_history_seen_keys

    def _mark_bsp_history_appended(self, key: str) -> None:
        self._bsp_history_seen_keys.add(str(key))
        self._bsp_history_seen_list_id = id(self.bsp_history)
        self._bsp_history_seen_count = len(self.bsp_history)

    @staticmethod
    def _bsp_source_signature(*parts: Any) -> tuple[Any, ...]:
        """结构尾巴签名：用于判断某级 BSP 是否需要重新扫。"""
        return tuple(parts)

    def _bsp_incremental_need_scan(
        self,
        level: str,
        structural_sig: tuple[Any, ...],
        bsp_list: Any,
    ) -> bool:
        """结构签名+列表长度未变则跳过；形成中价位浮动不触发重扫。"""
        flat_len = _bsp_list_flat_len(bsp_list)
        meta = self._bsp_level_scan_meta.get(str(level))
        bsp_id = id(bsp_list) if bsp_list is not None else 0
        if meta and meta[0] == structural_sig and meta[1] == bsp_id and meta[2] == flat_len:
            return False
        return True

    def _bsp_incremental_mark_scanned(
        self,
        level: str,
        structural_sig: tuple[Any, ...],
        bsp_list: Any,
    ) -> None:
        self._bsp_level_scan_meta[str(level)] = (
            structural_sig,
            id(bsp_list) if bsp_list is not None else 0,
            _bsp_list_flat_len(bsp_list),
        )

    def _bsp_struct_sig_unchanged(self, key: str, structural_sig: tuple[Any, ...]) -> bool:
        """高级别 BSP 重算门闩：2段/3段结构签名未变则跳过重链构建。"""
        return self._bsp_level_scan_meta.get(f"@{key}") == structural_sig

    def _bsp_mark_struct_sig(self, key: str, structural_sig: tuple[Any, ...]) -> None:
        self._bsp_level_scan_meta[f"@{key}"] = structural_sig

    def _reset_presentation_perf(self, *, target_step: int, total: int) -> None:
        """一次性呈现性能账本：只记耗时和次数，不改计算结果。"""
        self._presentation_perf = {
            "enabled": True,
            "target_step": int(target_step),
            "total": int(total),
            "loop_steps": 0,
            "step_calls": 0,
            "step_ms": 0.0,
            "progress_ms": 0.0,
            "bsp_sync_calls": 0,
            "bsp_sync_ms": 0.0,
            "bsp_snapshot_calls": 0,
            "bsp_snapshot_ms": 0.0,
            "bsp_snapshot_items": 0,
            "bsp_append_calls": 0,
            "bsp_append_ms": 0.0,
            "rust_collect_calls": 0,
            "rust_collect_ms": 0.0,
            "rust_items": 0,
            "python_items": 0,
            "rust_shadow_ms": 0.0,
            "rust_shadow_calls": 0,
            "rust_shadow_mismatch_step": None,
            "dual_sync_ms": 0.0,
            "final_sync_ms": 0.0,
            "coarse_rebuild_ms": 0.0,
            "levels": {},
            "cache": {},
        }
        for st in [self.stepper, self.stepper2, *(self.multi_steppers or [])]:
            if st is not None and hasattr(st, "reset_bsp_cache_stats"):
                st.reset_bsp_cache_stats()
            if st is not None and hasattr(st, "reset_step_perf_stats"):
                st.reset_step_perf_stats()

    def _presentation_perf_active(self) -> bool:
        return bool((getattr(self, "_presentation_perf", None) or {}).get("enabled"))

    def _presentation_perf_add(self, key: str, value: float) -> None:
        perf = getattr(self, "_presentation_perf", None)
        if not perf or not perf.get("enabled"):
            return
        perf[key] = float(perf.get(key, 0.0)) + float(value)

    def _presentation_perf_inc(self, key: str, value: int = 1) -> None:
        perf = getattr(self, "_presentation_perf", None)
        if not perf or not perf.get("enabled"):
            return
        perf[key] = int(perf.get(key, 0)) + int(value)

    def _presentation_level_perf(self, level: str) -> Optional[dict[str, Any]]:
        perf = getattr(self, "_presentation_perf", None)
        if not perf or not perf.get("enabled"):
            return None
        levels = perf.setdefault("levels", {})
        return levels.setdefault(
            str(level),
            {
                "checks": 0,
                "skip": 0,
                "struct_skip": 0,
                "scan": 0,
                "items": 0,
                "scan_ms": 0.0,
                "signature_ms": 0.0,
                "rust_ms": 0.0,
                "python_iter_ms": 0.0,
                "item_ms": 0.0,
                "cursor_tail": 0,
                "cursor_full": 0,
                "cursor_empty": 0,
                "bucket_candidates": 0,
            },
        )

    def _presentation_record_bsp_snapshot(self, start: float, item_count: int) -> None:
        perf = getattr(self, "_presentation_perf", None)
        if not perf or not perf.get("enabled"):
            return
        perf["bsp_snapshot_calls"] = int(perf.get("bsp_snapshot_calls", 0)) + 1
        perf["bsp_snapshot_ms"] = float(perf.get("bsp_snapshot_ms", 0.0)) + (time.perf_counter() - start) * 1000.0
        perf["bsp_snapshot_items"] = int(perf.get("bsp_snapshot_items", 0)) + int(item_count)

    def _finish_presentation_perf(self) -> None:
        perf = getattr(self, "_presentation_perf", None)
        if not perf or not perf.get("enabled"):
            return
        cache: dict[str, Any] = {}
        for label, st in [
            ("stepper1", self.stepper),
            ("stepper2", self.stepper2),
            *[(f"multi{idx + 1}", st) for idx, st in enumerate(self.multi_steppers or [])],
        ]:
            if st is not None and hasattr(st, "bsp_cache_stats_snapshot"):
                cache[label] = st.bsp_cache_stats_snapshot()
        perf["cache"] = cache
        step_detail: dict[str, Any] = {}
        for label, st in [
            ("stepper1", self.stepper),
            ("stepper2", self.stepper2),
            *[(f"multi{idx + 1}", st) for idx, st in enumerate(self.multi_steppers or [])],
        ]:
            if st is not None and hasattr(st, "step_perf_stats_snapshot"):
                step_detail[label] = st.step_perf_stats_snapshot()
        perf["step_detail"] = step_detail
        perf["enabled"] = False

        step_s = float(perf.get("step_ms", 0.0)) / 1000.0
        bsp_s = float(perf.get("bsp_sync_ms", 0.0)) / 1000.0
        snap_s = float(perf.get("bsp_snapshot_ms", 0.0)) / 1000.0
        rust_s = float(perf.get("rust_shadow_ms", 0.0)) / 1000.0
        rust_shadow_calls = int(perf.get("rust_shadow_calls", 0))
        mismatch_step = perf.get("rust_shadow_mismatch_step")
        cache1 = cache.get("stepper1", {}) if isinstance(cache, dict) else {}
        detail1 = step_detail.get("stepper1", {}) if isinstance(step_detail, dict) else {}
        level_parts: list[str] = []
        levels_map = perf.get("levels") if isinstance(perf.get("levels"), dict) else {}
        level_keys = ["bi", "seg", "segseg", "extra"]
        if isinstance(levels_map, dict):
            for lv_key in sorted((k for k in levels_map.keys() if k not in set(level_keys)), key=bsp_level_sort_order):
                level_keys.append(str(lv_key))
        for lv_key in level_keys:
            row = levels_map.get(lv_key) if isinstance(levels_map, dict) else None
            if not isinstance(row, dict):
                continue
            scan_ms = float(row.get("scan_ms", 0.0)) / 1000.0
            level_parts.append(
                f"{lv_key}={scan_ms:.2f}s"
                f"/扫{int(row.get('scan', 0))}"
                f"跳{int(row.get('skip', 0))}"
                f"增{int(row.get('items', 0))}"
            )
        level_tail = f"；BSP分级={'；'.join(level_parts)}" if level_parts else ""
        bsp_action_parts: list[str] = []
        for lv_key in level_keys:
            row = levels_map.get(lv_key) if isinstance(levels_map, dict) else None
            if not isinstance(row, dict):
                continue
            bsp_action_parts.append(
                f"{lv_key}:签名={float(row.get('signature_ms', 0.0)) / 1000.0:.2f}s"
                f"/扫描={float(row.get('scan_ms', 0.0)) / 1000.0:.2f}s"
                f"/Rust全扫={float(row.get('rust_ms', 0.0)) / 1000.0:.2f}s"
                f"/Python遍历={float(row.get('python_iter_ms', 0.0)) / 1000.0:.2f}s"
                f"/item构造={float(row.get('item_ms', 0.0)) / 1000.0:.2f}s"
                f"/游标尾扫{int(row.get('cursor_tail', 0))}"
                f"/全扫{int(row.get('cursor_full', 0))}"
                f"/空跳{int(row.get('cursor_empty', 0))}"
                f"/候选{int(row.get('bucket_candidates', 0))}"
                f"/结构跳过{int(row.get('struct_skip', 0))}"
            )
        bsp_rebuild_detail = (
            f"segseg结构跳过={int(perf.get('segseg_struct_skip', 0))}次；"
            f"extra结构跳过={int(perf.get('extra_struct_skip', 0))}次；"
            f"segseg签名={float(cache1.get('segseg_sig_ms', 0.0)) / 1000.0:.2f}s；"
            f"segseg隐藏层={float(cache1.get('segseg_hidden_ms', 0.0)) / 1000.0:.2f}s；"
            f"segseg挂中枢={float(cache1.get('segseg_zs_ms', 0.0)) / 1000.0:.2f}s；"
            f"segseg BSP计算={float(cache1.get('segseg_bsp_ms', 0.0)) / 1000.0:.2f}s；"
            f"extra签名={float(cache1.get('extra_sig_ms', 0.0)) / 1000.0:.2f}s；"
            f"extra链构建={float(cache1.get('extra_lines_build_ms', 0.0)) / 1000.0:.2f}s；"
            f"extra中枢/BSP={float(cache1.get('extra_zs_bsp_ms', 0.0)) / 1000.0:.2f}s；"
            f"level中枢复用/新建={int(cache1.get('level_zs_hit', 0))}/{int(cache1.get('level_zs_miss', 0))}；"
            f"level中枢耗时={float(cache1.get('level_zs_ms', 0.0)) / 1000.0:.2f}s；"
            f"levelBSP复用/新建={int(cache1.get('level_bsp_hit', 0))}/{int(cache1.get('level_bsp_miss', 0))}；"
            f"levelBSP耗时={float(cache1.get('level_bsp_ms', 0.0)) / 1000.0:.2f}s"
        )
        for line in rust_presentation_detail_lines(perf, step_detail, stepper=self.stepper or ChanStepper()):
            push_record_trace(line)
        shadow_tail = ""
        if rust_chan_shadow_enabled():
            shadow_tail = (
                f"；RustShadow={rust_s:.2f}s/{rust_shadow_calls}次"
                f"{'' if mismatch_step is None else f'；shadow首错step={mismatch_step}'}"
            )
        push_record_trace(
            "一次性呈现耗时细分："
            f"step={step_s:.2f}s/{int(perf.get('step_calls', 0))}次；"
            f"step递推={float(detail1.get('iter_ms', 0.0)) / 1000.0:.2f}s；"
            f"step指标={float(detail1.get('indicator_ms', 0.0)) / 1000.0:.2f}s；"
            f"stepK线缓存={float(detail1.get('kline_cache_ms', 0.0)) / 1000.0:.2f}s；"
            f"BSP同步={bsp_s:.2f}s/{int(perf.get('bsp_sync_calls', 0))}次；"
            f"BSP快照={snap_s:.2f}s；Rust去重={float(perf.get('rust_collect_ms', 0.0)) / 1000.0:.2f}s"
            f"{shadow_tail}；"
            f"segseg快照缓存={int(cache1.get('segseg_hit', 0))}/{int(cache1.get('segseg_miss', 0))} 命中/重算(结构跳过{int(perf.get('segseg_struct_skip', 0))})；"
            f"extra快照缓存={int(cache1.get('extra_hit', 0))}/{int(cache1.get('extra_miss', 0))} 命中/重算(结构跳过{int(perf.get('extra_struct_skip', 0))})；"
            f"extra链缓存={int(cache1.get('extra_lines_hit', 0))}/{int(cache1.get('extra_lines_miss', 0))} 命中/重算"
            f"{level_tail}"
        )
        if bsp_action_parts:
            push_record_trace(f"BSP动作耗时拆分：{'；'.join(bsp_action_parts)}")
        push_record_trace(f"BSP重链耗时拆分：{bsp_rebuild_detail}")

    def _clear_rollback_cache(self) -> None:
        self._rollback_light.clear()
        self._rollback_full.clear()
        self._rollback_full_order.clear()
        self._rollback_target_hits.clear()
        self._rollback_target_hit_order.clear()

    def _set_rollback_config(
        self,
        *,
        cache_depth: Optional[int] = None,
        full_snapshot_interval: Optional[int] = None,
        capture_max_bars: Optional[int] = None,
    ) -> None:
        if cache_depth is not None:
            v = max(8, int(cache_depth))
            self._rollback_max = v
            self._rollback_light = deque(self._rollback_light, maxlen=v)
        if full_snapshot_interval is not None:
            self._rollback_full_snapshot_interval = max(1, int(full_snapshot_interval))
        if capture_max_bars is not None:
            self._rollback_capture_max_bars = max(0, int(capture_max_bars))

    def _capture_light_snapshot(self) -> AppStepDelta:
        """步进前抓取轻量增量快照。

        相较旧实现的 `copy.deepcopy(self.bsp_history)` 等递归走访式拷贝，
        本实现对「元素创建后不再修改」的列表用 `list(...)` 浅拷贝；
        对「会被原地改写 status 的 bsp_history」额外维护稀疏 status map；
        对 PaperAccount 转 tuple 后逐字段写回。
        随历史步数增长不再触发递归走访，单步开销基本恒定。
        """
        return capture_app_step_delta(
            pre_step_idx=int(self.get_active_stepper().step_idx),
            active_chart_id=str(self.active_chart_id),
            chart_mode=str(self.chart_mode),
            trade_events=self.trade_events,
            bsp_history=self.bsp_history,
            bsp_judge_logs=self.bsp_judge_logs,
            rhythm_hit_history=self.rhythm_hit_history,
            rhythm_hit_keys=self.rhythm_hit_keys,
            last_level_dirs=self._last_level_dirs,
            judge_notice=self._judge_notice,
            last_judge_stats=self._last_judge_stats,
            last_judge_x=self._last_judge_x,
            last_judge_time=self._last_judge_time,
            account=self.account,
        )

    def _restore_light_snapshot(self, delta: AppStepDelta) -> None:
        """把当前非 chan 累加状态覆盖回 delta 表示的目标态。"""
        def _set_active(v: str) -> None:
            self.active_chart_id = v

        def _set_chart_mode(v: str) -> None:
            self.chart_mode = v

        def _set_trade_events(v: list) -> None:
            self.trade_events = v

        def _set_bsp_history(v: list) -> None:
            self.bsp_history = v

        def _set_bsp_judge_logs(v: list) -> None:
            self.bsp_judge_logs = v

        def _set_rhythm_hit_history(v: list) -> None:
            self.rhythm_hit_history = v

        def _set_rhythm_hit_keys(v: set) -> None:
            self.rhythm_hit_keys = v

        def _set_last_level_dirs(v: dict) -> None:
            self._last_level_dirs = v

        def _set_judge_notice(v: bool) -> None:
            self._judge_notice = v

        def _set_last_judge_stats(v: Any) -> None:
            self._last_judge_stats = v

        def _set_last_judge_x(v: Any) -> None:
            self._last_judge_x = v

        def _set_last_judge_time(v: Any) -> None:
            self._last_judge_time = v

        overlay_app_step_delta(
            delta,
            set_active_chart_id=_set_active,
            set_chart_mode=_set_chart_mode,
            set_trade_events=_set_trade_events,
            set_bsp_history=_set_bsp_history,
            set_bsp_judge_logs=_set_bsp_judge_logs,
            set_rhythm_hit_history=_set_rhythm_hit_history,
            set_rhythm_hit_keys=_set_rhythm_hit_keys,
            set_last_level_dirs=_set_last_level_dirs,
            set_judge_notice=_set_judge_notice,
            set_last_judge_stats=_set_last_judge_stats,
            set_last_judge_x=_set_last_judge_x,
            set_last_judge_time=_set_last_judge_time,
            account=self.account,
        )
        self._rhythm_notice_hits = []
        self._reset_bsp_incremental_cache()

    def _store_full_snapshot(self, snap: AppRollbackSnapshot) -> None:
        idx = int(snap.stepper1.step_idx)
        self._rollback_full[idx] = snap
        self._rollback_full_order.append(idx)
        while len(self._rollback_full_order) > self._rollback_max:
            old = self._rollback_full_order.popleft()
            if old in self._rollback_full:
                del self._rollback_full[old]
        # 全量快照存在更新时，精确命中表也保守控长，避免无限增长。
        while len(self._rollback_target_hit_order) > self._rollback_max * 2:
            old = self._rollback_target_hit_order.popleft()
            if old in self._rollback_target_hits:
                del self._rollback_target_hits[old]

    def _capture_full_snapshot(self) -> Optional[AppRollbackSnapshot]:
        """抓取当前完整状态快照，供精确命中表复用。

        性能优化：
        - 列表 / dict 的元素是只读 frozen dict 时，用 `list(...)`/`dict(...)`
          浅拷贝而非 `deepcopy` 递归走访，避免随历史步数线性变慢；
        - bsp_history 的可变 status 字段，由 `_capture_bsp_history_with_status`
          复制 item 字典浅副本以隔离后续 status 改写。
        """
        if not self.ready or self.stepper.chan is None:
            return None
        try:
            return AppRollbackSnapshot(
                active_chart_id=str(self.active_chart_id),
                chart_mode=str(self.chart_mode),
                stepper1=capture_stepper_snapshot(self.stepper),
                stepper2=(capture_stepper_snapshot(self.stepper2) if self.stepper2 is not None else None),
                trade_events=list(self.trade_events),
                account=copy.copy(self.account),
                bsp_history=_capture_bsp_history_with_status(self.bsp_history),
                rhythm_hit_history=list(self.rhythm_hit_history),
                rhythm_hit_keys=set(self.rhythm_hit_keys),
                bsp_judge_logs=list(self.bsp_judge_logs),
                last_level_dirs=dict(self._last_level_dirs),
                judge_notice=bool(self._judge_notice),
                last_judge_stats=self._last_judge_stats,
                last_judge_x=self._last_judge_x,
                last_judge_time=self._last_judge_time,
                multi_steppers=(
                    [capture_stepper_snapshot(s) for s in self.multi_steppers] if self.multi_steppers else None
                ),
            )
        except RecursionError:
            return None

    def _store_target_hit_snapshot(self, step_idx: int, snap: AppRollbackSnapshot) -> None:
        """保存目标步精确命中快照，供 back_n 直接命中。"""
        idx = int(step_idx)
        self._rollback_target_hits[idx] = snap
        self._rollback_target_hit_order.append(idx)
        while len(self._rollback_target_hit_order) > self._rollback_max * 2:
            old = self._rollback_target_hit_order.popleft()
            if old in self._rollback_target_hits:
                del self._rollback_target_hits[old]

    def _capture_should_store_full(self, step_idx: int) -> bool:
        master = getattr(self.stepper, "_replay_klus_master", None) or []
        bars = len(master) if isinstance(master, list) else 0
        if bars <= self._rollback_capture_max_bars:
            return True
        return step_idx % self._rollback_full_snapshot_interval == 0

    def _push_rollback_snapshot(self) -> None:
        if not self.ready or self.stepper.chan is None:
            return
        cur_step = int(self.get_active_stepper().step_idx)
        should_full = self._capture_should_store_full(cur_step)
        # 单步快照：零深拷贝；本次仍要做的轻量 delta 与历史步数解耦，恒定成本。
        self._rollback_light.append(self._capture_light_snapshot())
        if not should_full:
            return
        # 全量快照：仅在采样间隔点触发。chan/indicators 仍需 deepcopy；
        # 累加列表用浅拷贝避免随步数累积的递归走访开销。
        snap = self._capture_full_snapshot()
        if snap is None:
            return
        self._store_full_snapshot(snap)
        # target_hits 与 full snapshot 共享同一份 snap 引用：
        # 旧实现的 `copy.deepcopy(snap)` 完全是冗余复制（_restore_full_snapshot 中
        # 已对 _rollback_target_hits.get(target) 做了 `copy.deepcopy(hit)`）。
        # 这里直接共享引用即可，省下一次完整 deepcopy。
        self._store_target_hit_snapshot(cur_step, snap)

    def _restore_full_snapshot(self, snap: AppRollbackSnapshot) -> None:
        self.chart_mode = snap.chart_mode
        self.active_chart_id = snap.active_chart_id
        restore_stepper_snapshot(self.stepper, snap.stepper1)
        if snap.stepper2 is None:
            self.stepper2 = None
        else:
            if self.stepper2 is None:
                self.stepper2 = ChanStepper()
            restore_stepper_snapshot(self.stepper2, snap.stepper2)
        msn = getattr(snap, "multi_steppers", None)
        if msn:
            self.multi_steppers = []
            for sub in msn:
                st = ChanStepper()
                restore_stepper_snapshot(st, sub)
                self.multi_steppers.append(st)
        else:
            self.multi_steppers = []
        self.trade_events = snap.trade_events
        self.account = snap.account
        self.bsp_history = snap.bsp_history
        self.rhythm_hit_history = snap.rhythm_hit_history
        self.rhythm_hit_keys = snap.rhythm_hit_keys
        self.bsp_judge_logs = snap.bsp_judge_logs
        self._last_level_dirs = snap.last_level_dirs
        self._judge_notice = snap.judge_notice
        self._last_judge_stats = snap.last_judge_stats
        self._last_judge_x = snap.last_judge_x
        self._last_judge_time = snap.last_judge_time
        self._rhythm_notice_hits = []
        self._reset_bsp_incremental_cache()

    def _memory_step_forward_no_snapshot(self, n: int) -> None:
        for _ in range(max(0, int(n))):
            active = self.get_active_stepper()
            ok = active.step()
            if ok:
                self._sync_passives_to_anchor(active.current_time())
            self._dual_rebuild_coarse_chan_anti_future(active.current_time())
            if not ok:
                break
            self.sync_bsp_history()
            self.sync_rhythm_history()
            self.after_step_update()

    def _rollback_n_steps_from_memory(self, n: int) -> int:
        """内存回退 n 步；返回实际回退步数。"""
        if n <= 0:
            return 0
        cur = int(self.get_active_stepper().step_idx)
        target = max(-1, cur - int(n))
        if target == cur:
            return 0
        hit = self._rollback_target_hits.get(target)
        if hit is not None:
            self._restore_full_snapshot(copy.deepcopy(hit))
            return max(0, cur - int(self.get_active_stepper().step_idx))
        # 先找 <= target 的最近全量快照
        full_keys = sorted(int(k) for k in self._rollback_full.keys())
        if not full_keys:
            return 0
        pos = bisect_right(full_keys, target) - 1
        if pos < 0:
            return 0
        base_idx = full_keys[pos]
        snap = self._rollback_full.get(base_idx)
        if snap is None:
            return 0
        self._restore_full_snapshot(snap)
        self._memory_step_forward_no_snapshot(target - base_idx)
        # 若轻量快照里有目标步，覆盖一次轻量状态（进一步对齐）
        for ls in reversed(self._rollback_light):
            if int(ls.step_idx) == target:
                self._restore_light_snapshot(copy.deepcopy(ls))
                break
        exact_snap = self._capture_full_snapshot()
        if exact_snap is not None:
            self._store_target_hit_snapshot(target, exact_snap)
        return max(0, cur - int(self.get_active_stepper().step_idx))

    def _normalize_chart_id(self, chart_id: Optional[str]) -> str:
        cid = str(chart_id or self.active_chart_id or "chart1").strip().lower()
        return "chart2" if (self.chart_mode == "dual" and cid == "chart2" and self.stepper2 is not None) else "chart1"

    def get_active_stepper(self, chart_id: Optional[str] = None) -> ChanStepper:
        cid = self._normalize_chart_id(chart_id)
        return self.stepper2 if (cid == "chart2" and self.stepper2 is not None) else self.stepper

    def get_passive_stepper(self, chart_id: Optional[str] = None) -> Optional[ChanStepper]:
        if self.chart_mode != "dual" or self.stepper2 is None:
            return None
        cid = self._normalize_chart_id(chart_id)
        return self.stepper if cid == "chart2" else self.stepper2

    @staticmethod
    def _parse_time_safe(ts: str) -> Optional[datetime]:
        return bt_parse_time_safe(ts)

    def _anchor_compare_effective_dt(self, stepper: ChanStepper, time_str: str) -> Optional[datetime]:
        """被动同步比较用：日线等常只有日期串，解析成午夜会与同日分钟锚点误判，故用「该显示日结束」比较。"""
        return bt_anchor_compare_effective_dt(stepper, time_str)

    def _sync_stepper_to_anchor(self, stepper: ChanStepper, anchor_time: str) -> None:
        """将目标周期对齐到 anchor_time；unified 可前进/后退切片，step 仍为逐步向前。"""
        stepper.unified_sync_to_anchor_time(anchor_time)

    @staticmethod
    def _k_type_granularity_rank(k_type: KL_TYPE) -> int:
        return kl_granularity_rank(k_type)

    def _resolve_dual_coarse_fine(self) -> Optional[tuple[ChanStepper, ChanStepper]]:
        """双周期下识别粗细周期；优先按 k_type，兜底按已载入 K 根数。"""
        return bt_resolve_dual_coarse_fine(str(self.chart_mode or "single"), self.stepper, self.stepper2)

    def _apply_partial_last_bar(
        self, big_chart: dict[str, Any], coarse: ChanStepper, fine: ChanStepper, anchor_time: str
    ) -> None:
        """防未来数据：用细周期（必要时回退 raw）截至锚点数据重算粗周期末根 OHLCV。"""
        big_ks = big_chart.get("kline") if isinstance(big_chart, dict) else None
        if not isinstance(big_ks, list) or len(big_ks) <= 0:
            return
        picked = self._collect_fine_klus_for_coarse_tail(coarse, fine, anchor_time)
        if not picked:
            return
        try:
            h = max(float(getattr(x, "high", 0.0)) for x in picked)
            l = min(float(getattr(x, "low", 0.0)) for x in picked)
            c = float(getattr(picked[-1], "close", 0.0))
            v = sum(_klu_float_trade_metric(x, DATA_FIELD.FIELD_VOLUME) for x in picked)
        except Exception:
            return
        last_big = big_ks[-1]
        # 开盘价保持粗周期已形成的周期首价，仅用细周期重算高低收量
        o_keep = float(last_big.get("o", last_big.get("open", 0.0)) or 0.0)
        # 细周期片段可能不含粗 K 开盘时刻，须保证 O/H/L/C 极值合法以免 kl_data_check 报错
        lo = min(o_keep, h, l, c)
        hi = max(o_keep, h, l, c)
        last_big["h"] = hi
        last_big["l"] = lo
        last_big["c"] = c
        last_big["v"] = v

    def _count_stepper_klus(self, stepper: ChanStepper) -> int:
        """已载入 K 线单元根数；较少者视为粗周期（与 build_payload 一致）。"""
        return bt_count_stepper_klus(stepper)

    @staticmethod
    def _klu_to_datetime(klu: Any) -> Optional[datetime]:
        return bt_klu_to_datetime(klu)

    def _collect_fine_klus_for_coarse_tail(
        self, coarse: ChanStepper, fine: ChanStepper, anchor_time: str
    ) -> list[Any]:
        """细周期在(上一根粗K时间, 锚点]内的 KLU；数量模式且 raw 不太大时用划分前 raw，避免合并后缺日。"""
        return bt_collect_fine_klus_for_coarse_tail(coarse, fine, anchor_time)

    def _sync_passives_to_anchor(self, anchor_time: str) -> None:
        """双周期：同步被动图；多周期：同步全部被动层到锚点。"""
        if normalize_replay_chart_mode(self.chart_mode) == "multi" and self.multi_steppers:
            for st in self.multi_steppers:
                self._sync_stepper_to_anchor(st, anchor_time)
            return
        passive = self.get_passive_stepper()
        if passive is not None:
            self._sync_stepper_to_anchor(passive, anchor_time)

    def _dual_rebuild_coarse_chan_anti_future(self, anchor_time: str) -> None:
        """双/多周期：粗周期末根按 driver 截至锚点重算并重建 Chan。"""
        if normalize_replay_chart_mode(self.chart_mode) == "multi" and self.multi_steppers:
            bt_multi_rebuild_coarse_chan_anti_future(
                self.session_params or {}, self.stepper, self.multi_steppers, anchor_time
            )
            return
        bt_dual_rebuild_coarse_chan_anti_future(
            self.session_params or {},
            str(self.chart_mode or "single"),
            self.stepper,
            self.stepper2,
            anchor_time,
        )

    def _reset_judge_state(self) -> None:
        self._judge_notice = False
        self._last_judge_stats = None
        self._last_judge_x = None
        self._last_judge_time = None
        self._rhythm_notice_hits = []

    def _reset_rhythm_history(self) -> None:
        self.rhythm_hit_history = []
        self.rhythm_hit_keys = set()
        self._rhythm_notice_hits = []

    def _current_level_dir(self, level: str) -> Optional[str]:
        st = self.get_active_stepper()
        if st.data_feed_mode == "unified":
            chart = st.build_chart_payload_cached(include_kline_all=False)
            lines = chart.get(level, [])
            if not lines:
                lines = (chart.get("extra_levels") or {}).get(level, [])
            if not lines:
                return None
            line = lines[-1]
            try:
                y1 = float(line.get("y1"))
                y2 = float(line.get("y2"))
            except Exception:
                return None
            if y2 > y1:
                return "UP"
            if y2 < y1:
                return "DOWN"
            return None
        if st.chan is None:
            return None
        bundle = st.get_structure_bundle()
        lines = get_bundle_line_list(bundle, level)
        if not lines:
            return None
        line = lines[-1]
        try:
            y1 = float(line.get_begin_val())
            y2 = float(line.get_end_val())
        except Exception:
            return None
        if y2 > y1:
            return "UP"
        if y2 < y1:
            return "DOWN"
        return None

    def rebuild_bsp_all_snapshot(self) -> None:
        """使用 trigger_step==False 一次性计算全量买卖点快照。"""
        self.bsp_all_snapshot = []
        self._bsp_all_prefix_x = []
        self._bsp_all_prefix_keys = []
        self._reset_judge_state()
        if self.session_params is None:
            return
        if self.stepper._replay_klus_master is None:
            return
        cfg_dict = (self.stepper.effective_cfg_dict or {}).copy()
        cfg_dict["trigger_step"] = False
        cfg = CChanConfig(self.stepper._cfg_without_chan_algo(cfg_dict))
        chan_all = ReplayChan(
            code=self.stepper.code,
            begin_time=self.session_params["begin_date"],
            end_time=self.session_params["end_date"],
            data_src=self.stepper.data_src_used or DATA_SRC.AKSHARE,
            lv_list=[self.stepper.k_type],
            config=cfg,
            autype=self.session_params["autype"],
            replay_klus_master=self.stepper._replay_klus_master,
        )
        # 强制全量加载一次，生成笔/线段/中枢/买卖点
        for _ in chan_all.load(step=False):
            pass
        lazy_layers = (self.session_params or {}).get("chart_lazy_layers")
        bundle = build_structure_bundle(chan_all, self.stepper.chan_algo, chart_lazy_layers=lazy_layers)
        snapshot: list[dict[str, Any]] = []
        for level in bsp_levels_from_layers(lazy_layers):
            if not chart_lazy_bsp_enabled(lazy_layers, level):
                continue
            bsp_list = get_bundle_bsp_list(bundle, level)
            for bsp in bsp_list.bsp_iter():
                item = make_bsp_item(level, bsp)
                item["key"] = self._bsp_key(item)
                snapshot.append(item)
        self.bsp_all_snapshot = sorted(
            snapshot,
            key=lambda item: (int(item.get("x", -1)), bsp_level_sort_order(str(item.get("level"))), int(not bool(item.get("is_buy")))),
        )
        # 前缀索引缓存：每个 x 对应“<=x 的全部 key 集合”，判定时 O(logN) 直取。
        running_keys: set[str] = set()
        for item in self.bsp_all_snapshot:
            x = int(item.get("x", -1))
            key = str(item.get("key") or "")
            if not key:
                continue
            running_keys.add(key)
            if self._bsp_all_prefix_x and self._bsp_all_prefix_x[-1] == x:
                self._bsp_all_prefix_keys[-1] = set(running_keys)
            else:
                self._bsp_all_prefix_x.append(x)
                self._bsp_all_prefix_keys.append(set(running_keys))

    def _install_bsp_all_snapshot(self, snapshot: list[dict[str, Any]]) -> None:
        """安装全量 BSP 快照，并重建前缀索引。"""
        self.bsp_all_snapshot = sorted(
            snapshot,
            key=lambda item: (int(item.get("x", -1)), bsp_level_sort_order(str(item.get("level"))), int(not bool(item.get("is_buy")))),
        )
        self._bsp_all_prefix_x = []
        self._bsp_all_prefix_keys = []
        running_keys: set[str] = set()
        for item in self.bsp_all_snapshot:
            x = int(item.get("x", -1))
            key = str(item.get("key") or "")
            if not key:
                continue
            running_keys.add(key)
            if self._bsp_all_prefix_x and self._bsp_all_prefix_x[-1] == x:
                self._bsp_all_prefix_keys[-1] = set(running_keys)
            else:
                self._bsp_all_prefix_x.append(x)
                self._bsp_all_prefix_keys.append(set(running_keys))

    def rebuild_bsp_all_snapshot_from_current(self) -> None:
        """一次性呈现后复用当前已算好的结构，避免全量缠论重复跑一遍。"""
        self.bsp_all_snapshot = []
        self._bsp_all_prefix_x = []
        self._bsp_all_prefix_keys = []
        self._reset_judge_state()
        stepper = self.get_active_stepper()
        if stepper.data_feed_mode == "unified":
            chart = stepper.build_chart_payload_cached(include_kline_all=False)
            src = chart.get("bsp", []) or []
            snapshot: list[dict[str, Any]] = []
            for item in src:
                try:
                    snap = {
                        "x": int(item.get("x", -1)),
                        "y": float(item.get("y", 0.0)),
                        "is_buy": bool(item.get("is_buy")),
                        "label": str(item.get("label", "")),
                        "level": str(item.get("level", "")),
                        "level_label": str(item.get("level_label", "")),
                        "display_label": str(item.get("display_label", "")),
                    }
                    snap["key"] = self._bsp_key(snap)
                    snapshot.append(snap)
                except Exception:
                    continue
            self._install_bsp_all_snapshot(snapshot)
            return
        if stepper.chan is None:
            return
        snapshot = []
        for item in self._current_bsp_snapshot_light(current_x=None, include_segseg=True):
            item["key"] = self._bsp_key(item)
            snapshot.append(item)
        self._install_bsp_all_snapshot(snapshot)

    def _judge_bsp_against_all(self, *, reason: str, levels: Optional[list[str]] = None) -> None:
        """在当前步进位置，对照（全量预计算）与（步进触发快照）进行 ×/✓ 判定。"""
        current_x = self._current_kline_x()
        if current_x is None:
            return
        if not self.bsp_all_snapshot:
            return
        active_levels = [level for level in (levels or bsp_levels_from_layers(self.session_params.get("chart_lazy_layers") if self.session_params else None)) if is_bsp_level(level)]
        if not active_levels:
            return
        all_keys_upto: set[str]
        if self._bsp_all_prefix_x:
            pos = bisect_right(self._bsp_all_prefix_x, int(current_x)) - 1
            all_keys_upto = set(self._bsp_all_prefix_keys[pos]) if pos >= 0 else set()
        else:
            all_keys_upto = {str(it.get("key")) for it in self.bsp_all_snapshot if int(it.get("x", -1)) <= current_x}
        details: list[dict[str, Any]] = []
        summary = {"appeared": 0, "judged": 0, "correct": 0, "wrong": 0}
        for level in active_levels:
            pending_items: list[dict[str, Any]] = []
            correct = 0
            wrong = 0
            for item in self.bsp_history:
                x = int(item.get("x", -1))
                if str(item.get("level")) != level or x < 0 or x > current_x:
                    continue
                if item.get("status") is not None:
                    continue
                pending_items.append(item)
            for item in pending_items:
                if str(item.get("key")) in all_keys_upto:
                    item["status"] = "correct"
                    correct += 1
                else:
                    item["status"] = "wrong"
                    wrong += 1
            judged = len(pending_items)
            summary["appeared"] += judged
            summary["judged"] += judged
            summary["correct"] += correct
            summary["wrong"] += wrong
            details.append(
                {
                    "level": level,
                    "level_label": level_label(level),
                    "appeared": judged,
                    "judged": judged,
                    "correct": correct,
                    "wrong": wrong,
                    "rate": (correct / judged) if judged > 0 else None,
                }
            )

        rate = (summary["correct"] / summary["judged"]) if summary["judged"] > 0 else None
        cur_time = self.get_active_stepper().current_time()
        interval = {
            "from_x": self._last_judge_x,
            "to_x": int(current_x),
            "from_time": self._last_judge_time or "-",
            "to_time": cur_time,
        }
        stats = {
            "step_idx": int(self.get_active_stepper().step_idx),
            "x": int(current_x),
            "time": cur_time,
            "reason": reason,
            "appeared": summary["appeared"],
            "judged": summary["judged"],
            "correct": summary["correct"],
            "wrong": summary["wrong"],
            "rate": rate,
            "interval": interval,
            "summary": {**summary, "rate": rate},
            "details": details,
        }
        # 自动模式（线段变向）仅在确实发生判定时提示；手动检查则始终提示
        reason_s = str(reason or "")
        is_manual = "manual" in reason_s.lower()
        should_notice = summary["judged"] > 0 or is_manual
        self._judge_notice = bool(should_notice)
        self._last_judge_stats = stats if should_notice else None
        self.bsp_judge_logs.append(stats)
        # 更新“上次判定”区间锚点（无论是否弹窗，均视为一次检查点）
        self._last_judge_x = int(current_x)
        self._last_judge_time = cur_time

    def after_step_update(self) -> None:
        """每次步进后调用：检测上一级结构变向并触发三层买卖点判定。"""
        self._judge_notice = False
        self._last_judge_stats = None
        triggered_levels: list[str] = []
        reason_parts: list[str] = []
        for level in bsp_levels_from_layers(self.get_active_stepper().chart_lazy_layers):
            trigger_level = judge_trigger_level(level)
            if not trigger_level:
                continue
            cur_dir = self._current_level_dir(trigger_level)
            last_dir = self._last_level_dirs.get(trigger_level)
            if last_dir is None:
                self._last_level_dirs[trigger_level] = cur_dir
                continue
            if cur_dir is None:
                continue
            if cur_dir != last_dir:
                triggered_levels.append(level)
                reason_parts.append(f"{level_label(level)}:{trigger_level}:{last_dir}->{cur_dir}")
            self._last_level_dirs[trigger_level] = cur_dir
        if triggered_levels:
            self._judge_bsp_against_all(reason="; ".join(reason_parts), levels=triggered_levels)

    def _current_kline_x(self) -> Optional[int]:
        stepper = self.get_active_stepper()
        if stepper.data_feed_mode == "unified":
            chart = stepper.build_chart_payload_cached(include_kline_all=False)
            bars = chart.get("kline", [])
            if not bars:
                return None
            return int(bars[-1].get("x", -1))
        if stepper.chan is None:
            return None
        kl_list = stepper.chan[0]
        if len(kl_list.lst) == 0:
            return None
        return int(kl_list.lst[-1].lst[-1].idx)

    def _build_trade_state(self) -> dict[str, Any]:
        history: list[dict[str, Any]] = []
        short_history: list[dict[str, Any]] = []
        active: Optional[dict[str, Any]] = None
        for event in self.trade_events:
            if event.get("side") == "buy":
                active = {
                    "side": "long",
                    "buyX": event.get("x"),
                    "buyPrice": float(event.get("price", 0.0)),
                    "shares": int(event.get("shares", 0)),
                    "sellX": None,
                    "sellPrice": None,
                }
            elif event.get("side") == "sell" and active is not None:
                history.append(
                    {
                        "buyX": active.get("buyX"),
                        "buyPrice": active.get("buyPrice"),
                        "shares": active.get("shares"),
                        "sellX": event.get("x"),
                        "sellPrice": float(event.get("price", 0.0)),
                    }
                )
                active = None
            elif event.get("side") == "short":
                active = {
                    "side": "short",
                    "shortX": event.get("x"),
                    "shortPrice": float(event.get("price", 0.0)),
                    "shares": int(event.get("shares", 0)),
                    "coverX": None,
                    "coverPrice": None,
                }
            elif event.get("side") == "cover" and active is not None:
                short_history.append(
                    {
                        "shortX": active.get("shortX"),
                        "shortPrice": active.get("shortPrice"),
                        "shares": active.get("shares"),
                        "coverX": event.get("x"),
                        "coverPrice": float(event.get("price", 0.0)),
                    }
                )
                active = None
        return {"history": history, "short_history": short_history, "active": active}

    def _current_bsp_snapshot(self, *, current_x: Optional[int] = None) -> list[dict[str, Any]]:
        stepper = self.get_active_stepper()
        if stepper.data_feed_mode == "unified":
            chart = stepper.build_chart_payload_cached(include_kline_all=False)
            src = chart.get("bsp", [])
            snapshot: list[dict[str, Any]] = []
            for item in src:
                x = int(item.get("x", -1))
                if current_x is not None and x != int(current_x):
                    continue
                snapshot.append(
                    {
                        "x": x,
                        "y": float(item.get("y", 0.0)),
                        "is_buy": bool(item.get("is_buy")),
                        "label": str(item.get("label", "")),
                        "level": str(item.get("level", "")),
                        "level_label": str(item.get("level_label", "")),
                        "display_label": str(item.get("display_label", "")),
                    }
                )
            if current_x is not None:
                return snapshot
            return sorted(snapshot, key=lambda it: (int(it["x"]), bsp_level_sort_order(str(it["level"])), int(not bool(it["is_buy"]))))
        if stepper.chan is None:
            return []
        bundle = stepper.get_structure_bundle()
        snapshot: list[dict[str, Any]] = []
        for level in bsp_levels_from_layers(stepper.chart_lazy_layers):
            bsp_list = get_bundle_bsp_list(bundle, level)
            for bsp in bsp_list.bsp_iter():
                item = make_bsp_item(level, bsp)
                if current_x is not None and int(item["x"]) != int(current_x):
                    continue
                snapshot.append(item)
        if current_x is not None:
            return snapshot
        return sorted(snapshot, key=lambda item: (int(item["x"]), bsp_level_sort_order(item["level"]), int(not bool(item["is_buy"]))))

    def _current_bsp_snapshot_light(self, *, current_x: Optional[int] = None, include_segseg: bool = False) -> list[dict[str, Any]]:
        """一次性呈现专用：只抓当前 BSP，不重建完整图表包。"""
        stepper = self.get_active_stepper()
        if stepper.chan is None:
            return []
        if normalize_chan_algo(stepper.chan_algo) != CHAN_ALGO_CLASSIC:
            return self._current_bsp_snapshot(current_x=current_x)
        kl_list = stepper.chan[0]
        conf = stepper.chan.conf
        level_sources: list[tuple[str, Any]] = []
        if chart_lazy_bsp_enabled(stepper.chart_lazy_layers, "bi"):
            level_sources.append(("bi", getattr(kl_list, "bs_point_lst", None)))
        if chart_lazy_bsp_enabled(stepper.chart_lazy_layers, "seg"):
            level_sources.append(("seg", getattr(kl_list, "seg_bs_point_lst", None)))
        segseg_list = getattr(kl_list, "segseg_list", None)
        lazy_layers = stepper.chart_lazy_layers if isinstance(stepper.chart_lazy_layers, dict) else normalize_chart_lazy_layers(stepper.chart_lazy_layers)
        if segseg_list is not None and chart_lazy_bsp_enabled(lazy_layers, "segseg"):
            # 2段BSP依赖2段中枢；轻量路径也要先挂中枢，否则逐K历史会漏掉2段买卖点。
            level_sources.append(("segseg", stepper.segseg_bsp_snapshot_cached(segseg_list=segseg_list, conf=conf)))
        extra_bsp = stepper.extra_bsp_snapshot_cached(segseg_list=segseg_list, conf=conf, lazy_layers=lazy_layers)
        for level in sorted(extra_bsp.keys(), key=bsp_level_sort_order):
            level_sources.append((level, extra_bsp[level]))
        snapshot: list[dict[str, Any]] = []
        for level, bsp_list in level_sources:
            if bsp_list is None:
                continue
            for bsp in bsp_list.bsp_iter():
                item = make_bsp_item(level, bsp)
                if current_x is not None and int(item["x"]) != int(current_x):
                    continue
                snapshot.append(item)
        if current_x is not None:
            return snapshot
        return sorted(snapshot, key=lambda item: (int(item["x"]), bsp_level_sort_order(item["level"]), int(not bool(item["is_buy"]))))

    def _bsp_structural_signature_timed(self, level: str, lines: Any, *, tail: int = 3) -> tuple[Any, ...]:
        t0 = time.perf_counter()
        sig = line_list_structural_signature(lines, tail=tail)
        lv_perf = self._presentation_level_perf(level)
        if lv_perf is not None:
            lv_perf["signature_ms"] = float(lv_perf.get("signature_ms", 0.0)) + (time.perf_counter() - t0) * 1000.0
        return sig

    def _collect_new_bsp_items_from_buckets(
        self,
        *,
        level: str,
        bsp_list: Any,
        seen_keys: set[str],
        current_x: Optional[int] = None,
    ) -> Optional[list[dict[str, Any]]]:
        """逐K轻量路径：按 BSP 分桶游标只扫新增尾巴。"""
        if current_x is not None:
            return None
        store = getattr(bsp_list, "bsp_store_dict", None)
        if not isinstance(store, dict):
            return None
        if not store:
            return []

        lv_perf = self._presentation_level_perf(level)
        level_meta = self._bsp_bucket_scan_meta.setdefault(str(level), {})
        active_keys: set[str] = set()
        out: list[dict[str, Any]] = []
        iter_t0 = time.perf_counter()

        for bsp_type, bucket_pair in store.items():
            for is_buy in (True, False):
                try:
                    bucket = bucket_pair[1 if is_buy else 0]
                except Exception:
                    continue
                if not isinstance(bucket, list):
                    return None
                bucket_key = f"{_bsp_type_key(bsp_type)}|{1 if is_buy else 0}"
                active_keys.add(bucket_key)
                bucket_len = len(bucket)
                meta = level_meta.get(bucket_key) or {}
                start = 0
                cursor_ok = False

                if meta.get("list_id") == id(bucket):
                    prev_next = int(meta.get("next_pos", 0) or 0)
                    if bucket_len >= prev_next:
                        if prev_next <= 0:
                            cursor_ok = True
                            start = 0
                        else:
                            check_idx = prev_next - 1
                            if check_idx < bucket_len:
                                check_bsp = bucket[check_idx]
                                if (
                                    int(meta.get("last_obj_id", -1)) == id(check_bsp)
                                    and str(meta.get("last_key", "")) == _bsp_raw_freeze_key(level, check_bsp)
                                ):
                                    cursor_ok = True
                                    start = prev_next

                if lv_perf is not None:
                    if cursor_ok and start >= bucket_len:
                        lv_perf["cursor_empty"] = int(lv_perf.get("cursor_empty", 0)) + 1
                    elif cursor_ok:
                        lv_perf["cursor_tail"] = int(lv_perf.get("cursor_tail", 0)) + 1
                    else:
                        lv_perf["cursor_full"] = int(lv_perf.get("cursor_full", 0)) + 1

                if not cursor_ok and bucket_len > 0:
                    # 官方 BSP 桶只会尾部回撤再递增追加；前缀不稳时，从尾部找已冻结点即可。
                    suffix_start = 0
                    for idx in range(bucket_len - 1, -1, -1):
                        if _bsp_raw_freeze_key(level, bucket[idx]) in seen_keys:
                            suffix_start = idx + 1
                            break
                    if suffix_start > 0:
                        start = suffix_start

                for bsp in bucket[start:]:
                    if lv_perf is not None:
                        lv_perf["bucket_candidates"] = int(lv_perf.get("bucket_candidates", 0)) + 1
                    key = _bsp_raw_freeze_key(level, bsp)
                    if key in seen_keys:
                        continue
                    item_t0 = time.perf_counter()
                    item = make_bsp_item(level, bsp)
                    if lv_perf is not None:
                        lv_perf["item_ms"] = float(lv_perf.get("item_ms", 0.0)) + (time.perf_counter() - item_t0) * 1000.0
                    key = self._bsp_key(item)
                    if key in seen_keys:
                        continue
                    out.append(item)

                if bucket_len > 0:
                    tail_bsp = bucket[-1]
                    level_meta[bucket_key] = {
                        "list_id": id(bucket),
                        "next_pos": bucket_len,
                        "last_obj_id": id(tail_bsp),
                        "last_key": _bsp_raw_freeze_key(level, tail_bsp),
                    }
                else:
                    level_meta[bucket_key] = {"list_id": id(bucket), "next_pos": 0, "last_obj_id": 0, "last_key": ""}

        for old_key in list(level_meta.keys()):
            if old_key not in active_keys:
                level_meta.pop(old_key, None)

        if lv_perf is not None:
            lv_perf["python_iter_ms"] = float(lv_perf.get("python_iter_ms", 0.0)) + (time.perf_counter() - iter_t0) * 1000.0
        return out

    def _collect_new_bsp_items_from_list(
        self,
        *,
        level: str,
        bsp_list: Any,
        seen_keys: set[str],
        current_x: Optional[int] = None,
    ) -> list[dict[str, Any]]:
        """只收本次还没冻结过的 BSP；历史标签不回写。"""
        if bsp_list is None or _bsp_list_flat_len(bsp_list) <= 0:
            return []
        bucket_items = self._collect_new_bsp_items_from_buckets(
            level=level,
            bsp_list=bsp_list,
            seen_keys=seen_keys,
            current_x=current_x,
        )
        if bucket_items is not None:
            return bucket_items
        lv_perf = self._presentation_level_perf(level)
        rust_t0 = time.perf_counter()
        rust_items = APP_PERF_ENGINE.collect_bsp_items_from_list(
            level=level,
            level_label=level_label(level),
            bsp_list=bsp_list,
            seen_keys=seen_keys,
            current_x=current_x,
        )
        if lv_perf is not None:
            lv_perf["rust_ms"] = float(lv_perf.get("rust_ms", 0.0)) + (time.perf_counter() - rust_t0) * 1000.0
        if rust_items is not None:
            return rust_items
        out: list[dict[str, Any]] = []
        iter_t0 = time.perf_counter()
        for bsp in bsp_list.bsp_iter():
            item_t0 = time.perf_counter()
            item = make_bsp_item(level, bsp)
            if lv_perf is not None:
                lv_perf["item_ms"] = float(lv_perf.get("item_ms", 0.0)) + (time.perf_counter() - item_t0) * 1000.0
            if current_x is not None and int(item["x"]) != int(current_x):
                continue
            key = self._bsp_key(item)
            if key in seen_keys:
                continue
            out.append(item)
        if lv_perf is not None:
            lv_perf["python_iter_ms"] = float(lv_perf.get("python_iter_ms", 0.0)) + (time.perf_counter() - iter_t0) * 1000.0
        return out

    def _incremental_collect_level_bsp(
        self,
        *,
        level: str,
        structural_sig: tuple[Any, ...],
        bsp_list: Any,
        seen_keys: set[str],
        current_x: Optional[int] = None,
    ) -> list[dict[str, Any]]:
        """一次性逐K：按结构签名决定是否扫描该级 BSP。"""
        lv_perf = self._presentation_level_perf(level)
        if lv_perf is not None:
            lv_perf["checks"] = int(lv_perf.get("checks", 0)) + 1
        if not self._bsp_incremental_need_scan(level, structural_sig, bsp_list):
            if lv_perf is not None:
                lv_perf["skip"] = int(lv_perf.get("skip", 0)) + 1
            return []
        t0 = time.perf_counter()
        items = self._collect_new_bsp_items_from_list(
            level=level,
            bsp_list=bsp_list,
            seen_keys=seen_keys,
            current_x=current_x,
        )
        if lv_perf is not None:
            lv_perf["scan"] = int(lv_perf.get("scan", 0)) + 1
            lv_perf["items"] = int(lv_perf.get("items", 0)) + len(items)
            lv_perf["scan_ms"] = float(lv_perf.get("scan_ms", 0.0)) + (time.perf_counter() - t0) * 1000.0
        self._bsp_incremental_mark_scanned(level, structural_sig, bsp_list)
        return items

    def _current_bsp_snapshot_incremental_light(self, *, current_x: Optional[int] = None) -> list[dict[str, Any]]:
        """一次性逐K专用：结构没变的级别直接跳过，只返回新增 BSP。"""
        snapshot_t0 = time.perf_counter()
        stepper = self.get_active_stepper()
        if stepper.chan is None:
            self._presentation_record_bsp_snapshot(snapshot_t0, 0)
            return []
        if normalize_chan_algo(stepper.chan_algo) != CHAN_ALGO_CLASSIC:
            seen_keys = self._bsp_history_seen_keys_current()
            out = [
                item
                for item in self._current_bsp_snapshot(current_x=current_x)
                if self._bsp_key(item) not in seen_keys
            ]
            self._presentation_record_bsp_snapshot(snapshot_t0, len(out))
            return out

        kl_list = stepper.chan[0]
        conf = stepper.chan.conf
        lazy_layers = stepper.chart_lazy_layers if isinstance(stepper.chart_lazy_layers, dict) else normalize_chart_lazy_layers(stepper.chart_lazy_layers)
        seen_keys = self._bsp_history_seen_keys_current()
        snapshot: list[dict[str, Any]] = []
        source_sig_cache: dict[str, tuple[Any, ...]] = {}

        def source_sig(name: str, stat_level: str, lines: Any) -> tuple[Any, ...]:
            if name not in source_sig_cache:
                source_sig_cache[name] = self._bsp_structural_signature_timed(stat_level, lines, tail=3)
            return source_sig_cache[name]

        if chart_lazy_bsp_enabled(lazy_layers, "bi"):
            bi_sig = self._bsp_source_signature(
                "bi",
                id(conf.bs_point_conf),
                source_sig("bi_list", "bi", getattr(kl_list, "bi_list", None)),
                source_sig("seg_list", "bi", getattr(kl_list, "seg_list", None)),
            )
            snapshot.extend(
                self._incremental_collect_level_bsp(
                    level="bi",
                    structural_sig=bi_sig,
                    bsp_list=getattr(kl_list, "bs_point_lst", None),
                    seen_keys=seen_keys,
                    current_x=current_x,
                )
            )

        if chart_lazy_bsp_enabled(lazy_layers, "seg"):
            seg_sig = self._bsp_source_signature(
                "seg",
                id(conf.seg_bs_point_conf),
                source_sig("seg_list", "seg", getattr(kl_list, "seg_list", None)),
                source_sig("segseg_list", "seg", getattr(kl_list, "segseg_list", None)),
            )
            snapshot.extend(
                self._incremental_collect_level_bsp(
                    level="seg",
                    structural_sig=seg_sig,
                    bsp_list=getattr(kl_list, "seg_bs_point_lst", None),
                    seen_keys=seen_keys,
                    current_x=current_x,
                )
            )

        segseg_list = getattr(kl_list, "segseg_list", None)
        extra_levels = tuple(extra_bsp_levels_from_layers(lazy_layers))
        segseg_lines_sig: Optional[tuple[Any, ...]] = None
        if segseg_list is not None and (chart_lazy_bsp_enabled(lazy_layers, "segseg") or extra_levels):
            sig_level = "segseg" if chart_lazy_bsp_enabled(lazy_layers, "segseg") else "extra"
            segseg_lines_sig = source_sig("segseg_list", sig_level, segseg_list)

        if segseg_list is not None and chart_lazy_bsp_enabled(lazy_layers, "segseg"):
            segseg_sig = self._bsp_source_signature(
                "segseg",
                id(conf.seg_conf),
                id(conf.zs_conf),
                id(conf.seg_bs_point_conf),
                segseg_lines_sig,
            )
            if not self._bsp_struct_sig_unchanged("segseg", segseg_sig):
                segseg_bsp = stepper.segseg_bsp_snapshot_cached(segseg_list=segseg_list, conf=conf, source_sig=segseg_lines_sig)
                snapshot.extend(
                    self._incremental_collect_level_bsp(
                        level="segseg",
                        structural_sig=segseg_sig,
                        bsp_list=segseg_bsp,
                        seen_keys=seen_keys,
                        current_x=current_x,
                    )
                )
                self._bsp_mark_struct_sig("segseg", segseg_sig)
            else:
                self._presentation_perf_inc("segseg_struct_skip")
                lv_perf = self._presentation_level_perf("segseg")
                if lv_perf is not None:
                    lv_perf["checks"] = int(lv_perf.get("checks", 0)) + 1
                    lv_perf["skip"] = int(lv_perf.get("skip", 0)) + 1
                    lv_perf["struct_skip"] = int(lv_perf.get("struct_skip", 0)) + 1

        if segseg_list is not None and extra_levels:
            extra_sig = self._bsp_source_signature(
                "extra",
                extra_levels,
                id(conf.seg_conf),
                id(conf.zs_conf),
                id(conf.seg_bs_point_conf),
                segseg_lines_sig,
            )
            if not self._bsp_struct_sig_unchanged("extra", extra_sig):
                extra_bsp = stepper.extra_bsp_snapshot_cached(segseg_list=segseg_list, conf=conf, lazy_layers=lazy_layers, source_sig=segseg_lines_sig)
                for level in sorted(extra_bsp.keys(), key=bsp_level_sort_order):
                    snapshot.extend(
                        self._incremental_collect_level_bsp(
                            level=str(level),
                            structural_sig=extra_sig,
                            bsp_list=extra_bsp[level],
                            seen_keys=seen_keys,
                            current_x=current_x,
                        )
                    )
                self._bsp_mark_struct_sig("extra", extra_sig)
            else:
                self._presentation_perf_inc("extra_struct_skip")
                lv_perf = self._presentation_level_perf("extra")
                if lv_perf is not None:
                    lv_perf["checks"] = int(lv_perf.get("checks", 0)) + 1
                    lv_perf["skip"] = int(lv_perf.get("skip", 0)) + 1
                    lv_perf["struct_skip"] = int(lv_perf.get("struct_skip", 0)) + 1

        if current_x is not None:
            self._presentation_record_bsp_snapshot(snapshot_t0, len(snapshot))
            return snapshot
        out = sorted(snapshot, key=lambda item: (int(item["x"]), bsp_level_sort_order(item["level"]), int(not bool(item["is_buy"]))))
        self._presentation_record_bsp_snapshot(snapshot_t0, len(out))
        return out

    @staticmethod
    def _bsp_key(item: dict[str, Any]) -> str:
        # 逐K当下性：同级别/同锚点/同方向只冻结首次识别标签，未来组合标签不回写、不追加。
        return f'{item["level"]}|{int(item["x"])}|{1 if item["is_buy"] else 0}'

    def sync_bsp_history(self) -> None:
        """同步当前步进下的买卖点历史。

        注意：×/✓ 判定不在这里做，而是在“上一级结构变向”时对照全量快照进行。
        """
        current_x = self._current_kline_x()
        if current_x is None:
            self.bsp_history = []
            self._reset_bsp_incremental_cache()
            return

        stepper = self.get_active_stepper()
        # unified：图表序列化已含截至当前切片的全部 BSP，直接对齐 bsp_history（步进 N、切片浏览均一致）
        if stepper.data_feed_mode == "unified":
            chart = stepper.build_chart_payload_cached(include_kline_all=False)
            src = chart.get("bsp", []) or []
            status_by_key = {str(it.get("key")): it.get("status") for it in self.bsp_history if it.get("key")}
            next_hist: list[dict[str, Any]] = []
            seen_keys: set[str] = set()
            for item in sorted(
                src,
                key=lambda it: (
                    int(it.get("x", -1)),
                    bsp_level_sort_order(str(it.get("level"))),
                    int(not bool(it.get("is_buy"))),
                ),
            ):
                try:
                    key = self._bsp_key(
                        {
                            "level": str(item.get("level", "")),
                            "x": int(item.get("x", -1)),
                            "label": str(item.get("label", "")),
                            "is_buy": bool(item.get("is_buy")),
                        }
                    )
                except Exception:
                    continue
                if key in seen_keys:
                    continue
                seen_keys.add(key)
                next_hist.append(
                    {
                        "key": key,
                        "x": int(item.get("x", -1)),
                        "is_buy": bool(item.get("is_buy")),
                        "label": str(item.get("label", "")),
                        "level": str(item.get("level", "")),
                        "level_label": str(item.get("level_label", "")),
                        "display_label": str(item.get("display_label", "")),
                        "status": status_by_key.get(key),
                    }
                )
            self.bsp_history = next_hist
            self._reset_bsp_incremental_cache()
            return

        # 普通步进也按“当前已知全量快照 - 已冻结历史”增量追加；不按锚点等于当前 K 过滤。
        snapshot = self._current_bsp_snapshot(current_x=None)
        self._append_bsp_history_items(snapshot, display_x=current_x)

    def _append_bsp_history_items(
        self,
        snapshot: list[dict[str, Any]],
        *,
        display_x: Optional[int] = None,
        use_rust_delta: bool = False,
    ) -> None:
        """追加 BSP 历史，供普通步进和轻量逐K共用。"""
        append_t0 = time.perf_counter()
        if not snapshot:
            self._presentation_perf_inc("bsp_append_calls")
            self._presentation_perf_add("bsp_append_ms", (time.perf_counter() - append_t0) * 1000.0)
            return
        if use_rust_delta:
            # POC：只让 Rust 接管一次性呈现里的 BSP 增量小账本，普通步进先不扩范围。
            if not self._bsp_delta_collector_id:
                self._reset_rust_bsp_delta_collector()
            rust_t0 = time.perf_counter()
            rust_items = APP_PERF_ENGINE.collect_bsp_delta(
                self._bsp_delta_collector_id,
                snapshot,
                display_x=(int(display_x) if display_x is not None else None),
            )
            self._presentation_perf_inc("rust_collect_calls")
            self._presentation_perf_add("rust_collect_ms", (time.perf_counter() - rust_t0) * 1000.0)
            if rust_items is not None:
                for item in rust_items:
                    self.bsp_history.append(item)
                    key = str(item.get("key", ""))
                    if key:
                        self._mark_bsp_history_appended(key)
                self._presentation_perf_inc("rust_items", len(rust_items))
                self._presentation_perf_inc("bsp_append_calls")
                self._presentation_perf_add("bsp_append_ms", (time.perf_counter() - append_t0) * 1000.0)
                return
        existing_keys = self._bsp_history_seen_keys_current()
        python_added = 0
        for item in snapshot:
            key = self._bsp_key(item)
            if key in existing_keys:
                continue
            anchor_x = int(item["x"])
            shown_x = int(display_x) if display_x is not None else anchor_x
            self.bsp_history.append(
                {
                    "key": key,
                    "x": shown_x,
                    "anchor_x": anchor_x,
                    "is_buy": bool(item["is_buy"]),
                    "label": item["label"],
                    "level": item["level"],
                    "level_label": item["level_label"],
                    "display_label": item["display_label"],
                    "status": None,
                }
            )
            self._mark_bsp_history_appended(key)
            python_added += 1
        self._presentation_perf_inc("python_items", python_added)
        self._presentation_perf_inc("bsp_append_calls")
        self._presentation_perf_add("bsp_append_ms", (time.perf_counter() - append_t0) * 1000.0)

    def sync_bsp_history_light(self) -> None:
        """一次性呈现轻量同步：只收集当下新增 BSP。"""
        sync_t0 = time.perf_counter()
        self._presentation_perf_inc("bsp_sync_calls")
        try:
            self._sync_bsp_history_light_impl()
        finally:
            self._presentation_perf_add("bsp_sync_ms", (time.perf_counter() - sync_t0) * 1000.0)

    def _sync_bsp_history_light_impl(self) -> None:
        """一次性呈现轻量同步主体：外层只负责性能记账。"""
        current_x = self._current_kline_x()
        if current_x is None:
            return
        if self.get_active_stepper().data_feed_mode == "unified":
            self.sync_bsp_history()
            return
        # 不按 current_x 过滤：BSP 常在当前 step 才确认、锚点却落在更早 K。
        self._append_bsp_history_items(
            self._current_bsp_snapshot_incremental_light(current_x=None),
            display_x=current_x,
            use_rust_delta=False,
        )

    def sync_bsp_history_full_from_current_light(self) -> None:
        """逐K跑完后不做末态回填，避免未来组合标签污染历史。"""
        if self.get_active_stepper().data_feed_mode == "unified":
            self.sync_bsp_history()
            return
        # 逐K模式不做末态回填，避免把未来才出现的组合标签写回历史。
        return

    def sync_rhythm_history(self) -> None:
        current_x = self._current_kline_x()
        self._rhythm_notice_hits = []
        stepper = self.get_active_stepper()
        if current_x is None:
            return
        if stepper.data_feed_mode == "unified":
            source_hits = stepper.build_chart_payload_cached(include_kline_all=False).get("rhythm_hits", [])
        else:
            if stepper.chan is None:
                return
            source_hits = stepper.get_structure_bundle().rhythm_hits
        for item in source_hits:
            if int(item.get("x", -1)) != current_x:
                continue
            key = str(item.get("key") or "")
            if not key or key in self.rhythm_hit_keys:
                continue
            history_item = {
                "key": key,
                "x": int(item["x"]),
                "y": float(item["y"]),
                "level": str(item["level"]),
                "parent_level": str(item.get("parent_level", "")),
                "parent_key": str(item.get("parent_key", "")),
                "display_label": str(item.get("display_label", "")),
                "round_ref": int(item.get("round_ref", 0)),
                "detail": str(item.get("detail", "")),
                "time": str(item.get("time", stepper.current_time())),
            }
            self.rhythm_hit_history.append(history_item)
            self.rhythm_hit_keys.add(key)
            self._rhythm_notice_hits.append(
                {
                    "key": key,
                    "display_label": history_item["display_label"],
                    "detail": history_item["detail"],
                    "x": history_item["x"],
                    "time": history_item["time"],
                }
            )

    @staticmethod
    def _replay_bar_total_for_stepper(stepper: "ChanStepper") -> int:
        if (
            normalize_data_feed_mode(getattr(stepper, "data_feed_mode", "step")) == "unified"
            and getattr(stepper, "_unified_full_payload", None) is not None
        ):
            return len(stepper._unified_full_payload.get("kline") or [])
        master = getattr(stepper, "_replay_klus_master", None) or []
        return len(master) if isinstance(master, list) else 0

    def apply_kline_presentation_end(self) -> None:
        """一次性呈现：加载/重配后直接展示末根完整图表（跳过逐步浏览过程）。"""
        pres = normalize_kline_presentation_mode(
            (self.session_params or {}).get("kline_presentation_mode", "step")
        )
        if pres != "instant":
            return
        if normalize_data_feed_mode(getattr(self.stepper, "data_feed_mode", "step")) == "unified":
            self.stepper.ensure_unified_full_payload()
        total = self._replay_bar_total_for_stepper(self.stepper)
        if total <= 0:
            return
        last_idx = total - 1
        if normalize_data_feed_mode(getattr(self.stepper, "data_feed_mode", "step")) == "unified":
            self.stepper.unified_set_step_idx(last_idx)
            if self.chart_mode == "dual" and self.stepper2 is not None:
                self._sync_stepper_to_anchor(self.stepper2, self.stepper.current_time())
            elif self.chart_mode == "multi" and self.multi_steppers:
                self._sync_passives_to_anchor(self.stepper.current_time())
            self._dual_rebuild_coarse_chan_anti_future(self.stepper.current_time())
            self.sync_bsp_history()
            self.sync_rhythm_history()
            self.after_step_update()
            return
        # init 快路径：stepper 已就绪，直接步进至末根，避免 rebuild_to_step 重复 init
        self._advance_steppers_to_index(last_idx, report_progress=True)

    def _advance_steppers_to_index(self, target_step: int, *, report_progress: bool = False) -> None:
        """从当前步位推进到 target_step，不重建 stepper。"""
        total = self._replay_bar_total_for_stepper(self.stepper)
        if total <= 0:
            return
        target_step = max(0, min(int(target_step), total - 1))
        feed = normalize_data_feed_mode(getattr(self.stepper, "data_feed_mode", "step"))
        if report_progress and feed != "unified":
            self._reset_presentation_perf(target_step=target_step, total=total)
        if feed == "unified":
            self.stepper.unified_set_step_idx(target_step)
            if self.chart_mode == "dual" and self.stepper2 is not None:
                self._sync_stepper_to_anchor(self.stepper2, self.stepper.current_time())
            elif self.chart_mode == "multi" and self.multi_steppers:
                self._sync_passives_to_anchor(self.stepper.current_time())
            self._dual_rebuild_coarse_chan_anti_future(self.stepper.current_time())
            self.sync_bsp_history()
            self.sync_rhythm_history()
            self.after_step_update()
            return

        if self.stepper.step_idx < 0:
            _check_init_cancelled()
            prev_suppress_first = bool(getattr(self.stepper, "_suppress_step_bundle_refresh", False))
            if report_progress:
                self.stepper._suppress_step_bundle_refresh = True
            try:
                step_t0 = time.perf_counter()
                step_ok = self.stepper.step()
                if report_progress:
                    self._presentation_perf_inc("step_calls")
                    self._presentation_perf_add("step_ms", (time.perf_counter() - step_t0) * 1000.0)
                    if step_ok:
                        self._presentation_perf_inc("loop_steps")
                if not step_ok:
                    return
            finally:
                if report_progress:
                    self.stepper._suppress_step_bundle_refresh = prev_suppress_first
            dual_t0 = time.perf_counter()
            if self.chart_mode == "dual" and self.stepper2 is not None:
                self.stepper2.step()
                self._sync_stepper_to_anchor(self.stepper2, self.stepper.current_time())
            elif self.chart_mode == "multi" and self.multi_steppers:
                self._sync_passives_to_anchor(self.stepper.current_time())
            if report_progress:
                self._presentation_perf_add("dual_sync_ms", (time.perf_counter() - dual_t0) * 1000.0)
            if report_progress:
                self.sync_bsp_history_light()
            else:
                self.sync_bsp_history()
                self.sync_rhythm_history()
                self.after_step_update()

        current = max(0, int(self.stepper.step_idx))
        if current >= target_step:
            coarse_t0 = time.perf_counter()
            self._dual_rebuild_coarse_chan_anti_future(self.get_active_stepper().current_time())
            if report_progress:
                self._presentation_perf_add("coarse_rebuild_ms", (time.perf_counter() - coarse_t0) * 1000.0)
                self._finish_presentation_perf()
            return

        span = max(1, target_step - current)
        if report_progress:
            for line in rust_presentation_begin_lines(self.stepper):
                push_record_trace(line)
            push_record_trace("一次性呈现：按逐K步进跑到末根…")
        total_count = target_step + 1
        progress_unit = max(1, total_count // 5)
        prev_suppress = bool(getattr(self.stepper, "_suppress_step_bundle_refresh", False))
        if report_progress:
            self.stepper._suppress_step_bundle_refresh = True
        try:
            for i in range(current, target_step):
                _check_init_cancelled()
                step_no = i + 1
                should_report = (
                    report_progress
                    and (
                        i == current
                        or step_no % progress_unit == 0
                        or i == target_step - 1
                    )
                )
                if should_report:
                    progress_t0 = time.perf_counter()
                    pct = 85 + int(13 * (i - current + 1) / span)
                    _init_status_set_subprogress(
                        min(98, pct),
                        f"一次性呈现：逐K步进 {step_no}/{total_count}",
                        push_trace=True,
                    )
                    self._presentation_perf_add("progress_ms", (time.perf_counter() - progress_t0) * 1000.0)
                step_t0 = time.perf_counter()
                step_ok = self.stepper.step()
                self._presentation_perf_inc("step_calls")
                self._presentation_perf_add("step_ms", (time.perf_counter() - step_t0) * 1000.0)
                if step_ok:
                    self._presentation_perf_inc("loop_steps")
                if not step_ok:
                    break
                dual_t0 = time.perf_counter()
                if self.chart_mode == "dual" and self.stepper2 is not None:
                    self._sync_stepper_to_anchor(self.stepper2, self.stepper.current_time())
                elif self.chart_mode == "multi" and self.multi_steppers:
                    self._sync_passives_to_anchor(self.stepper.current_time())
                self._presentation_perf_add("dual_sync_ms", (time.perf_counter() - dual_t0) * 1000.0)
                if report_progress:
                    self.sync_bsp_history_light()
                else:
                    self.sync_bsp_history()
                    self.sync_rhythm_history()
                    self.after_step_update()
        finally:
            if report_progress:
                self.stepper._suppress_step_bundle_refresh = prev_suppress

        if report_progress:
            final_t0 = time.perf_counter()
            self.sync_bsp_history_full_from_current_light()
            self._presentation_perf_add("final_sync_ms", (time.perf_counter() - final_t0) * 1000.0)
            progress_t0 = time.perf_counter()
            _init_status_set_subprogress(
                98,
                f"一次性呈现：逐K步进 {total_count}/{total_count}",
                push_trace=True,
            )
            self._presentation_perf_add("progress_ms", (time.perf_counter() - progress_t0) * 1000.0)
        coarse_t0 = time.perf_counter()
        self._dual_rebuild_coarse_chan_anti_future(self.get_active_stepper().current_time())
        if report_progress:
            self._presentation_perf_add("coarse_rebuild_ms", (time.perf_counter() - coarse_t0) * 1000.0)
            if getattr(self.stepper, "_rust_chan_primary_used", False):
                self._presentation_perf_add("rust_chan_primary_used", 1)
                sync_t0 = time.perf_counter()
                self.stepper.bulk_present_to_step(int(self.stepper.step_idx))
                self.stepper._rust_chan_primary_used = False
                self._presentation_perf_add("final_sync_ms", (time.perf_counter() - sync_t0) * 1000.0)
            self._finish_presentation_perf()

    def rebuild_to_step(self, target_step: int) -> None:
        if self.session_params is None:
            raise ValueError("当前无可重建会话")
        params = self.session_params
        APP_PERF_ENGINE.requested_mode = str(params.get("performance_engine_mode", "rust_auto") or "rust_auto")
        self._set_rollback_config(
            cache_depth=params.get("rollback_cache_depth"),
            full_snapshot_interval=params.get("rollback_full_snapshot_interval"),
            capture_max_bars=params.get("rollback_capture_max_bars"),
        )
        self._clear_rollback_cache()

        # 重建也固定走 a_Data；不复用历史缓存。
        self.stepper.init(
            params["code"],
            params["begin_date"],
            params["end_date"],
            params["autype"],
            chan_config=params.get("chan_config"),
            k_type=params.get("k_type", "daily"),  # 重建时保留周期类型
            confirm_offline=bool(params.get("confirm_offline", False)),
            data_source_priority=params.get("data_source_priority"),
            data_form_mode=params.get("data_form_mode", "traditional"),
            data_form_quantity=params.get("data_form_quantity"),
            data_form_quantity_alloc=params.get("data_form_quantity_alloc", "front"),
            data_feed_mode=params.get("data_feed_mode", "step"),
            offline_data_custom=params.get("offline_data_custom", "native"),
            chan_record_enabled=False,
            chart_lazy_layers=params.get("chart_lazy_layers"),
        )
        cm = normalize_replay_chart_mode(params.get("chart_mode", "single"))
        off_custom = normalize_offline_data_custom(params.get("offline_data_custom", "native"))
        self.multi_steppers = []
        qty_alloc = params.get("data_form_quantity_alloc", "front")
        rec_en = False
        if cm == "dual":
            self.chart_mode = "dual"
            self.stepper2 = ChanStepper()
            self.stepper2.init(
                params["code"],
                params["begin_date"],
                params["end_date"],
                params["autype"],
                chan_config=params.get("chan_config"),
                k_type=params.get("k_type_2") or params.get("k_type", "daily"),
                confirm_offline=bool(params.get("confirm_offline", False)),
                data_source_priority=params.get("data_source_priority"),
                data_form_mode=params.get("data_form_mode", "traditional"),
                data_form_quantity=params.get("data_form_quantity"),
                data_form_quantity_alloc=qty_alloc,
                data_feed_mode=params.get("data_feed_mode", "step"),
                offline_data_custom=off_custom,
                chan_record_enabled=rec_en,
                chart_lazy_layers=params.get("chart_lazy_layers"),
            )
        elif cm == "multi":
            self.chart_mode = "multi"
            self.stepper2 = None
            ktm = params.get("k_types_multi") or []
            _, passives = resolve_multi_k_types_from_request(ktm)
            for pk in passives:
                st = ChanStepper()
                st.init(
                    params["code"],
                    params["begin_date"],
                    params["end_date"],
                    params["autype"],
                    chan_config=params.get("chan_config"),
                    k_type=pk,
                    confirm_offline=bool(params.get("confirm_offline", False)),
                    data_source_priority=params.get("data_source_priority"),
                    data_form_mode=params.get("data_form_mode", "traditional"),
                    data_form_quantity=params.get("data_form_quantity"),
                    data_form_quantity_alloc=qty_alloc,
                    data_feed_mode=params.get("data_feed_mode", "step"),
                    offline_data_custom=off_custom,
                    chan_record_enabled=rec_en,
                    chart_lazy_layers=params.get("chart_lazy_layers"),
                )
                self.multi_steppers.append(st)
        else:
            self.chart_mode = "single"
            self.stepper2 = None

        # Account reset is handled by the caller if needed (e.g. in reconfig)
        # but for back_n it should stay consistent with history.
        # However, rebuild_to_step is also used by back_n which needs to replay trades.
        self.ready = True
        self.finished = False
        self.bsp_history = []
        self._reset_bsp_incremental_cache()
        self._reset_rhythm_history()
        self._last_level_dirs = {level: None for level in set(JUDGE_TRIGGER_LEVELS.values())}
        self._reset_judge_state()
        self.rebuild_bsp_all_snapshot()

        total = self._replay_bar_total_for_stepper(self.stepper)
        if total <= 0:
            return
        target_step = max(0, min(int(target_step), total - 1))

        # 统一喂数据：切片游标直接定位，避免按步循环；修改数量后须钳制到新区间末根
        if normalize_data_feed_mode(getattr(self.stepper, "data_feed_mode", "step")) == "unified":
            self.stepper.unified_set_step_idx(target_step)
            if self.chart_mode == "dual" and self.stepper2 is not None:
                self._sync_stepper_to_anchor(self.stepper2, self.stepper.current_time())
            elif self.chart_mode == "multi" and self.multi_steppers:
                self._sync_passives_to_anchor(self.stepper.current_time())
            self._dual_rebuild_coarse_chan_anti_future(self.stepper.current_time())
            self.sync_bsp_history()
            self.sync_rhythm_history()
            self.after_step_update()
        else:
            if not self.stepper.step():
                return
            if self.chart_mode == "dual" and self.stepper2 is not None:
                self.stepper2.step()
                self._sync_stepper_to_anchor(self.stepper2, self.stepper.current_time())
            elif self.chart_mode == "multi" and self.multi_steppers:
                self._sync_passives_to_anchor(self.stepper.current_time())
            self.sync_bsp_history()
            self.sync_rhythm_history()
            self.after_step_update()
            for _ in range(target_step):
                if not self.stepper.step():
                    break
                if self.chart_mode == "dual" and self.stepper2 is not None:
                    self._sync_stepper_to_anchor(self.stepper2, self.stepper.current_time())
                elif self.chart_mode == "multi" and self.multi_steppers:
                    self._sync_passives_to_anchor(self.stepper.current_time())
                self.sync_bsp_history()
                self.sync_rhythm_history()
                self.after_step_update()

            self._dual_rebuild_coarse_chan_anti_future(self.get_active_stepper().current_time())

        effective_step = max(0, self.stepper.step_idx)
        self.trade_events = [e for e in self.trade_events if int(e.get("step_idx", -1)) <= effective_step]
        self.account.reset(params["initial_cash"])
        for event in self.trade_events:
            side = event.get("side")
            price = float(event.get("price", 0.0))
            step_idx = int(event.get("step_idx", -1))
            try:
                if side == "buy":
                    self.account.buy_with_all_cash(price, step_idx)
                elif side == "sell":
                    self.account.sell_all(price, step_idx)
                elif side == "short":
                    self.account.short_with_all_cash(price, step_idx)
                elif side == "cover":
                    self.account.cover_all(price, step_idx)
            except Exception:
                # Replay might fail if parameters changed drastically, but we try our best
                pass

    def reconfig(
        self,
        chan_config: dict[str, Any],
        *,
        data_form_mode: Optional[str] = None,
        data_form_quantity: Optional[int] = None,
        data_form_quantity_alloc: Optional[str] = None,
        offline_data_custom: Optional[str] = None,
        data_feed_mode: Optional[str] = None,
        kline_presentation_mode: Optional[str] = None,
        rollback_cache_depth: Optional[int] = None,
        rollback_full_snapshot_interval: Optional[int] = None,
        rollback_capture_max_bars: Optional[int] = None,
        performance_engine_mode: Optional[str] = None,
        chip_bucket_step: Optional[float] = None,
        chart_lazy_layers: Optional[dict[str, Any]] = None,
    ) -> None:
        if self.session_params is None:
            raise ValueError("当前无可重配会话")
        
        # 1. Update session params
        self.session_params["chan_config"] = chan_config
        if data_form_mode is not None:
            self.session_params["data_form_mode"] = normalize_data_form_mode(data_form_mode)
        if data_form_quantity is not None:
            self.session_params["data_form_quantity"] = int(data_form_quantity)
        if data_form_quantity_alloc is not None:
            self.session_params["data_form_quantity_alloc"] = normalize_data_form_quantity_alloc(
                data_form_quantity_alloc
            )
        if offline_data_custom is not None:
            self.session_params["offline_data_custom"] = normalize_offline_data_custom(offline_data_custom)
        if data_feed_mode is not None:
            self.session_params["data_feed_mode"] = normalize_data_feed_mode(data_feed_mode)
        if kline_presentation_mode is not None:
            self.session_params["kline_presentation_mode"] = normalize_kline_presentation_mode(
                kline_presentation_mode
            )
        if rollback_cache_depth is not None:
            self.session_params["rollback_cache_depth"] = int(rollback_cache_depth)
        if rollback_full_snapshot_interval is not None:
            self.session_params["rollback_full_snapshot_interval"] = int(rollback_full_snapshot_interval)
        if rollback_capture_max_bars is not None:
            self.session_params["rollback_capture_max_bars"] = int(rollback_capture_max_bars)
        if performance_engine_mode is not None:
            self.session_params["performance_engine_mode"] = str(performance_engine_mode or "rust_auto")
            APP_PERF_ENGINE.requested_mode = self.session_params["performance_engine_mode"]
        if chip_bucket_step is not None:
            self.session_params["chip_bucket_step"] = float(chip_bucket_step)
        if chart_lazy_layers is not None:
            self.session_params["chart_lazy_layers"] = normalize_chart_lazy_layers(chart_lazy_layers)
        self._set_rollback_config(
            cache_depth=rollback_cache_depth,
            full_snapshot_interval=rollback_full_snapshot_interval,
            capture_max_bars=rollback_capture_max_bars,
        )
        
        # 2. Clear simulation data (trades and account)
        self.trade_events = []
        self.account.reset(self.session_params["initial_cash"])
        
        # 3. 重建：改数量/形式/喂入方式后展示全部聚合 K 线（末根）；仅改缠论配置时保持步位
        pres = normalize_kline_presentation_mode(
            self.session_params.get("kline_presentation_mode", "step")
        )
        data_form_changed = any(
            x is not None
            for x in (
                data_form_mode,
                data_form_quantity,
                data_form_quantity_alloc,
                offline_data_custom,
                data_feed_mode,
            )
        )
        if data_form_changed or pres == "instant":
            # 重建后钳制到末根（rebuild_to_step 内按新 total 处理）
            target_step = 10**9
        else:
            target_step = self.stepper.step_idx
        self.rebuild_to_step(target_step)

    def build_payload(self, stock_name: Optional[str] = None, *, include_kline_all: bool = True) -> dict[str, Any]:
        if not self.ready or self.stepper.chan is None:
            return {
                "ready": False,
                "finished": self.finished,
                "payload_version": 2,
                "engine_mode": APP_PERF_ENGINE.cache_status().get("engine_mode", "rust-missing"),
                "step_delta": None,
                "chip_profile": None,
                "cache_info": APP_PERF_ENGINE.cache_status(),
                "legacy_chart": None,
                "message": "请先加载会话",
            }
        rhythm_notice_hits = list(self._rhythm_notice_hits)
        self._rhythm_notice_hits = []

        chart = self.stepper.build_chart_payload_cached(include_kline_all=include_kline_all)
        chart2: Optional[dict[str, Any]] = None
        if self.chart_mode == "dual" and self.stepper2 is not None and self.stepper2.chan is not None:
            chart2 = self.stepper2.build_chart_payload_cached(include_kline_all=include_kline_all)

        active_stepper = self.get_active_stepper()
        anchor_time = active_stepper.current_time()
        # 还可向前步进根数：须与 ChanStepper.step() 一致（unified 以 _unified_full_payload.kline 根数为准，避免与 _replay_klus_master 长度不一致时误判）
        if (
            normalize_data_feed_mode(getattr(active_stepper, "data_feed_mode", "step")) == "unified"
            and getattr(active_stepper, "_unified_full_payload", None) is not None
        ):
            ukl = active_stepper._unified_full_payload.get("kline") or []
            _total = len(ukl)
        else:
            _master = getattr(active_stepper, "_replay_klus_master", None) or []
            _total = len(_master) if isinstance(_master, list) else 0
        _si = int(getattr(active_stepper, "step_idx", -1) or -1)
        step_forward_max = max(0, _total - 1 - _si) if _total > 0 else 0
        if chart2 is not None:
            # 展示层也按同一套粗细/raw感知逻辑裁剪，避免数量模式分组把未来数据带回末根显示。
            pair = self._resolve_dual_coarse_fine()
            if pair is not None:
                coarse, fine = pair
                if coarse is self.stepper:
                    chart = copy.deepcopy(chart)
                    self._apply_partial_last_bar(chart, coarse, fine, anchor_time)
                else:
                    chart2 = copy.deepcopy(chart2)
                    self._apply_partial_last_bar(chart2, coarse, fine, anchor_time)
        chart_layers: Optional[list[dict[str, Any]]] = None
        chip_basis: Optional[str] = None
        if is_data_form_tick_synth_mode(self.stepper.data_form_mode):
            chip_basis = "tick_accum_driver"
        elif normalize_replay_chart_mode(self.chart_mode) == "multi" and self.multi_steppers:
            chip_basis = "tick_accum_driver" if self.stepper.data_src_used == OFFLINE_INLINE_SRC else None
            dk = chart.get("kline") or []
            chart_layers = []
            for st in sorted(self.multi_steppers, key=lambda s: -kl_granularity_rank(s.k_type)):
                if st.chan is None:
                    continue
                ch_ov = st.build_chart_payload_cached(include_kline_all=False)
                ch_ov = copy.deepcopy(ch_ov)
                self._apply_partial_last_bar(ch_ov, st, self.stepper, anchor_time)
                ch_mapped = remap_overlay_chart_to_driver_x(
                    ch_ov, coarse_kline=list(ch_ov.get("kline") or []), driver_kline=list(dk)
                )
                chart_layers.append(
                    {"k_type": k_type_to_api_key(st.k_type), "role": "overlay", "chart": ch_mapped}
                )
            chart_layers.append(
                {"k_type": k_type_to_api_key(self.stepper.k_type), "role": "driver", "chart": chart}
            )
        price: Optional[float] = None
        active_chart = chart2 if (self._normalize_chart_id(self.active_chart_id) == "chart2" and chart2 is not None) else chart
        if len(active_chart.get("kline", [])) > 0:
            price = active_stepper.current_price()
        perf_step_delta: Optional[dict[str, Any]] = None
        perf_chip_profile: Optional[dict[str, Any]] = None
        perf_cache_info: dict[str, Any] = APP_PERF_ENGINE.cache_status()
        perf_mode = getattr(active_stepper, "perf_engine_mode", perf_cache_info.get("engine_mode", "rust-missing"))
        if getattr(active_stepper, "perf_session_id", None) and str(APP_PERF_ENGINE.requested_mode) != "python_legacy":
            perf_step_delta = APP_PERF_ENGINE.next_step_delta(
                active_stepper.perf_session_id,
                int(active_stepper.step_idx) - 1,
                int(active_stepper.step_idx),
            )
            ks_for_chip = active_chart.get("kline", []) or []
            cutoff_x = int(ks_for_chip[-1].get("x")) if ks_for_chip else None
            bucket_step = float((self.session_params or {}).get("chip_bucket_step") or 0.1)
            perf_chip_profile = APP_PERF_ENGINE.chip_profile(
                active_stepper.perf_session_id,
                cutoff_x=cutoff_x,
                bucket_step=bucket_step,
            )
        charts_payload = {"chart1": chart}
        if chart2 is not None:
            charts_payload["chart2"] = chart2
        src_per_chart: dict[str, Any] = {
            "chart1": {
                "k_type": k_type_to_api_key(self.stepper.k_type),
                "kline_label": data_source_label(self.stepper.data_src_used),
                "chip_label": data_source_label(getattr(self.stepper, "data_src_chip_used", None) or self.stepper.data_src_used),
            }
        }
        if self.stepper2 is not None:
            src_per_chart["chart2"] = {
                "k_type": k_type_to_api_key(self.stepper2.k_type),
                "kline_label": data_source_label(self.stepper2.data_src_used),
                "chip_label": data_source_label(getattr(self.stepper2, "data_src_chip_used", None) or self.stepper2.data_src_used),
            }
        result = {
            "ready": True,
            "finished": self.finished,
            "payload_version": 2,
            "engine_mode": perf_mode,
            "step_delta": perf_step_delta,
            "chip_profile": perf_chip_profile,
            "cache_info": perf_cache_info,
            "legacy_chart": {"field": "chart", "note": "旧前端继续读取 chart 字段，避免重复下发完整图表。"},
            "code": self.stepper.code,
            "name": stock_name,
            "src_per_chart": src_per_chart,
            "data_source": {
                "label": data_source_label(self.stepper.data_src_used),
                "chip_label": data_source_label(getattr(self.stepper, "data_src_chip_used", None) or self.stepper.data_src_used),
                "logs": list(self.stepper.data_src_logs),
            },
            "chan_algo": self.stepper.chan_algo,
            "step_idx": active_stepper.step_idx,
            "step_forward_max": int(step_forward_max),
            "replay_bar_total": int(_total),
            "rollback_config": {
                "cache_depth": int(self._rollback_max),
                "full_snapshot_interval": int(self._rollback_full_snapshot_interval),
                "capture_max_bars": int(self._rollback_capture_max_bars),
                "light_count": int(len(self._rollback_light)),
                "full_count": int(len(self._rollback_full)),
            },
            "time": active_stepper.current_time(),
            "price": price,
            "chart": chart,
            "charts": charts_payload,
            "chart_layers": chart_layers,
            "chart_lazy_layers": normalize_chart_lazy_layers((self.session_params or {}).get("chart_lazy_layers")),
            "chip_basis": chip_basis,
            "k_types_multi": (self.session_params or {}).get("k_types_multi"),
            "chart_mode": self.chart_mode,
            "active_chart_id": self._normalize_chart_id(self.active_chart_id),
            "time_anchor": anchor_time,
            "data_form": {
                "mode": self.stepper.data_form_mode,
                "quantity": int(self.stepper.data_form_quantity or 0),
                "quantity_alloc": normalize_data_form_quantity_alloc(
                    getattr(self.stepper, "data_form_quantity_alloc", "front")
                ),
                "feed_mode": normalize_data_feed_mode(getattr(self.stepper, "data_feed_mode", "step")),
                "offline_data_custom": normalize_offline_data_custom(
                    getattr(self.stepper, "offline_data_custom", "native")
                ),
                "presentation_mode": normalize_kline_presentation_mode(
                    (self.session_params or {}).get("kline_presentation_mode", "step")
                ),
                "raw_count": int(self.stepper.raw_kline_count or 0),
                # 聚合后的总根数（非 unified 切片后的可见根数）
                "current_count": int(_total),
            },
            "bsp_history": self.bsp_history,
            "rhythm_notice_hits": rhythm_notice_hits,
            "judge_notice": bool(self._judge_notice),
            "judge_stats": self._last_judge_stats,
            "account": {
                "initial_cash": round(self.account.initial_cash, 2),
                "cash": round(self.account.cash, 2),
                "position": self.account.position,
                "avg_cost": round(self.account.avg_cost, 4),
                "equity": round(self.account.equity(price or 0.0), 2),
                "can_sell": bool(
                    normalize_data_feed_mode(getattr(self.stepper, "data_feed_mode", "step")) == "step"
                    and price is not None
                    and self.account.can_sell(self.stepper.step_idx)
                ),
                "can_cover": bool(
                    normalize_data_feed_mode(getattr(self.stepper, "data_feed_mode", "step")) == "step"
                    and price is not None
                    and self.account.can_cover(self.stepper.step_idx)
                ),
            },
            "trades": self._build_trade_state(),
        }
        trace = drain_record_trace()
        if trace:
            result["record_trace"] = trace
        return result

    def load_chart_layers(self, layers: dict[str, Any]) -> dict[str, Any]:
        """会话后按需补算图层，并返回最新图表包。"""
        wanted = normalize_chart_lazy_layers(layers, default_enabled=False)
        for st in [self.stepper, self.stepper2, *(self.multi_steppers or [])]:
            if st is None:
                continue
            st.chart_lazy_layers = merge_chart_lazy_layers(getattr(st, "chart_lazy_layers", None), wanted)
            st.clear_structure_runtime_cache(clear_bsp_cache=True)
            st.rebuild_unified_full_payload_for_layers()
        self._reset_bsp_incremental_cache()
        if self.session_params is not None:
            self.session_params["chart_lazy_layers"] = merge_chart_lazy_layers(
                self.session_params.get("chart_lazy_layers"), wanted
            )
        with init_perf_stage("chart_lazy_layers"):
            return self.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)


# ---------------------------------------------------------------------------
# 双周期防未来：被动同步 + 粗末根按细K重算（与 AppState 原实现一致，供回测与复盘共用）
# ---------------------------------------------------------------------------


def bt_parse_time_safe(ts: str) -> Optional[datetime]:
    s = str(ts or "").strip()
    if not s:
        return None
    fmts = ("%Y/%m/%d", "%Y/%m/%d %H:%M", "%Y/%m/%d %H:%M:%S")
    for fmt in fmts:
        try:
            return datetime.strptime(s, fmt)
        except Exception:
            continue
    return None


def bt_anchor_compare_effective_dt(stepper: ChanStepper, time_str: str) -> Optional[datetime]:
    dt = bt_parse_time_safe(time_str)
    if dt is None:
        return None
    if AppState._k_type_granularity_rank(stepper.k_type) < AppState._k_type_granularity_rank(KL_TYPE.K_DAY):
        return dt
    s = str(time_str or "").strip()
    if " " in s:
        return dt
    if dt.hour == 0 and dt.minute == 0 and dt.second == 0:
        return dt.replace(hour=23, minute=59, second=59, microsecond=0)
    return dt


def bt_klu_to_datetime(klu: Any) -> Optional[datetime]:
    try:
        return bt_parse_time_safe(klu.time.to_str())
    except Exception:
        return None


def bt_count_stepper_klus(stepper: ChanStepper) -> int:
    if stepper.chan is None or len(stepper.chan[0].lst) == 0:
        return 0
    return len(list(stepper.chan[0].klu_iter()))


def bt_resolve_dual_coarse_fine(chart_mode: str, s1: ChanStepper, s2: Optional[ChanStepper]) -> Optional[tuple[ChanStepper, ChanStepper]]:
    if str(chart_mode or "single").lower() != "dual" or s2 is None:
        return None
    r1 = kl_granularity_rank(s1.k_type)
    r2 = kl_granularity_rank(s2.k_type)
    if r1 != r2:
        return (s1, s2) if r1 > r2 else (s2, s1)
    n1 = bt_count_stepper_klus(s1)
    n2 = bt_count_stepper_klus(s2)
    if n1 <= 0 or n2 <= 0 or n1 == n2:
        return None
    return (s1, s2) if n1 < n2 else (s2, s1)


def bt_collect_fine_klus_for_coarse_tail(coarse: ChanStepper, fine: ChanStepper, anchor_time: str) -> list[Any]:
    t_anchor = bt_parse_time_safe(anchor_time)
    if t_anchor is None or coarse.chan is None or len(coarse.chan[0].lst) == 0:
        return []
    klus_c = list(coarse.chan[0].klu_iter())
    if not klus_c:
        return []
    t_prev = bt_klu_to_datetime(klus_c[-2]) if len(klus_c) >= 2 else None
    use_raw = (
        is_data_form_quantity_mode(getattr(fine, "data_form_mode", "traditional"))
        and fine._replay_klus_master_raw
        and len(fine._replay_klus_master_raw) <= 100_000
    )
    if use_raw:
        source_iter = list(fine._replay_klus_master_raw)
    elif fine.chan is not None and len(fine.chan[0].lst) > 0:
        source_iter = list(fine.chan[0].klu_iter())
    else:
        source_iter = []
    picked: list[Any] = []
    for klu in source_iter:
        t = bt_klu_to_datetime(klu)
        if t is None:
            continue
        if t > t_anchor:
            continue
        if t_prev is not None and t <= t_prev:
            continue
        picked.append(klu)
    picked.sort(key=lambda k: float(getattr(getattr(k, "time", None), "ts", 0.0)))
    return picked


def bt_sync_stepper_to_anchor(stepper: ChanStepper, anchor_time: str) -> None:
    t_anchor = bt_parse_time_safe(anchor_time)
    if t_anchor is None or stepper.chan is None:
        return
    prev_step = int(stepper.step_idx)
    while True:
        cur_t = bt_anchor_compare_effective_dt(stepper, stepper.current_time())
        if cur_t is None:
            break
        if cur_t >= t_anchor:
            break
        if not stepper.step():
            break
    if int(stepper.step_idx) != prev_step:
        stepper.clear_structure_runtime_cache()


def bt_rebuild_coarse_anti_future_vs_fine(
    session_params: dict[str, Any],
    coarse: ChanStepper,
    fine: ChanStepper,
    anchor_time: str,
) -> None:
    """粗周期末根按细周期截至锚点重算并重建 coarse.chan（防未来）。"""
    if getattr(coarse, "data_feed_mode", "step") == "unified" or getattr(fine, "data_feed_mode", "step") == "unified":
        return
    if not session_params:
        return
    if kl_granularity_rank(coarse.k_type) <= kl_granularity_rank(fine.k_type):
        return
    saved = int(coarse.step_idx)
    if saved < 0:
        return
    master_full = coarse._replay_klus_master
    if not master_full or saved >= len(master_full):
        return
    picked = bt_collect_fine_klus_for_coarse_tail(coarse, fine, anchor_time)
    if not picked:
        return
    last_orig = master_full[saved]
    o0 = float(last_orig.open)
    h = max(float(k.high) for k in picked)
    l = min(float(k.low) for k in picked)
    c = float(picked[-1].close)
    l = min(o0, h, l, c)
    h = max(o0, h, l, c)
    v = sum(_klu_float_trade_metric(k, DATA_FIELD.FIELD_VOLUME) for k in picked)
    turnover = 0.0
    for k in picked:
        ti = getattr(k, "trade_info", None)
        if ti and getattr(ti, "metric", None):
            tv = ti.metric.get(DATA_FIELD.FIELD_TURNOVER)
            if tv is not None:
                turnover += float(tv or 0.0)
    patch_dict: dict[str, Any] = {
        DATA_FIELD.FIELD_TIME: last_orig.time,
        DATA_FIELD.FIELD_OPEN: o0,
        DATA_FIELD.FIELD_HIGH: h,
        DATA_FIELD.FIELD_LOW: l,
        DATA_FIELD.FIELD_CLOSE: c,
        DATA_FIELD.FIELD_VOLUME: v,
    }
    if turnover > 0:
        patch_dict[DATA_FIELD.FIELD_TURNOVER] = turnover
    patched = CKLine_Unit(patch_dict)
    patched.macd = None
    patched.boll = None
    new_master = copy.deepcopy(list(master_full))
    new_master[saved] = patched
    params = session_params
    cfg = CChanConfig(coarse._cfg_without_chan_algo(dict(coarse.effective_cfg_dict or {})))
    coarse.chan = ReplayChan(
        code=coarse.code,
        begin_time=params["begin_date"],
        end_time=params.get("end_date"),
        data_src=coarse.data_src_used or DATA_SRC.AKSHARE,
        lv_list=[coarse.k_type],
        config=cfg,
        autype=params["autype"],
        replay_klus_master=new_master,
    )
    coarse._iter = coarse.chan.step_load()
    coarse.indicators = {
        "macd": CMACD(),
        "kdj": KDJ(),
        "rsi": RSI(),
        "boll": BollModel(),
        "demark": CDemarkEngine(),
    }
    coarse.indicator_history = []
    coarse.clear_structure_runtime_cache(clear_bsp_cache=True)
    coarse.step_idx = -1
    coarse.trend_lines = []
    for _ in range(saved + 1):
        if not coarse.step():
            break


def bt_multi_rebuild_coarse_chan_anti_future(
    session_params: dict[str, Any],
    driver: ChanStepper,
    passive_steppers: list[ChanStepper],
    anchor_time: str,
) -> None:
    """多周期：每个粗于 driver 的周期分别做末根 patch + chan 重建。"""
    if getattr(driver, "data_feed_mode", "step") == "unified":
        return
    if any(getattr(s, "data_feed_mode", "step") == "unified" for s in passive_steppers):
        return
    for coarse in passive_steppers:
        bt_rebuild_coarse_anti_future_vs_fine(session_params, coarse, driver, anchor_time)


def bt_dual_rebuild_coarse_chan_anti_future(
    session_params: dict[str, Any],
    chart_mode: str,
    stepper: ChanStepper,
    stepper2: Optional[ChanStepper],
    anchor_time: str,
) -> None:
    if getattr(stepper, "data_feed_mode", "step") == "unified" or (
        stepper2 is not None and getattr(stepper2, "data_feed_mode", "step") == "unified"
    ):
        return
    pair = bt_resolve_dual_coarse_fine(chart_mode, stepper, stepper2)
    if pair is None:
        return
    coarse, fine = pair
    bt_rebuild_coarse_anti_future_vs_fine(session_params, coarse, fine, anchor_time)


def _bt_bsp_key_set(stepper: ChanStepper) -> set[str]:
    if stepper.chan is None:
        return set()
    bundle = stepper.get_structure_bundle()
    keys: set[str] = set()
    for level in bsp_levels_from_layers(getattr(stepper, "chart_lazy_layers", None)):
        bsp_list = get_bundle_bsp_list(bundle, level)
        for bsp in bsp_list.bsp_iter():
            item = make_bsp_item(level, bsp)
            keys.add(ChanStepper._bsp_key(item))
    return keys


def _bt_stepper_for_chart(sim: AppState, chart: str) -> Optional[ChanStepper]:
    c = str(chart or "k1").lower().strip()
    if c in ("k2", "chart2", "2"):
        return sim.stepper2
    return sim.stepper


def _pick_driver_for_indicator_bt(sim: AppState, step_driver: str) -> tuple[ChanStepper, Optional[ChanStepper]]:
    sd = str(step_driver or "auto").lower().strip()
    if str(sim.chart_mode or "single").lower() != "dual" or sim.stepper2 is None:
        return sim.stepper, None
    if sd == "k1":
        return sim.stepper, sim.stepper2
    if sd == "k2":
        return sim.stepper2, sim.stepper
    r1 = AppState._k_type_granularity_rank(sim.stepper.k_type)
    r2 = AppState._k_type_granularity_rank(sim.stepper2.k_type)
    if r1 < r2:
        return sim.stepper, sim.stepper2
    if r2 < r1:
        return sim.stepper2, sim.stepper
    return sim.stepper, sim.stepper2


def _normalize_indicator_backtest_req(req: IndicatorBacktestReq) -> tuple[list[dict[str, Any]], str, list[dict[str, Any]], str, Optional[int]]:
    entry = [c for c in (req.entry_conditions or []) if isinstance(c, dict)]
    if not entry and req.conditions:
        entry = [c for c in req.conditions if isinstance(c, dict)]
    exit_c = [c for c in (req.exit_conditions or []) if isinstance(c, dict)]
    ent_comb = str(req.entry_combine or req.combine_mode or "and").strip().lower()
    ex_comb = str(req.exit_combine or "and").strip().lower()
    hold = req.exit_hold_bars
    if hold is None and req.sell_hold_bars is not None:
        hold = int(req.sell_hold_bars)
    if not exit_c and hold is None:
        hold = 5
    return entry, ent_comb, exit_c, ex_comb, hold


def _combine_cond_flags(flags: list[bool], use_or: bool) -> bool:
    if not flags:
        return False
    return any(flags) if use_or else all(flags)


def _eval_indicator_condition(
    cond: dict[str, Any],
    sim: AppState,
    bsp_ctx: dict[str, set[str]],
) -> bool:
    """BSP 类条件仅在本步新增的 key 集合上成立（与上一步快照 diff），避免历史买卖点重复触发。"""
    st = _bt_stepper_for_chart(sim, str(cond.get("chart", "k1")))
    if st is None or st.chan is None:
        return False
    kl_list = st.chan[0]
    if len(kl_list.lst) == 0:
        return False
    hist = st.indicator_history
    if len(hist) < 1:
        return False
    kind = str(cond.get("kind", "")).strip().lower()
    last = hist[-1]
    prev = hist[-2] if len(hist) >= 2 else None

    def last_klu_idx() -> Optional[int]:
        try:
            return int(kl_list.lst[-1].lst[-1].idx)
        except Exception:
            return None

    def new_bsp_keys_for_stepper() -> set[str]:
        if st is sim.stepper:
            return set(bsp_ctx.get("new_k1") or ())
        if st is sim.stepper2:
            return set(bsp_ctx.get("new_k2") or ())
        return set()

    if kind == "boll_lower_reclaim":
        if prev is None:
            return False
        klus = list(kl_list.klu_iter())
        if len(klus) < 2:
            return False
        h_prev = float(klus[-2].high)
        down_prev = float(prev.get("boll", {}).get("down", 0.0))
        c_now = float(klus[-1].close)
        down_now = float(last.get("boll", {}).get("down", 0.0))
        return h_prev < down_prev and c_now >= down_now

    if kind == "close_ge_boll_down":
        c_now = float(kl_list.lst[-1].lst[-1].close)
        return c_now >= float(last.get("boll", {}).get("down", c_now))

    if kind == "cross_up_boll_mid":
        if prev is None:
            return False
        klus = list(kl_list.klu_iter())
        if len(klus) < 2:
            return False
        c_prev2 = float(klus[-2].close)
        pmid = float(prev.get("boll", {}).get("mid", 0.0))
        cmid = float(last.get("boll", {}).get("mid", 0.0))
        c_now = float(klus[-1].close)
        return c_prev2 <= pmid and c_now > cmid

    if kind == "macd_golden_cross":
        if prev is None:
            return False
        pd, pa = float(prev["macd"]["dif"]), float(prev["macd"]["dea"])
        cd, ca = float(last["macd"]["dif"]), float(last["macd"]["dea"])
        return pd <= pa and cd > ca

    if kind == "macd_dead_cross":
        if prev is None:
            return False
        pd, pa = float(prev["macd"]["dif"]), float(prev["macd"]["dea"])
        cd, ca = float(last["macd"]["dif"]), float(last["macd"]["dea"])
        return pd >= pa and cd < ca

    if kind == "macd_above_zero":
        return float(last["macd"]["dif"]) > 0.0

    if kind == "macd_below_zero":
        return float(last["macd"]["dif"]) < 0.0

    if kind == "kdj_golden_cross":
        if prev is None:
            return False
        pk, pdj = float(prev["kdj"]["k"]), float(prev["kdj"]["d"])
        ck, cdj = float(last["kdj"]["k"]), float(last["kdj"]["d"])
        return pk <= pdj and ck > cdj

    if kind == "kdj_dead_cross":
        if prev is None:
            return False
        pk, pdj = float(prev["kdj"]["k"]), float(prev["kdj"]["d"])
        ck, cdj = float(last["kdj"]["k"]), float(last["kdj"]["d"])
        return pk >= pdj and ck < cdj

    if kind == "rsi_below":
        thr = float(cond.get("value", 30))
        return float(last.get("rsi", 50)) < thr

    if kind == "rsi_above":
        thr = float(cond.get("value", 70))
        return float(last.get("rsi", 50)) > thr

    if kind == "close_above_boll_mid":
        c_now = float(kl_list.lst[-1].lst[-1].close)
        return c_now > float(last.get("boll", {}).get("mid", c_now))

    if kind == "close_below_boll_upper":
        c_now = float(kl_list.lst[-1].lst[-1].close)
        return c_now < float(last.get("boll", {}).get("up", c_now))

    if kind == "close_above_boll_upper":
        c_now = float(kl_list.lst[-1].lst[-1].close)
        return c_now > float(last.get("boll", {}).get("up", c_now))

    if kind in ("bsp_buy", "bsp_sell"):
        lv = str(cond.get("level", "bi")).strip().lower()
        if not is_bsp_level(lv):
            lv = "bi"
        want_buy = kind == "bsp_buy"
        xi = last_klu_idx()
        if xi is None:
            return False
        new_keys = new_bsp_keys_for_stepper()
        if not new_keys:
            return False
        bundle = st.get_structure_bundle()
        bsp_list = get_bundle_bsp_list(bundle, lv)
        for bsp in bsp_list.bsp_iter():
            if bool(bsp.is_buy) != want_buy or int(bsp.klu.idx) != xi:
                continue
            item = make_bsp_item(lv, bsp)
            k = ChanStepper._bsp_key(item)
            if k in new_keys:
                return True
        return False

    return False


def _indicator_backtest_init_first_bar(sim: AppState, driver: ChanStepper) -> None:
    """首根：与驱动周期一致；driver=k2 时先推图2 再同步图1。"""
    if driver is sim.stepper2:
        if sim.stepper2 is None or not sim.stepper2.step():
            raise ValueError("K 线数据不足，无法回测")
        bt_sync_stepper_to_anchor(sim.stepper, sim.stepper2.current_time())
    else:
        if not sim.stepper.step():
            raise ValueError("K 线数据不足，无法回测")
        if sim.stepper2 is not None:
            sim.stepper2.step()
            bt_sync_stepper_to_anchor(sim.stepper2, sim.stepper.current_time())
    bt_dual_rebuild_coarse_chan_anti_future(
        sim.session_params or {},
        str(sim.chart_mode or "single"),
        sim.stepper,
        sim.stepper2,
        driver.current_time(),
    )


def run_indicator_backtest(req: IndicatorBacktestReq) -> dict[str, Any]:
    autype_map = {"qfq": AUTYPE.QFQ, "hfq": AUTYPE.HFQ, "none": AUTYPE.NONE}
    autype = autype_map.get(str(req.autype or "qfq").lower(), AUTYPE.QFQ)
    code_norm = normalize_code(req.code)
    cfg = req.chan_config if isinstance(req.chan_config, dict) else {}
    chart_mode = str(req.chart_mode or "single").strip().lower()
    if chart_mode == "multi":
        raise ValueError("指标回测暂不支持「单品种多周期单图」模式，请改用单周期或双周期")
    entry_conds, entry_comb_s, exit_conds, exit_comb_s, exit_hold = _normalize_indicator_backtest_req(req)
    if not entry_conds:
        raise ValueError("请至少配置一条入场条件（entry_conditions 或兼容字段 conditions）")
    entry_use_or = str(entry_comb_s).lower() == "or"
    exit_use_or = str(exit_comb_s).lower() == "or"

    sim = AppState()
    sim.chart_mode = "dual" if chart_mode == "dual" else "single"
    sim.stepper.init(
        code_norm,
        req.begin_date,
        req.end_date,
        autype,
        chan_config=cfg,
        k_type=req.k_type,
        confirm_offline=bool(req.confirm_offline),
        data_source_priority=req.data_source_priority,
        data_form_mode=req.data_form_mode,
        data_form_quantity=req.data_form_quantity,
        data_form_quantity_alloc=getattr(req, "data_form_quantity_alloc", "front"),
        data_feed_mode=getattr(req, "data_feed_mode", "step"),
        offline_data_custom=getattr(req, "offline_data_custom", "native"),
    )
    sim.stepper2 = None
    if sim.chart_mode == "dual":
        sim.stepper2 = ChanStepper()
        sim.stepper2.init(
            code_norm,
            req.begin_date,
            req.end_date,
            autype,
            chan_config=cfg,
            k_type=str(req.k_type_2 or req.k_type),
            confirm_offline=bool(req.confirm_offline),
            data_source_priority=req.data_source_priority,
            data_form_mode=req.data_form_mode,
            data_form_quantity=req.data_form_quantity,
            data_form_quantity_alloc=getattr(req, "data_form_quantity_alloc", "front"),
            data_feed_mode=getattr(req, "data_feed_mode", "step"),
            offline_data_custom=getattr(req, "offline_data_custom", "native"),
        )
    sim.session_params = {
        "code": code_norm,
        "begin_date": req.begin_date,
        "end_date": req.end_date,
        "autype": autype,
        "initial_cash": float(req.initial_cash),
        "chan_config": cfg,
        "k_type": req.k_type,
        "chart_mode": sim.chart_mode,
        "k_type_2": req.k_type_2,
        "active_chart_id": "chart1",
        "confirm_offline": bool(req.confirm_offline),
        "data_source_priority": req.data_source_priority,
        "data_form_mode": normalize_data_form_mode(req.data_form_mode),
        "data_form_quantity": req.data_form_quantity,
        "data_feed_mode": normalize_data_feed_mode(getattr(req, "data_feed_mode", "step")),
        "offline_data_custom": normalize_offline_data_custom(getattr(req, "offline_data_custom", "native")),
    }
    sim.ready = True

    sdriver = str(req.step_driver or "auto").lower().strip()
    if sdriver == "k2" and chart_mode != "dual":
        raise ValueError("步进驱动选「周期2」时需开启双周期模式")
    driver, follower = _pick_driver_for_indicator_bt(sim, sdriver)
    _indicator_backtest_init_first_bar(sim, driver)

    prev_k1 = _bt_bsp_key_set(sim.stepper)
    prev_k2 = _bt_bsp_key_set(sim.stepper2) if sim.stepper2 else set()

    cash = float(req.initial_cash)
    pos_shares = 0
    pos_buy_price = 0.0
    pos_buy_step_ch1 = -1
    pos_buy_driver_step = -1
    pos_buy_time = ""
    trades: list[dict[str, Any]] = []
    equity_curve: list[float] = []

    def ref_price() -> float:
        return float(sim.stepper.chan[0].lst[-1].lst[-1].close)

    def eval_entry(bsp_ctx: dict[str, set[str]]) -> bool:
        flags = [_eval_indicator_condition(c, sim, bsp_ctx) for c in entry_conds]
        return _combine_cond_flags(flags, entry_use_or)

    def eval_exit(bsp_ctx: dict[str, set[str]]) -> bool:
        if not exit_conds:
            return False
        flags = [_eval_indicator_condition(c, sim, bsp_ctx) for c in exit_conds]
        return _combine_cond_flags(flags, exit_use_or)

    def try_buy() -> None:
        nonlocal cash, pos_shares, pos_buy_price, pos_buy_step_ch1, pos_buy_driver_step, pos_buy_time
        if pos_shares > 0 or cash <= 0:
            return
        price = ref_price()
        if price <= 0:
            return
        shares = int(cash // price)
        if shares <= 0:
            return
        cash -= shares * price
        pos_shares = shares
        pos_buy_price = float(price)
        pos_buy_step_ch1 = int(sim.stepper.step_idx)
        pos_buy_driver_step = int(driver.step_idx)
        pos_buy_time = str(sim.stepper.current_time())

    def try_sell(idx_sell: int, sell_reason: str) -> None:
        nonlocal cash, pos_shares, pos_buy_price, pos_buy_step_ch1, pos_buy_driver_step, pos_buy_time
        if pos_shares <= 0:
            return
        price = ref_price()
        if price <= 0:
            return
        cash += pos_shares * price
        trades.append(
            {
                "buy_idx": int(pos_buy_step_ch1),
                "sell_idx": int(idx_sell),
                "buy_t": pos_buy_time,
                "sell_t": str(sim.stepper.current_time()),
                "buy_price": round(pos_buy_price, 4),
                "sell_price": round(float(price), 4),
                "shares": int(pos_shares),
                "pnl": round((float(price) - pos_buy_price) * pos_shares, 2),
                "sell_reason": sell_reason,
                "driver_step": int(driver.step_idx),
            }
        )
        pos_shares = 0
        pos_buy_price = 0.0
        pos_buy_step_ch1 = -1
        pos_buy_driver_step = -1
        pos_buy_time = ""

    while True:
        keys_k1 = _bt_bsp_key_set(sim.stepper)
        keys_k2 = _bt_bsp_key_set(sim.stepper2) if sim.stepper2 else set()
        bsp_ctx = {"new_k1": keys_k1 - prev_k1, "new_k2": keys_k2 - prev_k2}

        c_now = ref_price()
        if pos_shares > 0 and pos_buy_driver_step >= 0:
            exit_sig = eval_exit(bsp_ctx)
            hold_hit = exit_hold is not None and (int(driver.step_idx) - pos_buy_driver_step >= int(exit_hold))
            if exit_sig or hold_hit:
                if exit_sig and hold_hit:
                    reason = "exit_formula+hold"
                elif exit_sig:
                    reason = "exit_formula"
                else:
                    reason = "exit_hold"
                try_sell(int(sim.stepper.step_idx), reason)
        if pos_shares <= 0 and eval_entry(bsp_ctx):
            try_buy()
        mv = cash + (pos_shares * c_now if pos_shares > 0 else 0.0)
        equity_curve.append(round(mv, 2))

        ok = driver.step()
        if not ok:
            break
        if follower is not None:
            bt_sync_stepper_to_anchor(follower, driver.current_time())
        bt_dual_rebuild_coarse_chan_anti_future(
            sim.session_params or {},
            str(sim.chart_mode or "single"),
            sim.stepper,
            sim.stepper2,
            driver.current_time(),
        )
        prev_k1 = _bt_bsp_key_set(sim.stepper)
        prev_k2 = _bt_bsp_key_set(sim.stepper2) if sim.stepper2 else set()

    if pos_shares > 0:
        try_sell(int(sim.stepper.step_idx), "eof")

    final_equity = cash
    total_pnl = round(final_equity - float(req.initial_cash), 2)
    ret_pct = (total_pnl / float(req.initial_cash) * 100.0) if req.initial_cash else 0.0
    wins = sum(1 for tr in trades if float(tr.get("pnl", 0)) > 0)
    losses = sum(1 for tr in trades if float(tr.get("pnl", 0)) < 0)
    ntr = len(trades)
    bar_count = len(sim.stepper._replay_klus_master or [])
    warn = None
    if bar_count > 8000:
        warn = "K 线根数较多，回测可能较慢（每步粗周期可能整段重建）。"

    return {
        "code": code_norm,
        "name": sim.stepper.stock_name,
        "chart_mode": chart_mode,
        "k_type": req.k_type,
        "k_type_2": req.k_type_2 if chart_mode == "dual" else None,
        "step_driver": str(req.step_driver or "auto"),
        "bars": bar_count,
        "initial_cash": round(float(req.initial_cash), 2),
        "final_equity": round(final_equity, 2),
        "total_pnl": total_pnl,
        "total_return_pct": round(ret_pct, 2),
        "trade_count": ntr,
        "win_count": wins,
        "loss_count": losses,
        "win_rate_pct": round((wins / ntr * 100.0) if ntr else 0.0, 2),
        "trades": trades,
        "entry_combine": entry_comb_s,
        "exit_combine": exit_comb_s,
        "exit_hold_bars": exit_hold,
        "entry_conditions": entry_conds,
        "exit_conditions": exit_conds,
        "hold_bars_basis": "driver",
        "warning": warn,
    }


def serialize_klu_iter(klu_iter) -> list[dict[str, Any]]:
    return serialize_klu_iter_fast(
        klu_iter,
        serialize_klu_unit_fast_fn=serialize_klu_unit_fast,
        volume_getter_fn=lambda x: _klu_float_trade_metric(x, DATA_FIELD.FIELD_VOLUME),
    )


def serialize_replay_master_klines(master: list[Any]) -> list[dict[str, Any]]:
    """数量/分笔数量模式：主图 K 线按喂入的聚合根数序列化，避免引擎合并 K 后 klu_iter 多出重叠蜡烛。"""
    _ensure_klu_deepcopy_attrs(master)
    out: list[dict[str, Any]] = []
    vol_fn = lambda x: _klu_float_trade_metric(x, DATA_FIELD.FIELD_VOLUME)
    for i, klu in enumerate(master):
        row = serialize_klu_unit_fast(klu, vol_fn)
        row["x"] = i
        out.append(row)
    return out


def use_master_kline_for_chart(data_form_mode: str) -> bool:
    """图表主图 K 线是否以 _replay_klus_master 为准（与数量聚合根数一致）。"""
    return is_data_form_quantity_mode(data_form_mode)


def _newk_combine_frame_time_lo(el: NewKElement) -> str:
    """合并框左界时间（与 begin_x 同源）。"""
    it = el.item
    if isinstance(it, CKLine):
        return it.lst[0].time.to_str()
    if isinstance(it, (CBi, CSeg)):
        return it.get_begin_klu().time.to_str()
    return ""


def _newk_combine_frame_time_hi(el: NewKElement) -> str:
    """合并框右界时间（与 end_x 同源）。"""
    it = el.item
    if isinstance(it, CKLine):
        return it.lst[-1].time.to_str()
    if isinstance(it, (CBi, CSeg)):
        return it.get_end_klu().time.to_str()
    return ""


def serialize_kline_combine(kl_list) -> list[dict[str, Any]]:
    """序列化合并K线线框，供前端独立绘制。"""
    bars = build_combined_newk_bars(list(kl_list.lst))
    out: list[dict[str, Any]] = []
    for bar in bars:
        if len(bar.elements) == 0:
            continue
        first = bar.elements[0]
        last = bar.elements[-1]
        t1 = _newk_combine_frame_time_lo(first)
        t2 = _newk_combine_frame_time_hi(last)
        out.append(
            {
                "x1": int(first.begin_x),
                "x2": int(last.end_x),
                "t1": t1,
                "t2": t2,
                "high": float(bar.high),
                "low": float(bar.low),
                "fx": str(bar.fx.name if isinstance(bar.fx, FX_TYPE) else bar.fx),
                "count": len(bar.elements),
            }
        )
    return out


def serialize_chan(
    chan: CChan,
    indicator_history: list,
    trend_lines: list,
    *,
    chan_algo: str = CHAN_ALGO_CLASSIC,
    bundle: Optional[ChanStructureBundle] = None,
    kline_all: Optional[list[dict[str, Any]]] = None,
    klu_arr_cache: Optional[list[dict[str, Any]]] = None,
) -> dict[str, Any]:
    return serialize_chan_with_cache(
        chan,
        indicator_history,
        trend_lines,
        build_structure_bundle_fn=build_structure_bundle,
        serialize_klu_iter_fn=serialize_klu_iter,
        serialize_line_collection_fn=serialize_line_collection,
        serialize_zs_collection_fn=serialize_zs_collection,
        serialize_kline_combine_fn=serialize_kline_combine,
        serialize_bsp_collection_fn=serialize_bsp_collection,
        level_order=LEVEL_ORDER,
        chan_algo=chan_algo,
        bundle=bundle,
        kline_all=kline_all,
        klu_arr_cache=klu_arr_cache,
    )


HTML = r"""
<!DOCTYPE html>
<html lang="zh-CN" data-theme="light">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>chan.py 复盘训练器</title>
  <style>
    :root, [data-theme="light"]{
      --bg: #f7f7f8;
      --panel: #ffffff;
      --text: #0f172a;
      --muted: #475569;
      --border: #cbd5e1;
      --btn: #f1f5f9;
      --btnText: #0f172a;
      --chartBg: #ffffff;
      --grid: #e2e8f0;
      --candleUp: #ef4444;
      --candleDown: #22c55e;
      --candleUpFill: rgba(239,68,68,0.12);
      --candleDownFill: rgba(34,197,94,0.75);
      --lineFx: #06b6d4;
      --lineBi: #f59e0b;
      --lineBiWeak: #94a3b8;
      --lineSeg: #059669;
      --lineSegWeak: #34d399;
      --holdFill: rgba(59,130,246,0.14);
      --holdFillPast: rgba(99,102,241,0.12);
      --markBuy: #dc2626;
      --markSell: #16a34a;
      --rayBuy: #f97316;
      --raySell: #14b8a6;
      --bspBuy: #dc2626;
      --bspSell: #16a34a;
      --legendBg: rgba(255,255,255,0.92);
      --legendText: #0f172a;
      --legendBorder: rgba(148,163,184,0.6);
      --chipFill: rgba(59,130,246,0.45);
      --chipBg: rgba(148,163,184,0.12);
      --chipEdge: rgba(59,130,246,0.75);
    }
    [data-theme="dark"]{
      --bg: #0b0f14;
      --panel: #0b0f14;
      --text: #e6edf3;
      --muted: #9ca3af;
      --border: #334155;
      --btn: #1e293b;
      --btnText: #e6edf3;
      --chartBg: #0b0f14;
      --grid: #334155;
      --candleUp: #f87171;
      --candleDown: #4ade80;
      --candleUpFill: rgba(248,113,113,0.15);
      --candleDownFill: rgba(74,222,128,0.45);
      --lineFx: #22d3ee;
      --lineBi: #fbbf24;
      --lineBiWeak: #94a3b8;
      --lineSeg: #34d399;
      --lineSegWeak: #6ee7b7;
      --holdFill: rgba(59,130,246,0.18);
      --holdFillPast: rgba(129,140,248,0.16);
      --markBuy: #f87171;
      --markSell: #4ade80;
      --rayBuy: #fb923c;
      --raySell: #2dd4bf;
      --bspBuy: #fca5a5;
      --bspSell: #86efac;
      --legendBg: rgba(15,23,42,0.88);
      --legendText: #e2e8f0;
      --legendBorder: rgba(71,85,105,0.8);
      --chipFill: rgba(96,165,250,0.5);
      --chipBg: rgba(148,163,184,0.16);
      --chipEdge: rgba(147,197,253,0.8);
    }
    [data-theme="eye-care"]{
      --bg: #e8f0e8;
      --panel: #f4faf4;
      --text: #1a2e1a;
      --muted: #3d5a3d;
      --border: #a3c4a3;
      --btn: #dcefdc;
      --btnText: #1a2e1a;
      --chartBg: #fafdf8;
      --grid: #c5dcc5;
      --candleUp: #c0392b;
      --candleDown: #27ae60;
      --candleUpFill: rgba(192,57,43,0.12);
      --candleDownFill: rgba(39,174,96,0.55);
      --lineFx: #1a8a9e;
      --lineBi: #b45309;
      --lineBiWeak: #78716c;
      --lineSeg: #047857;
      --lineSegWeak: #6ee7b7;
      --holdFill: rgba(37,99,235,0.12);
      --holdFillPast: rgba(79,70,229,0.1);
      --markBuy: #b91c1c;
      --markSell: #15803d;
      --rayBuy: #c2410c;
      --raySell: #0f766e;
      --bspBuy: #b91c1c;
      --bspSell: #15803d;
      --legendBg: rgba(250,253,248,0.94);
      --legendText: #1a2e1a;
      --legendBorder: rgba(163,196,163,0.9);
      --chipFill: rgba(37,99,235,0.42);
      --chipBg: rgba(163,196,163,0.18);
      --chipEdge: rgba(37,99,235,0.72);
    }
    body { margin: 0; font-family: Arial, sans-serif; background: var(--bg); color: var(--text); overflow: hidden; }
    .wrap { display: flex; height: 100vh; flex-direction: row-reverse; }
    /* 左侧操控区：纵向 flex，下方内容区滚轮可滚动 */
    .left {
      width: 360px;
      padding: 12px;
      border-right: none;
      border-left: 1px solid var(--border);
      box-sizing: border-box;
      overflow: hidden;
      background: var(--panel);
      position: relative;
      display: flex;
      flex-direction: column;
      height: 100vh;
    }
    .leftScrollRegion {
      flex: 1 1 auto;
      min-height: 0;
      overflow-y: auto;
      overflow-x: hidden;
      overscroll-behavior: contain;
    }
    .leftContent {
      transform-origin: top left;
      width: 100%;
      will-change: transform;
    }
    .sourceStatus {
      margin: -4px 0 10px;
      color: var(--muted);
      font-size: 12px;
      min-height: 18px;
    }
    .resizer {
      width: 4px;
      cursor: col-resize;
      background: var(--border);
      height: 100%;
      z-index: 10;
      transition: background 0.2s;
    }
    .resizer:hover { background: #2563eb; }
    .right { flex: 1; padding: 0; box-sizing: border-box; min-width: 0; position: relative; display: flex; }
    .row { margin-bottom: 8px; display: flex; align-items: center; gap: 6px; }
    .row input[type="checkbox"] { width: auto; transform: scale(1.1); margin-left: 8px; }
    label { display: inline-block; width: 110px; font-size: 14px; }
    input, select { flex: 1; padding: 4px; background: var(--panel); color: var(--text); border: 1px solid var(--border); min-width: 0; }
    
    .btnRow { display: flex; flex-direction: column; gap: 6px; margin-bottom: 8px; }
    .btnRow button { width: 100%; margin: 0; padding: 8px; text-align: left; position: relative; }
    
    button { padding: 6px 10px; border: 1px solid var(--border); background: var(--btn); color: var(--btnText); cursor: pointer; border-radius: 4px; }
    button:disabled { opacity: 0.4; cursor: not-allowed; }
    button:hover:not(:disabled) { border-color: #2563eb; background: #eff6ff; color: #2563eb; }
    
    .title { font-size: 16px; margin: 4px 0 10px; color: #2563eb; font-weight: bold; }
    .card { border: 1px solid var(--border); padding: 12px; margin-bottom: 12px; background: var(--panel); border-radius: 8px; }
    #configCard {
      padding: 0;
      overflow: hidden;
      background:
        linear-gradient(135deg, rgba(15,23,42,0.05), transparent 38%),
        var(--panel);
    }
    .configHero {
      padding: 12px 12px 10px;
      border-bottom: 1px solid var(--border);
      background: linear-gradient(180deg, rgba(37,99,235,0.08), rgba(15,23,42,0.02));
    }
    .configHeroTitle {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      margin-bottom: 4px;
      color: var(--text);
      font-size: 14px;
      font-weight: 700;
    }
    .configHeroBadge {
      flex: 0 0 auto;
      padding: 2px 7px;
      border: 1px solid rgba(37,99,235,0.32);
      border-radius: 999px;
      color: #2563eb;
      background: rgba(37,99,235,0.08);
      font-size: 11px;
      font-weight: 700;
    }
    .configHeroHint { color: var(--muted); font-size: 11px; line-height: 1.45; margin: 0; }
    .configQuickActions {
      display: grid;
      grid-template-columns: 1fr;
      gap: 6px;
      padding: 10px 12px;
      border-bottom: 1px solid var(--border);
      background: rgba(148,163,184,0.06);
    }
    .configQuickActions button {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      padding: 7px 9px;
      border-radius: 6px;
      font-weight: 700;
      text-align: left;
    }
    .configSection {
      padding: 12px;
      border-bottom: 1px solid var(--border);
    }
    .configSection:last-child { border-bottom: none; }
    .configSectionHead {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      margin-bottom: 9px;
    }
    .configSectionTitle {
      color: #0f172a;
      font-size: 12px;
      font-weight: 800;
      letter-spacing: 0;
    }
    [data-theme="dark"] .configSectionTitle { color: #dbeafe; }
    .configSectionNote {
      color: var(--muted);
      font-size: 11px;
      white-space: nowrap;
    }
    #configCard .row {
      margin-bottom: 7px;
      align-items: center;
    }
    #configCard .row:last-child { margin-bottom: 0; }
    #configCard label {
      width: 86px;
      color: var(--muted);
      font-size: 12px;
      font-weight: 700;
    }
    #configCard input,
    #configCard select {
      min-height: 30px;
      border-radius: 6px;
      padding: 5px 8px;
      font-size: 13px;
    }
    #configCard input:focus,
    #configCard select:focus {
      outline: 2px solid rgba(37,99,235,0.2);
      border-color: #2563eb;
    }
    .configPrimaryActions {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 6px;
      margin-bottom: 10px;
    }
    .configPrimaryActions button,
    .configStepActions button,
    .tradeActions button {
      min-height: 32px;
      text-align: center;
      font-weight: 700;
    }
    #btnInit {
      background: #2563eb;
      border-color: #1d4ed8;
      color: #fff;
    }
    #btnInit:hover:not(:disabled) {
      background: #1d4ed8;
      color: #fff;
    }
    .configStepActions {
      display: grid !important;
      grid-template-columns: 1fr;
      gap: 6px;
      width: 100%;
      margin-top: 6px !important;
    }
    .tradeRuleLine {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin: 0 0 8px;
      padding: 7px 8px;
      border: 1px dashed var(--border);
      border-radius: 6px;
      background: rgba(148,163,184,0.07);
    }
    .tradeActions {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 6px;
      margin: 0;
    }
    #kTypesMultiCbWrap > div:first-child {
      gap: 5px 6px !important;
    }
    #configCard .kTypesMultiLbl {
      width: auto !important;
      min-height: 26px;
      padding: 3px 7px;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: rgba(148,163,184,0.07);
    }
    #configCard .kTypesMultiLbl input { min-height: 0; }
    .left.compact .title { margin-bottom: 8px; font-size: 15px; }
    .left.compact .sourceStatus { margin-bottom: 8px; font-size: 11px; }
    .left.compact .chartToolsPanel,
    .left.compact .card { padding: 10px; margin-bottom: 10px; }
    .left.compact #configCard { padding: 0; }
    .left.compact .configHero,
    .left.compact .configSection { padding: 10px; }
    .left.compact .configQuickActions { padding: 8px 10px; }
    .left.compact .btnRow { gap: 4px; margin-bottom: 6px; }
    .left.compact .btnRow button { padding: 6px 8px; }
    .left.compact .row { margin-bottom: 6px; }
    .left.compact label { width: 96px; font-size: 13px; }
    .left.compact input,
    .left.compact select,
    .left.compact button { font-size: 12px; }
    #chart { width: 100%; height: 100%; background: var(--chartBg); display: block; flex: 1; min-width: 0; }
    .muted { color: var(--muted); font-size: 12px; }
    .mono { font-family: Consolas, monospace; }
    
    .account-grid { display: grid; grid-template-columns: 1fr; gap: 8px; }
    .account-item { display: flex; justify-content: space-between; font-size: 14px; padding: 4px 0; border-bottom: 1px dashed var(--grid); }
    .account-item label { width: auto; color: var(--muted); }
    .account-item span { font-weight: bold; font-family: Consolas, monospace; }

    /* 回测条件区：Figma 风格分区卡片 */
    .bt-cond-shell {
      border: 1px solid var(--border);
      border-radius: 12px;
      background: linear-gradient(180deg, rgba(255,255,255,0.95), rgba(248,250,252,0.95));
      padding: 10px;
      margin-top: 8px;
    }
    .bt-cond-section {
      border: 1px solid rgba(148,163,184,0.25);
      border-radius: 10px;
      background: #ffffff;
      padding: 10px;
      margin-bottom: 10px;
      box-shadow: 0 2px 8px rgba(15,23,42,0.04);
    }
    .bt-cond-section:last-child { margin-bottom: 0; }
    .bt-cond-title {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      margin-bottom: 6px;
    }
    .bt-cond-title strong {
      font-size: 13px;
      letter-spacing: 0.2px;
      color: #1e3a8a;
    }
    .bt-cond-badge {
      font-size: 11px;
      color: #334155;
      background: #e2e8f0;
      border-radius: 999px;
      padding: 2px 8px;
      white-space: nowrap;
    }
    .bt-cond-desc {
      color: var(--muted);
      font-size: 11px;
      line-height: 1.45;
      margin: 0 0 8px;
    }
    .bt-combine-row {
      display: flex;
      align-items: center;
      gap: 8px;
      margin-bottom: 8px;
    }
    .bt-combine-row label {
      width: auto;
      min-width: 72px;
      color: #334155;
      font-size: 12px;
      font-weight: 600;
    }
    .bt-combine-row select {
      flex: 1 1 auto;
      max-width: 180px;
      border-radius: 8px;
      padding: 6px 8px;
      background: #f8fafc;
    }
    .bt-cond-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 8px;
      font-size: 12px;
    }
    .bt-cond-cascade-host .settings-cascade { min-height: 200px; max-height: 280px; }
    .bt-cond-cascade-host .settings-cascade-list { max-height: none; flex: 1; }
    .bt-cond-cascade-panel {
      display: flex;
      flex-direction: column;
      gap: 6px;
      max-height: 220px;
      overflow-y: auto;
    }
    .bt-cond-cascade-panel .bt-cond-item { margin: 0; }
    .bt-cond-item {
      display: flex;
      align-items: flex-start;
      gap: 8px;
      border: 1px solid #dbeafe;
      background: #f8fbff;
      border-radius: 8px;
      padding: 7px 8px;
      cursor: pointer;
      transition: all .16s ease;
      min-height: 42px;
      box-sizing: border-box;
    }
    .bt-cond-item:hover {
      border-color: #93c5fd;
      background: #eff6ff;
      transform: translateY(-1px);
    }
    .bt-cond-item input[type="checkbox"] {
      margin: 2px 0 0;
      width: 14px;
      height: 14px;
      accent-color: #2563eb;
      transform: none;
    }
    .bt-cond-text {
      display: flex;
      flex-direction: column;
      gap: 2px;
      line-height: 1.3;
      min-width: 0;
    }
    .bt-cond-main {
      color: #0f172a;
      word-break: break-word;
    }
    .bt-cond-sub {
      color: #64748b;
      font-size: 11px;
    }
    .bt-hold-row {
      display: flex;
      align-items: center;
      gap: 8px;
      margin-top: 8px;
      padding: 8px;
      border-radius: 8px;
      background: #f8fafc;
      border: 1px dashed #cbd5e1;
    }
    .bt-hold-row label {
      width: auto;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      font-size: 12px;
      font-weight: 600;
      color: #334155;
      flex: 1 1 auto;
      min-width: 0;
    }
    .bt-hold-row input[type="number"] {
      max-width: 100px;
      flex: 0 0 auto;
      border-radius: 8px;
      background: #fff;
      padding: 6px 8px;
    }

    /* Tooltip logic */
    .tip-icon {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 16px;
      height: 16px;
      background: #2563eb;
      color: white;
      border-radius: 50%;
      font-size: 11px;
      font-weight: bold;
      margin-left: 6px;
      cursor: help;
      position: relative;
      user-select: none;
    }
    .tip-icon::before {
      content: "i";
      font-family: serif;
    }
    .tip-content {
      position: fixed;
      background: #1e293b;
      color: white;
      padding: 8px 12px;
      border-radius: 6px;
      font-size: 12px;
      white-space: pre-wrap;
      z-index: 30000;
      width: max-content;
      max-width: 280px;
      font-weight: normal;
      box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05);
      pointer-events: none;
      display: none;
      line-height: 1.5;
    }

    /* Chart tools panel (pinned to the very top of the trainer controls) */
    .chartToolsPanel {
      width: 100%;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--panel);
      padding: 12px;
      box-sizing: border-box;
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 10px;
      margin: 0 0 12px 0;
    }
    :fullscreen #chart { height: 100vh; }
    .fullscreen-btn {
      background: rgba(255,255,255,0.8);
      border: 1px solid var(--border);
      border-radius: 4px;
      padding: 4px 8px;
      cursor: pointer;
      display: flex;
      align-items: center;
      gap: 4px;
      width: auto;
      min-width: 140px;
      justify-content: center;
    }
    .fullscreen-btn:hover { background: #fff; border-color: #2563eb; }

    .judge-bsp-btn {
      background: rgba(255,255,255,0.88);
      border: 1px solid var(--border);
      border-radius: 4px;
      padding: 4px 10px;
      cursor: pointer;
      display: none;
      align-items: center;
      gap: 4px;
      white-space: nowrap;
      width: auto;
      min-width: 124px;
      justify-content: center;
    }
    .judge-bsp-btn:hover { background: #fff; border-color: #16a34a; }
    .judge-bsp-btn:disabled { opacity: 0.55; cursor: not-allowed; }

    .toolbox {
      background: rgba(255,255,255,0.92);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 8px;
      display: flex;
      flex: 1 1 460px;
      flex-direction: row;
      flex-wrap: wrap;
      gap: 8px;
      align-items: center;
      min-width: 0;
    }
    .toolbox .label {
      color: var(--muted);
      font-size: 12px;
      white-space: nowrap;
      margin-right: 4px;
    }
    .toolbox button {
      padding: 4px 8px;
      font-size: 12px;
      width: auto;
      border-radius: 6px;
      border: 1px solid var(--border);
      background: #fff;
      cursor: pointer;
      white-space: nowrap;
    }
    .toolbox button.active {
      border-color: #2563eb;
      box-shadow: 0 0 0 2px rgba(37, 99, 235, 0.12);
    }
    .toolbox button.focus-highlight {
      border-color: #f59e0b;
      box-shadow: 0 0 0 3px rgba(245, 158, 11, 0.3), 0 8px 18px rgba(245, 158, 11, 0.18);
      background: linear-gradient(180deg, #fff9ec 0%, #fffbeb 100%);
      font-weight: 700;
    }

    /* Toast 弹窗 */
    #toastContainer {
      position: fixed;
      top: 20px;
      left: 50%;
      transform: translateX(-50%);
      z-index: 11000;
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 10px;
      pointer-events: none;
    }
    .toast {
      padding: 10px 20px;
      background: var(--legendBg);
      color: var(--legendText);
      border: 1px solid var(--legendBorder);
      border-radius: 8px;
      box-shadow: 0 4px 12px rgba(0,0,0,0.15);
      font-family: Consolas, monospace;
      animation: toastFadeIn 0.3s forwards;
      pointer-events: auto;
      max-width: 80vw;
      text-align: center;
      transition: opacity 0.3s;
      white-space: pre-wrap;
      line-height: 1.5;
    }
    @keyframes toastFadeIn {
      from { opacity: 0; transform: translateY(-20px); }
      to { opacity: 1; transform: translateY(0); }
    }

    /* 消息历史弹窗 */
    .msgHistoryModal {
      position: fixed; inset: 0; display: none; align-items: center; justify-content: center;
      background: rgba(2, 6, 23, 0.6); z-index: 21000;
    }
    .msgHistoryModal.show { display: flex; }
    .msgHistoryModal .panel {
      width: 600px; max-height: 80vh; background: var(--panel); padding: 20px; border-radius: 12px;
      display: flex; flex-direction: column;
    }
    .msgHistoryList {
      flex: 1; overflow-y: auto; border: 1px solid var(--border); margin: 10px 0; padding: 10px;
      font-family: Consolas, "Microsoft YaHei UI", monospace; font-size: 13px;
      white-space: pre-wrap;
      user-select: text;
    }
    .msgHistoryItem { border-bottom: 1px dashed var(--grid); padding: 6px 0; }
    .msgHistoryItem .time { color: #2563eb; margin-right: 10px; }

    /* 全量 K 线数据查看弹窗 */
    .klineDataModal {
      position: fixed; inset: 0; display: none; align-items: center; justify-content: center;
      background: rgba(2, 6, 23, 0.6); z-index: 10007;
    }
    .klineDataModal.show { display: flex; }
    .klineDataModal .panel {
      width: min(920px, 96vw); max-height: 86vh; background: var(--panel); padding: 16px 18px; border-radius: 12px;
      display: flex; flex-direction: column; box-sizing: border-box;
    }
    .klineDataToolbar {
      display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-bottom: 10px; font-size: 13px;
    }
    .klineDataToolbar label { margin-right: 4px; color: var(--muted); }
    .klineDataToolbar select { padding: 4px 8px; border-radius: 6px; border: 1px solid var(--border); background: var(--panel); color: var(--text); }
    .klineDataMeta { font-size: 12px; color: var(--muted); margin-bottom: 8px; }
    .klineDataTableWrap {
      flex: 1; overflow: auto; border: 1px solid var(--border); border-radius: 8px; max-height: 58vh;
      font-family: Consolas, "Microsoft YaHei UI", monospace; font-size: 12px;
    }
    .klineDataTableWrap table { width: 100%; border-collapse: collapse; }
    .klineDataTableWrap th, .klineDataTableWrap td {
      border-bottom: 1px solid var(--grid); padding: 4px 6px; text-align: left; vertical-align: top;
    }
    .klineDataTableWrap th { position: sticky; top: 0; background: var(--btn); z-index: 1; }
    .klineDataCellJson { max-width: 420px; white-space: pre-wrap; word-break: break-all; }
    
    .stepNRow {
      margin-top: 6px;
      display: flex;
      align-items: center;
      gap: 6px;
      flex-wrap: wrap;
    }
    .stepNRow input {
      width: 76px;
      padding: 4px 6px;
      box-sizing: border-box;
      font-family: Consolas, monospace;
    }
    .stepNRow .hint {
      color: var(--muted);
      font-size: 12px;
    }
    .modal-overlay {
      position: absolute;
      inset: 0;
      pointer-events: none;
      z-index: 10000;
    }
    .modal-overlay > div {
      pointer-events: auto;
    }
    .globalLoading {
      position: fixed;
      inset: 0;
      display: none;
      align-items: center;
      justify-content: center;
      background: rgba(15, 23, 42, 0.36);
      backdrop-filter: blur(1px);
      z-index: 20000;
      pointer-events: none;
    }
    .globalLoading.show { display: flex; }
    .globalLoading .panel {
      width: min(780px, calc(100vw - 32px));
      min-width: 260px;
      padding: 18px 20px;
      border-radius: 10px;
      border: 1px solid var(--legendBorder);
      background: var(--legendBg);
      color: var(--legendText);
      box-shadow: 0 14px 36px rgba(2, 6, 23, 0.26);
      display: flex;
      flex-direction: column;
      align-items: stretch;
      gap: 12px;
      font: 14px Consolas, monospace;
      position: relative;
      z-index: 20002;
      pointer-events: auto;
    }
    .globalLoadingBody {
      display: flex;
      gap: 14px;
      align-items: stretch;
    }
    .globalLoading .spinner {
      width: 18px;
      height: 18px;
      border-radius: 50%;
      border: 2px solid rgba(59, 130, 246, 0.22);
      border-top-color: #2563eb;
      animation: spin 0.8s linear infinite;
      flex: 0 0 auto;
    }
    .globalLoading .loadingMain {
      display: flex;
      align-items: center;
      gap: 12px;
      min-width: 0;
      flex: 1;
    }
    .globalLoadingPrimary {
      flex: 1 1 380px;
      min-width: 0;
    }
    .globalLoading .loadingText {
      flex: 1;
      min-width: 0;
      word-break: break-word;
    }
    .loadingEta {
      color: var(--muted);
      font-size: 12px;
      margin-top: 6px;
    }
    .loadingProgressOuter {
      margin-top: 10px;
      height: 16px;
      border-radius: 999px;
      overflow: hidden;
      background: rgba(148, 163, 184, 0.28);
      border: 1px solid rgba(148, 163, 184, 0.26);
    }
    .loadingProgressInner {
      height: 100%;
      width: 0%;
      min-width: 34px;
      background: #2563eb;
      color: #fff;
      font-size: 11px;
      line-height: 16px;
      text-align: center;
      transition: width 0.25s ease;
    }
    .loadingHistorySide {
      flex: 0 0 min(300px, 38%);
      min-width: 200px;
      max-height: min(320px, 42vh);
      overflow-y: auto;
      border: 1px solid var(--legendBorder);
      border-radius: 8px;
      padding: 10px 12px;
      background: var(--legendBg);
      color: var(--legendText);
      font-size: 12px;
      line-height: 1.55;
      white-space: pre-wrap;
      user-select: text;
    }
    .loadingHistorySide .time {
      color: #2563eb;
      margin-right: 6px;
    }
    .globalLoading .loadingActions {
      display: block;
      margin-top: 10px;
      text-align: right;
      position: relative;
      z-index: 20003;
    }
    .globalLoading .loadingActions.show {
      display: block;
    }
    .globalLoading .loadingActions button {
      width: auto;
      padding: 6px 14px;
      font-size: 13px;
      line-height: 1.4;
      pointer-events: auto;
    }
    .globalLoading .loadingActions button:disabled {
      opacity: 0.45;
    }
    @media (max-width: 760px) {
      .globalLoadingBody { flex-direction: column; }
      .loadingHistorySide {
        flex: 1 1 auto;
        min-width: 0;
        max-height: 36vh;
        width: auto;
      }
    }
    @keyframes spin {
      from { transform: rotate(0deg); }
      to { transform: rotate(360deg); }
    }
    .bspPrompt {
      position: absolute;
      inset: 0;
      display: none;
      align-items: center;
      justify-content: center;
      background: rgba(2, 6, 23, 0.45);
      z-index: 10001;
      pointer-events: auto;
      cursor: pointer;
    }
    .bspPrompt.show { display: flex; }
    .bspPrompt .panel {
      width: min(560px, calc(100vw - 24px));
      border: 1px solid var(--legendBorder);
      border-radius: 10px;
      background: var(--legendBg);
      color: var(--legendText);
      box-shadow: 0 18px 42px rgba(2, 6, 23, 0.32);
      padding: 16px;
      box-sizing: border-box;
      pointer-events: auto;
      cursor: default;
    }
    .bspPromptTitle {
      font-size: 16px;
      font-weight: 700;
      margin-bottom: 8px;
      color: #b91c1c;
    }
    .bspPromptBody {
      white-space: pre-wrap;
      line-height: 1.6;
      margin-bottom: 10px;
      font-family: Consolas, monospace;
      font-size: 13px;
    }
    .bspPromptHint {
      color: var(--muted);
      font-size: 12px;
      margin-bottom: 10px;
    }
    .bspPromptActions {
      display: flex;
      justify-content: flex-end;
    }
    .bspPromptActions button {
      min-width: 120px;
    }
    /* 交易状态悬浮窗 */
    .tradeStatusOverlay {
      position: fixed;
      top: 16px;
      left: 16px;
      width: 280px;
      min-width: 220px;
      min-height: 64px;
      background: rgba(255, 255, 255, 0.95);
      border-radius: 14px;
      box-shadow: 0 8px 32px rgba(0, 0, 0, 0.15);
      padding: 0;
      z-index: 10002;
      border: 2px solid #e2e8f0;
      transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
      backdrop-filter: blur(8px);
      overflow: hidden;
    }
    [data-theme="dark"] .tradeStatusOverlay { background: rgba(30, 41, 59, 0.95); border-color: #334155; }
    .tradeStatusTitleBar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 10px 12px;
      background: linear-gradient(135deg, rgba(37,99,235,0.18), rgba(14,165,233,0.08));
      border-bottom: 1px solid #dbeafe;
      cursor: move;
      user-select: none;
      gap: 8px;
    }
    .tradeStatusTitle {
      font-weight: bold;
      font-size: 14px;
      letter-spacing: 0.5px;
      color: #0f172a;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .tradeStatusDot {
      width: 10px;
      height: 10px;
      border-radius: 50%;
      background: linear-gradient(135deg, #22c55e, #16a34a);
      box-shadow: 0 0 0 3px rgba(34, 197, 94, 0.18);
    }
    .tradeStatusActions { display: flex; gap: 6px; }
    .tradeStatusMiniBtn {
      width: 24px;
      height: 24px;
      border-radius: 6px;
      border: 1px solid rgba(148, 163, 184, 0.6);
      background: rgba(255,255,255,0.75);
      color: var(--text);
      font-size: 12px;
      padding: 0;
      display: inline-flex;
      align-items: center;
      justify-content: center;
    }
    .tradeStatusMiniBtn:hover { background: rgba(255,255,255,0.95); }
    .tradeStatusOverlay.dragging .tradeStatusTitle { opacity: 0.85; }
    .tradeStatusBody { padding: 12px 14px 16px; }
    .tradeStatusGrid { display: grid; grid-template-columns: 1fr; gap: 6px; }
    .tsItem { display: flex; justify-content: space-between; font-family: Consolas, monospace; }
    .tsItem label { color: #64748b; font-size: 12px; }
    .tsItem span { font-weight: bold; }
    .tradeStatusOverlay.minimized .tradeStatusBody { display: none; }
    .tradeStatusResizeHandle {
      position: absolute;
      right: 0;
      bottom: 0;
      width: 18px;
      height: 18px;
      cursor: nwse-resize;
      background: linear-gradient(135deg, transparent 45%, rgba(37,99,235,0.45) 45%, rgba(37,99,235,0.45) 55%, transparent 55%);
    }
    .pnl-plus { color: #ef4444; }
    .pnl-minus { color: #22c55e; }
    .overlay-plus { border-color: #ef4444; background: rgba(254, 242, 242, 0.95); }
    .overlay-minus { border-color: #22c55e; background: rgba(240, 253, 244, 0.95); }
    [data-theme="dark"] .overlay-plus { background: rgba(69, 10, 10, 0.95); }
    [data-theme="dark"] .overlay-minus { background: rgba(5, 46, 22, 0.95); }

    /* 结算弹窗 */
    .settlementModal {
      position: fixed; top: 0; left: 0; width: 100%; height: 100%;
      background: rgba(0,0,0,0.5); display: none; align-items: center; justify-content: center; z-index: 10000;
    }
    .settlementModal.show { display: flex; }
    .settlementModal .panel {
      width: 480px; background: white; border-radius: 12px; padding: 24px;
      box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.1);
    }
    [data-theme="dark"] .settlementModal .panel { background: #1e293b; color: #f1f5f9; }
    .settlementTitle { font-size: 20px; font-weight: bold; margin-bottom: 20px; text-align: center; border-bottom: 2px solid #e2e8f0; padding-bottom: 12px; }
    .settlementBody { font-family: Consolas, monospace; line-height: 1.8; font-size: 14px; margin-bottom: 20px; }
    .settlementActions { text-align: center; }
    .settlementActions button { padding: 10px 40px; font-size: 16px; cursor: pointer; background: #3b82f6; color: white; border: none; border-radius: 6px; }

    .settingsModal {
      position: fixed;
      inset: 0;
      display: none;
      align-items: center;
      justify-content: center;
      background: rgba(2, 6, 23, 0.6);
      z-index: 10005;
    }
    .settingsModal.show { display: flex; }
    .settingsModal .panel {
      width: min(640px, calc(100vw - 40px));
      max-height: 85vh;
      overflow-y: auto;
      border: 1px solid var(--legendBorder);
      border-radius: 12px;
      background: var(--panel);
      color: var(--text);
      box-shadow: 0 20px 50px rgba(0, 0, 0, 0.3);
      padding: 24px;
      box-sizing: border-box;
    }
    #settingsModal .panel.chart-settings-panel {
      width: min(920px, calc(100vw - 32px));
      max-height: 88vh;
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }
    #settingsModal .panel.chart-settings-panel #settingsContent {
      flex: 1;
      min-height: 0;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }
    .settingsTitle {
      font-size: 20px;
      font-weight: bold;
      margin-bottom: 20px;
      padding-bottom: 10px;
      border-bottom: 2px solid var(--border);
      color: #2563eb;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .settingsSection {
      margin-bottom: 20px;
      padding: 16px;
      border-radius: 12px;
      box-shadow: 0 4px 6px rgba(0, 0, 0, 0.05);
    }
    .settingsSectionTitle {
      font-weight: bold;
      margin-bottom: 16px;
      font-size: 14px;
      text-transform: uppercase;
      letter-spacing: 1px;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .settingsSectionTitle::before {
      content: "";
      display: inline-block;
      width: 4px;
      height: 16px;
      background: currentColor;
      border-radius: 2px;
    }
    .settingsGrid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
      gap: 12px;
    }
    .settingsItem {
      display: flex;
      flex-direction: column;
      gap: 4px;
    }
    .settingsItem label {
      font-size: 13px;
      width: auto;
    }
    .settingsItem input {
      width: 100%;
      box-sizing: border-box;
    }
    .settingsItemDisabled {
      opacity: 0.58;
    }
    .settingsItemDisabled select,
    .settingsItemDisabled input {
      cursor: not-allowed;
    }
    .settingsItemWide {
      grid-column: 1 / -1;
    }
    /* 图表显示设置：三级级联（级别 → 类型 → 买/卖） */
    .settings-cascade {
      display: flex;
      border: 1px solid var(--border);
      border-radius: 8px;
      overflow: hidden;
      min-height: 200px;
      font-size: 13px;
      background: var(--panel);
    }
    .settings-cascade-col {
      flex: 1;
      min-width: 0;
      border-right: 1px solid var(--border);
      display: flex;
      flex-direction: column;
    }
    .settings-cascade-col:last-child { border-right: none; }
    .settings-cascade-head {
      padding: 8px 10px;
      background: rgba(37, 99, 235, 0.06);
      font-weight: 600;
      border-bottom: 1px solid var(--border);
      color: #1e40af;
    }
    .settings-cascade-list {
      flex: 1;
      overflow-y: auto;
      max-height: 220px;
    }
    .settings-cascade-item {
      padding: 8px 10px;
      cursor: pointer;
      border-bottom: 1px solid rgba(148, 163, 184, 0.2);
      user-select: none;
    }
    .settings-cascade-item:hover { background: rgba(37, 99, 235, 0.08); }
    .settings-cascade-item.active {
      background: rgba(37, 99, 235, 0.14);
      color: #1d4ed8;
      font-weight: 600;
    }
    .settings-cascade-panel {
      padding: 12px;
      display: flex;
      flex-direction: column;
      gap: 10px;
      flex: 1;
    }
    .settings-cascade-actions {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      margin-top: 4px;
    }
    .settings-cascade-actions button {
      padding: 4px 8px;
      font-size: 12px;
      width: auto;
    }
    /* 图表显示设置：单面板级联（分组 → 配置项） */
    .chart-settings-shell { margin-bottom: 8px; display: flex; flex-direction: column; min-height: 0; flex: 1; }
    .chart-settings-hint { font-size: 12px; margin-bottom: 10px; line-height: 1.5; flex-shrink: 0; }
    .chart-settings-cascade {
      display: flex;
      flex: 1;
      min-height: min(420px, 52vh);
      max-height: min(560px, 62vh);
      min-width: 0;
    }
    .chart-settings-nav {
      flex: 0 0 26%;
      min-width: 132px;
      max-width: 220px;
      display: flex;
      flex-direction: column;
      min-height: 0;
    }
    .chart-settings-nav .settings-cascade-list {
      flex: 1;
      max-height: none;
      min-height: 0;
    }
    .chart-settings-nav .settings-cascade-item {
      width: 100%;
      box-sizing: border-box;
      line-height: 1.35;
      word-break: break-word;
    }
    .chart-settings-detail-col {
      flex: 1;
      min-width: 0;
      display: flex;
      flex-direction: column;
      min-height: 0;
    }
    .chart-settings-detail-scroll {
      flex: 1;
      overflow-y: auto;
      min-height: 0;
      max-height: none;
      padding: 12px 14px;
      box-sizing: border-box;
    }
    .chart-settings-detail-head {
      margin-bottom: 12px;
      padding-left: 10px;
      border-left: 4px solid #2563eb;
    }
    .chart-settings-detail-body {
      display: flex;
      flex-direction: column;
      gap: 12px;
    }
    .chart-settings-detail-body .settingsItem {
      padding: 10px;
      border: 1px solid rgba(148, 163, 184, 0.35);
      border-radius: 8px;
      background: rgba(255, 255, 255, 0.5);
    }
    [data-theme="dark"] .chart-settings-detail-body .settingsItem {
      background: rgba(15, 23, 42, 0.35);
    }
    .chart-settings-branch-toolbar {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 10px 14px;
      margin-top: 10px;
      padding: 10px 12px;
      border-radius: 8px;
      background: rgba(37, 99, 235, 0.05);
      border: 1px solid rgba(148, 163, 184, 0.35);
    }
    .chart-settings-cascade-label {
      font-size: 12px;
      font-weight: 600;
      color: #475569;
      margin-right: -4px;
    }
    [data-theme="dark"] .chart-settings-cascade-label { color: #94a3b8; }
    .chart-settings-cascade-select {
      min-width: 128px;
      max-width: min(100%, 240px);
      padding: 6px 10px;
      border-radius: 6px;
      border: 1px solid var(--border);
      background: var(--panel);
      font-size: 13px;
      cursor: pointer;
    }
    .chart-settings-cascade-select:disabled {
      opacity: 0.85;
      cursor: default;
      color: #1e40af;
      font-weight: 600;
    }
    .chart-settings-branch-help {
      margin-left: auto;
      padding: 5px 12px;
      font-size: 12px;
      width: auto;
      border-radius: 6px;
    }
    .chart-settings-branch-subtitle {
      margin: 2px 0 10px;
      padding-left: 10px;
      border-left: 3px solid rgba(37, 99, 235, 0.4);
      font-size: 13px;
    }
    .chart-settings-branch-body { margin-top: 4px; }
    .settingsActions {
      margin-top: 16px;
      display: flex;
      justify-content: flex-end;
      gap: 12px;
      position: sticky;
      bottom: 0;
      z-index: 2;
      padding: 12px 0 4px;
      border-top: 1px solid var(--border);
      background: linear-gradient(to bottom, rgba(255,255,255,0), var(--panel) 24%);
    }
    .settingsActions button {
      min-width: 100px;
    }
    /* 左侧主标签：1 复盘 / 2 回测 */
    .mainTabs {
      display: flex;
      gap: 6px;
      margin: 0 0 8px 0;
      flex-shrink: 0;
    }
    .mainTabBtn {
      flex: 1;
      padding: 8px 6px;
      font-size: 13px;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--btn);
      color: var(--btnText);
      cursor: pointer;
    }
    .mainTabBtn:hover:not(.active) { border-color: #2563eb; }
    .mainTabBtn.active {
      border-color: #2563eb;
      background: var(--panel);
      font-weight: bold;
      color: #2563eb;
      box-shadow: 0 0 0 1px rgba(37, 99, 235, 0.15);
    }
    .tabPanel { width: 100%; box-sizing: border-box; }
    .subTabs { display: flex; gap: 6px; margin-bottom: 8px; flex-wrap: wrap; }
    .subTabBtn {
      padding: 5px 12px;
      font-size: 12px;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--btn);
      cursor: pointer;
    }
    .subTabBtn.active { border-color: #2563eb; color: #2563eb; font-weight: bold; }
    .btTradeRow { cursor: pointer; font-size: 12px; }
    .btTradeRow:hover { background: rgba(37, 99, 235, 0.08); }
  </style>

</head>
<body>
  <div class="wrap">
    <div class="left">
      <div class="title" style="display:flex; align-items:center; justify-content:space-between; gap:8px;">
        <span>chan.py 复盘训练器 <span class="tip-icon" data-tip="Chan.py 缠论复盘交易系统"></span></span>
        <button id="btnCopyCurrentConfig" type="button" style="width:auto; padding:3px 8px; font-size:12px;" data-tip="复制当前基础参数、缠论配置、图表显示设置和系统关键配置，方便粘贴给调试。">复制配置</button>
      </div>
      <div id="dataSourceStatus" class="sourceStatus mono">当前数据源：未加载</div>
      <div class="mainTabs" role="tablist" aria-label="主标签">
        <button type="button" class="mainTabBtn active" id="btnMainTab1" role="tab" aria-selected="true">1 · 复盘训练</button>
        <button type="button" class="mainTabBtn" id="btnMainTab2" role="tab" aria-selected="false">2 · 回测</button>
      </div>
      <div class="leftScrollRegion">
      <div id="leftContent" class="leftContent">
      <div id="tabPanel1" class="tabPanel">
      <div id="chartToolsPanel" class="chartToolsPanel">
        <button id="btnFullscreen" class="fullscreen-btn" data-tip="切换图表区域全屏显示。">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3"/></svg>
          全屏显示 (F11)
        </button>
        <button id="btnJudgeBsp" class="judge-bsp-btn" data-tip="手动检查买卖点（仅手动判定模式下可用）。" disabled>检查买卖点</button>
        <div id="toolbox" class="toolbox">
          <span class="label">画线工具箱</span>
          <button id="toolNone" type="button" class="active" data-tip="选择模式：可选中画线并使用“画线属性”进行编辑。">选择</button>
          <button id="toolHorizontalRay" type="button" data-tip="生成水平射线：点击图表在当前价位生成一条水平射线。">水平射线</button>
          <button id="toolBiRay" type="button" data-tip="笔端点射线：依次点击两个笔端点生成一条向右延伸的射线。再次点击可退出。">笔端点射线</button>
          <button id="toolRatioLine" type="button" data-tip="比例线：点击按钮会弹出详细操作说明。依次点两个笔端点可生成 0.382 / 0.5 / 0.618，悬停可高亮，拖拽可上下移动，按 Ctrl 可吸附K线高低点。">比例线</button>
          <button id="toolParallelogram" type="button" data-tip="平行四边形：依次点 3 个位置。Ctrl+左键可在任意 K 线列吸附开高低收（不必是笔/段端点）；无 Ctrl 时仍优先吸附笔端点。第1、2点定平行边方向。再次点击工具退出。">平行四边形</button>
          <button id="toolLineProps" type="button" data-tip="先使用“选择”并点击某条画线，再点此按钮编辑粗细/颜色/线型。">画线属性</button>
        </div>
      </div>
      <div class="card" id="configCard">
        <div class="configHero">
          <div class="configHeroTitle">
            <span>K线复盘控制台</span>
            <span class="configHeroBadge">右侧图窗</span>
          </div>
          <p class="configHeroHint">先定标的与周期，再加载会话；训练、回退、交易动作集中在下方。</p>
        </div>
        <div class="configQuickActions">
          <button id="btnChanSettingsOpen" data-tip="打开缠论逻辑配置面板，可调整笔、线段、中枢等算法。">缠论配置... <small>(L)</small></button>
          <button id="btnSettingsOpen" data-tip="打开图表显示设置面板，可调整主题、指标与绘制项。">图表显示设置... <small>(P)</small></button>
          <button id="btnSystemSettingsOpen" data-tip="打开系统配置面板，可统一维护快捷键。">系统配置... <small>(Shift+P)</small></button>
        </div>
        <div class="configSection">
          <div class="configSectionHead">
            <div class="configSectionTitle">基础参数</div>
            <div class="configSectionNote">标的 / 日期 / 资金</div>
          </div>
        <div class="row cfg-editable">
          <label>代码</label>
          <input id="code" value="600340" />
          <span class="tip-icon" data-tip="输入6位数字代码"></span>
        </div>
        <div class="row cfg-editable"><label>开始日期</label><input id="begin" type="date" value="2018-01-01" /><span class="tip-icon" data-tip="复盘回放的起始日期。"></span></div>
        <div class="row cfg-editable"><label>结束日期</label><input id="end" type="date" value="" placeholder="可空" /><span class="tip-icon" data-tip="默认为空，表示截止当前日期。"></span></div>
        <div class="row cfg-editable"><label>初始资金</label><input id="cash" value="10000" /><span class="tip-icon" data-tip="模拟交易使用的初始资金，买入按钮会基于该资金全仓买入。"></span></div>
        <div class="row cfg-editable">
          <label>复权</label>
          <select id="autype">
            <option value="qfq">前复权</option>
            <option value="hfq">后复权</option>
            <option value="none">不复权</option>
          </select>
          <span class="tip-icon" data-tip="选择K线数据的复权方式。"></span>
        </div>
        </div>
        <div class="configSection">
          <div class="configSectionHead">
            <div class="configSectionTitle">图形结构</div>
            <div class="configSectionNote">模式 / 周期 / 双图</div>
          </div>
        <div class="row cfg-editable">
          <label>K线图模式</label>
          <select id="chartMode">
            <option value="single" selected>单品种单周期图</option>
            <option value="dual">单品种两周期图</option>
            <option value="multi">单品种多周期单图</option>
          </select>
          <span class="tip-icon" data-tip="单周期=原模式；两周期=上下两窗；多周期单图=多周期叠在同一主图（仅离线分笔，最细勾选周期步进，粗周期防未来）。后两者互斥。"></span>
        </div>
        <div class="row cfg-editable" id="kType1Row">
          <label>周期类型1</label>
          <select id="kType">
            <option value="1min">1分钟</option>
            <option value="5min">5分钟</option>
            <option value="15min">15分钟</option>
            <option value="30min">30分钟</option>
            <option value="60min">60分钟</option>
            <option value="daily" selected>日线</option>
            <option value="weekly">周线</option>
            <option value="monthly">月线</option>
            <option value="quarterly">季线</option>
            <option value="yearly">年线</option>
            <option value="3min">3分钟</option>
          </select>
          <span class="tip-icon" data-tip="双周期时对应图1；单周期时为当前主图周期。不同数据源支持周期可能不同。"></span>
        </div>
        <div class="row cfg-editable" id="kType2Row" style="display:none;">
          <label>周期类型2</label>
          <select id="kType2">
            <option value="1min">1分钟</option>
            <option value="5min">5分钟</option>
            <option value="15min">15分钟</option>
            <option value="30min">30分钟</option>
            <option value="60min">60分钟</option>
            <option value="daily" selected>日线</option>
            <option value="weekly">周线</option>
            <option value="monthly">月线</option>
            <option value="quarterly">季线</option>
            <option value="yearly">年线</option>
            <option value="3min">3分钟</option>
          </select>
          <span class="tip-icon" data-tip="双周期模式下第二个图窗的周期。"></span>
        </div>
        <div class="row cfg-editable" id="kTypesMultiRow" style="display:none;">
          <label style="align-self:flex-start; margin-top:4px;">叠加周期</label>
          <div id="kTypesMultiCbWrap" style="flex:2; display:flex; flex-direction:column; gap:4px; min-width:0;">
            <div style="display:flex; flex-wrap:wrap; gap:4px 10px; align-items:center;">
            <label class="kTypesMultiLbl" style="display:inline-flex; align-items:center; gap:3px; white-space:nowrap;" data-kt="1min"><input type="checkbox" class="kTypesMultiCb" value="1min" /><span class="kTypesMultiTxt">1分</span></label>
            <label class="kTypesMultiLbl" style="display:inline-flex; align-items:center; gap:3px; white-space:nowrap;" data-kt="3min"><input type="checkbox" class="kTypesMultiCb" value="3min" /><span class="kTypesMultiTxt">3分</span></label>
            <label class="kTypesMultiLbl" style="display:inline-flex; align-items:center; gap:3px; white-space:nowrap;" data-kt="5min"><input type="checkbox" class="kTypesMultiCb" value="5min" /><span class="kTypesMultiTxt">5分</span></label>
            <label class="kTypesMultiLbl" style="display:inline-flex; align-items:center; gap:3px; white-space:nowrap;" data-kt="15min"><input type="checkbox" class="kTypesMultiCb" value="15min" /><span class="kTypesMultiTxt">15分</span></label>
            <label class="kTypesMultiLbl" style="display:inline-flex; align-items:center; gap:3px; white-space:nowrap;" data-kt="30min"><input type="checkbox" class="kTypesMultiCb" value="30min" /><span class="kTypesMultiTxt">30分</span></label>
            <label class="kTypesMultiLbl" style="display:inline-flex; align-items:center; gap:3px; white-space:nowrap;" data-kt="60min"><input type="checkbox" class="kTypesMultiCb" value="60min" /><span class="kTypesMultiTxt">60分</span></label>
            <label class="kTypesMultiLbl" style="display:inline-flex; align-items:center; gap:3px; white-space:nowrap;" data-kt="daily"><input type="checkbox" class="kTypesMultiCb" value="daily" /><span class="kTypesMultiTxt">日</span></label>
            <label class="kTypesMultiLbl" style="display:inline-flex; align-items:center; gap:3px; white-space:nowrap;" data-kt="weekly"><input type="checkbox" class="kTypesMultiCb" value="weekly" /><span class="kTypesMultiTxt">周</span></label>
            <label class="kTypesMultiLbl" style="display:inline-flex; align-items:center; gap:3px; white-space:nowrap;" data-kt="monthly"><input type="checkbox" class="kTypesMultiCb" value="monthly" /><span class="kTypesMultiTxt">月</span></label>
            <label class="kTypesMultiLbl" style="display:inline-flex; align-items:center; gap:3px; white-space:nowrap;" data-kt="quarterly"><input type="checkbox" class="kTypesMultiCb" value="quarterly" /><span class="kTypesMultiTxt">季</span></label>
            <label class="kTypesMultiLbl" style="display:inline-flex; align-items:center; gap:3px; white-space:nowrap;" data-kt="yearly"><input type="checkbox" class="kTypesMultiCb" value="yearly" /><span class="kTypesMultiTxt">年</span></label>
            </div>
            <div class="muted" style="font-size:11px;">多周期叠画时可用键盘 <b>1–5</b> 切换第 1–5 个勾选周期（按上表从左到右顺序）的 K 线/缠论线显示，不改变已选周期。</div>
          </div>
          <span class="tip-icon" data-tip="多周期单图：须至少勾选 2 个周期；其中最细的勾选周期为步进驱动。左侧「周期类型1」行在本模式下隐藏，仅在此勾选叠加周期。仅支持离线分笔数据。筹码仅跟驱动周期。指标回测页不支持本模式。"></span>
        </div>
        <div class="row cfg-editable" id="dualLayoutRow" style="display:none;">
          <label>排列方式</label>
          <select id="dualLayout">
            <option value="vertical" selected>上下</option>
            <option value="horizontal">左右</option>
          </select>
          <span class="tip-icon" data-tip="双周期模式下两张主图的排列方式：上下或左右。"></span>
        </div>
        <div class="row cfg-editable" id="dualSplitRow" style="display:none;">
          <label>双图区域比</label>
          <input type="range" id="dualSplitRatio" min="22" max="78" step="1" value="50" style="flex:2; min-width:0;" />
          <span id="dualSplitRatioLabel" class="muted" style="width:40px; text-align:right; flex-shrink:0;">50%</span>
          <span class="tip-icon" data-tip="双周期下调节图1与图2占比：上下排为高度比，左右排为宽度比。"></span>
        </div>
        </div>
        <div class="configSection">
          <div class="configSectionHead">
            <div class="configSectionTitle">会话动作</div>
            <div class="configSectionNote">加载 / 步进 / 跳转</div>
          </div>
        <div class="btnRow configPrimaryActions">
          <button id="btnInit" data-tip="根据当前代码、日期区间、初始资金加载复盘会话。首次加载历史数据可能较慢。">加载会话 <small>(Ctrl+I)</small></button>
          <button id="btnViewKlineData" data-tip="查看当前会话全量 K 线：开高低收、成交量与筹码分桶（若有）、或全部字段。" disabled>查看数据</button>
          <button id="btnReset" data-tip="清空当前会话并恢复到可重新配置的初始状态。">重新训练 <small>(Ctrl+R)</small></button>
          <button id="btnFinish" data-tip="结束当前训练，并可选择导出本次交易总结文件。" disabled>结束训练</button>
          <button id="btnExit" data-tip="尝试关闭当前页面。浏览器可能会拦截关闭操作。">退出</button>
          <button id="btnStepPrev" data-tip="回退一根K线（重建到上一根）。快捷键可在系统配置中修改。" disabled>上一根K线 <small>(Shift+Space)</small></button>
          <button id="btnStep" data-tip="步进到下一根K线。若当前K线命中买卖点（1/1p/2/2s/3a/3b）或 1382 提示，会合并为一个弹窗提示。" disabled>下一根K线 <small>(Space)</small></button>
        </div>
        <div class="stepNRow">
          <label for="stepN">步进数量 N</label>
          <span id="tipStepN" class="tip-icon" data-tip="设置连续步进或回退时使用的根数。连续步进遇到买卖点（1/1p/2/2s/3a/3b）或 1382 提示可自动中断，中断项可在图表显示设置里配置。"></span>
          <input id="stepN" type="number" min="1" step="1" value="5" />
          <span id="stepNMaxHint" class="hint" style="flex:1 1 200px; min-width:0;"></span>
          <div class="btnRow configStepActions">
            <button id="btnStepN" data-tip="按步进数量 N 连续推进，若中途遇到买卖点（1/1p/2/2s/3a/3b）或 1382 提示会按设置自动停止。" disabled>步进 N 根 <small>(Ctrl+Alt+N)</small></button>
            <button id="btnStepInterrupt" data-tip="正在连续步进时可点击中断；当前根处理完后停止。" disabled>中断步进 <small>(Ctrl+Alt+X)</small></button>
            <button id="btnBackN" data-tip="按步进数量 N 回退，会自动重建到更早的状态。" disabled>后退 N 根 <small>(Ctrl+Alt+M)</small></button>
          </div>
          <div id="unifiedGotoRow" style="display:none; width:100%; margin-top:6px; align-items:center; gap:6px; flex-wrap:wrap;">
            <label for="inputUnifiedGotoStep">跳转 step</label>
            <span id="tipUnifiedGotoStep" class="tip-icon" data-tip="统一喂数据专用：跳转作用于当前激活图窗（与图1/图2激活按钮一致），仅切片不重算；step 与界面 step_idx 一致（0 为第一根）。双周期时被动图按锚点时间对齐。"></span>
            <input id="inputUnifiedGotoStep" type="number" min="0" step="1" value="0" />
            <button type="button" id="btnUnifiedGotoStep" data-tip="跳转到指定 step_idx（统一喂数据模式）。" disabled>跳转</button>
          </div>
        </div>
        </div>
        <div class="configSection">
          <div class="configSectionHead">
            <div class="configSectionTitle">交易动作</div>
            <div class="configSectionNote">单持仓 / T+1</div>
          </div>
        <div class="tradeRuleLine">
          <span class="muted">交易规则</span>
          <span class="tip-icon" data-tip="规则：单持仓、T+1、每步最多一笔；平多当根可再开空，平空当根可再开多。"></span>
        </div>
        <div class="btnRow tradeActions">
          <button id="btnBuy" data-tip="按当前收盘价使用全部可用现金买入，遵循单持仓和每步最多一笔规则。" disabled>买入（全仓） <small>(PageUp)</small></button>
          <button id="btnSell" data-tip="按当前收盘价全部卖出，若受 T+1 约束则按钮不可用。" disabled>卖出（全量） <small>(PageDown)</small></button>
          <button id="btnShort" data-tip="按当前收盘价使用全仓做空，遵循单持仓和每步最多一笔规则。" disabled>做空（全仓）</button>
          <button id="btnCover" data-tip="按当前收盘价全部平空，若受 T+1 约束则按钮不可用。" disabled>平空（全量）</button>
        </div>
        </div>
      </div>
      <div class="card">
        <div class="title" style="margin:0 0 12px 0; display:flex; justify-content:space-between; align-items:center;">
          历史记录
          <button id="btnMsgHistory" style="padding:2px 6px; font-size:12px; width:auto;">历史记录</button>
        </div>
        <div class="muted">账户状态信息已迁移到“当前持仓状态”浮窗（仅持仓时显示）。</div>
      </div>
      </div>
      <div id="tabPanel2" class="tabPanel" style="display:none;">
        <div class="card">
          <p class="muted" style="font-size:12px; line-height:1.5; margin:0 0 10px;">股票代码、日期、资金、复权与<strong>标签1</strong>共用；本页可单独设回测周期与条件。步进规则与复盘一致：<strong>细周期驱动、粗周期跟随</strong>，粗末根按细K重算，无大周期未来函数。</p>
          <div class="row cfg-editable">
            <label>K线图模式</label>
            <select id="btChartMode">
              <option value="single">单周期</option>
              <option value="dual">双周期</option>
            </select>
            <span class="tip-icon" data-tip="双周期时可选手动指定步进时钟；默认较细周期驱动。被动周期同步+粗末根防未来与复盘一致。"></span>
          </div>
          <div class="row cfg-editable" id="btStepDriverRow" style="display:none;">
            <label>步进驱动</label>
            <select id="btStepDriver">
              <option value="auto" selected>自动（较细周期）</option>
              <option value="k1">周期1 K 线</option>
              <option value="k2">周期2 K 线</option>
            </select>
            <span class="tip-icon" data-tip="回测每步以所选周期的下一根 K 为时钟；与复盘里「点 active 图步进」不同，此处由本项固定，避免歧义。"></span>
          </div>
          <div class="row cfg-editable">
            <label>周期1</label>
            <select id="btKType1">
              <option value="1min">1分钟</option>
              <option value="5min">5分钟</option>
              <option value="15min">15分钟</option>
              <option value="30min">30分钟</option>
              <option value="60min">60分钟</option>
              <option value="daily" selected>日线</option>
              <option value="weekly">周线</option>
              <option value="monthly">月线</option>
              <option value="quarterly">季线</option>
              <option value="yearly">年线</option>
              <option value="3min">3分钟</option>
            </select>
          </div>
          <div class="row cfg-editable" id="btKType2Row" style="display:none;">
            <label>周期2</label>
            <select id="btKType2">
              <option value="1min">1分钟</option>
              <option value="5min">5分钟</option>
              <option value="15min">15分钟</option>
              <option value="30min">30分钟</option>
              <option value="60min">60分钟</option>
              <option value="daily">日线</option>
              <option value="weekly" selected>周线</option>
              <option value="monthly">月线</option>
              <option value="quarterly">季线</option>
              <option value="yearly">年线</option>
              <option value="3min">3分钟</option>
            </select>
          </div>
          <div class="bt-cond-shell">
            <div class="bt-cond-section">
              <div class="bt-cond-title">
                <strong>入场条件</strong>
                <span class="bt-cond-badge">多选</span>
              </div>
              <p class="bt-cond-desc">BOLL/MACD/KDJ/RSI 与复盘同一递推；买卖点仅当<strong>本步新增</strong>且落在当前 K 上触发。</p>
              <div class="bt-combine-row cfg-editable">
                <label>条件关系</label>
                <select id="btEntryCombineMode">
                  <option value="and" selected>AND（全部满足）</option>
                  <option value="or">OR（任一满足）</option>
                </select>
              </div>
              <div id="btEntryCondCascade" class="bt-cond-cascade-host"></div>
            </div>
            <div class="bt-cond-section">
              <div class="bt-cond-title">
                <strong>出场条件</strong>
                <span class="bt-cond-badge">多选 + 兜底</span>
              </div>
              <p class="bt-cond-desc">出场公式与“持有满 N 根兜底平仓”为「或」关系，任一满足即触发卖出。</p>
              <div class="bt-combine-row cfg-editable">
                <label>条件关系</label>
                <select id="btExitCombineMode">
                  <option value="and" selected>AND（全部满足）</option>
                  <option value="or">OR（任一满足）</option>
                </select>
              </div>
              <div id="btExitCondCascade" class="bt-cond-cascade-host"></div>
              <div class="bt-hold-row cfg-editable">
                <label>
                  <input type="checkbox" id="btUseExitHold" checked />
                  <span>持有满 N 根（驱动周期）兜底平仓</span>
                </label>
                <input id="btExitHoldN" type="number" min="1" step="1" value="5" />
                <span class="tip-icon" data-tip="未勾选时仅按出场公式平仓；若未配出场公式且未勾选，服务端仍默认持有 5 根兜底。出场公式与兜底任一满足即卖。"></span>
              </div>
            </div>
          </div>
          <div class="btnRow" style="margin-top:8px;">
            <button type="button" id="btnStrategyBacktestRun">执行回测</button>
          </div>
        </div>
        <div class="card" id="btResultCard" style="display:none; margin-top:10px;">
          <div class="title" style="margin:0 0 8px;">回测结果</div>
          <pre id="btBacktestSummary" class="mono" style="white-space:pre-wrap; font-size:12px; margin:0; color:var(--text);"></pre>
          <p class="muted" style="font-size:11px; margin:8px 0 0;">双击表格一行：切到标签1并跳转到该笔买入 K（需已用相同代码与周期1加载会话）。买卖点与粗周期指标已按细周期重算末根，与复盘防未来逻辑一致。</p>
          <div id="btTradeTableWrap" style="max-height:240px; overflow:auto; margin-top:8px; border:1px solid var(--border); border-radius:6px;"></div>
        </div>
      </div>
      </div>
      </div>
    </div>
    <div class="resizer" id="resizer"></div>
    <div class="right">
      <div id="modalOverlay" class="modal-overlay">
        <div id="chanSettingsModal" class="settingsModal" aria-hidden="true">
          <div class="panel">
            <div class="settingsTitle">
              缠论配置
              <button id="btnChanSettingsClose" style="margin:0; padding:4px 8px;">&times;</button>
            </div>
            <div id="chanSettingsContent">
              <!-- Generated by JS -->
            </div>
            <div class="settingsActions">
              <button id="btnChanSettingsReset">恢复默认</button>
              <button id="btnChanSettingsSave">保存并应用 (S)</button>
            </div>
          </div>
        </div>
        <div id="settingsModal" class="settingsModal" aria-hidden="true">
          <div class="panel">
            <div class="settingsTitle">
              图表显示设置
              <button id="btnSettingsClose" style="margin:0; padding:4px 8px;">&times;</button>
            </div>
            <div id="settingsContent">
              <!-- Generated by JS -->
            </div>
            <div class="settingsActions">
              <button id="btnSettingsReset">恢复默认</button>
              <button id="btnSettingsSave">保存并应用 (S)</button>
            </div>
          </div>
        </div>
        <div id="systemSettingsModal" class="settingsModal" aria-hidden="true">
          <div class="panel">
            <div class="settingsTitle">
              系统配置
              <button id="btnSystemSettingsClose" style="margin:0; padding:4px 8px;">&times;</button>
            </div>
            <div id="systemSettingsContent">
              <!-- Generated by JS -->
            </div>
            <div class="settingsActions">
              <button id="btnSystemSettingsReset">恢复默认</button>
              <button id="btnSystemSettingsSave">保存并应用 (S)</button>
            </div>
          </div>
        </div>
      </div>
      
      <div id="toastContainer"></div>
  <div id="tipContent" class="tip-content"></div>

      <div id="msgHistoryModal" class="msgHistoryModal" aria-hidden="true">
        <div class="panel">
          <div class="settingsTitle">
            消息历史记录
            <button id="btnMsgHistoryClose" style="margin:0; padding:4px 8px;">&times;</button>
          </div>
          <div id="msgHistoryList" class="msgHistoryList"></div>
          <div class="settingsActions">
            <button id="btnMsgHistoryCopy">复制记录</button>
            <button id="btnMsgHistoryPrev">上一次记录</button>
            <button id="btnMsgHistoryClear">清空记录</button>
            <button id="btnMsgHistoryOk">确 认</button>
          </div>
        </div>
      </div>
      <div id="klineDataModal" class="klineDataModal" aria-hidden="true">
        <div class="panel">
          <div class="settingsTitle">
            查看 K 线数据
            <button id="btnKlineDataClose" type="button" style="margin:0; padding:4px 8px;">&times;</button>
          </div>
          <div class="klineDataToolbar">
            <span id="klineDataChartWrap" style="display:none;">
              <label for="klineDataChartId">图表</label>
              <select id="klineDataChartId">
                <option value="chart1">周期 1（图1）</option>
                <option value="chart2">周期 2（图2）</option>
                <option value="active">当前激活图</option>
              </select>
            </span>
            <span id="klineDataMultiWrap" style="display:none;">
              <label for="klineDataLayerKt">查看周期</label>
              <select id="klineDataLayerKt"></select>
            </span>
            <span>
              <label for="klineDataView">内容</label>
              <select id="klineDataView">
                <option value="kline">K 线（开高低收）</option>
                <option value="volume_chip">成交量与筹码分桶</option>
                <option value="all">全部字段</option>
              </select>
            </span>
            <button id="btnKlineDataRefresh" type="button">刷新</button>
            <button id="btnKlineDataCopy" type="button">复制 JSON</button>
          </div>
          <div id="klineDataMeta" class="klineDataMeta"></div>
          <div id="klineDataTableWrap" class="klineDataTableWrap"></div>
          <div class="settingsActions" style="margin-top:12px;">
            <button id="btnKlineDataOk" type="button">关 闭</button>
          </div>
        </div>
      </div>
      <div id="bspPrompt" class="bspPrompt" aria-hidden="true">
        <div class="panel">
          <div id="bspPromptTitle" class="bspPromptTitle">检测到当前K线出现买卖点</div>
          <div id="bspPromptBody" class="bspPromptBody"></div>
          <div class="bspPromptHint">只能按 Enter 或左键点击确认，确认前将禁止步进到下一根K线。</div>
          <div class="bspPromptActions">
            <button id="bspPromptConfirm" type="button">确认（Enter / 左键）</button>
          </div>
        </div>
      </div>
      <!-- 交易结算弹窗 -->
      <div id="settlementModal" class="settlementModal" aria-hidden="true">
        <div class="panel">
          <div id="settlementTitle" class="settlementTitle">交易结算</div>
          <div id="settlementBody" class="settlementBody"></div>
          <div class="settlementActions">
            <button id="btnSettlementClose">确 认</button>
          </div>
        </div>
      </div>
      <div id="globalLoading" class="globalLoading" aria-hidden="true">
        <div class="panel">
          <div class="globalLoadingBody">
            <div class="globalLoadingPrimary">
              <div class="loadingMain">
                <div class="spinner"></div>
                <div>
                  <div id="globalLoadingText" class="loadingText">正在加载数据...</div>
                  <div id="globalLoadingEta" class="loadingEta">预计剩余：--</div>
                </div>
              </div>
              <div class="loadingProgressOuter">
                <div id="globalLoadingBar" class="loadingProgressInner">0%</div>
              </div>
            </div>
            <div id="globalLoadingHistory" class="loadingHistorySide"></div>
          </div>
          <div id="globalLoadingActions" class="loadingActions">
            <button id="btnLoadingHistory" type="button">查看历史记录</button>
            <button id="btnPrevLoadingHistory" type="button">上一次记录</button>
            <button id="btnCopyLoadingHistory" type="button">复制进度</button>
            <button id="btnCancelInitLoad" type="button">终止加载</button>
          </div>
        </div>
      </div>

      <!-- 交易状态悬浮窗 -->
      <div id="tradeStatusOverlay" class="tradeStatusOverlay" style="display: none;">
        <div class="tradeStatusTitleBar">
          <div class="tradeStatusTitle"><span class="tradeStatusDot"></span><span>当前持仓状态</span></div>
          <div class="tradeStatusActions">
            <button id="btnTradeStatusMin" class="tradeStatusMiniBtn" type="button">-</button>
            <button id="btnTradeStatusMax" class="tradeStatusMiniBtn" type="button">+</button>
          </div>
        </div>
        <div class="tradeStatusBody">
          <div class="tradeStatusGrid">
            <div class="tsItem"><label>持仓时间</label><span id="ts_hold_bars">-</span></div>
            <div class="tsItem"><label>持仓股数</label><span id="ts_pos">-</span></div>
            <div class="tsItem"><label>买入价格</label><span id="ts_buy_price">-</span></div>
            <div class="tsItem"><label>当前价格</label><span id="ts_curr_price">-</span></div>
            <div class="tsItem"><label>持仓盈亏</label><span id="ts_pnl">-</span></div>
            <div class="tsItem"><label>盈亏比例</label><span id="ts_pnl_pct">-</span></div>
            <div class="tsItem"><label>可用现金</label><span id="ts_cash">-</span></div>
            <div class="tsItem"><label>总资产</label><span id="ts_equity">-</span></div>
            <div class="tsItem"><label>总盈亏</label><span id="ts_total_pnl">-</span></div>
          </div>
        </div>
        <div class="tradeStatusResizeHandle"></div>
      </div>

      <div id="dualChartToolbar" style="position:absolute; top:8px; right:12px; z-index:10; display:none; gap:6px;">
        <button id="btnActiveChart1" style="width:auto; padding:4px 8px;">图1激活</button>
        <button id="btnActiveChart2" style="width:auto; padding:4px 8px;">图2激活</button>
      </div>
      <canvas id="chart"></canvas>
    </div>
  </div>
<script>
const $ = (id) => document.getElementById(id);
function markUiBound(id) {
  const el = $(id);
  if (el) el.dataset.bound = "1";
}
let canvas = $("chart");
let ctx = canvas.getContext("2d");
const rootCanvas = canvas;
const rootCtx = ctx;
function safeJsonParse(raw, fallback) {
  try {
    if (raw === null || raw === undefined || raw === "") return fallback;
    return JSON.parse(raw);
  } catch (_) {
    return fallback;
  }
}

function storageGet(key, fallback = null) {
  try {
    return localStorage.getItem(key);
  } catch (_) {
    return fallback;
  }
}

function storageSet(key, value) {
  try {
    localStorage.setItem(key, value);
    return true;
  } catch (_) {
    return false;
  }
}

function storageRemove(key) {
  try {
    localStorage.removeItem(key);
    return true;
  } catch (_) {
    return false;
  }
}

function ensureObject(v, fallback = {}) {
  return v && typeof v === "object" && !Array.isArray(v) ? v : fallback;
}

function ensureArray(v, fallback = []) {
  return Array.isArray(v) ? v : fallback;
}
let lastPayload = null;
let chipKlineAllCache = null; // 兜底缓存：后续 payload 省略 kline_all 时仍用于筹码分布
let chipKlineAllCacheSessionKey = "";
// #region agent log
const __agentDebugState = { lastByKey: {} };
function __agentDebugLog(hypothesisId, location, message, data, dedupeKey = "", dedupeMs = 500) {
  return;
  try {
    const now = Date.now();
    const key = `${hypothesisId}|${location}|${dedupeKey || message}`;
    const last = Number(__agentDebugState.lastByKey[key] || 0);
    if (now - last < dedupeMs) return;
    __agentDebugState.lastByKey[key] = now;
    const body = {
      sessionId: "cb2ced",
      runId: "post-fix",
      hypothesisId,
      location,
      message,
      data: data || {},
      timestamp: now,
    };
    fetch("/api/_agent_debug_log", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).catch(() => {});
    fetch("http://127.0.0.1:7753/ingest/f371f054-1caf-42ef-b835-583f3f88c3f9", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Debug-Session-Id": "cb2ced" },
      body: JSON.stringify(body),
    }).catch(() => {});
  } catch (_) {}
}
// #endregion
let chipProfileCache = null; // 极速引擎筹码 profile：前端只绘制数组，不再每帧扫历史
let allXMin = 0;
let allXMax = 0;
let viewXMin = 0;
let viewXMax = 0;
let viewReady = false;
let userAdjustedView = false;
let userRays = ensureArray(safeJsonParse(storageGet("chan_user_rays"), []), []);
let userBiRays = ensureArray(safeJsonParse(storageGet("chan_user_bi_rays"), []), []);
let userBiRaysDirty = false;
/** 数量模式射线（锚定原始 K 线时间+OHLC，切换数量 Q 时位置不变） */
const QUANTITY_RAY_STORAGE_KEY = "chan_user_quantity_rays";
let userQuantityRays = ensureArray(safeJsonParse(storageGet(QUANTITY_RAY_STORAGE_KEY), []), []);
let userQuantityRaysDirty = false;
let pendingQuantityRayPts = [];
let quantityDigitBuffer = "";
let quantityDigitBufferTimer = null;
const QUANTITY_DIGIT_BUFFER_MS = 1200;
let pendingBiRayPts = [];
let pendingRatioLinePts = [];
let pendingParallelogramPts = [];
let activeTool = storageGet("chan_active_tool") || "none"; // none | horizontalRay | biRay | ratioLine | parallelogram
let selectedDrawing = null; // { type: "ray"|"biRay", index: number }
let linePropsHighlightUntil = 0;
let hoveredBiRay = null; // { type: "biRay", index: number }
let draggingRatioLine = null; // { index: number, ratio: number }
let chartClickMoved = false;
let chartMouseDownPos = null;

// 比例线默认展示比例（常用回撤档）
const DEFAULT_RATIO_LINE_RATIOS = [0.191, 0.236, 0.382, 0.5, 0.618, 0.782, 0.809];
// 多组比例线自动分配颜色（尽量区分度高）
const RATIO_GROUP_COLORS = [
  "#ef4444", "#f97316", "#eab308", "#22c55e", "#06b6d4",
  "#3b82f6", "#8b5cf6", "#ec4899", "#14b8a6", "#a3e635",
];

function normalizeRatioLineRatios(list) {
  const raw = Array.isArray(list) ? list : DEFAULT_RATIO_LINE_RATIOS;
  const out = [];
  raw.forEach((v) => {
    const n = Number(v);
    if (!Number.isFinite(n)) return;
    if (n <= 0 || n >= 2.5) return;
    const k = Math.round(n * 1000) / 1000;
    if (!out.includes(k)) out.push(k);
  });
  out.sort((a, b) => a - b);
  return out.length > 0 ? out : DEFAULT_RATIO_LINE_RATIOS.slice();
}

function buildRatioGroupId() {
  // 轻量可读：时间戳+随机，避免与旧数据冲突
  return `rg_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function pickNextRatioGroupColor() {
  const used = new Set();
  (userBiRays || []).forEach((r) => {
    if (r && r.kind === "ratioLine" && r.groupColor) used.add(String(r.groupColor));
  });
  for (const c of RATIO_GROUP_COLORS) {
    if (!used.has(c)) return c;
  }
  const groups = new Set();
  (userBiRays || []).forEach((r) => {
    if (r && r.kind === "ratioLine" && r.groupId) groups.add(String(r.groupId));
  });
  const idx = groups.size % Math.max(1, RATIO_GROUP_COLORS.length);
  return RATIO_GROUP_COLORS[idx] || "#f97316";
}

const PAD_L = 64;
const PAD_R = 64;
const PAD_T = 10;
/** 单周期主图底部留白（时间轴、副图、买卖点标签连线锚点） */
const PAD_B_SINGLE = 90;
const PRICE_AXIS_STEP = 0.5;
const WEEKDAY_NAMES = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

let isPanning = false;
let panStartX = 0;
let panStartY = 0;
let panStartViewMin = 0;
let panStartViewMax = 0;
let panStartYShiftRatio = 0;
let viewYShiftRatio = 0;
let viewYZoomRatio = 1.0;

let activeTrade = null;
let tradeHistory = [];
let lastSeenBspKey = new Set();
let bspHistory = [];
let bspHistoryKey = new Set();
let sessionFinished = false;
let stepInFlight = false;
let stepInterruptRequested = false;
let initAbortController = null;
let pendingBspPrompt = null;
let crosshairEnabled = false;
let crosshairX = null;
let crosshairY = null;
let dualInternalRenderDepth = 0;
const DUAL_CHART_IDS = ["chart1", "chart2"];
const dualChartRuntime = {
  chart1: { allXMin: 0, allXMax: 0, viewXMin: 0, viewXMax: 0, viewReady: false, userAdjustedView: false, viewYShiftRatio: 0, viewYZoomRatio: 1, crosshairX: null, crosshairY: null },
  chart2: { allXMin: 0, allXMax: 0, viewXMin: 0, viewXMax: 0, viewReady: false, userAdjustedView: false, viewYShiftRatio: 0, viewYZoomRatio: 1, crosshairX: null, crosshairY: null },
};
let dualActiveChartId = "chart1";
/** 右键锁定后，悬停不再切换激活子图；步进刷新时仍保持该图窗为激活 */
let dualActivePaneLock = false;
let dualLockedChartId = "chart1";
let canvasHovered = false;
let signalHoverBoxes = [];
let legendHoverBox = null;
let legendHoverActive = false;
function getSessionDualLayout() {
  const raw = ($("dualLayout") && $("dualLayout").value) || (sessionConfig && sessionConfig.dualLayout) || "vertical";
  return raw === "horizontal" ? "horizontal" : "vertical";
}

/** 图1占双图可用空间比例（0.22~0.78），来自滑块或 session */
function getDualSplitRatio1() {
  const el = $("dualSplitRatio");
  if (el) {
    const pv = Number(el.value);
    if (Number.isFinite(pv)) return Math.min(0.78, Math.max(0.22, pv / 100));
  }
  const sv = Number(sessionConfig && sessionConfig.dualSplitRatio1);
  if (Number.isFinite(sv)) return Math.min(0.78, Math.max(0.22, sv));
  return 0.5;
}

function getDualPaneRects() {
  const w = Math.max(1, canvas.clientWidth);
  const h = Math.max(1, canvas.clientHeight);
  const gap = 10;
  const r1 = getDualSplitRatio1();
  if (getSessionDualLayout() === "horizontal") {
    const inner = w - gap;
    const w1 = Math.max(80, Math.min(inner - 80, Math.floor(inner * r1)));
    return {
      chart1: { x: 0, y: 0, w: w1, h },
      chart2: { x: w1 + gap, y: 0, w: Math.max(1, inner - w1), h },
    };
  }
  const inner = h - gap;
  const h1 = Math.max(60, Math.min(inner - 60, Math.floor(inner * r1)));
  return {
    chart1: { x: 0, y: 0, w, h: h1 },
    chart2: { x: 0, y: h1 + gap, w, h: Math.max(1, inner - h1) },
  };
}

/** 双周期下某子图在根画布上的 CSS 宽高（与 draw 时子 canvas 一致）；单图返回 null */
function dualPaneCssSize(chartId) {
  if (!isDualRuntimeReady()) return null;
  const id = chartId === "chart2" ? "chart2" : "chart1";
  const p = getDualPaneRects()[id];
  return p && p.w > 0 && p.h > 0 ? { w: p.w, h: p.h } : null;
}

/**
 * toScaler 用的画布 CSS 尺寸：子图内渲染时读当前子 canvas；根画布上交互时用对应当前/指定子窗宽高，
 * 否则左右双图时 plotW 误用整宽会导致十字线隔根跳变。
 */
function scalerCssDimensions(dualChartIdHint) {
  if (typeof dualInternalRenderDepth === "number" && dualInternalRenderDepth > 0) {
    return readCanvasCssSize(canvas);
  }
  if (dualChartIdHint === "chart1" || dualChartIdHint === "chart2") {
    const ph = dualPaneCssSize(dualChartIdHint);
    if (ph) return ph;
  }
  if (isDualRuntimeReady()) {
    const ph = dualPaneCssSize(dualActiveChartId || "chart1");
    if (ph) return ph;
  }
  return readCanvasCssSize(canvas);
}

function resolveDualChartIdFromClient(clientX, clientY) {
  if (!lastPayload || lastPayload.chart_mode !== "dual" || !lastPayload.charts || !lastPayload.charts.chart1 || !lastPayload.charts.chart2) return "chart1";
  const rect = canvas.getBoundingClientRect();
  const px = clientX - rect.left;
  const py = clientY - rect.top;
  const panes = getDualPaneRects();
  const inside = (pane) => px >= pane.x && px <= pane.x + pane.w && py >= pane.y && py <= pane.y + pane.h;
  if (inside(panes.chart2)) return "chart2";
  if (inside(panes.chart1)) return "chart1";
  return dualActiveChartId || "chart1";
}

function getRuntimeState(chartId) {
  return dualChartRuntime[chartId] || dualChartRuntime.chart1;
}

function loadRuntimeState(chartId) {
  const st = getRuntimeState(chartId);
  allXMin = st.allXMin;
  allXMax = st.allXMax;
  viewXMin = st.viewXMin;
  viewXMax = st.viewXMax;
  viewReady = !!st.viewReady;
  userAdjustedView = !!st.userAdjustedView;
  viewYShiftRatio = Number.isFinite(st.viewYShiftRatio) ? st.viewYShiftRatio : 0;
  viewYZoomRatio = Number.isFinite(st.viewYZoomRatio) && st.viewYZoomRatio > 0 ? st.viewYZoomRatio : 1;
  crosshairX = Number.isFinite(st.crosshairX) ? st.crosshairX : null;
  crosshairY = Number.isFinite(st.crosshairY) ? st.crosshairY : null;
}

function saveRuntimeState(chartId) {
  const st = getRuntimeState(chartId);
  st.allXMin = allXMin;
  st.allXMax = allXMax;
  st.viewXMin = viewXMin;
  st.viewXMax = viewXMax;
  st.viewReady = !!viewReady;
  st.userAdjustedView = !!userAdjustedView;
  st.viewYShiftRatio = viewYShiftRatio;
  st.viewYZoomRatio = viewYZoomRatio;
  st.crosshairX = Number.isFinite(crosshairX) ? crosshairX : null;
  st.crosshairY = Number.isFinite(crosshairY) ? crosshairY : null;
}

function setActiveChart(chartId, persist = true) {
  const next = chartId === "chart2" ? "chart2" : "chart1";
  dualActiveChartId = next;
  if (lastPayload && lastPayload.charts && lastPayload.charts[next]) {
    lastPayload.active_chart_id = next;
    lastPayload.chart = lastPayload.charts[next];
  }
  loadRuntimeState(next);
  if (persist) {
    sessionConfig.activeChartId = next;
    saveSessionConfig();
  }
  updateDualModeUI(lastPayload);
}
let selectedMainIndicatorSlot = Number(storageGet("chan_selected_main_indicator_slot") || "0");
/** 图表显示设置级联面板：当前选中的分组 key */
let chartSettingsCascadeSelKey = null;
/** 「级别/中枢/买卖点」组内二级选中（仅 UI 状态，持久化键名不变） */
let chartSettingsBranchChildSel = ensureObject(safeJsonParse(storageGet("chan_chart_settings_branch_sel"), null), {});
/** 打开面板时的快照，关闭未保存时恢复 */
let chartSettingsDraftBaseline = null;
let selectedSubIndicatorSlot = Number(storageGet("chan_selected_sub_indicator_slot") || "0");
let indicatorMainSlots = ensureObject(safeJsonParse(storageGet("chan_indicator_main_slots"), null), null);
let indicatorSubSlots = ensureObject(safeJsonParse(storageGet("chan_indicator_sub_slots"), null), null);
let indicatorMainVarVisible = String(storageGet("chan_indicator_main_var_visible") || "1") !== "0";
let indicatorSubVarVisible = String(storageGet("chan_indicator_sub_var_visible") || "1") !== "0";

const defaultMainSlots = { "0": [], "1": [], "2": [], "3": [], "4": [], "5": [] };
const defaultSubSlots = { "0": [], "1": [], "2": [], "3": [], "4": [], "5": [] };

if (!indicatorMainSlots || !indicatorSubSlots) {
  indicatorMainSlots = { ...defaultMainSlots };
  indicatorSubSlots = { ...defaultSubSlots };
}
if (!Number.isFinite(selectedMainIndicatorSlot) || selectedMainIndicatorSlot < 0 || selectedMainIndicatorSlot > 5) {
  selectedMainIndicatorSlot = 0;
}
if (!Number.isFinite(selectedSubIndicatorSlot) || selectedSubIndicatorSlot < 0 || selectedSubIndicatorSlot > 5) {
  selectedSubIndicatorSlot = 0;
}
storageSet("chan_selected_main_indicator_slot", String(selectedMainIndicatorSlot));
storageSet("chan_selected_sub_indicator_slot", String(selectedSubIndicatorSlot));

// Migration from legacy string-based slots to arrays
for (let i = 0; i <= 5; i++) {
  const mainVal = indicatorMainSlots[String(i)];
  if (typeof mainVal === "string") indicatorMainSlots[String(i)] = (mainVal === "none" || mainVal === "enabled" ? [] : [mainVal]);
  else if (!Array.isArray(mainVal)) indicatorMainSlots[String(i)] = [];

  let v = indicatorSubSlots[String(i)];
  if (typeof v === "string") indicatorSubSlots[String(i)] = (v === "none" ? [] : [v]);
  else if (!Array.isArray(v)) indicatorSubSlots[String(i)] = [];
}

storageSet("chan_indicator_main_slots", JSON.stringify(indicatorMainSlots));
storageSet("chan_indicator_sub_slots", JSON.stringify(indicatorSubSlots));
storageSet("chan_indicator_main_var_visible", indicatorMainVarVisible ? "1" : "0");
storageSet("chan_indicator_sub_var_visible", indicatorSubVarVisible ? "1" : "0");
const MAIN_INDICATORS = new Set(["boll", "demark", "trendline"]);
const SUB_INDICATORS = new Set(["macd", "kdj", "rsi", "vol"]);

const DEFAULT_CHAN_CONFIG = {
  chan_algo: "classic",
  bi_strict: true,
  bi_algo: "normal",
  bi_fx_check: "strict",
  gap_as_kl: false,
  bi_end_is_peak: true,
  bi_allow_sub_peak: true,
  seg_algo: "chan",
  left_seg_method: "peak",
  zs_algo: "normal",
  zs_combine: true,
  zs_combine_mode: "zs",
  one_bi_zs: false,
  trigger_step: true,
  skip_step: 0,
  kl_data_check: true,
  print_warning: false,
  print_err_time: false,
  rhythm_calc_mode: "normal",
  mean_metrics: "",
  trend_metrics: "",
  macd: { fast: 12, slow: 26, signal: 9 },
  demark: {
    demark_len: 9,
    setup_bias: 4,
    countdown_bias: 2,
    max_countdown: 13,
    tiaokong_st: true,
    setup_cmp2close: true,
    countdown_cmp2close: true,
  },
  cal_demark: false,
  cal_rsi: false,
  cal_kdj: false,
  rsi_cycle: 14,
  kdj_cycle: 9,
  boll_n: 20,
  max_kl_misalgin_cnt: 2,
  max_kl_inconsistent_cnt: 5,
  auto_skip_illegal_sub_lv: false,
  // BSP General
  divergence_rate: "inf",
  min_zs_cnt: 1,
  bsp1_only_multibi_zs: true,
  max_bs2_rate: 0.9999,
  macd_algo: "peak",
  bs1_peak: true,
  bs_type: "1,1p,2,2s,3a,3b",
  bsp2_follow_1: true,
  bsp3_follow_1: true,
  bsp3_peak: false,
  bsp2s_follow_2: false,
  max_bsp2s_lv: "",
  strict_bsp3: false,
  bsp3a_max_zs_cnt: 1
};

const DEFAULT_CHART_CONFIG = {
  theme: "light",
  crosshair: { width: 5, color: "#000000", fontSize: 16, enabled: false },
  fx: { width: 1.1, color: "#06b6d4", dashed: true },
  fract: { widthSure: 2.2, widthUnsure: 1.6, color: "#d97706" },
  bi: { widthSure: 3.1, widthUnsure: 2.2, color: "#f59e0b" },
  seg: { widthSure: 4.8, widthUnsure: 3.5, color: "#059669" },
  segseg: { widthSure: 6.0, widthUnsure: 4.6, color: "#2563eb" },
  fractZs: { width: 1.4, color: "#b45309", enabled: true },
  biZs: { width: 1.8, color: "#f59e0b", enabled: true },
  segZs: { width: 2.4, color: "#059669", enabled: true },
  segsegZs: { width: 2.8, color: "#2563eb", enabled: true },
  candle: { width: 1.4, upColor: "#ef4444", downColor: "#22c55e", alpha: 1 },
  bspBi: { enabled: true, fontSize: 14, lineColor: "#94a3b8", lineWidth: 1, lineStyle: "dashed", lineDash: [5, 4], showLowerExtension: true },
  bspSeg: { enabled: true, fontSize: 14, lineColor: "#64748b", lineWidth: 1.1, lineStyle: "dashed", lineDash: [5, 4], showLowerExtension: true },
  bspSegseg: { enabled: true, fontSize: 14, lineColor: "#475569", lineWidth: 1.2, lineStyle: "dashed", lineDash: [5, 4], showLowerExtension: true },
  customSegmentLevels: [],
  rhythmLine: {
    enabled: true,
    fractToBiEnabled: true,
    biToSegEnabled: true,
    segToSegsegEnabled: true,
    maxLayer: 9,
    calcMode: "normal",
    group1LineColor: "#9333ea",
    group1LineWidth: 1.2,
    group1LineStyle: "dashed",
    group1TextColor: "#9333ea",
    group1TextFontSize: 12,
    group1TextFontWeight: "bold",
    group2LineColor: "#0f766e",
    group2LineWidth: 1.6,
    group2LineStyle: "solid",
    group2TextColor: "#0f766e",
    group2TextFontSize: 13,
    group2TextFontWeight: "bold",
    group3LineColor: "#2563eb",
    group3LineWidth: 2.0,
    group3LineStyle: "dashed",
    group3TextColor: "#2563eb",
    group3TextFontSize: 14,
    group3TextFontWeight: "bold",
    group4LineColor: "#ea580c",
    group4LineWidth: 2.4,
    group4LineStyle: "solid",
    group4TextColor: "#ea580c",
    group4TextFontSize: 15,
    group4TextFontWeight: "bold",
    group5LineColor: "#be123c",
    group5LineWidth: 2.8,
    group5LineStyle: "dotted",
    group5TextColor: "#be123c",
    group5TextFontSize: 16,
    group5TextFontWeight: "bold"
  },
  rhythmHit: {
    enabled: true,
    fontSize: 14,
    color: "#7c3aed",
    lineColor: "#8b5cf6",
    lineWidth: 1,
    lineStyle: "dashed",
    overflowLimit: 4,
    overflowColor: "#7c3aed"
  },
  trade: {
    buyColor: "#dc2626",
    sellColor: "#16a34a",
    rangeFillBuy: "#dc2626",
    rangeFillSell: "#16a34a",
    profitBandColor: "#f97316",
    lossBandColor: "#0ea5e9",
    profitColor: "#ef4444",
    lossColor: "#22c55e",
    popupFontSize: 16,
    markerFontSize: 14,
    markerFontWeight: "bold",
    markerLineWidth: 2,
    markerLineStyle: "dashed",
    closeLineWidth: 2,
    buyCloseLineStyle: "solid",
    sellCloseLineStyle: "dashed"
  },
  tradeStatus: {
    titleFontSize: 14,
    titleFontWeight: "bold",
    titleColor: "#0f172a",
    labelFontSize: 12,
    labelFontWeight: "normal",
    labelColor: "#64748b",
    valueFontSize: 13,
    valueFontWeight: "bold",
    valueColor: "#0f172a"
  },
  chip: {
    enabled: true,
    stretchLevel: 5,
    bucketStep: 0.1,
    color: "rgba(59,130,246,0.45)",
    sColor: "rgba(34,197,94,0.78)",
    bColor: "rgba(220,38,38,0.78)",
    peakLineEnabled: true,
    peakRefMode: "latest_visible",
    peakLineColor: "#2563eb",
    peakLineWidth: 1.2,
    peakLineStyle: "dashed"
  },
  xAxis: {
    mode: "manual",
    fontSize: 13,
    rotation: -45,
    fontWeight: "normal",
    interval: 10,
    autoMinFontSize: 10,
    autoMaxFontSize: 14,
    autoDenseRotation: -90,
    autoSparseRotation: -35,
    autoDenseFontWeight: "normal",
    autoSparseFontWeight: "bold",
  },
  yAxis: {
    mode: "manual",
    fontSize: 13,
    fontWeight: "normal",
    interval: 0.5,
    autoMinFontSize: 11,
    autoMaxFontSize: 14,
    autoDenseFontWeight: "normal",
    autoSparseFontWeight: "bold",
    autoMaxDigits: 6,
  },
  klineCombineFrame: {
    enabled: true,
    color: "#6366f1",
    lineWidth: 1.2,
    lineStyle: "solid",
  },
  toast: {
    fontSize: 16,
    fontWeight: "bold",
    speed: 3000,
    showBsp: true,
    showRhythm1382: true,
    showJudge: true,
    interruptOnBsp: true,
    interruptOnRhythm1382: true,
    // 步进中断：BSP 与 1382 之间 OR / AND
    interruptStepSourcesCombine: "or",
    // 细分条件之间 OR / AND（AND=勾选的各档须当根同时命中才停）
    interruptBspFineCombine: "or",
    // 方向例外：无 / 仅买点参与 / 仅卖点参与
    interruptBspSideException: "none",
    // 未覆盖在下方细分表里的类型（如 3a/3b）是否仍参与中断
    interruptBspUnlistedTypes: true,
    // 步进中断细分：级别 + 类型 + 买/卖
    interruptBspBi1Buy: true,
    interruptBspBi1Sell: true,
    interruptBspBi2Buy: true,
    interruptBspBi2Sell: true,
    interruptBspBi2sBuy: true,
    interruptBspBi2sSell: true,
    interruptBspSeg1Buy: true,
    interruptBspSeg1Sell: true,
    interruptBspSeg2Buy: true,
    interruptBspSeg2Sell: true,
    interruptBspSeg2sBuy: true,
    interruptBspSeg2sSell: true,
    interruptBspSegseg1Buy: true,
    interruptBspSegseg1Sell: true,
    interruptBspSegseg2Buy: true,
    interruptBspSegseg2Sell: true,
    interruptBspSegseg2sBuy: true,
    interruptBspSegseg2sSell: true,
  },
  legend: { fontSize: 12, fontWeight: "normal", color: "#0f172a" },
  userRay: { color: "#f97316", width: 1.5, dash: [8, 4], fontSize: 12 },
  // 多周期单图：layers[周期键] 可覆盖粗层蜡烛/影线/缠论线透明度；default* 为各粗周期缺省
  multiOverlay: {
    defaultAlpha: 0.58,
    defaultCandleWidth: 1.2,
    defaultCoarseBodyAlpha: 0.42,
    defaultCoarseUpperShadowAlpha: 0.55,
    defaultCoarseLowerShadowAlpha: 0.55,
    defaultUpperShadowStyle: "grid",
    defaultLowerShadowStyle: "grid",
    layers: {},
  },
};

function customSegLevelNum(level) {
  const text = String(level || "").trim().toLowerCase();
  if (text === "segseg") return 2;
  const m = text.match(/^seg(\d+)$/);
  if (!m) return null;
  const n = Number(m[1]);
  return Number.isFinite(n) && n >= 3 ? Math.floor(n) : null;
}

function segLevelId(num) {
  const n = Math.floor(Number(num));
  return n === 2 ? "segseg" : `seg${n}`;
}

function segLevelLabel(level) {
  const n = customSegLevelNum(level);
  if (n != null) return `${n}段`;
  if (level === "fract") return "分型";
  if (level === "bi") return "笔";
  if (level === "seg") return "段";
  return String(level || "");
}

function segLevelSortOrder(level) {
  const text = String(level || "").trim().toLowerCase();
  if (text === "bi") return 0;
  if (text === "seg") return 1;
  const n = customSegLevelNum(text);
  return n != null ? n : 999;
}

function lineConfigKeyForLevel(level) {
  const n = customSegLevelNum(level);
  return n != null && n >= 3 ? `seg${n}` : String(level || "");
}

function zsConfigKeyForLevel(level) {
  const n = customSegLevelNum(level);
  if (n != null && n >= 3) return `seg${n}Zs`;
  return level === "segseg" ? "segsegZs" : `${level}Zs`;
}

function bspConfigKeyForLevel(level) {
  const n = customSegLevelNum(level);
  if (n != null && n >= 3) return `bspSeg${n}`;
  if (level === "segseg") return "bspSegseg";
  if (level === "seg") return "bspSeg";
  return "bspBi";
}

function customSegmentLevelsFromConfig(cfg = chartConfig) {
  const raw = Array.isArray(cfg && cfg.customSegmentLevels) ? cfg.customSegmentLevels : [];
  const nums = new Set();
  raw.forEach((v) => {
    const n = customSegLevelNum(v);
    if (n != null && n >= 3) nums.add(n);
  });
  return Array.from(nums).sort((a, b) => a - b).map((n) => segLevelId(n));
}

function allBspLevels(cfg = chartConfig) {
  return ["bi", "seg", "segseg", ...customSegmentLevelsFromConfig(cfg)];
}

function allZsLevels(cfg = chartConfig) {
  return ["fract", "bi", "seg", "segseg", ...customSegmentLevelsFromConfig(cfg)];
}

function ensureCustomLevelDefaults(cfg) {
  if (!cfg || typeof cfg !== "object") return cfg;
  const levels = customSegmentLevelsFromConfig(cfg);
  cfg.customSegmentLevels = levels;
  levels.forEach((level) => {
    const n = customSegLevelNum(level);
    const lineKey = lineConfigKeyForLevel(level);
    const zsKey = zsConfigKeyForLevel(level);
    const bspKey = bspConfigKeyForLevel(level);
    if (!cfg[lineKey]) cfg[lineKey] = { widthSure: 5.4 + Math.min(4, (n || 3) - 3) * 0.35, widthUnsure: 4.0, color: "#7c3aed" };
    if (!cfg[zsKey]) cfg[zsKey] = { width: 2.6, color: cfg[lineKey].color || "#7c3aed", enabled: true };
    if (!cfg[bspKey]) cfg[bspKey] = { enabled: true, fontSize: 14, lineColor: "#475569", lineWidth: 1.2, lineStyle: "dashed", lineDash: [5, 4], showLowerExtension: true };
    if (typeof cfg[zsKey].enabled !== "boolean") cfg[zsKey].enabled = true;
    if (typeof cfg[bspKey].enabled !== "boolean") cfg[bspKey].enabled = true;
  });
  return cfg;
}

function addNextCustomSegmentLevel() {
  flushChartSettingsFormToMemory();
  const nums = customSegmentLevelsFromConfig(chartConfig).map((level) => customSegLevelNum(level)).filter((n) => n != null);
  const nextN = nums.length ? Math.max(...nums) + 1 : 3;
  chartConfig.customSegmentLevels = [...customSegmentLevelsFromConfig(chartConfig), segLevelId(nextN)];
  ensureCustomLevelDefaults(chartConfig);
  const key = lineConfigKeyForLevel(segLevelId(nextN));
  chartSettingsBranchChildSel.__branch_level__ = key;
  persistChartSettingsBranchChildSel();
  renderSettingsForm();
}

function deepMerge(target, source) {
  if (!source || typeof source !== "object" || Array.isArray(source)) return target;
  for (const key in source) {
    if (source[key] && typeof source[key] === 'object' && !Array.isArray(source[key])) {
      if (!target[key]) target[key] = {};
      deepMerge(target[key], source[key]);
    } else {
      target[key] = source[key];
    }
  }
  return target;
}

let chanConfig = deepMerge(
  JSON.parse(JSON.stringify(DEFAULT_CHAN_CONFIG)),
  ensureObject(safeJsonParse(storageGet("chan_logic_config"), null), {})
);

function migrateChartConfig(cfg) {
  const next = ensureObject(cfg, {});
  if (next.bsp && !next.bspBi) next.bspBi = JSON.parse(JSON.stringify(next.bsp));
  if (!next.fract) next.fract = {};
  if (!next.segseg) next.segseg = {};
  if (!next.fractZs) next.fractZs = {};
  if (!next.segsegZs) next.segsegZs = {};
  if (!next.bspBi) next.bspBi = {};
  if (!next.bspSeg) next.bspSeg = {};
  if (!next.bspSegseg) next.bspSegseg = {};
  if (!Array.isArray(next.customSegmentLevels)) next.customSegmentLevels = [];
  ensureCustomLevelDefaults(next);
  ["bspBi", "bspSeg", "bspSegseg"].forEach((k) => {
    if (typeof next[k].enabled !== "boolean") next[k].enabled = true;
  });
  if (!next.rhythmLine) next.rhythmLine = {};
  if (!Number.isFinite(Number(next.rhythmLine.maxLayer))) next.rhythmLine.maxLayer = 9;
  next.rhythmLine.maxLayer = Math.max(0, Math.min(9, Math.floor(Number(next.rhythmLine.maxLayer))));
  if (!["normal", "transition", "strict1382"].includes(String(next.rhythmLine.calcMode || ""))) {
    next.rhythmLine.calcMode = "normal";
  }
  if (!next.rhythmHit) next.rhythmHit = {};
  if (typeof next.rhythmHit.enabled !== "boolean") next.rhythmHit.enabled = true;
  if (!next.xAxis) next.xAxis = {};
  if (!next.yAxis) next.yAxis = {};
  if (!next.klineCombineFrame) next.klineCombineFrame = {};
  if (!next.crosshair) next.crosshair = {};
  if (typeof next.crosshair.enabled !== "boolean") next.crosshair.enabled = false;
  if (!next.toast) next.toast = {};
  if (typeof next.toast.showBsp !== "boolean") next.toast.showBsp = true;
  if (typeof next.toast.showRhythm1382 !== "boolean") next.toast.showRhythm1382 = true;
  if (typeof next.toast.showJudge !== "boolean") next.toast.showJudge = true;
  if (typeof next.toast.interruptOnBsp !== "boolean") next.toast.interruptOnBsp = true;
  if (typeof next.toast.interruptOnRhythm1382 !== "boolean") next.toast.interruptOnRhythm1382 = true;
  const legacyBspPairs = [
    ["interruptBspBi1", "interruptBspBi1Buy", "interruptBspBi1Sell"],
    ["interruptBspBi2", "interruptBspBi2Buy", "interruptBspBi2Sell"],
    ["interruptBspBi2s", "interruptBspBi2sBuy", "interruptBspBi2sSell"],
    ["interruptBspSeg1", "interruptBspSeg1Buy", "interruptBspSeg1Sell"],
    ["interruptBspSeg2", "interruptBspSeg2Buy", "interruptBspSeg2Sell"],
    ["interruptBspSeg2s", "interruptBspSeg2sBuy", "interruptBspSeg2sSell"],
    ["interruptBspSegseg1", "interruptBspSegseg1Buy", "interruptBspSegseg1Sell"],
    ["interruptBspSegseg2", "interruptBspSegseg2Buy", "interruptBspSegseg2Sell"],
    ["interruptBspSegseg2s", "interruptBspSegseg2sBuy", "interruptBspSegseg2sSell"],
  ];
  legacyBspPairs.forEach(([legacy, buyK, sellK]) => {
    if (typeof next.toast[buyK] !== "boolean" && typeof next.toast[legacy] === "boolean") {
      next.toast[buyK] = next.toast[legacy];
      next.toast[sellK] = next.toast[legacy];
    }
  });
  if (typeof next.toast.interruptBspBi1Buy !== "boolean") next.toast.interruptBspBi1Buy = true;
  if (typeof next.toast.interruptBspBi1Sell !== "boolean") next.toast.interruptBspBi1Sell = true;
  if (typeof next.toast.interruptBspBi2Buy !== "boolean") next.toast.interruptBspBi2Buy = true;
  if (typeof next.toast.interruptBspBi2Sell !== "boolean") next.toast.interruptBspBi2Sell = true;
  if (typeof next.toast.interruptBspBi2sBuy !== "boolean") next.toast.interruptBspBi2sBuy = true;
  if (typeof next.toast.interruptBspBi2sSell !== "boolean") next.toast.interruptBspBi2sSell = true;
  if (typeof next.toast.interruptBspSeg1Buy !== "boolean") next.toast.interruptBspSeg1Buy = true;
  if (typeof next.toast.interruptBspSeg1Sell !== "boolean") next.toast.interruptBspSeg1Sell = true;
  if (typeof next.toast.interruptBspSeg2Buy !== "boolean") next.toast.interruptBspSeg2Buy = true;
  if (typeof next.toast.interruptBspSeg2Sell !== "boolean") next.toast.interruptBspSeg2Sell = true;
  if (typeof next.toast.interruptBspSeg2sBuy !== "boolean") next.toast.interruptBspSeg2sBuy = true;
  if (typeof next.toast.interruptBspSeg2sSell !== "boolean") next.toast.interruptBspSeg2sSell = true;
  if (typeof next.toast.interruptBspSegseg1Buy !== "boolean") next.toast.interruptBspSegseg1Buy = true;
  if (typeof next.toast.interruptBspSegseg1Sell !== "boolean") next.toast.interruptBspSegseg1Sell = true;
  if (typeof next.toast.interruptBspSegseg2Buy !== "boolean") next.toast.interruptBspSegseg2Buy = true;
  if (typeof next.toast.interruptBspSegseg2Sell !== "boolean") next.toast.interruptBspSegseg2Sell = true;
  if (typeof next.toast.interruptBspSegseg2sBuy !== "boolean") next.toast.interruptBspSegseg2sBuy = true;
  if (typeof next.toast.interruptBspSegseg2sSell !== "boolean") next.toast.interruptBspSegseg2sSell = true;
  if (!next.toast.interruptStepSourcesCombine) next.toast.interruptStepSourcesCombine = "or";
  if (!next.toast.interruptBspFineCombine) next.toast.interruptBspFineCombine = "or";
  if (!next.toast.interruptBspSideException) next.toast.interruptBspSideException = "none";
  if (typeof next.toast.interruptBspUnlistedTypes !== "boolean") next.toast.interruptBspUnlistedTypes = true;
  if (!next.multiOverlay) next.multiOverlay = { defaultAlpha: 0.58, defaultCandleWidth: 1.2, layers: {} };
  if (!next.multiOverlay.layers || typeof next.multiOverlay.layers !== "object") next.multiOverlay.layers = {};
  const da = Number(next.multiOverlay.defaultAlpha);
  next.multiOverlay.defaultAlpha = Number.isFinite(da) ? Math.min(1, Math.max(0.05, da)) : 0.58;
  const dw = Number(next.multiOverlay.defaultCandleWidth);
  next.multiOverlay.defaultCandleWidth = Number.isFinite(dw) ? Math.min(3, Math.max(0.2, dw)) : 1.2;
  const dba = Number(next.multiOverlay.defaultCoarseBodyAlpha);
  next.multiOverlay.defaultCoarseBodyAlpha = Number.isFinite(dba) ? Math.min(1, Math.max(0.05, dba)) : 0.42;
  const dua = Number(next.multiOverlay.defaultCoarseUpperShadowAlpha);
  next.multiOverlay.defaultCoarseUpperShadowAlpha = Number.isFinite(dua) ? Math.min(1, Math.max(0.05, dua)) : 0.55;
  const dla = Number(next.multiOverlay.defaultCoarseLowerShadowAlpha);
  next.multiOverlay.defaultCoarseLowerShadowAlpha = Number.isFinite(dla) ? Math.min(1, Math.max(0.05, dla)) : 0.55;
  if (!next.multiOverlay.defaultUpperShadowStyle) next.multiOverlay.defaultUpperShadowStyle = "grid";
  if (!next.multiOverlay.defaultLowerShadowStyle) next.multiOverlay.defaultLowerShadowStyle = "grid";
  const styOk = new Set(["grid", "dots", "hatch", "shade", "soft"]);
  if (!styOk.has(String(next.multiOverlay.defaultUpperShadowStyle || "").toLowerCase())) next.multiOverlay.defaultUpperShadowStyle = "grid";
  if (!styOk.has(String(next.multiOverlay.defaultLowerShadowStyle || "").toLowerCase())) next.multiOverlay.defaultLowerShadowStyle = "grid";
  if (next.multiOverlay.layers && typeof next.multiOverlay.layers === "object") {
    Object.keys(next.multiOverlay.layers).forEach((kt) => {
      const L = next.multiOverlay.layers[kt];
      if (!L || typeof L !== "object") return;
      if (L.lineAlpha == null && L.alpha != null) L.lineAlpha = L.alpha;
      if (L.bodyAlpha == null && L.alpha != null) L.bodyAlpha = Math.min(1, Math.max(0.05, Number(L.alpha) * 0.88));
      if (L.upperShadowAlpha == null && L.alpha != null) L.upperShadowAlpha = L.alpha;
      if (L.lowerShadowAlpha == null && L.alpha != null) L.lowerShadowAlpha = L.alpha;
    });
  }
  if (!next.candle || typeof next.candle.alpha !== "number" || !Number.isFinite(next.candle.alpha)) {
    if (!next.candle) next.candle = {};
    next.candle.alpha = 1;
  } else {
    next.candle.alpha = Math.min(1, Math.max(0.05, Number(next.candle.alpha)));
  }
  return next;
}

let savedChartConfig = ensureObject(safeJsonParse(storageGet("chan_chart_config"), {}), {});
/** 多周期单图：各 API 周期键一套「缠论线样式」局部配置（与 chart1/chart2 主配置并列持久化） */
function cloneMultiPerKFromRaw(raw) {
  const mp = ensureObject(raw.multiPerK, {});
  const out = {};
  Object.keys(mp).forEach((kt) => {
    out[kt] = JSON.parse(JSON.stringify(ensureObject(mp[kt], {})));
  });
  return out;
}
function buildChartConfigStore(rawCfg) {
  const raw = ensureObject(rawCfg, {});
  // 兼容旧版：旧版直接是单套配置
  if (!raw.shared || !raw.perChart) {
    const migratedSingle = deepMerge(JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG)), migrateChartConfig(raw));
    return {
      shared: {
        mode: "single",
        theme: migratedSingle.theme,
        crosshair: JSON.parse(JSON.stringify(migratedSingle.crosshair || {})),
        // K 线主图底部买卖点总标注（单周期/双周期共用，存于 shared）
        showBottomBsp: typeof raw.showBottomBsp === "boolean" ? raw.showBottomBsp : true,
      },
      perChart: {
        chart1: migratedSingle,
        chart2: deepMerge(JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG)), migrateChartConfig(raw)),
      },
      multiPerK: cloneMultiPerKFromRaw(raw),
    };
  }
  const shared = ensureObject(raw.shared, {});
  const perChart = ensureObject(raw.perChart, {});
  return {
    shared: {
      mode: String(shared.mode || "single"),
      theme: String(shared.theme || "light"),
      crosshair: deepMerge(JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG.crosshair)), ensureObject(shared.crosshair, {})),
      showBottomBsp: typeof shared.showBottomBsp === "boolean" ? shared.showBottomBsp : true,
    },
    perChart: {
      chart1: deepMerge(JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG)), migrateChartConfig(ensureObject(perChart.chart1, {}))),
      chart2: deepMerge(JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG)), migrateChartConfig(ensureObject(perChart.chart2, {}))),
    },
    multiPerK: cloneMultiPerKFromRaw(raw),
  };
}
let chartConfigStore = buildChartConfigStore(savedChartConfig);
let chartConfig = chartConfigStore.perChart.chart1;

function syncCrosshairEnabledFromStore() {
  const sh = chartConfigStore.shared && chartConfigStore.shared.crosshair;
  if (sh && typeof sh.enabled === "boolean") crosshairEnabled = !!sh.enabled;
  else if (chartConfig.crosshair && typeof chartConfig.crosshair.enabled === "boolean") {
    crosshairEnabled = !!chartConfig.crosshair.enabled;
  }
}

function persistCrosshairEnabledToStore() {
  if (!chartConfig.crosshair) chartConfig.crosshair = {};
  chartConfig.crosshair.enabled = !!crosshairEnabled;
  if (!chartConfigStore.shared.crosshair) chartConfigStore.shared.crosshair = {};
  chartConfigStore.shared.crosshair.enabled = !!crosshairEnabled;
  storageSet("chan_chart_config", JSON.stringify(chartConfigStore));
}

syncCrosshairEnabledFromStore();
/** 多周期叠层绘制时临时覆盖的样式对象（与 chartConfig 结构一致） */
let drawStyleCtx = null;
function activeDrawStyle() {
  return drawStyleCtx || chartConfig;
}
/** 合并默认 + 持久化 multiPerK[kt]；合并 K 线框开关/样式跟主图 chartConfig（避免叠层默认强制启用线框） */
function getMultiLayerDrawConfig(kt) {
  const base = JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG));
  base.customSegmentLevels = customSegmentLevelsFromConfig(chartConfig);
  ensureCustomLevelDefaults(base);
  const raw = (chartConfigStore.multiPerK && chartConfigStore.multiPerK[kt]) || {};
  const merged = deepMerge(base, JSON.parse(JSON.stringify(raw)));
  customSegmentLevelsFromConfig(chartConfig).forEach((level) => {
    [lineConfigKeyForLevel(level), zsConfigKeyForLevel(level), bspConfigKeyForLevel(level)].forEach((key) => {
      if (chartConfig[key] && !raw[key]) merged[key] = JSON.parse(JSON.stringify(chartConfig[key]));
    });
  });
  merged.klineCombineFrame = deepMerge(
    JSON.parse(JSON.stringify(merged.klineCombineFrame || {})),
    JSON.parse(JSON.stringify(chartConfig.klineCombineFrame || {}))
  );
  return merged;
}
const DATA_FORM_DEFAULT = {
  mode: "traditional",
  quantity: 1,
  quantityAlloc: "front",
  feedMode: "step",
  klinePresentation: "step",
  offlineDataCustom: "native",
};
let dataFormConfig = { ...DATA_FORM_DEFAULT };

const OFFLINE_DATA_CUSTOM_HELP =
  "【离线数据自定义】\n" +
  "原生：分笔按文件原样解析（无 B/S 标记行默认按 B 处理）。\n" +
  "无BS向上或向下合并：\n" +
  "1) 按每个交易日独立处理，不跨交易日合并。\n" +
  "2) 当天开盘侧连续无 B/S（例 09:25）→ 成交量累加到当天下一根有 B/S 或常规成交行（例 09:30）；\n" +
  "   价格若在目标高低之间则不改价，低于最低价则扩低，高于最高价则扩高。\n" +
  "3) 当天收盘侧连续无 B/S（例 15:00–15:07 多根）→ 向上合并到当天上一根有 B/S（例 14:57），价格规则同上。\n" +
  "4) 当天中间仍无 B/S 的分笔不做头尾合并，保留并默认按 B 处理。\n" +
  "5) 分笔价格合成传统/数量模式下，该设置会影响 K线、VOL、筹码分布；保存后会重新加载分笔并重算。";

function normalizeOfflineDataCustom(mode) {
  const m = String(mode || "native").toLowerCase();
  if (m === "merge_no_bs" || m === "merge" || m === "无bs" || m.includes("合并")) return "merge_no_bs";
  return "native";
}

function offlineDataCustomLabel(mode) {
  return normalizeOfflineDataCustom(mode) === "merge_no_bs" ? "无BS向上或者向下合并" : "原生";
}

function normalizeDataFormQuantityAlloc(alloc) {
  const m = String(alloc || "front").toLowerCase();
  return m === "back" || m === "靠后" || m === "靠后分配" ? "back" : "front";
}

function normalizeKlinePresentationMode(mode) {
  const m = String(mode || "step").toLowerCase();
  return m === "instant" || m === "oneshot" || m === "一次性" || m === "一次性呈现" ? "instant" : "step";
}

function normalizeDataFormMode(mode) {
  const m = String(mode || "traditional").toLowerCase();
  const allow = new Set(["traditional", "quantity", "tick_traditional", "tick_quantity"]);
  return allow.has(m) ? m : "traditional";
}

function normalizeDataFeedMode(mode) {
  const m = String(mode || "step").toLowerCase();
  return m === "unified" ? "unified" : "step";
}

function isQuantityDataFormMode(mode) {
  const m = normalizeDataFormMode(mode);
  return m === "quantity" || m === "tick_quantity";
}

function getRawKlineCount() {
  const n = Number(lastPayload && lastPayload.data_form ? lastPayload.data_form.raw_count : 0);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
}

function clampDataFormQuantity(rawVal, fallback = null) {
  const n = getRawKlineCount();
  const base = Number.isFinite(fallback) && fallback > 0 ? Math.floor(fallback) : (n > 0 ? n : 1);
  let q = parseInt(rawVal, 10);
  if (!Number.isFinite(q)) q = base;
  if (n > 0) {
    if (q < 1) q = 1;
    if (q > n) q = n;
  } else if (q < 1) {
    q = 1;
  }
  return q;
}

/** 单品种单周期 + 数量类数据形式 */
function isSingleQuantityRayMode() {
  if (!lastPayload || !lastPayload.ready) return false;
  const cm = $("chartMode") ? String($("chartMode").value || "single") : "single";
  return cm === "single" && isQuantityDataFormMode(dataFormConfig.mode);
}

function getActiveSessionCode() {
  return String((lastPayload && lastPayload.code) || sessionConfig.code || "").trim();
}

function quantityRaysForActiveSession() {
  const code = getActiveSessionCode();
  if (!code) return userQuantityRays || [];
  return (userQuantityRays || []).filter((r) => !r.code || String(r.code) === code);
}

function snapPriceToKlineOhlc(k, rawPrice) {
  if (!k) return { field: "c", y: rawPrice };
  const candidates = [
    { field: "o", v: Number(k.o) },
    { field: "h", v: Number(k.h) },
    { field: "l", v: Number(k.l) },
    { field: "c", v: Number(k.c) },
  ].filter((c) => Number.isFinite(c.v));
  if (candidates.length === 0) return { field: "c", y: rawPrice };
  let best = candidates[0];
  let bestD = Math.abs(best.v - rawPrice);
  for (let i = 1; i < candidates.length; i++) {
    const d = Math.abs(candidates[i].v - rawPrice);
    if (d < bestD) {
      best = candidates[i];
      bestD = d;
    }
  }
  return { field: best.field, y: best.v };
}

/** 数量射线锚点：按锚点保存的时间 t，映射到当前数量聚合后的 K 线（桶末时刻区间） */
function findDisplayKlineForRawTime(chart, rawTimeStr) {
  const dk = chart && chart.kline ? chart.kline : [];
  if (!dk.length) return null;
  const rawT = String(rawTimeStr || "").trim();
  if (!rawT) return dk[dk.length - 1];
  const rawCmp = chipTimeComparable(rawT);
  if (rawCmp == null) {
    for (const k of dk) {
      if (String(k.t || "").trim() === rawT) return k;
    }
    return dk[dk.length - 1];
  }
  for (let i = 0; i < dk.length; i++) {
    const curCmp = chipTimeComparable(String(dk[i].t || ""));
    if (curCmp == null) continue;
    const prevCmp = i > 0 ? chipTimeComparable(String(dk[i - 1].t || "")) : null;
    if (prevCmp == null && rawCmp <= curCmp) return dk[i];
    if (prevCmp != null && rawCmp > prevCmp && rawCmp <= curCmp) return dk[i];
    if (curCmp === rawCmp) return dk[i];
  }
  const lastCmp = chipTimeComparable(String(dk[dk.length - 1].t || ""));
  if (lastCmp != null && rawCmp > lastCmp) return dk[dk.length - 1];
  return dk[0];
}

function resolveQuantityRayAnchor(chart, anchor) {
  if (!chart || !anchor) return null;
  const y = Number(anchor.y);
  if (!Number.isFinite(y)) return null;
  const displayK = findDisplayKlineForRawTime(chart, anchor.t);
  if (!displayK || !Number.isFinite(Number(displayK.x))) return null;
  return { x: Number(displayK.x), y };
}

function parseSessionDateToComparableMs(dateStr, endOfDay) {
  const s = String(dateStr || "").trim();
  if (!s) return null;
  const cmp = chipTimeComparable(s.replace(/\//g, "-"));
  if (cmp != null) return cmp;
  const m = s.match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})/);
  if (!m) return null;
  const y = +m[1], mo = +m[2], d = +m[3];
  if (endOfDay) return Date.UTC(y, mo - 1, d, 23, 59, 59);
  return Date.UTC(y, mo - 1, d, 0, 0, 0);
}

function getCurrentSessionRangeMs() {
  const beginStr = $("begin") ? $("begin").value : sessionConfig.begin;
  const endStr = $("end") && $("end").value ? $("end").value : sessionConfig.end;
  let beginMs = parseSessionDateToComparableMs(beginStr, false);
  let endMs = parseSessionDateToComparableMs(endStr, true);
  if (beginMs == null) beginMs = parseSessionDateToComparableMs("1990-01-01", false);
  if (endMs == null) {
    const now = new Date();
    endMs = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), 23, 59, 59);
  }
  if (endMs < beginMs) endMs = beginMs;
  return { beginMs, endMs, beginStr: String(beginStr || ""), endStr: String(endStr || "") };
}

function raySavedSessionRangeMs(r) {
  let beginMs = parseSessionDateToComparableMs(r.sessionBegin, false);
  let endMs = parseSessionDateToComparableMs(r.sessionEnd, true);
  if (beginMs == null && r.p1 && r.p2) {
    const t1 = chipTimeComparable(r.p1.t);
    const t2 = chipTimeComparable(r.p2.t);
    if (t1 != null && t2 != null) {
      beginMs = Math.min(t1, t2);
      endMs = Math.max(t1, t2);
    }
  }
  if (beginMs == null) beginMs = parseSessionDateToComparableMs("1990-01-01", false);
  if (endMs == null) endMs = parseSessionDateToComparableMs("2099-12-31", true);
  return { beginMs, endMs };
}

function sessionRangeContains(outer, inner) {
  return outer.beginMs <= inner.beginMs && inner.endMs <= outer.endMs;
}

/** 时间-价格斜率 k：切换数量时保持不变（不随 K 线索引 x 变化） */
function quantityRayTimePriceK(r) {
  const t1 = chipTimeComparable(r.p1.t);
  const t2 = chipTimeComparable(r.p2.t);
  const y1 = Number(r.p1.y);
  const y2 = Number(r.p2.y);
  if (t1 == null || t2 == null || !Number.isFinite(y1) || !Number.isFinite(y2)) return null;
  const dt = t2 - t1;
  if (Math.abs(dt) < 1) return null;
  return { t1, y1, k: (y2 - y1) / dt };
}

function quantityRayPriceAt(tp, tMs) {
  return tp.y1 + tp.k * (tMs - tp.t1);
}

function chartPointAtTimeMs(chart, tp, tMs) {
  const ks = chart.kline || [];
  if (!ks.length) return null;
  let best = ks[ks.length - 1];
  for (let i = 0; i < ks.length; i++) {
    const c = chipTimeComparable(String(ks[i].t || ""));
    if (c == null) continue;
    const prev = i > 0 ? chipTimeComparable(String(ks[i - 1].t || "")) : null;
    if (prev == null && tMs <= c) {
      best = ks[i];
      break;
    }
    if (prev != null && tMs > prev && tMs <= c) {
      best = ks[i];
      break;
    }
    if (c === tMs) {
      best = ks[i];
      break;
    }
  }
  const y = quantityRayPriceAt(tp, tMs);
  const x = Number(best.x);
  if (!Number.isFinite(x)) return null;
  return { x, y, tMs };
}

function chartPointAtTimeStr(chart, tp, tStr) {
  const tMs = chipTimeComparable(tStr);
  if (tMs == null) return null;
  return chartPointAtTimeMs(chart, tp, tMs);
}

function quantityRayRightEnd(chart, s, tp) {
  const ks = chart.kline || [];
  if (!ks.length) return null;
  const last = ks[ks.length - 1];
  const tEnd = chipTimeComparable(String(last.t || ""));
  if (tEnd == null) return null;
  const y = quantityRayPriceAt(tp, tEnd);
  const px = s.x(s.xMax);
  const py = s.y(y);
  if (!Number.isFinite(px) || !Number.isFinite(py)) return null;
  return { x: s.xMax, y, tMs: tEnd, px, py };
}

function resolveQuantityRayDrawSpec(chart, s, r) {
  const tp = quantityRayTimePriceK(r);
  if (!tp) return null;
  const p1d = chartPointAtTimeStr(chart, tp, r.p1.t);
  const p2d = chartPointAtTimeStr(chart, tp, r.p2.t);
  const right = quantityRayRightEnd(chart, s, tp);
  if (!p1d || !right) return null;
  const current = getCurrentSessionRangeMs();
  const saved = raySavedSessionRangeMs(r);
  const contained = sessionRangeContains(current, saved);
  const segments = [];
  const tRay0 = tp.t1;
  const tEnd = right.tMs;
  if (!contained) {
    segments.push({ from: p1d, to: right, dashed: true });
    return { tp, p1d, p2d, right, contained, segments, allDashed: true };
  }
  const tSolidStart = Math.max(tRay0, saved.beginMs);
  const tSolidEnd = Math.min(saved.endMs, tEnd);
  if (tRay0 < saved.beginMs) {
    const ptA0 = chartPointAtTimeMs(chart, tp, saved.beginMs);
    if (ptA0) segments.push({ from: p1d, to: ptA0, dashed: true });
  }
  if (tSolidEnd > tSolidStart + 1) {
    const ptS0 = chartPointAtTimeMs(chart, tp, tSolidStart);
    const ptS1 = chartPointAtTimeMs(chart, tp, tSolidEnd);
    if (ptS0 && ptS1) segments.push({ from: ptS0, to: ptS1, dashed: false });
  }
  if (saved.endMs < tEnd - 1) {
    const ptAe = chartPointAtTimeMs(chart, tp, saved.endMs);
    if (ptAe) segments.push({ from: ptAe, to: right, dashed: true });
  } else if (tRay0 > saved.endMs) {
    segments.push({ from: p1d, to: right, dashed: true });
  }
  if (segments.length === 0) segments.push({ from: p1d, to: right, dashed: false });
  return { tp, p1d, p2d, right, contained, segments, allDashed: false };
}

function distPointToSegmentPx(px, py, x0, y0, x1, y1) {
  const dx = x1 - x0;
  const dy = y1 - y0;
  const len2 = dx * dx + dy * dy;
  if (len2 < 1e-6) return Math.hypot(px - x0, py - y0);
  let t = ((px - x0) * dx + (py - y0) * dy) / len2;
  t = Math.max(0, Math.min(1, t));
  const qx = x0 + t * dx;
  const qy = y0 + t * dy;
  return Math.hypot(px - qx, py - qy);
}

function hitTestQuantityRayPx(chart, s, r, xp, yp, threshold) {
  const spec = resolveQuantityRayDrawSpec(chart, s, r);
  if (!spec || !spec.segments) return false;
  for (const seg of spec.segments) {
    const x0 = s.x(seg.from.x);
    const y0 = s.y(seg.from.y);
    const x1 = seg.to.px != null ? seg.to.px : s.x(seg.to.x);
    const y1 = seg.to.py != null ? seg.to.py : s.y(seg.to.y);
    if (distPointToSegmentPx(xp, yp, x0, y0, x1, y1) <= threshold) return true;
  }
  return false;
}

function buildQuantityRayAnchor(chart, s, px, py) {
  const visibleKs = getVisibleKs(chart, s.xMin, s.xMax);
  const xVal = xFromPx(s, px);
  const refK = nearestKByX(visibleKs, xVal);
  if (!refK) return null;
  const rawPrice = s.yFromPx(py);
  const snapped = snapPriceToKlineOhlc(refK, rawPrice);
  const rawK = mapChartBarToKsAll(refK, getChipBaseKs(chart)) || refK;
  return {
    t: String(rawK.t || refK.t || ""),
    ohlc: snapped.field,
    y: snapped.y,
    code: getActiveSessionCode(),
  };
}

function persistUserQuantityRaysNow() {
  storageSet(QUANTITY_RAY_STORAGE_KEY, JSON.stringify(userQuantityRays));
  userQuantityRaysDirty = false;
}

async function applyQuantityFromKeyboard(rawQ) {
  if (!isSingleQuantityRayMode() || stepInFlight) return;
  const n = getRawKlineCount();
  if (n <= 0) {
    setMsg("请先加载会话后再使用数量模式。");
    return;
  }
  const nextQ = clampDataFormQuantity(rawQ, n);
  if (nextQ === dataFormConfig.quantity) return;
  dataFormConfig.quantity = nextQ;
  sessionConfig.dataFormQuantity = nextQ;
  saveSessionConfig();
  const ctl = prepareCancelableLoading("正在按新数量重算K线…", `数量切换：准备重算为 ${nextQ} 根…`);
  try {
    const payload = await api("/api/reconfig", {
      chan_config: chanConfig,
      data_form_mode: dataFormConfig.mode,
      data_form_quantity: nextQ,
      data_form_quantity_alloc: normalizeDataFormQuantityAlloc(dataFormConfig.quantityAlloc),
      data_feed_mode: normalizeDataFeedMode(dataFormConfig.feedMode),
      offline_data_custom: normalizeOfflineDataCustom(dataFormConfig.offlineDataCustom),
      kline_presentation_mode: normalizeKlinePresentationMode(dataFormConfig.klinePresentation),
      rollback_cache_depth: Number(systemConfig.rollbackCacheDepth || DEFAULT_SYSTEM_CONFIG.rollbackCacheDepth),
      rollback_full_snapshot_interval: Number(systemConfig.rollbackFullSnapshotInterval || DEFAULT_SYSTEM_CONFIG.rollbackFullSnapshotInterval),
      rollback_capture_max_bars: Number(systemConfig.rollbackCaptureMaxBars || DEFAULT_SYSTEM_CONFIG.rollbackCaptureMaxBars),
    }, "POST", { signal: ctl.signal });
    refreshUI(payload, { afterStep: false });
    void fetchChipKlineAllLazy(payload);
    setMsg(`数量已设为 ${nextQ}（原始 K 线共 ${n} 根）`);
  } catch (e) {
    if (e && (e.name === "AbortError" || String(e.message || "").indexOf("终止") >= 0 || Number(e.httpStatus) === 499)) {
      setMsg("已终止数量切换重算。");
    } else {
      setMsg("数量切换失败：" + (e && e.message ? e.message : e));
    }
  } finally {
    finishCancelableLoading(false);
  }
}

function scheduleQuantityDigitApply() {
  if (quantityDigitBufferTimer) clearTimeout(quantityDigitBufferTimer);
  quantityDigitBufferTimer = setTimeout(() => {
    quantityDigitBufferTimer = null;
    const buf = quantityDigitBuffer;
    quantityDigitBuffer = "";
    if (!buf) return;
    applyQuantityFromKeyboard(parseInt(buf, 10));
  }, QUANTITY_DIGIT_BUFFER_MS);
}

function pushQuantityDigitKey(digit) {
  quantityDigitBuffer = `${quantityDigitBuffer}${digit}`.replace(/^0+(\d)/, "$1");
  const n = getRawKlineCount();
  const maxLen = n > 0 ? String(n).length : 6;
  if (quantityDigitBuffer.length > maxLen) {
    quantityDigitBuffer = quantityDigitBuffer.slice(-maxLen);
  }
  const preview = clampDataFormQuantity(parseInt(quantityDigitBuffer, 10), n || 1);
  setMsg(`数量输入: ${quantityDigitBuffer} → ${preview}（${QUANTITY_DIGIT_BUFFER_MS / 1000}s 无输入自动应用，Enter 立即应用）`, true);
  scheduleQuantityDigitApply();
}

const DEFAULT_SESSION_CONFIG = {
  code: "600340",
  begin: "2018-01-01",
  end: "",
  cash: "10000",
  autype: "qfq",
  theme: "light",
  chipEnabled: true,
  chipStretchLevel: "5",
  chipBucketStep: "0.1",
  fractZsEnabled: true,
  biZsEnabled: true,
  segZsEnabled: true,
  segsegZsEnabled: true,
  stepN: "5",
  kType: "daily",
  chartMode: "single",
  kTypesMulti: ["1min", "3min"],
  multiLayerHidden: [],
  kType2: "weekly",
  dualLayout: "vertical",
  dualSplitRatio1: 0.5,
  activeChartId: "chart1",
  dataFormMode: "traditional",
  dataFormQuantity: 1,
  dataFormQuantityAlloc: "front",
  dataFeedMode: "step",
  klinePresentationMode: "step",
};
let sessionConfig = ensureObject(
  safeJsonParse(storageGet("chan_session_config"), JSON.parse(JSON.stringify(DEFAULT_SESSION_CONFIG))),
  JSON.parse(JSON.stringify(DEFAULT_SESSION_CONFIG))
);

const SHORTCUT_ACTIONS = [
  { id: "openChanSettings", label: "打开缠论配置", description: "打开缠论逻辑配置面板。", defaults: ["l"], contexts: ["global"], buttonId: "btnChanSettingsOpen" },
  { id: "openChartSettings", label: "打开图表显示设置", description: "打开图表显示设置面板。", defaults: ["p"], contexts: ["global"], buttonId: "btnSettingsOpen" },
  { id: "openSystemSettings", label: "打开系统配置", description: "打开系统配置面板。", defaults: ["shift+p"], contexts: ["global"], buttonId: "btnSystemSettingsOpen" },
  { id: "toggleFullscreen", label: "切换全屏显示", description: "切换右侧图表区域全屏显示。", defaults: ["f11"], contexts: ["global"], buttonId: "btnFullscreen" },
  { id: "initSession", label: "加载会话", description: "根据当前代码、日期区间和初始资金加载复盘会话。", defaults: ["ctrl+i"], contexts: ["global"], buttonId: "btnInit" },
  { id: "resetSession", label: "重新训练", description: "清空当前会话并恢复到可重新配置的初始状态。", defaults: ["ctrl+r"], contexts: ["global"], buttonId: "btnReset" },
  { id: "prevBar", label: "回退一根K线", description: "重建到上一根 K 线（与后退 N 根 N=1 相同）。", defaults: ["shift+space"], contexts: ["global"], buttonId: "btnStepPrev" },
  { id: "nextBar", label: "步进到下一根K线", description: "步进到下一根 K 线；若当前 K 线命中买卖点（1/1p/2/2s/3a/3b）或 1382，会合并为一个弹窗提示。", defaults: ["space"], contexts: ["global"], buttonId: "btnStep" },
  { id: "stepForwardN", label: "步进 N 根", description: "按步进数量 N 连续推进，遇到买卖点（1/1p/2/2s/3a/3b）或 1382 可按设置自动停止，并合并当根提示。", defaults: ["ctrl+alt+n"], contexts: ["global"], buttonId: "btnStepN" },
  { id: "interruptStepForward", label: "中断连续步进", description: "连续步进过程中请求中断，将在当前根处理完成后停止。", defaults: ["ctrl+alt+x"], contexts: ["global"], buttonId: "btnStepInterrupt" },
  { id: "stepBackwardN", label: "后退 N 根", description: "按步进数量 N 回退，会自动重建到更早状态。", defaults: ["ctrl+alt+m"], contexts: ["global"], buttonId: "btnBackN" },
  { id: "buyAll", label: "买入（全仓）", description: "按当前收盘价使用全部可用现金买入。", defaults: ["pageup"], contexts: ["global"], buttonId: "btnBuy" },
  { id: "sellAll", label: "卖出（全量）", description: "按当前收盘价全部卖出。", defaults: ["pagedown"], contexts: ["global"], buttonId: "btnSell" },
  { id: "shortAll", label: "做空（全仓）", description: "按当前收盘价使用全部可用现金做空。", defaults: [], contexts: ["global"], buttonId: "btnShort" },
  { id: "coverAll", label: "平空（全量）", description: "按当前收盘价全部平空。", defaults: [], contexts: ["global"], buttonId: "btnCover" },
  { id: "centerLatest", label: "居中到最新K线", description: "将视图快速居中到最新一根 K 线。", defaults: ["c", "center"], contexts: ["global"] },
  { id: "drawHorizontalRay", label: "生成水平射线", description: "在当前十字光标价位生成一条水平射线。", defaults: ["ctrl+enter"], contexts: ["global"] },
  { id: "zoomYIn", label: "纵向放大", description: "放大图表纵轴缩放比例。", defaults: ["ctrl+alt+arrowup"], contexts: ["global"] },
  { id: "zoomYOut", label: "纵向缩小", description: "缩小图表纵轴缩放比例。", defaults: ["ctrl+alt+arrowdown"], contexts: ["global"] },
  { id: "zoomXIn", label: "横向放大", description: "放大图表横轴缩放比例。", defaults: ["ctrl+alt+arrowleft"], contexts: ["global"] },
  { id: "zoomXOut", label: "横向缩小", description: "缩小图表横轴缩放比例。", defaults: ["ctrl+alt+arrowright"], contexts: ["global"] },
  { id: "adjustCrosshairUp", label: "十字光标价格上移", description: "将十字光标对应价格向上微调。", defaults: ["ctrl+arrowup"], contexts: ["global"] },
  { id: "adjustCrosshairDown", label: "十字光标价格下移", description: "将十字光标对应价格向下微调。", defaults: ["ctrl+arrowdown"], contexts: ["global"] },
  { id: "saveChanSettings", label: "保存缠论配置", description: "在缠论配置面板中保存并立即应用配置。", defaults: ["s"], contexts: ["chanSettings"], buttonId: "btnChanSettingsSave" },
  { id: "saveChartSettings", label: "保存图表显示设置", description: "在图表显示设置面板中保存并立即应用配置。", defaults: ["s"], contexts: ["chartSettings"], buttonId: "btnSettingsSave" },
  { id: "saveSystemSettings", label: "保存系统配置", description: "在系统配置面板中保存并立即应用快捷键设置。", defaults: ["s"], contexts: ["systemSettings"], buttonId: "btnSystemSettingsSave" },
  { id: "confirmBspPrompt", label: "确认买卖点提示", description: "确认当前买卖点提示并允许继续步进。", defaults: ["enter"], contexts: ["bspPrompt"], buttonId: "bspPromptConfirm" },
  { id: "closeSettlement", label: "关闭交易结算", description: "关闭当前交易结算弹窗。", defaults: ["enter"], contexts: ["settlement"], buttonId: "btnSettlementClose" },
  { id: "setBspJudgeAuto", label: "买卖点判定：自动", description: "将笔/段/2段买卖点 ×/✓ 判定方式切换为自动（按上一级结构变向自动判定）。", defaults: ["z"], contexts: ["global"] },
  { id: "setBspJudgeManual", label: "买卖点判定：手动", description: "将笔/段/2段买卖点 ×/✓ 判定方式切换为手动（需点击按钮/快捷键手动检查）。", defaults: ["s"], contexts: ["global"] },
  { id: "checkBspJudge", label: "检查买卖点（手动）", description: "在手动模式下触发一次笔/段/2段买卖点 ×/✓ 判定检查。", defaults: ["j"], contexts: ["global"], buttonId: "btnJudgeBsp" },
];

const SHORTCUT_ACTION_MAP = SHORTCUT_ACTIONS.reduce((acc, action) => {
  acc[action.id] = action;
  return acc;
}, {});

const DEFAULT_SYSTEM_CONFIG = {
  bspJudgeMode: "auto",
  shortcuts: SHORTCUT_ACTIONS.reduce((acc, action) => {
    acc[action.id] = action.defaults.slice();
    return acc;
  }, {}),
  // 固定使用 a_Data 离线分笔，加载时重新计算，不走历史缓存。
  dataSourcePriority: ["离线数据"],
  // 回退缓存（以内存换速度）
  rollbackCacheDepth: 96,
  rollbackFullSnapshotInterval: 8,
  rollbackCaptureMaxBars: 30000,
  chanRecordEnabled: false,
  // 性能引擎：rust_auto=严格 Rust；python_legacy=旧路径
  performanceEngineMode: "rust_auto",
};

let systemConfig = ensureObject(
  safeJsonParse(storageGet("chan_system_config"), JSON.parse(JSON.stringify(DEFAULT_SYSTEM_CONFIG))),
  JSON.parse(JSON.stringify(DEFAULT_SYSTEM_CONFIG))
);
systemConfig.dataSourcePriority = ["离线数据"];
systemConfig.chanRecordEnabled = false;

function storageSetDefaultJson(key, value) {
  if (storageGet(key) == null) storageSet(key, JSON.stringify(value));
}

function storageSetDefaultText(key, value) {
  if (storageGet(key) == null) storageSet(key, String(value));
}

function ensurePersistentDefaultSelections() {
  // 可持久化设置默认值：只补空，不覆盖用户已保存的选择。
  storageSetDefaultJson("chan_logic_config", DEFAULT_CHAN_CONFIG);
  storageSetDefaultJson("chan_chart_config", buildChartConfigStore({}));
  storageSetDefaultJson("chan_session_config", DEFAULT_SESSION_CONFIG);
  storageSetDefaultJson("chan_system_config", systemConfig);
  storageSetDefaultJson("chan_chart_settings_branch_sel", {});
  storageSetDefaultJson("chan_bt_cond_selected", { entry: [], exit: [] });
  storageSetDefaultText("chan_left_main_tab", "1");
  storageSetDefaultText("chan_active_tool", "none");
  storageSetDefaultText("chan_selected_main_indicator_slot", "0");
  storageSetDefaultText("chan_selected_sub_indicator_slot", "0");
  storageSetDefaultText("chan_indicator_main_var_visible", "1");
  storageSetDefaultText("chan_indicator_sub_var_visible", "1");
  storageSetDefaultJson("chan_indicator_main_slots", defaultMainSlots);
  storageSetDefaultJson("chan_indicator_sub_slots", defaultSubSlots);
}

ensurePersistentDefaultSelections();

let compiledShortcuts = [];
let shortcutSequenceBuffer = [];
let shortcutSequenceLastAt = 0;
const SHORTCUT_SEQUENCE_TIMEOUT = 1500;

function escapeHtmlAttr(text) {
  return String(text || "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function escapeHtml(text) {
  return escapeHtmlAttr(text).replace(/'/g, "&#39;");
}

function normalizeShortcutKeyToken(raw) {
  if (raw === undefined || raw === null) return null;
  const rawStr = String(raw);
  const aliasMap = {
    " ": "space",
    spacebar: "space",
    esc: "escape",
    return: "enter",
    del: "delete",
    plus: "+",
    minus: "-",
    left: "arrowleft",
    right: "arrowright",
    up: "arrowup",
    down: "arrowdown",
    pgup: "pageup",
    pgdn: "pagedown",
    cmd: "meta",
    command: "meta",
    win: "meta",
    windows: "meta",
    option: "alt",
    control: "ctrl",
  };
  const lowerRaw = rawStr.toLowerCase();
  if (aliasMap[lowerRaw]) return aliasMap[lowerRaw];
  const text = rawStr.trim().toLowerCase();
  if (!text) return null;
  if (aliasMap[text]) return aliasMap[text];
  if (/^key[a-z]$/.test(text)) return text.slice(3);
  if (/^digit[0-9]$/.test(text)) return text.slice(5);
  return text;
}

function eventToShortcutKeyToken(e) {
  const code = String(e.code || "");
  if (/^Key[A-Z]$/.test(code)) return code.slice(3).toLowerCase();
  if (/^Digit[0-9]$/.test(code)) return code.slice(5);
  if (/^Numpad[0-9]$/.test(code)) return code.slice(6);
  if (/^F[0-9]{1,2}$/.test(code)) return code.toLowerCase();
  const key = normalizeShortcutKeyToken(e.key);
  if (!key || ["shift", "ctrl", "alt", "meta"].includes(key)) return null;
  return key;
}

function parseShortcutToken(text) {
  const raw = String(text || "").trim();
  if (!raw) return null;
  
  // 处理规范化后的序列格式 seq:a>b>c
  if (raw.startsWith("seq:")) {
    const keys = raw.slice(4).split(">").map(normalizeShortcutKeyToken).filter(Boolean);
    if (keys.length > 0) return { type: "sequence", keys };
    return null;
  }

  const normalized = raw.toLowerCase().replace(/\s+/g, "");
  if (normalized.includes("+")) {
    const parts = normalized.split("+").filter(Boolean);
    if (parts.length === 0) return null;
    const combo = { type: "combo", ctrl: false, alt: false, shift: false, meta: false, key: null };
    for (let i = 0; i < parts.length; i += 1) {
      const part = normalizeShortcutKeyToken(parts[i]);
      if (!part) return null;
      if (part === "ctrl") combo.ctrl = true;
      else if (part === "alt") combo.alt = true;
      else if (part === "shift") combo.shift = true;
      else if (part === "meta") combo.meta = true;
      else if (i === parts.length - 1 && !combo.key) combo.key = part;
      else return null;
    }
    return combo.key ? combo : null;
  }
  const lower = raw.trim().toLowerCase();
  const single = normalizeShortcutKeyToken(lower);
  const specialSingles = new Set(["space", "enter", "escape", "tab", "backspace", "delete", "pageup", "pagedown", "home", "end", "insert", "arrowup", "arrowdown", "arrowleft", "arrowright", "meta"]);
  if (single && (single.length === 1 || specialSingles.has(single) || /^f[0-9]{1,2}$/.test(single))) {
    return { type: "combo", ctrl: false, alt: false, shift: false, meta: false, key: single };
  }
  const compact = lower.replace(/\s+/g, "");
  if (/^[a-z0-9]+$/.test(compact)) {
    return { type: "sequence", keys: compact.split("") };
  }
  const seqParts = lower.split(/\s+/).map(normalizeShortcutKeyToken).filter(Boolean);
  if (seqParts.length > 1) return { type: "sequence", keys: seqParts };
  return null;
}

function canonicalizeShortcut(def) {
  if (!def) return "";
  if (def.type === "sequence") return `seq:${def.keys.join(">")}`;
  const parts = [];
  if (def.ctrl) parts.push("ctrl");
  if (def.alt) parts.push("alt");
  if (def.shift) parts.push("shift");
  if (def.meta) parts.push("meta");
  parts.push(def.key);
  return parts.join("+");
}

function parseShortcutList(raw) {
  const parts = String(raw || "")
    .split(/[\n,，;；]+/)
    .map(item => item.trim())
    .filter(Boolean);
  const parsed = [];
  const invalid = [];
  const seen = new Set();
  parts.forEach(item => {
    const def = parseShortcutToken(item);
    if (!def) {
      invalid.push(item);
      return;
    }
    const canonical = canonicalizeShortcut(def);
    if (canonical && !seen.has(canonical)) {
      parsed.push(def);
      seen.add(canonical);
    }
  });
  return { parsed, invalid };
}

function formatShortcut(def) {
  if (!def) return "";
  if (typeof def === "string") {
    const parsed = parseShortcutToken(def);
    return parsed ? formatShortcut(parsed) : def;
  }
  if (def.type === "sequence") {
    const joined = def.keys.join("");
    if (/^[a-z0-9]+$/.test(joined)) return joined;
    return def.keys.map(key => formatShortcut({ type: "combo", ctrl: false, alt: false, shift: false, meta: false, key })).join(" > ");
  }
  const labels = [];
  if (def.ctrl) labels.push("Ctrl");
  if (def.alt) labels.push("Alt");
  if (def.shift) labels.push("Shift");
  if (def.meta) labels.push("Meta");
  const keyMap = {
    space: "Space",
    enter: "Enter",
    pageup: "PageUp",
    pagedown: "PageDown",
    arrowup: "ArrowUp",
    arrowdown: "ArrowDown",
    arrowleft: "ArrowLeft",
    arrowright: "ArrowRight",
    escape: "Esc",
  };
  let keyLabel = keyMap[def.key] || def.key;
  if (/^[a-z]$/.test(keyLabel)) keyLabel = keyLabel.toUpperCase();
  else if (/^f[0-9]{1,2}$/.test(keyLabel)) keyLabel = keyLabel.toUpperCase();
  labels.push(keyLabel);
  return labels.join("+");
}

function getActionShortcuts(actionId) {
  if (systemConfig.shortcuts && Object.prototype.hasOwnProperty.call(systemConfig.shortcuts, actionId)) {
    return ensureArray(systemConfig.shortcuts[actionId], []).slice();
  }
  const meta = SHORTCUT_ACTION_MAP[actionId];
  return meta ? meta.defaults.slice() : [];
}

function getActionShortcutDisplay(actionId) {
  return getActionShortcuts(actionId)
    .map(item => formatShortcut(item))
    .filter(Boolean)
    .join(" / ");
}

function setActionShortcuts(actionId, parsedShortcuts) {
  if (!systemConfig.shortcuts) systemConfig.shortcuts = {};
  systemConfig.shortcuts[actionId] = parsedShortcuts.map(canonicalizeShortcut);
}

function normalizeSystemConfig() {
    const normalized = { shortcuts: {}, bspJudgeMode: "auto" };
    const rawMode = systemConfig && typeof systemConfig.bspJudgeMode === "string" ? systemConfig.bspJudgeMode : "auto";
    normalized.bspJudgeMode = rawMode === "manual" ? "manual" : "auto";
    
    // 数据源优先级：去重后按用户顺序，再补齐未出现的默认项（仅排序，不允许缺省源）
    const canonical = DEFAULT_SYSTEM_CONFIG.dataSourcePriority.slice();
    if (systemConfig && Array.isArray(systemConfig.dataSourcePriority)) {
        const raw = systemConfig.dataSourcePriority.filter(item => typeof item === "string");
        const seen = new Set();
        const ordered = [];
        raw.forEach((n) => {
            if (canonical.includes(n) && !seen.has(n)) {
                seen.add(n);
                ordered.push(n);
            }
        });
        canonical.forEach((n) => {
            if (!seen.has(n)) ordered.push(n);
        });
        normalized.dataSourcePriority = ordered;
    } else {
        normalized.dataSourcePriority = canonical.slice();
    }
    normalized.rollbackCacheDepth = Number(systemConfig.rollbackCacheDepth || DEFAULT_SYSTEM_CONFIG.rollbackCacheDepth);
    normalized.rollbackFullSnapshotInterval = Number(systemConfig.rollbackFullSnapshotInterval || DEFAULT_SYSTEM_CONFIG.rollbackFullSnapshotInterval);
    normalized.rollbackCaptureMaxBars = Number(systemConfig.rollbackCaptureMaxBars || DEFAULT_SYSTEM_CONFIG.rollbackCaptureMaxBars);
    normalized.performanceEngineMode = String(systemConfig.performanceEngineMode || DEFAULT_SYSTEM_CONFIG.performanceEngineMode || "rust_auto") === "python_legacy"
      ? "python_legacy"
      : "rust_auto";

    SHORTCUT_ACTIONS.forEach(action => {
        const hasOwn = systemConfig.shortcuts && Object.prototype.hasOwnProperty.call(systemConfig.shortcuts, action.id);
        const source = ensureArray(hasOwn ? systemConfig.shortcuts[action.id] : action.defaults, []);
        const parsed = [];
        const seen = new Set();
        source.forEach(item => {
            const def = typeof item === "string" ? parseShortcutToken(item) : item;
            const canonical = canonicalizeShortcut(def);
            if (canonical && !seen.has(canonical)) {
                parsed.push(canonical);
                seen.add(canonical);
            }
        });
        normalized.shortcuts[action.id] = parsed;
    });
    systemConfig = normalized;
}

async function syncDataSourcePriorityToServer() {
    normalizeSystemConfig();
    const p = systemConfig.dataSourcePriority;
    if (!Array.isArray(p) || p.length === 0) return;
    try {
        await api("/api/set_data_source_priority", { priority: p });
    } catch (e) {
        console.warn("同步数据源优先级到服务端失败:", e);
    }
}

function saveSystemConfig() {
    normalizeSystemConfig();

    const dataSourcePriority = getDataSourcePriority();
    if (dataSourcePriority && dataSourcePriority.length > 0) {
        systemConfig.dataSourcePriority = dataSourcePriority;
    }

    storageSet("chan_system_config", JSON.stringify(systemConfig));
    rebuildShortcutRegistry();
    updateShortcutUI();
    void syncDataSourcePriorityToServer();
}

function rebuildShortcutRegistry() {
  compiledShortcuts = SHORTCUT_ACTIONS.map((action, index) => {
    const parsedShortcuts = getActionShortcuts(action.id)
      .map(item => parseShortcutToken(item))
      .filter(Boolean);
    return { actionId: action.id, index, contexts: action.contexts || ["global"], shortcuts: parsedShortcuts };
  });
}

function getShortcutConflicts(actionId) {
  const own = new Set(getActionShortcuts(actionId));
  const conflicts = [];
  SHORTCUT_ACTIONS.forEach(action => {
    if (action.id === actionId) return;
    const overlap = getActionShortcuts(action.id).filter(item => own.has(item));
    if (overlap.length > 0) conflicts.push(`${action.label} (${overlap.map(item => formatShortcut(item)).join(" / ")})`);
  });
  return conflicts;
}

function setButtonShortcutLabel(button, baseLabel, actionId) {
  if (!button) return;
  const display = getActionShortcutDisplay(actionId);
  button.innerHTML = display ? `${baseLabel} <small>(${escapeHtmlAttr(display)})</small>` : baseLabel;
}

function updateShortcutUI() {
  setButtonShortcutLabel($("btnChanSettingsOpen"), "缠论配置...", "openChanSettings");
  setButtonShortcutLabel($("btnSettingsOpen"), "图表显示设置...", "openChartSettings");
  setButtonShortcutLabel($("btnSystemSettingsOpen"), "系统配置...", "openSystemSettings");
  if ($("btnInit").disabled && $("btnInit").textContent.includes("已加载")) {
    $("btnInit").innerHTML = "已加载";
  } else {
    setButtonShortcutLabel($("btnInit"), "加载会话", "initSession");
  }
  setButtonShortcutLabel($("btnReset"), "重新训练", "resetSession");
  setButtonShortcutLabel($("btnStepPrev"), "上一根K线", "prevBar");
  setButtonShortcutLabel($("btnStep"), "下一根K线", "nextBar");
  setButtonShortcutLabel($("btnStepN"), "步进 N 根", "stepForwardN");
  setButtonShortcutLabel($("btnBackN"), "后退 N 根", "stepBackwardN");
  setButtonShortcutLabel($("btnBuy"), "买入（全仓）", "buyAll");
  setButtonShortcutLabel($("btnSell"), "卖出（全量）", "sellAll");
  setButtonShortcutLabel($("btnShort"), "做空（全仓）", "shortAll");
  setButtonShortcutLabel($("btnCover"), "平空（全量）", "coverAll");
  $("btnChanSettingsSave").textContent = `保存并应用${getActionShortcutDisplay("saveChanSettings") ? ` (${getActionShortcutDisplay("saveChanSettings")})` : ""}`;
  $("btnSettingsSave").textContent = `保存并应用${getActionShortcutDisplay("saveChartSettings") ? ` (${getActionShortcutDisplay("saveChartSettings")})` : ""}`;
  $("btnSystemSettingsSave").textContent = `保存并应用${getActionShortcutDisplay("saveSystemSettings") ? ` (${getActionShortcutDisplay("saveSystemSettings")})` : ""}`;
  $("bspPromptConfirm").textContent = `确认（${getActionShortcutDisplay("confirmBspPrompt") || "Enter"} / 左键）`;
  $("btnSettlementClose").textContent = `确认${getActionShortcutDisplay("closeSettlement") ? `（${getActionShortcutDisplay("closeSettlement")}）` : ""}`;
  $("btnFullscreen").innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3"/></svg> 全屏显示${getActionShortcutDisplay("toggleFullscreen") ? ` (${escapeHtmlAttr(getActionShortcutDisplay("toggleFullscreen"))})` : ""}`;
  $("btnFullscreen").setAttribute("data-tip", `切换图表区域全屏显示。快捷键：${getActionShortcutDisplay("toggleFullscreen") || "未设置"}。`);
  $("btnChanSettingsOpen").setAttribute("data-tip", `打开缠论逻辑配置面板，可调整笔、线段、中枢等算法。快捷键：${getActionShortcutDisplay("openChanSettings") || "未设置"}。`);
  $("btnSettingsOpen").setAttribute("data-tip", `打开图表显示设置面板，可调整主题、指标与绘制项。快捷键：${getActionShortcutDisplay("openChartSettings") || "未设置"}。`);
  $("btnSystemSettingsOpen").setAttribute("data-tip", `打开系统配置面板，可统一维护快捷键。快捷键：${getActionShortcutDisplay("openSystemSettings") || "未设置"}。`);
  $("btnInit").setAttribute("data-tip", `根据当前代码、日期区间、初始资金加载复盘会话。首次加载历史数据可能较慢。快捷键：${getActionShortcutDisplay("initSession") || "未设置"}。`);
  $("btnReset").setAttribute("data-tip", `清空当前会话并恢复到可重新配置的初始状态。快捷键：${getActionShortcutDisplay("resetSession") || "未设置"}。`);
  if ($("btnStepPrev")) {
    $("btnStepPrev").setAttribute("data-tip", `回退一根K线（服务端重建）。快捷键：${getActionShortcutDisplay("prevBar") || "未设置"}。`);
  }
  $("btnStep").setAttribute("data-tip", `步进到下一根K线。若当前K线命中买卖点（1/1p/2/2s/3a/3b）或 1382 提示，会合并为一个弹窗提示。快捷键：${getActionShortcutDisplay("nextBar") || "未设置"}。`);
  $("btnStepN").setAttribute("data-tip", `按步进数量 N 连续推进，若中途遇到买卖点（1/1p/2/2s/3a/3b）或 1382 提示会按设置自动停止。快捷键：${getActionShortcutDisplay("stepForwardN") || "未设置"}。`);
  if ($("btnStepInterrupt")) {
    $("btnStepInterrupt").setAttribute("data-tip", `正在连续步进时可点击中断；当前根处理完后停止。快捷键：${getActionShortcutDisplay("interruptStepForward") || "未设置"}。`);
  }
  $("btnBackN").setAttribute("data-tip", `按步进数量 N 回退，会自动重建到更早的状态。快捷键：${getActionShortcutDisplay("stepBackwardN") || "未设置"}。`);
  $("btnBuy").setAttribute("data-tip", `按当前收盘价使用全部可用现金买入，遵循单持仓和每步最多一笔规则。快捷键：${getActionShortcutDisplay("buyAll") || "未设置"}。`);
  $("btnSell").setAttribute("data-tip", `按当前收盘价全部卖出，若受 T+1 约束则按钮不可用。快捷键：${getActionShortcutDisplay("sellAll") || "未设置"}。`);
  $("btnShort").setAttribute("data-tip", `按当前收盘价使用全仓做空，遵循单持仓和每步最多一笔规则。快捷键：${getActionShortcutDisplay("shortAll") || "未设置"}。`);
  $("btnCover").setAttribute("data-tip", `按当前收盘价全部平空，若受 T+1 约束则按钮不可用。快捷键：${getActionShortcutDisplay("coverAll") || "未设置"}。`);
  $("tipStepN").setAttribute("data-tip", `设置连续步进或回退时使用的根数。连续步进遇到买卖点（1/1p/2/2s/3a/3b）或 1382 可自动中断。步进快捷键：${getActionShortcutDisplay("stepForwardN") || "未设置"}；回退快捷键：${getActionShortcutDisplay("stepBackwardN") || "未设置"}。`);
  if ($("btnJudgeBsp")) {
    setButtonShortcutLabel($("btnJudgeBsp"), "检查买卖点", "checkBspJudge");
    $("btnJudgeBsp").setAttribute("data-tip", `手动检查笔/段/2段买卖点（仅手动判定模式下可用）。快捷键：${getActionShortcutDisplay("checkBspJudge") || "未设置"}。`);
  }
  initTooltips();
}

function isBspJudgeManual() {
  return systemConfig && systemConfig.bspJudgeMode === "manual";
}

function updateBspJudgeUI() {
  const btn = $("btnJudgeBsp");
  if (!btn) return;
  const manual = isBspJudgeManual();
  btn.style.display = manual ? "inline-flex" : "none";
  btn.disabled = !manual || !lastPayload || !lastPayload.ready;
}

function getActiveShortcutContexts() {
  if ($("settlementModal").classList.contains("show")) return ["settlement"];
  if (isSystemSettingsOpen()) return ["systemSettings"];
  if (isChanSettingsOpen()) return ["chanSettings"];
  if (isSettingsOpen()) return ["chartSettings"];
  return ["global"];
}

function shortcutMatchesEvent(def, e) {
  if (!def || def.type !== "combo") return false;
  const key = eventToShortcutKeyToken(e);
  if (!key) return false;
  return def.key === key &&
    !!def.ctrl === !!e.ctrlKey &&
    !!def.alt === !!e.altKey &&
    !!def.shift === !!e.shiftKey &&
    !!def.meta === !!e.metaKey;
}

function cleanupShortcutSequenceBuffer(now) {
  if (!shortcutSequenceLastAt || now - shortcutSequenceLastAt > SHORTCUT_SEQUENCE_TIMEOUT) {
    shortcutSequenceBuffer = [];
  }
  while (shortcutSequenceBuffer.length > 12) shortcutSequenceBuffer.shift();
}

function shortcutSequenceMatches(def) {
  if (!def || def.type !== "sequence" || def.keys.length === 0) return false;
  if (shortcutSequenceBuffer.length < def.keys.length) return false;
  const tail = shortcutSequenceBuffer.slice(-def.keys.length);
  return def.keys.every((key, idx) => tail[idx] === key);
}

/** 多周期勾选顺序（请求体与持久化稳定排序） */
const MULTI_KTYPE_ORDER = ["1min", "3min", "5min", "15min", "30min", "60min", "daily", "weekly", "monthly", "quarterly", "yearly"];

function collectKTypesMultiSelected() {
  const row = $("kTypesMultiRow");
  if (!row) return [];
  const picked = [];
  row.querySelectorAll("input.kTypesMultiCb[type=\"checkbox\"]:checked").forEach((cb) => picked.push(cb.value));
  return MULTI_KTYPE_ORDER.filter((k) => picked.includes(k));
}

function collectKTypesMultiOrdered() {
  return collectKTypesMultiSelected();
}

const KTYPE_MULTI_SHORT = {
  "1min": "1分", "3min": "3分", "5min": "5分", "15min": "15分", "30min": "30分", "60min": "60分",
  "daily": "日", "weekly": "周", "monthly": "月", "quarterly": "季", "yearly": "年",
};

/** 多周期勾选区：按固定顺序给已勾选项加 1. 2. 前缀（与快捷键序号一致） */
function refreshKTypesMultiOrderLabels() {
  const row = $("kTypesMultiRow");
  if (!row) return;
  row.querySelectorAll(".kTypesMultiLbl").forEach((lab) => {
    const kt = lab.getAttribute("data-kt") || "";
    const span = lab.querySelector(".kTypesMultiTxt");
    if (span) span.textContent = KTYPE_MULTI_SHORT[kt] || kt;
  });
  const picked = MULTI_KTYPE_ORDER.filter((k) => {
    const cb = row.querySelector(`input.kTypesMultiCb[value="${k}"]`);
    return cb && cb.checked;
  });
  picked.forEach((k, i) => {
    const span = row.querySelector(`.kTypesMultiLbl[data-kt="${k}"] .kTypesMultiTxt`);
    if (span) span.textContent = `${i + 1}.${KTYPE_MULTI_SHORT[k] || k}`;
  });
}

function applyKTypesMultiToDomFromList(list) {
  const row = $("kTypesMultiRow");
  if (!row) return;
  let arr = Array.isArray(list) ? list.filter((k) => typeof k === "string") : [];
  arr = MULTI_KTYPE_ORDER.filter((k) => arr.includes(k));
  if (arr.length < 2) arr = ["1min", "3min"];
  const set = new Set(arr);
  row.querySelectorAll("input.kTypesMultiCb[type=\"checkbox\"]").forEach((cb) => {
    cb.checked = set.has(cb.value);
  });
  if (Array.isArray(sessionConfig.multiLayerHidden)) {
    sessionConfig.multiLayerHidden = sessionConfig.multiLayerHidden.filter((k) => set.has(k));
  }
  refreshKTypesMultiOrderLabels();
}

function syncChartModeOptionRows() {
  const cm = $("chartMode") ? String($("chartMode").value || "single") : "single";
  const dual = cm === "dual";
  const multi = cm === "multi";
  if ($("kType1Row")) $("kType1Row").style.display = multi ? "none" : "";
  if ($("kType2Row")) $("kType2Row").style.display = dual ? "" : "none";
  if ($("dualLayoutRow")) $("dualLayoutRow").style.display = dual ? "" : "none";
  if ($("dualSplitRow")) $("dualSplitRow").style.display = dual ? "" : "none";
  if ($("kTypesMultiRow")) $("kTypesMultiRow").style.display = multi ? "" : "none";
}

function saveSessionConfig() {
  const prevHid = Array.isArray(sessionConfig.multiLayerHidden) ? sessionConfig.multiLayerHidden.slice() : [];
  sessionConfig = {
    code: $("code").value,
    begin: $("begin").value,
    end: $("end").value,
    cash: $("cash").value,
    autype: $("autype").value,
    theme: chartConfig.theme,
    chipEnabled: chartConfig.chip.enabled,
    chipStretchLevel: String(chartConfig.chip.stretchLevel),
    chipBucketStep: String(chartConfig.chip.bucketStep),
    fractZsEnabled: chartConfig.fractZs.enabled,
    biZsEnabled: chartConfig.biZs.enabled,
    segZsEnabled: chartConfig.segZs.enabled,
    segsegZsEnabled: chartConfig.segsegZs.enabled,
    stepN: $("stepN").value,
    kType: $("kType").value,
    chartMode: $("chartMode") ? $("chartMode").value : "single",
    kTypesMulti: collectKTypesMultiSelected(),
    kType2: $("kType2") ? $("kType2").value : $("kType").value,
    dualLayout: $("dualLayout") ? $("dualLayout").value : "vertical",
    dualSplitRatio1: getDualSplitRatio1(),
    activeChartId: String(
      (lastPayload && lastPayload.ready && lastPayload.active_chart_id)
        ? lastPayload.active_chart_id
        : (sessionConfig.activeChartId || dualActiveChartId || "chart1")
    ),
    multiLayerHidden: prevHid,
    // 保存数据形式与喂数据方式
    dataFormMode: normalizeDataFormMode(dataFormConfig.mode),
    dataFormQuantity: clampDataFormQuantity(dataFormConfig.quantity, dataFormConfig.quantity || 1),
    dataFormQuantityAlloc: normalizeDataFormQuantityAlloc(dataFormConfig.quantityAlloc),
    dataFeedMode: normalizeDataFeedMode(dataFormConfig.feedMode),
    klinePresentationMode: normalizeKlinePresentationMode(dataFormConfig.klinePresentation),
    offlineDataCustom: normalizeOfflineDataCustom(dataFormConfig.offlineDataCustom),
  };
  storageSet("chan_session_config", JSON.stringify(sessionConfig));
}

/** 将内存中的 chartConfig 写回 localStorage（重新训练前调用，避免未点「保存」时丢失） */
function persistChartConfigStoreNow(syncAllPerChart) {
  const aid = (lastPayload && lastPayload.ready && String(lastPayload.active_chart_id) === "chart2")
    ? "chart2"
    : (String(sessionConfig.activeChartId || dualActiveChartId || "chart1") === "chart2" ? "chart2" : "chart1");
  const snap = JSON.parse(JSON.stringify(chartConfig));
  chartConfigStore.perChart[aid] = snap;
  if (syncAllPerChart !== false) {
    chartConfigStore.perChart.chart1 = JSON.parse(JSON.stringify(snap));
    chartConfigStore.perChart.chart2 = deepMerge(
      JSON.parse(JSON.stringify(chartConfigStore.perChart.chart2 || DEFAULT_CHART_CONFIG)),
      JSON.parse(JSON.stringify(snap))
    );
  }
  chartConfigStore.shared.theme = chartConfig.theme;
  chartConfigStore.shared.crosshair = JSON.parse(JSON.stringify(chartConfig.crosshair || chartConfigStore.shared.crosshair || {}));
  if (typeof chartConfigStore.shared.showBottomBsp !== "boolean") {
    chartConfigStore.shared.showBottomBsp = true;
  }
  if ($("chartMode")) chartConfigStore.shared.mode = $("chartMode").value;
  if (!chartConfigStore.multiPerK) chartConfigStore.multiPerK = {};
  if (chartConfig.multiOverlay) {
    chartConfigStore.multiOverlay = JSON.parse(JSON.stringify(chartConfig.multiOverlay));
  }
  storageSet("chan_chart_config", JSON.stringify(chartConfigStore));
}

function loadSessionConfig() {
    if (sessionConfig.code !== undefined) $("code").value = sessionConfig.code;
    if (sessionConfig.begin !== undefined) $("begin").value = sessionConfig.begin;
    if (sessionConfig.end !== undefined) $("end").value = sessionConfig.end;
    if (sessionConfig.cash !== undefined) $("cash").value = sessionConfig.cash;
    if (sessionConfig.autype !== undefined) $("autype").value = sessionConfig.autype;
    if (sessionConfig.theme !== undefined) {
        chartConfig.theme = sessionConfig.theme;
        applyThemeFromSelect();
    }
    if (sessionConfig.kType !== undefined) $("kType").value = sessionConfig.kType;
    if ($("chartMode") && sessionConfig.chartMode !== undefined) $("chartMode").value = String(sessionConfig.chartMode || "single");
    if ($("kType2") && sessionConfig.kType2 !== undefined) $("kType2").value = String(sessionConfig.kType2 || $("kType").value);
    if ($("dualLayout") && sessionConfig.dualLayout !== undefined) $("dualLayout").value = String(sessionConfig.dualLayout || "vertical");
    if ($("dualSplitRatio") && sessionConfig.dualSplitRatio1 !== undefined) {
      const pct = Math.round(Math.min(0.78, Math.max(0.22, Number(sessionConfig.dualSplitRatio1) || 0.5)) * 100);
      $("dualSplitRatio").value = String(pct);
      const lab = $("dualSplitRatioLabel");
      if (lab) lab.textContent = `${pct}%`;
    }
    // No longer setting DOM for chip/biZs/segZs here as they are in chartConfig
    if (sessionConfig.stepN !== undefined) $("stepN").value = sessionConfig.stepN;
    dataFormConfig.mode = normalizeDataFormMode(sessionConfig.dataFormMode);
    dataFormConfig.quantity = clampDataFormQuantity(
      sessionConfig.dataFormQuantity,
      Number.isFinite(Number(sessionConfig.dataFormQuantity)) ? Number(sessionConfig.dataFormQuantity) : 1
    );
    dataFormConfig.feedMode = normalizeDataFeedMode(sessionConfig.dataFeedMode);
    dataFormConfig.quantityAlloc = normalizeDataFormQuantityAlloc(
      sessionConfig.dataFormQuantityAlloc != null ? sessionConfig.dataFormQuantityAlloc : dataFormConfig.quantityAlloc
    );
    dataFormConfig.klinePresentation = normalizeKlinePresentationMode(
      sessionConfig.klinePresentationMode != null ? sessionConfig.klinePresentationMode : dataFormConfig.klinePresentation
    );
    dataFormConfig.offlineDataCustom = normalizeOfflineDataCustom(
      sessionConfig.offlineDataCustom != null ? sessionConfig.offlineDataCustom : dataFormConfig.offlineDataCustom
    );
    if (!Array.isArray(sessionConfig.multiLayerHidden)) sessionConfig.multiLayerHidden = [];
    applyKTypesMultiToDomFromList(sessionConfig.kTypesMulti);
    syncChartModeOptionRows();
}

function updateDualModeUI(payload = null) {
  if (payload && payload.ready && $("chartMode") && payload.chart_mode) {
    const pcm = String(payload.chart_mode || "single");
    const sel = $("chartMode");
    if (sel) {
      const ok = [...sel.options].some((o) => o.value === pcm);
      if (ok) sel.value = pcm;
    }
    if (Array.isArray(payload.k_types_multi) && payload.k_types_multi.length >= 2) {
      applyKTypesMultiToDomFromList(payload.k_types_multi);
    }
  }
  syncChartModeOptionRows();
  const mode = payload && payload.chart_mode ? String(payload.chart_mode) : ($("chartMode") ? $("chartMode").value : "single");
  const dual = mode === "dual";
  // 双图激活：鼠标移入子图即激活（可右键锁定）；无“图1/图2激活”按钮入口
  if ($("dualChartToolbar")) $("dualChartToolbar").style.display = "none";
  const active = payload && payload.active_chart_id ? String(payload.active_chart_id) : (sessionConfig.activeChartId || "chart1");
  dualActiveChartId = active === "chart2" ? "chart2" : "chart1";
  chartConfig = active === "chart2" ? chartConfigStore.perChart.chart2 : chartConfigStore.perChart.chart1;
  chartConfig.theme = chartConfigStore.shared.theme || chartConfig.theme;
  chartConfig.crosshair = deepMerge(JSON.parse(JSON.stringify(chartConfig.crosshair || {})), chartConfigStore.shared.crosshair || {});
  syncCrosshairEnabledFromStore();
  if (dual) loadRuntimeState(dualActiveChartId);
}

function getCfgColor(c) {
  if (c && c.startsWith("--")) return cssVar(c, "#000");
  return c;
}

const BSP_LEVEL_CONFIG_KEY = { bi: "bspBi", seg: "bspSeg", segseg: "bspSegseg" };
const RHYTHM_LEVEL_ENABLED_KEY = {
  fract: "fractToBiEnabled",
  bi: "biToSegEnabled",
  seg: "segToSegsegEnabled",
};
const RHYTHM_CALC_MODE_LABELS = {
  normal: "通用",
  transition: "过渡",
  strict1382: "1382严格",
};

function normalizeRhythmCalcMode(mode) {
  const text = String(mode || "normal");
  return Object.prototype.hasOwnProperty.call(RHYTHM_CALC_MODE_LABELS, text) ? text : "normal";
}

function applyRhythmCalcModeToChanConfig(targetConfig) {
  const cfg = targetConfig || chanConfig;
  const rhythmCfg = chartConfig.rhythmLine || DEFAULT_CHART_CONFIG.rhythmLine;
  cfg.rhythm_calc_mode = normalizeRhythmCalcMode(rhythmCfg.calcMode);
  return cfg;
}

function getRhythmMaxLayer() {
  const cfg = activeDrawStyle().rhythmLine || DEFAULT_CHART_CONFIG.rhythmLine;
  const n = Math.floor(Number(cfg.maxLayer));
  return Number.isFinite(n) ? Math.max(0, Math.min(9, n)) : 9;
}

function getBspConfig(level) {
  const key = BSP_LEVEL_CONFIG_KEY[level] || bspConfigKeyForLevel(level);
  return chartConfig[key] || chartConfig.bspBi || DEFAULT_CHART_CONFIG.bspBi;
}
function isBspLevelEnabled(level, cfg = chartConfig, store = chartConfigStore) {
  if (store && store.shared && store.shared.showBottomBsp === false) return false;
  const key = BSP_LEVEL_CONFIG_KEY[level] || bspConfigKeyForLevel(level);
  const c = cfg && cfg[key] ? cfg[key] : DEFAULT_CHART_CONFIG[key];
  return !c || c.enabled !== false;
}
function collectChartLazyLayersFromConfig(cfg = chartConfig, store = chartConfigStore) {
  const rhythmOn = !!(cfg && cfg.rhythmLine && cfg.rhythmLine.enabled);
  const rhythmHitOn = !!(cfg && cfg.rhythmHit && cfg.rhythmHit.enabled !== false);
  const lineLevels = {};
  customSegmentLevelsFromConfig(cfg).forEach((lv) => { lineLevels[lv] = true; });
  const bspLevels = {};
  allBspLevels(cfg).forEach((lv) => { bspLevels[lv] = isBspLevelEnabled(lv, cfg, store); });
  const zsLevels = {};
  allZsLevels(cfg).forEach((lv) => {
    const key = zsConfigKeyForLevel(lv);
    zsLevels[lv] = !!(cfg && cfg[key] && cfg[key].enabled);
  });
  return {
    rhythm: rhythmOn,
    rhythm_hits: rhythmOn && rhythmHitOn,
    line_levels: lineLevels,
    bsp_levels: bspLevels,
    zs_levels: zsLevels,
  };
}
function diffEnabledLazyLayers(prev, next) {
  const out = {
    rhythm: false,
    rhythm_hits: false,
    line_levels: {},
    bsp_levels: {},
    zs_levels: {},
  };
  if (!prev || !next) return out;
  out.rhythm = !prev.rhythm && !!next.rhythm;
  out.rhythm_hits = !prev.rhythm_hits && !!next.rhythm_hits;
  Array.from(new Set([...Object.keys(prev.line_levels || {}), ...Object.keys(next.line_levels || {})])).sort((a, b) => segLevelSortOrder(a) - segLevelSortOrder(b)).forEach((lv) => {
    out.line_levels[lv] = !(prev.line_levels && prev.line_levels[lv]) && !!(next.line_levels && next.line_levels[lv]);
  });
  Array.from(new Set([...Object.keys(prev.bsp_levels || {}), ...Object.keys(next.bsp_levels || {})])).sort((a, b) => segLevelSortOrder(a) - segLevelSortOrder(b)).forEach((lv) => {
    out.bsp_levels[lv] = !(prev.bsp_levels && prev.bsp_levels[lv]) && !!(next.bsp_levels && next.bsp_levels[lv]);
  });
  Array.from(new Set([...Object.keys(prev.zs_levels || {}), ...Object.keys(next.zs_levels || {})])).sort((a, b) => segLevelSortOrder(a) - segLevelSortOrder(b)).forEach((lv) => {
    out.zs_levels[lv] = !(prev.zs_levels && prev.zs_levels[lv]) && !!(next.zs_levels && next.zs_levels[lv]);
  });
  return out;
}
function hasAnyLazyLayer(layers) {
  return !!(layers && (
    layers.rhythm ||
    layers.rhythm_hits ||
    Object.values(layers.line_levels || {}).some(Boolean) ||
    Object.values(layers.bsp_levels || {}).some(Boolean) ||
    Object.values(layers.zs_levels || {}).some(Boolean)
  ));
}
function filterUnloadedLazyLayers(request, loaded) {
  if (!request || !loaded) return request;
  const out = {
    rhythm: !!request.rhythm && !loaded.rhythm,
    rhythm_hits: !!request.rhythm_hits && !loaded.rhythm_hits,
    line_levels: {},
    bsp_levels: {},
    zs_levels: {},
  };
  Array.from(new Set([...Object.keys(request.line_levels || {}), ...Object.keys(loaded.line_levels || {})])).sort((a, b) => segLevelSortOrder(a) - segLevelSortOrder(b)).forEach((lv) => {
    out.line_levels[lv] = !!(request.line_levels && request.line_levels[lv]) && !(loaded.line_levels && loaded.line_levels[lv]);
  });
  Array.from(new Set([...Object.keys(request.bsp_levels || {}), ...Object.keys(loaded.bsp_levels || {})])).sort((a, b) => segLevelSortOrder(a) - segLevelSortOrder(b)).forEach((lv) => {
    out.bsp_levels[lv] = !!(request.bsp_levels && request.bsp_levels[lv]) && !(loaded.bsp_levels && loaded.bsp_levels[lv]);
  });
  Array.from(new Set([...Object.keys(request.zs_levels || {}), ...Object.keys(loaded.zs_levels || {})])).sort((a, b) => segLevelSortOrder(a) - segLevelSortOrder(b)).forEach((lv) => {
    out.zs_levels[lv] = !!(request.zs_levels && request.zs_levels[lv]) && !(loaded.zs_levels && loaded.zs_levels[lv]);
  });
  return out;
}

function getBspDisplayLabel(p) {
  if (!p) return "";
  if (p.display_label) return String(p.display_label);
  if (p.level_label && p.label) return `${p.level_label}${p.label}`;
  return String(p.label || "");
}

function isRhythmLevelEnabled(level) {
  const cfg = activeDrawStyle().rhythmLine || DEFAULT_CHART_CONFIG.rhythmLine;
  const subKey = RHYTHM_LEVEL_ENABLED_KEY[level];
  if (!subKey) return true;
  return !!cfg[subKey];
}

function isRhythmLineVisible(line) {
  if (!line || !isRhythmLevelEnabled(line.level)) return false;
  const layer = Number.isFinite(Number(line.layer))
    ? Number(line.layer)
    : Math.max(0, Number(line.round_current || 0) - Number(line.round_ref || 0));
  return layer <= getRhythmMaxLayer();
}

function getRhythmGroupIndex(group) {
  const raw = String(group || "rhythm1").replace(/[^0-9]/g, "");
  const idx = Number(raw || "1");
  return Number.isFinite(idx) && idx >= 1 ? idx : 1;
}

function getRhythmVisualConfig(group) {
  const cfg = activeDrawStyle().rhythmLine || DEFAULT_CHART_CONFIG.rhythmLine;
  const rawIdx = getRhythmGroupIndex(group);
  const cycleIdx = ((rawIdx - 1) % 5) + 1;
  const growth = Math.max(0, rawIdx - 5);
  const lineColor = getCfgColor(cfg[`group${cycleIdx}LineColor`] || DEFAULT_CHART_CONFIG.rhythmLine[`group${cycleIdx}LineColor`]);
  const lineStyle = String(cfg[`group${cycleIdx}LineStyle`] || DEFAULT_CHART_CONFIG.rhythmLine[`group${cycleIdx}LineStyle`] || "dashed");
  const baseLineWidth = Number(cfg[`group${cycleIdx}LineWidth`] || DEFAULT_CHART_CONFIG.rhythmLine[`group${cycleIdx}LineWidth`] || 1.2);
  const baseTextSize = Number(cfg[`group${cycleIdx}TextFontSize`] || DEFAULT_CHART_CONFIG.rhythmLine[`group${cycleIdx}TextFontSize`] || 12);
  const textColor = getCfgColor(cfg[`group${cycleIdx}TextColor`] || lineColor);
  const configuredWeight = String(cfg[`group${cycleIdx}TextFontWeight`] || DEFAULT_CHART_CONFIG.rhythmLine[`group${cycleIdx}TextFontWeight`] || "bold");
  return {
    rawIdx,
    cycleIdx,
    lineColor,
    lineStyle,
    lineWidth: baseLineWidth + growth * 0.4,
    textColor,
    textFontSize: baseTextSize + growth,
    textFontWeight: growth > 0 ? "bold" : configuredWeight,
  };
}

function getRhythmLineColor(group) {
  return getRhythmVisualConfig(group).lineColor;
}

function openChanSettings() {
  if (isSettingsOpen()) closeSettings();
  if (isSystemSettingsOpen()) closeSystemSettings();
  renderChanSettingsForm();
  $("chanSettingsModal").classList.add("show");
}

function closeChanSettings() {
  $("chanSettingsModal").classList.remove("show");
}

function isChanSettingsOpen() {
  return $("chanSettingsModal").classList.contains("show");
}

function renderChanSettingsForm() {
  const container = $("chanSettingsContent");
  container.innerHTML = "";

  const sections = [
    {
      title: "主逻辑 (Algo)",
      key: "algo",
      color: "#2563eb",
      bgColor: "rgba(37, 99, 235, 0.08)",
      items: [
        { label: "缠论主逻辑", subKey: "chan_algo", type: "select", options: [
          { value: "classic", label: "原缠论" },
          { value: "new", label: "新缠论" }
        ], tip: "原缠论使用工程原有笔/段/2段逻辑；新缠论使用“新K线 -> 分型 -> 笔 -> 段 -> 2段”的递推逻辑，前端展示名称固定为分型/笔/段/2段。" }
      ]
    },
    {
      title: "笔配置 (Bi)",
      key: "bi",
      color: "#d97706",
      bgColor: "rgba(217, 119, 6, 0.08)",
      items: [
        { label: "笔是否严格", subKey: "bi_strict", type: "checkbox", tip: "是否使用严格笔定义。开启后分型间必须至少有一根独立K线。" },
        { label: "笔算法", subKey: "bi_algo", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "fx", label: "分型" }
        ], tip: "选择笔的生成算法。常规算法更符合标准缠论。" },
        { label: "分型检查", subKey: "bi_fx_check", type: "select", options: [
          { value: "strict", label: "严格" },
          { value: "normal", label: "常规" }
        ], tip: "分型成立的检查强度。严格模式要求更高。" },
        { label: "缺口当K线", subKey: "gap_as_kl", type: "checkbox", tip: "是否将缺口视为一根K线。在某些品种中很有用。" },
        { label: "笔终点是极值", subKey: "bi_end_is_peak", type: "checkbox", tip: "笔的结束点是否必须是区间内的最高/最低点。" },
        { label: "允许次极值", subKey: "bi_allow_sub_peak", type: "checkbox", tip: "是否允许笔在次极值处结束。" }
      ]
    },
    {
      title: "线段配置 (Seg)",
      key: "seg",
      color: "#059669",
      bgColor: "rgba(5, 150, 105, 0.1)",
      items: [
        { label: "线段算法", subKey: "seg_algo", type: "select", options: [
          { value: "chan", label: "标准缠论" },
          { value: "simple", label: "简单线段" }
        ], tip: "选择线段的生成算法。" },
        { label: "左端点方法", subKey: "left_seg_method", type: "select", options: [
          { value: "peak", label: "极值" },
          { value: "all", label: "所有" }
        ], tip: "线段左端点确定的逻辑。" }
      ]
    },
    {
      title: "中枢配置 (ZS)",
      key: "zs",
      color: "#ea580c",
      bgColor: "rgba(234, 88, 12, 0.08)",
      items: [
        { label: "中枢算法", subKey: "zs_algo", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "mac", label: "MAC算法" }
        ], tip: "选择中枢的生成算法。" },
        { label: "中枢合并", subKey: "zs_combine", type: "checkbox", tip: "是否自动合并重叠的中枢。" },
        { label: "合并模式", subKey: "zs_combine_mode", type: "select", options: [
          { value: "zs", label: "按中枢" },
          { value: "peak", label: "按极值" }
        ], tip: "中枢合并时的逻辑依据。" },
        { label: "一笔中枢", subKey: "one_bi_zs", type: "checkbox", tip: "是否允许由单笔构成的中枢。" }
      ]
    },
    {
      title: "均线与指标配置 (Ind)",
      key: "ind",
      color: "#6366f1",
      bgColor: "rgba(99, 102, 241, 0.08)",
      items: [
        { label: "均线周期", subKey: "mean_metrics", type: "text", placeholder: "如: 5, 10, 20", tip: "均线计算周期，逗号分隔。" },
        { label: "趋势线周期", subKey: "trend_metrics", type: "text", placeholder: "如: 20, 60", tip: "趋势线计算周期，逗号分隔。" },
        { label: "MACD 快线", subKey: "macd_fast", type: "number", tip: "MACD 快线周期（默认12）。" },
        { label: "MACD 慢线", subKey: "macd_slow", type: "number", tip: "MACD 慢线周期（默认26）。" },
        { label: "MACD 信号", subKey: "macd_signal", type: "number", tip: "MACD 信号周期（默认9）。" },
        { label: "BOLL 周期", subKey: "boll_n", type: "number", tip: "布林带计算周期。" },
        { label: "计算 Demark", subKey: "cal_demark", type: "checkbox", tip: "是否计算 Demark 指标。" },
        { label: "计算 RSI", subKey: "cal_rsi", type: "checkbox", tip: "是否计算 RSI 指标。" },
        { label: "RSI 周期", subKey: "rsi_cycle", type: "number", tip: "RSI 计算周期。" },
        { label: "计算 KDJ", subKey: "cal_kdj", type: "checkbox", tip: "是否计算 KDJ 指标。" },
        { label: "KDJ 周期", subKey: "kdj_cycle", type: "number", tip: "KDJ 计算周期。" }
      ]
    },
    {
      title: "买卖点配置 (BSP)",
      key: "bsp",
      color: "#be123c",
      bgColor: "rgba(190, 18, 60, 0.08)",
      items: [
        { label: "背驰比率阈值", subKey: "divergence_rate", type: "text", tip: "判定背驰的阈值，默认 inf (不限制)。" },
        { label: "最小中枢数量", subKey: "min_zs_cnt", type: "number", tip: "产生1类买卖点所需的最小中枢数量。" },
        { label: "1类点需多笔中枢", subKey: "bsp1_only_multibi_zs", type: "checkbox", tip: "1类买卖点是否仅在由多笔构成的中枢后产生。" },
        { label: "2类点最大回撤率", subKey: "max_bs2_rate", type: "number", tip: "2类买卖点允许的最大回撤比例 (0-1)。" },
        { label: "MACD 比较算法", subKey: "macd_algo", type: "select", options: [
          { value: "peak", label: "峰值 (Peak)" },
          { value: "area", label: "面积 (Area)" },
          { value: "full_area", label: "全面积" },
          { value: "diff", label: "DIFF值" },
          { value: "slope", label: "斜率 (Slope)" },
          { value: "amp", label: "振幅 (Amp)" }
        ], tip: "用于背驰比较的 MACD 数据提取算法。" },
        { label: "1类点需顶底分型", subKey: "bs1_peak", type: "checkbox", tip: "1类点是否必须对应分型极值。" },
        { label: "目标买卖点类型", subKey: "bs_type", type: "text", tip: "需要计算的买卖点类型，逗号分隔 (如 1, 2, 3a, 2s)。" },
        { label: "2类点跟随1类", subKey: "bsp2_follow_1", type: "checkbox", tip: "2类买卖点是否必须紧跟在1类点之后。" },
        { label: "3类点跟随1类", subKey: "bsp3_follow_1", type: "checkbox", tip: "3类买卖点是否必须跟在1类点之后。" },
        { label: "3类点需顶底分型", subKey: "bsp3_peak", type: "checkbox", tip: "3类点是否必须对应分型极值。" },
        { label: "类2s点跟随2类", subKey: "bsp2s_follow_2", type: "checkbox", tip: "类2s点是否必须紧跟在2类点之后。" },
        { label: "类2s点最大级别", subKey: "max_bsp2s_lv", type: "text", tip: "允许产生类2s点的最大中枢级别。" },
        { label: "严格3类点", subKey: "strict_bsp3", type: "checkbox", tip: "是否使用更严格的3类买卖点判定逻辑。" },
        { label: "3a类点最大中枢数", subKey: "bsp3a_max_zs_cnt", type: "number", tip: "3a类点允许的最大中枢数量。" }
      ]
    },
    {
      title: "系统运行 (Sys)",
      key: "sys",
      color: "#334155",
      bgColor: "rgba(51, 65, 85, 0.08)",
      items: [
        { label: "数据检查", subKey: "kl_data_check", type: "checkbox", tip: "是否在加载时检查K线数据的完整性。" },
        { label: "打印警告", subKey: "print_warning", type: "checkbox", tip: "是否在控制台打印逻辑警告。" },
        { label: "打印错误时间", subKey: "print_err_time", type: "checkbox", tip: "警告中是否包含时间信息。" },
        { label: "步进触发", subKey: "trigger_step", type: "checkbox", tip: "回放模式的核心开关，必须保持开启。" }
      ]
    }
  ];

  const readmeTip = (text) => text;
  const sectionsFromReadme = [
    {
      title: "主逻辑 (Algo)",
      key: "algo",
      color: "#2563eb",
      bgColor: "rgba(37, 99, 235, 0.08)",
      items: [
        { label: "chan_algo", subKey: "chan_algo", type: "select", options: [
          { value: "classic", label: "classic" },
          { value: "new", label: "new" }
        ], tip: readmeTip("复盘扩展项：classic=工程原有笔/段/2段逻辑；new=新K线 -> 分型 -> 笔 -> 段 -> 2段递推逻辑。") }
      ]
    },
    {
      title: "笔 (Bi)",
      key: "bi",
      color: "#d97706",
      bgColor: "rgba(217, 119, 6, 0.08)",
      items: [
        { label: "bi_algo", subKey: "bi_algo", type: "select", options: [
          { value: "normal", label: "normal" },
          { value: "fx", label: "fx" }
        ], tip: readmeTip("README.md：bi_algo 笔算法，默认为 normal。normal：按缠论笔定义来算；fx：顶底分形即成笔。") },
        { label: "bi_strict", subKey: "bi_strict", type: "checkbox", tip: readmeTip("README.md：bi_strict 是否只用严格笔（bi_algo=normal时有效），默认为 True。这里的严格笔只考虑顶底分形之间相隔几个合并K线。") },
        { label: "gap_as_kl", subKey: "gap_as_kl", type: "checkbox", tip: readmeTip("README.md：gap_as_kl 缺口是否处理成一根K线，默认为 True。当前复盘默认 False。") },
        { label: "bi_end_is_peak", subKey: "bi_end_is_peak", type: "checkbox", tip: readmeTip("README.md：bi_end_is_peak 笔的尾部是否是整笔中最低/最高，默认为 True。") },
        { label: "bi_fx_check", subKey: "bi_fx_check", type: "select", options: [
          { value: "strict", label: "strict" },
          { value: "totally", label: "totally" },
          { value: "loss", label: "loss" },
          { value: "half", label: "half" }
        ], tip: readmeTip("README.md：bi_fx_check 检查笔顶底分形是否成立的方法。strict(默认)：底分型的最低点必须比顶分型3元素最低点的最小值还低，顶分型反之。totally：底分型3元素的最高点必须必顶分型三元素的最低点还低。loss：底分型的最低点比顶分型中间元素低点还低，顶分型反之。half：对于上升笔，底分型的最低点比顶分型前两元素最低点还低，顶分型的最高点比底分型后两元素高点还高；下降笔反之。") },
        { label: "bi_allow_sub_peak", subKey: "bi_allow_sub_peak", type: "checkbox", tip: readmeTip("README.md：bi_allow_sub_peak 是否允许次高点成笔，默认为 True。") }
      ]
    },
    {
      title: "线段 (Seg)",
      key: "seg",
      color: "#059669",
      bgColor: "rgba(5, 150, 105, 0.1)",
      items: [
        { label: "seg_algo", subKey: "seg_algo", type: "select", options: [
          { value: "chan", label: "chan" },
          { value: "1+1", label: "1+1" },
          { value: "break", label: "break" }
        ], tip: readmeTip("README.md：seg_algo 线段计算方法。chan：利用特征序列来计算（默认）；1+1：都业华版本 1+1 终结算法；break：线段破坏定义来计算线段。") },
        { label: "left_seg_method", subKey: "left_seg_method", type: "select", options: [
          { value: "peak", label: "peak" },
          { value: "all", label: "all" }
        ], tip: readmeTip("README.md：left_seg_method 剩余那些不能归入确定线段的笔如何处理成段。all：收集至最后一个方向正确的笔，成为一段；peak：如果有个靠谱的新的极值，那么分成两段（默认）。") }
      ]
    },
    {
      title: "中枢 (ZS)",
      key: "zs",
      color: "#ea580c",
      bgColor: "rgba(234, 88, 12, 0.08)",
      items: [
        { label: "zs_combine", subKey: "zs_combine", type: "checkbox", tip: readmeTip("README.md：zs_combine 是否进行中枢合并，默认为 True。") },
        { label: "zs_combine_mode", subKey: "zs_combine_mode", type: "select", options: [
          { value: "zs", label: "zs" },
          { value: "peak", label: "peak" }
        ], tip: readmeTip("README.md：zs_combine_mode 中枢合并模式。zs：两中枢区间有重叠才合并（默认）；peak：两中枢有K线重叠就合并。") },
        { label: "one_bi_zs", subKey: "one_bi_zs", type: "checkbox", tip: readmeTip("README.md：one_bi_zs 是否需要计算只有一笔的中枢（分析趋势时会用到），默认为 False。") },
        { label: "zs_algo", subKey: "zs_algo", type: "select", options: [
          { value: "normal", label: "normal" },
          { value: "over_seg", label: "over_seg" },
          { value: "auto", label: "auto" }
        ], tip: readmeTip("README.md：zs_algo 中枢算法 normal/over_seg/auto（段内中枢/跨段中枢/自动），默认为 normal。") }
      ]
    },
    {
      title: "指标 (Ind)",
      key: "ind",
      color: "#6366f1",
      bgColor: "rgba(99, 102, 241, 0.08)",
      items: [
        { label: "mean_metrics", subKey: "mean_metrics", type: "text", placeholder: "5,20", tip: readmeTip("README.md：mean_metrics 均线计算周期（用于生成特征及绘图时使用），默认为空[]。例子：[5,20]。") },
        { label: "trend_metrics", subKey: "trend_metrics", type: "text", placeholder: "20,60", tip: readmeTip("README.md：trend_metrics 计算上下轨道线周期，即 T 天内最高/低价格（用于生成特征及绘图时使用），默认为空[]。") },
        { label: "macd.fast", subKey: "macd_fast", type: "number", tip: readmeTip("README.md：macd.fast 默认为12。") },
        { label: "macd.slow", subKey: "macd_slow", type: "number", tip: readmeTip("README.md：macd.slow 默认为26。") },
        { label: "macd.signal", subKey: "macd_signal", type: "number", tip: readmeTip("README.md：macd.signal 默认为9。") },
        { label: "boll_n", subKey: "boll_n", type: "number", tip: readmeTip("README.md：boll_n 布林线参数 N，整数，默认为20。") },
        { label: "cal_demark", subKey: "cal_demark", type: "checkbox", tip: readmeTip("README.md：cal_demark 是否计算demark指标，默认为False。") },
        { label: "demark.demark_len", subKey: "demark_len", type: "number", tip: readmeTip("README.md：demark_len setup完成时长度，默认为9。") },
        { label: "demark.setup_bias", subKey: "setup_bias", type: "number", tip: readmeTip("README.md：setup_bias setup比较偏移量，默认为4。") },
        { label: "demark.countdown_bias", subKey: "countdown_bias", type: "number", tip: readmeTip("README.md：countdown_bias countdown比较偏移量，默认为2。") },
        { label: "demark.max_countdown", subKey: "max_countdown", type: "number", tip: readmeTip("README.md：max_countdown 最大countdown数，默认为13。") },
        { label: "demark.tiaokong_st", subKey: "tiaokong_st", type: "checkbox", tip: readmeTip("README.md：tiaokong_st 序列真实起始位置计算时，如果setup第一根跳空，是否需要取前一根收盘价，默认为True。") },
        { label: "demark.setup_cmp2close", subKey: "setup_cmp2close", type: "checkbox", tip: readmeTip("README.md：setup_cmp2close setup计算当前K线的收盘价对比的是 setup_bias 根K线前的close，如果不是，下跌setup对比的是low，上升对比的是close，默认为True。") },
        { label: "demark.countdown_cmp2close", subKey: "countdown_cmp2close", type: "checkbox", tip: readmeTip("README.md：countdown_cmp2close countdown计算当前K线的收盘价对比的是 countdown_bias 根K线前的close，如果不是，下跌setup对比的是low，上升对比的是close，默认为True。") },
        { label: "cal_rsi", subKey: "cal_rsi", type: "checkbox", tip: readmeTip("README.md：cal_rsi 是否计算rsi指标，默认为False。") },
        { label: "rsi_cycle", subKey: "rsi_cycle", type: "number", tip: readmeTip("CChanConfig：rsi_cycle 默认为14。") },
        { label: "cal_kdj", subKey: "cal_kdj", type: "checkbox", tip: readmeTip("README.md：cal_kdj 是否计算kdj指标，默认为False。") },
        { label: "kdj_cycle", subKey: "kdj_cycle", type: "number", tip: readmeTip("CChanConfig：kdj_cycle 默认为9。") }
      ]
    },
    {
      title: "买卖点 (BSP)",
      key: "bsp",
      color: "#be123c",
      bgColor: "rgba(190, 18, 60, 0.08)",
      items: [
        { label: "divergence_rate", subKey: "divergence_rate", type: "text", tip: readmeTip("README.md：divergence_rate 1类买卖点背驰比例，即离开中枢的笔的 MACD 指标相对于进入中枢的笔，默认为0.9。当前复盘默认 inf。") },
        { label: "min_zs_cnt", subKey: "min_zs_cnt", type: "number", tip: readmeTip("README.md：min_zs_cnt 1类买卖点至少要经历几个中枢，默认为1。") },
        { label: "bsp1_only_multibi_zs", subKey: "bsp1_only_multibi_zs", type: "checkbox", tip: readmeTip("README.md：bsp1_only_multibi_zs：min_zs_cnt 计算的中枢至少3笔（少于3笔是因为开启了 one_bi_zs 参数），默认为 True。") },
        { label: "max_bs2_rate", subKey: "max_bs2_rate", type: "number", tip: readmeTip("README.md：max_bs2_rate 2类买卖点那一笔回撤最大比例，默认为0.9999。注：如果是1.0，那么相当于允许回测到1类买卖点的位置。") },
        { label: "bs1_peak", subKey: "bs1_peak", type: "checkbox", tip: readmeTip("README.md：bs1_peak 1类买卖点位置是否必须是整个中枢最低点，默认为 True。") },
        { label: "macd_algo", subKey: "macd_algo", type: "select", options: [
          { value: "peak", label: "peak" },
          { value: "full_area", label: "full_area" },
          { value: "area", label: "area" },
          { value: "slope", label: "slope" },
          { value: "amp", label: "amp" },
          { value: "diff", label: "diff" },
          { value: "amount", label: "amount" },
          { value: "volumn", label: "volumn" },
          { value: "amount_avg", label: "amount_avg" },
          { value: "volumn_avg", label: "volumn_avg" },
          { value: "turnrate_avg", label: "turnrate_avg" },
          { value: "rsi", label: "rsi" }
        ], tip: readmeTip("README.md：macd_algo MACD指标算法：peak/full_area/area/slope/amp/diff/amount/volumn/amount_avg/volumn_avg/turnrate_avg/rsi。") },
        { label: "bs_type", subKey: "bs_type", type: "text", tip: readmeTip("README.md：bs_type 关注的买卖点类型，逗号分隔，默认 1,1p,2,2s,3a,3b。1,2：分别表示1、2、3类买卖点；2s：类二买卖点；1p：盘整背驰1类买卖点；3a：中枢出现在1类后面的3类买卖点；3b：中枢出现在1类前面的3类买卖点。") },
        { label: "bsp2_follow_1", subKey: "bsp2_follow_1", type: "checkbox", tip: readmeTip("README.md：bsp2_follow_1 2类买卖点是否必须跟在1类买卖点后面（用于小转大时1类买卖点因为背驰度不足没生成），默认为 True。") },
        { label: "bsp3_follow_1", subKey: "bsp3_follow_1", type: "checkbox", tip: readmeTip("README.md：bsp3_follow_1 3类买卖点是否必须跟在1类买卖点后面（用于小转大时1类买卖点因为背驰度不足没生成），默认为 True。") },
        { label: "bsp3_peak", subKey: "bsp3_peak", type: "checkbox", tip: readmeTip("README.md：bsp3_peak 3类买卖点突破笔是不是必须突破中枢里面最高/最低的，默认为 False。") },
        { label: "bsp3a_max_zs_cnt", subKey: "bsp3a_max_zs_cnt", type: "number", tip: readmeTip("README.md：bsp3a_max_zs_cnt 3类买卖点最多可以跨越多少个中枢，默认为1。") },
        { label: "bsp2s_follow_2", subKey: "bsp2s_follow_2", type: "checkbox", tip: readmeTip("README.md：bsp2s_follow_2 类2买卖点是否必须跟在2类买卖点后面（2类买卖点可能由于不满足 max_bs2_rate 最大回测比例条件没生成），默认为 False。") },
        { label: "max_bsp2s_lv", subKey: "max_bsp2s_lv", type: "text", tip: readmeTip("README.md：max_bsp2s_lv 类2买卖点最大层级（距离2类买卖点的笔的距离/2），默认为None，不做限制。") },
        { label: "strict_bsp3", subKey: "strict_bsp3", type: "checkbox", tip: readmeTip("README.md：strict_bsp3 3类买卖点对应的中枢必须紧挨着1类买卖点，默认为 False。") }
      ]
    },
    {
      title: "系统运行 (Sys)",
      key: "sys",
      color: "#334155",
      bgColor: "rgba(51, 65, 85, 0.08)",
      items: [
        { label: "trigger_step", subKey: "trigger_step", type: "checkbox", tip: readmeTip("README.md：trigger_step 是否回放逐步返回，复盘逐K模式需要保持开启。") },
        { label: "skip_step", subKey: "skip_step", type: "number", tip: readmeTip("CChanConfig：skip_step 跳过前 N 步。") },
        { label: "kl_data_check", subKey: "kl_data_check", type: "checkbox", tip: readmeTip("CChanConfig：kl_data_check 是否检查K线数据完整性，默认为 True。") },
        { label: "max_kl_misalgin_cnt", subKey: "max_kl_misalgin_cnt", type: "number", tip: readmeTip("CChanConfig：max_kl_misalgin_cnt K线时间错位最大容忍数量，默认为2。") },
        { label: "max_kl_inconsistent_cnt", subKey: "max_kl_inconsistent_cnt", type: "number", tip: readmeTip("CChanConfig：max_kl_inconsistent_cnt K线不一致最大容忍数量，默认为5。") },
        { label: "auto_skip_illegal_sub_lv", subKey: "auto_skip_illegal_sub_lv", type: "checkbox", tip: readmeTip("CChanConfig：auto_skip_illegal_sub_lv 是否自动跳过非法子级别，默认为 False。") },
        { label: "print_warning", subKey: "print_warning", type: "checkbox", tip: readmeTip("CChanConfig：print_warning 是否打印警告，默认为 True；复盘默认 False。") },
        { label: "print_err_time", subKey: "print_err_time", type: "checkbox", tip: readmeTip("CChanConfig：print_err_time 警告中是否包含时间信息，默认为 True；复盘默认 False。") }
      ]
    }
  ];
  sections.length = 0;
  sections.push(...sectionsFromReadme);

  const buildLabelHtml = (item) => {
    const tipText = escapeHtmlAttr(item.tip || `${item.label}：用于调整缠论逻辑参数。`);
    const tipIcon = `<svg class="tip-icon" data-tip="${tipText}" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" style="display:inline-block; vertical-align:middle; cursor:help; color:#3b82f6; margin-left:4px;"><circle cx="12" cy="12" r="10"></circle><line x1="12" y1="16" x2="12" y2="12"></line><line x1="12" y1="8" x2="12.01" y2="8"></line></svg>`;
    return `${item.label}${tipIcon}`;
  };

  sections.forEach(sec => {
    const section = document.createElement("div");
    section.className = "settingsSection";
    section.style.background = sec.bgColor;
    section.innerHTML = `<div class="settingsSectionTitle" style="color:${sec.color}">${sec.title}</div>`;
    
    const grid = document.createElement("div");
    grid.className = "settingsGrid";
    
    sec.items.forEach(item => {
      const itemDiv = document.createElement("div");
      itemDiv.className = "settingsItem";
      const label = document.createElement("label");
      label.innerHTML = buildLabelHtml(item);
      
      let input;
      let val;
      if (item.subKey === "macd_fast") val = (chanConfig.macd && chanConfig.macd.fast) || 12;
      else if (item.subKey === "macd_slow") val = (chanConfig.macd && chanConfig.macd.slow) || 26;
      else if (item.subKey === "macd_signal") val = (chanConfig.macd && chanConfig.macd.signal) || 9;
      else if (item.subKey === "demark_len") val = (chanConfig.demark && chanConfig.demark.demark_len) || 9;
      else if (item.subKey === "setup_bias") val = (chanConfig.demark && chanConfig.demark.setup_bias) || 4;
      else if (item.subKey === "countdown_bias") val = (chanConfig.demark && chanConfig.demark.countdown_bias) || 2;
      else if (item.subKey === "max_countdown") val = (chanConfig.demark && chanConfig.demark.max_countdown) || 13;
      else if (item.subKey === "tiaokong_st") val = chanConfig.demark ? chanConfig.demark.tiaokong_st !== false : true;
      else if (item.subKey === "setup_cmp2close") val = chanConfig.demark ? chanConfig.demark.setup_cmp2close !== false : true;
      else if (item.subKey === "countdown_cmp2close") val = chanConfig.demark ? chanConfig.demark.countdown_cmp2close !== false : true;
      else val = chanConfig[item.subKey];

      if (item.type === "select") {
        input = document.createElement("select");
        item.options.forEach(opt => {
          const o = document.createElement("option");
          o.value = opt.value;
          o.textContent = opt.label;
          if (String(opt.value) === String(val)) o.selected = true;
          input.appendChild(o);
        });
      } else if (item.type === "checkbox") {
        input = document.createElement("input");
        input.type = "checkbox";
        input.checked = !!val;
        input.style.width = "auto";
        itemDiv.style.flexDirection = "row";
        itemDiv.style.alignItems = "center";
        itemDiv.style.justifyContent = "space-between";
      } else {
        input = document.createElement("input");
        input.type = item.type;
        input.value = val !== undefined ? val : "";
        if (item.type === "number") input.step = "any";
        if (item.placeholder) input.placeholder = item.placeholder;
      }
      input.dataset.key = item.subKey;
      itemDiv.appendChild(label);
      itemDiv.appendChild(input);
      grid.appendChild(itemDiv);
    });
    section.appendChild(grid);
    container.appendChild(section);
  });
  initTooltips();
}

function chanSettingDisplayKey(key) {
  const map = {
    macd_fast: "macd.fast",
    macd_slow: "macd.slow",
    macd_signal: "macd.signal",
    demark_len: "demark.demark_len",
    setup_bias: "demark.setup_bias",
    countdown_bias: "demark.countdown_bias",
    max_countdown: "demark.max_countdown",
    tiaokong_st: "demark.tiaokong_st",
    setup_cmp2close: "demark.setup_cmp2close",
    countdown_cmp2close: "demark.countdown_cmp2close",
  };
  return map[key] || key;
}

function chanSettingValueByInputKey(cfg, key) {
  if (!cfg) return undefined;
  if (key === "macd_fast") return cfg.macd ? cfg.macd.fast : undefined;
  if (key === "macd_slow") return cfg.macd ? cfg.macd.slow : undefined;
  if (key === "macd_signal") return cfg.macd ? cfg.macd.signal : undefined;
  if (key === "demark_len") return cfg.demark ? cfg.demark.demark_len : undefined;
  if (key === "setup_bias") return cfg.demark ? cfg.demark.setup_bias : undefined;
  if (key === "countdown_bias") return cfg.demark ? cfg.demark.countdown_bias : undefined;
  if (key === "max_countdown") return cfg.demark ? cfg.demark.max_countdown : undefined;
  if (key === "tiaokong_st") return cfg.demark ? cfg.demark.tiaokong_st : undefined;
  if (key === "setup_cmp2close") return cfg.demark ? cfg.demark.setup_cmp2close : undefined;
  if (key === "countdown_cmp2close") return cfg.demark ? cfg.demark.countdown_cmp2close : undefined;
  return cfg[key];
}

function normalizeChanSettingCompareValue(v) {
  if (Array.isArray(v)) return v.join(",");
  if (v == null) return "";
  if (typeof v === "number" && !Number.isFinite(v)) return String(v);
  return String(v);
}

function formatChanSettingValue(v) {
  if (Array.isArray(v)) return `[${v.join(",")}]`;
  if (v === "") return "空";
  if (v == null) return "None";
  return String(v);
}

function collectChanDefaultChanges(inputs) {
  const changes = [];
  const seen = new Set();
  inputs.forEach(input => {
    const key = input.dataset.key;
    if (!key || seen.has(key)) return;
    seen.add(key);
    const cur = chanSettingValueByInputKey(chanConfig, key);
    const def = chanSettingValueByInputKey(DEFAULT_CHAN_CONFIG, key);
    if (normalizeChanSettingCompareValue(cur) === normalizeChanSettingCompareValue(def)) return;
    changes.push(`您已更改了默认项 ${chanSettingDisplayKey(key)} 为 ${formatChanSettingValue(cur)}（默认 ${formatChanSettingValue(def)}）`);
  });
  return changes;
}

function saveChanSettings() {
  const inputs = $("chanSettingsContent").querySelectorAll("input, select");
  if (!chanConfig.macd) chanConfig.macd = { fast: 12, slow: 26, signal: 9 };
  if (!chanConfig.demark) chanConfig.demark = { demark_len: 9, setup_bias: 4, countdown_bias: 2, max_countdown: 13, tiaokong_st: true, setup_cmp2close: true, countdown_cmp2close: true };
  
  inputs.forEach(input => {
    const key = input.dataset.key;
    if (input.type === "checkbox") {
      if (key === "tiaokong_st" || key === "setup_cmp2close" || key === "countdown_cmp2close") chanConfig.demark[key] = input.checked;
      else chanConfig[key] = input.checked;
    } else if (input.tagName === "SELECT") {
      const val = input.value;
      chanConfig[key] = (val === "true" ? true : (val === "false" ? false : val));
    } else if (input.type === "number") {
      const numVal = parseFloat(input.value);
      if (key === "macd_fast") chanConfig.macd.fast = numVal;
      else if (key === "macd_slow") chanConfig.macd.slow = numVal;
      else if (key === "macd_signal") chanConfig.macd.signal = numVal;
      else if (key === "demark_len" || key === "setup_bias" || key === "countdown_bias" || key === "max_countdown") chanConfig.demark[key] = numVal;
      else chanConfig[key] = numVal;
    } else if (key === "mean_metrics" || key === "trend_metrics" || key === "bs_type") {
      chanConfig[key] = input.value; // Store as string for easy editing
    } else {
      chanConfig[key] = input.value;
    }
  });

  const defaultChanges = collectChanDefaultChanges(inputs);
  if (defaultChanges.length > 0) {
    const preview = defaultChanges.slice(0, 20).join("\n");
    const more = defaultChanges.length > 20 ? `\n……另有 ${defaultChanges.length - 20} 项默认项被更改。` : "";
    if (!confirmAndLog(`检测到缠论配置默认项变更：\n${preview}${more}\n\n是否确认保存这些更改？`)) {
      return;
    }
  }
  
  // Create a deep copy for the final config to be sent to backend
  const finalConfig = JSON.parse(JSON.stringify(chanConfig));
  applyRhythmCalcModeToChanConfig(finalConfig);
  
  // Post-process list fields
  ["mean_metrics", "trend_metrics"].forEach(k => {
    if (typeof finalConfig[k] === "string") {
      finalConfig[k] = finalConfig[k].split(/[,，\s]+/).map(v => parseInt(v.trim())).filter(v => !isNaN(v));
    }
  });

  storageSet("chan_logic_config", JSON.stringify(chanConfig));

  // If session is already loaded, prompt for reconfig
  if (lastPayload && lastPayload.ready) {
    if (confirmAndLog("更改缠论配置将导致从第1根K线重新计算到当前位置，且之前的模拟持仓数据（若有）将被清除。是否继续并应用配置？")) {
      const ctl = prepareCancelableLoading("正在重新计算缠论逻辑...", "配置重算：开始按新缠论配置重建会话…");
      api("/api/reconfig", { chan_config: finalConfig }, "POST", { signal: ctl.signal })
        .then(payload => {
          refreshUI(payload);
          void fetchChipKlineAllLazy(payload);
          if (payload.bsp_history && payload.bsp_history.length > 0) {
            payload.bsp_history.forEach(h => {
              setMsg(`[重算] 发现 ${h.display_label || h.label} @K线:${h.x}`, true);
            });
          }
          showToast(payload.message || "配置已更新，逻辑已重算。");
          closeChanSettings();
        })
        .catch(e => {
          if (e && (e.name === "AbortError" || String(e.message || "").indexOf("终止") >= 0 || Number(e.httpStatus) === 499)) {
            showToast("已终止配置重算。");
          } else {
            showToast("配置应用失败：" + e.message);
          }
        })
        .finally(() => {
          finishCancelableLoading(false);
        });
    }
  } else {
    showToast("缠论配置已保存，将在加载会话时生效。");
    closeChanSettings();
  }
}

function resetChanSettings() {
  if (confirmAndLog("确定要恢复默认缠论配置吗？")) {
    chanConfig = JSON.parse(JSON.stringify(DEFAULT_CHAN_CONFIG));
    renderChanSettingsForm();
  }
}

function captureChartSettingsDraftBaseline() {
  chartSettingsDraftBaseline = {
    chartConfig: JSON.parse(JSON.stringify(chartConfig)),
    chartConfigStore: JSON.parse(JSON.stringify(chartConfigStore)),
    dataFormConfig: JSON.parse(JSON.stringify(dataFormConfig)),
    selectedMainIndicatorSlot,
    selectedSubIndicatorSlot,
    indicatorMainSlots: JSON.parse(JSON.stringify(indicatorMainSlots)),
    indicatorSubSlots: JSON.parse(JSON.stringify(indicatorSubSlots)),
    indicatorMainVarVisible,
    indicatorSubVarVisible,
    crosshairEnabled,
  };
}

function restoreChartSettingsDraftBaseline() {
  if (!chartSettingsDraftBaseline) return;
  const b = chartSettingsDraftBaseline;
  chartConfig = JSON.parse(JSON.stringify(b.chartConfig));
  chartConfigStore = JSON.parse(JSON.stringify(b.chartConfigStore));
  dataFormConfig = JSON.parse(JSON.stringify(b.dataFormConfig));
  selectedMainIndicatorSlot = b.selectedMainIndicatorSlot;
  selectedSubIndicatorSlot = b.selectedSubIndicatorSlot;
  indicatorMainSlots = JSON.parse(JSON.stringify(b.indicatorMainSlots));
  indicatorSubSlots = JSON.parse(JSON.stringify(b.indicatorSubSlots));
  indicatorMainVarVisible = !!b.indicatorMainVarVisible;
  indicatorSubVarVisible = !!b.indicatorSubVarVisible;
  crosshairEnabled = b.crosshairEnabled;
  chartSettingsDraftBaseline = null;
}

/** 将当前可见表单写入内存草稿（切换分组前调用，不写 localStorage） */
function flushChartSettingsFormToMemory() {
  const root = $("settingsContent");
  if (!root || !isSettingsOpen()) return;
  const inputs = root.querySelectorAll("input, select");
  let nextDataFormMode = dataFormConfig.mode;
  let nextDataFormQuantity = dataFormConfig.quantity;
  let nextDataFormQuantityAlloc = dataFormConfig.quantityAlloc;
  let nextDataFeedMode = dataFormConfig.feedMode;
  let nextKlinePresentation = dataFormConfig.klinePresentation;
  let nextOfflineDataCustom = dataFormConfig.offlineDataCustom;
  inputs.forEach((input) => {
    const key = input.dataset.key;
    const subkey = input.dataset.subkey;
    const mkt = input.dataset.multiKt;
    if (mkt && key && subkey && !subkey.endsWith("-text")) {
      let val;
      if (input.type === "checkbox") val = input.checked;
      else if (input.type === "number") val = parseFloat(input.value);
      else val = input.value;
      if (subkey === "dash" && typeof val === "string") {
        const arr = val.split(",").map((n) => parseFloat(n.trim())).filter((n) => !Number.isNaN(n));
        val = arr.length > 0 ? arr : null;
      }
      if (key === "rhythmLine" && subkey === "maxLayer") val = Math.max(0, Math.min(9, Math.floor(Number(val))));
      if (key === "rhythmLine" && subkey === "calcMode") val = normalizeRhythmCalcMode(val);
      if (!chartConfigStore.multiPerK) chartConfigStore.multiPerK = {};
      if (!chartConfigStore.multiPerK[mkt]) chartConfigStore.multiPerK[mkt] = {};
      if (!chartConfigStore.multiPerK[mkt][key]) chartConfigStore.multiPerK[mkt][key] = {};
      chartConfigStore.multiPerK[mkt][key][subkey] = val;
      return;
    }
    const mokt = input.dataset.moverlayKt;
    const mosub = input.dataset.moverlaySubkey;
    if (mokt && mosub) {
      let valMo;
      if (input.type === "number") valMo = parseFloat(input.value);
      else valMo = input.value;
      if (!chartConfig.multiOverlay) chartConfig.multiOverlay = JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG.multiOverlay));
      if (!chartConfig.multiOverlay.layers) chartConfig.multiOverlay.layers = {};
      if (!chartConfig.multiOverlay.layers[mokt]) chartConfig.multiOverlay.layers[mokt] = {};
      if (input.type === "number") {
        if (!Number.isFinite(valMo)) delete chartConfig.multiOverlay.layers[mokt][mosub];
        else {
          let v = valMo;
          if (/Alpha$/.test(mosub) || mosub === "alpha" || mosub === "lineAlpha") v = Math.min(1, Math.max(0.05, v));
          chartConfig.multiOverlay.layers[mokt][mosub] = v;
        }
      } else chartConfig.multiOverlay.layers[mokt][mosub] = valMo;
      return;
    }
    if (!key || !subkey || subkey.endsWith("-text")) return;
    let val;
    if (input.type === "checkbox") val = input.checked;
    else if (input.type === "number") val = parseFloat(input.value);
    else val = input.value;
    if (key === "theme_section") chartConfig.theme = val;
    else if (key === "shared_bsp_bottom" && subkey === "enabled") chartConfigStore.shared.showBottomBsp = !!val;
    else if (key === "dataForm") {
      if (subkey === "mode") nextDataFormMode = normalizeDataFormMode(val);
      if (subkey === "quantity") nextDataFormQuantity = clampDataFormQuantity(val, getRawKlineCount() || dataFormConfig.quantity || 1);
      if (subkey === "quantityAlloc") nextDataFormQuantityAlloc = normalizeDataFormQuantityAlloc(val);
      if (subkey === "feedMode") nextDataFeedMode = normalizeDataFeedMode(val);
      if (subkey === "klinePresentation") nextKlinePresentation = normalizeKlinePresentationMode(val);
      if (subkey === "offlineDataCustom") nextOfflineDataCustom = normalizeOfflineDataCustom(val);
    } else if (key === "indicators") {
      if (subkey === "mainSlot") selectedMainIndicatorSlot = Number(val);
      else if (subkey === "subSlot") selectedSubIndicatorSlot = Number(val);
      else if (subkey === "mainVarVisible") indicatorMainVarVisible = !!val;
      else if (subkey === "subVarVisible") indicatorSubVarVisible = !!val;
      else if (subkey === "mainType") {
        const selected = [];
        root.querySelectorAll(".indicator-check-main").forEach((c) => { if (c.checked) selected.push(c.value); });
        indicatorMainSlots[String(selectedMainIndicatorSlot)] = selected;
      } else if (subkey === "subType") {
        const selected = [];
        root.querySelectorAll(".indicator-check-sub").forEach((c) => { if (c.checked) selected.push(c.value); });
        indicatorSubSlots[String(selectedSubIndicatorSlot)] = selected;
      }
    } else if (key === "crosshair" && subkey === "enabled") {
      crosshairEnabled = !!val;
      if (!chartConfig.crosshair) chartConfig.crosshair = {};
      chartConfig.crosshair.enabled = crosshairEnabled;
    } else if (key && subkey) {
      if (subkey === "dash" && typeof val === "string") {
        const arr = val.split(",").map((n) => parseFloat(n.trim())).filter((n) => !Number.isNaN(n));
        val = arr.length > 0 ? arr : null;
      }
      if (key === "rhythmLine" && subkey === "maxLayer") val = Math.max(0, Math.min(9, Math.floor(Number(val))));
      if (key === "rhythmLine" && subkey === "calcMode") val = normalizeRhythmCalcMode(val);
      if (!chartConfig[key]) chartConfig[key] = {};
      chartConfig[key][subkey] = val;
    }
  });
  root.querySelectorAll('input[type="text"][data-multi-kt]').forEach((textInput) => {
    const sk = textInput.dataset.subkey || "";
    if (!sk.endsWith("-text")) return;
    const mainKey = sk.slice(0, -5);
    const mkt = textInput.dataset.multiKt;
    const key = textInput.dataset.key;
    if (!mkt || !key) return;
    const col = textInput.parentElement && textInput.parentElement.querySelector(`input[type="color"][data-multi-kt="${mkt}"][data-key="${key}"][data-subkey="${mainKey}"]`);
    const v = (textInput.value && String(textInput.value).trim()) || (col && col.value) || "#000000";
    if (!chartConfigStore.multiPerK) chartConfigStore.multiPerK = {};
    if (!chartConfigStore.multiPerK[mkt]) chartConfigStore.multiPerK[mkt] = {};
    if (!chartConfigStore.multiPerK[mkt][key]) chartConfigStore.multiPerK[mkt][key] = {};
    chartConfigStore.multiPerK[mkt][key][mainKey] = v;
  });
  dataFormConfig.mode = nextDataFormMode;
  dataFormConfig.quantity = nextDataFormQuantity;
  dataFormConfig.quantityAlloc = nextDataFormQuantityAlloc;
  dataFormConfig.feedMode = nextDataFeedMode;
  dataFormConfig.klinePresentation = nextKlinePresentation;
  dataFormConfig.offlineDataCustom = nextOfflineDataCustom;
  ensureCustomLevelDefaults(chartConfig);
}

function openSettings() {
  if (isSystemSettingsOpen()) closeSystemSettings();
  if (!chartConfig.crosshair) chartConfig.crosshair = {};
  chartConfig.crosshair.enabled = !!crosshairEnabled;
  captureChartSettingsDraftBaseline();
  const panel = $("settingsModal") && $("settingsModal").querySelector(".panel");
  if (panel) panel.classList.add("chart-settings-panel");
  renderSettingsForm();
  $("settingsModal").classList.add("show");
}

let chartSettingsCloseKeepDraft = false;

function closeSettings() {
  if (!chartSettingsCloseKeepDraft) restoreChartSettingsDraftBaseline();
  chartSettingsCloseKeepDraft = false;
  $("settingsModal").classList.remove("show");
  const panel = $("settingsModal") && $("settingsModal").querySelector(".panel");
  if (panel) panel.classList.remove("chart-settings-panel");
}

function isSettingsOpen() {
  return $("settingsModal").classList.contains("show");
}

function openSystemSettings() {
  if (isSettingsOpen()) closeSettings();
  renderSystemSettingsForm();
  $("systemSettingsModal").classList.add("show");
}

function closeSystemSettings() {
  $("systemSettingsModal").classList.remove("show");
}

function isSystemSettingsOpen() {
  return $("systemSettingsModal").classList.contains("show");
}

const MULTI_LAYER_STYLE_KEYS = new Set(["fx", "fract", "bi", "seg", "segseg", "fractZs", "biZs", "segZs", "segsegZs", "candle", "bspBi", "bspSeg", "bspSegseg", "rhythmLine", "rhythmHit", "klineCombineFrame"]);
function multiLayerStyleKeys() {
  const keys = new Set(MULTI_LAYER_STYLE_KEYS);
  customSegmentLevelsFromConfig(chartConfig).forEach((level) => {
    keys.add(lineConfigKeyForLevel(level));
    keys.add(zsConfigKeyForLevel(level));
    keys.add(bspConfigKeyForLevel(level));
  });
  return keys;
}

/** 图表显示：级别 / 中枢 / 买卖点 合并导航（子项仍用原 chartConfig 键持久化） */
const CHART_SETTINGS_BRANCH_GROUPS = [
  {
    key: "__branch_level__",
    title: "级别",
    color: "#b45309",
    bgColor: "rgba(180, 83, 9, 0.1)",
    tip: "分型 / 笔 / 段 / 2段 的缠论线颜色与粗细。\n持久化键：fract、bi、seg、segseg（与旧版相同）。\n多周期单图可在「多周期·某周期」中按周期覆盖。",
    childKeys: ["fract", "bi", "seg", "segseg"],
  },
  {
    key: "__branch_zs__",
    title: "中枢",
    color: "#c2410c",
    bgColor: "rgba(194, 65, 12, 0.1)",
    tip: "分型中枢 / 笔中枢 / 段中枢 / 2段中枢。\n持久化键：fractZs、biZs、segZs、segsegZs。",
    childKeys: ["fractZs", "biZs", "segZs", "segsegZs"],
  },
  {
    key: "__branch_bsp__",
    title: "买卖点",
    color: "#be123c",
    bgColor: "rgba(190, 18, 60, 0.1)",
    tip: "K 线下方总开关与各层买卖点样式。\n总开关：shared.showBottomBsp；笔/段/2段：bspBi、bspSeg、bspSegseg。\n逐K喂数据下按当时当下冻结：同级别、同锚点、同方向只保留首次识别标签；未来演化出的组合标签不回写、不追加。",
    childKeys: ["shared_bsp_bottom", "bspBi", "bspSeg", "bspSegseg"],
  },
];
const CHART_SETTINGS_BRANCH_CHILD_KEYS = new Set(CHART_SETTINGS_BRANCH_GROUPS.flatMap((g) => g.childKeys));
const CHART_SETTINGS_BRANCH_BY_KEY = Object.fromEntries(CHART_SETTINGS_BRANCH_GROUPS.map((g) => [g.key, g]));

function makeCustomLevelLineSection(level) {
  const label = segLevelLabel(level);
  const key = lineConfigKeyForLevel(level);
  const cfg = chartConfig[key] || {};
  return {
    title: label,
    key,
    color: cfg.color || "#7c3aed",
    bgColor: "rgba(124, 58, 237, 0.08)",
    items: [
      { label: `${label}颜色`, subKey: "color", type: "color" },
      { label: "粗细(确定)", subKey: "widthSure", type: "number", min: 0.1, max: 14, step: 0.1 },
      { label: "粗细(未完成)", subKey: "widthUnsure", type: "number", min: 0.1, max: 14, step: 0.1 },
    ],
  };
}

function makeCustomLevelZsSection(level) {
  const label = segLevelLabel(level);
  const key = zsConfigKeyForLevel(level);
  return {
    title: `${label}中枢`,
    key,
    color: "#6d28d9",
    bgColor: "rgba(109, 40, 217, 0.08)",
    items: [
      { label: `启用${label}中枢`, subKey: "enabled", type: "checkbox", tip: "关闭后首包不构建/下发该级别中枢；会话后开启时按需懒加载。" },
      { label: `${label}中枢颜色`, subKey: "color", type: "color" },
      { label: `${label}中枢粗细`, subKey: "width", type: "number", min: 0.1, max: 5, step: 0.1 },
    ],
  };
}

function makeCustomLevelBspSection(level) {
  const label = segLevelLabel(level);
  const key = bspConfigKeyForLevel(level);
  return {
    title: `${label}买卖点`,
    key,
    color: "#7f1d1d",
    bgColor: "rgba(127, 29, 29, 0.08)",
    items: [
      { label: `启用${label}买卖点`, subKey: "enabled", type: "checkbox", tip: `关闭后加载会话首包不计算/下发${label}买卖点；会话后再开启会按需懒加载。逐K喂数据模式下，当下性优先，历史买卖点写入后冻结。` },
      { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 30 },
      { label: "连线颜色", subKey: "lineColor", type: "color" },
      { label: "连线粗细", subKey: "lineWidth", type: "number", min: 0.1, max: 5, step: 0.1 },
      { label: "竖线延长线", subKey: "showLowerExtension", type: "checkbox", tip: "控制买卖点从K线低点向下连接到底部信号框的竖线显示。" },
      { label: "连线线型", subKey: "lineStyle", type: "select", options: [
        { value: "dashed", label: "虚线" },
        { value: "solid", label: "实线" },
        { value: "dotted", label: "点线" },
      ]},
    ],
  };
}

function chartSettingsBranchChildKeys(branchKey) {
  const branch = CHART_SETTINGS_BRANCH_BY_KEY[branchKey];
  const keys = branch ? branch.childKeys.slice() : [];
  customSegmentLevelsFromConfig(chartConfig).forEach((level) => {
    if (branchKey === "__branch_level__") keys.push(lineConfigKeyForLevel(level));
    if (branchKey === "__branch_zs__") keys.push(zsConfigKeyForLevel(level));
    if (branchKey === "__branch_bsp__") keys.push(bspConfigKeyForLevel(level));
  });
  return keys;
}

function chartSettingsBranchChildKeySet() {
  const keys = new Set(CHART_SETTINGS_BRANCH_CHILD_KEYS);
  CHART_SETTINGS_BRANCH_GROUPS.forEach((b) => chartSettingsBranchChildKeys(b.key).forEach((k) => keys.add(k)));
  return keys;
}

function persistChartSettingsBranchChildSel() {
  storageSet("chan_chart_settings_branch_sel", JSON.stringify(chartSettingsBranchChildSel));
}

/** 旧版左侧直接点「分型/笔中枢」等时，映射到合并组并记住子项 */
function normalizeChartSettingsCascadeSelKey(key) {
  if (!key || !chartSettingsBranchChildKeySet().has(key)) return key;
  const branch = CHART_SETTINGS_BRANCH_GROUPS.find((b) => chartSettingsBranchChildKeys(b.key).includes(key));
  if (!branch) return key;
  if (!chartSettingsBranchChildSel[branch.key]) chartSettingsBranchChildSel[branch.key] = key;
  persistChartSettingsBranchChildSel();
  return branch.key;
}

/** 左侧导航：隐藏已并入「级别/中枢/买卖点」的子节 */
function buildChartSettingsNavSections(baseSections) {
  const visible = buildVisibleChartSettingsSections(baseSections);
  const nav = [];
  const inserted = new Set();
  visible.forEach((sec) => {
    if (chartSettingsBranchChildKeySet().has(sec.key)) {
      const branch = CHART_SETTINGS_BRANCH_GROUPS.find((b) => chartSettingsBranchChildKeys(b.key).includes(sec.key));
      if (branch && !inserted.has(branch.key)) {
        inserted.add(branch.key);
        nav.push({
          key: branch.key,
          title: branch.title,
          color: branch.color,
          bgColor: branch.bgColor,
          panel: "branch",
          branchKey: branch.key,
          childKeys: chartSettingsBranchChildKeys(branch.key),
          tip: branch.tip,
          items: [],
        });
      }
      return;
    }
    nav.push(sec);
  });
  return nav;
}

/** 图表显示设置：单品种多周期单图下按周期覆盖「缠论线/K 线蜡烛」等样式 */
function appendMultiLayerPerKStyleSections(container, sections, buildLabelHtml) {
  if (!$("chartMode") || $("chartMode").value !== "multi") return;
  const kts = collectKTypesMultiSelected();
  if (!kts.length) return;
  const styleKeys = multiLayerStyleKeys();
  const secs = sections.filter((s) => styleKeys.has(s.key));
  const wrap = document.createElement("div");
  wrap.className = "settingsSection";
  wrap.style.background = "rgba(30, 64, 175, 0.09)";
  wrap.innerHTML = `<div class="settingsSectionTitle" style="color:#1d4ed8">单品种多周期单图 · 各周期样式</div>
    <div class="muted" style="margin:0 0 10px 4px;font-size:12px;">以下为当前勾选的叠加周期分别配置（持久化在 chan_chart_config.multiPerK）。未填项使用默认值。全局「级别 / 中枢 / 买卖点」组内各项仍作用于单周期与双周期图。</div>`;
  container.appendChild(wrap);
  kts.forEach((kt) => {
    const det = document.createElement("details");
    det.style.margin = "6px 0";
    det.open = false;
    const sm = document.createElement("summary");
    sm.style.cursor = "pointer";
    sm.style.fontWeight = "600";
    sm.textContent = `${getKTypeLabelText(kt)}（${kt}）`;
    det.appendChild(sm);
    if (!chartConfigStore.multiPerK || typeof chartConfigStore.multiPerK !== "object") chartConfigStore.multiPerK = {};
    if (!chartConfigStore.multiPerK[kt] || typeof chartConfigStore.multiPerK[kt] !== "object") chartConfigStore.multiPerK[kt] = {};
    const layerMap = chartConfigStore.multiPerK[kt];
    secs.forEach((sec) => {
      const div = document.createElement("div");
      div.className = "settingsSection";
      div.style.background = sec.bgColor;
      div.innerHTML = `<div class="settingsSectionTitle" style="color:${sec.color}">${sec.title} · ${getKTypeLabelText(kt)}</div>`;
      const grid = document.createElement("div");
      grid.className = "settingsGrid";
      const sectionCfg = ensureObject(layerMap[sec.key], {});
      sec.items.forEach((item) => {
        let val = sectionCfg[item.subKey];
        if (val === undefined || val === null) {
          const d0 = DEFAULT_CHART_CONFIG[sec.key] || {};
          val = d0[item.subKey];
        }
        const itemDiv = document.createElement("div");
        itemDiv.className = "settingsItem";
        if (item.type === "select") {
          const opts = (item.options || []).map((o) => `<option value="${o.value}" ${String(val) === String(o.value) ? "selected" : ""}>${o.label}</option>`).join("");
          itemDiv.innerHTML = `<label>${buildLabelHtml(item)}</label><select data-multi-kt="${kt}" data-key="${sec.key}" data-subkey="${item.subKey}">${opts}</select>`;
        } else if (item.type === "checkbox") {
          itemDiv.innerHTML = `<label style="flex-direction:row;align-items:center;display:flex;"><input type="checkbox" data-multi-kt="${kt}" data-key="${sec.key}" data-subkey="${item.subKey}" ${val ? "checked" : ""} style="width:auto;margin-right:8px;">${item.label}</label>`;
        } else if (item.type === "color") {
          const safeVal = typeof val === "string" ? val : "#000000";
          itemDiv.innerHTML = `<label>${buildLabelHtml(item)}</label><div style="display:flex;align-items:center;gap:8px;"><input type="color" value="${safeVal.startsWith("#") ? safeVal : "#000000"}" data-multi-kt="${kt}" data-key="${sec.key}" data-subkey="${item.subKey}" style="width:40px;height:24px;padding:0;border:none;"><input type="text" value="${safeVal}" data-multi-kt="${kt}" data-key="${sec.key}" data-subkey="${item.subKey}-text" style="flex:1;height:24px;font-size:12px;font-family:monospace;"></div>`;
        } else if (item.type === "number") {
          const mn = item.min != null ? item.min : "";
          const mx = item.max != null ? item.max : "";
          const st = item.step != null ? item.step : "";
          itemDiv.innerHTML = `<label>${buildLabelHtml(item)}</label><input type="number" data-multi-kt="${kt}" data-key="${sec.key}" data-subkey="${item.subKey}" min="${mn}" max="${mx}" step="${st}" value="${val != null ? val : ""}">`;
        } else if (item.type === "text") {
          itemDiv.innerHTML = `<label>${buildLabelHtml(item)}</label><input type="text" data-multi-kt="${kt}" data-key="${sec.key}" data-subkey="${item.subKey}" value="${val != null ? String(val) : ""}" placeholder="${item.placeholder || ""}">`;
        }
        grid.appendChild(itemDiv);
      });
      div.appendChild(grid);
      det.appendChild(div);
    });
    wrap.appendChild(det);
  });
}

/** 多周期单图：各粗周期 multiOverlay.layers[kt] 蜡烛分项（持久化在 chartConfig.multiOverlay.layers） */
function appendMultiOverlayPerLayerFields(container, buildLabelHtml) {
  if (!$("chartMode") || $("chartMode").value !== "multi") return;
  const picked = collectKTypesMultiSelected();
  const driverKt = MULTI_KTYPE_ORDER.filter((k) => picked.includes(k))[0];
  const coarses = picked.filter((k) => k !== driverKt);
  if (coarses.length === 0) return;
  if (!chartConfig.multiOverlay) chartConfig.multiOverlay = JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG.multiOverlay));
  if (!chartConfig.multiOverlay.layers || typeof chartConfig.multiOverlay.layers !== "object") chartConfig.multiOverlay.layers = {};
  const mo = chartConfig.multiOverlay;
  const styleOpts = [
    { value: "grid", label: "网格" },
    { value: "dots", label: "点状" },
    { value: "hatch", label: "斜线阴影" },
    { value: "shade", label: "竖向明暗" },
    { value: "soft", label: "淡色平铺" },
  ];
  const wrap = document.createElement("div");
  wrap.className = "settingsSection";
  wrap.style.background = "rgba(124, 45, 18, 0.1)";
  wrap.innerHTML = `<div class="settingsSectionTitle" style="color:#9a3412">单品种多周期 · 各粗周期叠层蜡烛</div>
    <div class="muted" style="margin:0 0 10px 4px;font-size:12px;">驱动周期（最细勾选：${getKTypeLabelText(driverKt)}）使用上方「K线显示」整体透明度。以下为粗于驱动的各周期独立参数（保存到 multiOverlay.layers）。</div>`;
  container.appendChild(wrap);
  coarses.forEach((kt) => {
    if (!chartConfig.multiOverlay.layers[kt]) chartConfig.multiOverlay.layers[kt] = {};
    const L = chartConfig.multiOverlay.layers[kt];
    const det = document.createElement("details");
    det.style.margin = "6px 0";
    det.open = false;
    const sm = document.createElement("summary");
    sm.style.cursor = "pointer";
    sm.style.fontWeight = "600";
    sm.textContent = `${getKTypeLabelText(kt)}（${kt}）叠层`;
    det.appendChild(sm);
    const grid = document.createElement("div");
    grid.className = "settingsGrid";
    const items = [
      { label: "缠论线透明度 lineAlpha", subkey: "lineAlpha", type: "number", min: 0.05, max: 1, step: 0.02, def: mo.defaultAlpha, tip: "合并框/分型笔段等；默认取上方「缠论线默认透明度」。" },
      { label: "实体透明度 bodyAlpha", subkey: "bodyAlpha", type: "number", min: 0.05, max: 1, step: 0.02, def: mo.defaultCoarseBodyAlpha, tip: "大周期实心矩形。" },
      { label: "上影线透明度", subkey: "upperShadowAlpha", type: "number", min: 0.05, max: 1, step: 0.02, def: mo.defaultCoarseUpperShadowAlpha, tip: "" },
      { label: "下影线透明度", subkey: "lowerShadowAlpha", type: "number", min: 0.05, max: 1, step: 0.02, def: mo.defaultCoarseLowerShadowAlpha, tip: "" },
      { label: "上影线纹理", subkey: "upperShadowStyle", type: "select", options: styleOpts, def: mo.defaultUpperShadowStyle, tip: "" },
      { label: "下影线纹理", subkey: "lowerShadowStyle", type: "select", options: styleOpts, def: mo.defaultLowerShadowStyle, tip: "" },
      { label: "兼容旧字段 alpha", subkey: "alpha", type: "number", min: 0.05, max: 1, step: 0.02, def: null, tip: "旧版单一透明度；若新字段未填可继续用此项，保存迁移时会拆到 line/body/影线。" },
    ];
    items.forEach((it) => {
      let val = L[it.subkey];
      if ((val === undefined || val === null) && it.def != null) val = it.def;
      if (val === undefined || val === null) val = "";
      const itemDiv = document.createElement("div");
      itemDiv.className = "settingsItem";
      const tip = it.tip || "";
      const labelH = buildLabelHtml({ ...it, tip: tip || `${it.label}。` });
      if (it.type === "select") {
        const opts = (it.options || [])
          .map((o) => `<option value="${o.value}" ${String(val) === String(o.value) ? "selected" : ""}>${o.label}</option>`)
          .join("");
        itemDiv.innerHTML = `<label>${labelH}</label><select data-moverlay-kt="${kt}" data-moverlay-subkey="${it.subkey}">${opts}</select>`;
      } else {
        const mn = it.min != null ? it.min : "";
        const mx = it.max != null ? it.max : "";
        const st = it.step != null ? it.step : "";
        itemDiv.innerHTML = `<label>${labelH}</label><input type="number" data-moverlay-kt="${kt}" data-moverlay-subkey="${it.subkey}" min="${mn}" max="${mx}" step="${st}" value="${val !== "" ? val : ""}">`;
      }
      grid.appendChild(itemDiv);
    });
    det.appendChild(grid);
    wrap.appendChild(det);
  });
}

/** 图表显示设置：可见分组（含多周期动态项） */
function buildVisibleChartSettingsSections(baseSections) {
  const cmv = $("chartMode") ? String($("chartMode").value || "single") : "single";
  const out = baseSections.filter((s) => s.key !== "multiOverlay" || cmv === "multi");
  customSegmentLevelsFromConfig(chartConfig).forEach((level) => {
    out.push(makeCustomLevelLineSection(level));
    out.push(makeCustomLevelZsSection(level));
    out.push(makeCustomLevelBspSection(level));
  });
  if (cmv === "multi") {
    const picked = collectKTypesMultiSelected();
    const driverKt = MULTI_KTYPE_ORDER.filter((k) => picked.includes(k))[0];
    picked.forEach((kt) => {
      out.push({
        key: `__multiPerK_${kt}__`,
        title: `多周期·${getKTypeLabelText(kt)}`,
        color: "#1d4ed8",
        bgColor: "rgba(29, 78, 216, 0.08)",
        panel: "multiPerK",
        kt,
        items: [],
      });
    });
    picked.filter((k) => k !== driverKt).forEach((kt) => {
      out.push({
        key: `__moverlay_${kt}__`,
        title: `叠层蜡烛·${getKTypeLabelText(kt)}`,
        color: "#9a3412",
        bgColor: "rgba(124, 45, 18, 0.1)",
        panel: "moverlay",
        kt,
        items: [],
      });
    });
  }
  return out;
}

function resolveChartSettingsItemValue(sec, item) {
  if (sec.key === "theme_section") return chartConfig.theme;
  if (sec.key === "shared_bsp_bottom") return chartConfigStore.shared && chartConfigStore.shared.showBottomBsp !== false;
  if (sec.key === "dataForm") return dataFormConfig[item.subKey];
  if (sec.key === "indicators") {
    if (item.subKey === "mainSlot") return selectedMainIndicatorSlot;
    if (item.subKey === "subSlot") return selectedSubIndicatorSlot;
    if (item.subKey === "mainType") return indicatorMainSlots[String(selectedMainIndicatorSlot)] || [];
    if (item.subKey === "subType") return indicatorSubSlots[String(selectedSubIndicatorSlot)] || [];
    if (item.subKey === "mainVarVisible") return !!indicatorMainVarVisible;
    if (item.subKey === "subVarVisible") return !!indicatorSubVarVisible;
  }
  const sectionCfg = ensureObject(chartConfig[sec.key], {});
  return sectionCfg[item.subKey];
}

/** 渲染单项控件到父节点，返回 item 根元素 */
function appendChartSettingsItemTo(parent, sec, item, buildLabelHtml) {
  const val = resolveChartSettingsItemValue(sec, item);
  const sectionCfg = ensureObject(chartConfig[sec.key], {});
  const itemDiv = document.createElement("div");
  itemDiv.className = "settingsItem";
  const noPreview = new Set(["theme_section", "shared_bsp_bottom", "indicators", "toast", "xAxis", "yAxis", "multiOverlay"]);
  if (!noPreview.has(sec.key)) {
    const previewLine = document.createElement("div");
    previewLine.style.height = "2px";
    previewLine.style.width = "100%";
    previewLine.style.marginBottom = "4px";
    const color = sectionCfg.color || sectionCfg.lineColor || sectionCfg.upColor || "#ccc";
    previewLine.style.background = getCfgColor(color);
    itemDiv.appendChild(previewLine);
  }
  if (item.type === "select") {
    const optionsHtml = (item.options || []).map((o) => `<option value="${o.value}" ${String(val) === String(o.value) ? "selected" : ""}>${o.label}</option>`).join("");
    itemDiv.innerHTML += `<label>${buildLabelHtml(item)}</label><select data-key="${sec.key}" data-subkey="${item.subKey}">${optionsHtml}</select>`;
    if (sec.key === "dataForm" && item.subKey === "quantityAlloc") {
      const select = itemDiv.querySelector("select");
      const quantityMode = isQuantityDataFormMode(dataFormConfig.mode);
      if (!quantityMode) {
        select.disabled = true;
        itemDiv.classList.add("settingsItemDisabled");
      }
      itemDiv.innerHTML += `<div class="muted" style="font-size:12px;">${quantityMode ? "当前数量模式生效。" : "仅“数量/分笔价格合成数量”生效，当前模式不参与加载。"}</div>`;
    }
    if (sec.key === "dataForm" && item.subKey === "mode") {
      const select = itemDiv.querySelector("select");
      // 首次加载前 N 未知，后端会按真实根数钳制数量；不要拦截会话加载。
      select.onchange = () => {
        flushChartSettingsFormToMemory();
        renderSettingsForm();
      };
    }
    if (sec.key === "dataForm" && item.subKey === "offlineDataCustom") {
      const sel = itemDiv.querySelector("select");
      sel.onchange = () => {
        if (normalizeOfflineDataCustom(sel.value) === "merge_no_bs") {
          showAlertAndLog(OFFLINE_DATA_CUSTOM_HELP);
        }
      };
    }
    if (sec.key === "indicators" && item.subKey === "mainSlot") {
      itemDiv.querySelector("select").onchange = (e) => {
        flushChartSettingsFormToMemory();
        selectedMainIndicatorSlot = Number(e.target.value);
        storageSet("chan_selected_main_indicator_slot", String(selectedMainIndicatorSlot));
        renderSettingsForm();
      };
    } else if (sec.key === "indicators" && item.subKey === "subSlot") {
      itemDiv.querySelector("select").onchange = (e) => {
        flushChartSettingsFormToMemory();
        selectedSubIndicatorSlot = Number(e.target.value);
        storageSet("chan_selected_sub_indicator_slot", String(selectedSubIndicatorSlot));
        renderSettingsForm();
      };
    }
  } else if (item.type === "indicator_multi_main") {
    let html = `<label>${buildLabelHtml(item)}</label>`;
    if (selectedMainIndicatorSlot === 0) {
      html += `<div class="muted" style="margin-top:8px;">当前主图槽位为 0，不显示主图指标。</div>`;
    } else {
      const currentList = Array.isArray(val) ? val : [];
      const options = [{ v: "boll", l: "BOLL" }, { v: "demark", l: "Demark" }, { v: "trendline", l: "TrendLine" }];
      html += `<div style="display:flex;flex-direction:column;gap:4px;margin-top:8px;">`;
      options.forEach((opt) => {
        const checked = currentList.includes(opt.v);
        html += `<label style="flex-direction:row;align-items:center;display:flex;"><input type="checkbox" class="indicator-check-main" value="${opt.v}" ${checked ? "checked" : ""} data-key="indicators" data-subkey="mainType" style="width:auto;margin-right:8px;">${opt.l}</label>`;
      });
      html += `</div>`;
    }
    itemDiv.innerHTML += html;
  } else if (item.type === "indicator_multi_sub") {
    let html = `<label>${buildLabelHtml(item)}</label>`;
    if (selectedSubIndicatorSlot === 0) {
      html += `<div class="muted" style="margin-top:8px;">当前副图槽位为 0，不显示任何副图指标。</div>`;
    } else {
      const currentList = Array.isArray(val) ? val : [];
      const options = [{ v: "macd", l: "MACD" }, { v: "kdj", l: "KDJ" }, { v: "rsi", l: "RSI" }, { v: "vol", l: "VOL" }];
      html += `<div style="display:flex;flex-direction:column;gap:4px;margin-top:8px;">`;
      options.forEach((opt) => {
        const checked = currentList.includes(opt.v);
        html += `<label style="flex-direction:row;align-items:center;display:flex;"><input type="checkbox" class="indicator-check-sub" value="${opt.v}" ${checked ? "checked" : ""} data-key="indicators" data-subkey="subType" style="width:auto;margin-right:8px;">${opt.l}</label>`;
      });
      html += `</div>`;
    }
    itemDiv.innerHTML += html;
  } else if (item.type === "interrupt_bsp_cascade") {
    itemDiv.classList.add("settingsItemWide");
    itemDiv.innerHTML = `<label>${buildLabelHtml(item)}</label><div class="muted" style="font-size:12px;line-height:1.5;margin:4px 0 8px;">内嵌三级：级别 → 类型 → 买/卖。</div>`;
    const cascadeRoot = document.createElement("div");
    cascadeRoot.className = "settings-cascade interrupt-bsp-cascade";
    itemDiv.appendChild(cascadeRoot);
    mountInterruptBspCascade(cascadeRoot, sectionCfg);
  } else if (item.type === "nested_cascade") {
    itemDiv.classList.add("settingsItemWide");
    itemDiv.innerHTML = `<div class="muted" style="font-size:12px;margin-bottom:8px;">${item.tip || "二级分类 → 具体配置项。"}</div>`;
    const cascadeRoot = document.createElement("div");
    cascadeRoot.className = "settings-cascade chart-nested-cascade";
    itemDiv.appendChild(cascadeRoot);
    mountChartNestedCascade(cascadeRoot, sec.key, item.tree || [], buildLabelHtml);
  } else if (item.type === "checkbox") {
    itemDiv.innerHTML += `<label style="flex-direction:row;align-items:center;display:flex;"><input type="checkbox" ${val ? "checked" : ""} data-key="${sec.key}" data-subkey="${item.subKey}" style="width:auto;margin-right:8px;">${item.label}</label>`;
    if (sec.key === "indicators" && (item.subKey === "mainVarVisible" || item.subKey === "subVarVisible")) {
      const c = itemDiv.querySelector('input[type="checkbox"]');
      if (c) {
        c.onchange = () => {
          const who = item.subKey === "mainVarVisible" ? "主图" : "副图";
          const st = c.checked ? "开启" : "关闭";
          showAlertAndLog(
            `${who}变量显示已${st}。\n` +
            "操作逻辑：\n" +
            "1) 开启后显示指标变量文本（示例：VOL: 1999）。\n" +
            "2) 关闭后仅保留图形，不显示变量文本。\n" +
            "3) 保存设置后会持久化，重启后保持。"
          );
        };
      }
    }
  } else if (item.type === "color") {
    const safeVal = typeof val === "string" ? val : "#000000";
    itemDiv.innerHTML += `<label>${buildLabelHtml(item)}</label><div style="display:flex;align-items:center;gap:8px;"><input type="color" value="${safeVal.startsWith("#") ? safeVal : "#000000"}" data-key="${sec.key}" data-subkey="${item.subKey}" style="width:40px;height:24px;padding:0;border:none;cursor:pointer;"><input type="text" value="${safeVal}" data-key="${sec.key}" data-subkey="${item.subKey}-text" style="flex:1;height:24px;padding:2px 4px;font-size:12px;font-family:monospace;"></div>`;
    const colorInput = itemDiv.querySelector('input[type="color"]');
    const textInput = itemDiv.querySelector('input[type="text"]');
    colorInput.oninput = (e) => { textInput.value = e.target.value; };
    textInput.oninput = (e) => {
      if (/^#[0-9a-fA-F]{6}$/.test(e.target.value)) colorInput.value = e.target.value;
    };
  } else {
    let displayVal = val;
    if (item.subKey === "dash" && Array.isArray(val)) displayVal = val.join(", ");
    if (sec.key === "dataForm" && item.subKey === "quantity") {
      const n = getRawKlineCount();
      const minN = 1;
      const maxN = n > 0 ? n : 1;
      const quantityMode = isQuantityDataFormMode(dataFormConfig.mode);
      const disabled = !quantityMode;
      const finalVal = clampDataFormQuantity(displayVal, maxN);
      const helpText = !quantityMode
        ? "仅“数量/分笔价格合成数量”生效，当前模式不参与加载。"
        : ((lastPayload && lastPayload.ready) ? `当前范围：1 - ${maxN}` : "首次加载前范围未知，后端会按真实根数自动钳制。");
      if (disabled) itemDiv.classList.add("settingsItemDisabled");
      itemDiv.innerHTML += `<label>${buildLabelHtml(item)}</label><input type="number" value="${finalVal}" min="${minN}" max="${maxN}" step="1" ${disabled ? "disabled" : ""} data-key="${sec.key}" data-subkey="${item.subKey}"><div class="muted" style="font-size:12px;">${helpText}</div>`;
    } else {
      itemDiv.innerHTML += `<label>${buildLabelHtml(item)}</label><input type="${item.type}" value="${displayVal != null ? displayVal : ""}" step="${item.step || 1}" placeholder="${item.placeholder || ""}" data-key="${sec.key}" data-subkey="${item.subKey}">`;
    }
  }
  parent.appendChild(itemDiv);
  return itemDiv;
}

function renderMultiPerKPanelInto(parent, kt, baseSections, buildLabelHtml) {
  if (!chartConfigStore.multiPerK || typeof chartConfigStore.multiPerK !== "object") chartConfigStore.multiPerK = {};
  if (!chartConfigStore.multiPerK[kt] || typeof chartConfigStore.multiPerK[kt] !== "object") chartConfigStore.multiPerK[kt] = {};
  const layerMap = chartConfigStore.multiPerK[kt];
  const styleKeys = multiLayerStyleKeys();
  const secs = buildVisibleChartSettingsSections(baseSections).filter((s) => styleKeys.has(s.key));
  secs.forEach((sec) => {
    const sub = document.createElement("div");
    sub.className = "chart-settings-subblock";
    sub.innerHTML = `<div class="muted" style="font-weight:600;margin:8px 0 6px;color:${sec.color}">${sec.title}</div>`;
    const sectionCfg = ensureObject(layerMap[sec.key], {});
    sec.items.forEach((item) => {
      let val = sectionCfg[item.subKey];
      if (val === undefined || val === null) {
        const d0 = DEFAULT_CHART_CONFIG[sec.key] || {};
        val = d0[item.subKey];
      }
      const itemDiv = document.createElement("div");
      itemDiv.className = "settingsItem";
      if (item.type === "select") {
        const opts = (item.options || []).map((o) => `<option value="${o.value}" ${String(val) === String(o.value) ? "selected" : ""}>${o.label}</option>`).join("");
        itemDiv.innerHTML = `<label>${buildLabelHtml(item)}</label><select data-multi-kt="${kt}" data-key="${sec.key}" data-subkey="${item.subKey}">${opts}</select>`;
      } else if (item.type === "checkbox") {
        itemDiv.innerHTML = `<label style="flex-direction:row;align-items:center;display:flex;"><input type="checkbox" data-multi-kt="${kt}" data-key="${sec.key}" data-subkey="${item.subKey}" ${val ? "checked" : ""} style="width:auto;margin-right:8px;">${item.label}</label>`;
      } else if (item.type === "color") {
        const safeVal = typeof val === "string" ? val : "#000000";
        itemDiv.innerHTML = `<label>${buildLabelHtml(item)}</label><div style="display:flex;align-items:center;gap:8px;"><input type="color" value="${safeVal.startsWith("#") ? safeVal : "#000000"}" data-multi-kt="${kt}" data-key="${sec.key}" data-subkey="${item.subKey}" style="width:40px;height:24px;padding:0;border:none;"><input type="text" value="${safeVal}" data-multi-kt="${kt}" data-key="${sec.key}" data-subkey="${item.subKey}-text" style="flex:1;height:24px;font-size:12px;font-family:monospace;"></div>`;
      } else if (item.type === "number") {
        const mn = item.min != null ? item.min : "";
        const mx = item.max != null ? item.max : "";
        const st = item.step != null ? item.step : "";
        itemDiv.innerHTML = `<label>${buildLabelHtml(item)}</label><input type="number" data-multi-kt="${kt}" data-key="${sec.key}" data-subkey="${item.subKey}" min="${mn}" max="${mx}" step="${st}" value="${val != null ? val : ""}">`;
      } else if (item.type === "text") {
        itemDiv.innerHTML = `<label>${buildLabelHtml(item)}</label><input type="text" data-multi-kt="${kt}" data-key="${sec.key}" data-subkey="${item.subKey}" value="${val != null ? String(val) : ""}" placeholder="${item.placeholder || ""}">`;
      }
      sub.appendChild(itemDiv);
    });
    parent.appendChild(sub);
  });
}

function renderMoverlayKtPanelInto(parent, kt, buildLabelHtml) {
  if (!chartConfig.multiOverlay) chartConfig.multiOverlay = JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG.multiOverlay));
  if (!chartConfig.multiOverlay.layers || typeof chartConfig.multiOverlay.layers !== "object") chartConfig.multiOverlay.layers = {};
  if (!chartConfig.multiOverlay.layers[kt]) chartConfig.multiOverlay.layers[kt] = {};
  const L = chartConfig.multiOverlay.layers[kt];
  const mo = chartConfig.multiOverlay;
  const styleOpts = [
    { value: "grid", label: "网格" },
    { value: "dots", label: "点状" },
    { value: "hatch", label: "斜线阴影" },
    { value: "shade", label: "竖向明暗" },
    { value: "soft", label: "淡色平铺" },
  ];
  const items = [
    { label: "缠论线透明度 lineAlpha", subkey: "lineAlpha", type: "number", min: 0.05, max: 1, step: 0.02, def: mo.defaultAlpha, tip: "合并框/分型笔段等。" },
    { label: "实体透明度 bodyAlpha", subkey: "bodyAlpha", type: "number", min: 0.05, max: 1, step: 0.02, def: mo.defaultCoarseBodyAlpha, tip: "大周期实心矩形。" },
    { label: "上影线透明度", subkey: "upperShadowAlpha", type: "number", min: 0.05, max: 1, step: 0.02, def: mo.defaultCoarseUpperShadowAlpha, tip: "" },
    { label: "下影线透明度", subkey: "lowerShadowAlpha", type: "number", min: 0.05, max: 1, step: 0.02, def: mo.defaultCoarseLowerShadowAlpha, tip: "" },
    { label: "上影线纹理", subkey: "upperShadowStyle", type: "select", options: styleOpts, def: mo.defaultUpperShadowStyle, tip: "" },
    { label: "下影线纹理", subkey: "lowerShadowStyle", type: "select", options: styleOpts, def: mo.defaultLowerShadowStyle, tip: "" },
    { label: "兼容旧字段 alpha", subkey: "alpha", type: "number", min: 0.05, max: 1, step: 0.02, def: null, tip: "旧版单一透明度。" },
  ];
  items.forEach((it) => {
    let val = L[it.subkey];
    if ((val === undefined || val === null) && it.def != null) val = it.def;
    if (val === undefined || val === null) val = "";
    const itemDiv = document.createElement("div");
    itemDiv.className = "settingsItem";
    const labelH = buildLabelHtml({ ...it, subKey: it.subkey, tip: it.tip || `${it.label}。` });
    if (it.type === "select") {
      const opts = (it.options || []).map((o) => `<option value="${o.value}" ${String(val) === String(o.value) ? "selected" : ""}>${o.label}</option>`).join("");
      itemDiv.innerHTML = `<label>${labelH}</label><select data-moverlay-kt="${kt}" data-moverlay-subkey="${it.subkey}">${opts}</select>`;
    } else {
      const mn = it.min != null ? it.min : "";
      const mx = it.max != null ? it.max : "";
      const st = it.step != null ? it.step : "";
      itemDiv.innerHTML = `<label>${labelH}</label><input type="number" data-moverlay-kt="${kt}" data-moverlay-subkey="${it.subkey}" min="${mn}" max="${mx}" step="${st}" value="${val !== "" ? val : ""}">`;
    }
    parent.appendChild(itemDiv);
  });
}

function renderChartSettingsSectionInto(detailEl, sec, baseSections, buildLabelHtml) {
  if (sec.panel === "branch") {
    renderChartSettingsBranchPanel(detailEl, sec, baseSections, buildLabelHtml);
    return;
  }
  detailEl.innerHTML = "";
  const head = document.createElement("div");
  head.className = "chart-settings-detail-head";
  head.style.borderLeftColor = sec.color || "#2563eb";
  let hint = "";
  if (sec.panel === "multiPerK") hint = `<div class="muted" style="font-size:12px;margin-top:4px;">持久化：multiPerK[${sec.kt}]，未填项用默认。</div>`;
  else if (sec.panel === "moverlay") hint = `<div class="muted" style="font-size:12px;margin-top:4px;">粗周期叠层蜡烛，持久化：multiOverlay.layers[${sec.kt}]</div>`;
  head.innerHTML = `<strong style="color:${sec.color || "#2563eb"}">${sec.title}</strong>${hint}`;
  detailEl.appendChild(head);
  const body = document.createElement("div");
  body.className = "chart-settings-detail-body";
  if (sec.panel === "multiPerK") renderMultiPerKPanelInto(body, sec.kt, baseSections, buildLabelHtml);
  else if (sec.panel === "moverlay") renderMoverlayKtPanelInto(body, sec.kt, buildLabelHtml);
  else (sec.items || []).forEach((item) => appendChartSettingsItemTo(body, sec, item, buildLabelHtml));
  detailEl.appendChild(body);
}

/** 「级别/中枢/买卖点」：级联下拉（类别 → 具体项）+ 配置区 */
function renderChartSettingsBranchPanel(detailEl, navSec, baseSections, buildLabelHtml) {
  const branch = CHART_SETTINGS_BRANCH_BY_KEY[navSec.branchKey];
  if (!branch) return;
  const visible = buildVisibleChartSettingsSections(baseSections);
  const branchKeys = chartSettingsBranchChildKeys(branch.key);
  const childSecs = branchKeys.map((k) => visible.find((s) => s.key === k)).filter(Boolean);
  if (!childSecs.length) {
    detailEl.innerHTML = '<div class="muted">当前模式下无可用子项。</div>';
    return;
  }
  let selChildKey = chartSettingsBranchChildSel[branch.key];
  if (!branchKeys.includes(selChildKey)) selChildKey = branchKeys[0];

  detailEl.innerHTML = "";
  const head = document.createElement("div");
  head.className = "chart-settings-detail-head chart-settings-branch-head";
  head.style.borderLeftColor = branch.color;
  head.innerHTML = `<strong style="color:${branch.color}">${branch.title}</strong><div class="muted" style="font-size:12px;margin-top:4px;">左侧选组后，用下方下拉选具体项；保存仍写入原有配置键。</div>`;

  const toolbar = document.createElement("div");
  toolbar.className = "chart-settings-branch-toolbar";

  const grpLbl = document.createElement("span");
  grpLbl.className = "chart-settings-cascade-label";
  grpLbl.textContent = "类别";
  const grpSel = document.createElement("select");
  grpSel.className = "chart-settings-cascade-select";
  grpSel.disabled = true;
  grpSel.innerHTML = `<option selected>${branch.title}</option>`;

  const childLbl = document.createElement("span");
  childLbl.className = "chart-settings-cascade-label";
  childLbl.textContent = "具体项";
  const childSel = document.createElement("select");
  childSel.className = "chart-settings-cascade-select";
  childSecs.forEach((cs) => {
    const opt = document.createElement("option");
    opt.value = cs.key;
    opt.textContent = cs.title;
    if (cs.key === selChildKey) opt.selected = true;
    childSel.appendChild(opt);
  });

  const helpBtn = document.createElement("button");
  helpBtn.type = "button";
  helpBtn.className = "chart-settings-branch-help";
  helpBtn.textContent = "说明";
  helpBtn.setAttribute("data-tip", "查看本组的持久化键与操作说明");
  helpBtn.onclick = () => showAlertAndLog(branch.tip || branch.title);

  toolbar.append(grpLbl, grpSel, childLbl, childSel, helpBtn);
  if (branch.key === "__branch_level__") {
    const addBtn = document.createElement("button");
    addBtn.type = "button";
    addBtn.className = "chart-settings-branch-help";
    addBtn.textContent = "增加级别";
    addBtn.setAttribute("data-tip", "新增 3段、4段……并同步添加中枢/买卖点显示设置");
    addBtn.onclick = addNextCustomSegmentLevel;
    toolbar.appendChild(addBtn);
  }
  head.appendChild(toolbar);
  detailEl.appendChild(head);

  const bodyWrap = document.createElement("div");
  bodyWrap.className = "chart-settings-branch-body";
  detailEl.appendChild(bodyWrap);

  const paintBody = () => {
    const cur = childSecs.find((s) => s.key === selChildKey) || childSecs[0];
    bodyWrap.innerHTML = "";
    const subHead = document.createElement("div");
    subHead.className = "chart-settings-branch-subtitle";
    subHead.innerHTML = `<strong style="color:${cur.color || branch.color}">${cur.title}</strong>`;
    bodyWrap.appendChild(subHead);
    const grid = document.createElement("div");
    grid.className = "chart-settings-detail-body";
    (cur.items || []).forEach((item) => appendChartSettingsItemTo(grid, cur, item, buildLabelHtml));
    bodyWrap.appendChild(grid);
    initTooltips();
  };

  childSel.onchange = () => {
    flushChartSettingsFormToMemory();
    selChildKey = childSel.value;
    chartSettingsBranchChildSel[branch.key] = selChildKey;
    persistChartSettingsBranchChildSel();
    paintBody();
  };

  paintBody();
}

/** 单面板级联：左列分组、右列该组全部配置 */
function mountChartSettingsCascadePanel(container, baseSections, buildLabelHtml) {
  const sections = buildChartSettingsNavSections(baseSections);
  if (!sections.length) return;
  chartSettingsCascadeSelKey = normalizeChartSettingsCascadeSelKey(chartSettingsCascadeSelKey);
  if (!chartSettingsCascadeSelKey || !sections.some((s) => s.key === chartSettingsCascadeSelKey)) {
    chartSettingsCascadeSelKey = sections[0].key;
  }
  const shell = document.createElement("div");
  shell.className = "chart-settings-shell";
  shell.innerHTML = `<div class="muted chart-settings-hint">左侧选分组；「级别 / 中枢 / 买卖点」组内用级联下拉先确认类别、再选具体项（分型/笔中枢等）。配置仍按原键名持久化。改完后点「保存并应用」。</div>`;
  const panel = document.createElement("div");
  panel.className = "settings-cascade chart-settings-cascade";
  const colNav = document.createElement("div");
  colNav.className = "settings-cascade-col chart-settings-nav";
  colNav.innerHTML = `<div class="settings-cascade-head">分组</div><div class="settings-cascade-list" data-chart-nav="1"></div>`;
  const colDetail = document.createElement("div");
  colDetail.className = "settings-cascade-col chart-settings-detail-col";
  colDetail.innerHTML = `<div class="settings-cascade-head">配置项</div><div class="chart-settings-detail-scroll" data-chart-detail="1"></div>`;
  panel.appendChild(colNav);
  panel.appendChild(colDetail);
  shell.appendChild(panel);
  container.appendChild(shell);
  const listEl = colNav.querySelector('[data-chart-nav="1"]');
  const detailEl = colDetail.querySelector('[data-chart-detail="1"]');
  const paint = () => {
    listEl.innerHTML = "";
    sections.forEach((sec) => {
      const el = document.createElement("div");
      el.className = "settings-cascade-item" + (sec.key === chartSettingsCascadeSelKey ? " active" : "");
      el.textContent = sec.title;
      if (sec.color) el.style.boxShadow = sec.key === chartSettingsCascadeSelKey ? `inset 3px 0 0 ${sec.color}` : `inset 3px 0 0 transparent`;
      el.onclick = () => {
        flushChartSettingsFormToMemory();
        chartSettingsCascadeSelKey = sec.key;
        paint();
      };
      listEl.appendChild(el);
    });
    const cur = sections.find((s) => s.key === chartSettingsCascadeSelKey) || sections[0];
    renderChartSettingsSectionInto(detailEl, cur, baseSections, buildLabelHtml);
    initTooltips();
  };
  paint();
}

/** 步进 N 买卖点中断：三级级联树（级别 → 类型 → 买/卖） */
const INTERRUPT_BSP_CASCADE_TREE = [
  {
    id: "bi", label: "笔",
    types: [
      { id: "1", label: "1 / 1p", buyKey: "interruptBspBi1Buy", sellKey: "interruptBspBi1Sell" },
      { id: "2", label: "2", buyKey: "interruptBspBi2Buy", sellKey: "interruptBspBi2Sell" },
      { id: "2s", label: "2s", buyKey: "interruptBspBi2sBuy", sellKey: "interruptBspBi2sSell" },
    ],
  },
  {
    id: "seg", label: "段",
    types: [
      { id: "1", label: "1 / 1p", buyKey: "interruptBspSeg1Buy", sellKey: "interruptBspSeg1Sell" },
      { id: "2", label: "2", buyKey: "interruptBspSeg2Buy", sellKey: "interruptBspSeg2Sell" },
      { id: "2s", label: "2s", buyKey: "interruptBspSeg2sBuy", sellKey: "interruptBspSeg2sSell" },
    ],
  },
  {
    id: "segseg", label: "2段",
    types: [
      { id: "1", label: "1 / 1p", buyKey: "interruptBspSegseg1Buy", sellKey: "interruptBspSegseg1Sell" },
      { id: "2", label: "2", buyKey: "interruptBspSegseg2Buy", sellKey: "interruptBspSegseg2Sell" },
      { id: "2s", label: "2s", buyKey: "interruptBspSegseg2sBuy", sellKey: "interruptBspSegseg2sSell" },
    ],
  },
];

function _interruptBspSlotEnabled(toastCfg, typeNode) {
  return toastCfg[typeNode.buyKey] !== false || toastCfg[typeNode.sellKey] !== false;
}

function _interruptBspLevelEnabledCount(toastCfg, levelNode) {
  return levelNode.types.filter((t) => _interruptBspSlotEnabled(toastCfg, t)).length;
}

function _setInterruptBspCascadeKeys(toastCfg, keys, checked) {
  keys.forEach((k) => { toastCfg[k] = !!checked; });
}

function mountInterruptBspCascade(root, toastCfg) {
  const cfg = ensureObject(toastCfg, {});
  let selLevelId = INTERRUPT_BSP_CASCADE_TREE[0].id;
  let selTypeId = INTERRUPT_BSP_CASCADE_TREE[0].types[0].id;

  const colLevel = document.createElement("div");
  colLevel.className = "settings-cascade-col";
  colLevel.innerHTML = `<div class="settings-cascade-head">1. 级别</div><div class="settings-cascade-list" data-cascade="level"></div>`;

  const colType = document.createElement("div");
  colType.className = "settings-cascade-col";
  colType.innerHTML = `<div class="settings-cascade-head">2. 类型</div><div class="settings-cascade-list" data-cascade="type"></div>`;

  const colSide = document.createElement("div");
  colSide.className = "settings-cascade-col";
  colSide.innerHTML = `<div class="settings-cascade-head">3. 买 / 卖</div>`;
  const sidePanel = document.createElement("div");
  sidePanel.className = "settings-cascade-panel";
  sidePanel.setAttribute("data-cascade", "side");
  colSide.appendChild(sidePanel);

  root.appendChild(colLevel);
  root.appendChild(colType);
  root.appendChild(colSide);

  const listLevel = colLevel.querySelector('[data-cascade="level"]');
  const listType = colType.querySelector('[data-cascade="type"]');

  function currentLevel() {
    return INTERRUPT_BSP_CASCADE_TREE.find((l) => l.id === selLevelId) || INTERRUPT_BSP_CASCADE_TREE[0];
  }

  function currentType() {
    const lv = currentLevel();
    const t = lv.types.find((x) => x.id === selTypeId);
    return t || lv.types[0];
  }

  function renderLevels() {
    listLevel.innerHTML = "";
    INTERRUPT_BSP_CASCADE_TREE.forEach((lv) => {
      const n = _interruptBspLevelEnabledCount(cfg, lv);
      const el = document.createElement("div");
      el.className = "settings-cascade-item" + (lv.id === selLevelId ? " active" : "");
      el.textContent = `${lv.label}（${n}/${lv.types.length}）`;
      el.onclick = () => {
        selLevelId = lv.id;
        const first = lv.types[0];
        selTypeId = first ? first.id : selTypeId;
        renderAll();
      };
      listLevel.appendChild(el);
    });
  }

  function renderTypes() {
    listType.innerHTML = "";
    const lv = currentLevel();
    if (!lv.types.some((t) => t.id === selTypeId)) selTypeId = lv.types[0].id;
    lv.types.forEach((tp) => {
      const buyOn = cfg[tp.buyKey] !== false;
      const sellOn = cfg[tp.sellKey] !== false;
      const el = document.createElement("div");
      el.className = "settings-cascade-item" + (tp.id === selTypeId ? " active" : "");
      const marks = [];
      if (buyOn) marks.push("买");
      if (sellOn) marks.push("卖");
      el.textContent = `${tp.label}${marks.length ? " ·" + marks.join("·") : ""}`;
      el.onclick = () => {
        selTypeId = tp.id;
        renderAll();
      };
      listType.appendChild(el);
    });
  }

  function renderSides() {
    const tp = currentType();
    sidePanel.innerHTML = `
      <div class="muted" style="font-size:12px;line-height:1.5;">
        当前：${currentLevel().label} → ${tp.label}。勾选后该档位参与「买卖点细分条件」；与上方 OR/AND、方向例外组合生效。
      </div>
      <label style="flex-direction:row;align-items:center;display:flex;">
        <input type="checkbox" data-key="toast" data-subkey="${tp.buyKey}" ${cfg[tp.buyKey] !== false ? "checked" : ""} style="width:auto;margin-right:8px;">
        买点参与中断
      </label>
      <label style="flex-direction:row;align-items:center;display:flex;">
        <input type="checkbox" data-key="toast" data-subkey="${tp.sellKey}" ${cfg[tp.sellKey] !== false ? "checked" : ""} style="width:auto;margin-right:8px;">
        卖点参与中断
      </label>
      <div class="settings-cascade-actions">
        <button type="button" data-act="type-all">本类型全选</button>
        <button type="button" data-act="type-none">本类型全清</button>
        <button type="button" data-act="level-all">本级别全选</button>
        <button type="button" data-act="level-none">本级别全清</button>
        <button type="button" data-act="all-on">全部全选</button>
        <button type="button" data-act="all-off">全部全清</button>
      </div>
    `;
    sidePanel.querySelectorAll('input[type="checkbox"]').forEach((cb) => {
      cb.onchange = () => {
        cfg[cb.dataset.subkey] = cb.checked;
        renderLevels();
        renderTypes();
      };
    });
    sidePanel.querySelectorAll("button[data-act]").forEach((btn) => {
      btn.onclick = () => {
        const act = btn.getAttribute("data-act");
        const lv = currentLevel();
        const allKeys = [];
        INTERRUPT_BSP_CASCADE_TREE.forEach((l) => l.types.forEach((t) => { allKeys.push(t.buyKey, t.sellKey); }));
        if (act === "type-all") _setInterruptBspCascadeKeys(cfg, [tp.buyKey, tp.sellKey], true);
        else if (act === "type-none") _setInterruptBspCascadeKeys(cfg, [tp.buyKey, tp.sellKey], false);
        else if (act === "level-all") lv.types.forEach((t) => _setInterruptBspCascadeKeys(cfg, [t.buyKey, t.sellKey], true));
        else if (act === "level-none") lv.types.forEach((t) => _setInterruptBspCascadeKeys(cfg, [t.buyKey, t.sellKey], false));
        else if (act === "all-on") _setInterruptBspCascadeKeys(cfg, allKeys, true);
        else if (act === "all-off") _setInterruptBspCascadeKeys(cfg, allKeys, false);
        renderAll();
      };
    });
  }

  function renderAll() {
    renderLevels();
    renderTypes();
    renderSides();
  }

  renderAll();
}

/** 图表显示：分组内二级级联（子类 → 配置项） */
function mountChartNestedCascade(root, sectionKey, tree, buildLabelHtml) {
  let selCatId = (tree[0] && tree[0].id) || "";
  const colCat = document.createElement("div");
  colCat.className = "settings-cascade-col";
  colCat.innerHTML = `<div class="settings-cascade-head">1. 子类</div><div class="settings-cascade-list" data-nested-cat="1"></div>`;
  const colDetail = document.createElement("div");
  colDetail.className = "settings-cascade-col";
  colDetail.innerHTML = `<div class="settings-cascade-head">2. 配置项</div><div class="settings-cascade-panel" data-nested-detail="1"></div>`;
  root.appendChild(colCat);
  root.appendChild(colDetail);
  const listCat = colCat.querySelector("[data-nested-cat='1']");
  const panelDetail = colDetail.querySelector("[data-nested-detail='1']");

  function currentCat() {
    return tree.find((c) => c.id === selCatId) || tree[0];
  }

  function paint() {
    listCat.innerHTML = "";
    tree.forEach((cat) => {
      const el = document.createElement("div");
      el.className = "settings-cascade-item" + (cat.id === selCatId ? " active" : "");
      el.textContent = cat.label;
      el.onclick = () => {
        flushChartSettingsFormToMemory();
        selCatId = cat.id;
        paint();
      };
      listCat.appendChild(el);
    });
    panelDetail.innerHTML = "";
    const cat = currentCat();
    if (!cat) return;
    const grid = document.createElement("div");
    grid.className = "settingsGrid";
    (cat.items || []).forEach((item) => {
      appendChartSettingsItemTo(grid, { key: sectionKey, title: cat.label }, item, buildLabelHtml);
    });
    panelDetail.appendChild(grid);
    initTooltips();
  }
  paint();
}

function renderSettingsForm() {
  const container = $("settingsContent");
  container.innerHTML = "";

  const slotTip = [
    "槽位规则：",
    "1) 主图槽位(0-5)：0 表示主图不显示指标，1-5 为主图指标方案槽位。",
    "2) 副图槽位(0-5)：0 表示不显示任何副图，1-5 为副图指标方案槽位。",
    "3) 主图与副图槽位独立选择、独立保存。",
    "4) 更改配置后点击保存即可生效。"
  ].join("\n");
  const mainSlotOptions = [
    { value: "0", label: "主图(0) 不显示指标" },
    { value: "1", label: "主图(1)" },
    { value: "2", label: "主图(2)" },
    { value: "3", label: "主图(3)" },
    { value: "4", label: "主图(4)" },
    { value: "5", label: "主图(5)" },
  ];
  const subSlotOptions = [
    { value: "0", label: "副图(0) 不显示副图" },
    { value: "1", label: "副图(1)" },
    { value: "2", label: "副图(2)" },
    { value: "3", label: "副图(3)" },
    { value: "4", label: "副图(4)" },
    { value: "5", label: "副图(5)" },
  ];

  const buildLabelHtml = (item) => {
    const tipText = String(item.tip || `${item.label}：用于调整该项在图表或浮窗中的显示效果。`).replace(/"/g, "&quot;");
    return `${item.label} <span class="tip-icon" data-tip="${tipText}">!</span>`;
  };

  const sections = [
    {
      title: "数据形式",
      key: "dataForm",
      color: "#0369a1",
      bgColor: "rgba(3, 105, 161, 0.08)",
      items: [
        { label: "形式", subKey: "mode", type: "select", options: [
          { value: "traditional", label: "传统" },
          { value: "quantity", label: "数量" },
          { value: "tick_traditional", label: "分笔价格合成传统" },
          { value: "tick_quantity", label: "分笔价格合成数量" }
        ], tip: "传统：保持原始K线；数量：按数量Q聚合原始K线；分笔价格合成传统：用 a_Data/六位代码/ 下分笔 txt 合成目标周期K线；分笔价格合成数量：先逐笔合成再按数量Q聚合。分笔合成两种模式的筹码均使用逐笔累加，不使用三角分摊。" },
        { label: "数量分配原则", subKey: "quantityAlloc", type: "select", options: [
          { value: "front", label: "靠前分配（余数优先分给前方K线）" },
          { value: "back", label: "靠后分配（余数优先分给后方K线）" }
        ], tip: "仅「数量/分笔价格合成数量」生效。例：原生99根、数量4、靠前分配 → 25+25+25+24；靠后分配 → 24+24+24+27。默认靠前。" },
        { label: "喂数据方式", subKey: "feedMode", type: "select", options: [
          { value: "step", label: "逐K喂数据" },
          { value: "unified", label: "统一喂数据（一次性喂给缠论计算）" }
        ], tip: "逐K喂数据：逐根喂入缠论引擎，可模拟操盘。统一喂数据：初始化时一次性全量计算，买卖按钮禁用，主要用于看画线/筹码；仍可用步进或跳转浏览切片。" },
        { label: "数量", subKey: "quantity", type: "number", min: 1, step: 1, tip: "仅“数量/分笔价格合成数量”生效。范围 1~N（N=当前模式原始K线数）：1=全合并，N=不聚合。数量射线：Ctrl+左键固定两点；斜率按时间-价格固定（换数量不变）；同代码跨区间保留。若当前区间 B 包含绘制时区间 A：A 段实线、超出 A 的延长虚线；若不包含 A：全线虚线。" },
        { label: "K线图呈现形式", subKey: "klinePresentation", type: "select", options: [
          { value: "step", label: "步进" },
          { value: "instant", label: "一次性呈现" }
        ], tip: "适配所有「形式」与「喂数据方式」。步进：加载后从第一根起逐步展示（当前默认）。一次性呈现：加载后直接显示末根完整K线与缠论结果，跳过逐步过程；之后仍可用步进/回退/跳转浏览。" },
        { label: "离线数据自定义", subKey: "offlineDataCustom", type: "select", options: [
          { value: "native", label: "原生" },
          { value: "merge_no_bs", label: "无BS向上或者向下合并" }
        ], tip: OFFLINE_DATA_CUSTOM_HELP }
      ]
    },
    {
      title: "系统主题",
      key: "theme_section",
      color: "#3b82f6",
      bgColor: "rgba(59, 130, 246, 0.08)",
      items: [
        { label: "主题", subKey: "theme", type: "select", options: [
          { value: "light", label: "白色" },
          { value: "dark", label: "黑色" },
          { value: "eye-care", label: "护眼" }
        ]}
      ]
    },
    {
      title: "十字辅助线",
      key: "crosshair",
      color: "#0f766e",
      bgColor: "rgba(15, 118, 110, 0.08)",
      items: [
        { label: "启用十字线", subKey: "enabled", type: "checkbox", tip: "也可在 K 线图双击切换；状态会写入本地持久化。" },
        { label: "粗细", subKey: "width", type: "number", min: 1, max: 10, step: 0.5 },
        { label: "颜色", subKey: "color", type: "color" },
        { label: "文字大小", subKey: "fontSize", type: "number", min: 10, max: 24 }
      ]
    },
    {
      title: "技术指标设置",
      key: "indicators",
      color: "#7c3aed",
      bgColor: "rgba(124, 58, 237, 0.08)",
      items: [
        { label: "主图配置槽位", subKey: "mainSlot", type: "select", options: mainSlotOptions, tip: slotTip },
        { label: "主图指标选择", subKey: "mainType", type: "indicator_multi_main" },
        { label: "主图变量显示", subKey: "mainVarVisible", type: "checkbox", tip: "控制主图指标变量文本显示（如 BOLL 当前值）。" },
        { label: "副图配置槽位", subKey: "subSlot", type: "select", options: subSlotOptions, tip: slotTip },
        { label: "副图指标选择", subKey: "subType", type: "indicator_multi_sub" },
        { label: "副图变量显示", subKey: "subVarVisible", type: "checkbox", tip: "控制副图指标变量文本显示（如 VOL: 1999）。" }
      ]
    },
    {
      title: "K线显示",
      key: "candle",
      color: "#dc2626",
      bgColor: "rgba(220, 38, 38, 0.08)",
      items: [
        { label: "描边粗细", subKey: "width", type: "number", min: 0.1, max: 5, step: 0.1 },
        { label: "上涨颜色", subKey: "upColor", type: "color" },
        { label: "下跌颜色", subKey: "downColor", type: "color" },
        {
          label: "K线整体透明度",
          subKey: "alpha",
          type: "number",
          min: 0.05,
          max: 1,
          step: 0.02,
          tip: "所有模式下主图蜡烛透明度（1=不透明）。多周期单图时主要影响驱动周期（最细勾选周期，通常为 1 分钟）小 K 线；粗周期叠层另有独立透明度项。",
        },
      ]
    },
    {
      title: "多周期叠图 (multi)",
      key: "multiOverlay",
      color: "#7c2d12",
      bgColor: "rgba(124, 45, 18, 0.08)",
      items: [
        {
          label: "缠论线默认透明度",
          subKey: "defaultAlpha",
          type: "number",
          min: 0.05,
          max: 1,
          step: 0.02,
          tip: "各粗周期叠层「合并框/笔段/中枢」等默认透明度；可按周期在下方「各粗周期叠层」中单独覆盖（lineAlpha）。",
        },
        {
          label: "非驱动层K宽倍率",
          subKey: "defaultCandleWidth",
          type: "number",
          min: 0.2,
          max: 3,
          step: 0.1,
          tip: "叠加层线宽基数=主图 K 线描边粗细×本倍率；实体宽度仍按细 K 外沿全包对齐，不受倍率拉伸。",
        },
        {
          label: "粗层实体默认透明度",
          subKey: "defaultCoarseBodyAlpha",
          type: "number",
          min: 0.05,
          max: 1,
          step: 0.02,
          tip: "大周期实心实体默认透明度；可按周期单独覆盖 bodyAlpha。",
        },
        {
          label: "上影线默认透明度",
          subKey: "defaultCoarseUpperShadowAlpha",
          type: "number",
          min: 0.05,
          max: 1,
          step: 0.02,
          tip: "大周期上影线（纹理填充）默认透明度。",
        },
        {
          label: "下影线默认透明度",
          subKey: "defaultCoarseLowerShadowAlpha",
          type: "number",
          min: 0.05,
          max: 1,
          step: 0.02,
          tip: "大周期下影线（纹理填充）默认透明度。",
        },
        {
          label: "上影线默认纹理",
          subKey: "defaultUpperShadowStyle",
          type: "select",
          options: [
            { value: "grid", label: "网格" },
            { value: "dots", label: "点状" },
            { value: "hatch", label: "斜线阴影" },
            { value: "shade", label: "竖向明暗" },
            { value: "soft", label: "淡色平铺" },
          ],
          tip: "非驱动层大周期蜡烛上影线区域填充样式；可按周期用 upperShadowStyle 覆盖。",
        },
        {
          label: "下影线默认纹理",
          subKey: "defaultLowerShadowStyle",
          type: "select",
          options: [
            { value: "grid", label: "网格" },
            { value: "dots", label: "点状" },
            { value: "hatch", label: "斜线阴影" },
            { value: "shade", label: "竖向明暗" },
            { value: "soft", label: "淡色平铺" },
          ],
          tip: "下影线区域样式；可按周期用 lowerShadowStyle 覆盖。",
        },
      ],
    },
    {
      title: "分型辅助线",
      key: "fx",
      color: "#0891b2",
      bgColor: "rgba(8, 145, 178, 0.08)",
      items: [
        { label: "辅助线颜色", subKey: "color", type: "color" },
        { label: "辅助线粗细", subKey: "width", type: "number", min: 0.1, max: 5, step: 0.1 }
      ]
    },
    {
      title: "筹码分布 (Chip)",
      key: "chip",
      color: "#0891b2",
      bgColor: "rgba(8, 145, 178, 0.08)",
      items: [
        { label: "启用筹码", subKey: "enabled", type: "checkbox" },
        { label: "筹码峰延长线", subKey: "peakLineEnabled", type: "checkbox", tip: "控制筹码峰水平延长线的显示开关。" },
        { label: "拉伸强度", subKey: "stretchLevel", type: "number", min: 1, max: 20 },
        { label: "价格桶(元)", subKey: "bucketStep", type: "number", min: 0.001, max: 1, step: 0.001 },
        { label: "填充颜色", subKey: "color", type: "color" },
        { label: "S颜色(左侧)", subKey: "sColor", type: "color" },
        { label: "B颜色(右侧)", subKey: "bColor", type: "color" },
        { label: "筹码峰延长线参考", subKey: "peakRefMode", type: "select", options: [
          { value: "latest_visible", label: "最新可见K线" },
          { value: "seg_turn", label: "线段转折点" },
          { value: "bi_turn", label: "笔转折点" }
        ]},
        { label: "筹码峰延长线颜色", subKey: "peakLineColor", type: "color" },
        { label: "筹码峰延长线粗细", subKey: "peakLineWidth", type: "number", min: 0.1, max: 6, step: 0.1 },
        { label: "筹码峰延长线线型", subKey: "peakLineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]}
      ]
    },
    {
      title: "分型",
      key: "fract",
      color: "#b45309",
      bgColor: "rgba(180, 83, 9, 0.08)",
      items: [
        { label: "分型颜色", subKey: "color", type: "color" },
        { label: "粗细(确定)", subKey: "widthSure", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "粗细(未完成)", subKey: "widthUnsure", type: "number", min: 0.1, max: 8, step: 0.1 }
      ]
    },
    {
      title: "笔",
      key: "bi",
      color: "#d97706",
      bgColor: "rgba(217, 119, 6, 0.08)",
      items: [
        { label: "笔颜色", subKey: "color", type: "color" },
        { label: "粗细(确定)", subKey: "widthSure", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "粗细(未完成)", subKey: "widthUnsure", type: "number", min: 0.1, max: 8, step: 0.1 }
      ]
    },
    {
      title: "段",
      key: "seg",
      color: "#059669",
      bgColor: "rgba(5, 150, 105, 0.1)",
      items: [
        { label: "段颜色", subKey: "color", type: "color" },
        { label: "粗细(确定)", subKey: "widthSure", type: "number", min: 0.1, max: 10, step: 0.1 },
        { label: "粗细(未完成)", subKey: "widthUnsure", type: "number", min: 0.1, max: 10, step: 0.1 }
      ]
    },
    {
      title: "2段",
      key: "segseg",
      color: "#2563eb",
      bgColor: "rgba(37, 99, 235, 0.1)",
      items: [
        { label: "2段颜色", subKey: "color", type: "color" },
        { label: "粗细(确定)", subKey: "widthSure", type: "number", min: 0.1, max: 12, step: 0.1 },
        { label: "粗细(未完成)", subKey: "widthUnsure", type: "number", min: 0.1, max: 12, step: 0.1 }
      ]
    },
    {
      title: "节奏线",
      key: "rhythmLine",
      color: "#7c3aed",
      bgColor: "rgba(124, 58, 237, 0.08)",
      items: [
        {
          label: "节奏线配置",
          subKey: "__nested__",
          type: "nested_cascade",
          tip: "左侧选子类，右侧编辑；切换子类前会自动暂存当前修改到内存草稿。",
          tree: [
            {
              id: "switch", label: "开关与层级",
              items: [
                { label: "启用节奏线", subKey: "enabled", type: "checkbox", tip: "总开关，关闭后不绘制任何节奏线。" },
                { label: "分型→笔", subKey: "fractToBiEnabled", type: "checkbox" },
                { label: "笔→段", subKey: "biToSegEnabled", type: "checkbox" },
                { label: "段→2段", subKey: "segToSegsegEnabled", type: "checkbox" },
                { label: "显示层级", subKey: "maxLayer", type: "number", min: 0, max: 9, step: 1, tip: "0层只显示 1-0 / 2-0；N 层显示 <=N 的所有节奏线。" },
              ],
            },
            {
              id: "calc", label: "计算",
              items: [
                { label: "计算逻辑", subKey: "calcMode", type: "select", options: [
                  { value: "normal", label: "通用" },
                  { value: "transition", label: "过渡" },
                  { value: "strict1382", label: "1382严格" },
                ], tip: "保存后会重算当前会话。" },
              ],
            },
            ...[1, 2, 3, 4, 5].map((n) => ({
              id: `g${n}`,
              label: `节奏线${n}`,
              items: [
                { label: `节奏线${n}颜色`, subKey: `group${n}LineColor`, type: "color" },
                { label: `节奏线${n}粗细`, subKey: `group${n}LineWidth`, type: "number", min: 0.1, max: 8, step: 0.1 },
                { label: `节奏线${n}线型`, subKey: `group${n}LineStyle`, type: "select", options: [
                  { value: "dashed", label: "虚线" },
                  { value: "solid", label: "实线" },
                  { value: "dotted", label: "点线" },
                ]},
                { label: `节奏线${n}数字颜色`, subKey: `group${n}TextColor`, type: "color" },
                { label: `节奏线${n}数字大小`, subKey: `group${n}TextFontSize`, type: "number", min: 8, max: 32, step: 1 },
                { label: `节奏线${n}数字粗细`, subKey: `group${n}TextFontWeight`, type: "select", options: [
                  { value: "normal", label: "常规" },
                  { value: "bold", label: "加粗" },
                ]},
              ],
            })),
          ],
        },
      ],
    },
    {
      title: "分型中枢",
      key: "fractZs",
      color: "#c2410c",
      bgColor: "rgba(194, 65, 12, 0.08)",
      items: [
        { label: "启用分型中枢", subKey: "enabled", type: "checkbox", tip: "关闭后首包不构建/下发分型中枢；会话后开启时按需懒加载。" },
        { label: "分型中枢颜色", subKey: "color", type: "color" },
        { label: "分型中枢粗细", subKey: "width", type: "number", min: 0.1, max: 5, step: 0.1 }
      ]
    },
    {
      title: "笔中枢",
      key: "biZs",
      color: "#ea580c",
      bgColor: "rgba(234, 88, 12, 0.08)",
      items: [
        { label: "启用笔中枢", subKey: "enabled", type: "checkbox", tip: "关闭后首包不下发笔中枢；会话后开启时按需懒加载。" },
        { label: "笔中枢颜色", subKey: "color", type: "color" },
        { label: "笔中枢粗细", subKey: "width", type: "number", min: 0.1, max: 5, step: 0.1 }
      ]
    },
    {
      title: "段中枢",
      key: "segZs",
      color: "#0d9488",
      bgColor: "rgba(13, 148, 136, 0.08)",
      items: [
        { label: "启用段中枢", subKey: "enabled", type: "checkbox", tip: "关闭后首包不下发段中枢；会话后开启时按需懒加载。" },
        { label: "段中枢颜色", subKey: "color", type: "color" },
        { label: "段中枢粗细", subKey: "width", type: "number", min: 0.1, max: 5, step: 0.1 }
      ]
    },
    {
      title: "2段中枢",
      key: "segsegZs",
      color: "#1d4ed8",
      bgColor: "rgba(29, 78, 216, 0.08)",
      items: [
        { label: "启用2段中枢", subKey: "enabled", type: "checkbox", tip: "关闭后首包不构建/下发2段中枢；会话后开启时按需懒加载。" },
        { label: "2段中枢颜色", subKey: "color", type: "color" },
        { label: "2段中枢粗细", subKey: "width", type: "number", min: 0.1, max: 5, step: 0.1 }
      ]
    },
    {
      title: "K线下方买卖点（总）",
      key: "shared_bsp_bottom",
      color: "#991b1b",
      bgColor: "rgba(153, 27, 27, 0.08)",
      items: [
        {
          label: "显示图底买卖点标注",
          subKey: "enabled",
          type: "checkbox",
          tip: "总开关：关闭后隐藏 K 线下方买卖点标签与垂线；笔/段/2段买卖点样式仍可在下方各节调整。单周期、双周期、各 K 线周期与步进/统一喂数据模式均适用。",
        },
      ],
    },
    {
      title: "笔买卖点",
      key: "bspBi",
      color: "#be123c",
      bgColor: "rgba(190, 18, 60, 0.08)",
      items: [
        { label: "启用笔买卖点", subKey: "enabled", type: "checkbox", tip: "关闭后加载会话首包不计算/下发笔买卖点；会话后再开启会按需懒加载。" },
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 30 },
        { label: "连线颜色", subKey: "lineColor", type: "color" },
        { label: "连线粗细", subKey: "lineWidth", type: "number", min: 0.1, max: 5, step: 0.1 },
        { label: "竖线延长线", subKey: "showLowerExtension", type: "checkbox", tip: "控制买卖点从K线低点向下连接到底部信号框的竖线显示。" },
        { label: "连线线型", subKey: "lineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]}
      ]
    },
    {
      title: "段买卖点",
      key: "bspSeg",
      color: "#9f1239",
      bgColor: "rgba(159, 18, 57, 0.08)",
      items: [
        { label: "启用段买卖点", subKey: "enabled", type: "checkbox", tip: "关闭后加载会话首包不计算/下发段买卖点；会话后再开启会按需懒加载。" },
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 30 },
        { label: "连线颜色", subKey: "lineColor", type: "color" },
        { label: "连线粗细", subKey: "lineWidth", type: "number", min: 0.1, max: 5, step: 0.1 },
        { label: "竖线延长线", subKey: "showLowerExtension", type: "checkbox", tip: "控制买卖点从K线低点向下连接到底部信号框的竖线显示。" },
        { label: "连线线型", subKey: "lineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]}
      ]
    },
    {
      title: "2段买卖点",
      key: "bspSegseg",
      color: "#881337",
      bgColor: "rgba(136, 19, 55, 0.08)",
      items: [
        { label: "启用2段买卖点", subKey: "enabled", type: "checkbox", tip: "关闭后加载会话首包不计算/下发2段买卖点；会话后再开启会按需懒加载。" },
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 30 },
        { label: "连线颜色", subKey: "lineColor", type: "color" },
        { label: "连线粗细", subKey: "lineWidth", type: "number", min: 0.1, max: 5, step: 0.1 },
        { label: "竖线延长线", subKey: "showLowerExtension", type: "checkbox", tip: "控制买卖点从K线低点向下连接到底部信号框的竖线显示。" },
        { label: "连线线型", subKey: "lineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]}
      ]
    },
    {
      title: "1382提示",
      key: "rhythmHit",
      color: "#6d28d9",
      bgColor: "rgba(109, 40, 217, 0.08)",
      items: [
        { label: "启用1382提示", subKey: "enabled", type: "checkbox", tip: "关闭后首包不下发节奏命中；会话后开启时按需懒加载。" },
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 30 },
        { label: "文字颜色", subKey: "color", type: "color" },
        { label: "连线颜色", subKey: "lineColor", type: "color" },
        { label: "连线粗细", subKey: "lineWidth", type: "number", min: 0.1, max: 5, step: 0.1 },
        { label: "连线线型", subKey: "lineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]},
        { label: "同列显示上限", subKey: "overflowLimit", type: "number", min: 1, max: 10, step: 1 },
        { label: "溢出提示颜色", subKey: "overflowColor", type: "color" }
      ]
    },
    {
      title: "自定义支撑压力线 (User Rays)",
      key: "userRay",
      color: "#f97316",
      bgColor: "rgba(249, 115, 22, 0.1)",
      items: [
        { label: "射线颜色", subKey: "color", type: "color" },
        { label: "粗细", subKey: "width", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "线型(虚线间隔)", subKey: "dash", type: "text", placeholder: "如 8, 4" },
        { label: "价格字体大小", subKey: "fontSize", type: "number", min: 8, max: 24 }
      ]
    },
    {
      title: "X 轴设置",
      key: "xAxis",
      color: "#475569",
      bgColor: "rgba(71, 85, 105, 0.08)",
      items: [
        { label: "模式", subKey: "mode", type: "select", options: [
          { value: "manual", label: "手动设置" },
          { value: "auto", label: "自动设置" }
        ], tip: "自动模式会按缩放动态调整字体、角度和日期抽样间隔。" },
        { label: "手动-文字大小", subKey: "fontSize", type: "number", min: 8, max: 24 },
        { label: "手动-文字方向(度)", subKey: "rotation", type: "number", min: -180, max: 180 },
        { label: "手动-文字粗细", subKey: "fontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "手动-刻度间隔(K线)", subKey: "interval", type: "number", min: 1, max: 100 }
      ]
    },
    {
      title: "Y 轴设置",
      key: "yAxis",
      color: "#334155",
      bgColor: "rgba(51, 65, 85, 0.08)",
      items: [
        { label: "模式", subKey: "mode", type: "select", options: [
          { value: "manual", label: "手动设置" },
          { value: "auto", label: "自动设置" }
        ], tip: "自动模式会按纵向缩放动态调整刻度步长和显示精度。" },
        { label: "手动-文字大小", subKey: "fontSize", type: "number", min: 8, max: 24 },
        { label: "手动-文字粗细", subKey: "fontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "手动-刻度间隔(价格)", subKey: "interval", type: "number", min: 0.001, max: 100, step: 0.001 }
      ]
    },
    {
      title: "合并K线线框",
      key: "klineCombineFrame",
      color: "#4f46e5",
      bgColor: "rgba(79, 70, 229, 0.08)",
      items: [
        { label: "启用线框", subKey: "enabled", type: "checkbox", tip: "按合并K线范围绘制独立线框层。" },
        { label: "线框颜色", subKey: "color", type: "color" },
        { label: "线框粗细", subKey: "lineWidth", type: "number", min: 0.1, max: 5, step: 0.1 },
        { label: "线框线型", subKey: "lineStyle", type: "select", options: [
          { value: "solid", label: "实线" },
          { value: "dashed", label: "虚线" },
          { value: "dotted", label: "点线" }
        ]}
      ]
    },
    {
      title: "模拟交易",
      key: "trade",
      color: "#be123c",
      bgColor: "rgba(190, 18, 60, 0.08)",
      items: [
        {
          label: "交易样式",
          subKey: "__nested__",
          type: "nested_cascade",
          tip: "二级：文字标记 / 收盘价线 / 持仓区间。",
          tree: [
            {
              id: "marker", label: "买卖文字标记",
              items: [
                { label: "买入颜色", subKey: "buyColor", type: "color" },
                { label: "卖出颜色", subKey: "sellColor", type: "color" },
                { label: "文字大小", subKey: "markerFontSize", type: "number", min: 10, max: 32 },
                { label: "文字粗细", subKey: "markerFontWeight", type: "select", options: [{ value: "normal", label: "常规" }, { value: "bold", label: "加粗" }] },
                { label: "买卖竖线粗细", subKey: "markerLineWidth", type: "number", min: 0.5, max: 8, step: 0.1 },
                { label: "买卖竖线线型", subKey: "markerLineStyle", type: "select", options: [
                  { value: "dashed", label: "虚线" }, { value: "solid", label: "实线" }, { value: "dotted", label: "点线" },
                ]},
              ],
            },
            {
              id: "close", label: "收盘价指示线",
              items: [
                { label: "指示线粗细", subKey: "closeLineWidth", type: "number", min: 0.5, max: 8, step: 0.1 },
                { label: "买入价线型", subKey: "buyCloseLineStyle", type: "select", options: [
                  { value: "solid", label: "实线" }, { value: "dashed", label: "虚线" }, { value: "dotted", label: "点线" },
                ]},
                { label: "卖出价线型", subKey: "sellCloseLineStyle", type: "select", options: [
                  { value: "dashed", label: "虚线" }, { value: "solid", label: "实线" }, { value: "dotted", label: "点线" },
                ]},
              ],
            },
            {
              id: "range", label: "持仓与盈亏区间",
              items: [
                { label: "持仓区间(买)背景", subKey: "rangeFillBuy", type: "color" },
                { label: "持仓区间(卖)背景", subKey: "rangeFillSell", type: "color" },
                { label: "盈利区间颜色", subKey: "profitBandColor", type: "color" },
                { label: "亏损区间颜色", subKey: "lossBandColor", type: "color" },
              ],
            },
          ],
        },
      ],
    },
    {
      title: "持仓浮窗",
      key: "tradeStatus",
      color: "#1d4ed8",
      bgColor: "rgba(29, 78, 216, 0.08)",
      items: [
        {
          label: "浮窗字体",
          subKey: "__nested__",
          type: "nested_cascade",
          tree: [
            {
              id: "title", label: "标题栏",
              items: [
                { label: "标题大小", subKey: "titleFontSize", type: "number", min: 10, max: 28 },
                { label: "标题粗细", subKey: "titleFontWeight", type: "select", options: [{ value: "normal", label: "常规" }, { value: "bold", label: "加粗" }] },
                { label: "标题颜色", subKey: "titleColor", type: "color" },
              ],
            },
            {
              id: "body", label: "内容区",
              items: [
                { label: "名称大小", subKey: "labelFontSize", type: "number", min: 10, max: 24 },
                { label: "名称粗细", subKey: "labelFontWeight", type: "select", options: [{ value: "normal", label: "常规" }, { value: "bold", label: "加粗" }] },
                { label: "名称颜色", subKey: "labelColor", type: "color" },
                { label: "数值大小", subKey: "valueFontSize", type: "number", min: 10, max: 28 },
                { label: "数值粗细", subKey: "valueFontWeight", type: "select", options: [{ value: "normal", label: "常规" }, { value: "bold", label: "加粗" }] },
                { label: "数值颜色", subKey: "valueColor", type: "color" },
              ],
            },
          ],
        },
      ],
    },
    {
      title: "图例说明",
      key: "legend",
      color: "#7c2d12",
      bgColor: "rgba(124, 45, 18, 0.08)",
      items: [
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 24, tip: "控制左上角图例说明文字大小。" },
        { label: "文字粗细", subKey: "fontWeight", type: "select", options: [{ value: "normal", label: "常规" }, { value: "bold", label: "加粗" }], tip: "控制左上角图例说明文字粗细。" },
        { label: "文字颜色", subKey: "color", type: "color", tip: "控制左上角图例说明文字颜色。" }
      ]
    },
    {
      title: "消息与通知",
      key: "toast",
      color: "#1e293b",
      bgColor: "rgba(30, 41, 59, 0.12)",
      items: [
        {
          label: "通知与步进中断",
          subKey: "__nested__",
          type: "nested_cascade",
          tip: "二级：基础弹窗 / 步进中断规则 / 买卖点档位。",
          tree: [
            {
              id: "basic", label: "基础",
              items: [
                { label: "文字大小", subKey: "fontSize", type: "number", min: 10, max: 30 },
                { label: "文字粗细", subKey: "fontWeight", type: "select", options: [{ value: "normal", label: "常规" }, { value: "bold", label: "加粗" }] },
                { label: "消失速度(ms)", subKey: "speed", type: "number", min: 500, max: 10000, step: 100 },
                { label: "显示买卖点弹窗", subKey: "showBsp", type: "checkbox" },
                { label: "显示1382弹窗", subKey: "showRhythm1382", type: "checkbox" },
                { label: "显示判定统计弹窗", subKey: "showJudge", type: "checkbox" },
              ],
            },
            {
              id: "interrupt", label: "步进 N 中断",
              items: [
                { label: "步进N遇买卖点中断", subKey: "interruptOnBsp", type: "checkbox" },
                { label: "步进N遇1382中断", subKey: "interruptOnRhythm1382", type: "checkbox" },
                { label: "BSP 与 1382 组合", subKey: "interruptStepSourcesCombine", type: "select", options: [
                  { value: "or", label: "OR（任一来源）" }, { value: "and", label: "AND（同时命中）" },
                ]},
                { label: "买卖点细分组合", subKey: "interruptBspFineCombine", type: "select", options: [
                  { value: "or", label: "OR（任一档位）" }, { value: "and", label: "AND（各档同时）" },
                ]},
                { label: "方向例外", subKey: "interruptBspSideException", type: "select", options: [
                  { value: "none", label: "无例外" }, { value: "buy_only", label: "仅买点" }, { value: "sell_only", label: "仅卖点" },
                ]},
                { label: "未列出类型仍中断", subKey: "interruptBspUnlistedTypes", type: "checkbox" },
              ],
            },
            {
              id: "bspCascade", label: "买卖点档位",
              items: [
                {
                  label: "步进N买卖点中断档位",
                  subKey: "interruptBspCascade",
                  type: "interrupt_bsp_cascade",
                  tip: "三级：级别 → 类型 → 买/卖。",
                },
              ],
            },
          ],
        },
      ],
    }
  ];

  mountChartSettingsCascadePanel(container, sections, buildLabelHtml);
}

function renderSystemSettingsForm() {
    const container = $("systemSettingsContent");
    container.innerHTML = "";

    // 添加数据源管理区块
    const dsSec = document.createElement("div");
    dsSec.className = "settingsSection";
    dsSec.style.background = "rgba(245, 158, 11, 0.08)";
    dsSec.innerHTML = `<div class="settingsSectionTitle" style="color:#f59e0b">数据源管理</div>`;

    const dsGrid = document.createElement("div");
    dsGrid.className = "settingsGrid";
    dsGrid.id = "dataSourceGrid";

    // 添加说明
    const dsNote = document.createElement("div");
    dsNote.className = "muted";
    dsNote.style.fontSize = "12px";
    dsNote.style.gridColumn = "1 / -1";
    dsNote.textContent = "拖拽或上下键调整顺序；列表为全部可用源，仅调整优先级。K 线与筹码共用此顺序，服务端按同一顺序分别在两条链上回退，可选用不同实际源。";
    dsGrid.appendChild(dsNote);

    // 数据源优先级列表容器
    const dsList = document.createElement("div");
    dsList.id = "dataSourceList";
    dsList.style.gridColumn = "1 / -1";
    dsList.style.display = "flex";
    dsList.style.flexDirection = "column";
    dsList.style.gap = "6px";
    dsList.style.marginTop = "8px";

    // 获取当前数据源优先级配置
    const currentPriority = systemConfig.dataSourcePriority || ["AKShare", "Ashare", "AData", "pytdx", "BaoStock", "离线数据", "Tushare", "新浪财经", "腾讯财经", "雅虎财经", "东方财富"];
    
    currentPriority.forEach((srcName, idx) => {
        const item = document.createElement("div");
        item.className = "dataSourceItem";
        item.style.display = "flex";
        item.style.alignItems = "center";
        item.style.gap = "8px";
        item.style.padding = "6px 10px";
        item.style.background = "var(--panel)";
        item.style.border = "1px solid var(--border)";
        item.style.borderRadius = "6px";
        item.draggable = true;
        item.dataset.index = String(idx);
        item.dataset.name = srcName;
        
        // 拖拽手柄
        const handle = document.createElement("span");
        handle.textContent = "☰";
        handle.style.cursor = "move";
        handle.style.color = "var(--muted)";
        handle.style.fontSize = "16px";
        item.appendChild(handle);
        
        // 名称
        const nameSpan = document.createElement("span");
        nameSpan.textContent = srcName;
        nameSpan.style.flex = "1";
        nameSpan.style.fontWeight = "bold";
        item.appendChild(nameSpan);
        
        // 状态（模拟检测）
        const statusSpan = document.createElement("span");
        statusSpan.className = "dataSourceStatus";
        statusSpan.textContent = "●";
        statusSpan.style.color = "#22c55e"; // 默认绿色，表示可用
        statusSpan.style.fontSize = "12px";
        statusSpan.title = "点击检测状态";
        statusSpan.onclick = () => checkDataSource(srcName);
        item.appendChild(statusSpan);
        
        // 上移按钮
        const upBtn = document.createElement("button");
        upBtn.textContent = "↑";
        upBtn.style.width = "auto";
        upBtn.style.padding = "2px 6px";
        upBtn.onclick = () => moveDataSource(idx, -1);
        item.appendChild(upBtn);
        
        // 下移按钮
        const downBtn = document.createElement("button");
        downBtn.textContent = "↓";
        downBtn.style.width = "auto";
        downBtn.style.padding = "2px 6px";
        downBtn.onclick = () => moveDataSource(idx, 1);
        item.appendChild(downBtn);

        // 拖拽事件
        item.ondragstart = (e) => {
            draggedItem = item;
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('text/plain', item.dataset.index);
            setTimeout(() => item.style.opacity = '0.5', 0);
        };
        item.ondragover = (e) => e.preventDefault();
        item.ondrop = (e) => onDrop(e, item);
        
        dsList.appendChild(item);
    });
    
    dsGrid.appendChild(dsList);

    dsSec.appendChild(dsGrid);
    container.appendChild(dsSec);

    const perfSec = document.createElement("div");
    perfSec.className = "settingsSection";
    perfSec.style.background = "rgba(79, 70, 229, 0.08)";
    perfSec.innerHTML = `<div class="settingsSectionTitle" style="color:#4f46e5">性能引擎</div>`;
    const perfGrid = document.createElement("div");
    perfGrid.className = "settingsGrid";
    const perfModeItem = document.createElement("div");
    perfModeItem.className = "settingsItem";
    perfModeItem.style.gridColumn = "1 / -1";
  perfModeItem.innerHTML = `<label>运行模式 <span class="tip-icon" data-tip="${escapeHtmlAttr("Rust极速：使用 a_rust_core 编译扩展；Rust 调用失败会直接弹窗并写入历史记录。Python兼容：关闭极速 payload，用旧逻辑排查问题。保存后重新加载会话生效。")}">!</span></label>`;
    const perfSel = document.createElement("select");
    perfSel.dataset.sysKey = "performanceEngineMode";
    perfSel.innerHTML = `<option value="rust_auto">Rust极速（自动回退）</option><option value="python_legacy">Python兼容</option>`;
    perfSel.value = String(systemConfig.performanceEngineMode || DEFAULT_SYSTEM_CONFIG.performanceEngineMode || "rust_auto");
    perfModeItem.appendChild(perfSel);
    const perfNote = document.createElement("div");
    perfNote.className = "muted";
    perfNote.style.fontSize = "12px";
    perfNote.textContent = "操作步骤：保存系统配置 → 重新加载会话。当前阶段先加速数据/筹码/步进增量协议，缠论结构仍按 Python 严格计算。";
    perfModeItem.appendChild(perfNote);
    perfGrid.appendChild(perfModeItem);
    const perfBtnItem = document.createElement("div");
    perfBtnItem.className = "settingsItem";
    perfBtnItem.style.gridColumn = "1 / -1";
    perfBtnItem.innerHTML = `<label>缓存维护</label><button type="button" id="btnPerfCacheStatus" style="width:auto;">查看性能缓存</button><button type="button" id="btnPerfCacheClear" style="width:auto;margin-top:6px;">清理性能缓存</button>`;
    perfGrid.appendChild(perfBtnItem);
    perfSec.appendChild(perfGrid);
    container.appendChild(perfSec);
    setTimeout(() => {
      const statusBtn = $("btnPerfCacheStatus");
      const clearBtn = $("btnPerfCacheClear");
      if (statusBtn) {
        statusBtn.onclick = async () => {
          try {
            const st = await api("/api/perf_cache_status", null, "GET");
            showAlertAndLog(`性能缓存状态：\n模式：${st.engine_mode}\nRust可用：${st.rust_available ? "是" : "否"}\n文件数：${st.file_count}\n大小：${Math.round(Number(st.total_bytes || 0) / 1024)} KB\n目录：${st.cache_dir}`);
          } catch (e) {
            showToast("读取性能缓存失败：" + e.message);
          }
        };
      }
      if (clearBtn) {
        clearBtn.onclick = async () => {
          if (!confirmAndLog("确定清理性能引擎缓存吗？下次加载会重新解析并生成缓存。")) return;
          try {
            const st = await api("/api/perf_clear_cache", {}, "POST");
            showAlertAndLog(`性能缓存已清理：删除 ${st.removed || 0} 个文件。`);
          } catch (e) {
            showToast("清理性能缓存失败：" + e.message);
          }
        };
      }
    }, 0);

    // 继续原有的买卖点判定部分
    const bspSec = document.createElement("div");
    bspSec.className = "settingsSection";
    bspSec.style.background = "rgba(34, 197, 94, 0.08)";
    bspSec.innerHTML = `<div class="settingsSectionTitle" style="color:#16a34a">买卖点判定</div>`;

  const bspGrid = document.createElement("div");
  bspGrid.className = "settingsGrid";

  const bspItem = document.createElement("div");
  bspItem.className = "settingsItem";
  bspItem.style.gridColumn = "1 / -1";
  bspItem.innerHTML = `<label>判定方式 <span class="tip-icon" data-tip="${escapeHtmlAttr("自动：段/2段/隐藏更高层变向时，会分别对笔/段/2段买卖点自动判定 ×/✓。手动：不自动判定，需要点击“检查买卖点”或按快捷键。由手动切回自动时，会自动补判当前尚未判定的三层买卖点，并记录。")}">!</span></label>`;

  const bspSel = document.createElement("select");
  bspSel.dataset.sysKey = "bspJudgeMode";
  bspSel.innerHTML = `<option value="auto">自动</option><option value="manual">手动</option>`;
  bspSel.value = isBspJudgeManual() ? "manual" : "auto";
  bspItem.appendChild(bspSel);

  const bspNote = document.createElement("div");
  bspNote.className = "muted";
  bspNote.style.fontSize = "12px";
  bspNote.textContent = `默认快捷键：自动(${getActionShortcutDisplay("setBspJudgeAuto") || "未设置"})；手动(${getActionShortcutDisplay("setBspJudgeManual") || "未设置"})；检查三层买卖点(${getActionShortcutDisplay("checkBspJudge") || "未设置"})。`;
  bspItem.appendChild(bspNote);

  bspGrid.appendChild(bspItem);
  bspSec.appendChild(bspGrid);
  container.appendChild(bspSec);

  const recSec = document.createElement("div");
  recSec.className = "settingsSection";
  recSec.style.background = "rgba(99, 102, 241, 0.08)";
  recSec.innerHTML = `<div class="settingsSectionTitle" style="color:#6366f1">历史缓存</div>`;
  const recGrid = document.createElement("div");
  recGrid.className = "settingsGrid";
  const recItem = document.createElement("div");
  recItem.className = "settingsItem";
  recItem.style.gridColumn = "1 / -1";
  const recTip =
    "本分支已关闭 K线会话磁盘缓存与缠论 record 缓存。\n" +
    "加载会话时固定从 a_Data 离线分笔重新取数、重新计算，不再读取或生成 pkl。";
  recItem.innerHTML = `<label>已禁用本地历史缓存</label> <span class="tip-icon" data-tip="${escapeHtmlAttr(recTip)}">!</span>`;
  const recNote = document.createElement("div");
  recNote.className = "muted";
  recNote.style.fontSize = "12px";
  recNote.textContent = "当前加载策略：每次从 a_Data 重新计算；不会写入 a_replay_cache/kline_sessions 或 a_replay_record 的 pkl 文件。";
  recItem.appendChild(recNote);
  recGrid.appendChild(recItem);
  recSec.appendChild(recGrid);
  container.appendChild(recSec);

  const section = document.createElement("div");
  section.className = "settingsSection";
  section.style.background = "rgba(14, 165, 233, 0.08)";
  section.innerHTML = `<div class="settingsSectionTitle" style="color:#0ea5e9">快捷键配置</div>`;

  const intro = document.createElement("div");
  intro.className = "muted";
  intro.style.marginBottom = "12px";
  intro.textContent = "同一功能支持配置多个快捷键，可用英文逗号或换行分隔；支持单键（如 e）、组合键（如 Ctrl+A）和连续字母序列（如 center）。若同一快捷键命中多个操作，则按当前列表顺序优先，越靠前优先级越高。";
  section.appendChild(intro);

  const grid = document.createElement("div");
  grid.className = "settingsGrid";

  SHORTCUT_ACTIONS.forEach(action => {
    const itemDiv = document.createElement("div");
    itemDiv.className = "settingsItem";
    itemDiv.style.gridColumn = "1 / -1";

    const conflicts = getShortcutConflicts(action.id);
    const current = getActionShortcutDisplay(action.id) || "未设置";
    const tipText = [
      `操作：${action.label}`,
      action.description,
      `当前快捷键：${current}`,
      "支持格式：e、Ctrl+A、Ctrl+Alt+N、center。",
      "提示：Backspace 用于删除，不录为快捷键。",
      conflicts.length > 0 ? `冲突提示：${conflicts.join("；")}` : "冲突提示：当前无重复快捷键。"
    ].join("\n");

    const label = document.createElement("label");
    label.innerHTML = `${action.label} <span class="tip-icon" data-tip="${escapeHtmlAttr(tipText)}">!</span>`;
    itemDiv.appendChild(label);

    const input = document.createElement("input");
    input.type = "text";
    input.dataset.actionId = action.id;
    input.placeholder = "点击录入... Backspace删除";
    input.value = getActionShortcuts(action.id).map(item => formatShortcut(item)).join(", ");
    itemDiv.appendChild(input);

    // 快捷键自动录入逻辑
    input.onkeydown = (e) => {
      // 允许的功能键
      if (["Tab", "CapsLock", "NumLock", "ScrollLock", "Pause"].includes(e.key)) return;
      
      // 处理清除逻辑 (Backspace 只用于删除，不录入)
      if (e.key === "Backspace") {
        e.preventDefault();
        const currentValues = input.value.split(/[,，]/).map(v => v.trim()).filter(Boolean);
        if (currentValues.length > 0) {
          const lastValue = currentValues[currentValues.length - 1];
          // 如果是序列（纯字母），删掉最后一个字母；否则删掉整个 token
          if (/^[a-z0-9]+$/i.test(lastValue) && lastValue.length > 1) {
            currentValues[currentValues.length - 1] = lastValue.slice(0, -1);
          } else {
            currentValues.pop();
          }
          input.value = currentValues.join(", ");
        }
        return;
      }
      if (e.key === "Escape") {
        input.blur();
        return;
      }

      e.preventDefault();
      e.stopPropagation();

      // 获取当前按键对应的 token
      const token = eventToShortcutKeyToken(e);
      if (!token) return;

      // 判断是否有修饰键
      const modifiers = [];
      if (e.ctrlKey) modifiers.push("Ctrl");
      if (e.altKey) modifiers.push("Alt");
      if (e.shiftKey) modifiers.push("Shift");
      if (e.metaKey) modifiers.push("Meta");

      let keyLabel = token;
      const keyMap = {
        space: "Space",
        enter: "Enter",
        pageup: "PageUp",
        pagedown: "PageDown",
        arrowup: "ArrowUp",
        arrowdown: "ArrowDown",
        arrowleft: "ArrowLeft",
        arrowright: "ArrowRight",
        escape: "Esc",
      };
      keyLabel = keyMap[token] || token;
      if (/^[a-z]$/.test(keyLabel)) keyLabel = keyLabel.toUpperCase();
      else if (/^f[0-9]{1,2}$/.test(keyLabel)) keyLabel = keyLabel.toUpperCase();

      const comboStr = modifiers.length > 0 ? `${modifiers.join("+")}+${keyLabel}` : keyLabel;

      // 如果是连续按键（如 gg），处理逻辑
      // 简单逻辑：如果是普通字母且没有修饰键，支持追加成序列
      const isPlainLetter = /^[a-z0-9]$/i.test(e.key) && !e.ctrlKey && !e.altKey && !e.metaKey;
      
      const currentValues = input.value.split(/[,，]/).map(v => v.trim()).filter(Boolean);
      if (currentValues.length > 0) {
        const lastValue = currentValues[currentValues.length - 1];
        // 如果最后是一个纯字母序列，且当前也是纯字母，则尝试追加
        if (isPlainLetter && /^[a-z0-9]+$/i.test(lastValue) && lastValue.length < 10) {
          currentValues[currentValues.length - 1] = lastValue + e.key.toLowerCase();
        } else {
          // 否则作为新的快捷键追加（以逗号分隔）
          if (!currentValues.includes(comboStr)) {
            currentValues.push(comboStr);
          }
        }
      } else {
        currentValues.push(comboStr);
      }
      
      input.value = currentValues.join(", ");
    };

    const note = document.createElement("div");
    note.className = "muted";
    note.style.fontSize = "12px";
    note.textContent = `默认：${action.defaults.map(item => formatShortcut(item)).join(" / ") || "未设置"}。`;
    itemDiv.appendChild(note);

    if (conflicts.length > 0) {
      const conflictNote = document.createElement("div");
      conflictNote.className = "muted";
      conflictNote.style.fontSize = "12px";
      conflictNote.style.color = "#dc2626";
      conflictNote.textContent = `冲突：${conflicts.join("；")}`;
      itemDiv.appendChild(conflictNote);
    }

    grid.appendChild(itemDiv);
  });

  section.appendChild(grid);
  container.appendChild(section);
  initTooltips();
}

async function loadChartLazyLayers(layers) {
  const ctl = prepareCancelableLoading("正在加载图表图层，请稍候…", "图表懒加载：准备加载勾选图层…");
  try {
    const payload = await api("/api/load_chart_layers", {
      chart_lazy_layers: layers || collectChartLazyLayersFromConfig(chartConfig, chartConfigStore),
    }, "POST", { signal: ctl.signal });
    if (payload && Array.isArray(payload.record_trace)) {
      const startIdx = initStatusPollTimer ? Math.min(initTraceSeenCount, payload.record_trace.length) : 0;
      payload.record_trace.slice(startIdx).forEach((line) => appendMsgHistory(String(line)));
      initTraceSeenCount = Math.max(initTraceSeenCount, payload.record_trace.length);
      // 已在懒加载流程刷过历史，避免 refreshUI 再重复刷一遍。
      payload.record_trace = [];
    }
    return payload;
  } finally {
    finishCancelableLoading(true);
  }
}

async function saveSettings() {
  const prevLazyLayers = collectChartLazyLayersFromConfig(chartConfig, chartConfigStore);
  const prevDataFormSnapshot = JSON.stringify(dataFormConfig || {});
  const prevChanSnapshot = JSON.stringify(chanConfig || {});
  if (isSettingsOpen()) flushChartSettingsFormToMemory();
  const prevRhythmCalcMode = normalizeRhythmCalcMode(chartConfig.rhythmLine && chartConfig.rhythmLine.calcMode);
  const prevKlinePresentation = normalizeKlinePresentationMode(dataFormConfig.klinePresentation);
  const prevOfflineDataCustom = normalizeOfflineDataCustom(dataFormConfig.offlineDataCustom);
  const nextOfflineDataCustom = normalizeOfflineDataCustom(dataFormConfig.offlineDataCustom);
  if (chartConfig.theme) applyThemeFromSelect();
  storageSet("chan_indicator_main_slots", JSON.stringify(indicatorMainSlots));
  storageSet("chan_indicator_sub_slots", JSON.stringify(indicatorSubSlots));
  storageSet("chan_selected_main_indicator_slot", String(selectedMainIndicatorSlot));
  storageSet("chan_selected_sub_indicator_slot", String(selectedSubIndicatorSlot));
  storageSet("chan_indicator_main_var_visible", indicatorMainVarVisible ? "1" : "0");
  storageSet("chan_indicator_sub_var_visible", indicatorSubVarVisible ? "1" : "0");
  applyRhythmCalcModeToChanConfig(chanConfig);
  const nextRhythmCalcMode = normalizeRhythmCalcMode(chartConfig.rhythmLine && chartConfig.rhythmLine.calcMode);
  storageSet("chan_logic_config", JSON.stringify(chanConfig));
  chartSettingsDraftBaseline = null;
  saveSessionConfig();
  const activeCfgKey = (lastPayload && lastPayload.ready && String(lastPayload.active_chart_id) === "chart2")
    ? "chart2"
    : (String(sessionConfig.activeChartId || dualActiveChartId || "chart1") === "chart2" ? "chart2" : "chart1");
  if (chartConfig.crosshair && typeof chartConfig.crosshair.enabled === "boolean") {
    crosshairEnabled = !!chartConfig.crosshair.enabled;
  }
  persistChartConfigStoreNow(true);
  chartSettingsCloseKeepDraft = true;
  closeSettings();
  if (prevOfflineDataCustom !== nextOfflineDataCustom) {
    showAlertAndLog(
      `离线数据自定义已切换为【${offlineDataCustomLabel(nextOfflineDataCustom)}】。\n` +
      (nextOfflineDataCustom === "merge_no_bs" ? OFFLINE_DATA_CUSTOM_HELP.split("\n").slice(1).join("\n") : "已恢复原生分笔解析。")
    );
  }
  if (prevRhythmCalcMode !== nextRhythmCalcMode) {
    showAlertAndLog(
      `节奏线计算逻辑已切换为【${RHYTHM_CALC_MODE_LABELS[nextRhythmCalcMode]}】。\n` +
      "操作逻辑：保存后会将该模式写入缠论配置，并从第1根K线重算当前会话。\n" +
      "显示层级只影响前端显示，不改变服务端计算结果。"
    );
  }
  if (lastPayload && lastPayload.ready) {
    const nextLazyLayers = collectChartLazyLayersFromConfig(chartConfig, chartConfigStore);
    const newLazyLayers = filterUnloadedLazyLayers(
      diffEnabledLazyLayers(prevLazyLayers, nextLazyLayers),
      lastPayload.chart_lazy_layers
    );
    const dataFormSame = prevDataFormSnapshot === JSON.stringify(dataFormConfig || {});
    const chanSame = prevChanSnapshot === JSON.stringify(chanConfig || {});
    if (dataFormSame && chanSame) {
      if (hasAnyLazyLayer(newLazyLayers)) {
        const payload = await loadChartLazyLayers(newLazyLayers);
        refreshUI(payload, { afterStep: false });
        setMsg(payload.message || "图表懒加载图层加载完成");
      } else {
        drawFromLastPayload();
        setMsg("图表显示设置已保存");
      }
      return;
    }
    const n = getRawKlineCount();
    if (isQuantityDataFormMode(dataFormConfig.mode) && n <= 0) {
      throw new Error("请先加载会话后再使用数量类模式。");
    }
    const ctl = prepareCancelableLoading("正在按新设置重算会话…", "图表设置：开始按新配置重算当前会话…");
    let payload;
    try {
      payload = await api("/api/reconfig", {
      chan_config: chanConfig,
      data_form_mode: dataFormConfig.mode,
      data_form_quantity: clampDataFormQuantity(dataFormConfig.quantity, n || 1),
      data_form_quantity_alloc: normalizeDataFormQuantityAlloc(dataFormConfig.quantityAlloc),
      data_feed_mode: normalizeDataFeedMode(dataFormConfig.feedMode),
      offline_data_custom: normalizeOfflineDataCustom(dataFormConfig.offlineDataCustom),
      kline_presentation_mode: normalizeKlinePresentationMode(dataFormConfig.klinePresentation),
      rollback_cache_depth: Number(systemConfig.rollbackCacheDepth || DEFAULT_SYSTEM_CONFIG.rollbackCacheDepth),
      rollback_full_snapshot_interval: Number(systemConfig.rollbackFullSnapshotInterval || DEFAULT_SYSTEM_CONFIG.rollbackFullSnapshotInterval),
      rollback_capture_max_bars: Number(systemConfig.rollbackCaptureMaxBars || DEFAULT_SYSTEM_CONFIG.rollbackCaptureMaxBars),
      performance_engine_mode: String(systemConfig.performanceEngineMode || DEFAULT_SYSTEM_CONFIG.performanceEngineMode || "rust_auto"),
      chip_bucket_step: Number(chartConfig.chip && chartConfig.chip.bucketStep ? chartConfig.chip.bucketStep : 0.1),
      chart_lazy_layers: collectChartLazyLayersFromConfig(chartConfig, chartConfigStore),
      }, "POST", { signal: ctl.signal });
    } finally {
      finishCancelableLoading(false);
    }
    refreshUI(payload, { afterStep: false });
    void fetchChipKlineAllLazy(payload);
    setMsg(payload.message || "图表设置更新成功");
    if (prevKlinePresentation !== normalizeKlinePresentationMode(dataFormConfig.klinePresentation)) {
      showAlertAndLog(
        `K线图呈现已切换为【${dataFormConfig.klinePresentation === "instant" ? "一次性呈现" : "步进"}】。\n` +
        "一次性呈现：加载/重配后直接显示末根完整图表；步进：从第一根起逐步展示。"
      );
    }
  } else if (lastPayload && lastPayload.chart) {
    drawFromLastPayload();
  } else {
    canvas.style.cursor = crosshairEnabled ? "crosshair" : "default";
  }
}

function saveSystemSettingsFromForm() {
    const modeSelect = $("systemSettingsContent").querySelector('select[data-sys-key="bspJudgeMode"]');
    if (modeSelect) {
        const prev = systemConfig.bspJudgeMode;
        const next = String(modeSelect.value || "auto") === "manual" ? "manual" : "auto";
        systemConfig.bspJudgeMode = next;
        if (prev === "manual" && next === "auto" && lastPayload && lastPayload.ready) {
            saveSystemConfig();
            updateBspJudgeUI();
            showAlertAndLog("买卖点判定方式切换：手动 → 自动。\n将自动补判当前尚未判定的笔/段/2段买卖点，并记录到后台。");
            checkBspJudge("switch_manual_to_auto");
        } else if (prev === "auto" && next === "manual") {
            saveSystemConfig();
            updateBspJudgeUI();
            showAlertAndLog("买卖点判定方式切换：自动 → 手动。\n上一级结构变向时将不再自动判定，需手动点击“检查买卖点”。");
        }
    }
    const perfModeSelect = $("systemSettingsContent").querySelector('select[data-sys-key="performanceEngineMode"]');
    if (perfModeSelect) {
        const nextPerf = String(perfModeSelect.value || "rust_auto");
        const prevPerf = String(systemConfig.performanceEngineMode || DEFAULT_SYSTEM_CONFIG.performanceEngineMode || "rust_auto");
        systemConfig.performanceEngineMode = nextPerf === "python_legacy" ? "python_legacy" : "rust_auto";
        if (prevPerf !== systemConfig.performanceEngineMode) {
            showAlertAndLog("性能引擎模式已更新。\n操作逻辑：保存后请重新加载会话；Rust极速模式会优先使用 a_rust_core，失败时自动回退 Python。");
        }
    }
    
    // 保存数据源配置
    const dataSourcePriority = getDataSourcePriority();
    if (dataSourcePriority && dataSourcePriority.length > 0) {
        systemConfig.dataSourcePriority = dataSourcePriority;
    }

    const recChk = $("systemSettingsContent").querySelector('input[data-sys-key="chanRecordEnabled"]');
    if (recChk) {
        const prevRec = systemConfig.chanRecordEnabled === true;
        systemConfig.chanRecordEnabled = !!recChk.checked;
        if (prevRec !== systemConfig.chanRecordEnabled) {
            showAlertAndLog(
                systemConfig.chanRecordEnabled
                    ? "已启用缠论 record：下次加载同配置会话将尝试从 a_replay_record 复用计算结果。"
                    : "已关闭缠论 record：不再写入/读取 a_replay_record（已有文件仍保留）。"
            );
        }
    }
    systemConfig.chanRecordEnabled = false;
    systemConfig.dataSourcePriority = ["离线数据"];

    const inputs = $("systemSettingsContent").querySelectorAll("input[data-action-id]");
    const nextShortcuts = {};
    const errors = [];

    inputs.forEach(input => {
        const actionId = input.dataset.actionId;
        const action = SHORTCUT_ACTION_MAP[actionId];
        if (!action) return;
        const { parsed, invalid } = parseShortcutList(input.value);
        if (invalid.length > 0) {
            errors.push(`${action.label}: ${invalid.join("、")}`);
            return;
        }
        nextShortcuts[actionId] = parsed.map(canonicalizeShortcut);
    });

    if (errors.length > 0) {
        showAlertAndLog(`以下快捷键格式无法识别，请修改后再保存：\n${errors.join("\n")}`);
        return;
    }

    systemConfig.shortcuts = {};
    SHORTCUT_ACTIONS.forEach(action => {
        systemConfig.shortcuts[action.id] = nextShortcuts[action.id] || [];
    });
    saveSystemConfig();
    closeSystemSettings();
    renderSystemSettingsForm();
    updateBspJudgeUI();
}

function showFloatingTip(text, clientX, clientY, avoidRect = null) {
  const tipContent = $("tipContent");
  if (!tipContent || !text) return;
  tipContent.textContent = text;
  tipContent.style.display = "block";
  const tipRect = tipContent.getBoundingClientRect();
  let top = clientY - tipRect.height / 2;
  let left = clientX + 12;
  if (avoidRect) {
    const gap = 14;
    const rightCandidate = avoidRect.right + gap;
    const leftCandidate = avoidRect.left - tipRect.width - gap;
    if (rightCandidate + tipRect.width <= window.innerWidth - 8) {
      left = rightCandidate;
    } else if (leftCandidate >= 8) {
      left = leftCandidate;
    }
    const centeredTop = avoidRect.top + (avoidRect.height - tipRect.height) / 2;
    top = Math.max(8, centeredTop);
  } else if (left + tipRect.width > window.innerWidth) {
    left = clientX - tipRect.width - 12;
  }
  if (left + tipRect.width > window.innerWidth) left = window.innerWidth - tipRect.width - 8;
  if (top + tipRect.height > window.innerHeight) top = window.innerHeight - tipRect.height - 8;
  if (top < 0) top = 8;
  if (left < 0) left = 8;
  tipContent.style.top = `${top}px`;
  tipContent.style.left = `${left}px`;
}

function hideFloatingTip() {
  const tipContent = $("tipContent");
  if (tipContent) tipContent.style.display = "none";
}

function initTooltips() {
  // data-tip 专用：优先贴近按钮上下方，且尽量避开 K 线画布区域
  const showTooltipNearTarget = (target, text) => {
    const tipContent = $("tipContent");
    if (!tipContent || !text || !target) return;
    tipContent.textContent = text;
    tipContent.style.display = "block";
    const tipRect = tipContent.getBoundingClientRect();
    const targetRect = target.getBoundingClientRect();
    const chartRect = canvas ? canvas.getBoundingClientRect() : null;
    const gap = 10;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const minEdge = 8;
    const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
    let left = targetRect.left + (targetRect.width - tipRect.width) / 2;
    left = clamp(left, minEdge, Math.max(minEdge, vw - tipRect.width - minEdge));
    const overlapWithChart = (top) => {
      if (!chartRect) return false;
      const right = left + tipRect.width;
      const bottom = top + tipRect.height;
      return !(right <= chartRect.left || left >= chartRect.right || bottom <= chartRect.top || top >= chartRect.bottom);
    };
    const topAbove = targetRect.top - tipRect.height - gap;
    const topBelow = targetRect.bottom + gap;
    const aboveOk = topAbove >= minEdge;
    const belowOk = topBelow + tipRect.height <= vh - minEdge;
    const aboveClear = aboveOk && !overlapWithChart(topAbove);
    const belowClear = belowOk && !overlapWithChart(topBelow);
    let top = topBelow;
    if (aboveClear) top = topAbove;
    else if (belowClear) top = topBelow;
    else if (aboveOk) top = topAbove;
    else if (belowOk) top = topBelow;
    else {
      // 极端空间不足时兜底：继续贴近控件，按窗口边界裁剪
      top = clamp(topBelow, minEdge, Math.max(minEdge, vh - tipRect.height - minEdge));
    }
    tipContent.style.top = `${top}px`;
    tipContent.style.left = `${left}px`;
  };
  const showTooltip = (target) => {
    const text = target.getAttribute("data-tip");
    if (!text) return;
    showTooltipNearTarget(target, text);
  };
  const hideTooltip = () => {
    hideFloatingTip();
  };
  document.querySelectorAll("[data-tip]").forEach(target => {
    target.onmouseenter = () => showTooltip(target);
    target.onmouseleave = hideTooltip;
  });
}
initTooltips();
normalizeSystemConfig();
void syncDataSourcePriorityToServer();
rebuildShortcutRegistry();
updateShortcutUI();
updateBspJudgeUI();

function resetSettings() {
  if (confirmAndLog("确定要恢复默认设置吗？")) {
    dataFormConfig = { ...DATA_FORM_DEFAULT };
    chartConfig = JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG));
    crosshairEnabled = !!(chartConfig.crosshair && chartConfig.crosshair.enabled);
    indicatorMainSlots = { ...defaultMainSlots };
    indicatorSubSlots = { ...defaultSubSlots };
    selectedMainIndicatorSlot = 0;
    selectedSubIndicatorSlot = 0;
    indicatorMainVarVisible = true;
    indicatorSubVarVisible = true;
    storageSet("chan_indicator_main_slots", JSON.stringify(indicatorMainSlots));
    storageSet("chan_indicator_sub_slots", JSON.stringify(indicatorSubSlots));
    storageSet("chan_selected_main_indicator_slot", "0");
    storageSet("chan_selected_sub_indicator_slot", "0");
    storageSet("chan_indicator_main_var_visible", "1");
    storageSet("chan_indicator_sub_var_visible", "1");
    const sharedReset = JSON.parse(
      JSON.stringify(chartConfigStore.shared || { theme: chartConfig.theme, crosshair: chartConfig.crosshair, showBottomBsp: true })
    );
    chartConfigStore = buildChartConfigStore({
      shared: sharedReset,
      perChart: { chart1: chartConfig, chart2: JSON.parse(JSON.stringify(chartConfig)) },
      multiPerK: chartConfigStore.multiPerK || {},
    });
    persistChartConfigStoreNow(true);
    renderSettingsForm();
  }
}

function resetSystemSettings() {
    if (confirmAndLog("确定要恢复默认系统配置吗（包括数据源、快捷键等）？")) {
        systemConfig = JSON.parse(JSON.stringify(DEFAULT_SYSTEM_CONFIG));
        saveSystemConfig();
        renderSystemSettingsForm();
        showAlertAndLog("系统配置已重置为默认值，包括数据源优先级。");
    }
}

$("btnChanSettingsOpen").addEventListener("click", openChanSettings);
markUiBound("btnChanSettingsOpen");
$("btnChanSettingsClose").addEventListener("click", closeChanSettings);
$("btnChanSettingsSave").addEventListener("click", saveChanSettings);
$("btnChanSettingsReset").addEventListener("click", resetChanSettings);
$("btnSettingsOpen").addEventListener("click", openSettings);
markUiBound("btnSettingsOpen");
$("btnSettingsClose").addEventListener("click", closeSettings);
$("btnSettingsSave").addEventListener("click", () => {
  void saveSettings().catch((e) => setMsg("保存图表设置失败：" + e.message));
});
$("btnSettingsReset").addEventListener("click", resetSettings);
$("btnSystemSettingsOpen").addEventListener("click", openSystemSettings);
$("btnSystemSettingsClose").addEventListener("click", closeSystemSettings);
$("btnSystemSettingsSave").addEventListener("click", saveSystemSettingsFromForm);
$("btnSystemSettingsReset").addEventListener("click", resetSystemSettings);
$("btnJudgeBsp").addEventListener("click", () => {
  if (!isBspJudgeManual()) return;
  checkBspJudge("manual_button");
});
markUiBound("btnJudgeBsp");

// Close on outside click
$("chanSettingsModal").addEventListener("click", (e) => {
  if (e.target === $("chanSettingsModal")) closeChanSettings();
});

$("settingsModal").addEventListener("click", (e) => {
  if (e.target === $("settingsModal")) closeSettings();
});

$("systemSettingsModal").addEventListener("click", (e) => {
  if (e.target === $("systemSettingsModal")) closeSystemSettings();
});

function cssVar(name, fallback) {
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return v || fallback;
}

function isMainIndicator(type) {
  return MAIN_INDICATORS.has(type);
}

function isSubIndicator(type) {
  return SUB_INDICATORS.has(type);
}

function getTradeLineDash(style) {
  if (style === "solid") return [];
  if (style === "dotted") return [2, 4];
  return [7, 5];
}

function getIndicatorConfig() {
  const mainTypes = [];
  const mainSlot = Number(selectedMainIndicatorSlot);
  if (indicatorMainSlots && Number.isFinite(mainSlot) && mainSlot >= 1 && mainSlot <= 5) {
    const list = indicatorMainSlots[String(mainSlot)] || [];
    for (const type of list) {
      if (type && type !== "none" && isMainIndicator(type)) {
        mainTypes.push({ slot: mainSlot, type });
      }
    }
  }
  
  const subCharts = [];
  const subSlot = Number(selectedSubIndicatorSlot);
  if (indicatorSubSlots && Number.isFinite(subSlot) && subSlot >= 1 && subSlot <= 5) {
    const list = indicatorSubSlots[String(subSlot)] || [];
    for (const type of list) {
      if (type && type !== "none" && isSubIndicator(type)) {
        subCharts.push({ slot: subSlot, type });
      }
    }
  }
  return {
    mainTypes,
    subCharts,
    mainVarVisible: !!indicatorMainVarVisible,
    subVarVisible: !!indicatorSubVarVisible,
  };
}

function getChipBucketStep() {
  const v = Number(chartConfig.chip.bucketStep);
  return Number.isFinite(v) && v > 0 ? v : 0.1;
}

let initLoadTimer = null;
let initStatusPollTimer = null;
let initTraceSeenCount = 0;
let initLoadStartMs = 0;
let initLoadServerPct = 0;
let initLoadExpectedMs = Number(storageGet("chan_init_expected_ms") || 40000);
const INIT_STAGE_PROGRESS_FRONT = {
  start: 1,
  data_kline: 8,
  data_chip: 18,
  chip_refresh: 22,
  chan_record: 32,
  perf_engine_load: 38,
  chan_bootstrap: 52,
  bsp_snapshot: 68,
  presentation_end: 72,
  initial_step: 72,
  build_payload: 92,
  chart_lazy_layers: 96,
};
const INIT_STAGE_PROGRESS_ORDER = [
  "start",
  "data_kline",
  "data_chip",
  "chip_refresh",
  "chan_record",
  "perf_engine_load",
  "chan_bootstrap",
  "bsp_snapshot",
  "presentation_end",
  "initial_step",
  "build_payload",
  "chart_lazy_layers",
];

function fmtLoadingRemain(sec) {
  const s = Math.max(0, Math.round(Number(sec) || 0));
  if (s >= 60) return `${(s / 60).toFixed(1)}分钟`;
  return `${s}秒`;
}

function loadingStageSoftPct(serverHint, fallbackPct) {
  if (!serverHint || !serverHint.stage) return fallbackPct;
  const stage = String(serverHint.stage || "");
  const base = Number(INIT_STAGE_PROGRESS_FRONT[stage]);
  if (!Number.isFinite(base)) return fallbackPct;
  const idx = INIT_STAGE_PROGRESS_ORDER.indexOf(stage);
  const nextStage = idx >= 0 ? INIT_STAGE_PROGRESS_ORDER[idx + 1] : "";
  const nextBase = Number(INIT_STAGE_PROGRESS_FRONT[nextStage]);
  if (!Number.isFinite(nextBase) || nextBase <= base + 1) return fallbackPct;
  const stageElapsed = Number(serverHint.stage_elapsed_sec);
  if (!Number.isFinite(stageElapsed) || stageElapsed <= 0) return fallbackPct;
  // 同一阶段久等时给用户一个“还活着”的软进度，真实节点进度仍以后端为准。
  const span = Math.max(1, nextBase - base - 1);
  const softStep = Math.min(span, Math.floor(stageElapsed / 8));
  return Math.max(fallbackPct, base + softStep);
}

function renderGlobalLoadingHistory() {
  const box = $("globalLoadingHistory");
  if (!box) return;
  const rows = (Array.isArray(msgHistory) ? msgHistory : []).slice(-80);
  if (!rows.length) {
    box.innerHTML = `<div><span class="time">[--]</span>正在加载会话...</div>`;
    box.scrollTop = box.scrollHeight;
    return;
  }
  box.innerHTML = rows.map((m) => {
    return `<div><span class="time">[${escapeHtml(String(m.time || "--"))}]</span>${escapeHtml(String(m.text || ""))}</div>`;
  }).join("");
  box.scrollTop = box.scrollHeight;
}

function updateGlobalLoadingProgress(done = false, serverHint = null) {
  const bar = $("globalLoadingBar");
  const eta = $("globalLoadingEta");
  const txt = $("globalLoadingText");
  if (!bar || !eta || !initLoadStartMs) return;
  if (done) {
    bar.style.width = "100%";
    bar.textContent = "100%";
    eta.textContent = "预计剩余：0秒";
    renderGlobalLoadingHistory();
    return;
  }
  const elapsed = Date.now() - initLoadStartMs;
  const expected = Math.max(5000, Number(initLoadExpectedMs) || 40000);
  let pct = Math.max(1, Math.min(92, Math.floor((elapsed / expected) * 100)));
  if (Number.isFinite(initLoadServerPct) && initLoadServerPct > 0) {
    pct = Math.max(pct, Math.min(99, Math.floor(initLoadServerPct)));
  }
  if (serverHint && Number.isFinite(Number(serverHint.progress_pct))) {
    pct = Math.max(pct, Math.min(99, Math.floor(Number(serverHint.progress_pct))));
    initLoadServerPct = pct;
  }
  pct = Math.min(99, Math.floor(loadingStageSoftPct(serverHint, pct)));
  let remainSec = Math.max(1, (expected - elapsed) / 1000);
  if (serverHint && Number.isFinite(Number(serverHint.eta_sec))) {
    remainSec = Math.max(1, Number(serverHint.eta_sec));
  } else if (pct > 3 && pct < 99) {
    remainSec = Math.max(1, (elapsed / pct) * (100 - pct) / 1000);
  }
  bar.style.width = `${pct}%`;
  bar.textContent = `${pct}%`;
  const elapsedText = `已用：${fmtLoadingRemain(elapsed / 1000)}`;
  const stageElapsed = serverHint && Number.isFinite(Number(serverHint.stage_elapsed_sec))
    ? ` 当前阶段：${fmtLoadingRemain(Number(serverHint.stage_elapsed_sec))}`
    : "";
  eta.textContent = `预计剩余：${fmtLoadingRemain(remainSec)} ｜ ${elapsedText}${stageElapsed}`;
  if (txt && serverHint && serverHint.stage_label) {
    txt.textContent = `正在加载会话：${serverHint.stage_label}`;
  }
  renderGlobalLoadingHistory();
}

function prepareCancelableLoading(text, historyText = "") {
  if (initAbortController) {
    try { initAbortController.abort(); } catch (_) {}
  }
  initAbortController = new AbortController();
  initLoadStartMs = Date.now();
  initLoadServerPct = 0;
  if (historyText) appendMsgHistory(historyText);
  setGlobalLoading(true, text);
  startInitStatusPoll();
  return initAbortController;
}

function finishCancelableLoading(done = false) {
  stopInitStatusPoll();
  if (done) updateGlobalLoadingProgress(true);
  initAbortController = null;
  hideGlobalLoading();
}

async function pollInitStatusOnce() {
  if (!initAbortController) return;
  try {
    const st = await api("/api/init_status", null, "GET");
    const traces = Array.isArray(st.traces) ? st.traces : [];
    if (traces.length > initTraceSeenCount) {
      traces.slice(initTraceSeenCount).forEach((line) => appendMsgHistory(String(line)));
      initTraceSeenCount = traces.length;
    }
    updateGlobalLoadingProgress(false, st);
  } catch (_) {
    /* 轮询失败忽略 */
  }
}

function startInitStatusPoll() {
  stopInitStatusPoll();
  initTraceSeenCount = 0;
  initLoadServerPct = 0;
  void pollInitStatusOnce();
  initStatusPollTimer = setInterval(() => { void pollInitStatusOnce(); }, 600);
}

function stopInitStatusPoll() {
  if (initStatusPollTimer) {
    clearInterval(initStatusPollTimer);
    initStatusPollTimer = null;
  }
}

function setGlobalLoading(visible, text) {
  const overlay = $("globalLoading");
  if (!overlay) return;
  const txt = $("globalLoadingText");
  if (txt && text) txt.textContent = text;
  overlay.classList.toggle("show", !!visible);
  if (visible) {
    if (!initLoadStartMs) initLoadStartMs = Date.now();
    if (!initLoadTimer) initLoadTimer = setInterval(() => updateGlobalLoadingProgress(false), 1000);
    updateGlobalLoadingProgress(false);
    renderGlobalLoadingHistory();
  } else {
    if (initLoadTimer) {
      clearInterval(initLoadTimer);
      initLoadTimer = null;
    }
    stopInitStatusPoll();
    initLoadServerPct = 0;
  }
  if (!visible) {
    initLoadStartMs = 0;
  }
  const actions = $("globalLoadingActions");
  if (actions) {
    const canCancel = !!visible && !!initAbortController;
    actions.classList.toggle("show", !!visible);
    actions.style.display = visible ? "block" : "none";
  }
  const cancelBtn = $("btnCancelInitLoad");
  if (cancelBtn) {
    const canCancel = !!(visible && initAbortController);
    cancelBtn.disabled = !canCancel;
    cancelBtn.style.pointerEvents = canCancel ? "auto" : "none";
  }
}

function hideGlobalLoading() {
  setGlobalLoading(false);
}

function syncStepButtonState() {
  const disabled = !lastPayload || !lastPayload.ready || sessionFinished || stepInFlight;
  $("btnStep").disabled = disabled;
  $("btnStepN").disabled = disabled;
  $("btnBackN").disabled = !lastPayload || !lastPayload.ready || stepInFlight;
  if ($("btnStepInterrupt")) $("btnStepInterrupt").disabled = !stepInFlight;
  const si = lastPayload && Number.isFinite(Number(lastPayload.step_idx)) ? Number(lastPayload.step_idx) : -1;
  if ($("btnStepPrev")) $("btnStepPrev").disabled = disabled || si <= 0;
  // 查看数据：与会话绑定，训练结束后仍可查看；步进进行中不禁止（只读）
  if ($("btnViewKlineData")) $("btnViewKlineData").disabled = !lastPayload || !lastPayload.ready;
  if ($("btnUnifiedGotoStep")) $("btnUnifiedGotoStep").disabled = disabled;
}

function getStepNValue() {
  const el = $("stepN");
  const v = Number(el ? el.value : 1);
  const n = Number.isFinite(v) ? Math.floor(v) : 1;
  const safeN = Math.max(1, n);
  if (el && String(safeN) !== String(el.value)) el.value = String(safeN);
  return safeN;
}

function syncTradesFromPayload(payload) {
  if (!payload || !payload.trades) return;
  const longHist = Array.isArray(payload.trades.history) ? payload.trades.history : [];
  const shortHist = Array.isArray(payload.trades.short_history) ? payload.trades.short_history : [];
  tradeHistory = longHist.concat(shortHist);
  activeTrade = payload.trades.active || null;
}

function showBspPrompt(payload, lines, key, hits) {
  const t = payload && payload.time ? payload.time : "-";
  const text = `检测到当前K线出现买卖点\n时间：${t}\n${lines || ""}`.trim();
  showToast(text, { record: false });
  setMsg(text, true);
}

function clearBspPrompt() {
  pendingBspPrompt = null;
  const box = $("bspPrompt");
  if (box) box.classList.remove("show");
  syncStepButtonState();
}

function formatDateWithWeekday(raw) {
  const text = String(raw || "").trim();
  if (!text) return "-";
  const datePart = text.slice(0, 10);
  const d = new Date(`${datePart}T00:00:00`);
  if (!Number.isNaN(d.getTime())) return `${text} ${WEEKDAY_NAMES[d.getDay()]}`;
  return text;
}

function formatPriceText(v, digits = 3) {
  const n = Number(v);
  if (!Number.isFinite(n)) return "-";
  const clean = Math.abs(n) < 1e-9 ? 0 : n;
  return clean.toFixed(digits);
}

function getBspAtX(chart, xVal) {
  const tags = [];
  const seen = new Set();
  for (const p of (bspHistory || [])) {
    if (!p || p.x !== xVal) continue;
    const prefix = p.status === "correct" ? "✓" : (p.status === "wrong" ? "×" : "…");
    const txt = `${prefix} ${getBspDisplayLabel(p)}`;
    if (seen.has(txt)) continue;
    seen.add(txt);
    tags.push(txt);
  }
  for (const hit of (chart && chart.rhythm_hits) || []) {
    if (!hit || hit.x !== xVal) continue;
    const txt = String(hit.display_label || "1382");
    if (seen.has(txt)) continue;
    seen.add(txt);
    tags.push(txt);
  }
  return tags;
}

function getChipStretchExponent() {
  const level = Number(chartConfig.chip.stretchLevel || 5);
  // level 1 -> 1.0(线性), level 10 -> 0.2(最强), keep extending smoothly.
  const exp = 1.0 - 0.08 * (level - 1);
  return Math.max(0.08, Math.min(1.0, exp));
}

function syncIndicatorControls() {
  // Main indicator panel controls were moved to the settings modal.
  // This function now primarily ensures indicators are refreshed if needed.
}

function applyThemeFromSelect() {
  const t = chartConfig.theme || "light";
  document.documentElement.setAttribute("data-theme", t);
  if (lastPayload && lastPayload.ready && lastPayload.chart) drawFromLastPayload();
}

// Indicator controls moved to modal.

const IDS_SESSION_PARAMS = ["code", "begin", "end", "cash", "autype", "kType", "stepN"];
IDS_SESSION_PARAMS.forEach(id => {
  const el = $(id);
  if (!el) return;
  el.addEventListener("change", () => {
    saveSessionConfig();
  });
});

syncIndicatorControls();

function zoomViewAt(factor, anchorCanvasX) {
  if (!lastPayload || !lastPayload.ready || !viewReady) return;
  if (!lastPayload.chart || !lastPayload.chart.kline || lastPayload.chart.kline.length === 0) return;
  const span = viewXMax - viewXMin;
  if (span <= 1) return;
  let newSpan = span / factor;
  newSpan = Math.max(5, newSpan);
  const w = Math.max(1, scalerCssDimensions(undefined).w);
  const usableW = Math.max(1, w - PAD_L - PAD_R);
  const rel = Math.min(1, Math.max(0, (anchorCanvasX - PAD_L) / usableW));
  const xAtMouse = viewXMin + rel * span;
  let newXMin = xAtMouse - rel * newSpan;
  let newXMax = newXMin + newSpan;
  if (newXMin < allXMin) {
    newXMin = allXMin;
    newXMax = newXMin + newSpan;
  }
  const rightMax = allXMax + Math.round(newSpan * 2);
  if (newXMax > rightMax) {
    newXMax = rightMax;
    newXMin = newXMax - newSpan;
  }
  viewXMin = Math.round(newXMin);
  viewXMax = Math.round(newXMax);
  if (viewXMin < allXMin) viewXMin = allXMin;
  if (viewXMin >= viewXMax) {
    viewXMin = allXMin;
    viewXMax = allXMax;
  }
  userAdjustedView = true;
  drawFromLastPayload();
}

function ensureLatestKVisible() {
  if (!lastPayload || !lastPayload.chart || !lastPayload.chart.kline.length) return;
  const lastX = lastPayload.chart.kline[lastPayload.chart.kline.length - 1].x;
  if (lastX >= viewXMin && lastX <= viewXMax) return;
  const span = viewXMax - viewXMin;
  // 数量聚合后 bar 很少时 span 常为 1，旧逻辑直接 return 会导致步进后最新 K 在视窗外
  if (span <= 1) {
    viewXMin = allXMin;
    viewXMax = allXMax;
    return;
  }
  const pos = 0.85;
  let newMin = lastX - span * pos;
  let newMax = newMin + span;
  if (newMin < allXMin) {
    newMin = allXMin;
    newMax = newMin + span;
  }
  const rightMax = allXMax + Math.round(span * 2);
  if (newMax > rightMax) {
    newMax = rightMax;
    newMin = newMax - span;
  }
  viewXMin = Math.round(newMin);
  viewXMax = Math.round(newMax);
}

function centerLatestK() {
  if (!lastPayload || !lastPayload.chart || !lastPayload.chart.kline.length || !viewReady) return;
  const lastX = lastPayload.chart.kline[lastPayload.chart.kline.length - 1].x;
  const span = viewXMax - viewXMin;
  if (span <= 1) return;
  let newMin = lastX - span * 0.5;
  let newMax = newMin + span;
  if (newMin < allXMin) {
    newMin = allXMin;
    newMax = newMin + span;
  }
  viewXMin = Math.round(newMin);
  viewXMax = Math.round(newMax);
  userAdjustedView = true;
  drawFromLastPayload();
}

function setText(id, value) {
  const el = $(id);
  if (!el) return;
  el.textContent = value;
}

function resizeCanvas() {
  const rect = canvas.getBoundingClientRect();
  canvas.width = rect.width * devicePixelRatio;
  canvas.height = rect.height * devicePixelRatio;
  ctx.setTransform(devicePixelRatio, 0, 0, devicePixelRatio, 0, 0);
  if (lastPayload && lastPayload.ready) drawFromLastPayload();
}
window.addEventListener("resize", () => {
  resizeCanvas();
  const overlay = $("tradeStatusOverlay");
  if (overlay) applyTradeOverlayPosition(parseFloat(overlay.style.left) || 16, parseFloat(overlay.style.top) || 16);
});
setTimeout(resizeCanvas, 0);

function isDualRuntimeReady() {
  return !!(lastPayload && lastPayload.ready && lastPayload.chart_mode === "dual" && lastPayload.charts && lastPayload.charts.chart1 && lastPayload.charts.chart2);
}

/** 底部留白：双周期子图矮，收紧以抬高 K 线主区，仍留时间轴与买卖点标签连线 */
function getLayoutPadB() {
  return isDualRuntimeReady() ? 46 : PAD_B_SINGLE;
}

function normalizePointerEventToActivePane(e, requireInside = true) {
  if (!isDualRuntimeReady()) return e;
  const panes = getDualPaneRects();
  const pane = panes[dualActiveChartId || "chart1"];
  if (!pane) return e;
  const rect = canvas.getBoundingClientRect();
  const rawX = e.clientX - rect.left;
  const rawY = e.clientY - rect.top;
  const inside = rawX >= pane.x && rawX <= pane.x + pane.w && rawY >= pane.y && rawY <= pane.y + pane.h;
  if (requireInside && !inside) return null;
  const mapped = {
    button: e.button,
    buttons: e.buttons,
    ctrlKey: !!e.ctrlKey,
    shiftKey: !!e.shiftKey,
    altKey: !!e.altKey,
    metaKey: !!e.metaKey,
    deltaY: Number(e.deltaY || 0),
    clientX: rect.left + (rawX - pane.x),
    clientY: rect.top + (rawY - pane.y),
    code: e.code,
    key: e.key,
  };
  return mapped;
}

function redrawCurrentPayload() {
  if (!lastPayload || !lastPayload.ready) return;
  if (isDualRuntimeReady()) {
    drawDualCharts(lastPayload);
  } else {
    drawFromLastPayload();
  }
}

/** 合并到下一帧再整图重绘，减轻十字移动时同帧多次 draw 的卡顿 */
let chartRedrawScheduled = false;
function scheduleChartRedraw() {
  if (chartRedrawScheduled) return;
  chartRedrawScheduled = true;
  requestAnimationFrame(() => {
    chartRedrawScheduled = false;
    redrawCurrentPayload();
  });
}

/** 会话载荷里由服务端给出的「还可向前步进」根数上限（加载后随步进变化） */
function getStepForwardMaxFromPayload(payload) {
  const n = Number(payload && payload.step_forward_max);
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : null;
}

/** 仅「逐步喂数据」且仍可向前步进时视为正在步进：筹码跟当前步末端 K，十字不裁剪筹码；统一喂数据只用切片游标浏览，十字仍可锚定筹码 */
function isChipReplayStepping(payload) {
  if (!payload || !payload.ready) return false;
  const feed = normalizeDataFeedMode(payload.data_form ? payload.data_form.feed_mode : "step");
  if (feed !== "step") return false;
  const si = Number(payload.step_idx);
  if (!Number.isFinite(si) || si < 0) return false;
  const maxF = getStepForwardMaxFromPayload(payload);
  return maxF !== null && maxF > 0;
}

function updateStepForwardMaxUi(payload) {
  const hint = $("stepNMaxHint");
  if (!hint) return;
  const maxV = getStepForwardMaxFromPayload(payload);
  if (!payload || !payload.ready || maxV === null) {
    hint.textContent = "";
    return;
  }
  hint.textContent =
    maxV > 0
      ? `还可向前步进至多 ${maxV} 根（N 勿超过此值可避免无效请求）。`
      : "已在最后一根 K 线，向前步进为 0（仍可按 N 回退）。";
}

/** 统一喂数据：显示 step 跳转行并同步输入范围（与 payload.step_idx / step_forward_max 一致） */
function updateUnifiedGotoRow(payload) {
  const row = $("unifiedGotoRow");
  const inp = $("inputUnifiedGotoStep");
  const tip = $("tipUnifiedGotoStep");
  if (!row || !inp) return;
  const isUnified = normalizeDataFeedMode(payload && payload.data_form ? payload.data_form.feed_mode : "step") === "unified";
  row.style.display = isUnified ? "flex" : "none";
  if (tip) {
    tip.setAttribute(
      "data-tip",
      "统一喂数据专用：跳转作用于当前激活图窗（与图1/图2激活一致），仅切片不重算；step 与界面 step_idx 一致（0 为第一根）。双周期时被动图按锚点时间对齐。"
    );
  }
  if (!isUnified || !payload || !payload.ready) return;
  const si = Number.isFinite(Number(payload.step_idx)) ? Math.floor(Number(payload.step_idx)) : 0;
  const maxF = getStepForwardMaxFromPayload(payload);
  const maxIdx = maxF !== null ? si + maxF : si;
  inp.min = "0";
  inp.max = String(Math.max(0, maxIdx));
  inp.value = String(Math.max(0, si));
}

canvas.addEventListener(
  "wheel",
  (e) => {
    if (isDualRuntimeReady() && !dualActivePaneLock) {
      const hitId = resolveDualChartIdFromClient(e.clientX, e.clientY);
      if (hitId && hitId !== dualActiveChartId) setActiveChart(hitId, true);
    }
    const pe = normalizePointerEventToActivePane(e, true);
    if (!pe) return;
    e.preventDefault();
    const rect = canvas.getBoundingClientRect();
    const mouseX = pe.clientX - rect.left;
    const factor = pe.deltaY > 0 ? 1 / 1.15 : 1.15;
    if (pe.ctrlKey) {
      if (pe.deltaY > 0) {
        viewYZoomRatio /= 1.15;
      } else {
        viewYZoomRatio *= 1.15;
      }
      if (isDualRuntimeReady()) saveRuntimeState(dualActiveChartId);
      scheduleChartRedraw();
      return;
    }
    zoomViewAt(factor, mouseX);
    if (isDualRuntimeReady()) saveRuntimeState(dualActiveChartId);
  },
  { passive: false }
);

canvas.addEventListener("mousedown", (e) => {
  if (e.button === 2) {
    if (isDualRuntimeReady()) {
      e.preventDefault();
      dualActivePaneLock = !dualActivePaneLock;
      if (dualActivePaneLock) dualLockedChartId = dualActiveChartId;
      setMsg(dualActivePaneLock ? "已锁定当前激活图窗，再次右键解锁。" : "已解锁图窗切换。");
      scheduleChartRedraw();
    }
    return;
  }
  if (e.button !== 0) return;
  if (isDualRuntimeReady() && !dualActivePaneLock) {
    const hitId = resolveDualChartIdFromClient(e.clientX, e.clientY);
    if (hitId && hitId !== dualActiveChartId) setActiveChart(hitId, true);
  }
  const pe = normalizePointerEventToActivePane(e, true);
  if (!pe) return;
  chartClickMoved = false;
  chartMouseDownPos = { x: pe.clientX, y: pe.clientY };
  if (!lastPayload || !lastPayload.ready || !viewReady) return;
  if (e.button === 0) {
    const rect = canvas.getBoundingClientRect();
    const s = scalerForActivePayloadChart(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
    const px = pe.clientX - rect.left;
    const py = pe.clientY - rect.top;
    const pickedRatio = pickRatioLineAt(s, px, py, 10);
    if (pickedRatio) {
      draggingRatioLine = {
        index: pickedRatio.index,
        ratio: Number(userBiRays[pickedRatio.index] && userBiRays[pickedRatio.index].ratio),
      };
      hoveredBiRay = pickedRatio;
      selectedDrawing = pickedRatio;
      isPanning = false;
      redrawCurrentPayload();
      return;
    }
  }
  isPanning = true;
  panStartX = pe.clientX;
  panStartY = pe.clientY;
  panStartViewMin = viewXMin;
  panStartViewMax = viewXMax;
  panStartYShiftRatio = viewYShiftRatio;
});
window.addEventListener("mouseup", () => {
  if (draggingRatioLine) {
    const idx = Number(draggingRatioLine.index);
    const line = userBiRays[idx];
    if (line) {
      const ratioVal = getRatioLineDynamicRatio(line);
      const ratioText = Number.isFinite(ratioVal) ? ratioVal.toFixed(3) : "-";
      const priceText = Number.isFinite(Number(line.y1)) ? Number(line.y1).toFixed(2) : "-";
      setMsg(`比例线已放置：比例 ${ratioText}，价格 ${priceText}`);
    }
    draggingRatioLine = null;
  }
  isPanning = false;
  chartMouseDownPos = null;
});
window.addEventListener("mousemove", (e) => {
  if (draggingRatioLine && lastPayload && lastPayload.ready) {
    const pe = normalizePointerEventToActivePane(e, true);
    if (!pe) return;
    const rect = canvas.getBoundingClientRect();
    const s = scalerForActivePayloadChart(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
    const px = pe.clientX - rect.left;
    const py = pe.clientY - rect.top;
    const idx = Number(draggingRatioLine.index);
    const line = userBiRays[idx];
    if (!line) {
      draggingRatioLine = null;
      return;
    }
    const yVal = getDragRatioLinePrice(lastPayload.chart, s, px, py, !!pe.ctrlKey);
    if (!Number.isFinite(yVal)) return;
    line.y1 = yVal;
    line.y2 = yVal;
    if (line.kind === "ratioLine") {
      // 拖拽后比例按“当前价相对初始端点区间”实时重算
      line.ratio = getRatioLineDynamicRatio(line);
    }
    userBiRaysDirty = true;
    hoveredBiRay = { type: "biRay", index: idx };
    selectedDrawing = { type: "biRay", index: idx };
    scheduleChartRedraw();
    return;
  }
  if (!isPanning) return;
  const pe = normalizePointerEventToActivePane(e, true);
  if (!pe) return;
  if (chartMouseDownPos) {
    const moved = Math.abs(pe.clientX - chartMouseDownPos.x) + Math.abs(pe.clientY - chartMouseDownPos.y);
    if (moved >= 6) chartClickMoved = true;
  }
  const rect = canvas.getBoundingClientRect();
  if (pe.clientY < rect.top || pe.clientY > rect.bottom) return;
  const dx = pe.clientX - panStartX;
  const dy = pe.clientY - panStartY;
  const span = panStartViewMax - panStartViewMin;
  const usableW = Math.max(1, scalerCssDimensions(undefined).w - PAD_L - PAD_R);
  const dxBars = Math.round((-dx / usableW) * span);
  let newMin = panStartViewMin + dxBars;
  let newMax = panStartViewMax + dxBars;
  if (newMin < allXMin) {
    newMin = allXMin;
    newMax = newMin + span;
  }
  viewXMin = newMin;
  viewXMax = newMax;
  const s = scalerForActivePayloadChart(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
  const plotH = Math.max(1, s.plotH);
  viewYShiftRatio = panStartYShiftRatio + (dy / plotH);
  viewYShiftRatio = Math.max(-3, Math.min(3, viewYShiftRatio));
  userAdjustedView = true;
  if (isDualRuntimeReady()) saveRuntimeState(dualActiveChartId);
  scheduleChartRedraw();
});

canvas.addEventListener("mousemove", (e) => {
  if (isDualRuntimeReady() && !dualActivePaneLock) {
    const hitId = resolveDualChartIdFromClient(e.clientX, e.clientY);
    if (hitId && hitId !== dualActiveChartId) setActiveChart(hitId, true);
  }
  const pe = normalizePointerEventToActivePane(e, true);
  if (!pe) return;
  canvasHovered = true;
  if (isPanning) {
    hideFloatingTip();
    return;
  }
  if (!lastPayload || !lastPayload.ready) {
    hideFloatingTip();
    return;
  }
  const rect = canvas.getBoundingClientRect();
  const s = scalerForActivePayloadChart(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
  const visibleKs = getVisibleKs(lastPayload.chart, s.xMin, s.xMax);
  const rawX = pe.clientX - rect.left;
  const rawY = pe.clientY - rect.top;
  hoveredBiRay = pickParallelogramAt(s, rawX, rawY, 9) || pickRatioLineAt(s, rawX, rawY, 9);
  const hoveredLegend = !!(legendHoverBox && rawX >= legendHoverBox.x1 && rawX <= legendHoverBox.x2 && rawY >= legendHoverBox.y1 && rawY <= legendHoverBox.y2);
  legendHoverActive = hoveredLegend;
  const clampedX = Math.max(PAD_L, Math.min(s.w - PAD_R, rawX));
  
  const targetX = s.xMin + ((clampedX - PAD_L) / Math.max(1, s.plotW)) * (s.xMax - s.xMin);
  const refK = nearestKByX(visibleKs, targetX);
  // Lock X if Ctrl is held（数量模式除外：仍吸附到 K 线列）
  if (!pe.ctrlKey || isSingleQuantityRayMode()) {
    crosshairX = refK ? s.x(refK.x) : clampedX;
  }
  let nextY = Math.max(PAD_T, Math.min(s.contentBottom, rawY));
  // 数量模式 + Ctrl：吸附开高低收四价
  if (isSingleQuantityRayMode() && pe.ctrlKey && refK) {
    const snapped = snapPriceToKlineOhlc(refK, s.yFromPx(rawY));
    nextY = s.y(snapped.y);
  }
  crosshairY = nextY;
   const hoveredSignal = (signalHoverBoxes || []).find((box) => rawX >= box.x1 && rawX <= box.x2 && rawY >= box.y1 && rawY <= box.y2);
   if (hoveredSignal && hoveredSignal.text) {
     showFloatingTip(hoveredSignal.text, pe.clientX, pe.clientY);
   } else {
     hideFloatingTip();
   }
  if (draggingRatioLine || hoveredBiRay) {
    canvas.style.cursor = "ns-resize";
  } else {
    canvas.style.cursor = crosshairEnabled ? "crosshair" : "default";
  }
   if (isDualRuntimeReady()) saveRuntimeState(dualActiveChartId);
   scheduleChartRedraw();
});

canvas.addEventListener("mouseleave", () => {
  canvasHovered = false;
  legendHoverActive = false;
  hoveredBiRay = null;
  crosshairX = null;
  crosshairY = null;
  if (isDualRuntimeReady()) saveRuntimeState(dualActiveChartId);
  hideFloatingTip();
  if (lastPayload && lastPayload.ready) scheduleChartRedraw();
});

canvas.addEventListener("dblclick", (e) => {
  if (isDualRuntimeReady() && !dualActivePaneLock) {
    const hitId = resolveDualChartIdFromClient(e.clientX, e.clientY);
    if (hitId && hitId !== dualActiveChartId) setActiveChart(hitId, true);
  }
  const pe = normalizePointerEventToActivePane(e, true);
  if (!pe) return;
  if (crosshairX !== null && crosshairY !== null) {
    const s = scalerForActivePayloadChart(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
    const rect = canvas.getBoundingClientRect();
    const xp = (pe && typeof pe.clientX === "number") ? (pe.clientX - rect.left) : crosshairX;
    const yp = (pe && typeof pe.clientY === "number") ? (pe.clientY - rect.top) : crosshairY;
    const xVal = xFromPx(s, xp);

    // Check if we are deleting a ray
    let removed = false;
    userRays = userRays.filter(ray => {
      const rayYp = s.y(ray.y);
      if (Math.abs(rayYp - yp) < 8) {
        removed = true;
        return false;
      }
      return true;
    });
    
    if (removed) {
      storageSet("chan_user_rays", JSON.stringify(userRays));
      redrawCurrentPayload();
      return;
    }

    // Check if we are deleting a Bi ray（含比例线/平行四边形）
    let removedBi = false;
    let removedRatioGroupId = null;
    let removedIdx = -1;
    const pickedPara = pickParallelogramAt(s, xp, yp, 8);
    if (pickedPara) {
      removedIdx = pickedPara.index;
      removedBi = true;
      const r = userBiRays[removedIdx];
      if (r && r.kind === "ratioLine" && r.groupId) removedRatioGroupId = String(r.groupId);
    } else {
      for (let i = userBiRays.length - 1; i >= 0; i -= 1) {
        const r = userBiRays[i];
        if (!r || r.kind === "parallelogram") continue;
        const x1 = Number(r.x1), y1 = Number(r.y1), x2 = Number(r.x2), y2 = Number(r.y2);
        const dx = (x2 - x1);
        if (!Number.isFinite(x1) || !Number.isFinite(y1) || !Number.isFinite(dx) || dx === 0) continue;
        if (xVal < x1) continue;
        const slope = (y2 - y1) / dx;
        const yOn = y1 + slope * (xVal - x1);
        const yPx = s.y(yOn);
        if (Math.abs(yPx - yp) < 8) {
          removedIdx = i;
          removedBi = true;
          if (r.kind === "ratioLine" && r.groupId) removedRatioGroupId = String(r.groupId);
          break;
        }
      }
    }
    if (removedBi) {
      if (removedRatioGroupId) {
        userBiRays = userBiRays.filter((r) => !(r && r.kind === "ratioLine" && String(r.groupId || "") === removedRatioGroupId));
      } else if (removedIdx >= 0) {
        userBiRays.splice(removedIdx, 1);
      }
    }
    if (removedBi) {
      userBiRaysDirty = true;
      if (selectedDrawing && selectedDrawing.type === "biRay") selectedDrawing = null;
      redrawCurrentPayload();
      return;
    }

    // 数量模式射线删除
    if (isSingleQuantityRayMode() && lastPayload && lastPayload.chart) {
      const code = getActiveSessionCode();
      let removedQty = false;
      const list = quantityRaysForActiveSession();
      for (let i = list.length - 1; i >= 0; i -= 1) {
        const r = list[i];
        if (hitTestQuantityRayPx(lastPayload.chart, s, r, xp, yp, 8)) {
          const gi = userQuantityRays.indexOf(r);
          if (gi >= 0) userQuantityRays.splice(gi, 1);
          removedQty = true;
          break;
        }
      }
      if (removedQty) {
        userQuantityRaysDirty = true;
        redrawCurrentPayload();
        return;
      }
    }
  }

  crosshairEnabled = !crosshairEnabled;
  persistCrosshairEnabledToStore();
  canvas.style.cursor = crosshairEnabled ? "crosshair" : "default";
  // 刚开启十字时尚无像素坐标（未触发 mousemove 等）时用双击点对齐最近 K，否则 drawCrosshair 直接 return
  if (crosshairEnabled && lastPayload && lastPayload.ready && pe && (crosshairX === null || crosshairY === null)) {
    const chartRef = isDualRuntimeReady() && lastPayload.charts && lastPayload.charts[dualActiveChartId]
      ? lastPayload.charts[dualActiveChartId]
      : lastPayload.chart;
    if (chartRef && chartRef.kline && chartRef.kline.length > 0) {
      if (isDualRuntimeReady()) loadRuntimeState(dualActiveChartId);
      const rect = canvas.getBoundingClientRect();
      const rawX = pe.clientX - rect.left;
      const rawY = pe.clientY - rect.top;
      const s0 = toScaler(chartRef, Math.max(allXMin, viewXMin), viewXMax, isDualRuntimeReady() ? dualActiveChartId : undefined);
      const clampedX = Math.max(PAD_L, Math.min(s0.w - PAD_R, rawX));
      const visibleKs = getVisibleKs(chartRef, s0.xMin, s0.xMax);
      const targetX = s0.xMin + ((clampedX - PAD_L) / Math.max(1, s0.plotW)) * (s0.xMax - s0.xMin);
      const refK0 = nearestKByX(visibleKs, targetX);
      crosshairX = refK0 ? s0.x(refK0.x) : clampedX;
      crosshairY = Math.max(PAD_T, Math.min(s0.contentBottom, rawY));
      if (isDualRuntimeReady()) saveRuntimeState(dualActiveChartId);
    }
  }
  if (lastPayload && lastPayload.ready) {
    if (isDualRuntimeReady()) saveRuntimeState(dualActiveChartId);
    redrawCurrentPayload();
  }
});

 // Fullscreen logic
const btnFullscreen = $("btnFullscreen");
btnFullscreen.onclick = () => {
  const rightPanel = document.querySelector(".right");
  if (!document.fullscreenElement) {
    rightPanel.requestFullscreen().catch(err => {
      setMsg(`全屏失败: ${err.message}`);
    });
  } else {
    document.exitFullscreen();
  }
};
markUiBound("btnFullscreen");

document.addEventListener("fullscreenchange", () => {
  resizeCanvas();
  const overlay = $("tradeStatusOverlay");
  if (overlay) applyTradeOverlayPosition(parseFloat(overlay.style.left) || 16, parseFloat(overlay.style.top) || 16);
});

function updateToolboxUI() {
  const ids = ["toolNone", "toolHorizontalRay", "toolBiRay", "toolRatioLine", "toolParallelogram", "toolLineProps"];
  ids.forEach((id) => {
    const el = $(id);
    if (!el) return;
    el.classList.remove("active");
    el.classList.remove("focus-highlight");
  });
  if (activeTool === "horizontalRay" && $("toolHorizontalRay")) $("toolHorizontalRay").classList.add("active");
  else if (activeTool === "biRay" && $("toolBiRay")) $("toolBiRay").classList.add("active");
  else if (activeTool === "ratioLine" && $("toolRatioLine")) $("toolRatioLine").classList.add("active");
  else if (activeTool === "parallelogram" && $("toolParallelogram")) $("toolParallelogram").classList.add("active");
  else if ($("toolNone")) $("toolNone").classList.add("active");
  if (activeTool === "none" && $("toolNone")) $("toolNone").classList.add("focus-highlight");
  if (activeTool === "horizontalRay" && $("toolHorizontalRay")) $("toolHorizontalRay").classList.add("focus-highlight");
  if (activeTool === "biRay" && $("toolBiRay")) $("toolBiRay").classList.add("focus-highlight");
  if (activeTool === "ratioLine" && $("toolRatioLine")) $("toolRatioLine").classList.add("focus-highlight");
  if (activeTool === "parallelogram" && $("toolParallelogram")) $("toolParallelogram").classList.add("focus-highlight");
  if ($("toolLineProps") && Date.now() < linePropsHighlightUntil) $("toolLineProps").classList.add("focus-highlight");
}

function setActiveTool(next) {
  const v = next === "horizontalRay" || next === "biRay" || next === "ratioLine" || next === "parallelogram" ? next : "none";
  activeTool = v;
  storageSet("chan_active_tool", v);
  if (v !== "biRay") pendingBiRayPts = [];
  if (v !== "ratioLine") pendingRatioLinePts = [];
  if (v !== "parallelogram") pendingParallelogramPts = [];
  if (v !== "none") selectedDrawing = null;
  updateToolboxUI();
  if (lastPayload && lastPayload.ready) drawFromLastPayload();
}

if ($("toolNone")) {
  $("toolNone").addEventListener("click", () => setActiveTool("none"));
  markUiBound("toolNone");
}
if ($("toolHorizontalRay")) {
  $("toolHorizontalRay").addEventListener("click", () => setActiveTool(activeTool === "horizontalRay" ? "none" : "horizontalRay"));
  markUiBound("toolHorizontalRay");
}
if ($("toolBiRay")) {
  $("toolBiRay").addEventListener("click", () => setActiveTool(activeTool === "biRay" ? "none" : "biRay"));
  markUiBound("toolBiRay");
}
if ($("toolRatioLine")) {
  $("toolRatioLine").addEventListener("click", () => {
    if (activeTool !== "ratioLine") {
      showAlertAndLog(
        [
          "比例线操作说明：",
          `1) 点击两个笔端点，自动生成 ${normalizeRatioLineRatios(DEFAULT_RATIO_LINE_RATIOS).map((x) => x.toFixed(3)).join(" / ")} 多条比例线。`,
          "2) 鼠标移到比例线会高亮；按住左键可上下拖动调整位置。",
          "3) 拖动时按住 Ctrl，可自动吸附到当前K线最高价或最低价。",
          "4) 松开鼠标后即完成放置，并显示该比例线比例值与价格。",
          "5) 所有比例线都会在右侧显示“比例 + 价格”。",
          "6) 双击比例线可删除（会删除整组比例线）；在“选择”模式下可用“画线属性”改样式。"
        ].join("\n")
      );
    }
    setActiveTool(activeTool === "ratioLine" ? "none" : "ratioLine");
  });
  markUiBound("toolRatioLine");
}
if ($("toolParallelogram")) {
  $("toolParallelogram").addEventListener("click", () => setActiveTool(activeTool === "parallelogram" ? "none" : "parallelogram"));
  markUiBound("toolParallelogram");
}
updateToolboxUI();

function getRayLineStyle(ray) {
  return String(ray && ray.lineStyle ? ray.lineStyle : "dashed");
}

function getRayLineWidth(ray) {
  const v = Number(ray && ray.lineWidth);
  return Number.isFinite(v) && v > 0 ? v : chartConfig.userRay.width;
}

function getRayLineColor(ray) {
  return getCfgColor(ray && ray.lineColor ? ray.lineColor : chartConfig.userRay.color);
}

function applyLinePropsToDrawing(target, props) {
  if (!target) return false;
  const list = target.type === "biRay" ? userBiRays : userRays;
  if (!Array.isArray(list) || !Number.isInteger(target.index) || target.index < 0 || target.index >= list.length) return false;
  const item = list[target.index];
  item.lineColor = props.lineColor;
  item.lineWidth = props.lineWidth;
  item.lineStyle = props.lineStyle;
  if (target.type === "biRay") {
    userBiRaysDirty = true;
  } else {
    storageSet("chan_user_rays", JSON.stringify(userRays));
  }
  return true;
}

/** 平行四边形：由任意三点 p1,p2,p3 确定（边方向 p2-p1，邻边 p1-p3） */
function buildParallelogramVerts(p1, p2, p3) {
  const dx = Number(p2.x) - Number(p1.x);
  const dy = Number(p2.y) - Number(p1.y);
  const vx = Number(p1.x) - Number(p3.x);
  const vy = Number(p1.y) - Number(p3.y);
  if (![dx, dy, vx, vy, p3.x, p3.y].every(Number.isFinite)) return null;
  return [
    { x: Number(p3.x), y: Number(p3.y) },
    { x: Number(p3.x) + dx, y: Number(p3.y) + dy },
    { x: Number(p2.x), y: Number(p2.y) },
    { x: Number(p1.x), y: Number(p1.y) },
  ];
}

function getParallelogramVerts(r) {
  if (!r || r.kind !== "parallelogram") return null;
  if (Array.isArray(r.verts) && r.verts.length >= 4) {
    const vs = r.verts.map((v) => ({ x: Number(v.x), y: Number(v.y) }));
    if (vs.every((v) => Number.isFinite(v.x) && Number.isFinite(v.y))) return vs;
  }
  const x1 = Number(r.x1), y1 = Number(r.y1), x2 = Number(r.x2), y2 = Number(r.y2);
  if (Number.isFinite(x1) && Number.isFinite(y1) && Number.isFinite(x2) && Number.isFinite(y2)) {
    return [{ x: x1, y: y1 }, { x: x2, y: y2 }];
  }
  return null;
}

function distPxToSegment(px, py, x1, y1, x2, y2) {
  const dx = x2 - x1;
  const dy = y2 - y1;
  const len2 = dx * dx + dy * dy;
  if (len2 <= 1e-12) return Math.hypot(px - x1, py - y1);
  let t = ((px - x1) * dx + (py - y1) * dy) / len2;
  t = Math.max(0, Math.min(1, t));
  return Math.hypot(px - (x1 + t * dx), py - (y1 + t * dy));
}

function pickParallelogramAt(s, px, py, threshold = 8) {
  for (let i = userBiRays.length - 1; i >= 0; i -= 1) {
    const r = userBiRays[i];
    const verts = getParallelogramVerts(r);
    if (!verts) continue;
    if (verts.length === 2) {
      const x1 = s.x(verts[0].x), y1 = s.y(verts[0].y);
      const x2 = s.x(verts[1].x), y2 = s.y(verts[1].y);
      if (distPxToSegment(px, py, x1, y1, x2, y2) <= threshold) return { type: "biRay", index: i };
      continue;
    }
    let hit = false;
    for (let j = 0; j < 4; j += 1) {
      const a = verts[j];
      const b = verts[(j + 1) % 4];
      const x1 = s.x(a.x), y1 = s.y(a.y);
      const x2 = s.x(b.x), y2 = s.y(b.y);
      if (distPxToSegment(px, py, x1, y1, x2, y2) <= threshold) {
        hit = true;
        break;
      }
    }
    if (hit) return { type: "biRay", index: i };
  }
  return null;
}

/** 平行四边形等：Ctrl 吸附当前列 K 线 OHLC；无 Ctrl 时优先笔端点 */
function pickBiEndpointWithCtrl(chart, s, px, py, ctrlKey) {
  const visibleKs = getVisibleKs(chart, s.xMin, s.xMax);
  const xVal = xFromPx(s, px);
  const refK = nearestKByX(visibleKs.length ? visibleKs : (chart.kline || []), xVal);
  if (ctrlKey && refK) {
    const snapped = snapPriceToKlineOhlc(refK, s.yFromPx(py));
    return { x: Number(refK.x), y: snapped.y };
  }
  const pt = getNearestBiEndpoint(chart, s, px, py, 12);
  if (pt) return pt;
  if (refK) {
    const snapped = snapPriceToKlineOhlc(refK, s.yFromPx(py));
    return { x: Number(refK.x), y: snapped.y };
  }
  return null;
}

function pickDrawingAt(s, px, py) {
  const threshold = 8;
  const pg = pickParallelogramAt(s, px, py, threshold);
  if (pg) return pg;
  for (let i = userRays.length - 1; i >= 0; i -= 1) {
    const ray = userRays[i];
    const yp = s.y(ray.y);
    const xp = s.x(ray.x);
    if (px >= xp - 10 && px <= s.w - PAD_R + 10 && Math.abs(py - yp) <= threshold) {
      return { type: "ray", index: i };
    }
  }
  const xVal = xFromPx(s, px);
  for (let i = userBiRays.length - 1; i >= 0; i -= 1) {
    const r = userBiRays[i];
    const x1 = Number(r.x1), y1 = Number(r.y1), x2 = Number(r.x2), y2 = Number(r.y2);
    const dx = x2 - x1;
    if (!Number.isFinite(x1) || !Number.isFinite(y1) || !Number.isFinite(dx) || dx === 0) continue;
    if (xVal < x1) continue;
    const slope = (y2 - y1) / dx;
    const yOn = y1 + slope * (xVal - x1);
    const yPx = s.y(yOn);
    if (Math.abs(yPx - py) <= threshold) return { type: "biRay", index: i };
  }
  return null;
}

function pickRatioLineAt(s, px, py, threshold = 8) {
  const xVal = xFromPx(s, px);
  for (let i = userBiRays.length - 1; i >= 0; i -= 1) {
    const r = userBiRays[i];
    if (!r || r.kind !== "ratioLine") continue;
    const x1 = Number(r.x1), y1 = Number(r.y1), x2 = Number(r.x2), y2 = Number(r.y2);
    const dx = x2 - x1;
    if (!Number.isFinite(x1) || !Number.isFinite(y1) || !Number.isFinite(dx) || dx === 0) continue;
    if (xVal < x1) continue;
    const slope = (y2 - y1) / dx;
    const yOn = y1 + slope * (xVal - x1);
    const yPx = s.y(yOn);
    if (Math.abs(yPx - py) <= threshold) return { type: "biRay", index: i };
  }
  return null;
}

function getDragRatioLinePrice(chart, s, px, py, ctrlKey) {
  const rawPrice = s.yFromPx(py);
  if (!ctrlKey) return rawPrice;
  const visibleKs = getVisibleKs(chart, s.xMin, s.xMax);
  const xVal = xFromPx(s, px);
  const refK = nearestKByX(visibleKs, xVal);
  if (!refK) return rawPrice;
  const high = Number(refK.h);
  const low = Number(refK.l);
  if (!Number.isFinite(high) || !Number.isFinite(low)) return rawPrice;
  return Math.abs(high - rawPrice) <= Math.abs(low - rawPrice) ? high : low;
}

function getRatioLineDynamicRatio(line) {
  if (!line || line.kind !== "ratioLine") return Number.NaN;
  const low = Number(line.baseLow);
  const high = Number(line.baseHigh);
  const baseDir = String(line.baseDir || "").toLowerCase();
  const y = Number(line.y1);
  const span = high - low;
  if (!Number.isFinite(low) || !Number.isFinite(high) || !Number.isFinite(y) || !Number.isFinite(span) || span === 0) {
    return Number(line.ratio);
  }
  // 上升笔：越往下回调比例越大；下降笔：沿用常规从低到高比例递增
  if (baseDir === "up") return (high - y) / span;
  return (y - low) / span;
}

function editSelectedLineProps() {
  if (!selectedDrawing) {
    setMsg("请先点击“选择”，并在图表上选中一条画线。");
    return;
  }
  const list = selectedDrawing.type === "biRay" ? userBiRays : userRays;
  const cur = list[selectedDrawing.index];
  if (!cur) {
    setMsg("当前选中画线不存在，请重新选择。");
    selectedDrawing = null;
    return;
  }
  const defaultColor = String(cur.lineColor || chartConfig.userRay.color || "#f97316");
  const defaultWidth = String(getRayLineWidth(cur));
  const defaultStyle = String(getRayLineStyle(cur));
  const lineColor = prompt("请输入画线颜色（如 #ff0000 或 rgba(...)）", defaultColor);
  if (lineColor === null) return;
  const widthText = prompt("请输入画线粗细（正数）", defaultWidth);
  if (widthText === null) return;
  const lineWidth = Number(widthText);
  if (!Number.isFinite(lineWidth) || lineWidth <= 0) {
    setMsg("画线粗细无效，已取消。");
    return;
  }
  const styleText = prompt("请输入线型：solid / dashed / dotted", defaultStyle);
  if (styleText === null) return;
  const style = ["solid", "dashed", "dotted"].includes(String(styleText).trim()) ? String(styleText).trim() : "dashed";
  if (applyLinePropsToDrawing(selectedDrawing, { lineColor: String(lineColor).trim() || defaultColor, lineWidth, lineStyle: style })) {
    setMsg("画线属性已更新。");
    if (lastPayload && lastPayload.ready) drawFromLastPayload();
  }
}

if ($("toolLineProps")) $("toolLineProps").addEventListener("click", () => {
  linePropsHighlightUntil = Date.now() + 1500;
  updateToolboxUI();
  editSelectedLineProps();
  setTimeout(updateToolboxUI, 1600);
});

function persistUserBiRaysNow() {
  storageSet("chan_user_bi_rays", JSON.stringify(userBiRays));
  userBiRaysDirty = false;
}

function maybeSaveUserBiRaysOnExit() {
  const biDirty = userBiRaysDirty && Array.isArray(userBiRays) && userBiRays.length > 0;
  const qtyDirty = userQuantityRaysDirty && Array.isArray(userQuantityRays) && userQuantityRays.length > 0;
  if (!biDirty && !qtyDirty) return;
  const msg = biDirty && qtyDirty
    ? "是否保存画线（含工具箱射线与数量模式射线）？"
    : (qtyDirty ? "是否保持数量模式画线？" : "是否保存画线？");
  const shouldSave = confirmAndLog(msg);
  if (!shouldSave) return;
  if (biDirty) persistUserBiRaysNow();
  if (qtyDirty) persistUserQuantityRaysNow();
}

window.addEventListener("beforeunload", () => {
  maybeSaveUserBiRaysOnExit();
});

(() => {
  const panel = $("chartToolsPanel");
  if (!panel) return;
  const handle = panel.querySelector(".drag-handle");
  if (!handle) return;
  let dragging = false;
  let startX = 0;
  let startY = 0;
  let baseLeft = 0;
  let baseTop = 0;
  handle.addEventListener("mousedown", (e) => {
    if (!panel.classList.contains("floating")) return;
    dragging = true;
    startX = e.clientX;
    startY = e.clientY;
    const rect = panel.getBoundingClientRect();
    baseLeft = rect.left;
    baseTop = rect.top;
    e.preventDefault();
  });
  window.addEventListener("mousemove", (e) => {
    if (!dragging) return;
    panel.style.left = `${Math.max(8, baseLeft + (e.clientX - startX))}px`;
    panel.style.top = `${Math.max(8, baseTop + (e.clientY - startY))}px`;
    panel.style.right = "auto";
  });
  window.addEventListener("mouseup", () => {
    dragging = false;
  });
})();

canvas.addEventListener("contextmenu", (e) => {
  if (isDualRuntimeReady()) e.preventDefault();
});

canvas.addEventListener("click", (e) => {
  const pe = normalizePointerEventToActivePane(e, true);
  if (!pe) return;
  if (!lastPayload || !lastPayload.ready || !viewReady) return;
  if (chartClickMoved) return;
  const rect = canvas.getBoundingClientRect();
  const s = scalerForActivePayloadChart(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
  const y = pe.clientY - rect.top;
  const x = pe.clientX - rect.left;

  const qtyRayMode = isSingleQuantityRayMode();
  const wantQuantityRay = qtyRayMode && !!pe.ctrlKey;
  const wantHorizontalRay = (!qtyRayMode && !!pe.ctrlKey) || activeTool === "horizontalRay";
  const wantBiRay = !!pe.shiftKey || activeTool === "biRay";
  const wantRatioLine = activeTool === "ratioLine";
  const wantParallelogram = activeTool === "parallelogram";

  // 数量模式：Ctrl+左键 固定端点（吸附 OHLC），两点生成向右射线
  if (wantQuantityRay) {
    const anchor = buildQuantityRayAnchor(lastPayload.chart, s, x, y);
    if (!anchor) return;
    pendingQuantityRayPts.push(anchor);
    if (pendingQuantityRayPts.length === 1) {
      setMsg("已固定端点1（Ctrl 吸附开高低收），请再 Ctrl+左键 固定端点2。");
      redrawCurrentPayload();
      return;
    }
    const p1 = pendingQuantityRayPts[0];
    const p2 = pendingQuantityRayPts[1];
    pendingQuantityRayPts = [];
    if (!quantityRayTimePriceK({ p1, p2 })) {
      setMsg("两端点时间相同或无效，无法生成射线。");
      return;
    }
    const sr = getCurrentSessionRangeMs();
    userQuantityRays.push({
      code: getActiveSessionCode(),
      createdQty: clampDataFormQuantity(dataFormConfig.quantity, getRawKlineCount() || 1),
      sessionBegin: sr.beginStr,
      sessionEnd: sr.endStr,
      p1: { t: p1.t, ohlc: p1.ohlc, y: p1.y },
      p2: { t: p2.t, ohlc: p2.ohlc, y: p2.y },
    });
    userQuantityRaysDirty = true;
    persistUserQuantityRaysNow();
    setMsg(
      "已生成数量射线：斜率按时间-价格固定；换数量后按时间重映射。当前区间包含绘制区间时，旧区间为实线、延长为虚线，否则全虚线。"
    );
    redrawCurrentPayload();
    return;
  }

  // Ctrl + Left Click (or toolbox): Horizontal Ray
  if (wantHorizontalRay) {
    const refK = getReferenceK(lastPayload.chart, s);
    if (refK) {
      const yVal = s.yFromPx(y);
      userRays.push({ x: refK.x, y: yVal });
      storageSet("chan_user_rays", JSON.stringify(userRays));
      setMsg(`已生成射线: ${yVal.toFixed(2)}`);
      redrawCurrentPayload();
    }
    return;
  }

  // Shift + Left Click (or toolbox): pick 2 Bi endpoints then draw a right ray
  if (wantBiRay) {
    const pt = getNearestBiEndpoint(lastPayload.chart, s, x, y, 12);
    if (!pt) {
      return;
    }
    pendingBiRayPts.push(pt);
    if (pendingBiRayPts.length === 1) {
      setMsg("已选择端点1，请再选择端点2。");
      redrawCurrentPayload();
      return;
    }
    const p1 = pendingBiRayPts[0];
    const p2 = pendingBiRayPts[1];
    pendingBiRayPts = [];
    if (Number(p2.x) === Number(p1.x)) {
      setMsg("两个端点 x 相同，无法生成射线。");
      return;
    }
    userBiRays.push({ x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y });
    userBiRaysDirty = true;
    setMsg("已生成笔射线 →");
    redrawCurrentPayload();
    return;
  }
  // 比例线工具：依次点 2 个笔端点，生成多条向右射线（按默认比例列表）
  if (wantRatioLine) {
    const pt = getNearestBiEndpoint(lastPayload.chart, s, x, y, 12);
    if (!pt) return;
    pendingRatioLinePts.push(pt);
    if (pendingRatioLinePts.length === 1) {
      setMsg("已选择端点1，请再选择端点2生成比例线。");
      redrawCurrentPayload();
      return;
    }
    const p1 = pendingRatioLinePts[0];
    const p2 = pendingRatioLinePts[1];
    pendingRatioLinePts = [];
    const xStart = Math.max(Number(p1.x), Number(p2.x));
    const low = Math.min(Number(p1.y), Number(p2.y));
    const high = Math.max(Number(p1.y), Number(p2.y));
    // 右侧端点价格 > 左侧端点价格 => 上升，否则下降
    const leftPt = Number(p1.x) <= Number(p2.x) ? p1 : p2;
    const rightPt = Number(p1.x) <= Number(p2.x) ? p2 : p1;
    const isUpBi = Number(rightPt.y) > Number(leftPt.y);
    const baseDir = isUpBi ? "up" : "down";
    const span = high - low;
    if (!Number.isFinite(xStart) || !Number.isFinite(span) || span <= 0) {
      setMsg("两个端点价格相同或无效，无法生成比例线。");
      return;
    }
    const ratios = normalizeRatioLineRatios(DEFAULT_RATIO_LINE_RATIOS);
    const groupId = buildRatioGroupId();
    const groupColor = pickNextRatioGroupColor();
    ratios.forEach((ratio) => {
      const yLevel = baseDir === "up" ? (high - span * ratio) : (low + span * ratio);
      userBiRays.push({
        x1: xStart,
        y1: yLevel,
        x2: xStart + 1,
        y2: yLevel,
        kind: "ratioLine",
        ratio,
        baseLow: low, // 记录该组比例线的基准端点最低价
        baseHigh: high, // 记录该组比例线的基准端点最高价
        baseDir, // 记录基准笔方向，供动态比例重算使用
        groupId,
        groupColor,
        lineColor: groupColor,
        // 记录该组选择的两个端点，渲染同色圆圈
        anchor1: { x: Number(p1.x), y: Number(p1.y) },
        anchor2: { x: Number(p2.x), y: Number(p2.y) },
      });
    });
    userBiRaysDirty = true;
    setMsg(`已生成比例线（${ratios.map((x) => x.toFixed(3)).join(" / ")}）→`);
    redrawCurrentPayload();
    return;
  }
  // 平行四边形：任意 3 笔端点 → 完整四边形（Ctrl 吸附 OHLC）
  if (wantParallelogram) {
    const pt = pickBiEndpointWithCtrl(lastPayload.chart, s, x, y, !!pe.ctrlKey);
    if (!pt) return;
    pendingParallelogramPts.push(pt);
    if (pendingParallelogramPts.length === 1) {
      setMsg("已选端点1，请再选端点2、端点3（Ctrl+左键可在任意 K 线列吸附 OHLC）。");
      redrawCurrentPayload();
      return;
    }
    if (pendingParallelogramPts.length === 2) {
      setMsg("已选端点2，请再选端点3。");
      redrawCurrentPayload();
      return;
    }
    const p1 = pendingParallelogramPts[0];
    const p2 = pendingParallelogramPts[1];
    const p3 = pendingParallelogramPts[2];
    pendingParallelogramPts = [];
    const verts = buildParallelogramVerts(p1, p2, p3);
    if (!verts) {
      setMsg("端点无效，无法生成平行四边形。");
      return;
    }
    userBiRays.push({
      kind: "parallelogram",
      verts,
      x1: verts[0].x,
      y1: verts[0].y,
      x2: verts[1].x,
      y2: verts[1].y,
    });
    userBiRaysDirty = true;
    setMsg("已生成完整平行四边形。");
    redrawCurrentPayload();
    return;
  }

  if (activeTool === "none") {
    const picked = pickDrawingAt(s, x, y);
    if (picked) {
      selectedDrawing = picked;
      setMsg(picked.type === "biRay" ? "已选中笔端点/比例/平行射线，可点击“画线属性”编辑。" : "已选中水平射线，可点击“画线属性”编辑。");
      redrawCurrentPayload();
      return;
    }
  }

  const panel = getPanelByY(s, y);
  if (!panel) return;
  selectedSubIndicatorSlot = Number(panel.slot);
  storageSet("chan_selected_sub_indicator_slot", String(selectedSubIndicatorSlot));
  syncIndicatorControls();
});

function executeShortcutAction(actionId) {
  switch (actionId) {
    case "openChartSettings":
      openSettings();
      return true;
    case "openSystemSettings":
      openSystemSettings();
      return true;
    case "toggleFullscreen":
      $("btnFullscreen").click();
      return true;
    case "initSession":
      if ($("btnInit").disabled) return false;
      $("btnInit").click();
      return true;
    case "resetSession":
      if ($("btnReset").disabled) return false;
      $("btnReset").click();
      return true;
    case "prevBar":
      if (!$("btnStepPrev") || $("btnStepPrev").disabled || stepInFlight) return false;
      $("btnStepPrev").click();
      return true;
    case "nextBar":
      if ($("btnStep").disabled || stepInFlight) return false;
      $("btnStep").click();
      return true;
    case "stepForwardN":
      if ($("btnStepN").disabled) return false;
      $("btnStepN").click();
      return true;
    case "interruptStepForward":
      if (!$("btnStepInterrupt") || $("btnStepInterrupt").disabled || !stepInFlight) return false;
      $("btnStepInterrupt").click();
      return true;
    case "stepBackwardN":
      if ($("btnBackN").disabled) return false;
      $("btnBackN").click();
      return true;
    case "buyAll":
      if ($("btnBuy").disabled) return false;
      $("btnBuy").click();
      return true;
    case "sellAll":
      if ($("btnSell").disabled) return false;
      $("btnSell").click();
      return true;
    case "shortAll":
      if ($("btnShort").disabled) return false;
      $("btnShort").click();
      return true;
    case "coverAll":
      if ($("btnCover").disabled) return false;
      $("btnCover").click();
      return true;
    case "centerLatest":
      centerLatestK();
      return true;
    case "drawHorizontalRay": {
      if (!crosshairEnabled || crosshairX === null || crosshairY === null || !lastPayload || !lastPayload.ready) return false;
      const s = scalerForActivePayloadChart(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
      const refK = getReferenceK(lastPayload.chart, s);
      if (!refK) return false;
      const yVal = s.yFromPx(crosshairY);
      userRays.push({ x: refK.x, y: yVal });
      storageSet("chan_user_rays", JSON.stringify(userRays));
      setMsg(`已生成射线: ${yVal.toFixed(2)}`);
      drawFromLastPayload();
      return true;
    }
    case "zoomYIn":
      if (!lastPayload || !lastPayload.ready) return false;
      viewYZoomRatio *= 1.15;
      drawFromLastPayload();
      return true;
    case "zoomYOut":
      if (!lastPayload || !lastPayload.ready) return false;
      viewYZoomRatio /= 1.15;
      drawFromLastPayload();
      return true;
    case "zoomXIn":
      if (!lastPayload || !lastPayload.ready) return false;
      zoomViewAt(1.15, Math.max(1, scalerCssDimensions(undefined).w) / 2);
      return true;
    case "zoomXOut":
      if (!lastPayload || !lastPayload.ready) return false;
      zoomViewAt(1 / 1.15, Math.max(1, scalerCssDimensions(undefined).w) / 2);
      return true;
    case "adjustCrosshairUp":
    case "adjustCrosshairDown": {
      if (!crosshairEnabled || crosshairY === null || !lastPayload || !lastPayload.ready) return false;
      const s = scalerForActivePayloadChart(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
      const delta = actionId === "adjustCrosshairUp" ? -0.01 : 0.01;
      const curPrice = s.yFromPx(crosshairY);
      const newPrice = curPrice - delta;
      crosshairY = s.y(newPrice);
      drawFromLastPayload();
      return true;
    }
    case "saveChartSettings":
      if (!isSettingsOpen()) return false;
      void saveSettings().catch((e) => setMsg("保存图表设置失败：" + e.message));
      return true;
    case "saveSystemSettings":
      if (!isSystemSettingsOpen()) return false;
      saveSystemSettingsFromForm();
      return true;
    case "confirmBspPrompt":
      // 兼容旧逻辑：买卖点提示不再阻断步进，无需确认
      clearBspPrompt();
      return true;
    case "closeSettlement":
      if (!$("settlementModal").classList.contains("show")) return false;
      $("btnSettlementClose").click();
      return true;
    case "setBspJudgeAuto": {
      const prev = systemConfig.bspJudgeMode;
      systemConfig.bspJudgeMode = "auto";
      saveSystemConfig();
      updateBspJudgeUI();
      showAlertAndLog("买卖点判定方式切换：手动 → 自动。\n将自动补判当前尚未判定的笔/段/2段买卖点，并记录到后台。");
      if (prev === "manual") checkBspJudge("switch_manual_to_auto");
      return true;
    }
    case "setBspJudgeManual":
      systemConfig.bspJudgeMode = "manual";
      saveSystemConfig();
      updateBspJudgeUI();
      showAlertAndLog("买卖点判定方式切换：自动 → 手动。\n上一级结构变向时将不再自动判定，需手动点击“检查买卖点”。");
      return true;
    case "checkBspJudge":
      if (!isBspJudgeManual()) return false;
      checkBspJudge("manual_shortcut");
      return true;
    default:
      return false;
  }
}

window.addEventListener("keydown", (e) => {
  const contexts = getActiveShortcutContexts();
  const activeTag = (document.activeElement && document.activeElement.tagName) ? document.activeElement.tagName.toLowerCase() : "";
  const allowWhenEditing = contexts.some(ctx => ctx === "bspPrompt" || ctx === "settlement");

  if (!allowWhenEditing && (activeTag === "input" || activeTag === "select" || activeTag === "textarea")) return;

  const now = Date.now();
  if (!shortcutSequenceLastAt || now - shortcutSequenceLastAt > SHORTCUT_SEQUENCE_TIMEOUT) {
    shortcutSequenceBuffer = [];
  }

  const currentEntries = compiledShortcuts.filter(entry => entry.contexts.some(ctx => contexts.includes(ctx)));
  const keyToken = eventToShortcutKeyToken(e);

  if (keyToken && !e.ctrlKey && !e.altKey && !e.metaKey) {
    shortcutSequenceBuffer.push(keyToken);
    shortcutSequenceLastAt = now;
    while (shortcutSequenceBuffer.length > 12) shortcutSequenceBuffer.shift();

    for (const entry of currentEntries) {
      const matched = entry.shortcuts.find(def => def.type === "sequence" && shortcutSequenceMatches(def));
      if (matched && executeShortcutAction(entry.actionId)) {
        e.preventDefault();
        shortcutSequenceBuffer = [];
        return;
      }
    }
  }

  for (const entry of currentEntries) {
    const matched = entry.shortcuts.find(def => shortcutMatchesEvent(def, e));
    if (matched && executeShortcutAction(entry.actionId)) {
      e.preventDefault();
      shortcutSequenceBuffer = [];
      return;
    }
  }

  if (!viewReady || !lastPayload || !lastPayload.ready || contexts[0] !== "global") return;
  const span = viewXMax - viewXMin;
  const shift = Math.max(2, Math.round(span * 0.1));
  const iw = Math.max(1, scalerCssDimensions(undefined).w);
  const plotMidX = PAD_L + (iw - PAD_L - PAD_R) / 2;
  if (e.code === "ArrowUp") {
    e.preventDefault();
    zoomViewAt(1.15, plotMidX);
    return;
  }
  if (e.code === "ArrowDown") {
    e.preventDefault();
    zoomViewAt(1 / 1.15, plotMidX);
    return;
  }
  if (e.code === "ArrowLeft") {
    if (crosshairEnabled && crosshairX !== null) {
      e.preventDefault();
      if (isDualRuntimeReady()) loadRuntimeState(dualActiveChartId);
      const ch = isDualRuntimeReady() && lastPayload.charts && lastPayload.charts[dualActiveChartId]
        ? lastPayload.charts[dualActiveChartId]
        : lastPayload.chart;
      const s = toScaler(ch, Math.max(allXMin, viewXMin), viewXMax, isDualRuntimeReady() ? dualActiveChartId : undefined);
      const refK = getReferenceK(ch, s);
      if (refK) {
        const prev = nearestKByX(ch.kline.filter((k) => k.x < refK.x), refK.x - 1);
        if (prev) {
          crosshairX = s.x(prev.x);
          crosshairY = s.y(prev.c);
          if (isDualRuntimeReady()) {
            saveRuntimeState(dualActiveChartId);
            syncDualCrosshairByTime(lastPayload);
            redrawCurrentPayload();
          } else {
            drawFromLastPayload();
          }
        }
      }
      return;
    }
    viewXMin = Math.max(allXMin, viewXMin - shift);
    viewXMax = viewXMin + span;
    userAdjustedView = true;
    drawFromLastPayload();
  } else if (e.code === "ArrowRight") {
    if (crosshairEnabled && crosshairX !== null) {
      e.preventDefault();
      if (isDualRuntimeReady()) loadRuntimeState(dualActiveChartId);
      const ch = isDualRuntimeReady() && lastPayload.charts && lastPayload.charts[dualActiveChartId]
        ? lastPayload.charts[dualActiveChartId]
        : lastPayload.chart;
      const s = toScaler(ch, Math.max(allXMin, viewXMin), viewXMax, isDualRuntimeReady() ? dualActiveChartId : undefined);
      const refK = getReferenceK(ch, s);
      if (refK) {
        const next = nearestKByX(ch.kline.filter((k) => k.x > refK.x), refK.x + 1);
        if (next) {
          crosshairX = s.x(next.x);
          crosshairY = s.y(next.c);
          if (isDualRuntimeReady()) {
            saveRuntimeState(dualActiveChartId);
            syncDualCrosshairByTime(lastPayload);
            redrawCurrentPayload();
          } else {
            drawFromLastPayload();
          }
        }
      }
      return;
    }
    viewXMin = viewXMin + shift;
    viewXMax = viewXMax + shift;
    userAdjustedView = true;
    drawFromLastPayload();
  }
});

let msgHistory = ensureArray(safeJsonParse(storageGet("chan_msg_history"), []), []);
let previousMsgHistory = ensureArray(safeJsonParse(storageGet("chan_msg_history_prev"), []), []);
let lastToastText = "";
let lastToastAt = 0;
const rustHistorySeen = new Set();

function appendMsgHistory(text) {
  const content = String(text || "").trim();
  if (!content) return;
  if (!Array.isArray(msgHistory)) msgHistory = [];
  const last = msgHistory.length > 0 ? msgHistory[msgHistory.length - 1] : null;
  if (last && String(last.text || "").trim() === content) return;
  const t = new Date().toLocaleTimeString();
  const entry = { time: t, text: content };
  msgHistory.push(entry);
  if (msgHistory.length > 500) msgHistory.shift();
  storageSet("chan_msg_history", JSON.stringify(msgHistory));
  const loading = $("globalLoading");
  if (loading && loading.classList.contains("show")) renderGlobalLoadingHistory();
  const modal = $("msgHistoryModal");
  if (modal && modal.classList.contains("show")) renderMsgHistory();
}

function appendRustHistoryFromPayload(payload) {
  const rows = [];
  const cacheInfo = payload && payload.cache_info;
  if (cacheInfo && Array.isArray(cacheInfo.last_rust_errors)) {
    cacheInfo.last_rust_errors.forEach((it) => rows.push(it));
  }
  const profile = payload && payload.chip_profile;
  if (profile && profile.error) {
    rows.push({ feature: "筹码分布", detail: String(profile.error || ""), traceback: "" });
  }
  rows.forEach((it) => {
    const feature = String(it && it.feature ? it.feature : "未知");
    const detail = String(it && it.detail ? it.detail : "").trim();
    const tb = String(it && it.traceback ? it.traceback : "").trim();
    const key = `${feature}|${detail}|${tb.slice(-240)}`;
    if (!detail || rustHistorySeen.has(key)) return;
    rustHistorySeen.add(key);
    appendMsgHistory(`Rust失败详情：${feature}：${detail}`);
    if (tb && tb !== detail) appendMsgHistory(`Rust失败堆栈：${feature}：${tb}`);
  });
}

function msgHistoryText(rows = null) {
  const src = Array.isArray(rows) ? rows : (Array.isArray(msgHistory) ? msgHistory : []);
  return src.map((m) => `[${String(m.time || "--")}] ${String(m.text || "")}`).join("\n");
}

function archiveAndClearMsgHistory(reason = "新会话") {
  if (Array.isArray(msgHistory) && msgHistory.length > 0) {
    previousMsgHistory = msgHistory.slice();
    storageSet("chan_msg_history_prev", JSON.stringify(previousMsgHistory));
  }
  msgHistory = [];
  storageSet("chan_msg_history", JSON.stringify(msgHistory));
  const loading = $("globalLoading");
  if (loading && loading.classList.contains("show")) renderGlobalLoadingHistory();
  const modal = $("msgHistoryModal");
  if (modal && modal.classList.contains("show")) renderMsgHistory();
  if (reason) appendMsgHistory(`历史记录已清空：${reason}`);
}

function showPreviousMsgHistory() {
  const rows = Array.isArray(previousMsgHistory) ? previousMsgHistory : [];
  if (!rows.length) {
    setMsg("暂无上一次历史记录。");
    return;
  }
  showMsgHistory(rows, "上一次历史记录");
}

function dataFormModeLabel(mode) {
  const m = normalizeDataFormMode(mode);
  return {
    traditional: "传统",
    quantity: "数量",
    tick_traditional: "分笔价格合成传统",
    tick_quantity: "分笔价格合成数量",
  }[m] || m;
}

function dataFeedModeLabel(mode) {
  return normalizeDataFeedMode(mode) === "unified" ? "统一喂数据（一次性喂给缠论计算）" : "逐K喂数据";
}

function klinePresentationLabel(mode) {
  return normalizeKlinePresentationMode(mode) === "instant" ? "一次性呈现" : "步进";
}

function quantityAllocLabel(alloc) {
  return normalizeDataFormQuantityAlloc(alloc) === "back" ? "靠后分配（余数优先分给后方K线）" : "靠前分配（余数优先分给前方K线）";
}

function collectCheckedLazySummary() {
  const layers = collectChartLazyLayersFromConfig(chartConfig, chartConfigStore);
  const onKeys = (obj) => Object.entries(obj || {}).filter(([, v]) => !!v).map(([k]) => segLevelLabel(k));
  return {
    rhythm: !!layers.rhythm,
    rhythmHits: !!layers.rhythm_hits,
    lineLevels: (Object.entries(layers.line_levels || {}).filter(([, v]) => !!v).map(([k]) => segLevelLabel(k))),
    bspLevels: onKeys(layers.bsp_levels),
    zsLevels: onKeys(layers.zs_levels),
  };
}

function buildCurrentConfigSummaryText() {
  flushChartSettingsFormToMemory();
  const chartMode = $("chartMode") ? String($("chartMode").value || "single") : "single";
  const k1 = $("kType") ? String($("kType").value || "") : "";
  const k2 = $("kType2") ? String($("kType2").value || "") : "";
  const multi = chartMode === "multi" ? collectKTypesMultiSelected().map(getKTypeLabelText).join("、") : "";
  const lazy = collectCheckedLazySummary();
  const customLevels = customSegmentLevelsFromConfig(chartConfig).map(segLevelLabel);
  const qtyMode = isQuantityDataFormMode(dataFormConfig.mode);
  const lines = [
    "当前配置快照",
    "【基础参数】",
    `代码=${$("code") ? $("code").value : "-"}；开始=${$("begin") ? $("begin").value : "-"}；结束=${$("end") && $("end").value ? $("end").value : "空/最新"}；初始资金=${$("cash") ? $("cash").value : "-"}；复权=${$("autype") ? $("autype").selectedOptions[0].textContent : "-"}`,
    `图形结构=${$("chartMode") ? $("chartMode").selectedOptions[0].textContent : "-"}；周期1=${getKTypeLabelText(k1)}${chartMode === "dual" ? `；周期2=${getKTypeLabelText(k2)}` : ""}${chartMode === "multi" ? `；叠加周期=${multi || "未选"}` : ""}`,
    "【配置项】",
    `数据形式=${dataFormModeLabel(dataFormConfig.mode)}；数量=${qtyMode ? clampDataFormQuantity(dataFormConfig.quantity, getRawKlineCount() || 1) : "不生效"}；数量分配=${qtyMode ? quantityAllocLabel(dataFormConfig.quantityAlloc) : "不生效/控件应灰度"}`,
    `喂数据方式=${dataFeedModeLabel(dataFormConfig.feedMode)}；K线图呈现形式=${klinePresentationLabel(dataFormConfig.klinePresentation)}；离线数据自定义=${offlineDataCustomLabel(dataFormConfig.offlineDataCustom)}`,
    "【懒加载/显示】",
    `中枢=${lazy.zsLevels.length ? lazy.zsLevels.join("、") : "全关"}；买卖点=${lazy.bspLevels.length ? lazy.bspLevels.join("、") : "全关"}；自定义级别=${customLevels.length ? customLevels.join("、") : "无"}；节奏线=${lazy.rhythm ? "开" : "关"}；1382提示=${lazy.rhythmHits ? "开" : "关"}；图底买卖点总开关=${chartConfigStore.shared && chartConfigStore.shared.showBottomBsp === false ? "关" : "开"}`,
    "【关键逻辑总结】",
    `数据逻辑：${offlineDataCustomLabel(dataFormConfig.offlineDataCustom)} 会影响 K线、VOL、筹码分布；分笔合成传统/数量均固定从 a_Data 重算。`,
    `计算逻辑：${dataFeedModeLabel(dataFormConfig.feedMode)}；${klinePresentationLabel(dataFormConfig.klinePresentation)}${normalizeDataFeedMode(dataFormConfig.feedMode) === "step" && normalizeKlinePresentationMode(dataFormConfig.klinePresentation) === "instant" ? " = 自动从第1根逐步 step 到末根并展示当时当下结果" : ""}。`,
    "买卖点逻辑：逐K喂数据下同级别/同锚点/同方向只冻结首次识别标签，未来组合标签不回写、不追加；当下性优先于事后正确性。",
    "级别依赖：2段买卖点依赖已形成的3段结构，3段买卖点依赖4段结构，依此类推；若上一级未形成，则该级可能只有结构线没有买卖点文字。",
    `系统关键项：性能引擎=${systemConfig.performanceEngineMode || DEFAULT_SYSTEM_CONFIG.performanceEngineMode}；买卖点判定=${systemConfig.bspJudgeMode || "auto"}；回退缓存=${systemConfig.rollbackCacheDepth || DEFAULT_SYSTEM_CONFIG.rollbackCacheDepth}/${systemConfig.rollbackFullSnapshotInterval || DEFAULT_SYSTEM_CONFIG.rollbackFullSnapshotInterval}/${systemConfig.rollbackCaptureMaxBars || DEFAULT_SYSTEM_CONFIG.rollbackCaptureMaxBars}`,
  ];
  return lines.join("\n");
}

function appendCurrentConfigSummaryToHistory() {
  const text = buildCurrentConfigSummaryText();
  text.split("\n").forEach((line) => appendMsgHistory(line));
}

async function copyTextToClipboard(text, okMsg = "内容已复制") {
  const t = String(text || "");
  if (!t.trim()) {
    setMsg("没有可复制的内容");
    return;
  }
  try {
    await navigator.clipboard.writeText(t);
    setMsg(okMsg);
  } catch (_) {
    const ta = document.createElement("textarea");
    ta.value = t;
    document.body.appendChild(ta);
    ta.select();
    try {
      document.execCommand("copy");
      setMsg(okMsg);
    } catch (e2) {
      setMsg("复制失败：" + (e2 && e2.message ? e2.message : String(e2)));
    }
    document.body.removeChild(ta);
  }
}

function setMsg(text, quiet = false) {
  appendMsgHistory(text);
  if (!quiet) showToast(text, { record: false });
}

if ($("btnCopyCurrentConfig")) {
  $("btnCopyCurrentConfig").onclick = () => {
    void copyTextToClipboard(buildCurrentConfigSummaryText(), "当前配置已复制");
  };
  markUiBound("btnCopyCurrentConfig");
}

function showToast(text, options = {}) {
  const content = String(text || "").trim();
  if (!content) return;
  const record = options && Object.prototype.hasOwnProperty.call(options, "record") ? !!options.record : true;
  if (record) appendMsgHistory(content);
  const now = Date.now();
  if (content === lastToastText && now - lastToastAt < 1600) return;
  lastToastText = content;
  lastToastAt = now;
  const container = $("toastContainer");
  if (!container) return;
  
  const toast = document.createElement("div");
  toast.className = "toast";
  toast.textContent = content;
  
  // Apply settings
  toast.style.fontSize = `${chartConfig.toast.fontSize}px`;
  toast.style.fontWeight = chartConfig.toast.fontWeight;
  
  container.appendChild(toast);
  
  const speed = chartConfig.toast.speed || 3000;
  setTimeout(() => {
    toast.style.opacity = "0";
    setTimeout(() => toast.remove(), 300);
  }, speed);
}

function showAlertAndLog(text) {
  setMsg(text, true);
  alert(text);
}

function confirmAndLog(text) {
  setMsg(text, true);
  return confirm(text);
}

function judgeStatsText(stats) {
  if (!stats || typeof stats !== "object") return null;
  const reason = stats.reason ? String(stats.reason) : "-";
  const time = stats.time ? String(stats.time) : "-";
  const interval = stats.interval && typeof stats.interval === "object" ? stats.interval : null;
  const fromTime = interval && interval.from_time ? String(interval.from_time) : "-";
  const toTime = interval && interval.to_time ? String(interval.to_time) : time;
  const summary = stats.summary && typeof stats.summary === "object" ? stats.summary : stats;
  const details = Array.isArray(stats.details) ? stats.details : [];
  const appeared = Number.isFinite(summary.appeared) ? summary.appeared : null;
  const correct = Number.isFinite(summary.correct) ? summary.correct : null;
  const rate = typeof summary.rate === "number" ? (summary.rate * 100) : null;
  if (appeared === null || correct === null) return null;
  const lines = [
    "买卖点判定结果（自上次判定以来）",
    `区间：${fromTime} ~ ${toTime}`,
    `本次时间：${time}`,
    `总出现：${appeared}`,
    `总正确：${correct}`,
    `总正确率：${rate === null ? "-" : `${rate.toFixed(2)}%`}`,
    `原因：${reason}`,
  ];
  details.forEach((item) => {
    const itemRate = typeof item.rate === "number" ? `${(item.rate * 100).toFixed(2)}%` : "-";
    lines.push(`${item.level_label || item.level || "-"}：出现${item.appeared || 0}，正确${item.correct || 0}，正确率${itemRate}`);
  });
  return lines.join("\n");
}

function getRhythmNoticeTexts(payload) {
  const hits = payload && Array.isArray(payload.rhythm_notice_hits) ? payload.rhythm_notice_hits : [];
  return Array.from(new Set(hits
    .map((hit) => String(hit && (hit.detail || hit.display_label || "1382")).trim())
    .filter(Boolean)));
}

function shouldInterruptStepOnBsp() {
  const toastCfg = chartConfig && chartConfig.toast ? chartConfig.toast : DEFAULT_CHART_CONFIG.toast;
  return toastCfg.interruptOnBsp !== false;
}

/** 买卖点 label 拆成类型 token（与后端 type2str 逗号分隔一致） */
function _bspLabelTokens(label) {
  return String(label || "").split(/[,，]/).map((s) => s.trim().toLowerCase()).filter(Boolean);
}

// 步进 N 中断：细分档位（买/卖各一键）
const INTERRUPT_BSP_SLOT_DEFS = [
  { level: "bi", tokens: ["1", "1p"], buyKey: "interruptBspBi1Buy", sellKey: "interruptBspBi1Sell" },
  { level: "bi", tokens: ["2"], buyKey: "interruptBspBi2Buy", sellKey: "interruptBspBi2Sell" },
  { level: "bi", tokens: ["2s"], buyKey: "interruptBspBi2sBuy", sellKey: "interruptBspBi2sSell" },
  { level: "seg", tokens: ["1", "1p"], buyKey: "interruptBspSeg1Buy", sellKey: "interruptBspSeg1Sell" },
  { level: "seg", tokens: ["2"], buyKey: "interruptBspSeg2Buy", sellKey: "interruptBspSeg2Sell" },
  { level: "seg", tokens: ["2s"], buyKey: "interruptBspSeg2sBuy", sellKey: "interruptBspSeg2sSell" },
  { level: "segseg", tokens: ["1", "1p"], buyKey: "interruptBspSegseg1Buy", sellKey: "interruptBspSegseg1Sell" },
  { level: "segseg", tokens: ["2"], buyKey: "interruptBspSegseg2Buy", sellKey: "interruptBspSegseg2Sell" },
  { level: "segseg", tokens: ["2s"], buyKey: "interruptBspSegseg2sBuy", sellKey: "interruptBspSegseg2sSell" },
];

function _filterBspHitsBySideException(hits, toastCfg) {
  const mode = String(toastCfg.interruptBspSideException || "none").toLowerCase();
  const arr = Array.isArray(hits) ? hits.filter(Boolean) : [];
  if (mode === "buy_only") return arr.filter((h) => h.is_buy);
  if (mode === "sell_only") return arr.filter((h) => !h.is_buy);
  return arr;
}

function _bspHitMatchesSlot(item, slot, toastCfg) {
  if (String(item.level || "").toLowerCase() !== slot.level) return false;
  const labelToks = new Set(_bspLabelTokens(item.label));
  const typeOk = slot.tokens.some((t) => labelToks.has(t));
  if (!typeOk) return false;
  const buyOn = toastCfg[slot.buyKey] !== false;
  const sellOn = toastCfg[slot.sellKey] !== false;
  if (item.is_buy && !buyOn) return false;
  if (!item.is_buy && !sellOn) return false;
  return true;
}

function _bspHitHasUnlistedToken(item) {
  const lv = String(item.level || "").toLowerCase();
  const covered = new Set();
  INTERRUPT_BSP_SLOT_DEFS.forEach((s) => {
    if (s.level === lv) s.tokens.forEach((t) => covered.add(t));
  });
  const toks = _bspLabelTokens(item.label);
  return toks.some((t) => !covered.has(t));
}

function shouldInterruptStepOnBspFine(hits) {
  if (!shouldInterruptStepOnBsp()) return false;
  const toastCfg = chartConfig && chartConfig.toast ? chartConfig.toast : DEFAULT_CHART_CONFIG.toast;
  let arr = Array.isArray(hits) ? hits.filter(Boolean) : [];
  arr = _filterBspHitsBySideException(arr, toastCfg);
  if (arr.length <= 0) return false;

  const activeSlots = INTERRUPT_BSP_SLOT_DEFS.filter((slot) => toastCfg[slot.buyKey] !== false || toastCfg[slot.sellKey] !== false);
  const unlistedOk = toastCfg.interruptBspUnlistedTypes !== false;
  const useAnd = String(toastCfg.interruptBspFineCombine || "or").toLowerCase() === "and";

  // 全部细分买/卖都关时，退化为「当根有任一买卖点即中断」
  if (activeSlots.length <= 0) {
    return arr.length > 0;
  }

  const anyUnlistedHit = unlistedOk && arr.some((h) => _bspHitHasUnlistedToken(h));

  if (!useAnd) {
    for (const item of arr) {
      for (const slot of activeSlots) {
        if (_bspHitMatchesSlot(item, slot, toastCfg)) return true;
      }
    }
    return anyUnlistedHit;
  }

  const allSlotsHit = activeSlots.every((slot) => arr.some((item) => _bspHitMatchesSlot(item, slot, toastCfg)));
  return allSlotsHit || anyUnlistedHit;
}

function combineStepInterruptSources(bspOn, bspHit, rhythmOn, rhythmHit, combineRaw) {
  const mode = String(combineRaw || "or").toLowerCase();
  if (mode === "and") {
    if (bspOn && rhythmOn) return !!bspHit && !!rhythmHit;
    if (bspOn) return !!bspHit;
    if (rhythmOn) return !!rhythmHit;
    return false;
  }
  return (!!bspOn && !!bspHit) || (!!rhythmOn && !!rhythmHit);
}

function shouldInterruptStepOnRhythm1382() {
  const toastCfg = chartConfig && chartConfig.toast ? chartConfig.toast : DEFAULT_CHART_CONFIG.toast;
  return toastCfg.interruptOnRhythm1382 !== false;
}

function shouldShowToastCategory(category) {
  const toastCfg = chartConfig && chartConfig.toast ? chartConfig.toast : DEFAULT_CHART_CONFIG.toast;
  if (category === "bsp") return toastCfg.showBsp !== false;
  if (category === "rhythm1382") return toastCfg.showRhythm1382 !== false;
  if (category === "judge") return toastCfg.showJudge !== false;
  return true;
}

function getLatestBspNotice(payload) {
  if (!payload || !payload.ready || !payload.chart || !Array.isArray(payload.chart.kline) || payload.chart.kline.length === 0) return null;
  const lastX = payload.chart.kline[payload.chart.kline.length - 1].x;
  const hits = (payload.chart.bsp || []).filter((p) => p && p.x === lastX);
  if (hits.length <= 0) return null;
  const key = lastX + "|" + hits.map((p) => `${p.level || "-"}:${getBspDisplayLabel(p)}`).join("|");
  if (lastSeenBspKey.has(key)) return null;
  lastSeenBspKey.add(key);
  return {
    key,
    x: lastX,
    lines: hits.map((p) => getBspDisplayLabel(p)),
    hits,
  };
}

function formatCombinedNoticeSection(title, blocks) {
  const cleanBlocks = Array.from(new Set((blocks || []).map((block) => String(block || "").trim()).filter(Boolean)));
  if (cleanBlocks.length <= 0) return "";
  if (cleanBlocks.length === 1) return `${title}\n${cleanBlocks[0]}`;
  return `${title}\n${cleanBlocks.map((block, idx) => `${idx + 1}. ${block.replace(/\n/g, "\n   ")}`).join("\n\n")}`;
}

function buildStepNoticeText(payload, bspNotice) {
  const sections = [];
  if (shouldShowToastCategory("bsp") && bspNotice && Array.isArray(bspNotice.lines) && bspNotice.lines.length > 0) {
    sections.push(formatCombinedNoticeSection("买卖点提示", bspNotice.lines));
  }
  const rhythmTexts = shouldShowToastCategory("rhythm1382") ? getRhythmNoticeTexts(payload) : [];
  if (rhythmTexts.length > 0) {
    sections.push(formatCombinedNoticeSection("1382提示", rhythmTexts));
  }
  if (shouldShowToastCategory("judge") && payload && payload.judge_notice) {
    const judgeText = judgeStatsText(payload && payload.judge_stats ? payload.judge_stats : null) || "买卖点判定";
    sections.push(formatCombinedNoticeSection("买卖点判定", [judgeText]));
  }
  const cleanSections = sections.filter(Boolean);
  if (cleanSections.length <= 0) return null;
  if (cleanSections.length === 1) {
    const only = cleanSections[0];
    return only.includes("\n1.") ? only : only.replace(/^[^\n]+\n/, "");
  }
  return cleanSections.join("\n\n");
}

function showCombinedNotice(text) {
  const clean = String(text || "").trim();
  if (!clean) return false;
  showToast(clean, { record: false });
  setMsg(clean, true);
  return true;
}

function showJudgeNotice(payload) {
  if (!shouldShowToastCategory("judge")) return;
  const text = judgeStatsText(payload && payload.judge_stats ? payload.judge_stats : null) || "买卖点判定";
  showToast(text, { record: false });
  setMsg(text, true);
}

function showRhythmHitNotices(payload) {
  if (!shouldShowToastCategory("rhythm1382")) return;
  const hits = payload && Array.isArray(payload.rhythm_notice_hits) ? payload.rhythm_notice_hits : [];
  hits.forEach((hit) => {
    const text = String(hit.detail || hit.display_label || "1382").trim();
    if (!text) return;
    showToast(text, { record: false });
    setMsg(text, true);
  });
}

let msgHistoryViewRows = null;
let msgHistoryViewTitle = "消息历史记录";

function renderMsgHistory(rows = null, title = null) {
  const list = $("msgHistoryList");
  if (!list) return;
  list.innerHTML = "";
  const src = Array.isArray(rows) ? rows : (Array.isArray(msgHistory) ? msgHistory : []);
  msgHistoryViewRows = src;
  msgHistoryViewTitle = title || "消息历史记录";
  const titleEl = $("msgHistoryModal") && $("msgHistoryModal").querySelector(".settingsTitle");
  if (titleEl && titleEl.firstChild) titleEl.firstChild.textContent = msgHistoryViewTitle;
  src.forEach(m => {
    const item = document.createElement("div");
    item.className = "msgHistoryItem";
    item.innerHTML = `<span class="time">[${escapeHtml(String(m.time || "--"))}]</span><span class="text">${escapeHtml(String(m.text || ""))}</span>`;
    list.appendChild(item);
  });
  list.scrollTop = list.scrollHeight;
}

function showMsgHistory(rows = null, title = null) {
  renderMsgHistory(rows, title);
  $("msgHistoryModal").classList.add("show");
}

$("btnMsgHistory").onclick = showMsgHistory;
$("btnMsgHistoryClose").onclick = () => $("msgHistoryModal").classList.remove("show");
$("btnMsgHistoryOk").onclick = () => $("msgHistoryModal").classList.remove("show");
if ($("btnMsgHistoryCopy")) $("btnMsgHistoryCopy").onclick = () => copyTextToClipboard(msgHistoryText(msgHistoryViewRows), "历史记录已复制");
if ($("btnMsgHistoryPrev")) $("btnMsgHistoryPrev").onclick = () => showPreviousMsgHistory();
$("btnMsgHistoryClear").onclick = () => {
  if (confirmAndLog("确定要清空所有消息历史记录吗？")) {
    archiveAndClearMsgHistory("手动清空");
  }
};

function syncKlineDataChartSelectVisibility() {
  const wrapDual = $("klineDataChartWrap");
  const wrapMulti = $("klineDataMultiWrap");
  const sel = $("klineDataChartId");
  const selM = $("klineDataLayerKt");
  const dual = lastPayload && String(lastPayload.chart_mode || "") === "dual";
  const multi = lastPayload && String(lastPayload.chart_mode || "") === "multi";
  if (wrapDual) wrapDual.style.display = dual ? "inline" : "none";
  if (wrapMulti) wrapMulti.style.display = multi ? "inline" : "none";
  if (!sel) return;
  if (dual && lastPayload && lastPayload.active_chart_id) {
    const ac = String(lastPayload.active_chart_id) === "chart2" ? "chart2" : "chart1";
    sel.value = ac;
  } else {
    sel.value = "chart1";
  }
  if (multi && selM && lastPayload && Array.isArray(lastPayload.k_types_multi)) {
    const ordered = MULTI_KTYPE_ORDER.filter((k) => lastPayload.k_types_multi.includes(k));
    const cur = selM.value;
    selM.innerHTML = ordered.map((k) => `<option value="${k}">${getKTypeLabelText(k)}（${k}）</option>`).join("");
    if (cur && ordered.includes(cur)) selM.value = cur;
    else if (ordered[0]) selM.value = ordered[0];
  }
}

function renderKlineDataTable(rows) {
  const wrap = $("klineDataTableWrap");
  if (!wrap) return;
  if (!Array.isArray(rows) || rows.length === 0) {
    wrap.innerHTML = '<p class="muted" style="padding:10px">暂无数据</p>';
    return;
  }
  const keys = Object.keys(rows[0]);
  let thead = "<thead><tr>";
  keys.forEach((k) => {
    thead += `<th>${escapeHtmlAttr(k)}</th>`;
  });
  thead += "</tr></thead>";
  let tbody = "<tbody>";
  rows.forEach((r) => {
    tbody += "<tr>";
    keys.forEach((k) => {
      let cell = r[k];
      if (cell !== null && cell !== undefined && typeof cell === "object") cell = JSON.stringify(cell);
      const str = cell === null || cell === undefined ? "" : String(cell);
      const jsonCls = k === "chip_tick_bins" || str.length > 80 ? "klineDataCellJson" : "";
      tbody += `<td class="${jsonCls}">${escapeHtmlAttr(str)}</td>`;
    });
    tbody += "</tr>";
  });
  tbody += "</tbody>";
  wrap.innerHTML = `<table>${thead}${tbody}</table>`;
}

async function loadKlineDataView() {
  const meta = $("klineDataMeta");
  const wrap = $("klineDataTableWrap");
  if (!meta || !wrap) return;
  meta.textContent = "加载中…";
  wrap.innerHTML = "";
  window._klineDataViewLastJson = "";
  const chartId = ($("klineDataChartId") && $("klineDataChartId").value) || "active";
  const view = ($("klineDataView") && $("klineDataView").value) || "kline";
  const layerKt = ($("klineDataLayerKt") && $("klineDataLayerKt").value) || "";
  const multi = lastPayload && String(lastPayload.chart_mode || "") === "multi";
  try {
    const body = { chart_id: chartId, view };
    if (multi && layerKt) body.layer_k_type = layerKt;
    const data = await api("/api/session_kline_view", body);
    meta.textContent = `代码 ${data.code || "-"}　周期 ${data.k_type || "-"}${data.layer_k_type ? `（查看层 ${data.layer_k_type}）` : ""}　图表 ${data.chart_id || "-"}　共 ${data.bar_count != null ? data.bar_count : "-"} 根`;
    renderKlineDataTable(data.rows || []);
    window._klineDataViewLastJson = JSON.stringify(data.rows || [], null, 0);
  } catch (e) {
    meta.textContent = "加载失败：" + (e && e.message ? e.message : String(e));
  }
}

function openKlineDataModal() {
  if (!lastPayload || !lastPayload.ready) return;
  syncKlineDataChartSelectVisibility();
  $("klineDataModal").classList.add("show");
  loadKlineDataView();
}

function closeKlineDataModal() {
  $("klineDataModal").classList.remove("show");
}

if ($("btnViewKlineData")) $("btnViewKlineData").onclick = () => openKlineDataModal();
if ($("btnKlineDataClose")) $("btnKlineDataClose").onclick = () => closeKlineDataModal();
if ($("btnKlineDataOk")) $("btnKlineDataOk").onclick = () => closeKlineDataModal();
if ($("btnKlineDataRefresh")) $("btnKlineDataRefresh").onclick = () => loadKlineDataView();
if ($("klineDataChartId")) $("klineDataChartId").onchange = () => loadKlineDataView();
if ($("klineDataLayerKt")) $("klineDataLayerKt").onchange = () => loadKlineDataView();
if ($("klineDataView")) $("klineDataView").onchange = () => loadKlineDataView();
if ($("btnKlineDataCopy")) {
  $("btnKlineDataCopy").onclick = async () => {
    const t = window._klineDataViewLastJson || "";
    if (!t) {
      setMsg("没有可复制的内容");
      return;
    }
    try {
      await navigator.clipboard.writeText(t);
      setMsg("当前表格数据已复制为 JSON");
    } catch (_) {
      const ta = document.createElement("textarea");
      ta.value = t;
      document.body.appendChild(ta);
      ta.select();
      try {
        document.execCommand("copy");
        setMsg("当前表格数据已复制为 JSON");
      } catch (e2) {
        setMsg("复制失败：" + (e2 && e2.message ? e2.message : String(e2)));
      }
      document.body.removeChild(ta);
    }
  };
}

window.addEventListener("resize", () => {
  updateCompactLayout();
  hideFloatingTip();
});

// Sidebar Resizer
const resizer = $("resizer");
const leftPanel = document.querySelector(".left");
let isResizing = false;

resizer.addEventListener("mousedown", (e) => {
  isResizing = true;
  document.body.style.cursor = "col-resize";
});

window.addEventListener("mousemove", (e) => {
  if (!isResizing) return;
  const newWidth = window.innerWidth - e.clientX;
  if (newWidth > 200 && newWidth < 800) {
    leftPanel.style.width = `${newWidth}px`;
    resizeCanvas();
  }
});

window.addEventListener("mouseup", () => {
  if (isResizing) {
    isResizing = false;
    document.body.style.cursor = "default";
    storageSet("chan_sidebar_width", leftPanel.style.width);
  }
});

// Restore sidebar width
const savedWidth = storageGet("chan_sidebar_width");
if (savedWidth) leftPanel.style.width = savedWidth;

const tradeOverlayState = { dragging: false, offsetX: 0, offsetY: 0, resizing: false, startW: 0, startH: 0, startX: 0, startY: 0, minimized: false, maximized: false, prevRect: null };
function clampOverlayPosition(overlay, left, top) {
  const margin = 8;
  const maxLeft = Math.max(margin, window.innerWidth - overlay.offsetWidth - margin);
  const maxTop = Math.max(margin, window.innerHeight - overlay.offsetHeight - margin);
  return {
    left: Math.max(margin, Math.min(maxLeft, left)),
    top: Math.max(margin, Math.min(maxTop, top)),
  };
}

function applyTradeOverlayPosition(left, top) {
  const overlay = $("tradeStatusOverlay");
  if (!overlay) return;
  const pos = clampOverlayPosition(overlay, left, top);
  overlay.style.left = `${pos.left}px`;
  overlay.style.top = `${pos.top}px`;
  overlay.style.right = "auto";
}

function saveTradeOverlayState() {
  const overlay = $("tradeStatusOverlay");
  if (!overlay) return;
  storageSet("chan_trade_overlay_pos", JSON.stringify({
    left: parseFloat(overlay.style.left) || 16,
    top: parseFloat(overlay.style.top) || 16,
    width: parseFloat(overlay.style.width) || overlay.offsetWidth || 280,
    height: parseFloat(overlay.style.height) || overlay.offsetHeight || 0,
    minimized: !!tradeOverlayState.minimized,
    maximized: !!tradeOverlayState.maximized,
  }));
}

function initTradeStatusDrag() {
  const overlay = $("tradeStatusOverlay");
  const titleBar = overlay ? overlay.querySelector(".tradeStatusTitleBar") : null;
  const resizeHandle = overlay ? overlay.querySelector(".tradeStatusResizeHandle") : null;
  if (!overlay || !titleBar || !resizeHandle) return;
  const saved = safeJsonParse(storageGet("chan_trade_overlay_pos"), null);
  if (saved && Number.isFinite(saved.left) && Number.isFinite(saved.top)) {
    applyTradeOverlayPosition(saved.left, saved.top);
    if (Number.isFinite(saved.width)) {
      const safeWidth = Math.max(220, Math.min(window.innerWidth - 16, saved.width));
      overlay.style.width = `${safeWidth}px`;
    }
    if (Number.isFinite(saved.height) && saved.height > 0) {
      const safeHeight = Math.max(64, Math.min(window.innerHeight - 16, saved.height));
      overlay.style.height = `${safeHeight}px`;
    }
    tradeOverlayState.minimized = !!saved.minimized;
    // Do not auto-enter maximized mode on load, avoid covering the full page and blocking controls.
    tradeOverlayState.maximized = false;
    overlay.classList.toggle("minimized", tradeOverlayState.minimized);
  } else {
    applyTradeOverlayPosition(16, 16);
  }
  titleBar.addEventListener("mousedown", (e) => {
    if (e.button !== 0) return;
    if (e.target.closest("button")) return;
    tradeOverlayState.dragging = true;
    overlay.classList.add("dragging");
    const rect = overlay.getBoundingClientRect();
    tradeOverlayState.offsetX = e.clientX - rect.left;
    tradeOverlayState.offsetY = e.clientY - rect.top;
    e.preventDefault();
  });
  window.addEventListener("mousemove", (e) => {
    if (tradeOverlayState.dragging) {
      const left = e.clientX - tradeOverlayState.offsetX;
      const top = e.clientY - tradeOverlayState.offsetY;
      applyTradeOverlayPosition(left, top);
      return;
    }
    if (tradeOverlayState.resizing) {
      const nextW = Math.max(220, tradeOverlayState.startW + (e.clientX - tradeOverlayState.startX));
      const nextH = Math.max(64, tradeOverlayState.startH + (e.clientY - tradeOverlayState.startY));
      overlay.style.width = `${nextW}px`;
      overlay.style.height = `${nextH}px`;
    }
  });
  window.addEventListener("mouseup", () => {
    if (tradeOverlayState.dragging) {
      tradeOverlayState.dragging = false;
      overlay.classList.remove("dragging");
      saveTradeOverlayState();
    }
    if (tradeOverlayState.resizing) {
      tradeOverlayState.resizing = false;
      saveTradeOverlayState();
    }
  });
  resizeHandle.addEventListener("mousedown", (e) => {
    if (e.button !== 0) return;
    tradeOverlayState.resizing = true;
    tradeOverlayState.startW = overlay.offsetWidth;
    tradeOverlayState.startH = overlay.offsetHeight;
    tradeOverlayState.startX = e.clientX;
    tradeOverlayState.startY = e.clientY;
    e.preventDefault();
    e.stopPropagation();
  });
  $("btnTradeStatusMin").onclick = () => {
    tradeOverlayState.minimized = !tradeOverlayState.minimized;
    overlay.classList.toggle("minimized", tradeOverlayState.minimized);
    saveTradeOverlayState();
  };
  $("btnTradeStatusMax").onclick = () => {
    if (!tradeOverlayState.maximized) {
      tradeOverlayState.prevRect = {
        left: parseFloat(overlay.style.left) || 16,
        top: parseFloat(overlay.style.top) || 16,
        width: overlay.offsetWidth,
        height: overlay.offsetHeight,
      };
      overlay.style.left = "8px";
      overlay.style.top = "8px";
      overlay.style.width = `${Math.max(320, window.innerWidth - 16)}px`;
      overlay.style.height = `${Math.max(90, window.innerHeight - 16)}px`;
      tradeOverlayState.maximized = true;
    } else {
      const prev = tradeOverlayState.prevRect || { left: 16, top: 16, width: 280, height: overlay.offsetHeight };
      overlay.style.left = `${prev.left}px`;
      overlay.style.top = `${prev.top}px`;
      overlay.style.width = `${prev.width}px`;
      overlay.style.height = `${prev.height}px`;
      tradeOverlayState.maximized = false;
    }
    saveTradeOverlayState();
  };
}
initTradeStatusDrag();

function setState(p) {
  if (!p.ready) {
    setText("st_cash", "-");
    setText("st_pos", "-");
    setText("st_cost", "-");
    setText("st_price", "-");
    setText("st_pos_pnl", "-");
    setText("st_equity", "-");
    setText("st_total_pnl", "-");
    return;
  }
  const a = p.account;
  const price = (p.price === null || p.price === undefined) ? null : Number(p.price);
  
  // Fix precision: very small P/L should be 0
  const totalPnl = Math.abs(a.equity - a.initial_cash) < 0.005 ? 0 : (a.equity - a.initial_cash);
  let posPnlRaw = 0;
  if (price !== null && a.position > 0) posPnlRaw = (price - a.avg_cost) * a.position;
  else if (price !== null && a.position < 0) posPnlRaw = (a.avg_cost - price) * Math.abs(a.position);
  const posPnl = Math.abs(posPnlRaw) < 0.005 ? 0 : posPnlRaw;

  setText("st_cash", a.cash.toFixed(2) + " 元");
  setText("st_pos", String(a.position) + " 股");
  setText("st_cost", a.avg_cost === 0 ? "-" : a.avg_cost.toFixed(4) + " 元");
  setText("st_price", price === null ? "-" : price.toFixed(4) + " 元");
  
  const posPnlEl = $("st_pos_pnl");
  if (posPnlEl) {
    posPnlEl.textContent = (posPnl >= 0 ? "+" : "") + posPnl.toFixed(2) + " 元";
    posPnlEl.style.color = posPnl > 0 ? getCfgColor(chartConfig.trade.profitColor) : (posPnl < 0 ? getCfgColor(chartConfig.trade.lossColor) : "inherit");
  }

  setText("st_equity", a.equity.toFixed(2) + " 元");
  
  const totalPnlEl = $("st_total_pnl");
  if (totalPnlEl) {
    totalPnlEl.textContent = (totalPnl >= 0 ? "+" : "") + totalPnl.toFixed(2) + " 元";
    totalPnlEl.style.color = totalPnl > 0 ? getCfgColor(chartConfig.trade.profitColor) : (totalPnl < 0 ? getCfgColor(chartConfig.trade.lossColor) : "inherit");
  }
}

function updateTradeStatusOverlay(payload) {
  const overlay = $("tradeStatusOverlay");
  if (!payload || !payload.ready || !payload.account || payload.account.position === 0) {
    overlay.style.display = "none";
    return;
  }

  const a = payload.account;
  const price = payload.price;
  const isLong = a.position > 0;
  const openX = activeTrade ? (isLong ? activeTrade.buyX : activeTrade.shortX) : null;
  const lastX = payload.chart.kline[payload.chart.kline.length - 1].x;
  const holdBars = openX !== null ? (lastX - openX) : 0;
  const pnlRaw = isLong ? ((price - a.avg_cost) * a.position) : ((a.avg_cost - price) * Math.abs(a.position));
  const pnl = Math.abs(pnlRaw) < 0.005 ? 0 : pnlRaw;
  const pnlPct = (a.avg_cost > 0 && a.position > 0) ? (pnl / (a.avg_cost * a.position)) * 100 : 0;
  const totalPnlRaw = a.equity - a.initial_cash;
  const totalPnl = Math.abs(totalPnlRaw) < 0.005 ? 0 : totalPnlRaw;

  overlay.style.display = "block";
  overlay.style.borderColor = pnl > 0 ? getCfgColor(chartConfig.trade.profitColor) : (pnl < 0 ? getCfgColor(chartConfig.trade.lossColor) : "#e2e8f0");
  const titleEl = overlay.querySelector(".tradeStatusTitle");
  if (titleEl) {
    titleEl.style.fontSize = `${chartConfig.tradeStatus.titleFontSize}px`;
    titleEl.style.fontWeight = chartConfig.tradeStatus.titleFontWeight;
    titleEl.style.color = getCfgColor(chartConfig.tradeStatus.titleColor);
  }
  overlay.querySelectorAll(".tsItem label").forEach((el) => {
    el.style.fontSize = `${chartConfig.tradeStatus.labelFontSize}px`;
    el.style.fontWeight = chartConfig.tradeStatus.labelFontWeight;
    el.style.color = getCfgColor(chartConfig.tradeStatus.labelColor);
  });
  overlay.querySelectorAll(".tsItem span").forEach((el) => {
    el.style.fontSize = `${chartConfig.tradeStatus.valueFontSize}px`;
    el.style.fontWeight = chartConfig.tradeStatus.valueFontWeight;
    el.style.color = getCfgColor(chartConfig.tradeStatus.valueColor);
  });

  setText("ts_hold_bars", `${holdBars} 根`);
  setText("ts_pos", `${a.position} 股`);
  setText("ts_buy_price", `${isLong ? "多" : "空"}@${a.avg_cost.toFixed(4)}`);
  setText("ts_curr_price", price.toFixed(4));
  
  const pnlEl = $("ts_pnl");
  pnlEl.textContent = (pnl >= 0 ? "+" : "") + pnl.toFixed(2);
  pnlEl.style.color = pnl > 0 ? getCfgColor(chartConfig.trade.profitColor) : (pnl < 0 ? getCfgColor(chartConfig.trade.lossColor) : "inherit");

  const pnlPctEl = $("ts_pnl_pct");
  pnlPctEl.textContent = `${(pnlPct >= 0 ? "+" : "") + pnlPct.toFixed(2)}%`;
  pnlPctEl.style.color = pnl > 0 ? getCfgColor(chartConfig.trade.profitColor) : (pnl < 0 ? getCfgColor(chartConfig.trade.lossColor) : "inherit");

  setText("ts_cash", `${a.cash.toFixed(2)} 元`);
  setText("ts_equity", `${a.equity.toFixed(2)} 元`);
  const totalPnlEl = $("ts_total_pnl");
  totalPnlEl.textContent = `${totalPnl >= 0 ? "+" : ""}${totalPnl.toFixed(2)} 元`;
  totalPnlEl.style.color = totalPnl > 0 ? getCfgColor(chartConfig.trade.profitColor) : (totalPnl < 0 ? getCfgColor(chartConfig.trade.lossColor) : "inherit");
}

function showSettlement(tr, stockName) {
  const pnl = (tr.sellPrice - tr.buyPrice) * tr.shares;
  const pnlPct = ((tr.sellPrice - tr.buyPrice) / tr.buyPrice) * 100;
  const holdBars = tr.sellX - tr.buyX;
  
  // Estimate max favorable excursion and max adverse excursion if we have the data
  // For now we just show basic info
  
  const modal = $("settlementModal");
  const body = $("settlementBody");
  const title = $("settlementTitle");
  
  title.textContent = pnl >= 0 ? "交易结算 - 盈利" : "交易结算 - 亏损";
  title.style.color = pnl >= 0 ? "#ef4444" : "#22c55e";
  
  body.innerHTML = `
    <div style="display:grid; grid-template-columns: 1fr 1fr; gap: 12px;">
      <div>标的: <b>${stockName || '-'}</b></div>
      <div>持仓周期: <b>${holdBars} 根</b></div>
      <div>买入价格: <b>${tr.buyPrice.toFixed(4)}</b></div>
      <div>卖出价格: <b>${tr.sellPrice.toFixed(4)}</b></div>
      <div>成交股数: <b>${tr.shares}</b></div>
      <div style="grid-column: span 2; border-top: 1px dashed #ccc; padding-top: 8px; margin-top: 4px;"></div>
      <div>盈亏金额: <b class="${pnl >= 0 ? 'pnl-plus' : 'pnl-minus'}">${pnl.toFixed(2)}</b></div>
      <div>盈亏比例: <b class="${pnl >= 0 ? 'pnl-plus' : 'pnl-minus'}">${pnlPct.toFixed(2)}%</b></div>
    </div>
    <div style="margin-top: 16px; font-size: 12px; color: #64748b;">
      * 最大上涨和回撤指标将在后续版本支持更精确的日内数据统计。
    </div>
  `;
  
  setMsg(
    `交易结算\n标的：${stockName || '-'}\n持仓周期：${holdBars} 根\n买入价格：${tr.buyPrice.toFixed(4)}\n卖出价格：${tr.sellPrice.toFixed(4)}\n成交股数：${tr.shares}\n盈亏金额：${pnl.toFixed(2)}\n盈亏比例：${pnlPct.toFixed(2)}%`,
    true
  );
  modal.classList.add("show");
}

function buildTradeExportSummary(payload) {
  let wins = 0;
  let loss = 0;
  let sumPnl = 0;
  let peak = 0;
  let curve = 0;
  let maxDd = 0;
  let bestTrade = null;
  let worstTrade = null;
  const rows = [];
  rows.push("idx,buy_x,buy_price,sell_x,sell_price,shares,pnl,pnl_pct,hold_bars");
  for (let i = 0; i < tradeHistory.length; i++) {
    const tr = tradeHistory[i];
    const shares = tr.shares || 0;
    const pnl = (tr.sellPrice - tr.buyPrice) * shares;
    const pnlPct = tr.buyPrice === 0 ? 0 : ((tr.sellPrice - tr.buyPrice) / tr.buyPrice) * 100;
    const hold = Math.max(0, tr.sellX - tr.buyX);
    if (pnl >= 0) wins += 1;
    else loss += 1;
    sumPnl += pnl;
    curve += pnl;
    if (curve > peak) peak = curve;
    maxDd = Math.max(maxDd, peak - curve);
    if (!bestTrade || pnl > bestTrade.pnl) bestTrade = { idx: i + 1, pnl };
    if (!worstTrade || pnl < worstTrade.pnl) worstTrade = { idx: i + 1, pnl };
    rows.push(`${i + 1},${tr.buyX},${tr.buyPrice.toFixed(4)},${tr.sellX},${tr.sellPrice.toFixed(4)},${shares},${pnl.toFixed(2)},${pnlPct.toFixed(2)},${hold}`);
  }
  const n = tradeHistory.length;
  const winRate = n === 0 ? 0 : (wins / n) * 100;
  const avgPnl = n === 0 ? 0 : sumPnl / n;
  rows.unshift(`# 最差单笔,${worstTrade ? `${worstTrade.idx}:${worstTrade.pnl.toFixed(2)}` : "-"}`);
  rows.unshift(`# 最佳单笔,${bestTrade ? `${bestTrade.idx}:${bestTrade.pnl.toFixed(2)}` : "-"}`);
  rows.unshift(`# 最大回撤近似(按已平仓序列),${maxDd.toFixed(2)}`);
  rows.unshift(`# 胜率,${winRate.toFixed(2)}%`);
  rows.unshift(`# 平均每笔盈亏,${avgPnl.toFixed(2)}`);
  rows.unshift(`# 总盈亏,${sumPnl.toFixed(2)}`);
  rows.unshift(`# 亏损笔数,${loss}`);
  rows.unshift(`# 盈利笔数,${wins}`);
  rows.unshift(`# 交易笔数,${n}`);
  rows.unshift(`# 标的,${payload.name || payload.code || "-"}`);
  rows.unshift(`# 导出时间,${new Date().toISOString()}`);
  return rows.join("\n");
}

function downloadTradeExport(payload) {
  const blob = new Blob([buildTradeExportSummary(payload)], { type: "text/csv;charset=utf-8" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `chan_trades_${payload.code || "session"}_${Date.now()}.csv`;
  a.click();
  URL.revokeObjectURL(a.href);
}

$("btnSettlementClose").onclick = () => {
  $("settlementModal").classList.remove("show");
};

function getVisibleKs(chart, xMin, xMax) {
  let visibleK = chart.kline.filter((k) => k.x >= xMin && k.x <= xMax);
  if (visibleK.length === 0) visibleK = chart.kline;
  return visibleK;
}

/** 多周期叠图：driver 细 K 在 (tLo,tHi]（loOpen=true 时 tLo=-∞，等价于 <=tHi）内 x 最小/最大，与 a_replay_multi_xmap 一致。 */
function driverXSpanInTimeWindow(driverKs, tLoMs, tHiMs, loOpen) {
  const xs = [];
  for (const dk of driverKs || []) {
    const tm = parseChartTimeToMs(String(dk.t || ""));
    if (!Number.isFinite(tm) || !Number.isFinite(tHiMs)) continue;
    const inWin = loOpen ? tm <= tHiMs : tm > tLoMs && tm <= tHiMs;
    if (!inWin) continue;
    const xv = Number(dk.x);
    if (Number.isFinite(xv)) xs.push(xv);
  }
  if (xs.length === 0) return null;
  return { xLo: Math.min(...xs), xHi: Math.max(...xs) };
}

/** 粗 K 的 t 为桶末时刻：细 K 归属 (tPrev, tCurr]；无上一根则 (-∞, tCurr]（对齐 a_replay_multi_xmap._coarse_bar_time_span_ms）。 */
function overlayCoarseBarTimeWindowMs(prevBar, bar) {
  const tHiMs = parseChartTimeToMs(String(bar.t || ""));
  if (!Number.isFinite(tHiMs)) return null;
  if (!prevBar) {
    return { tLoMs: Number.NEGATIVE_INFINITY, tHiMs, loOpen: true };
  }
  const tLoMs = parseChartTimeToMs(String(prevBar.t || ""));
  if (!Number.isFinite(tLoMs)) {
    return { tLoMs: Number.NEGATIVE_INFINITY, tHiMs, loOpen: true };
  }
  if (tLoMs >= tHiMs) {
    return { tLoMs: Number.NEGATIVE_INFINITY, tHiMs, loOpen: true };
  }
  return { tLoMs, tHiMs, loOpen: false };
}

function overlayFindBarIndexInKline(chart, bar) {
  const arr = chart.kline || [];
  const tt = String(bar.t || "");
  for (let i = 0; i < arr.length; i++) {
    if (String(arr[i].t || "") === tt) return i;
  }
  const bx = Number(bar.x);
  if (Number.isFinite(bx)) {
    for (let i = 0; i < arr.length; i++) {
      if (Number(arr[i].x) === bx) return i;
    }
  }
  return -1;
}

/** (tLo,tHi]（或 loOpen 时 <=tHi）内 driver 细 K，按时间排序；与叠图横轴 span 同一时间语义。 */
function driverBarsInTimeWindowSorted(driverKs, tLoMs, tHiMs, loOpen) {
  const out = [];
  for (const dk of driverKs || []) {
    const tm = parseChartTimeToMs(String(dk.t || ""));
    if (!Number.isFinite(tm) || !Number.isFinite(tHiMs)) continue;
    const inWin = loOpen ? tm <= tHiMs : tm > tLoMs && tm <= tHiMs;
    if (!inWin) continue;
    out.push(dk);
  }
  out.sort((a, b) => {
    const ta = parseChartTimeToMs(String(a.t || ""));
    const tb = parseChartTimeToMs(String(b.t || ""));
    if (ta !== tb) return ta - tb;
    return Number(a.x) - Number(b.x);
  });
  return out;
}

/** 细 K 序列合成 OHLC：首根开、区间最高、区间最低、末根收；无数据则回退粗 K 字段。 */
function synthOhlcFromDriverSlice(slice, coarseBar) {
  const fb = {
    o: Number(coarseBar.o),
    h: Number(coarseBar.h),
    l: Number(coarseBar.l),
    c: Number(coarseBar.c),
  };
  if (!slice || slice.length === 0) return fb;
  const o = Number(slice[0].o);
  const c = Number(slice[slice.length - 1].c);
  let h = -Infinity;
  let l = Infinity;
  for (const b of slice) {
    const bh = Number(b.h);
    const bl = Number(b.l);
    if (Number.isFinite(bh)) h = Math.max(h, bh);
    if (Number.isFinite(bl)) l = Math.min(l, bl);
  }
  if (!Number.isFinite(o) || !Number.isFinite(c) || !Number.isFinite(h) || !Number.isFinite(l)) return fb;
  return { o, h, l, c };
}

function nearestKByX(ks, targetX) {
  if (!ks || ks.length === 0) return null;
  return ks.reduce((best, cur) => {
    return Math.abs(cur.x - targetX) < Math.abs(best.x - targetX) ? cur : best;
  }, ks[0]);
}

function getChipBaseKs(chart) {
  // Use full history K-lines for chip distribution.
  // Accumulation cutoff is controlled by reference K (crosshair/latest), not by replay step.
  if (chart.kline_all && chart.kline_all.length > 0) return chart.kline_all;
  if (chipKlineAllCache && chipKlineAllCache.length > 0) return chipKlineAllCache;
  return chart.kline || [];
}

/** 主图 K 线 bar 映射到筹码底座 ksAll（kline_all 与 kline 的 x 刻度常不一致，须按时间对齐） */
function mapChartBarToKsAll(bar, ksAll) {
  if (!bar || !ksAll || ksAll.length === 0) return null;
  const refT = String(bar.t || "").trim();
  const cb = chipTimeComparable(refT);
  if (cb != null) {
    for (let i = ksAll.length - 1; i >= 0; i--) {
      if (chipTimeComparable(ksAll[i].t) === cb) return ksAll[i];
    }
  }
  if (refT) {
    for (let i = ksAll.length - 1; i >= 0; i--) {
      if (String(ksAll[i].t || "").trim() === refT) return ksAll[i];
    }
  }
  const bx = Number(bar.x);
  if (Number.isFinite(bx)) {
    const barCmp = chipTimeComparable(refT);
    const firstCmp = chipTimeComparable(ksAll[0] && ksAll[0].t);
    // 全历史筹码底座通常早于主图会话；此时主图 x=0 不能拿来匹配底座 x=0。
    if (barCmp != null && firstCmp != null && firstCmp < barCmp) return null;
    let best = ksAll[0];
    let bestD = Math.abs(Number(best.x) - bx);
    for (let i = 1; i < ksAll.length; i++) {
      const d = Math.abs(Number(ksAll[i].x) - bx);
      if (d < bestD) {
        best = ksAll[i];
        bestD = d;
      }
    }
    if (best && bestD <= 1) return best;
  }
  return null;
}

/** 解析 K 线时间为可比毫秒（UTC）；失败时 chipTimeLe 回退字符串比较。分钟线、混合格式时比纯字符串更稳。 */
function chipTimeComparable(t) {
  const s = String(t || "").trim();
  if (!s) return null;
  const m = s.match(/^(\d{4})\/(\d{1,2})\/(\d{1,2})(?:\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?/);
  if (m) {
    const y = +m[1], mo = +m[2], d = +m[3];
    const hh = m[4] != null ? +m[4] : 0, mm = m[5] != null ? +m[5] : 0, ss = m[6] != null ? +m[6] : 0;
    return Date.UTC(y, mo - 1, d, hh, mm, ss);
  }
  const iso = Date.parse(s.replace(/\//g, "-"));
  return Number.isFinite(iso) ? iso : null;
}

function chipTimeLe(barTime, refTime) {
  const cb = chipTimeComparable(barTime);
  const cr = chipTimeComparable(refTime);
  if (cb != null && cr != null) return cb <= cr;
  return String(barTime || "") <= String(refTime || "");
}

function getReferenceKByBounds(chart, xMin, xMax, w) {
  const ksAll = getChipBaseKs(chart);
  if (!chart || !chart.kline || chart.kline.length === 0) {
    return ksAll.length > 0 ? ksAll[ksAll.length - 1] : null;
  }
  if (crosshairX === null) {
    return chart.kline[chart.kline.length - 1];
  }
  const plotW = Math.max(1, w - PAD_L - PAD_R);
  const clampedX = Math.max(PAD_L, Math.min(w - PAD_R, crosshairX));
  const targetX = xMin + ((clampedX - PAD_L) / plotW) * (xMax - xMin);
  // 十字锚定在主图 kline x 域（与 OHLC/BSP/射线一致）；筹码再在 drawChips 内映射 kline_all
  const visibleKs = getVisibleKs(chart, xMin, xMax);
  const klSrc = chart.kline && chart.kline.length > 0 ? chart.kline : visibleKs;
  const refFromChart = nearestKByX(visibleKs.length > 0 ? visibleKs : klSrc, targetX);
  return refFromChart || chart.kline[chart.kline.length - 1];
}

function getReferenceK(chart, s) {
  return getReferenceKByBounds(chart, s.xMin, s.xMax, s.w);
}

/** 十字线/末根对应的指标行（按主图 K 的 x 吸附） */
function resolveIndicatorRowForDisplay(chart, s, visibleInd) {
  if (!visibleInd || visibleInd.length === 0) return null;
  const refK = getReferenceK(chart, s);
  if (!refK) return visibleInd[visibleInd.length - 1];
  const refX = Number(refK.x);
  const exact = visibleInd.find((i) => Number(i.x) === refX);
  if (exact) return exact;
  return nearestKByX(visibleInd, refX);
}

function chipSessionIdentity(payload) {
  const sc = sessionConfig || {};
  return [
    String((payload && payload.code) || sc.code || ""),
    String(sc.begin || ""),
    String(sc.end || ""),
    String(sc.k_type || sc.kType || ""),
  ].join("|");
}

function chipKlineAllFirstTime(arr) {
  return arr && arr.length > 0 ? String(arr[0].t || "") : "";
}

/** 新下发的 kline_all 是否应覆盖旧缓存（更早起点或更长） */
function shouldPreferChipKlineAll(candidate, cached) {
  if (!cached || !cached.length) return true;
  if (!candidate || !candidate.length) return false;
  const c0 = chipTimeComparable(chipKlineAllFirstTime(candidate));
  const o0 = chipTimeComparable(chipKlineAllFirstTime(cached));
  if (c0 != null && o0 != null && c0 < o0) return true;
  return candidate.length > cached.length;
}

/** 按时间合并多段 kline_all（跨日加载时累加筹码底座） */
function mergeChipKlineAllByTime(a, b) {
  const rowsA = Array.isArray(a) ? a : [];
  const rowsB = Array.isArray(b) ? b : [];
  if (rowsA.length === 0) return rowsB.slice();
  if (rowsB.length === 0) return rowsA.slice();
  const map = new Map();
  for (const row of [...rowsA, ...rowsB]) {
    if (!row) continue;
    const key = String(row.t || "").trim();
    if (!key) continue;
    map.set(key, row);
  }
  const merged = Array.from(map.values());
  merged.sort((x, y) => {
    const cx = chipTimeComparable(x.t);
    const cy = chipTimeComparable(y.t);
    if (cx != null && cy != null) return cx - cy;
    return String(x.t || "").localeCompare(String(y.t || ""));
  });
  return merged;
}

function normalizeChipKlineAllX(arr) {
  return (arr || []).map((bar, i) => {
    const row = { ...bar };
    row.x = i;
    return row;
  });
}

function getPanelByY(s, y) {
  if (!s.subPanels || s.subPanels.length === 0) return null;
  return s.subPanels.find((panel) => y >= panel.top && y <= panel.bottom) || null;
}

/** 双周期子画布离屏时 clientWidth 常为 0，用 width/dpr 推算 CSS 像素尺寸（须配合 paneCtx.setTransform(dpr)） */
function readCanvasCssSize(cv) {
  const dpr = (typeof window !== "undefined" && window.devicePixelRatio) || 1;
  let w = cv.clientWidth;
  let h = cv.clientHeight;
  if (!w || !h) {
    w = Math.max(1, cv.width / dpr);
    h = Math.max(1, cv.height / dpr);
  }
  return { w, h };
}

function toScaler(chart, xMin, xMax, dualChartIdHint) {
  const { w, h } = scalerCssDimensions(dualChartIdHint);

  const xToTime = {};
  for (const k of chart.kline) {
    xToTime[k.x] = k.t;
  }

  let visibleK = getVisibleKs(chart, xMin, xMax);

  let yMin = Infinity;
  let yMax = -Infinity;
  for (const k of visibleK) {
    if (k.l < yMin) yMin = k.l;
    if (k.h > yMax) yMax = k.h;
  }
  
  const indicatorCfg = getIndicatorConfig();
  const mainTypes = indicatorCfg.mainTypes || [];
  const mainTypeSet = new Set(mainTypes.map((m) => m.type));
  const visibleInd = (chart.indicators || []).filter(i => i.x >= xMin && i.x <= xMax);
  if (mainTypeSet.has("boll")) {
    for (const i of visibleInd) {
      if (i.boll.up > yMax) yMax = i.boll.up;
      if (i.boll.down < yMin) yMin = i.boll.down;
    }
  }
  if (mainTypeSet.has("trendline") && chart.trend_lines) {
    for (const tl of chart.trend_lines) {
      const yAtMin = tl.y0 + tl.slope * (xMin - tl.x0);
      const yAtMax = tl.y0 + tl.slope * (xMax - tl.x0);
      if (isFinite(yAtMin)) {
        if (yAtMin > yMax) yMax = yAtMin;
        if (yAtMin < yMin) yMin = yAtMin;
      }
      if (isFinite(yAtMax)) {
        if (yAtMax > yMax) yMax = yAtMax;
        if (yAtMax < yMin) yMin = yAtMax;
      }
    }
  }
  if (chartConfig.rhythmLine && chartConfig.rhythmLine.enabled && chart.rhythm_lines) {
    for (const rl of chart.rhythm_lines) {
      if (!isRhythmLineVisible(rl)) continue;
      if (!intersects(rl, xMin, xMax)) continue;
      const yVal = Number(rl.y1);
      if (!Number.isFinite(yVal)) continue;
      if (yVal > yMax) yMax = yVal;
      if (yVal < yMin) yMin = yVal;
    }
  }
  if (!isFinite(yMin) || !isFinite(yMax)) {
    yMin = 0;
    yMax = 1;
  }
  const baseYSpan = Math.max(1e-6, yMax - yMin);
  const midY = (yMax + yMin) / 2;
  const zoomedSpan = baseYSpan / viewYZoomRatio;
  yMin = midY - zoomedSpan / 2;
  yMax = midY + zoomedSpan / 2;

  if (viewYShiftRatio !== 0) {
    const yOffset = baseYSpan * viewYShiftRatio;
    yMin += yOffset;
    yMax += yOffset;
  }

  const xSpan = Math.max(1, xMax - xMin);
  const ySpan = Math.max(1e-6, yMax - yMin);

  const padB = getLayoutPadB();
  const totalChartH = h - PAD_T - padB;
  const subCharts = indicatorCfg.subCharts;
  let subPanelGap = 18;
  let subPanelH = 90;
  const maxSubAreaH = totalChartH * 0.55;
  const totalNeed = subCharts.length * (subPanelH + subPanelGap);
  if (subCharts.length > 0 && totalNeed > maxSubAreaH) {
    const scale = maxSubAreaH / totalNeed;
    subPanelGap *= scale;
    subPanelH *= scale;
  }
  const totalSubH = subCharts.length > 0 ? subCharts.length * (subPanelH + subPanelGap) : 0;
  const plotBottomY = h - padB - totalSubH;
  const plotH = plotBottomY - PAD_T;
  const plotW = w - PAD_L - PAD_R;
  const subPanels = [];
  let panelTop = plotBottomY;
  for (const subCfg of subCharts) {
    panelTop += subPanelGap;
    const top = panelTop;
    const bottom = top + subPanelH;
    subPanels.push({
      slot: subCfg.slot,
      type: subCfg.type,
      top,
      bottom,
      height: subPanelH,
    });
    panelTop = bottom;
  }
  const contentBottom = subPanels.length > 0 ? subPanels[subPanels.length - 1].bottom : plotBottomY;

  return {
    visibleK,
    visibleInd,
    xToTime,
    w,
    h,
    xMin,
    xMax,
    yMin,
    yMax,
    plotBottomY,
    plotH,
    plotW,
    subPanels,
    contentBottom,
    mainTypes,
    x: (x) => PAD_L + ((x - xMin) / xSpan) * plotW,
    y: (y) => PAD_T + ((yMax - y) / ySpan) * plotH,
    yFromPx: (py) => yMax - ((py - PAD_T) / Math.max(1, plotH)) * ySpan,
  };
}

/** 根画布上的鼠标/键盘交互：双图时传入当前子窗 hint，保证 plotW 与激活 pane 一致 */
function scalerForActivePayloadChart(chart, xMin, xMax) {
  const hint = isDualRuntimeReady() ? dualActiveChartId : undefined;
  return toScaler(chart, xMin, xMax, hint);
}

function chooseAutoYAxisStep(range, targetTicks) {
  if (!Number.isFinite(range) || range <= 0) return 1;
  const rough = range / Math.max(1, targetTicks);
  const exponent = Math.floor(Math.log10(Math.max(rough, 1e-9)));
  const base = Math.pow(10, exponent);
  const factors = [1, 2, 2.5, 5, 10];
  for (const f of factors) {
    const step = base * f;
    if (step >= rough) return step;
  }
  return base * 10;
}

function chooseAutoYDigits(step, maxDigits = 6) {
  if (!Number.isFinite(step) || step <= 0) return 2;
  const digits = Math.max(0, Math.ceil(-Math.log10(step)) + 1);
  return Math.min(maxDigits, digits);
}

function toDateLabel(raw, minuteLike) {
  const text = String(raw || "").trim();
  if (!text) return "-";
  if (minuteLike) return text.length >= 16 ? text.slice(0, 16) : text;
  if (text.length >= 10) return text.slice(0, 10);
  return text;
}

function isMinuteLikeXAxisLabel(raw) {
  const text = String(raw || "");
  return text.includes(":");
}

function drawAxes(s) {
  const yBase = s.plotBottomY;
  const xLeft = PAD_L;
  const xRight = s.w - PAD_R;

  // main axes
  ctx.strokeStyle = cssVar("--grid", "#e2e8f0");
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(xLeft, PAD_T);
  ctx.lineTo(xLeft, yBase);
  ctx.lineTo(xRight, yBase);
  ctx.stroke();

  // main y labels/ticks on both sides
  const yAutoMode = (chartConfig.yAxis.mode || "manual") === "auto";
  const yRange = Math.max(1e-9, s.yMax - s.yMin);
  const axisPxH = Math.max(1, s.plotBottomY - PAD_T);
  const targetTicks = Math.max(4, Math.min(18, Math.round(axisPxH / 64)));
  const tickStep = yAutoMode
    ? chooseAutoYAxisStep(yRange, targetTicks)
    : (chartConfig.yAxis.interval || 0.5);
  const yDigits = yAutoMode
    ? chooseAutoYDigits(tickStep, Number(chartConfig.yAxis.autoMaxDigits || 6))
    : 2;
  const startTick = Math.ceil(s.yMin / tickStep);
  const endTick = Math.floor(s.yMax / tickStep);
  ctx.save();
  ctx.strokeStyle = cssVar("--grid", "#e2e8f0");
  ctx.fillStyle = cssVar("--muted", "#475569");
  const yDensity = Math.max(0, Math.min(1, axisPxH / Math.max(1, targetTicks * 80)));
  const yFontSize = yAutoMode
    ? Math.round((Number(chartConfig.yAxis.autoMinFontSize || 10)) + ((Number(chartConfig.yAxis.autoMaxFontSize || 12) - Number(chartConfig.yAxis.autoMinFontSize || 10)) * yDensity))
    : (chartConfig.yAxis.fontSize || 12);
  const yFontWeight = yAutoMode
    ? (yDensity >= 0.65 ? (chartConfig.yAxis.autoSparseFontWeight || "bold") : (chartConfig.yAxis.autoDenseFontWeight || "normal"))
    : (chartConfig.yAxis.fontWeight || "normal");
  ctx.font = `${yFontWeight} ${yFontSize}px Consolas`;
  ctx.lineWidth = 1;
  for (let t = startTick; t <= endTick; t++) {
    const p = t * tickStep;
    const y = s.y(p);
    if (y < PAD_T || y > yBase) continue;
    ctx.globalAlpha = 0.2;
    ctx.beginPath();
    ctx.moveTo(xLeft, y);
    ctx.lineTo(xRight, y);
    ctx.stroke();
    ctx.globalAlpha = 1;
    ctx.beginPath();
    ctx.moveTo(xLeft - 4, y);
    ctx.lineTo(xLeft, y);
    ctx.moveTo(xRight, y);
    ctx.lineTo(xRight + 4, y);
    ctx.stroke();
    const txt = formatPriceText(p, yDigits);
    ctx.fillText(txt, 4, y + (yFontSize / 2.5));
    const tw = ctx.measureText(txt).width;
    ctx.fillText(txt, s.w - tw - 4, y + (yFontSize / 2.5));
  }
  ctx.restore();
  
  if (s.subPanels.length > 0) {
    ctx.font = "10px Consolas";
    for (const panel of s.subPanels) {
      ctx.beginPath();
      ctx.moveTo(xLeft, panel.top);
      ctx.lineTo(xLeft, panel.bottom);
      ctx.lineTo(xRight, panel.bottom);
      ctx.stroke();
      ctx.fillStyle = cssVar("--muted", "#475569");
      ctx.fillText(`#${panel.slot} ${panel.type.toUpperCase()}`, xLeft + 6, panel.top + 12);
    }
    drawXTicks(s, s.contentBottom);
  } else {
    drawXTicks(s, yBase);
  }
}

function drawXTicks(s, yPos) {
  const span = s.xMax - s.xMin;
  if (span <= 0) return;
  const xAutoMode = (chartConfig.xAxis.mode || "manual") === "auto";
  const minuteLike = isMinuteLikeXAxisLabel(s.xToTime[Math.round(s.xMin)] || s.xToTime[Math.round(s.xMax)] || "");
  const sampledLabel = toDateLabel(s.xToTime[Math.round(s.xMin)] || s.xToTime[Math.round(s.xMax)] || "", minuteLike);
  const approxLabelWidth = Math.max(30, sampledLabel.length * 7 + 10);
  const perBarPx = s.plotW / Math.max(1, span);
  const autoInterval = Math.max(1, Math.ceil(approxLabelWidth / Math.max(1, perBarPx)));
  const interval = xAutoMode ? autoInterval : (chartConfig.xAxis.interval || 10);
  const tickXs = [];
  const startX = Math.ceil(s.xMin / interval) * interval;
  for (let x = startX; x <= s.xMax; x += interval) {
    tickXs.push(x);
  }
  const uniq = [...new Set(tickXs)];

  ctx.save();
  const xDensity = Math.max(0, Math.min(1, perBarPx * interval / Math.max(approxLabelWidth, 1)));
  const xFontSize = xAutoMode
    ? Math.round((Number(chartConfig.xAxis.autoMinFontSize || 8)) + ((Number(chartConfig.xAxis.autoMaxFontSize || 12) - Number(chartConfig.xAxis.autoMinFontSize || 8)) * xDensity))
    : (chartConfig.xAxis.fontSize || 12);
  const xFontWeight = xAutoMode
    ? (xDensity >= 0.65 ? (chartConfig.xAxis.autoSparseFontWeight || "bold") : (chartConfig.xAxis.autoDenseFontWeight || "normal"))
    : (chartConfig.xAxis.fontWeight || "normal");
  ctx.font = `${xFontWeight} ${xFontSize}px Consolas`;
  const xRotationDeg = xAutoMode
    ? (xDensity < 0.55 ? Number(chartConfig.xAxis.autoDenseRotation || -90) : Number(chartConfig.xAxis.autoSparseRotation || -35))
    : Number(chartConfig.xAxis.rotation || -45);
  for (const x of uniq) {
    const xp = s.x(x);
    ctx.strokeStyle = cssVar("--grid", "#e2e8f0");
    ctx.beginPath();
    ctx.moveTo(xp, yPos);
    ctx.lineTo(xp, yPos + 4);
    ctx.stroke();

    const t = s.xToTime[x];
    if (!t) continue;
    const label = toDateLabel(t, minuteLike);
    ctx.save();
    ctx.translate(xp, yPos + 20);
    const rad = xRotationDeg * (Math.PI / 180);
    ctx.rotate(rad);
    ctx.fillStyle = cssVar("--muted", "#475569");
    ctx.fillText(label, 0, 0);
    ctx.restore();
  }
  ctx.restore();
}

function drawCrosshair(chart, s) {
  if (!crosshairEnabled || crosshairX === null || crosshairY === null) return;
  if (!chart || !chart.kline || chart.kline.length === 0) return;
  // 竖线以 crosshairX 为准（与 mousemove / 各 pane 缓存一致），避免 getReferenceK 与 s.x(refK.x) 二次映射把线钳到轴边「消失」
  const x = Math.max(PAD_L, Math.min(s.w - PAD_R, Number(crosshairX)));
  const y = Math.max(PAD_T, Math.min(s.contentBottom, crosshairY));
  if (!Number.isFinite(x) || !Number.isFinite(y)) {
    return;
  }
  let refK = getReferenceK(chart, s);
  if (!refK) {
    const tx = xFromPx(s, x);
    const vis = getVisibleKs(chart, s.xMin, s.xMax);
    refK = nearestKByX(vis.length ? vis : chart.kline, tx) || chart.kline[chart.kline.length - 1];
  }
  const t = refK.t || "-";
  const crossPrice = s.yFromPx(y);
  const bspTags = getBspAtX(chart, refK.x);
  const infoRows = [
    formatDateWithWeekday(t),
    `Open:  ${formatPriceText(refK.o)}`,
    `High:  ${formatPriceText(refK.h)}`,
    `Low:   ${formatPriceText(refK.l)}`,
    `Close: ${formatPriceText(refK.c)}`,
    bspTags.length > 0 ? `信号:${bspTags.join(" | ")}` : "信号:-",
  ];

  ctx.save();
  ctx.strokeStyle = getCfgColor(chartConfig.crosshair.color);
  ctx.lineWidth = chartConfig.crosshair.width;
  ctx.setLineDash([4, 4]);
  ctx.beginPath();
  ctx.moveTo(x, PAD_T);
  ctx.lineTo(x, s.contentBottom);
  ctx.moveTo(PAD_L, y);
  ctx.lineTo(s.w - PAD_R, y);
  ctx.stroke();
  ctx.setLineDash([]);

  // Dynamic horizontal-line price label on both y-axes.
  const crossFontSize = chartConfig.crosshair.fontSize;
  ctx.font = `bold ${crossFontSize}px Consolas`;
  const axisPrice = formatPriceText(crossPrice, 3);
  const axisPad = 8;
  const axisH = crossFontSize + 10;
  const axisW = ctx.measureText(axisPrice).width + axisPad * 2;
  const axisY = y - axisH / 2;
  const leftX = Math.max(2, PAD_L - axisW - 4);
  const rightX = s.w - PAD_R + 4;
  ctx.fillStyle = cssVar("--legendBg", "rgba(255,255,255,0.95)");
  ctx.strokeStyle = getCfgColor(chartConfig.crosshair.color);
  ctx.fillRect(leftX, axisY, axisW, axisH);
  ctx.strokeRect(leftX, axisY, axisW, axisH);
  ctx.fillRect(rightX, axisY, axisW, axisH);
  ctx.strokeRect(rightX, axisY, axisW, axisH);
  ctx.fillStyle = getCfgColor(chartConfig.crosshair.color);
  ctx.fillText(axisPrice, leftX + axisPad, y + (crossFontSize / 2) - 2);
  ctx.fillText(axisPrice, rightX + axisPad, y + (crossFontSize / 2) - 2);

  // OHLC + date + weekday + BSP
  ctx.font = `bold ${crossFontSize}px Consolas`;
  let maxW = 0;
  for (const row of infoRows) {
    const w = ctx.measureText(row).width;
    if (w > maxW) maxW = w;
  }
  const cardPad = 10;
  const rowH = crossFontSize + 6;
  const boxW = Math.max(170 + (crossFontSize - 12) * 10, maxW + cardPad * 2);
  const boxH = cardPad * 2 + rowH * infoRows.length;
  let boxX = x + 12;
  if (boxX + boxW > s.w - PAD_R - 4) boxX = x - boxW - 12;
  boxX = Math.max(PAD_L + 4, Math.min(s.w - PAD_R - boxW - 4, boxX));
  let boxY = y - boxH - 10;
  boxY = Math.max(PAD_T + 4, Math.min(s.contentBottom - boxH - 4, boxY));

  ctx.fillStyle = cssVar("--legendBg", "rgba(255,255,255,0.95)");
  ctx.strokeStyle = getCfgColor(chartConfig.crosshair.color);
  ctx.fillRect(boxX, boxY, boxW, boxH);
  ctx.strokeRect(boxX, boxY, boxW, boxH);
  ctx.fillStyle = getCfgColor(chartConfig.crosshair.color);
  for (let i = 0; i < infoRows.length; i++) {
    ctx.fillText(infoRows[i], boxX + cardPad, boxY + cardPad + crossFontSize + i * rowH);
  }
  ctx.restore();
}

function drawGridLines(s) {
  // Keep chart background clean: no horizontal grid lines.
}

function tryDrawChipProfileFromEngine(chart, s) {
  if (lastPayload && lastPayload.chart_mode === "dual" && chart !== lastPayload.chart) return false;
  // 分笔累计已有 chip_tick_bins.s/b，走前端按鼠标锚点重算，避免引擎快照丢 B/S 颜色。
  if (lastPayload && lastPayload.chip_basis === "tick_accum_driver") return false;
  if (crosshairX !== null && crosshairY !== null && crosshairY <= s.plotBottomY && !isChipReplayStepping(lastPayload)) return false;
  const profile = (lastPayload && lastPayload.chip_profile && Array.isArray(lastPayload.chip_profile.prices))
    ? lastPayload.chip_profile
    : chipProfileCache;
  if (!profile || !Array.isArray(profile.prices) || profile.prices.length === 0) return false;
  if (systemConfig && systemConfig.performanceEngineMode === "python_legacy") return false;
  const priceStep = Number(profile.bucket_step || chartConfig.chip.bucketStep || 0.1);
  const cfgStep = Number(chartConfig.chip.bucketStep || 0.1);
  if (Number.isFinite(cfgStep) && Number.isFinite(priceStep) && Math.abs(cfgStep - priceStep) > Math.max(1e-9, cfgStep * 0.001)) {
    return false;
  }
  const prices = profile.prices || [];
  const arrS = profile.s || [];
  const arrB = profile.b || [];
  const arrT = profile.total || [];
  let maxTotVisible = 0;
  const stretchExp = getChipStretchExponent();
  const stretchVol = (v) => Math.pow(Math.max(0, Number(v) || 0), stretchExp);
  for (let i = 0; i < prices.length; i++) {
    const p = Number(prices[i]);
    if (!Number.isFinite(p) || p < s.yMin || p > s.yMax) continue;
    const vT = stretchVol(arrT[i]);
    if (vT > maxTotVisible) maxTotVisible = vT;
  }
  if (!(maxTotVisible > 0)) return false;
  const chipW = Math.max(96, Math.min(220, s.plotW * 0.2));
  const xR = s.w - PAD_R - 2;
  const xL = xR - chipW;
  const xOrig = xR - 2;
  const sFill = getCfgColor(chartConfig.chip.sColor || "rgba(34,197,94,0.78)");
  const bFill = getCfgColor(chartConfig.chip.bColor || "rgba(220,38,38,0.78)");
  const bg = cssVar("--chipBg", "rgba(148,163,184,0.12)");
  const edge = cssVar("--chipEdge", "rgba(59,130,246,0.75)");
  ctx.save();
  ctx.fillStyle = bg;
  ctx.fillRect(xL, PAD_T, chipW, s.plotBottomY - PAD_T);
  for (let i = 0; i < prices.length; i++) {
    const p = Number(prices[i]);
    if (!Number.isFinite(p) || p < s.yMin || p > s.yMax) continue;
    const vSraw = Number(arrS[i] || 0);
    const vBraw = Number(arrB[i] || 0);
    const totRaw = vSraw + vBraw;
    if (!(totRaw > 0)) continue;
    const yTop = s.y(p + priceStep);
    const yBot = s.y(p);
    const h = Math.max(1, yBot - yTop);
    const lenTotal = (stretchVol(totRaw) / maxTotVisible) * chipW;
    const lenB = totRaw > 1e-12 ? lenTotal * (vBraw / totRaw) : 0;
    const lenS = lenTotal - lenB;
    if (lenB > 0) {
      ctx.fillStyle = bFill;
      ctx.fillRect(xOrig - lenB, yTop, lenB, h);
    }
    if (lenS > 0) {
      ctx.fillStyle = sFill;
      ctx.fillRect(xOrig - lenB - lenS, yTop, lenS, h);
    }
  }
  ctx.strokeStyle = edge;
  ctx.lineWidth = 1;
  ctx.strokeRect(xL, PAD_T, chipW, s.plotBottomY - PAD_T);
  ctx.fillStyle = cssVar("--legendText", "#0f172a");
  ctx.font = "12px Consolas";
  const mode = lastPayload && lastPayload.engine_mode ? String(lastPayload.engine_mode) : "engine";
  ctx.fillText(`筹码(S/B)极速(${mode})`, xL + 6, PAD_T + 14);
  if (chartConfig.chip.peakLineEnabled !== false) {
    const peaks = [];
    for (let i = 1; i < prices.length - 1; i++) {
      const cur = Number(arrT[i] || 0);
      if (!(cur > Number(arrT[i - 1] || 0) && cur > Number(arrT[i + 1] || 0))) continue;
      const p = Number(prices[i]);
      if (p < s.yMin || p > s.yMax) continue;
      peaks.push(p);
    }
    if (peaks.length > 0) {
      ctx.save();
      ctx.strokeStyle = getCfgColor(chartConfig.chip.peakLineColor || "#2563eb");
      ctx.lineWidth = Number(chartConfig.chip.peakLineWidth || 1.2);
      ctx.setLineDash(getTradeLineDash(chartConfig.chip.peakLineStyle || "dashed"));
      for (const p of peaks) {
        const yPx = s.y(p);
        ctx.beginPath();
        ctx.moveTo(xL, yPx);
        ctx.lineTo(PAD_L, yPx);
        ctx.stroke();
      }
      ctx.restore();
    }
  }
  ctx.restore();
  return true;
}

function drawChips(chart, s) {
  if (!chartConfig.chip.enabled) return;
  if (tryDrawChipProfileFromEngine(chart, s)) return;
  const ksAll = getChipBaseKs(chart);
  const visibleKs = s.visibleK || [];
  const latestVisibleK = visibleKs.length > 0 ? visibleKs[visibleKs.length - 1] : ((chart.kline && chart.kline.length > 0) ? chart.kline[chart.kline.length - 1] : null);
  const stepping = isChipReplayStepping(lastPayload);
  const crossChipOn = crosshairX !== null && !stepping;
  const refMode = String(chartConfig.chip.peakRefMode || "latest_visible");
  const getTurnRef = (type) => {
    const arr = type === "seg" ? (chart.seg || []) : (chart.bi || []);
    let best = null;
    for (const l of arr) {
      if (!l || !Number.isFinite(l.x2)) continue;
      if (!latestVisibleK || l.x2 > latestVisibleK.x) continue;
      if (!best || l.x2 > best.x) best = { x: l.x2 };
    }
    if (!best) return null;
    return (chart.kline || []).find((k) => k.x === best.x) || null;
  };
  let refK = null;
  let chipCutoffByKsX = false;
  if (stepping && chart.kline && chart.kline.length > 0) {
    const tail = chart.kline[chart.kline.length - 1];
    const mappedTail = mapChartBarToKsAll(tail, ksAll);
    refK = mappedTail || tail;
    chipCutoffByKsX = !!mappedTail;
  } else if (crossChipOn) {
    const anchorOnChart = getReferenceK(chart, s);
    if (anchorOnChart) {
      const mappedCross = mapChartBarToKsAll(anchorOnChart, ksAll);
      refK = mappedCross || anchorOnChart;
      chipCutoffByKsX = !!mappedCross;
    }
  }
  if (!refK) {
    if (refMode === "seg_turn") refK = getTurnRef("seg");
    else if (refMode === "bi_turn") refK = getTurnRef("bi");
    if (!refK && latestVisibleK) refK = mapChartBarToKsAll(latestVisibleK, ksAll) || latestVisibleK;
    if (!refK) refK = ksAll.length > 0 ? ksAll[ksAll.length - 1] : null;
  }
  const refText = `日期:${refK?.t || "-"}`;
  if (ksAll.length === 0 || !refK) return;
  const priceStep = chartConfig.chip.bucketStep || 0.1;
  const stepMul = 1 / priceStep;
  const refT = String(refK.t || "");
  // 映射到 kline_all 且 ref 带有效 bar x 时用 x 截止；若 kline_all 全为占位 x（如 -1），x<=rx 会把全集算进来，须改按时间截止
  const refKX = Number(refK.x);
  const ksUsesSequentialX =
    ksAll.length > 0 &&
    Number(ksAll[0].x) === 0 &&
    Number(ksAll[ksAll.length - 1].x) === ksAll.length - 1;
  const useXCutoff = chipCutoffByKsX && Number.isFinite(refKX) && refKX >= 0 && ksUsesSequentialX;
  let useKs;
  if (useXCutoff) {
    useKs = ksAll.filter((k) => Number(k.x) <= refKX);
    if (useKs.length === 0) useKs = ksAll.length ? ksAll.slice(0, 1) : [];
  } else {
    useKs = refT ? ksAll.filter((k) => chipTimeLe(k.t, refT)) : ksAll;
  }
  // #region agent log
  __agentDebugLog(
    "H5",
    "a_replay_trainer.py:drawChips:cutoff",
    "筹码截止区间计算",
    {
      ksAllCount: ksAll.length,
      ksAllFirstT: ksAll.length > 0 ? String(ksAll[0].t || "") : "",
      ksAllLastT: ksAll.length > 0 ? String(ksAll[ksAll.length - 1].t || "") : "",
      refT,
      refX: Number.isFinite(refKX) ? refKX : null,
      useXCutoff,
      useKsCount: useKs.length,
      useKsFirstT: useKs.length > 0 ? String(useKs[0].t || "") : "",
      useKsLastT: useKs.length > 0 ? String(useKs[useKs.length - 1].t || "") : "",
      crossChipOn,
      stepping,
    },
    `all:${ksAll.length}|use:${useKs.length}|ref:${refT}|xCut:${useXCutoff ? 1 : 0}`,
    250
  );
  // #endregion

  let allMin = Infinity;
  let allMax = -Infinity;
  for (const k of useKs) {
    if (k.l < allMin) allMin = k.l;
    if (k.h > allMax) allMax = k.h;
    const tb = k.chip_tick_bins;
    if (tb && Array.isArray(tb.p)) {
      for (const pr of tb.p) {
        const pv = Number(pr);
        if (!Number.isFinite(pv)) continue;
        if (pv < allMin) allMin = pv;
        if (pv > allMax) allMax = pv;
      }
    }
  }
  if (!isFinite(allMin) || !isFinite(allMax)) return;
  const minTick = Math.floor(allMin * stepMul);
  const maxTick = Math.ceil(allMax * stepMul);
  const tickCount = Math.max(1, maxTick - minTick + 1);
  const arrS = new Array(tickCount).fill(0);
  const arrB = new Array(tickCount).fill(0);
  const arrT = new Array(tickCount).fill(0);

  for (const k of useKs) {
    const tickBins = k.chip_tick_bins;
    if (
      tickBins &&
      Array.isArray(tickBins.p) &&
      Array.isArray(tickBins.s) &&
      Array.isArray(tickBins.b) &&
      tickBins.p.length === tickBins.s.length &&
      tickBins.p.length === tickBins.b.length
    ) {
      for (let j = 0; j < tickBins.p.length; j++) {
        const p = Number(tickBins.p[j]);
        const sV = Number(tickBins.s[j]);
        const bV = Number(tickBins.b[j]);
        if (!Number.isFinite(p) || !Number.isFinite(sV) || !Number.isFinite(bV)) continue;
        if (sV <= 0 && bV <= 0) continue;
        const bi = Math.floor(p * stepMul);
        if (bi < minTick || bi > maxTick) continue;
        const idx = bi - minTick;
        if (sV > 0) arrS[idx] += sV;
        if (bV > 0) arrB[idx] += bV;
        arrT[idx] += sV + bV;
      }
      continue;
    }

    // 兼容旧字段：无 s/b 则全部当作右红 B
    if (tickBins && Array.isArray(tickBins.p) && Array.isArray(tickBins.w) && tickBins.p.length === tickBins.w.length) {
      for (let j = 0; j < tickBins.p.length; j++) {
        const p = Number(tickBins.p[j]);
        const w = Number(tickBins.w[j]);
        if (!Number.isFinite(p) || !Number.isFinite(w) || w <= 0) continue;
        const bi = Math.floor(p * stepMul);
        if (bi < minTick || bi > maxTick) continue;
        const idx = bi - minTick;
        arrB[idx] += w;
        arrT[idx] += w;
      }
      continue;
    }

    // 多周期离线：服务端 chip_basis=tick_accum_driver，仅分桶累加；禁止 OHLC 三角分摊
    if (lastPayload && lastPayload.chip_basis === "tick_accum_driver") {
      continue;
    }

    const low = Math.min(k.l, k.h);
    const high = Math.max(k.l, k.h);
    const mode = Math.min(high, Math.max(low, k.c)); // close作为筹码峰值
    let vol = Number(k.v);
    if (!Number.isFinite(vol) || vol <= 0) vol = 1;

    const i0 = Math.max(minTick, Math.floor(low * stepMul));
    const i1 = Math.min(maxTick, Math.ceil(high * stepMul));
    if (i1 < i0) continue;
    if (Math.abs(high - low) < 1e-12) {
      arrB[i0 - minTick] += vol;
      arrT[i0 - minTick] += vol;
      continue;
    }

    let sumW = 0;
    const ws = [];
    for (let t = i0; t <= i1; t++) {
      const p = t / stepMul;
      let w = 0;
      if (Math.abs(mode - low) < 1e-12) {
        w = (high - p) / Math.max(1e-12, high - low);
      } else if (Math.abs(high - mode) < 1e-12) {
        w = (p - low) / Math.max(1e-12, high - low);
      } else if (p <= mode) {
        w = (p - low) / Math.max(1e-12, mode - low);
      } else {
        w = (high - p) / Math.max(1e-12, high - mode);
      }
      w = Math.max(0, w);
      ws.push(w);
      sumW += w;
    }
    if (sumW <= 1e-12) continue;
    for (let t = i0; t <= i1; t++) {
      const w = ws[t - i0];
      if (w <= 0) continue;
      const addV = (w / sumW) * vol;
      arrB[t - minTick] += addV;
      arrT[t - minTick] += addV;
    }
  }

  // Visual-only stretch (monotonic): keep all historical chips unchanged,
  // only amplify contrast on rendering.
  const stretchExp = getChipStretchExponent();
  const stretchVol = (v) => Math.pow(Math.max(0, v), stretchExp);
  // 与旧版单色筹码一致：按 (S+B) 拉伸后取最大柱长；再在柱内按比例分 B(靠右原点) / S(在 B 左侧)
  let maxTotVisible = 0;
  for (let i = 0; i < tickCount; i++) {
    const p = (minTick + i) / stepMul;
    if (p < s.yMin || p > s.yMax) continue;
    const tot = arrS[i] + arrB[i];
    const vT = stretchVol(tot);
    if (vT > maxTotVisible) maxTotVisible = vT;
  }
  if (maxTotVisible <= 0) return;
  const chipW = Math.max(96, Math.min(220, s.plotW * 0.2));
  const xR = s.w - PAD_R - 2;
  const xL = xR - chipW;
  const xOrig = xR - 2; // 筹码峰右端锚点，柱体向左延伸
  const sFill = getCfgColor(chartConfig.chip.sColor || "rgba(34,197,94,0.78)"); // S: 左绿
  const bFill = getCfgColor(chartConfig.chip.bColor || "rgba(220,38,38,0.78)"); // B: 右红
  const bg = cssVar("--chipBg", "rgba(148,163,184,0.12)");
  const edge = cssVar("--chipEdge", "rgba(59,130,246,0.75)");

  ctx.save();
  ctx.fillStyle = bg;
  ctx.fillRect(xL, PAD_T, chipW, s.plotBottomY - PAD_T);
  for (let i = 0; i < tickCount; i++) {
    const p = (minTick + i) / stepMul;
    if (p < s.yMin || p > s.yMax) continue;
    const vSraw = arrS[i];
    const vBraw = arrB[i];
    const totRaw = vSraw + vBraw;
    if (!(totRaw > 0)) continue;
    const yTop = s.y(p + priceStep);
    const yBot = s.y(p);
    const h = Math.max(1, yBot - yTop);
    const vT = stretchVol(totRaw);
    const lenTotal = maxTotVisible > 0 ? (vT / maxTotVisible) * chipW : 0;
    const lenB = totRaw > 1e-12 ? lenTotal * (vBraw / totRaw) : 0;
    const lenS = lenTotal - lenB;
    if (lenB > 0) {
      ctx.fillStyle = bFill;
      ctx.fillRect(xOrig - lenB, yTop, lenB, h);
    }
    if (lenS > 0) {
      ctx.fillStyle = sFill;
      ctx.fillRect(xOrig - lenB - lenS, yTop, lenS, h);
    }
  }
  ctx.strokeStyle = edge;
  ctx.lineWidth = 1;
  ctx.strokeRect(xL, PAD_T, chipW, s.plotBottomY - PAD_T);
  ctx.fillStyle = cssVar("--legendText", "#0f172a");
  ctx.font = "12px Consolas";
  ctx.fillText(`筹码(S/B)(${refText})`, xL + 6, PAD_T + 14);
  const peaks = [];
  for (let i = 1; i < tickCount - 1; i++) {
    const cur = arrT[i];
    if (!(cur > arrT[i - 1] && cur > arrT[i + 1])) continue;
    const p = (minTick + i) / stepMul;
    if (p < s.yMin || p > s.yMax) continue;
    peaks.push(p);
  }
  if (peaks.length > 0) {
    ctx.save();
    ctx.strokeStyle = getCfgColor(chartConfig.chip.peakLineColor || "#2563eb");
    ctx.lineWidth = Number(chartConfig.chip.peakLineWidth || 1.2);
    ctx.setLineDash(getTradeLineDash(chartConfig.chip.peakLineStyle || "dashed"));
    if (chartConfig.chip.peakLineEnabled !== false) {
      for (const p of peaks) {
        const yPx = s.y(p);
        ctx.beginPath();
        ctx.moveTo(xL, yPx);
        ctx.lineTo(PAD_L, yPx);
        ctx.stroke();
      }
    }
    ctx.restore();
  }
  ctx.restore();
}

const _wickTexturePatternCache = new Map();
function hexToRgbComponents(hex) {
  let h = String(hex || "")
    .trim()
    .replace(/^#/, "");
  if (h.length === 3) h = h.split("").map((c) => c + c).join("");
  if (h.length !== 6 || !/^[0-9a-fA-F]+$/.test(h)) return { r: 148, g: 163, b: 184 };
  return { r: parseInt(h.slice(0, 2), 16), g: parseInt(h.slice(2, 4), 16), b: parseInt(h.slice(4, 6), 16) };
}

function normalizeWickStyle(v) {
  const s = String(v || "grid").toLowerCase();
  if (["grid", "dots", "hatch", "shade", "soft"].includes(s)) return s;
  return "grid";
}

/** 影线区域填充用重复纹理（与实体同宽的一体化粗影线） */
function getWickTexturePattern(ctx2d, style, colorHex) {
  const k = `${style}|${colorHex}`;
  let p = _wickTexturePatternCache.get(k);
  if (p) return p;
  const tile = document.createElement("canvas");
  tile.width = 12;
  tile.height = 12;
  const t = tile.getContext("2d");
  if (!t) return null;
  const { r, g, b } = hexToRgbComponents(colorHex);
  if (style === "soft") {
    t.fillStyle = `rgba(${r},${g},${b},0.22)`;
    t.fillRect(0, 0, 12, 12);
  } else if (style === "shade") {
    const grd = t.createLinearGradient(0, 0, 12, 0);
    grd.addColorStop(0, `rgba(${r},${g},${b},0.12)`);
    grd.addColorStop(0.5, `rgba(${r},${g},${b},0.45)`);
    grd.addColorStop(1, `rgba(${r},${g},${b},0.12)`);
    t.fillStyle = grd;
    t.fillRect(0, 0, 12, 12);
  } else if (style === "dots") {
    t.fillStyle = `rgba(${r},${g},${b},0.06)`;
    t.fillRect(0, 0, 12, 12);
    t.fillStyle = `rgba(${r},${g},${b},0.55)`;
    for (let i = 0; i < 12; i += 3) for (let j = 0; j < 12; j += 3) t.fillRect(i, j, 1.2, 1.2);
  } else if (style === "hatch") {
    t.fillStyle = `rgba(${r},${g},${b},0.08)`;
    t.fillRect(0, 0, 12, 12);
    t.strokeStyle = `rgba(${r},${g},${b},0.38)`;
    t.lineWidth = 1;
    t.beginPath();
    for (let d = -12; d < 24; d += 4) {
      t.moveTo(d, 0);
      t.lineTo(d + 12, 12);
    }
    t.stroke();
  } else {
    t.fillStyle = `rgba(${r},${g},${b},0.08)`;
    t.fillRect(0, 0, 12, 12);
    t.strokeStyle = `rgba(${r},${g},${b},0.35)`;
    t.lineWidth = 1;
    t.beginPath();
    for (let i = 0; i <= 12; i += 6) {
      t.moveTo(i, 0);
      t.lineTo(i, 12);
    }
    for (let j = 0; j <= 12; j += 6) {
      t.moveTo(0, j);
      t.lineTo(12, j);
    }
    t.moveTo(0, 0);
    t.lineTo(12, 12);
    t.stroke();
  }
  try {
    p = ctx2d.createPattern(tile, "repeat");
  } catch {
    p = null;
  }
  _wickTexturePatternCache.set(k, p);
  return p;
}

/** 多周期粗层：实体/上下影线/缠论线透明度与影线纹理（来自 multiOverlay） */
function resolveCoarseOverlayPaintOpts(mo, ktKey) {
  const moO = mo || {};
  const L = (moO.layers && moO.layers[ktKey]) || {};
  const da = Number(moO.defaultAlpha);
  const baseLine = Number.isFinite(da) ? Math.min(1, Math.max(0.05, da)) : 0.58;
  const lineA = Number(L.lineAlpha != null ? L.lineAlpha : L.alpha != null ? L.alpha : baseLine);
  const bodyA = Number(
    L.bodyAlpha != null ? L.bodyAlpha : moO.defaultCoarseBodyAlpha != null ? moO.defaultCoarseBodyAlpha : 0.42
  );
  const upA = Number(
    L.upperShadowAlpha != null
      ? L.upperShadowAlpha
      : moO.defaultCoarseUpperShadowAlpha != null
        ? moO.defaultCoarseUpperShadowAlpha
        : 0.55
  );
  const lowA = Number(
    L.lowerShadowAlpha != null
      ? L.lowerShadowAlpha
      : moO.defaultCoarseLowerShadowAlpha != null
        ? moO.defaultCoarseLowerShadowAlpha
        : 0.55
  );
  return {
    lineAlpha: Math.min(1, Math.max(0.05, Number.isFinite(lineA) ? lineA : baseLine)),
    bodyAlpha: Math.min(1, Math.max(0.05, Number.isFinite(bodyA) ? bodyA : 0.42)),
    upperShadowAlpha: Math.min(1, Math.max(0.05, Number.isFinite(upA) ? upA : 0.55)),
    lowerShadowAlpha: Math.min(1, Math.max(0.05, Number.isFinite(lowA) ? lowA : 0.55)),
    upperStyle: normalizeWickStyle(L.upperShadowStyle || moO.defaultUpperShadowStyle),
    lowerStyle: normalizeWickStyle(L.lowerShadowStyle || moO.defaultLowerShadowStyle),
  };
}

/** 与细 K 蜡烛同算法：半根实体宽（像素），用于粗 K 左右边界对齐到首末根细 K 外沿 */
function driverPixelHalfBarWidth(s, driverKs) {
  const drvVis = getVisibleKs({ kline: driverKs || [] }, s.xMin, s.xMax);
  const n = drvVis.length;
  const bodyW = Math.max(3, s.plotW / Math.max(42, (n || 1) * 1.28));
  return bodyW / 2;
}

function drawCandles(chart, s, paintOpts = {}) {
  const ks = getVisibleKs(chart, s.xMin, s.xMax);
  const driverKl = paintOpts.driverKlineForOverlaySpan;
  const spanOverlay = !!(paintOpts.overlaySpanCandles && Array.isArray(driverKl) && driverKl.length > 0);
  const upS = getCfgColor(activeDrawStyle().candle.upColor);
  const dnS = getCfgColor(activeDrawStyle().candle.downColor);
  const upF = cssVar("--candleUpFill", "rgba(239,68,68,0.12)");
  const dnF = cssVar("--candleDownFill", "rgba(34,197,94,0.75)");
  const ovPhase = paintOpts.overlayCandlePhase;

  if (spanOverlay) {
    const fullKl = chart.kline || [];
    const coarseOpts = paintOpts.coarseOverlayOpts || resolveCoarseOverlayPaintOpts(chartConfig.multiOverlay, String(paintOpts.overlayKtKey || ""));
    const halfW = driverPixelHalfBarWidth(s, driverKl);
    ctx.save();
    ctx.lineJoin = "miter";
    for (const k of ks) {
      const idx = overlayFindBarIndexInKline(chart, k);
      const prevBar = idx > 0 ? fullKl[idx - 1] : null;
      const tr = overlayCoarseBarTimeWindowMs(prevBar, k);
      if (!tr) continue;
      const slice = driverBarsInTimeWindowSorted(driverKl, tr.tLoMs, tr.tHiMs, tr.loOpen);
      const oN = Number(k.o),
        hN = Number(k.h),
        lN = Number(k.l),
        cN = Number(k.c);
      const nativeOk = [oN, hN, lN, cN].every((v) => Number.isFinite(v));
      const q = nativeOk ? { o: oN, h: hN, l: lN, c: cN } : synthOhlcFromDriverSlice(slice, k);
      const span = driverXSpanInTimeWindow(driverKl, tr.tLoMs, tr.tHiMs, tr.loOpen);
      let xLo = span ? span.xLo : Number(k.x);
      let xHi = span ? span.xHi : Number(k.x);
      if (!Number.isFinite(xLo) || !Number.isFinite(xHi)) continue;
      xLo = Math.max(s.xMin, Math.min(xLo, xHi));
      xHi = Math.min(s.xMax, Math.max(xLo, xHi));
      if (xHi < xLo) continue;
      const pxCL = s.x(xLo);
      const pxCR = s.x(xHi);
      const pxL = Math.min(pxCL, pxCR) - halfW;
      const pxR = Math.max(pxCL, pxCR) + halfW;
      const rectW = Math.max(1, pxR - pxL);
      const yHigh = s.y(q.h);
      const yLow = s.y(q.l);
      const yOpen = s.y(q.o);
      const yClose = s.y(q.c);
      const envTop = Math.min(yHigh, yLow);
      const envBot = Math.max(yHigh, yLow);
      let bodyTop = Math.min(yOpen, yClose);
      let bodyBot = Math.max(yOpen, yClose);
      if (bodyBot - bodyTop < 1) {
        const mid = (bodyTop + bodyBot) / 2;
        bodyTop = mid - 0.5;
        bodyBot = mid + 0.5;
      }
      const up = q.c >= q.o;
      const strokeC = up ? upS : dnS;
      const phase = ovPhase || "both";
      if (phase === "shadows" || phase === "both") {
        const uh = Math.max(0, bodyTop - envTop);
        const lh = Math.max(0, envBot - bodyBot);
        const patUp = getWickTexturePattern(ctx, coarseOpts.upperStyle, strokeC);
        const patLo = getWickTexturePattern(ctx, coarseOpts.lowerStyle, strokeC);
        if (uh > 0) {
          ctx.save();
          ctx.globalAlpha = coarseOpts.upperShadowAlpha;
          if (patUp) {
            ctx.fillStyle = patUp;
            ctx.fillRect(pxL, envTop, rectW, uh);
          } else {
            ctx.fillStyle = strokeC;
            ctx.globalAlpha *= 0.35;
            ctx.fillRect(pxL, envTop, rectW, uh);
          }
          ctx.restore();
        }
        if (lh > 0) {
          ctx.save();
          ctx.globalAlpha = coarseOpts.lowerShadowAlpha;
          if (patLo) {
            ctx.fillStyle = patLo;
            ctx.fillRect(pxL, bodyBot, rectW, lh);
          } else {
            ctx.fillStyle = strokeC;
            ctx.globalAlpha *= 0.35;
            ctx.fillRect(pxL, bodyBot, rectW, lh);
          }
          ctx.restore();
        }
      }
      if (phase === "bodies" || phase === "both") {
        const bh = Math.max(1, bodyBot - bodyTop);
        ctx.save();
        ctx.globalAlpha = coarseOpts.bodyAlpha;
        ctx.fillStyle = strokeC;
        ctx.fillRect(pxL, bodyTop, rectW, bh);
        ctx.restore();
      }
    }
    ctx.restore();
    return;
  }

  const bodyW = Math.max(3, s.plotW / Math.max(42, ks.length * 1.28));
  const ca = Number(activeDrawStyle().candle && activeDrawStyle().candle.alpha);
  const candleAlphaMul = Number.isFinite(ca) ? Math.min(1, Math.max(0.05, ca)) : 1;
  ctx.save();
  ctx.globalAlpha = candleAlphaMul;
  for (const k of ks) {
    const x = s.x(k.x);
    const yo = s.y(k.o),
      yc = s.y(k.c),
      yh = s.y(k.h),
      yl = s.y(k.l);
    const up = k.c >= k.o;
    ctx.strokeStyle = up ? upS : dnS;
    ctx.fillStyle = up ? upF : dnF;
    ctx.lineWidth = activeDrawStyle().candle.width;

    ctx.beginPath();
    ctx.moveTo(x, yh);
    ctx.lineTo(x, yl);
    ctx.stroke();

    const top = Math.min(yo, yc),
      bh = Math.max(1, Math.abs(yc - yo));
    if (up) {
      ctx.strokeRect(x - bodyW / 2, top, bodyW, bh);
    } else {
      ctx.fillRect(x - bodyW / 2, top, bodyW, bh);
    }
  }
  ctx.restore();
}

function drawKlineCombineFrames(chart, s) {
  if (!activeDrawStyle().klineCombineFrame || activeDrawStyle().klineCombineFrame.enabled === false) return;
  const frames = Array.isArray(chart.kline_combine) ? chart.kline_combine : [];
  if (frames.length === 0) return;
  ctx.save();
  ctx.strokeStyle = getCfgColor(activeDrawStyle().klineCombineFrame.color || "#6366f1");
  ctx.lineWidth = Number(activeDrawStyle().klineCombineFrame.lineWidth || 1.2);
  ctx.setLineDash(getTradeLineDash(activeDrawStyle().klineCombineFrame.lineStyle || "solid"));
  for (const frame of frames) {
    if (!frame) continue;
    const loX = Math.min(Number(frame.x1), Number(frame.x2));
    const hiX = Math.max(Number(frame.x1), Number(frame.x2));
    if (!Number.isFinite(loX) || !Number.isFinite(hiX)) continue;
    if (hiX < s.xMin || loX > s.xMax) continue;
    const x1 = s.x(loX);
    const x2 = s.x(hiX);
    const yTop = s.y(Number(frame.high));
    const yBottom = s.y(Number(frame.low));
    const rectX = Math.min(x1, x2);
    const rectY = Math.min(yTop, yBottom);
    const rectW = Math.max(1, Math.abs(x2 - x1));
    const rectH = Math.max(1, Math.abs(yBottom - yTop));
    ctx.strokeRect(rectX, rectY, rectW, rectH);
  }
  ctx.restore();
}

function intersects(l, xMin, xMax) {
  const a = Math.min(l.x1, l.x2);
  const b = Math.max(l.x1, l.x2);
  return b >= xMin && a <= xMax;
}

function drawLines(arr, s, color, width, dashed = false) {
  ctx.save();
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  if (dashed) ctx.setLineDash([5, 4]);
  else ctx.setLineDash([]);
  for (const l of arr) {
    if (!intersects(l, s.xMin, s.xMax)) continue;
    ctx.beginPath();
    ctx.moveTo(s.x(l.x1), s.y(l.y1));
    ctx.lineTo(s.x(l.x2), s.y(l.y2));
    ctx.stroke();
  }
  ctx.restore();
}

function drawLegend() {
  const pad = 8;
  const lineTpl = (label, cfg, sureKey, unsureKey) => [
    { label: `${label}(确定)`, color: getCfgColor(cfg.color), dashed: false, w: cfg[sureKey] },
    { label: `${label}(未完成)`, color: getCfgColor(cfg.color), dashed: true, w: cfg[unsureKey] },
  ];
  let lines = [
    { label: "分型辅助线", color: getCfgColor(chartConfig.fx.color), dashed: true, w: chartConfig.fx.width },
    ...lineTpl("分型", chartConfig.fract, "widthSure", "widthUnsure"),
    ...lineTpl("笔", chartConfig.bi, "widthSure", "widthUnsure"),
    ...lineTpl("段", chartConfig.seg, "widthSure", "widthUnsure"),
    ...lineTpl("2段", chartConfig.segseg, "widthSure", "widthUnsure"),
  ];
  if (lastPayload && String(lastPayload.chart_mode || "") === "multi" && Array.isArray(lastPayload.k_types_multi) && lastPayload.k_types_multi.length >= 2) {
    lines = [];
    const ordered = MULTI_KTYPE_ORDER.filter((k) => (lastPayload.k_types_multi || []).includes(k));
    ordered.forEach((kt) => {
      const st = getMultiLayerDrawConfig(kt);
      const tag = getKTypeLabelText(kt);
      lines.push({ label: `${tag}·分型辅助线`, color: getCfgColor(st.fx.color), dashed: true, w: st.fx.width });
      lines.push(...lineTpl(`${tag}·分型`, st.fract, "widthSure", "widthUnsure"));
      lines.push(...lineTpl(`${tag}·笔`, st.bi, "widthSure", "widthUnsure"));
      lines.push(...lineTpl(`${tag}·段`, st.seg, "widthSure", "widthUnsure"));
      lines.push(...lineTpl(`${tag}·2段`, st.segseg, "widthSure", "widthUnsure"));
    });
  }
  ctx.save();
  const fontSize = chartConfig.legend.fontSize;
  ctx.font = `${chartConfig.legend.fontWeight || "normal"} ${fontSize}px Consolas`;
  ctx.textBaseline = "middle";
  let maxW = 0;
  for (const L of lines) {
    const tw = ctx.measureText(L.label).width + 52;
    if (tw > maxW) maxW = tw;
  }
  const lh = fontSize + 6;
  const boxH = pad * 2 + lines.length * lh;
  const boxW = maxW;
  const x0 = PAD_L + 4;
  const y0 = PAD_T + 4;
  legendHoverBox = { x1: x0, y1: y0, x2: x0 + boxW, y2: y0 + boxH };
  // 图例只在鼠标悬停左上角图例区域时显示，默认隐藏。
  if (!legendHoverActive) {
    ctx.restore();
    return;
  }
  ctx.fillStyle = cssVar("--legendBg", "rgba(255,255,255,0.92)");
  ctx.strokeStyle = cssVar("--legendBorder", "rgba(148,163,184,0.6)");
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.rect(x0, y0, boxW, boxH);
  ctx.fill();
  ctx.stroke();
  let y = y0 + pad + lh / 2;
  for (const L of lines) {
    const xLine = x0 + pad;
    ctx.strokeStyle = L.color;
    ctx.lineWidth = L.w;
    if (L.dashed) ctx.setLineDash([5, 4]);
    else ctx.setLineDash([]);
    ctx.beginPath();
    ctx.moveTo(xLine, y);
    ctx.lineTo(xLine + 24, y);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = getCfgColor(chartConfig.legend.color || cssVar("--legendText", "#0f172a"));
    ctx.fillText(L.label, xLine + 32, y);
    y += lh;
  }
  ctx.restore();
}

function drawTradeBands(s, chart) {
  if (!lastPayload || !lastPayload.ready) return;
  const lastX = chart.kline[chart.kline.length - 1].x;
  /** 同根反手时 x 像素重合，给区间一个最小宽度避免「看不见」或与竖线完全重叠 */
  const minXBandPx = 2.2;
  const fillHoldBackground = (x1, x2, color, alphaMul) => {
    if (x1 == null || x2 == null) return;
    const lo = Math.min(x1, x2);
    const hi = Math.max(x1, x2);
    if (hi < s.xMin || lo > s.xMax) return;
    const xa = s.x(lo);
    const xb = s.x(hi);
    const xLeft = Math.min(xa, xb);
    const xW = Math.max(minXBandPx, Math.abs(xb - xa));
    ctx.save();
    ctx.fillStyle = color;
    ctx.globalAlpha = alphaMul;
    ctx.fillRect(xLeft, PAD_T, xW, s.plotBottomY - PAD_T);
    ctx.restore();
  };

  const fillPnlBand = (x1, x2, buyPrice, endPrice) => {
    if (x1 == null || x2 == null || buyPrice == null || endPrice == null) return;
    const lo = Math.min(x1, x2);
    const hi = Math.max(x1, x2);
    if (hi < s.xMin || lo > s.xMax) return;
    const xa = s.x(lo);
    const xb = s.x(hi);
    const xLeft = Math.min(xa, xb);
    const xW = Math.max(minXBandPx, Math.abs(xb - xa));
    const yBuy = s.y(buyPrice);
    const yEnd = s.y(endPrice);
    const top = Math.min(yBuy, yEnd);
    const height = Math.max(1, Math.abs(yEnd - yBuy));
    const isProfit = endPrice >= buyPrice;
    const pnlColor = isProfit ? getCfgColor(chartConfig.trade.profitBandColor) : getCfgColor(chartConfig.trade.lossBandColor);
    ctx.save();
    ctx.fillStyle = pnlColor;
    ctx.globalAlpha = 0.28;
    ctx.fillRect(xLeft, top, xW, height);
    ctx.restore();
  };

  for (const tr of tradeHistory) {
    if (tr.buyX != null && tr.sellX != null) {
      fillHoldBackground(tr.buyX, tr.sellX, getCfgColor(chartConfig.trade.rangeFillSell), 0.11);
      fillPnlBand(tr.buyX, tr.sellX, tr.buyPrice, tr.sellPrice);
    } else if (tr.shortX != null && tr.coverX != null) {
      fillHoldBackground(tr.shortX, tr.coverX, getCfgColor(chartConfig.trade.rangeFillSell), 0.11);
      // 做空盈亏区间用反向价格关系（shortPrice 与 coverPrice）
      fillPnlBand(tr.shortX, tr.coverX, tr.coverPrice, tr.shortPrice);
    }
  }
  if (lastPayload.account.position > 0 && activeTrade && activeTrade.buyX != null) {
    fillHoldBackground(activeTrade.buyX, lastX, getCfgColor(chartConfig.trade.rangeFillBuy), 0.11);
    fillPnlBand(activeTrade.buyX, lastX, activeTrade.buyPrice, lastPayload.price);
  } else if (lastPayload.account.position < 0 && activeTrade && activeTrade.shortX != null) {
    fillHoldBackground(activeTrade.shortX, lastX, getCfgColor(chartConfig.trade.rangeFillBuy), 0.11);
    fillPnlBand(activeTrade.shortX, lastX, lastPayload.price, activeTrade.shortPrice);
  }
}

function drawTradeMarkers(s, chart) {
  if (!lastPayload || !lastPayload.ready) return;
  const buyC = getCfgColor(chartConfig.trade.buyColor);
  const sellC = getCfgColor(chartConfig.trade.sellColor);
  /** 同根、同色多笔（如平多+做空）合并竖线，文字纵向错开 */
  const entries = [];
  const push = (xBar, color, tag) => {
    if (xBar == null || xBar === undefined) return;
    entries.push({ xBar: Number(xBar), color, tag: String(tag) });
  };
  for (const tr of tradeHistory) {
    if (tr.buyX != null) push(tr.buyX, buyC, "买");
    if (tr.sellX != null) push(tr.sellX, sellC, "卖");
    if (tr.shortX != null) push(tr.shortX, sellC, "空");
    if (tr.coverX != null) push(tr.coverX, buyC, "平");
  }
  if (lastPayload.account.position > 0 && activeTrade && activeTrade.buyX != null) {
    push(activeTrade.buyX, buyC, "买");
  } else if (lastPayload.account.position < 0 && activeTrade && activeTrade.shortX != null) {
    push(activeTrade.shortX, sellC, "空");
  }
  const groups = new Map();
  for (const e of entries) {
    const key = `${e.xBar}\t${e.color}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(e.tag);
  }
  for (const [key, tags] of groups) {
    const tab = key.indexOf("\t");
    const xBar = Number(key.slice(0, tab));
    const color = key.slice(tab + 1);
    if (xBar < s.xMin || xBar > s.xMax) continue;
    const xp = s.x(xBar);
    const uniq = [...new Set(tags)];
    ctx.save();
    ctx.strokeStyle = color;
    ctx.lineWidth = chartConfig.trade.markerLineWidth || 2;
    ctx.setLineDash(getTradeLineDash(chartConfig.trade.markerLineStyle || "dashed"));
    ctx.beginPath();
    ctx.moveTo(xp, PAD_T);
    ctx.lineTo(xp, s.plotBottomY);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = color;
    const fs = chartConfig.trade.markerFontSize || 14;
    ctx.font = `${chartConfig.trade.markerFontWeight || "bold"} ${fs}px Consolas`;
    ctx.textAlign = "center";
    const baseY = s.plotBottomY + 18;
    const stackGap = Math.min(18, Math.max(12, fs + 3));
    uniq.forEach((tag, idx) => {
      const off = (idx - (uniq.length - 1) / 2) * stackGap;
      ctx.fillText(tag, xp, baseY + off);
    });
    ctx.restore();
  }
}

function drawTradeRays(s) {
  const drawRay = (x1, y1, x2, color, style) => {
    if (x1 == null || x2 == null || y1 == null) return;
    const lo = Math.min(x1, x2);
    const hi = Math.max(x1, x2);
    if (hi < s.xMin || lo > s.xMax) return;
    ctx.save();
    ctx.strokeStyle = color;
    ctx.lineWidth = chartConfig.trade.closeLineWidth || 2;
    ctx.setLineDash(getTradeLineDash(style || "solid"));
    ctx.beginPath();
    ctx.moveTo(s.x(x1), s.y(y1));
    ctx.lineTo(s.x(x2), s.y(y1));
    ctx.stroke();
    ctx.restore();
  };

  const rayBuy = getCfgColor(chartConfig.trade.buyColor);
  const raySell = getCfgColor(chartConfig.trade.sellColor);
  for (const tr of tradeHistory) {
    drawRay(tr.buyX, tr.buyPrice, tr.sellX, rayBuy, chartConfig.trade.buyCloseLineStyle || "solid");
    drawRay(tr.sellX, tr.sellPrice, tr.buyX, raySell, chartConfig.trade.sellCloseLineStyle || "dashed");
    drawRay(tr.shortX, tr.shortPrice, tr.coverX, raySell, chartConfig.trade.sellCloseLineStyle || "dashed");
    drawRay(tr.coverX, tr.coverPrice, tr.shortX, rayBuy, chartConfig.trade.buyCloseLineStyle || "solid");
  }
  if (activeTrade && activeTrade.buyX != null && activeTrade.buyPrice != null) {
    const rightTo = Math.max(s.xMax, activeTrade.buyX + 1);
    drawRay(activeTrade.buyX, activeTrade.buyPrice, rightTo, rayBuy, chartConfig.trade.buyCloseLineStyle || "solid");
  }
  if (activeTrade && activeTrade.shortX != null && activeTrade.shortPrice != null) {
    const rightTo = Math.max(s.xMax, activeTrade.shortX + 1);
    drawRay(activeTrade.shortX, activeTrade.shortPrice, rightTo, raySell, chartConfig.trade.sellCloseLineStyle || "dashed");
  }
}

function drawIndicators(chart, s) {
  if (!chart || !chart.indicators || chart.indicators.length === 0) return;
  const visibleInd = s.visibleInd || [];
  if (visibleInd.length === 0) return;
  
  const theme = document.documentElement.getAttribute("data-theme") || "light";
  const lineMain = theme === "light" ? "#1e293b" : "#f8fafc";
  const mainTypeSet = new Set((s.mainTypes || []).map((m) => m.type));
  const indicatorCfg = getIndicatorConfig();
  const showMainVar = !!indicatorCfg.mainVarVisible;
  const showSubVar = !!indicatorCfg.subVarVisible;
  const fmtIndNum = (v, digits = 2) => (Number.isFinite(Number(v)) ? Number(v).toFixed(digits) : "--");
  const refInd = resolveIndicatorRowForDisplay(chart, s, visibleInd);
  const latestVisible = visibleInd.length > 0 ? visibleInd[visibleInd.length - 1] : null;
  const dispInd = refInd || latestVisible;
  // #region agent log
  const __dbgRefK = getReferenceK(chart, s);
  __agentDebugLog(
    "H1",
    "a_replay_trainer.py:drawIndicators:refInd",
    "指标变量锚点检查",
    {
      crosshairEnabled: !!crosshairEnabled,
      crosshairX,
      latestX: latestVisible ? Number(latestVisible.x) : null,
      refX: __dbgRefK ? Number(__dbgRefK.x) : null,
      dispX: dispInd ? Number(dispInd.x) : null,
      visibleIndCount: visibleInd.length,
      showMainVar,
      showSubVar,
    },
    `disp:${dispInd ? Number(dispInd.x) : "na"}|ref:${__dbgRefK ? Number(__dbgRefK.x) : "na"}|cx:${crosshairX}`,
    250
  );
  // #endregion

  const drawPanelLine = (arr, getter, yFn, color) => {
    ctx.strokeStyle = color;
    ctx.beginPath();
    let first = true;
    for (const item of arr) {
      const yVal = getter(item);
      if (!Number.isFinite(yVal)) continue;
      const xp = s.x(item.x);
      const yp = yFn(yVal);
      if (first) ctx.moveTo(xp, yp);
      else ctx.lineTo(xp, yp);
      first = false;
    }
    if (!first) ctx.stroke();
  };

  const getPanelRange = (type) => {
    let min = Infinity;
    let max = -Infinity;
    if (type === "macd") {
      for (const i of visibleInd) {
        if (!i.macd) continue;
        min = Math.min(min, i.macd.dif, i.macd.dea, i.macd.macd);
        max = Math.max(max, i.macd.dif, i.macd.dea, i.macd.macd);
      }
    } else if (type === "kdj") {
      min = 0;
      max = 100;
      for (const i of visibleInd) {
        if (!i.kdj) continue;
        min = Math.min(min, i.kdj.k, i.kdj.d, i.kdj.j);
        max = Math.max(max, i.kdj.k, i.kdj.d, i.kdj.j);
      }
    } else if (type === "rsi") {
      min = 0;
      max = 100;
    } else if (type === "vol") {
      min = 0;
      for (const i of visibleInd) {
        const vv = Number(i && i.vol);
        if (Number.isFinite(vv)) max = Math.max(max, vv);
      }
      // 兼容旧 payload：没有 vol 时回退读取 kline.v
      if (!isFinite(max)) {
        for (const k of s.visibleK || []) {
          const kv = Number(k && k.v);
          if (Number.isFinite(kv)) max = Math.max(max, kv);
        }
      }
    }
    if (!isFinite(min) || !isFinite(max)) {
      min = 0;
      max = 1;
    }
    if (min === max) {
      min -= 1;
      max += 1;
    }
    return [min, max];
  };

  const drawSubPanel = (panel) => {
    const [subYMin, subYMax] = getPanelRange(panel.type);
    const subYSpan = subYMax - subYMin;
    const subY = (val) => panel.bottom - ((val - subYMin) / subYSpan) * panel.height;

    ctx.save();
    ctx.fillStyle = cssVar("--muted", "#475569");
    ctx.font = "10px Consolas";
    ctx.fillText(subYMax.toFixed(2), 4, panel.top + 10);
    ctx.fillText(subYMin.toFixed(2), 4, panel.bottom);
    if (showSubVar && dispInd) {
      let subLabel = "";
      if (panel.type === "macd" && dispInd.macd) {
        subLabel = `MACD DIF:${fmtIndNum(dispInd.macd.dif)} DEA:${fmtIndNum(dispInd.macd.dea)} MACD:${fmtIndNum(dispInd.macd.macd)}`;
      } else if (panel.type === "kdj" && dispInd.kdj) {
        subLabel = `KDJ K:${fmtIndNum(dispInd.kdj.k)} D:${fmtIndNum(dispInd.kdj.d)} J:${fmtIndNum(dispInd.kdj.j)}`;
      } else if (panel.type === "rsi" && Number.isFinite(Number(dispInd.rsi))) {
        subLabel = `RSI:${fmtIndNum(dispInd.rsi)}`;
      } else if (panel.type === "vol") {
        const volV = Number.isFinite(Number(dispInd.vol))
          ? Number(dispInd.vol)
          : (() => {
              const refK = getReferenceK(chart, s);
              const vk = refK && s.visibleK ? s.visibleK.find((k) => Number(k.x) === Number(refK.x)) : null;
              return vk ? Number(vk.v) : NaN;
            })();
        subLabel = `VOL:${fmtIndNum(volV, 0)}`;
      }
      if (subLabel) {
        ctx.textAlign = "right";
        ctx.fillText(subLabel, s.w - PAD_R - 6, panel.top + 10);
        ctx.textAlign = "left";
      }
    }
    if (panel.type === "macd") {
      for (const i of visibleInd) {
        if (!i.macd) continue;
        const xp = s.x(i.x);
        const yp = subY(i.macd.macd);
        const y0 = subY(0);
        ctx.fillStyle = i.macd.macd >= 0 ? cssVar("--candleUp", "#ef4444") : cssVar("--candleDown", "#22c55e");
        ctx.fillRect(xp - 1, Math.min(yp, y0), 2, Math.abs(yp - y0));
      }
      drawPanelLine(visibleInd, (i) => i.macd?.dif, subY, lineMain);
      drawPanelLine(visibleInd, (i) => i.macd?.dea, subY, "#fbbf24");
    } else if (panel.type === "kdj") {
      drawPanelLine(visibleInd, (i) => i.kdj?.k, subY, lineMain);
      drawPanelLine(visibleInd, (i) => i.kdj?.d, subY, "#fbbf24");
      drawPanelLine(visibleInd, (i) => i.kdj?.j, subY, "#f472b6");
    } else if (panel.type === "rsi") {
      drawPanelLine(visibleInd, (i) => i.rsi, subY, lineMain);
    } else if (panel.type === "vol") {
      // 成交量柱：优先用指标序列，旧数据回退到当前可见K线
      const volRows = [];
      for (const i of visibleInd) {
        const vv = Number(i && i.vol);
        if (Number.isFinite(vv)) volRows.push({ x: Number(i.x), vol: vv });
      }
      if (volRows.length === 0) {
        for (const k of s.visibleK || []) {
          const kv = Number(k && k.v);
          if (Number.isFinite(kv)) volRows.push({ x: Number(k.x), vol: kv });
        }
      }
      const closeByX = new Map();
      for (const k of s.visibleK || []) closeByX.set(Number(k.x), Number(k.c));
      for (let idx = 0; idx < volRows.length; idx++) {
        const row = volRows[idx];
        const xp = s.x(row.x);
        const y0 = subY(0);
        const yp = subY(row.vol);
        const prevClose = idx > 0 ? closeByX.get(Number(volRows[idx - 1].x)) : undefined;
        const curClose = closeByX.get(Number(row.x));
        let barColor = cssVar("--muted", "#475569");
        if (Number.isFinite(curClose) && Number.isFinite(prevClose)) {
          barColor = curClose >= prevClose ? cssVar("--candleUp", "#ef4444") : cssVar("--candleDown", "#22c55e");
        }
        ctx.fillStyle = barColor;
        ctx.fillRect(xp - 1.5, Math.min(yp, y0), 3, Math.abs(yp - y0));
      }
    }
    ctx.restore();
  };

  if (mainTypeSet.has("boll")) {
    ctx.save();
    ctx.lineWidth = 1;
    drawPanelLine(visibleInd, (i) => i.boll?.mid, s.y, "#94a3b8");
    drawPanelLine(visibleInd, (i) => i.boll?.up, s.y, "#f59e0b");
    drawPanelLine(visibleInd, (i) => i.boll?.down, s.y, "#f59e0b");
    ctx.restore();
  }
  if (mainTypeSet.has("demark")) {
    ctx.save();
    ctx.font = "bold 12px Consolas";
    ctx.textAlign = "center";
    for (const i of visibleInd) {
      if (!i.demark) continue;
      for (const pt of i.demark) {
        const xp = s.x(pt.x);
        const up = pt.dir === "UP";
        const yp = up ? s.y(s.visibleK.find(k => k.x === pt.x)?.h || 0) - 15 : s.y(s.visibleK.find(k => k.x === pt.x)?.l || 0) + 20;
        ctx.fillStyle = up ? cssVar("--candleUp", "#ef4444") : cssVar("--candleDown", "#22c55e");
        ctx.fillText(pt.val, xp, yp);
      }
    }
    ctx.restore();
  }
  if (mainTypeSet.has("trendline")) {
    if (chart.trend_lines) {
      ctx.save();
      ctx.lineWidth = 2;
      for (const tl of chart.trend_lines) {
        const y_start = tl.y0 + tl.slope * (s.xMin - tl.x0);
        const y_end = tl.y0 + tl.slope * (s.xMax - tl.x0);
        ctx.strokeStyle = tl.type === "OUTSIDE" ? "#a855f7" : "#ec4899"; // Purple/Pink
        ctx.setLineDash([5, 5]);
        ctx.beginPath();
        ctx.moveTo(s.x(s.xMin), s.y(y_start));
        ctx.lineTo(s.x(s.xMax), s.y(y_end));
        ctx.stroke();
      }
      ctx.restore();
    }
  }
  if (showMainVar && dispInd) {
    const rows = [];
    if (mainTypeSet.has("boll") && dispInd.boll) {
      rows.push(
        `BOLL MID:${fmtIndNum(dispInd.boll.mid)} UP:${fmtIndNum(dispInd.boll.up)} DN:${fmtIndNum(dispInd.boll.down)}`
      );
    }
    if (mainTypeSet.has("demark")) {
      const demarkCnt = Array.isArray(dispInd.demark) ? dispInd.demark.length : 0;
      rows.push(`Demark: ${demarkCnt} 个标记`);
    }
    if (mainTypeSet.has("trendline")) {
      rows.push(`TrendLine: ${Array.isArray(chart.trend_lines) ? chart.trend_lines.length : 0} 条`);
    }
    // #region agent log
    __agentDebugLog(
      "H3",
      "a_replay_trainer.py:drawIndicators:mainRowsAssembled",
      "主图变量行组装结果",
      {
        showMainVar,
        rowsCount: rows.length,
        mainTypes: Array.from(mainTypeSet || []),
        hasBollValue: !!(dispInd && dispInd.boll),
        demarkValueCount: dispInd && Array.isArray(dispInd.demark) ? dispInd.demark.length : null,
        trendLineCount: Array.isArray(chart.trend_lines) ? chart.trend_lines.length : 0,
      },
      `mainVar:${showMainVar ? 1 : 0}|rows:${rows.length}|types:${Array.from(mainTypeSet || []).join(",")}`,
      350
    );
    // #endregion
    if (rows.length > 0) {
      // #region agent log
      __agentDebugLog(
        "H2",
        "a_replay_trainer.py:drawIndicators:mainVarBox",
        "主图变量绘制位置",
        {
          rowsCount: rows.length,
          textX: PAD_L + 4,
          textY: PAD_T + 8,
        },
        `rows:${rows.length}`,
        400
      );
      // #endregion
      ctx.save();
      ctx.fillStyle = cssVar("--legendText", "#0f172a");
      ctx.font = "11px Consolas";
      ctx.textBaseline = "top";
      ctx.textAlign = "left";
      let y = PAD_T + 8;
      const xLeft = PAD_L + 4;
      for (const row of rows) {
        ctx.fillText(row, xLeft, y);
        y += 14;
      }
      ctx.restore();
    }
  }
  for (const panel of s.subPanels || []) drawSubPanel(panel);
}

function drawBsp(arr, s) {
  return drawBottomSignals({ bsp: arr || [], rhythm: [] }, s);
}

/** 与后端 ChanStepper._bsp_key 一致，用于合并判定状态 */
function bottomBspRowKey(p) {
  if (!p) return "";
  const lvl = String(p.level || "");
  const x = Math.floor(Number(p.anchor_x != null ? p.anchor_x : p.x));
  const buy = p.is_buy ? 1 : 0;
  return `${lvl}|${x}|${buy}`;
}

/**
 * 图底买卖点数据源：单图用全局 bspHistory（含 ×/✓ 状态）；
 * 双周期子图各自 K 线索引不同，须用当前 chart.bsp 再叠 bsp_history 中同 key 的状态。
 */
function resolveBottomBspRowsForDraw(chart) {
  const chartRows = (chart && Array.isArray(chart.bsp)) ? chart.bsp : [];
  const historyRows = Array.isArray(bspHistory) ? bspHistory : [];
  const payloadFeed = normalizeDataFeedMode(lastPayload && lastPayload.data_form ? lastPayload.data_form.feed_mode : dataFormConfig.feedMode);
  if (payloadFeed === "step" && historyRows.length > 0 && dualInternalRenderDepth === 0) {
    return historyRows;
  }
  const mergeChartRowsWithHistory = () => {
    const historyMap = new Map();
    historyRows.forEach((h) => {
      const k = h.key || bottomBspRowKey(h);
      if (k && !historyMap.has(k)) historyMap.set(k, { ...h, key: k });
    });
    const used = new Set();
    const merged = chartRows.map((it) => {
      const k = it.key || bottomBspRowKey(it);
      if (k && historyMap.has(k)) {
        used.add(k);
        const h = historyMap.get(k);
        // 同 key 用历史冻结标签；统一喂数据/双图再由 chart 补齐当前图索引。
        return { ...it, ...h, key: k, status: h.status != null ? h.status : it.status };
      }
      return { ...it, key: k };
    });
    historyMap.forEach((h, k) => {
      if (!used.has(k)) merged.push(h);
    });
    return merged;
  };
  return mergeChartRowsWithHistory();
}

function drawRhythmLines(arr, s) {
  if (!activeDrawStyle().rhythmLine || !activeDrawStyle().rhythmLine.enabled) return;
  // 自定义术语说明：
  // - “推进峰值端点”指与父结构同向推进的子级端点（上升时对应 D/F/H...）。
  // - line.label_left 是节奏线编号，例如 1-0 / 1-1。
  // - line.label_right 是该线复用的回调比例，例如 0.618。
  for (const line of arr || []) {
    if (!isRhythmLineVisible(line)) continue;
    if (!intersects(line, s.xMin, s.xMax)) continue;
    const visual = getRhythmVisualConfig(line.color_group);
    const x1Val = Math.max(s.xMin, Math.min(s.xMax, Number(line.x1)));
    const x2Val = Math.max(s.xMin, Math.min(s.xMax, Number(line.x2)));
    const xp1 = s.x(x1Val);
    const xp2 = s.x(x2Val);
    const yp = s.y(line.y1);
    ctx.save();
    ctx.lineWidth = visual.lineWidth;
    ctx.setLineDash(getTradeLineDash(visual.lineStyle));
    ctx.strokeStyle = visual.lineColor;
    ctx.beginPath();
    ctx.moveTo(xp1, yp);
    ctx.lineTo(xp2, yp);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = visual.textColor;
    ctx.font = `${visual.textFontWeight} ${visual.textFontSize}px Consolas`;
    ctx.textBaseline = "middle";
    ctx.textAlign = "right";
    ctx.fillText(String(line.label_left || ""), xp1 - 6, yp);
    ctx.textAlign = "left";
    ctx.fillText(String(line.label_right || ""), xp2 + 6, yp);
    ctx.restore();
  }
}

function buildBottomSignalGroups(chart, bspArr) {
  const groups = {};
  const push = (x, item) => {
    if (!Number.isFinite(x)) return;
    if (!groups[x]) groups[x] = [];
    groups[x].push(item);
  };
  const colBuy = getCfgColor(chartConfig.trade.buyColor);
  const colSell = getCfgColor(chartConfig.trade.sellColor);
  for (const p of bspArr || []) {
    if (!p || !Number.isFinite(p.x)) continue;
    if (!isBspLevelEnabled(p.level)) continue;
    const bspCfg = getBspConfig(p.level);
    const prefix = p.status === "correct" ? "✓" : (p.status === "wrong" ? "×" : "·");
    const text = `${prefix} ${getBspDisplayLabel(p)}`;
    const levelPriority = segLevelSortOrder(p.level);
    const statusPriority = p.status === "correct" ? 0 : (p.status === "wrong" ? 1 : 2);
    push(Number(p.x), {
      kind: "bsp",
      anchorX: Number.isFinite(Number(p.anchor_x)) ? Number(p.anchor_x) : Number(p.x),
      isBuy: !!p.is_buy,
      priority: 0,
      sortKey: levelPriority * 10 + statusPriority,
      text,
      tipText: text,
      fontSize: Number(bspCfg.fontSize || 14),
      textColor: p.is_buy ? colBuy : colSell,
      borderColor: p.is_buy ? colBuy : colSell,
      lineColor: getCfgColor(bspCfg.lineColor),
      lineWidth: Number(bspCfg.lineWidth || 1),
      lineStyle: bspCfg.lineStyle || "dashed",
      showLowerExtension: bspCfg.showLowerExtension !== false,
    });
  }
  return groups;
}

function drawBottomSignals(chart, s) {
  if (chartConfigStore && chartConfigStore.shared && chartConfigStore.shared.showBottomBsp === false) return;
  signalHoverBoxes = [];
  const groups = buildBottomSignalGroups(chart, resolveBottomBspRowsForDraw(chart));
  const xs = Object.keys(groups).map((x) => Number(x)).filter((x) => x >= s.xMin && x <= s.xMax).sort((a, b) => a - b);
  const boxGap = 4;
  const boxPadX = 8;
  const boxPadY = 5;
  const compactLimit = 3;
  const byX = new Map((s.visibleK || []).map((k) => [k.x, k]));

  for (const x of xs) {
    const xp = s.x(x);
    const items = (groups[x] || []).slice().sort((a, b) => (a.priority - b.priority) || (a.sortKey - b.sortKey) || String(a.text).localeCompare(String(b.text)));
    const groupTip = items.map((item) => item.tipText || item.text).join("\n");
    let renderItems = items.slice();
    if (items.length > compactLimit) {
      renderItems = [{
        kind: "overflow",
        priority: 999,
        sortKey: 999,
        text: String(items.length),
        tipText: groupTip,
        fontSize: Math.max(
          Number(chartConfig.bspBi && chartConfig.bspBi.fontSize) || 14,
          Number(chartConfig.bspSeg && chartConfig.bspSeg.fontSize) || 14,
          Number(chartConfig.bspSegseg && chartConfig.bspSegseg.fontSize) || 14,
        ),
        textColor: cssVar("--muted", "#475569"),
        borderColor: cssVar("--muted", "#475569"),
        lineColor: cssVar("--muted", "#475569"),
        lineWidth: 1,
        lineStyle: "dashed",
        hoverOnly: true,
        showLowerExtension: false,
      }];
    }

    const boxBottom = s.h - 8;
    const k = byX.get(x);
    let offsetY = 0;
    for (const item of renderItems) {
      ctx.save();
      ctx.font = `bold ${item.fontSize}px Consolas`;
      const textW = ctx.measureText(item.text).width;
      const lineH = item.fontSize + boxPadY * 2;
      const rectW = textW + boxPadX * 2;
      const rectX = xp - rectW / 2;
      const rectY = boxBottom - offsetY - lineH;
      if (item.showLowerExtension !== false) {
        const anchorX = Number.isFinite(Number(item.anchorX)) ? Number(item.anchorX) : x;
        const anchorK = byX.get(anchorX) || k;
        if (anchorK) {
          const anchorXp = s.x(Math.max(s.xMin, Math.min(s.xMax, anchorX)));
          const anchorPrice = item.isBuy ? anchorK.l : anchorK.h;
          const anchorY = s.y(anchorPrice);
          const toY = Math.max(PAD_T + 2, Math.min(s.h - getLayoutPadB() + 8, rectY - 6));
          ctx.save();
          ctx.lineWidth = Number(item.lineWidth || 1);
          ctx.setLineDash(getTradeLineDash(item.lineStyle || "dashed"));
          ctx.strokeStyle = item.lineColor;
          ctx.beginPath();
          ctx.moveTo(anchorXp, anchorY);
          ctx.lineTo(xp, toY);
          ctx.stroke();
          ctx.restore();
        }
      }
      ctx.fillStyle = cssVar("--panel", "#ffffff");
      ctx.strokeStyle = item.borderColor;
      ctx.lineWidth = 1.5;
      ctx.fillRect(rectX, rectY, rectW, lineH);
      ctx.strokeRect(rectX, rectY, rectW, lineH);
      ctx.fillStyle = item.textColor;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(item.text, xp, rectY + lineH / 2);
      if (item.tipText) {
        signalHoverBoxes.push({
          x1: rectX,
          y1: rectY,
          x2: rectX + rectW,
          y2: rectY + lineH,
          text: item.tipText,
          overflowOnly: !!item.hoverOnly,
        });
      }
      ctx.restore();
      offsetY += lineH + boxGap;
    }
  }
}

function drawUserRays(s) {
  if (!userRays || userRays.length === 0) return;
  ctx.save();
  ctx.font = `${chartConfig.userRay.fontSize}px Consolas`;
  // 这里刻意使用 forEach + return。
  // 注意：forEach 回调里不能写 continue，否则会触发
  // "Illegal continue statement" 并导致整段前端脚本失效。
  userRays.forEach((ray, idx) => {
    ctx.lineWidth = getRayLineWidth(ray);
    ctx.strokeStyle = getRayLineColor(ray);
    ctx.setLineDash(getTradeLineDash(getRayLineStyle(ray)));
    const xp = s.x(ray.x);
    const yp = s.y(ray.y);
    const xEnd = s.w - PAD_R;
    if (xp > xEnd) return;
    ctx.beginPath();
    ctx.moveTo(xp, yp);
    ctx.lineTo(xEnd, yp);
    ctx.stroke();
    
    // Draw price at the end
    ctx.fillStyle = getRayLineColor(ray);
    ctx.fillText(ray.y.toFixed(2), xEnd + 4, yp + (chartConfig.userRay.fontSize / 3));
    if (selectedDrawing && selectedDrawing.type === "ray" && selectedDrawing.index === idx) {
      ctx.save();
      ctx.setLineDash([]);
      ctx.strokeStyle = "#2563eb";
      ctx.lineWidth = 2;
      ctx.strokeRect(xp - 4, yp - 4, 8, 8);
      ctx.restore();
    }
    
    // label for deletion if crosshair or mouse is near
    if (crosshairX !== null && crosshairY !== null) {
      const cxp = crosshairX;
      const cyp = crosshairY;
      if (Math.abs(cyp - yp) < 8 && cxp >= xp - 10 && cxp <= xEnd + 10) {
         ctx.fillStyle = "#ef4444";
         ctx.font = `bold ${chartConfig.userRay.fontSize}px sans-serif`;
         ctx.fillText("双击删除射线", xp + 5, yp - 5);
      }
    }
  });
  ctx.restore();
}

function xFromPx(s, px) {
  const xSpan = Math.max(1, s.xMax - s.xMin);
  const plotW = Math.max(1, s.plotW);
  const clamped = Math.max(PAD_L, Math.min(s.w - PAD_R, px));
  return s.xMin + ((clamped - PAD_L) / plotW) * xSpan;
}

function getNearestBiEndpoint(chart, s, px, py, maxDistPx = 12) {
  if (!chart || !Array.isArray(chart.bi)) return null;
  const list = chart.bi || [];
  let best = null;
  let bestD2 = maxDistPx * maxDistPx;
  const pushCandidate = (x, y) => {
    const cx = s.x(x);
    const cy = s.y(y);
    const dx = cx - px;
    const dy = cy - py;
    const d2 = dx * dx + dy * dy;
    if (d2 <= bestD2) {
      bestD2 = d2;
      best = { x, y };
    }
  };
  for (const bi of list) {
    if (bi == null) continue;
    if (Number.isFinite(bi.x1) && Number.isFinite(bi.y1)) pushCandidate(bi.x1, bi.y1);
    if (Number.isFinite(bi.x2) && Number.isFinite(bi.y2)) pushCandidate(bi.x2, bi.y2);
  }
  return best;
}

function drawUserQuantityRays(s, chart) {
  const list = quantityRaysForActiveSession();
  if (!list || list.length === 0) return;
  ctx.save();
  try {
    const rayCfg = chartConfig.userRay || DEFAULT_CHART_CONFIG.userRay;
    ctx.font = `${rayCfg.fontSize}px Consolas`;
    const strokeSeg = (x0, y0, x1, y1, dashed) => {
      ctx.setLineDash(dashed ? getTradeLineDash("dashed") || [8, 4] : []);
      ctx.beginPath();
      ctx.moveTo(x0, y0);
      ctx.lineTo(x1, y1);
      ctx.stroke();
    };
    list.forEach((r) => {
      if (!r) return;
      const spec = resolveQuantityRayDrawSpec(chart, s, r);
      if (!spec) return;
      const { p1d, p2d, allDashed, segments } = spec;
      const p1x = s.x(p1d.x);
      const p1y = s.y(p1d.y);
      if (!Number.isFinite(p1x) || !Number.isFinite(p1y)) return;
      if (p1x > s.w - PAD_R) return;
      ctx.lineWidth = getRayLineWidth(r);
      ctx.strokeStyle = getRayLineColor(r) || "#a855f7";
      for (const seg of segments) {
        const x0 = s.x(seg.from.x);
        const y0 = s.y(seg.from.y);
        const x1 = seg.to.px != null ? seg.to.px : s.x(seg.to.x);
        const y1 = seg.to.py != null ? seg.to.py : s.y(seg.to.y);
        if (!Number.isFinite(x0) || !Number.isFinite(y0) || !Number.isFinite(x1) || !Number.isFinite(y1)) continue;
        strokeSeg(x0, y0, x1, y1, !!seg.dashed);
      }
      const qLabel = Number.isFinite(Number(r.createdQty != null ? r.createdQty : r.quantity))
        ? Math.floor(Number(r.createdQty != null ? r.createdQty : r.quantity))
        : "-";
      ctx.save();
      ctx.setLineDash([]);
      ctx.fillStyle = getRayLineColor(r) || "#a855f7";
      ctx.font = `bold ${Math.max(10, rayCfg.fontSize)}px sans-serif`;
      const styleHint = allDashed ? "虚" : "实+虚";
      ctx.fillText(`数量:${qLabel}(${styleHint})`, p1x + 4, p1y - 6);
      const markCircle = (px, py) => {
        if (!Number.isFinite(px) || !Number.isFinite(py)) return;
        ctx.beginPath();
        ctx.arc(px, py + 10, 7, 0, Math.PI * 2);
        ctx.strokeStyle = getRayLineColor(r) || "#a855f7";
        ctx.lineWidth = 2;
        ctx.setLineDash([]);
        ctx.stroke();
      };
      markCircle(p1x, p1y);
      if (p2d) {
        markCircle(s.x(p2d.x), s.y(p2d.y));
      }
      ctx.restore();
      if (crosshairX !== null && crosshairY !== null) {
        if (hitTestQuantityRayPx(chart, s, r, crosshairX, crosshairY, 8)) {
          ctx.fillStyle = "#ef4444";
          ctx.font = `bold ${rayCfg.fontSize}px sans-serif`;
          ctx.fillText("双击删除数量射线", p1x + 5, crosshairY - 5);
        }
      }
    });
  } catch (err) {
    console.warn("drawUserQuantityRays:", err);
  } finally {
    ctx.restore();
  }
}

function drawUserBiRays(s, chart) {
  if (!userBiRays || userBiRays.length === 0) return;
  ctx.save();
  // 同上：需要跳过当前回调时统一使用 return，避免继续踩到 JS 语法坑。
  // 每组比例线：用同色圆圈标注选中的两个端点
  const ratioGroups = new Map(); // groupId -> { color, a1, a2 }
  userBiRays.forEach((r) => {
    if (!r || r.kind !== "ratioLine") return;
    const gid = r.groupId ? String(r.groupId) : "";
    if (!gid || ratioGroups.has(gid)) return;
    const a1 = r.anchor1;
    const a2 = r.anchor2;
    if (!a1 || !a2) return;
    if (!Number.isFinite(Number(a1.x)) || !Number.isFinite(Number(a1.y)) || !Number.isFinite(Number(a2.x)) || !Number.isFinite(Number(a2.y))) return;
    ratioGroups.set(gid, { color: String(r.groupColor || r.lineColor || "") || getRayLineColor(r), a1, a2 });
  });
  if (ratioGroups.size > 0) {
    ctx.save();
    ctx.setLineDash([]);
    ctx.lineWidth = 2;
    ratioGroups.forEach((g) => {
      ctx.strokeStyle = g.color || "#f97316";
      const drawOne = (pt) => {
        const xp = s.x(Number(pt.x));
        const yp = s.y(Number(pt.y));
        if (!Number.isFinite(xp) || !Number.isFinite(yp)) return;
        ctx.beginPath();
        ctx.arc(xp, yp, 9, 0, Math.PI * 2);
        ctx.stroke();
      };
      drawOne(g.a1);
      drawOne(g.a2);
    });
    ctx.restore();
  }
  userBiRays.forEach((r, idx) => {
    const isPara = !!(r && r.kind === "parallelogram");
    const paraVerts = isPara ? getParallelogramVerts(r) : null;
    if (isPara && paraVerts && paraVerts.length >= 4) {
      const isHovered = !!(hoveredBiRay && hoveredBiRay.type === "biRay" && hoveredBiRay.index === idx);
      const baseColor = getRayLineColor(r);
      ctx.lineWidth = isHovered ? Math.max(2, getRayLineWidth(r) + 1) : getRayLineWidth(r);
      ctx.strokeStyle = baseColor;
      ctx.setLineDash(getTradeLineDash(getRayLineStyle(r)));
      const pxs = paraVerts.map((v) => ({ x: s.x(v.x), y: s.y(v.y) }));
      if (pxs.every((p) => Number.isFinite(p.x) && Number.isFinite(p.y))) {
        ctx.beginPath();
        ctx.moveTo(pxs[0].x, pxs[0].y);
        for (let i = 1; i < pxs.length; i += 1) ctx.lineTo(pxs[i].x, pxs[i].y);
        ctx.closePath();
        ctx.globalAlpha = 0.08;
        ctx.fillStyle = baseColor;
        ctx.fill();
        ctx.globalAlpha = 1;
        ctx.stroke();
      }
      if (selectedDrawing && selectedDrawing.type === "biRay" && selectedDrawing.index === idx) {
        ctx.save();
        ctx.setLineDash([]);
        ctx.strokeStyle = "#2563eb";
        ctx.lineWidth = 2;
        pxs.forEach((p) => {
          ctx.strokeRect(p.x - 4, p.y - 4, 8, 8);
        });
        ctx.restore();
      }
      return;
    }
    const isRatio = !!(r && r.kind === "ratioLine");
    const isHovered = !!(hoveredBiRay && hoveredBiRay.type === "biRay" && hoveredBiRay.index === idx);
    const isDragging = !!(draggingRatioLine && Number(draggingRatioLine.index) === idx);
    const isActiveRatio = isRatio && (isHovered || isDragging);
    const baseColor = getRayLineColor(r);
    ctx.lineWidth = isActiveRatio ? Math.max(2, getRayLineWidth(r) + 1) : getRayLineWidth(r);
    // 比例线按组色显示；悬停/拖拽时仅加粗，不强行改色（避免多组同屏时难以分辨）
    ctx.strokeStyle = baseColor;
    ctx.setLineDash(getTradeLineDash(getRayLineStyle(r)));
    const x1 = Number(r.x1), y1 = Number(r.y1), x2 = Number(r.x2), y2 = Number(r.y2);
    if (!Number.isFinite(x1) || !Number.isFinite(y1) || !Number.isFinite(x2) || !Number.isFinite(y2)) return;
    const dx = (x2 - x1);
    if (!Number.isFinite(dx) || dx === 0) return;
    const slope = (y2 - y1) / dx;
    const xEnd = s.xMax;
    const yEnd = y1 + slope * (xEnd - x1);
    const p1x = s.x(x1);
    const p1y = s.y(y1);
    const p2x = s.x(xEnd);
    const p2y = s.y(yEnd);
    if (p1x > s.w - PAD_R) return;
    ctx.beginPath();
    ctx.moveTo(p1x, p1y);
    ctx.lineTo(p2x, p2y);
    ctx.stroke();
    if (isRatio) {
      ctx.save();
      ctx.setLineDash([]);
      ctx.fillStyle = baseColor;
      ctx.font = `bold ${Math.max(10, chartConfig.userRay.fontSize - 1)}px sans-serif`;
      const ratioVal = getRatioLineDynamicRatio(r);
      const ratioText = Number.isFinite(ratioVal) ? ratioVal.toFixed(3) : "-";
      const priceText = Number.isFinite(y1) ? y1.toFixed(2) : "-";
      ctx.fillText(`${ratioText} @ ${priceText}`, p1x + 4, p1y - 4);
      // 右侧也显示比例+价格，便于多条比例线快速对照
      ctx.textAlign = "left";
      ctx.textBaseline = "middle";
      ctx.fillText(`${ratioText} | ${priceText}`, Math.min(s.w - PAD_R + 6, p2x + 6), p2y);
      ctx.restore();
    }
    if (selectedDrawing && selectedDrawing.type === "biRay" && selectedDrawing.index === idx) {
      ctx.save();
      ctx.setLineDash([]);
      ctx.strokeStyle = "#2563eb";
      ctx.lineWidth = 2;
      ctx.strokeRect(p1x - 4, p1y - 4, 8, 8);
      ctx.restore();
    }

    if (crosshairX !== null && crosshairY !== null) {
      const xVal = xFromPx(s, crosshairX);
      if (xVal >= x1) {
        const yVal = y1 + slope * (xVal - x1);
        const yPx = s.y(yVal);
        if (Math.abs(yPx - crosshairY) < 8) {
          ctx.fillStyle = "#ef4444";
          ctx.font = `bold ${chartConfig.userRay.fontSize}px sans-serif`;
          ctx.fillText("双击删除射线", p1x + 5, yPx - 5);
        }
      }
    }
  });
  ctx.restore();
}

function drawPendingBiEndpointCircle(s) {
  const drawOne = (pt) => {
    if (!pt || !Number.isFinite(pt.x) || !Number.isFinite(pt.y)) return;
    const xp = s.x(pt.x);
    const yp = s.y(pt.y);
    if (!Number.isFinite(xp) || !Number.isFinite(yp)) return;
    ctx.beginPath();
    ctx.arc(xp, yp, 10, 0, Math.PI * 2);
    ctx.stroke();
  };
  const pending = [];
  if (Array.isArray(pendingBiRayPts) && pendingBiRayPts.length === 1) pending.push(...pendingBiRayPts);
  if (Array.isArray(pendingRatioLinePts) && pendingRatioLinePts.length === 1) pending.push(...pendingRatioLinePts);
  if (Array.isArray(pendingParallelogramPts) && pendingParallelogramPts.length > 0) {
    pending.push(...pendingParallelogramPts);
    if (pendingParallelogramPts.length >= 2) {
      const v2 = buildParallelogramVerts(
        pendingParallelogramPts[0],
        pendingParallelogramPts[1],
        pendingParallelogramPts[2] || pendingParallelogramPts[1]
      );
      if (v2 && v2.length >= 4) {
        ctx.save();
        ctx.strokeStyle = "#2563eb";
        ctx.lineWidth = 1.5;
        ctx.setLineDash([4, 4]);
        const pxs = v2.map((v) => ({ x: s.x(v.x), y: s.y(v.y) }));
        ctx.beginPath();
        ctx.moveTo(pxs[0].x, pxs[0].y);
        for (let i = 1; i < pxs.length; i += 1) ctx.lineTo(pxs[i].x, pxs[i].y);
        ctx.closePath();
        ctx.stroke();
        ctx.restore();
      }
    }
  }
  if (Array.isArray(pendingQuantityRayPts) && pendingQuantityRayPts.length > 0) {
    const chart = lastPayload && lastPayload.chart;
    if (chart) {
      pendingQuantityRayPts.forEach((a) => {
        const pt = resolveQuantityRayAnchor(chart, a);
        if (pt) pending.push(pt);
      });
    }
  }
  if (pending.length <= 0) return;
  ctx.save();
  ctx.strokeStyle = "#2563eb";
  ctx.lineWidth = 2;
  ctx.setLineDash([]);
  pending.forEach((pt) => drawOne(pt));
  ctx.restore();
}

function drawZsRects(arr, s, color, width) {
  ctx.save();
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  for (const zs of arr || []) {
    const loX = Math.min(zs.x1, zs.x2);
    const hiX = Math.max(zs.x1, zs.x2);
    if (hiX < s.xMin || loX > s.xMax) continue;
    const x1 = s.x(loX);
    const x2 = s.x(hiX);
    const yTop = s.y(zs.high);
    const yBottom = s.y(zs.low);
    const rectX = Math.min(x1, x2);
    const rectY = Math.min(yTop, yBottom);
    const rectW = Math.max(1, Math.abs(x2 - x1));
    const rectH = Math.max(1, Math.abs(yBottom - yTop));
    if (!zs.is_sure) ctx.setLineDash([6, 4]);
    else ctx.setLineDash([]);
    ctx.strokeRect(rectX, rectY, rectW, rectH);
  }
  ctx.restore();
}

/** 缠论主图装饰：合并框、中枢框、分型/笔/段/2段线、节奏线（不含 K 线蜡烛） */
function drawMainChartChanDecor(chart, s) {
  drawKlineCombineFrames(chart, s);
  if (activeDrawStyle().fractZs.enabled) {
    drawZsRects(chart.fract_zs || [], s, getCfgColor(activeDrawStyle().fractZs.color), activeDrawStyle().fractZs.width);
  }
  if (activeDrawStyle().biZs.enabled) {
    drawZsRects(chart.bi_zs || [], s, getCfgColor(activeDrawStyle().biZs.color), activeDrawStyle().biZs.width);
  }
  if (activeDrawStyle().segZs.enabled) {
    drawZsRects(chart.seg_zs || [], s, getCfgColor(activeDrawStyle().segZs.color), activeDrawStyle().segZs.width);
  }
  if (activeDrawStyle().segsegZs.enabled) {
    drawZsRects(chart.segseg_zs || [], s, getCfgColor(activeDrawStyle().segsegZs.color), activeDrawStyle().segsegZs.width);
  }
  customSegmentLevelsFromConfig(activeDrawStyle()).forEach((level) => {
    const key = zsConfigKeyForLevel(level);
    const cfg = activeDrawStyle()[key];
    if (cfg && cfg.enabled !== false) {
      drawZsRects((chart.extra_zs && chart.extra_zs[level]) || [], s, getCfgColor(cfg.color), cfg.width);
    }
  });
  drawLines(chart.fx_lines || [], s, getCfgColor(activeDrawStyle().fx.color), activeDrawStyle().fx.width, true);
  drawLines((chart.fract || []).filter((x) => x.is_sure), s, getCfgColor(activeDrawStyle().fract.color), activeDrawStyle().fract.widthSure, false);
  drawLines((chart.fract || []).filter((x) => !x.is_sure), s, getCfgColor(activeDrawStyle().fract.color), activeDrawStyle().fract.widthUnsure, true);
  drawLines((chart.bi || []).filter((x) => x.is_sure), s, getCfgColor(activeDrawStyle().bi.color), activeDrawStyle().bi.widthSure, false);
  drawLines((chart.bi || []).filter((x) => !x.is_sure), s, getCfgColor(activeDrawStyle().bi.color), activeDrawStyle().bi.widthUnsure, true);
  drawLines((chart.seg || []).filter((x) => x.is_sure), s, getCfgColor(activeDrawStyle().seg.color), activeDrawStyle().seg.widthSure, false);
  drawLines((chart.seg || []).filter((x) => !x.is_sure), s, getCfgColor(activeDrawStyle().seg.color), activeDrawStyle().seg.widthUnsure, true);
  drawLines((chart.segseg || []).filter((x) => x.is_sure), s, getCfgColor(activeDrawStyle().segseg.color), activeDrawStyle().segseg.widthSure, false);
  drawLines((chart.segseg || []).filter((x) => !x.is_sure), s, getCfgColor(activeDrawStyle().segseg.color), activeDrawStyle().segseg.widthUnsure, true);
  customSegmentLevelsFromConfig(activeDrawStyle()).forEach((level) => {
    const key = lineConfigKeyForLevel(level);
    const cfg = activeDrawStyle()[key];
    const arr = (chart.extra_levels && chart.extra_levels[level]) || [];
    if (!cfg || !arr.length) return;
    drawLines(arr.filter((x) => x.is_sure), s, getCfgColor(cfg.color), cfg.widthSure, false);
    drawLines(arr.filter((x) => !x.is_sure), s, getCfgColor(cfg.color), cfg.widthUnsure, true);
  });
  drawRhythmLines(chart.rhythm_lines || [], s);
}

/** K 线蜡烛 + 合并框 + 缠论线/中枢/节奏（不含筹码与底部 BSP）；paintOpts.layerStyle 多周期叠层按周期样式。 */
function drawMainChartLayers(chart, s, paintOpts = {}) {
  if (!chart || !chart.kline || chart.kline.length === 0) return;
  const prevCtx = drawStyleCtx;
  if (paintOpts && paintOpts.layerStyle) drawStyleCtx = paintOpts.layerStyle;
  const decor = paintOpts.drawChanDecor !== false;
  const sga = Number(paintOpts.structureGlobalAlpha);
  const useSga = Number.isFinite(sga) && sga < 0.999;
  try {
    if (!paintOpts.skipCandles) {
      drawCandles(chart, s, paintOpts);
    }
    if (decor) {
      if (useSga) {
        ctx.save();
        ctx.globalAlpha = Math.min(1, Math.max(0.05, sga));
        drawMainChartChanDecor(chart, s);
        ctx.restore();
      } else {
        drawMainChartChanDecor(chart, s);
      }
    }
  } finally {
    drawStyleCtx = prevCtx;
  }
}

function drawMultiLayers(payload) {
  if (dualInternalRenderDepth === 0 && isDualRuntimeReady()) {
    drawDualCharts(payload);
    return;
  }
  const driverChart = payload.chart;
  if (!driverChart || !driverChart.kline || driverChart.kline.length === 0) return;
  const { w: cw, h: ch } = readCanvasCssSize(canvas);
  ctx.clearRect(0, 0, cw, ch);
  signalHoverBoxes = [];
  ctx.fillStyle = cssVar("--chartBg", "#ffffff");
  ctx.fillRect(0, 0, cw, ch);
  const xMin = Math.max(allXMin, viewXMin);
  const xMax = viewXMax;
  const s = toScaler(driverChart, xMin, xMax);
  drawGridLines(s);
  drawChips(driverChart, s);
  drawTradeBands(s, driverChart);
  drawTradeRays(s);
  drawAxes(s);
  drawIndicators(driverChart, s);
  const mo = chartConfig.multiOverlay || { defaultAlpha: 0.58, defaultCandleWidth: 1.2, layers: {} };
  const layers = Array.isArray(payload.chart_layers) ? payload.chart_layers : [];
  const hidden = new Set(Array.isArray(sessionConfig.multiLayerHidden) ? sessionConfig.multiLayerHidden : []);

  const drawOneLayer = (layer, paintExtra) => {
    const ch = layer.chart;
    if (!ch || !ch.kline || ch.kline.length === 0) return;
    const kt = String(layer.k_type || "");
    if (hidden.has(kt)) return;
    const isDriver = layer.role === "driver";
    const L = (mo.layers && mo.layers[kt]) || {};
    const candleBak = JSON.parse(JSON.stringify(chartConfig.candle));
    try {
      if (!isDriver) {
        const cMul = Number(L.candleWidth != null ? L.candleWidth : mo.defaultCandleWidth);
        chartConfig.candle.width = Number(candleBak.width || chartConfig.candle.width) * cMul;
        if (L.upColor) chartConfig.candle.upColor = L.upColor;
        if (L.downColor) chartConfig.candle.downColor = L.downColor;
      }
      drawMainChartLayers(ch, s, {
        overlaySpanCandles: !isDriver,
        driverKlineForOverlaySpan: driverChart.kline,
        layerStyle: getMultiLayerDrawConfig(kt),
        overlayKtKey: kt,
        coarseOverlayOpts: !isDriver ? resolveCoarseOverlayPaintOpts(mo, kt) : null,
        ...paintExtra,
      });
    } finally {
      chartConfig.candle = candleBak;
    }
  };

  layers.forEach((layer) => {
    if (layer.role === "driver") return;
    drawOneLayer(layer, { overlayCandlePhase: "shadows", skipCandles: false, drawChanDecor: false });
  });
  layers.forEach((layer) => {
    if (layer.role === "driver") return;
    drawOneLayer(layer, { overlayCandlePhase: "bodies", skipCandles: false, drawChanDecor: false });
  });
  layers.forEach((layer) => {
    if (layer.role === "driver") return;
    const kt = String(layer.k_type || "");
    const o = resolveCoarseOverlayPaintOpts(mo, kt);
    drawOneLayer(layer, {
      skipCandles: true,
      drawChanDecor: true,
      structureGlobalAlpha: o.lineAlpha,
    });
  });
  layers.forEach((layer) => {
    if (layer.role !== "driver") return;
    drawOneLayer(layer, {});
  });

  drawBottomSignals(driverChart, s);
  drawUserRays(s);
  drawUserBiRays(s, driverChart);
  drawUserQuantityRays(s, driverChart);
  drawPendingBiEndpointCircle(s);
  drawTradeMarkers(s, driverChart);
  drawCrosshair(driverChart, s);
  drawLegend();
}

function drawFromLastPayload() {
  if (!lastPayload || !lastPayload.ready) return;
  if (lastPayload.chart_mode === "multi" && Array.isArray(lastPayload.chart_layers) && lastPayload.chart_layers.length > 0) {
    drawMultiLayers(lastPayload);
    return;
  }
  if (lastPayload.chart) draw(lastPayload.chart);
}

function draw(chart) {
  if (dualInternalRenderDepth === 0 && isDualRuntimeReady()) {
    drawDualCharts(lastPayload);
    return;
  }
  const { w: cw, h: ch } = readCanvasCssSize(canvas);
  ctx.clearRect(0, 0, cw, ch);
  signalHoverBoxes = [];
  ctx.fillStyle = cssVar("--chartBg", "#ffffff");
  ctx.fillRect(0, 0, cw, ch);
  if (!chart || !chart.kline || chart.kline.length === 0) return;

  const xMin = Math.max(allXMin, viewXMin);
  const xMax = viewXMax; // 允许右侧空白
  const s = toScaler(chart, xMin, xMax);

  drawGridLines(s);
  drawChips(chart, s);
  drawTradeBands(s, chart);
  drawTradeRays(s);
  drawAxes(s);
  drawIndicators(chart, s);
  drawMainChartLayers(chart, s);
  drawBottomSignals(chart, s);
  drawUserRays(s);
  drawUserBiRays(s, chart);
  drawUserQuantityRays(s, chart);
  drawPendingBiEndpointCircle(s);
  drawTradeMarkers(s, chart);
  drawCrosshair(chart, s);
  drawLegend();
}

/** 与 a_replay_multi_xmap._parse_chart_time_ms / 后端 strptime 顺序一致，用本地年月日时分秒，避免 `new Date("...")` 各浏览器歧义导致叠图时间窗多/少包 1 根细 K。 */
function parseChartTimeToMs(text) {
  const s0 = String(text || "").trim();
  if (!s0) return NaN;
  const localTs = (y, mo, d, hh, mm, ss) => {
    const dt = new Date(y, mo - 1, d, hh | 0, mm | 0, ss | 0, 0);
    return Number.isFinite(dt.getTime()) ? dt.getTime() : NaN;
  };
  const rows = [
    [/^(\d{4})\/(\d{1,2})\/(\d{1,2})\s+(\d{1,2}):(\d{1,2}):(\d{1,2})$/, 6],
    [/^(\d{4})\/(\d{1,2})\/(\d{1,2})\s+(\d{1,2}):(\d{1,2})$/, 5],
    [/^(\d{4})\/(\d{1,2})\/(\d{1,2})$/, 3],
    [/^(\d{4})-(\d{1,2})-(\d{1,2})\s+(\d{1,2}):(\d{1,2}):(\d{1,2})$/, 6],
    [/^(\d{4})-(\d{1,2})-(\d{1,2})\s+(\d{1,2}):(\d{1,2})$/, 5],
    [/^(\d{4})-(\d{1,2})-(\d{1,2})$/, 3],
  ];
  for (const cand of [s0, s0.replace(/\//g, "-")]) {
    for (const [re, n] of rows) {
      const m = cand.match(re);
      if (!m) continue;
      const y = +m[1],
        mo = +m[2],
        d = +m[3];
      const hh = n >= 5 ? +m[4] : 0;
      const mm = n >= 5 ? +m[5] : 0;
      const ss = n >= 6 ? +m[6] : 0;
      const t = localTs(y, mo, d, hh, mm, ss);
      if (Number.isFinite(t)) return t;
    }
  }
  const dt = new Date(s0.replace(/\//g, "-"));
  return Number.isFinite(dt.getTime()) ? dt.getTime() : NaN;
}

function findNearestKByTime(chart, anchorTime) {
  if (!chart || !Array.isArray(chart.kline) || chart.kline.length === 0) return null;
  const targetMs = parseChartTimeToMs(anchorTime);
  if (!Number.isFinite(targetMs)) return chart.kline[chart.kline.length - 1];
  let best = chart.kline[0];
  let bestDiff = Math.abs(parseChartTimeToMs(best.t) - targetMs);
  for (const k of chart.kline) {
    const ms = parseChartTimeToMs(k.t);
    if (!Number.isFinite(ms)) continue;
    const diff = Math.abs(ms - targetMs);
    if (diff < bestDiff) {
      bestDiff = diff;
      best = k;
    }
  }
  return best;
}

function getKTypeLabelText(v) {
  const map = {
    "1min": "1分钟", "3min": "3分钟", "5min": "5分钟", "15min": "15分钟",
    "30min": "30分钟", "60min": "60分钟", "daily": "日线", "weekly": "周线",
    "monthly": "月线", "quarterly": "季线", "yearly": "年线",
  };
  return map[String(v || "").toLowerCase()] || String(v || "-");
}

/** 写入消息历史的数据源摘要（与后端 src_per_chart 对齐） */
function buildSessionSourceHistoryLine(payload) {
  if (!payload || !payload.ready || !payload.code) return "";
  const code = String(payload.code || "").trim();
  const sp = payload.src_per_chart;
  if (payload.chart_mode === "dual" && sp && sp.chart1 && sp.chart2) {
    const a = sp.chart1;
    const b = sp.chart2;
    const k1 = String(a.k_type || "daily");
    const k2 = String(b.k_type || "daily");
    const lk = (v) => String(v || "-").trim();
    return `${code}，当前数据源${k1}K线：【${lk(a.kline_label)}】，${k2}K线：【${lk(b.kline_label)}】。${k1}筹码：【${lk(a.chip_label)}】，${k2}筹码：【${lk(b.chip_label)}】`;
  }
  const kt = (sp && sp.chart1 && sp.chart1.k_type) ? String(sp.chart1.k_type) : (($("kType") && $("kType").value) || "daily");
  const info = payload.data_source || {};
  const lab = String(info.label || "-").trim();
  const chip = String(info.chip_label || lab).trim();
  return `${code}，当前数据源${kt}K线：【${lab}】。${kt}筹码：【${chip}】`;
}

function buildPaneTitle(payload, chartId) {
  const name = String((payload && payload.name) || "").trim();
  const code = String((payload && payload.code) || "").trim();
  const base = name ? `${name}（${code || "-"}）` : (code || "-");
  const k1 = ($("kType") && $("kType").value) || (sessionConfig && sessionConfig.kType) || "daily";
  const k2 = ($("kType2") && $("kType2").value) || (sessionConfig && sessionConfig.kType2) || k1;
  const kt = chartId === "chart2" ? k2 : k1;
  return `${base} - ${getKTypeLabelText(kt)}`;
}

function syncDualCrosshairByTime(payload) {
  if (!crosshairEnabled || !payload || !payload.charts) return;
  const activeId = dualActiveChartId === "chart2" ? "chart2" : "chart1";
  const activeChart = payload.charts[activeId];
  const activeState = getRuntimeState(activeId);
  if (!activeChart || !activeState || !Number.isFinite(activeState.crosshairX)) return;
  loadRuntimeState(activeId);
  const sActive = toScaler(activeChart, Math.max(allXMin, viewXMin), viewXMax, activeId);
  const xSpan = Math.max(1, sActive.xMax - sActive.xMin);
  const localX = Math.max(PAD_L, Math.min(sActive.w - PAD_R, activeState.crosshairX));
  const targetX = sActive.xMin + ((localX - PAD_L) / Math.max(1, sActive.plotW)) * xSpan;
  const ref = nearestKByX(getVisibleKs(activeChart, sActive.xMin, sActive.xMax), targetX);
  const anchorTime = ref && ref.t ? ref.t : (payload.time_anchor || payload.time || "");
  DUAL_CHART_IDS.forEach((chartId) => {
    const chart = payload.charts[chartId];
    if (!chart) return;
    const st = getRuntimeState(chartId);
    loadRuntimeState(chartId);
    const s = toScaler(chart, Math.max(allXMin, viewXMin), viewXMax, chartId);
    const nk = findNearestKByTime(chart, anchorTime);
    if (nk) {
      st.crosshairX = s.x(nk.x);
      st.crosshairY = s.y(nk.c);
    }
  });
  loadRuntimeState(activeId);
}

function drawDualCharts(payload) {
  if (!payload || !payload.charts || !payload.charts.chart1 || !payload.charts.chart2) {
    if (payload && payload.chart_mode === "multi" && Array.isArray(payload.chart_layers) && payload.chart_layers.length > 0) {
      drawMultiLayers(payload);
    } else {
      draw(payload && payload.chart ? payload.chart : null);
    }
    return;
  }
  const activeId = (payload.active_chart_id === "chart2") ? "chart2" : "chart1";
  dualActiveChartId = activeId;
  saveRuntimeState(activeId);
  syncDualCrosshairByTime(payload);
  const panes = getDualPaneRects();
  const prevCanvas = canvas;
  const prevCtx = ctx;
  const prevCfg = chartConfig;
  rootCtx.clearRect(0, 0, rootCanvas.clientWidth, rootCanvas.clientHeight);
  rootCtx.fillStyle = cssVar("--chartBg", "#ffffff");
  rootCtx.fillRect(0, 0, rootCanvas.clientWidth, rootCanvas.clientHeight);
  dualInternalRenderDepth += 1;
  try {
    DUAL_CHART_IDS.forEach((chartId) => {
      const chart = payload.charts[chartId];
      const pane = panes[chartId];
      if (!chart || !pane || pane.w <= 20 || pane.h <= 20) return;
      const paneCanvas = document.createElement("canvas");
      paneCanvas.width = Math.max(1, Math.round(pane.w * window.devicePixelRatio));
      paneCanvas.height = Math.max(1, Math.round(pane.h * window.devicePixelRatio));
      paneCanvas.style.width = `${pane.w}px`;
      paneCanvas.style.height = `${pane.h}px`;
      const paneCtx = paneCanvas.getContext("2d");
      if (!paneCtx) return;
      const paneDpr = (typeof window !== "undefined" && window.devicePixelRatio) || 1;
      paneCtx.setTransform(paneDpr, 0, 0, paneDpr, 0, 0);
      canvas = paneCanvas;
      ctx = paneCtx;
      loadRuntimeState(chartId);
      chartConfig = chartId === "chart2" ? chartConfigStore.perChart.chart2 : chartConfigStore.perChart.chart1;
      chartConfig.theme = chartConfigStore.shared.theme || chartConfig.theme;
      chartConfig.crosshair = deepMerge(JSON.parse(JSON.stringify(chartConfig.crosshair || {})), chartConfigStore.shared.crosshair || {});
      draw(chart);
      saveRuntimeState(chartId);
      rootCtx.drawImage(paneCanvas, pane.x, pane.y, pane.w, pane.h);
      rootCtx.save();
      rootCtx.strokeStyle = chartId === activeId ? "#2563eb" : "rgba(148,163,184,0.55)";
      rootCtx.lineWidth = chartId === activeId ? 3 : 1.5;
      rootCtx.strokeRect(pane.x + 0.5, pane.y + 0.5, pane.w - 1, pane.h - 1);
      if (chartId === activeId) {
        rootCtx.fillStyle = "#2563eb";
        rootCtx.beginPath();
        rootCtx.moveTo(pane.x + 10, pane.y + 10);
        rootCtx.lineTo(pane.x + 44, pane.y + 10);
        rootCtx.lineTo(pane.x + 10, pane.y + 44);
        rootCtx.closePath();
        rootCtx.fill();
      }
      const title = buildPaneTitle(payload, chartId);
      rootCtx.fillStyle = "rgba(15,23,42,0.86)";
      rootCtx.font = "bold 14px Consolas";
      rootCtx.fillText(title, pane.x + 14, pane.y + 26);
      rootCtx.restore();
    });
  } finally {
    dualInternalRenderDepth -= 1;
    canvas = prevCanvas;
    ctx = prevCtx;
    chartConfig = prevCfg;
    loadRuntimeState(activeId);
  }
}

async function api(path, body, method = "POST", extraOptions = null) {
  const options = {
    method,
    headers: {"Content-Type": "application/json"}
  };
  if (extraOptions && typeof extraOptions === "object") {
    if (extraOptions.signal) options.signal = extraOptions.signal;
  }
  if (body !== null && body !== undefined) options.body = JSON.stringify(body);
  const res = await fetch(path, options);
  const data = await res.json();
  if (!res.ok) {
    const rawMessage = typeof data.detail === "string" ? data.detail : (data.detail && data.detail.reason_detail) || JSON.stringify(data.detail || data);
    if (String(rawMessage || "").includes("调用rust失败")) {
      try {
        const stRes = await fetch("/api/perf_cache_status", { method: "GET" });
        if (stRes.ok) appendRustHistoryFromPayload({ cache_info: await stRes.json() });
      } catch (_) {}
    }
    const err = new Error(
      rawMessage
    );
    if (data.detail && typeof data.detail === "object" && data.detail.type === "offline_confirm") {
      err.offlineConfirm = data.detail;
    }
    err.httpStatus = res.status;
    throw err;
  }
  return data;
}

async function checkBspJudge(reason) {
  if (!lastPayload || !lastPayload.ready) return;
  const payload = await api("/api/judge_bsp", { reason: reason || "manual_check" });
  refreshUI(payload, { afterStep: false });
}

function detectBspPromptOnLastBar(payload) {
  return getLatestBspNotice(payload);
}

async function stepOnce(logMessage) {
  const prevStepIdx = lastPayload && Number.isFinite(lastPayload.step_idx) ? Number(lastPayload.step_idx) : null;
  const payload = await api("/api/step", {
    judge_mode: systemConfig.bspJudgeMode || "auto",
    active_chart_id: (lastPayload && lastPayload.active_chart_id) ? lastPayload.active_chart_id : "chart1",
  });
  const bspNotice = detectBspPromptOnLastBar(payload);
  const rhythmTexts = getRhythmNoticeTexts(payload);
  const toastCfg = chartConfig && chartConfig.toast ? chartConfig.toast : DEFAULT_CHART_CONFIG.toast;
  const interruptedByBsp = shouldInterruptStepOnBspFine(bspNotice ? bspNotice.hits : []);
  const interruptedByRhythm = shouldInterruptStepOnRhythm1382() && rhythmTexts.length > 0;
  const bspOn = toastCfg.interruptOnBsp !== false;
  const rhythmOn = toastCfg.interruptOnRhythm1382 !== false;
  const interrupted = combineStepInterruptSources(
    bspOn,
    interruptedByBsp,
    rhythmOn,
    interruptedByRhythm,
    toastCfg.interruptStepSourcesCombine
  );
  const noticeText = buildStepNoticeText(payload, bspNotice);
  refreshUI(payload, { afterStep: true, showStandaloneNotices: false });
  const noticeShown = showCombinedNotice(noticeText);
  if (logMessage && !noticeShown) setMsg(payload.message || "步进成功");
  const reachedEnd = prevStepIdx !== null && Number(payload.step_idx) === prevStepIdx;
  return { payload, interrupted, reachedEnd, noticeShown };
}

function updateDataSourceStatus(payload) {
  const el = $("dataSourceStatus");
  if (!el) return;
  if (!payload || !payload.ready || !payload.data_source) {
    el.textContent = "当前数据源：未加载";
    el.title = "";
    return;
  }
  const info = payload.data_source || {};
  const label = String(info.label || "-");
  const chipLabel = String(info.chip_label || "").trim();
  const logs = Array.isArray(info.logs) ? info.logs.map((item) => String(item || "").trim()).filter(Boolean) : [];
  const chipPart = chipLabel && chipLabel !== label ? `（筹码：${chipLabel}）` : "";
  el.textContent = `当前数据源：${label}${chipPart}`;
  el.title = logs.join("\n");
  // 同步「系统配置」里数据源列表行上的小状态圆点（class 为 dataSourceStatus）
  document.querySelectorAll(".dataSourceStatus").forEach((span) => {
    const par = span.parentElement;
    if (!par || !par.dataset || !par.dataset.name) return;
    if (par.dataset.name === label) {
      span.textContent = "●";
      span.style.color = "#22c55e";
      span.title = "当前使用";
    }
  });
}

function updateCompactLayout() {
  const left = document.querySelector(".left");
  const scrollRegion = document.querySelector(".leftScrollRegion");
  const content = $("leftContent");
  if (!left || !content) return;
  content.style.transform = "scale(1)";
  content.style.width = "100%";
  left.classList.remove("compact");
  // 可滚动区域内高度：超出则 compact 缩放，避免与滚轮滚动抢空间
  const region = scrollRegion || left;
  const available = Math.max(100, region.clientHeight - 4);
  let contentHeight = content.scrollHeight;
  if (contentHeight <= available) return;
  left.classList.add("compact");
  contentHeight = content.scrollHeight;
  if (contentHeight <= available) return;
  const scale = Math.max(0.76, Math.min(1, available / Math.max(1, contentHeight)));
  content.style.transform = `scale(${scale})`;
  content.style.width = `${100 / scale}%`;
}

function syncRuntimeWindowFromChart(runtime, chart, afterStep) {
  if (!runtime || !chart || !Array.isArray(chart.kline) || chart.kline.length <= 0) return;
  const ks = chart.kline;
  runtime.allXMin = ks[0].x;
  runtime.allXMax = ks[ks.length - 1].x;
  if (!runtime.viewReady) {
    runtime.viewXMin = runtime.allXMin;
    runtime.viewXMax = runtime.allXMax;
    runtime.viewReady = true;
  } else if (!runtime.userAdjustedView) {
    runtime.viewXMin = runtime.allXMin;
    runtime.viewXMax = runtime.allXMax;
  } else {
    if (runtime.viewXMin < runtime.allXMin) runtime.viewXMin = runtime.allXMin;
    if (runtime.viewXMin >= runtime.viewXMax) {
      runtime.viewXMin = runtime.allXMin;
      runtime.viewXMax = runtime.allXMax;
      runtime.userAdjustedView = false;
    }
  }
  if (afterStep) {
    const lastX = ks[ks.length - 1].x;
    if (!(lastX >= runtime.viewXMin && lastX <= runtime.viewXMax)) {
      const span = runtime.viewXMax - runtime.viewXMin;
      if (span > 1) {
        let newMin = lastX - span * 0.85;
        let newMax = newMin + span;
        if (newMin < runtime.allXMin) {
          newMin = runtime.allXMin;
          newMax = newMin + span;
        }
        const rightMax = runtime.allXMax + Math.round(span * 2);
        if (newMax > rightMax) {
          newMax = rightMax;
          newMin = newMax - span;
        }
        runtime.viewXMin = Math.round(newMin);
        runtime.viewXMax = Math.round(newMax);
      }
    }
  }
}

async function fetchChipKlineAllLazy(payload) {
  if (!payload || !payload.ready || payload.chip_kline_all_lazy !== true) return;
  const cid = String((payload.active_chart_id) || "chart1");
  try {
    const r = await api(`/api/chip_kline_all?chart_id=${encodeURIComponent(cid)}`, null, "GET");
    if (!r || !Array.isArray(r.kline_all) || !r.kline_all.length) return;
    if (lastPayload && lastPayload.chart) {
      lastPayload.chart.kline_all = r.kline_all;
    }
    chipKlineAllCache = normalizeChipKlineAllX(r.kline_all);
    if (lastPayload && lastPayload.chart) {
      lastPayload.chart.kline_all = chipKlineAllCache;
    }
    const sid = chipSessionIdentity(lastPayload);
    if (sid) chipKlineAllCacheSessionKey = sid;
    // 懒加载完成后重绘一次，避免首屏停留在仅会话区间的筹码上。
    if (lastPayload && lastPayload.ready) scheduleChartRedraw();
  } catch (e) {
    console.warn("[chip] lazy kline_all failed", e);
  }
}

function refreshUI(payload, options) {
  const afterStep = options && options.afterStep;
  const showStandaloneNotices = options && Object.prototype.hasOwnProperty.call(options, "showStandaloneNotices")
    ? !!options.showStandaloneNotices
    : !afterStep;
  const prev = lastPayload;
  const chipSid = chipSessionIdentity(payload);
  if (chipSid && chipKlineAllCacheSessionKey && chipSid !== chipKlineAllCacheSessionKey) {
    chipKlineAllCache = null;
  }
  if (chipSid) chipKlineAllCacheSessionKey = chipSid;
  const dataFormChanged =
    prev &&
    payload &&
    prev.ready &&
    payload.ready &&
    prev.data_form &&
    payload.data_form &&
    (prev.data_form.mode !== payload.data_form.mode ||
      prev.data_form.quantity !== payload.data_form.quantity ||
      prev.data_form.quantity_alloc !== payload.data_form.quantity_alloc ||
      prev.data_form.feed_mode !== payload.data_form.feed_mode);
  // 稳定缓存 kline_all：避免后续 payload 省略时丢失筹码全历史
  if (
    payload &&
    payload.ready &&
    payload.chart &&
    Array.isArray(payload.chart.kline_all) &&
    payload.chart.kline_all.length > 0
  ) {
    if (!chipKlineAllCache || chipKlineAllCache.length === 0) {
      chipKlineAllCache = normalizeChipKlineAllX(payload.chart.kline_all);
    } else {
      chipKlineAllCache = normalizeChipKlineAllX(
        mergeChipKlineAllByTime(chipKlineAllCache, payload.chart.kline_all)
      );
    }
    // #region agent log
    __agentDebugLog(
      "H4",
      "a_replay_trainer.py:refreshUI:updateCacheFromPayload",
      "payload 主图更新 kline_all 缓存",
      {
        payloadHasKlineAll: true,
        payloadKlineAllCount: Array.isArray(payload.chart.kline_all) ? payload.chart.kline_all.length : 0,
        payloadKlineAllFirstT: Array.isArray(payload.chart.kline_all) && payload.chart.kline_all.length > 0 ? String(payload.chart.kline_all[0].t || "") : "",
        payloadKlineAllLastT: Array.isArray(payload.chart.kline_all) && payload.chart.kline_all.length > 0 ? String(payload.chart.kline_all[payload.chart.kline_all.length - 1].t || "") : "",
      },
      `payload-main:${Array.isArray(payload.chart.kline_all) ? payload.chart.kline_all.length : 0}|first:${Array.isArray(payload.chart.kline_all) && payload.chart.kline_all.length > 0 ? String(payload.chart.kline_all[0].t || "") : ""}`,
      300
    );
    // #endregion
  }
  if (payload && payload.ready && payload.chip_profile && Array.isArray(payload.chip_profile.prices)) {
    chipProfileCache = payload.chip_profile;
  } else if (!payload || !payload.ready) {
    chipProfileCache = null;
  }
  // 后端在步进等接口省略 kline_all；数据形式/数量变更时禁止沿用旧 kline_all（聚合根数已变）
  if (
    !dataFormChanged &&
    payload &&
    payload.ready &&
    payload.chart &&
    prev &&
    prev.ready &&
    prev.chart &&
    Array.isArray(prev.chart.kline_all) &&
    prev.chart.kline_all.length > 0
  ) {
    if (!Object.prototype.hasOwnProperty.call(payload.chart, "kline_all") || !payload.chart.kline_all || payload.chart.kline_all.length === 0) {
      payload.chart.kline_all = prev.chart.kline_all;
      // #region agent log
      __agentDebugLog(
        "H4",
        "a_replay_trainer.py:refreshUI:reusePrevChartKlineAll",
        "payload 缺失 kline_all 时复用 prev.chart",
        {
          dataFormChanged: !!dataFormChanged,
          prevCount: Array.isArray(prev.chart.kline_all) ? prev.chart.kline_all.length : 0,
          prevFirstT: Array.isArray(prev.chart.kline_all) && prev.chart.kline_all.length > 0 ? String(prev.chart.kline_all[0].t || "") : "",
          prevLastT: Array.isArray(prev.chart.kline_all) && prev.chart.kline_all.length > 0 ? String(prev.chart.kline_all[prev.chart.kline_all.length - 1].t || "") : "",
        },
        `reuse-prev:${Array.isArray(prev.chart.kline_all) ? prev.chart.kline_all.length : 0}`,
        300
      );
      // #endregion
    }
  }
  if (payload && payload.ready && payload.charts && typeof payload.charts === "object") {
    let activeId = String(payload.active_chart_id || "chart1") === "chart2" ? "chart2" : "chart1";
    if (dualActivePaneLock && payload.charts[dualLockedChartId]) {
      activeId = dualLockedChartId;
      payload.active_chart_id = dualLockedChartId;
    }
    sessionConfig.activeChartId = activeId;
    dualActiveChartId = activeId;
    if (payload.charts[activeId]) payload.chart = payload.charts[activeId];
    else if (payload.charts.chart1) payload.chart = payload.charts.chart1;
    if (
      payload.chart &&
      Array.isArray(payload.chart.kline_all) &&
      payload.chart.kline_all.length > 0
    ) {
      if (!chipKlineAllCache || chipKlineAllCache.length === 0) {
        chipKlineAllCache = normalizeChipKlineAllX(payload.chart.kline_all);
      } else {
        chipKlineAllCache = normalizeChipKlineAllX(
          mergeChipKlineAllByTime(chipKlineAllCache, payload.chart.kline_all)
        );
      }
      // #region agent log
      __agentDebugLog(
        "H4",
        "a_replay_trainer.py:refreshUI:updateCacheFromDualActive",
        "dual active 图更新 kline_all 缓存",
        {
          activeChartId: String(payload.active_chart_id || dualActiveChartId || "chart1"),
          count: payload.chart.kline_all.length,
          firstT: String(payload.chart.kline_all[0].t || ""),
          lastT: String(payload.chart.kline_all[payload.chart.kline_all.length - 1].t || ""),
        },
        `payload-dual:${payload.chart.kline_all.length}`,
        300
      );
      // #endregion
    } else if (!dataFormChanged && chipKlineAllCache && chipKlineAllCache.length > 0 && payload.chart) {
      payload.chart.kline_all = chipKlineAllCache;
      // #region agent log
      __agentDebugLog(
        "H4",
        "a_replay_trainer.py:refreshUI:reuseGlobalChipCache",
        "dual active 图缺失 kline_all 时复用全局缓存",
        {
          cacheCount: chipKlineAllCache.length,
          cacheFirstT: String(chipKlineAllCache[0].t || ""),
          cacheLastT: String(chipKlineAllCache[chipKlineAllCache.length - 1].t || ""),
          dataFormChanged: !!dataFormChanged,
        },
        `reuse-cache:${chipKlineAllCache.length}`,
        300
      );
      // #endregion
    }
  }
  if (
    payload &&
    payload.ready &&
    payload.chart &&
    chipKlineAllCache &&
    chipKlineAllCache.length > 0
  ) {
    const cur = payload.chart.kline_all;
    if (!cur || !cur.length || chipKlineAllCache.length > cur.length) {
      payload.chart.kline_all = chipKlineAllCache;
    }
  }
  lastPayload = payload;
  if (payload && Array.isArray(payload.record_trace)) {
    const startIdx = initStatusPollTimer ? Math.min(initTraceSeenCount, payload.record_trace.length) : 0;
    payload.record_trace.slice(startIdx).forEach((line) => appendMsgHistory(String(line)));
    initTraceSeenCount = Math.max(initTraceSeenCount, payload.record_trace.length);
  }
  appendRustHistoryFromPayload(payload);
  updateDualModeUI(payload);
  if (payload && payload.ready && payload.data_form) {
    dataFormConfig.mode = normalizeDataFormMode(payload.data_form.mode);
    dataFormConfig.quantity = clampDataFormQuantity(payload.data_form.quantity, payload.data_form.raw_count || payload.data_form.current_count || 1);
    dataFormConfig.quantityAlloc = normalizeDataFormQuantityAlloc(
      payload.data_form.quantity_alloc != null ? payload.data_form.quantity_alloc : dataFormConfig.quantityAlloc
    );
    dataFormConfig.feedMode = normalizeDataFeedMode(payload.data_form.feed_mode);
    dataFormConfig.klinePresentation = normalizeKlinePresentationMode(
      payload.data_form.presentation_mode != null ? payload.data_form.presentation_mode : dataFormConfig.klinePresentation
    );
    dataFormConfig.offlineDataCustom = normalizeOfflineDataCustom(
      payload.data_form.offline_data_custom != null ? payload.data_form.offline_data_custom : dataFormConfig.offlineDataCustom
    );
    sessionConfig.dataFormQuantityAlloc = dataFormConfig.quantityAlloc;
    sessionConfig.klinePresentationMode = dataFormConfig.klinePresentation;
    sessionConfig.offlineDataCustom = dataFormConfig.offlineDataCustom;
  } else if (!payload || !payload.ready) {
    dataFormConfig.mode = normalizeDataFormMode(sessionConfig.dataFormMode);
    dataFormConfig.quantity = clampDataFormQuantity(
      sessionConfig.dataFormQuantity,
      Number.isFinite(Number(sessionConfig.dataFormQuantity)) ? Number(sessionConfig.dataFormQuantity) : 1
    );
    dataFormConfig.feedMode = normalizeDataFeedMode(sessionConfig.dataFeedMode);
  }
  sessionFinished = !!payload.finished;
  syncTradesFromPayload(payload);
  syncIndicatorControls();
  if (payload.ready && Array.isArray(payload.bsp_history)) {
    bspHistory = payload.bsp_history.slice();
    bspHistoryKey = new Set(bspHistory.map((p) => p.key || bottomBspRowKey(p)));
  } else {
    bspHistory = [];
    bspHistoryKey = new Set();
  }
  setState(payload);
  updateDataSourceStatus(payload);
  updateTradeStatusOverlay(payload);
  if (showStandaloneNotices && payload && Array.isArray(payload.rhythm_notice_hits) && payload.rhythm_notice_hits.length > 0) {
    showRhythmHitNotices(payload);
  }
  if (showStandaloneNotices && payload && payload.judge_notice) {
    showJudgeNotice(payload);
  }
  if (payload.ready) {
    if ((dataFormChanged || (chipSid && chipKlineAllCacheSessionKey && chipSid !== chipSessionIdentity(prev))) && !afterStep) {
      if (payload.chart && Array.isArray(payload.chart.kline_all) && payload.chart.kline_all.length > 0) {
        chipKlineAllCache = normalizeChipKlineAllX(payload.chart.kline_all);
        payload.chart.kline_all = chipKlineAllCache;
      } else {
        chipKlineAllCache = null;
      }
      userAdjustedView = false;
      viewReady = false;
      DUAL_CHART_IDS.forEach((id) => {
        const rt = getRuntimeState(id);
        rt.userAdjustedView = false;
        rt.viewReady = false;
      });
    }
    if (payload.chart_mode === "dual" && payload.charts && payload.charts.chart1 && payload.charts.chart2) {
      DUAL_CHART_IDS.forEach((chartId) => {
        const c = payload.charts[chartId];
        if (!c || !Array.isArray(c.kline) || c.kline.length <= 0) return;
        syncRuntimeWindowFromChart(getRuntimeState(chartId), c, !!afterStep);
      });
      loadRuntimeState(dualActiveChartId);
      const activeRuntime = getRuntimeState(dualActiveChartId);
      lastSeenBspKey = new Set(
        [...lastSeenBspKey].filter((k) => {
          const x = Number(String(k).split("|")[0]);
          return Number.isFinite(x) && x <= activeRuntime.allXMax;
        })
      );
      redrawCurrentPayload();
    } else if (
      payload.chart_mode === "multi" &&
      Array.isArray(payload.chart_layers) &&
      payload.chart_layers.length > 0 &&
      payload.chart
    ) {
      const ks = payload.chart.kline ? payload.chart.kline : [];
      if (ks.length > 0) {
        allXMin = ks[0].x;
        allXMax = ks[ks.length - 1].x;
        if (!viewReady) {
          viewXMin = allXMin;
          viewXMax = allXMax;
          viewReady = true;
        } else if (!userAdjustedView) {
          viewXMin = allXMin;
          viewXMax = allXMax;
        } else {
          if (viewXMin < allXMin) viewXMin = allXMin;
          if (viewXMin >= viewXMax) {
            viewXMin = allXMin;
            viewXMax = allXMax;
            userAdjustedView = false;
          }
        }
        if (afterStep) ensureLatestKVisible();
        lastSeenBspKey = new Set(
          [...lastSeenBspKey].filter((k) => {
            const x = Number(String(k).split("|")[0]);
            return Number.isFinite(x) && x <= allXMax;
          })
        );
        drawMultiLayers(payload);
      }
    } else {
      const ks = payload.chart && payload.chart.kline ? payload.chart.kline : [];
      if (ks.length > 0) {
        allXMin = ks[0].x;
        allXMax = ks[ks.length - 1].x;
        if (!viewReady) {
          viewXMin = allXMin;
          viewXMax = allXMax;
          viewReady = true;
        } else if (!userAdjustedView) {
          viewXMin = allXMin;
          viewXMax = allXMax;
        } else {
          if (viewXMin < allXMin) viewXMin = allXMin;
          if (viewXMin >= viewXMax) {
            viewXMin = allXMin;
            viewXMax = allXMax;
            userAdjustedView = false;
          }
        }
        if (afterStep) {
          ensureLatestKVisible();
          // 数量模式 bar 数少，步进后若最新 K 仍不在视窗则展到全范围
          if (isSingleQuantityRayMode() && payload.chart && payload.chart.kline && payload.chart.kline.length > 0) {
            const lastX = payload.chart.kline[payload.chart.kline.length - 1].x;
            if (!(lastX >= viewXMin && lastX <= viewXMax)) {
              viewXMin = allXMin;
              viewXMax = allXMax;
            }
          }
        }
        lastSeenBspKey = new Set(
          [...lastSeenBspKey].filter((k) => {
            const x = Number(String(k).split("|")[0]);
            return Number.isFinite(x) && x <= allXMax;
          })
        );
        draw(payload.chart);
      }
    }
  }
  syncStepButtonState();
  $("btnFinish").disabled = !payload.ready || sessionFinished;
  const isUnifiedFeedMode = normalizeDataFeedMode(payload && payload.data_form ? payload.data_form.feed_mode : "step") === "unified";
  $("btnBuy").disabled = isUnifiedFeedMode || !payload.ready || sessionFinished || payload.price === null || payload.account.position !== 0;
  $("btnSell").disabled = isUnifiedFeedMode || !payload.ready || sessionFinished || !payload.account.can_sell;
  $("btnShort").disabled = isUnifiedFeedMode || !payload.ready || sessionFinished || payload.price === null || payload.account.position !== 0;
  $("btnCover").disabled = isUnifiedFeedMode || !payload.ready || sessionFinished || !payload.account.can_cover;
  $("configCard").classList.toggle("collapsed", payload.ready);
  updateBspJudgeUI();
  updateStepForwardMaxUi(payload);
  updateUnifiedGotoRow(payload);
  requestAnimationFrame(updateCompactLayout);
}

$("btnInit").onclick = async () => {
  const initBtn = $("btnInit");
  if (initBtn.disabled) return;
  let initSucceeded = false;
  const initBtnHtml = initBtn.innerHTML;
  archiveAndClearMsgHistory("开始加载新会话");
  appendCurrentConfigSummaryToHistory();
  const ctl = prepareCancelableLoading("正在加载会话，请稍候…", "正在加载会话…");
  initBtn.disabled = true;
  initBtn.innerHTML = "加载中...";
  try {
    const processedConfig = JSON.parse(JSON.stringify(chanConfig));
    applyRhythmCalcModeToChanConfig(processedConfig);
    ["mean_metrics", "trend_metrics"].forEach(k => {
      if (typeof processedConfig[k] === "string") {
        processedConfig[k] = processedConfig[k].split(/[,，\s]+/).map(v => parseInt(v.trim())).filter(v => !isNaN(v));
      }
    });
    const buildInitBody = (extra = {}) => ({
      code: $("code").value,
      begin_date: $("begin").value,
      end_date: $("end").value || null,
      initial_cash: Number($("cash").value),
      autype: $("autype").value,
      chan_config: processedConfig,
      k_type: $("kType").value,
      chart_mode: $("chartMode") ? $("chartMode").value : "single",
      k_type_2: $("kType2") ? $("kType2").value : $("kType").value,
      k_types_multi: (String($("chartMode") ? $("chartMode").value : "single") === "multi") ? collectKTypesMultiSelected() : undefined,
      active_chart_id: (sessionConfig && sessionConfig.activeChartId) ? sessionConfig.activeChartId : "chart1",
      confirm_offline: true,
      data_source_priority: ["离线数据"],
      data_form_mode: normalizeDataFormMode(dataFormConfig.mode),
      data_form_quantity: clampDataFormQuantity(dataFormConfig.quantity, getRawKlineCount() || 1),
      data_form_quantity_alloc: normalizeDataFormQuantityAlloc(dataFormConfig.quantityAlloc),
      data_feed_mode: normalizeDataFeedMode(dataFormConfig.feedMode),
      offline_data_custom: normalizeOfflineDataCustom(dataFormConfig.offlineDataCustom),
      kline_presentation_mode: normalizeKlinePresentationMode(dataFormConfig.klinePresentation),
      rollback_cache_depth: Number(systemConfig.rollbackCacheDepth || DEFAULT_SYSTEM_CONFIG.rollbackCacheDepth),
      rollback_full_snapshot_interval: Number(systemConfig.rollbackFullSnapshotInterval || DEFAULT_SYSTEM_CONFIG.rollbackFullSnapshotInterval),
      rollback_capture_max_bars: Number(systemConfig.rollbackCaptureMaxBars || DEFAULT_SYSTEM_CONFIG.rollbackCaptureMaxBars),
      chan_record_enabled: false,
      performance_engine_mode: String(systemConfig.performanceEngineMode || DEFAULT_SYSTEM_CONFIG.performanceEngineMode || "rust_auto"),
      chip_bucket_step: Number(chartConfig.chip && chartConfig.chip.bucketStep ? chartConfig.chip.bucketStep : 0.1),
      chart_lazy_layers: collectChartLazyLayersFromConfig(chartConfig, chartConfigStore),
      ...extra,
    });
    const cmInit = $("chartMode") ? $("chartMode").value : "single";
    if (cmInit === "multi") {
      const km = collectKTypesMultiSelected();
      if (km.length < 2) {
        throw new Error("多周期单图须至少勾选 2 个叠加周期");
      }
    }
    let payload;
    try {
      payload = await api("/api/init", buildInitBody({}), "POST", { signal: ctl.signal });
    } catch (e) {
      if (e && e.name === "AbortError") {
        throw new Error("已手动终止加载");
      }
      if (e.offlineConfirm && Number(e.httpStatus) === 409) {
        const oc = e.offlineConfirm;
        const tip = `${oc.display_code}使用${oc.failed_label}获取数据失败，原因为【${oc.reason_tag}】是否使用离线数据继续获取？`;
        if (confirmAndLog(tip)) {
          if (!initAbortController || initAbortController.signal.aborted) throw new Error("已手动终止加载");
          payload = await api("/api/init", buildInitBody({ confirm_offline: true }), "POST", { signal: initAbortController.signal });
        } else {
          let p = (systemConfig.dataSourcePriority || []).filter((x) => x !== "离线数据");
          if (!p.length) {
            p = DEFAULT_SYSTEM_CONFIG.dataSourcePriority.filter((x) => x !== "离线数据");
          }
          if (!initAbortController || initAbortController.signal.aborted) throw new Error("已手动终止加载");
          payload = await api("/api/init", buildInitBody({ data_source_priority: p }), "POST", { signal: initAbortController.signal });
        }
      } else {
        throw e;
      }
    }
    initSucceeded = true;
    // 最后一轮进度可能在 /api/init 返回前刚写入，完成后补拉一次。
    await pollInitStatusOnce();
    if (payload && payload.init_perf && Number.isFinite(Number(payload.init_perf.total_ms))) {
      initLoadExpectedMs = Math.max(5000, Number(payload.init_perf.total_ms));
      storageSet("chan_init_expected_ms", String(initLoadExpectedMs));
    }
    updateGlobalLoadingProgress(true);
    document.title = `chan.py 复盘训练器 - ${(payload.name ? payload.name : payload.code)}`;
    setMsg(payload.message || `加载成功：${payload.name ? payload.name : payload.code}`);
    initBtn.disabled = true;
    initBtn.innerHTML = "已加载";
    // $("btnChanSettingsOpen").disabled = true;
    updateShortcutUI();
    $("code").disabled = true;
    $("begin").disabled = true;
    $("end").disabled = true;
    $("cash").disabled = true;
    $("autype").disabled = true;
    userAdjustedView = false;
    viewReady = false;
    viewYShiftRatio = 0;
    viewYZoomRatio = 1.0;
    DUAL_CHART_IDS.forEach((cid) => {
      dualChartRuntime[cid] = { allXMin: 0, allXMax: 0, viewXMin: 0, viewXMax: 0, viewReady: false, userAdjustedView: false, viewYShiftRatio: 0, viewYZoomRatio: 1, crosshairX: null, crosshairY: null };
    });
    dualActiveChartId = (sessionConfig && sessionConfig.activeChartId === "chart2") ? "chart2" : "chart1";
    dualActivePaneLock = false;
    dualLockedChartId = "chart1";
    activeTrade = null;
    tradeHistory = [];
    bspHistory = [];
    bspHistoryKey = new Set();
    lastSeenBspKey = new Set();
    sessionFinished = false;
    stepInFlight = false;
    clearBspPrompt();
    refreshUI(payload);
    void fetchChipKlineAllLazy(payload);
    if (payload && payload.init_perf && payload.init_perf.rank && payload.init_perf.rank.length) {
      const fmtCost = (ms) => {
        const sec = Math.max(0, Number(ms || 0) / 1000);
        return sec >= 60 ? `${(sec / 60).toFixed(2)}分钟` : `${sec.toFixed(2)}秒`;
      };
      const stageLabel = {
        data_kline: "加载K线数据",
        data_chip: "加载筹码底座",
        chan_record: "跳过本地缓存",
        perf_engine_load: "加载性能引擎",
        chan_bootstrap: "计算缠论结构",
        bsp_snapshot: "生成买卖点快照",
        initial_step: "初始化首根K线",
        presentation_end: "一次性呈现到末根",
        build_payload: "构建图表首包",
        chip_refresh: "刷新筹码底座",
        chip_kline_all_api: "懒加载筹码底座",
      };
      const initStageName = (stage) => {
        const raw = String(stage || "");
        if (stageLabel[raw]) return stageLabel[raw];
        if (raw.startsWith("fetch_")) {
          const parts = raw.split("_");
          const useFor = parts[1] === "chip" ? "筹码" : (parts[1] === "kline" ? "K线" : "数据");
          return `读取${useFor}数据：${parts.slice(2).join("_") || "数据源"}`;
        }
        if (raw.startsWith("disk_cache_")) return "跳过历史磁盘缓存";
        return raw || "处理中";
      };
      const stageCore = (stage) => {
        const raw = String(stage || "");
        if (raw === "perf_engine_load") {
          return String(payload.engine_mode || "").toLowerCase().includes("python") ? "python" : "rust";
        }
        return "python";
      };
      const top = payload.init_perf.rank.slice(0, 4).map((r) => `${stageCore(r.stage)}:${initStageName(r.stage)}:${fmtCost(r.ms)}`).join("；");
      appendMsgHistory(`python<汇总>：加载耗时 ${fmtCost(payload.init_perf.total_ms)}（${top}）`);
    }
    const srcHistLine = buildSessionSourceHistoryLine(payload);
    if (srcHistLine) appendMsgHistory(srcHistLine);
  } catch (e) {
    const msg = (e && e.message) ? String(e.message) : "未知错误";
    if (e && (e.name === "AbortError" || msg.indexOf("终止") >= 0 || Number(e.httpStatus) === 499)) {
      setMsg("已终止加载会话。");
    } else {
      setMsg("加载失败：" + msg);
    }
  } finally {
    if (!initSucceeded) {
      initBtn.disabled = false;
      initBtn.innerHTML = initBtnHtml;
      updateShortcutUI();
    }
    finishCancelableLoading(false);
  }
};

if ($("btnCancelInitLoad")) {
  $("btnCancelInitLoad").onclick = () => {
    if (!initAbortController) return;
    void api("/api/init_cancel", {}, "POST").catch(() => {});
    initAbortController.abort();
    appendMsgHistory("已请求终止加载…");
    setMsg("已请求终止加载，会话加载请求已取消。");
    hideGlobalLoading();
  };
  markUiBound("btnCancelInitLoad");
}
if ($("btnLoadingHistory")) {
  $("btnLoadingHistory").onclick = () => showMsgHistory();
  markUiBound("btnLoadingHistory");
}
if ($("btnPrevLoadingHistory")) {
  $("btnPrevLoadingHistory").onclick = () => showPreviousMsgHistory();
  markUiBound("btnPrevLoadingHistory");
}
if ($("btnCopyLoadingHistory")) {
  $("btnCopyLoadingHistory").onclick = () => {
    const rows = Array.isArray(msgHistory) ? msgHistory.slice(-120) : [];
    void copyTextToClipboard(msgHistoryText(rows), "加载进度已复制");
  };
  markUiBound("btnCopyLoadingHistory");
}

$("btnStepPrev").onclick = async () => {
  if (!$("btnStepPrev") || $("btnStepPrev").disabled || stepInFlight) return;
  stepInFlight = true;
  syncStepButtonState();
  hideGlobalLoading();
  try {
    clearBspPrompt();
    const payload = await api("/api/back_n", { n: 1 });
    lastSeenBspKey = new Set();
    refreshUI(payload, { afterStep: true, showStandaloneNotices: false });
    setMsg(payload.message || "已回退一根K线");
  } catch (e) {
    setMsg("回退失败：" + e.message);
  } finally {
    stepInFlight = false;
    syncStepButtonState();
  }
};

$("btnStep").onclick = async () => {
  if ($("btnStep").disabled || stepInFlight) return;
  stepInFlight = true;
  syncStepButtonState();
  hideGlobalLoading();
  try {
    await stepOnce(true);
  } catch (e) {
    setMsg("步进失败：" + e.message);
  } finally {
    stepInFlight = false;
    syncStepButtonState();
  }
};

$("btnStepN").onclick = async () => {
  if ($("btnStepN").disabled || stepInFlight) return;
  const n = getStepNValue();
  const isUnifiedFeedMode = normalizeDataFeedMode(lastPayload && lastPayload.data_form ? lastPayload.data_form.feed_mode : "step") === "unified";
  let done = 0;
  let lastResult = null;
  stepInFlight = true;
  stepInterruptRequested = false;
  syncStepButtonState();
  hideGlobalLoading();
  try {
    if (isUnifiedFeedMode) {
      const payload = await api("/api/step", {
        judge_mode: systemConfig.bspJudgeMode || "auto",
        active_chart_id: (lastPayload && lastPayload.active_chart_id) ? lastPayload.active_chart_id : "chart1",
        n,
      });
      refreshUI(payload, { afterStep: true, showStandaloneNotices: false });
      setMsg(payload.message || `步进N（${n}）根完成`);
      return;
    }
    for (let i = 0; i < n; i++) {
      if (stepInterruptRequested) break;
      const result = await stepOnce(false);
      lastResult = result;
      done += 1;
      if (result.interrupted || result.reachedEnd) break;
    }
    if (!lastResult || !lastResult.noticeShown) {
      if (stepInterruptRequested) {
        setMsg(`步进N已手动中断，实际完成 ${done} 根。`);
      } else if (lastResult && lastResult.interrupted) {
        setMsg(`步进N已中断，实际完成 ${done} 根（触发中断条件）。`);
      } else {
        setMsg(`步进N（${done}）根完成`);
      }
    }
  } catch (e) {
    setMsg("步进 N 失败：" + e.message);
  } finally {
    stepInterruptRequested = false;
    stepInFlight = false;
    syncStepButtonState();
  }
};

if ($("btnStepInterrupt")) {
  $("btnStepInterrupt").onclick = () => {
    if (!stepInFlight) return;
    stepInterruptRequested = true;
    setMsg("已请求中断连续步进，将在当前根处理后停止。");
    syncStepButtonState();
  };
}

$("btnBackN").onclick = async () => {
  if ($("btnBackN").disabled || stepInFlight) return;
  const n = getStepNValue();
  stepInFlight = true;
  syncStepButtonState();
  hideGlobalLoading();
  try {
    clearBspPrompt();
    const payload = await api("/api/back_n", { n });
    lastSeenBspKey = new Set();
    refreshUI(payload, { afterStep: true, showStandaloneNotices: false });
    setMsg(payload.message || `后退 N 完成：N=${n}`);
  } catch (e) {
    setMsg("后退 N 失败：" + e.message);
  } finally {
    stepInFlight = false;
    syncStepButtonState();
  }
};

$("btnBuy").onclick = async () => {
  try {
    const payload = await api("/api/buy");
    setMsg(payload.message || "买入成功");
    refreshUI(payload);
  } catch (e) {
    setMsg("买入失败：" + e.message);
  }
};

$("btnSell").onclick = async () => {
  try {
    const payload = await api("/api/sell");
    setMsg(payload.message || "卖出成功");
    refreshUI(payload);
    
    // Show settlement for the last completed trade
    if (tradeHistory.length > 0) {
      const lastTrade = tradeHistory[tradeHistory.length - 1];
      showSettlement(lastTrade, payload.name || payload.code);
    }
  } catch (e) {
    setMsg("卖出失败：" + e.message);
  }
};

$("btnShort").onclick = async () => {
  try {
    const payload = await api("/api/short");
    setMsg(payload.message || "做空成功");
    refreshUI(payload);
  } catch (e) {
    setMsg("做空失败：" + e.message);
  }
};

$("btnCover").onclick = async () => {
  try {
    const payload = await api("/api/cover");
    setMsg(payload.message || "平空成功");
    refreshUI(payload);
  } catch (e) {
    setMsg("平空失败：" + e.message);
  }
};

if ($("btnUnifiedGotoStep")) {
  $("btnUnifiedGotoStep").onclick = async () => {
    if ($("btnUnifiedGotoStep").disabled || stepInFlight) return;
    const inp = $("inputUnifiedGotoStep");
    const raw = Number(inp ? inp.value : 0);
    const target = Number.isFinite(raw) ? Math.max(0, Math.floor(raw)) : 0;
    stepInFlight = true;
    syncStepButtonState();
    hideGlobalLoading();
    try {
      const payload = await api("/api/goto_step", {
        step_idx: target,
        active_chart_id: (lastPayload && lastPayload.active_chart_id) ? lastPayload.active_chart_id : "chart1",
      });
      refreshUI(payload, { afterStep: true, showStandaloneNotices: false });
      setMsg(payload.message || "已跳转");
    } catch (e) {
      setMsg("跳转失败：" + e.message);
    } finally {
      stepInFlight = false;
      syncStepButtonState();
    }
  };
}
if ($("inputUnifiedGotoStep")) {
  $("inputUnifiedGotoStep").addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      const btn = $("btnUnifiedGotoStep");
      if (btn && !btn.disabled) btn.click();
    }
  });
}

markUiBound("btnInit");
markUiBound("btnViewKlineData");
markUiBound("btnStepPrev");
markUiBound("btnStep");
markUiBound("btnStepN");
markUiBound("btnStepInterrupt");
markUiBound("btnBackN");
markUiBound("btnUnifiedGotoStep");
markUiBound("btnBuy");
markUiBound("btnSell");
markUiBound("btnShort");
markUiBound("btnCover");

if ($("chartMode")) {
  $("chartMode").addEventListener("change", () => {
    if ($("chartMode").value === "multi" && collectKTypesMultiSelected().length < 2) {
      applyKTypesMultiToDomFromList(["1min", "3min"]);
    }
    updateDualModeUI();
    refreshKTypesMultiOrderLabels();
    saveSessionConfig();
    redrawCurrentPayload();
  });
}
document.querySelectorAll("input.kTypesMultiCb[type=\"checkbox\"]").forEach((cb) => {
  cb.addEventListener("change", () => {
    refreshKTypesMultiOrderLabels();
    saveSessionConfig();
    if (lastPayload && lastPayload.ready) scheduleChartRedraw();
  });
});

function toggleMultiLayerVisibleByOrderIndex(orderIdx0) {
  const cm = $("chartMode") && String($("chartMode").value);
  if (cm !== "multi" || !lastPayload || !lastPayload.ready) return;
  const ordered = collectKTypesMultiOrdered();
  if (orderIdx0 < 0 || orderIdx0 >= ordered.length || orderIdx0 >= 5) return;
  const kt = ordered[orderIdx0];
  const hid = new Set(Array.isArray(sessionConfig.multiLayerHidden) ? sessionConfig.multiLayerHidden : []);
  if (hid.has(kt)) hid.delete(kt);
  else hid.add(kt);
  sessionConfig.multiLayerHidden = [...hid];
  saveSessionConfig();
  drawFromLastPayload();
  const st = hid.has(kt) ? "已隐藏" : "已显示";
  setMsg(`${st} ${getKTypeLabelText(kt)} 周期叠层（快捷键 ${orderIdx0 + 1}）`);
}

window.addEventListener("keydown", (e) => {
  if (isSingleQuantityRayMode() && !stepInFlight) {
    const t = e.target;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable)) {
      return;
    }
    if (!e.ctrlKey && !e.altKey && !e.metaKey) {
      const code = e.code || "";
      let digit = null;
      if (/^Digit[0-9]$/.test(code)) digit = code.slice(5);
      else if (/^Numpad[0-9]$/.test(code)) digit = code.slice(6);
      if (digit !== null) {
        e.preventDefault();
        pushQuantityDigitKey(digit);
        return;
      }
      if (code === "Enter" && quantityDigitBuffer) {
        e.preventDefault();
        if (quantityDigitBufferTimer) clearTimeout(quantityDigitBufferTimer);
        quantityDigitBufferTimer = null;
        const buf = quantityDigitBuffer;
        quantityDigitBuffer = "";
        applyQuantityFromKeyboard(parseInt(buf, 10));
        return;
      }
      if (code === "Escape" && quantityDigitBuffer) {
        e.preventDefault();
        if (quantityDigitBufferTimer) clearTimeout(quantityDigitBufferTimer);
        quantityDigitBufferTimer = null;
        quantityDigitBuffer = "";
        setMsg("已取消数量输入。");
        return;
      }
    }
  }
  if (!lastPayload || !lastPayload.ready) return;
  if (!$("chartMode") || $("chartMode").value !== "multi") return;
  const t = e.target;
  if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable)) return;
  if (e.ctrlKey || e.altKey || e.metaKey) return;
  const code = e.code || "";
  let idx = -1;
  if (code === "Digit1" || code === "Numpad1") idx = 0;
  else if (code === "Digit2" || code === "Numpad2") idx = 1;
  else if (code === "Digit3" || code === "Numpad3") idx = 2;
  else if (code === "Digit4" || code === "Numpad4") idx = 3;
  else if (code === "Digit5" || code === "Numpad5") idx = 4;
  if (idx < 0) return;
  e.preventDefault();
  toggleMultiLayerVisibleByOrderIndex(idx);
});
if ($("kType2")) {
  $("kType2").addEventListener("change", () => saveSessionConfig());
}
if ($("dualLayout")) {
  $("dualLayout").addEventListener("change", () => {
    saveSessionConfig();
    redrawCurrentPayload();
  });
}
  if ($("dualSplitRatio")) {
  $("dualSplitRatio").addEventListener("input", () => {
    const lab = $("dualSplitRatioLabel");
    if (lab) lab.textContent = `${$("dualSplitRatio").value}%`;
    saveSessionConfig();
    scheduleChartRedraw();
  });
}
if ($("btnActiveChart1")) {
  $("btnActiveChart1").addEventListener("click", () => {
    if (!lastPayload || !lastPayload.ready || !lastPayload.charts || !lastPayload.charts.chart1) return;
    setActiveChart("chart1", true);
    refreshUI(lastPayload, { afterStep: false });
  });
}
if ($("btnActiveChart2")) {
  $("btnActiveChart2").addEventListener("click", () => {
    if (!lastPayload || !lastPayload.ready || !lastPayload.charts || !lastPayload.charts.chart2) return;
    setActiveChart("chart2", true);
    refreshUI(lastPayload, { afterStep: false });
  });
}

$("btnFinish").onclick = async () => {
  try {
  maybeSaveUserBiRaysOnExit();
  if (!confirmAndLog("确定要结束当前训练吗？")) return;
    archiveAndClearMsgHistory("结束当前训练");
    const payload = await api("/api/finish");
    refreshUI(payload);
    setMsg("训练已结束。");
  if (confirmAndLog("训练结束，是否下载训练结果？")) {
      downloadTradeExport(payload);
    }
  } catch (e) {
    setMsg("结束失败：" + e.message);
  }
};

$("btnReset").onclick = async () => {
  try {
  maybeSaveUserBiRaysOnExit();
  if (!confirmAndLog("确定要重新训练吗？当前会话状态将被清空。")) return;
    archiveAndClearMsgHistory("重新训练");
    persistChartConfigStoreNow();
    saveSessionConfig();
    hideGlobalLoading();
    const payload = await api("/api/reset");
    $("btnInit").disabled = false;
    $("btnChanSettingsOpen").disabled = false;
    updateShortcutUI();
    $("code").disabled = false;
    $("begin").disabled = false;
    $("end").disabled = false;
    $("cash").disabled = false;
    $("autype").disabled = false;
    $("configCard").classList.remove("collapsed");
    document.title = "chan.py 复盘训练器";
    activeTrade = null;
    tradeHistory = [];
    bspHistory = [];
    bspHistoryKey = new Set();
    lastSeenBspKey = new Set();
    sessionFinished = false;
    stepInFlight = false;
    userAdjustedView = false;
    viewReady = false;
    viewYShiftRatio = 0;
    viewYZoomRatio = 1.0;
    pendingQuantityRayPts = [];
    quantityDigitBuffer = "";
    if (quantityDigitBufferTimer) clearTimeout(quantityDigitBufferTimer);
    quantityDigitBufferTimer = null;
    DUAL_CHART_IDS.forEach((cid) => {
      dualChartRuntime[cid] = { allXMin: 0, allXMax: 0, viewXMin: 0, viewXMax: 0, viewReady: false, userAdjustedView: false, viewYShiftRatio: 0, viewYZoomRatio: 1, crosshairX: null, crosshairY: null };
    });
    dualActiveChartId = "chart1";
    dualActivePaneLock = false;
    dualLockedChartId = "chart1";
    clearBspPrompt();
    lastPayload = payload;
    refreshUI(payload, { afterStep: false });
    persistChartConfigStoreNow();
    saveSessionConfig();
    ctx.clearRect(0, 0, canvas.clientWidth, canvas.clientHeight);
    setMsg("已重置，可重新配置并加载会话。");
    requestAnimationFrame(updateCompactLayout);
  } catch (e) {
    setMsg("重置失败：" + e.message);
  }
};

$("btnExit").onclick = async () => {
  if (!confirmAndLog("确定要退出并终止后台服务吗？")) return;
  maybeSaveUserBiRaysOnExit();
  archiveAndClearMsgHistory("退出训练器");
  setMsg("正在尝试终止后台服务并关闭页面...");
  try {
    await fetch("/api/exit", { method: "POST" });
  } catch (e) {
    console.warn("Failed to notify backend exit:", e);
  }
  window.close();
  setTimeout(() => {
    setMsg("服务已关闭。浏览器可能拦截了自动关窗，请手动关闭此页面。");
  }, 400);
};

// BSP Prompt Confirmation - Make it more robust
const bspConfirm = (e) => {
  if (e) {
    e.preventDefault();
    e.stopPropagation();
  }
  clearBspPrompt();
};
if ($("bspPromptConfirm")) {
  $("bspPromptConfirm").addEventListener("mousedown", (e) => {
    if (e.button === 0) bspConfirm(e);
  });
  $("bspPromptConfirm").addEventListener("click", bspConfirm);
}
if ($("bspPrompt")) {
  const panel = $("bspPrompt").querySelector(".panel");
  if (panel) panel.addEventListener("click", (e) => e.stopPropagation());
  $("bspPrompt").addEventListener("mousedown", (e) => {
    if (e.button === 0 && e.target === $("bspPrompt")) bspConfirm(e);
  });
  $("bspPrompt").addEventListener("click", (e) => {
    if (e.target === $("bspPrompt")) bspConfirm(e);
  });
}

/** 左侧主标签：1 复盘训练 / 2 回测（仅切换左栏内容，图表全宽不变） */
const MAIN_TAB_STORAGE_KEY = "chan_left_main_tab";
function syncBacktestFormFromSession() {
  if ($("btKType1") && $("kType")) $("btKType1").value = $("kType").value;
  if ($("btKType2") && $("kType2")) $("btKType2").value = $("kType2").value;
  // 指标回测后端不支持 multi，复盘选多周期时回测页回落为单周期
  if ($("btChartMode") && $("chartMode")) {
    const cm = String($("chartMode").value || "single");
    $("btChartMode").value = cm === "multi" ? "single" : cm;
  }
  const dual = $("btChartMode") && $("btChartMode").value === "dual";
  if ($("btKType2Row")) $("btKType2Row").style.display = dual ? "" : "none";
  if ($("btStepDriverRow")) $("btStepDriverRow").style.display = dual ? "" : "none";
}
const BT_COND_STORAGE_KEY = "chan_bt_cond_selected";

function _btCondItemKey(chart, kind, level, value) {
  return `${chart}|${kind}|${level || ""}|${value || ""}`;
}

function _btDefsToTree(defs) {
  const groups = new Map();
  defs.forEach(([chart, kind, level, value, label]) => {
    const cat = kind.startsWith("bsp_") ? "买卖点" : "指标";
    const gid = `${chart}_${cat}`;
    const glabel = chart === "k2" ? `图2 · ${cat}` : `图1 · ${cat}`;
    if (!groups.has(gid)) groups.set(gid, { id: gid, label: glabel, items: [] });
    groups.get(gid).items.push({
      id: _btCondItemKey(chart, kind, level, value),
      chart,
      kind,
      level: level || "",
      value: value || "",
      label,
    });
  });
  return [...groups.values()];
}

function _loadBtCondSelected(side) {
  const raw = safeJsonParse(storageGet(BT_COND_STORAGE_KEY), {});
  const arr = raw && raw[side];
  return Array.isArray(arr) ? new Set(arr.map(String)) : new Set();
}

function _saveBtCondSelected(side, hostId) {
  const host = $(hostId);
  if (!host) return;
  const ids = [];
  host.querySelectorAll('input[type="checkbox"][data-bt-cond-id]:checked').forEach((el) => {
    ids.push(String(el.getAttribute("data-bt-cond-id")));
  });
  const raw = safeJsonParse(storageGet(BT_COND_STORAGE_KEY), {});
  raw[side] = ids;
  storageSet(BT_COND_STORAGE_KEY, JSON.stringify(raw));
}

function buildBtConditionsFromCascade(hostId) {
  const out = [];
  const host = $(hostId);
  if (!host) return out;
  host.querySelectorAll('input[type="checkbox"][data-chart][data-kind]').forEach((el) => {
    if (!el.checked) return;
    const one = { chart: el.getAttribute("data-chart"), kind: el.getAttribute("data-kind") };
    const lv = el.getAttribute("data-level");
    const vf = el.getAttribute("data-value");
    if (lv) one.level = lv;
    if (vf != null && vf !== "") {
      const n = parseFloat(vf);
      if (!Number.isNaN(n)) one.value = n;
    }
    out.push(one);
  });
  return out;
}

function mountBtCondCascade(hostId, defs, side) {
  const host = $(hostId);
  if (!host) return;
  const tree = _btDefsToTree(defs);
  if (!tree.length) return;
  const saved = _loadBtCondSelected(side);
  let selGroupId = tree[0].id;
  host.innerHTML = "";
  host.dataset.inited = "1";
  const panel = document.createElement("div");
  panel.className = "settings-cascade";
  const colNav = document.createElement("div");
  colNav.className = "settings-cascade-col";
  colNav.innerHTML = `<div class="settings-cascade-head">分类</div><div class="settings-cascade-list" data-bt-nav="1"></div>`;
  const colDetail = document.createElement("div");
  colDetail.className = "settings-cascade-col";
  colDetail.innerHTML = `<div class="settings-cascade-head">条件（多选）</div><div class="bt-cond-cascade-panel" data-bt-detail="1"></div>`;
  panel.appendChild(colNav);
  panel.appendChild(colDetail);
  host.appendChild(panel);
  const listEl = colNav.querySelector('[data-bt-nav="1"]');
  const detailEl = colDetail.querySelector('[data-bt-detail="1"]');
  const paint = () => {
    listEl.innerHTML = "";
    tree.forEach((g) => {
      const el = document.createElement("div");
      const nOn = g.items.filter((it) => saved.has(it.id)).length;
      el.className = "settings-cascade-item" + (g.id === selGroupId ? " active" : "");
      el.textContent = nOn > 0 ? `${g.label} (${nOn})` : g.label;
      el.onclick = () => {
        selGroupId = g.id;
        paint();
      };
      listEl.appendChild(el);
    });
    const grp = tree.find((g) => g.id === selGroupId) || tree[0];
    detailEl.innerHTML = "";
    grp.items.forEach((it) => {
      const lab = document.createElement("label");
      lab.className = "bt-cond-item";
      const inp = document.createElement("input");
      inp.type = "checkbox";
      inp.setAttribute("data-bt-cond-id", it.id);
      inp.setAttribute("data-chart", it.chart);
      inp.setAttribute("data-kind", it.kind);
      if (it.level) inp.setAttribute("data-level", it.level);
      if (it.value) inp.setAttribute("data-value", it.value);
      inp.checked = saved.has(it.id);
      inp.addEventListener("change", () => {
        if (inp.checked) saved.add(it.id);
        else saved.delete(it.id);
        _saveBtCondSelected(side, hostId);
        paint();
      });
      const text = document.createElement("span");
      text.className = "bt-cond-text";
      const main = document.createElement("span");
      main.className = "bt-cond-main";
      const sub = document.createElement("span");
      sub.className = "bt-cond-sub";
      const left = String(it.label || "");
      const i = left.indexOf("（");
      if (i > 0) {
        main.textContent = left.slice(0, i);
        sub.textContent = left.slice(i);
      } else {
        main.textContent = left;
        sub.textContent = `${it.chart.toUpperCase()} · ${it.kind}`;
      }
      text.appendChild(main);
      text.appendChild(sub);
      lab.appendChild(inp);
      lab.appendChild(text);
      detailEl.appendChild(lab);
    });
  };
  paint();
}

function initBtCondGrids() {
  const entryDefs = [
    ["k1", "boll_lower_reclaim", "", "", "图1 布林下轨收回"],
    ["k2", "boll_lower_reclaim", "", "", "图2 布林下轨收回"],
    ["k1", "close_ge_boll_down", "", "", "图1 收盘≥布林下轨"],
    ["k1", "cross_up_boll_mid", "", "", "图1 上穿布林中轨"],
    ["k1", "macd_golden_cross", "", "", "图1 MACD金叉"],
    ["k1", "macd_dead_cross", "", "", "图1 MACD死叉"],
    ["k1", "macd_above_zero", "", "", "图1 MACD DIF>0"],
    ["k1", "kdj_golden_cross", "", "", "图1 KDJ金叉"],
    ["k1", "kdj_dead_cross", "", "", "图1 KDJ死叉"],
    ["k1", "rsi_below", "", "30", "图1 RSI<30"],
    ["k1", "rsi_above", "", "70", "图1 RSI>70"],
    ["k1", "close_above_boll_mid", "", "", "图1 收盘>布林中轨"],
    ["k1", "close_below_boll_upper", "", "", "图1 收盘<布林上轨"],
    ["k1", "bsp_buy", "bi", "", "图1 笔买点（本步新增）"],
    ["k2", "bsp_buy", "bi", "", "图2 笔买点（本步新增）"],
    ["k1", "bsp_buy", "seg", "", "图1 段买点（本步新增）"],
  ];
  const exitDefs = [
    ["k1", "macd_dead_cross", "", "", "图1 MACD死叉"],
    ["k1", "macd_below_zero", "", "", "图1 MACD DIF<0"],
    ["k1", "kdj_dead_cross", "", "", "图1 KDJ死叉"],
    ["k1", "rsi_above", "", "70", "图1 RSI>70"],
    ["k1", "close_above_boll_upper", "", "", "图1 收盘>布林上轨"],
    ["k1", "bsp_sell", "bi", "", "图1 笔卖点（本步新增）"],
    ["k1", "bsp_sell", "seg", "", "图1 段卖点（本步新增）"],
  ];
  mountBtCondCascade("btEntryCondCascade", entryDefs, "entry");
  mountBtCondCascade("btExitCondCascade", exitDefs, "exit");
}
function setMainTab(which) {
  const w = which === "2" ? "2" : "1";
  storageSet(MAIN_TAB_STORAGE_KEY, w);
  const p1 = $("tabPanel1");
  const p2 = $("tabPanel2");
  const b1 = $("btnMainTab1");
  const b2 = $("btnMainTab2");
  if (p1) p1.style.display = w === "1" ? "" : "none";
  if (p2) p2.style.display = w === "2" ? "" : "none";
  if (b1) {
    b1.classList.toggle("active", w === "1");
    b1.setAttribute("aria-selected", w === "1" ? "true" : "false");
  }
  if (b2) {
    b2.classList.toggle("active", w === "2");
    b2.setAttribute("aria-selected", w === "2" ? "true" : "false");
  }
  if (w === "2") {
    initBtCondGrids();
    syncBacktestFormFromSession();
  }
  requestAnimationFrame(updateCompactLayout);
}
if ($("btnMainTab1")) {
  $("btnMainTab1").addEventListener("click", () => setMainTab("1"));
}
if ($("btnMainTab2")) {
  $("btnMainTab2").addEventListener("click", () => setMainTab("2"));
}
setMainTab(storageGet(MAIN_TAB_STORAGE_KEY) || "1");
if ($("btChartMode")) {
  $("btChartMode").addEventListener("change", () => {
    const dual = $("btChartMode").value === "dual";
    if ($("btKType2Row")) $("btKType2Row").style.display = dual ? "" : "none";
    if ($("btStepDriverRow")) $("btStepDriverRow").style.display = dual ? "" : "none";
  });
}

function _processedChanConfigForApi() {
  const processedConfig = JSON.parse(JSON.stringify(chanConfig));
  applyRhythmCalcModeToChanConfig(processedConfig);
  ["mean_metrics", "trend_metrics"].forEach((k) => {
    if (typeof processedConfig[k] === "string") {
      processedConfig[k] = processedConfig[k]
        .split(/[,，\s]+/)
        .map((v) => parseInt(v.trim(), 10))
        .filter((v) => !Number.isNaN(v));
    }
  });
  return processedConfig;
}

function renderStrategyBacktestResult(res) {
  const card = $("btResultCard");
  const pre = $("btBacktestSummary");
  const wrap = $("btTradeTableWrap");
  if (!card || !pre || !wrap) return;
  card.style.display = "";
  const entC = res.entry_combine === "or" ? "OR" : "AND";
  const exC = res.exit_combine === "or" ? "OR" : "AND";
  const holdLine =
    res.exit_hold_bars != null && res.exit_hold_bars !== ""
      ? `兜底：持有 ${res.exit_hold_bars} 根（驱动周期）`
      : "兜底：未启用（仅出场公式或收盘强平）";
  const lines = [
    `标的：${res.name || res.code || "-"}`,
    `模式：${res.chart_mode === "dual" ? "双周期" : "单周期"}  ${res.k_type || ""}${res.chart_mode === "dual" && res.k_type_2 ? " / " + res.k_type_2 : ""}  步进：${res.step_driver || "auto"}`,
    `入场：${entC}  出场：${exC}  ${holdLine}`,
    res.warning ? `提示：${res.warning}` : "",
    `K 线根数（周期1）：${res.bars != null ? res.bars : "-"}`,
    `初始资金：${res.initial_cash}  期末权益：${res.final_equity}`,
    `总盈亏：${res.total_pnl}  收益率：${res.total_return_pct}%`,
    `成交笔数：${res.trade_count}  胜/负：${res.win_count}/${res.loss_count}  胜率：${res.win_rate_pct}%`,
  ].filter(Boolean);
  pre.textContent = lines.join("\n");
  wrap.innerHTML = "";
  const tbl = document.createElement("table");
  tbl.style.width = "100%";
  tbl.style.borderCollapse = "collapse";
  tbl.style.fontSize = "12px";
  const head = document.createElement("thead");
  head.innerHTML =
    "<tr><th style='text-align:left;padding:4px;border-bottom:1px solid var(--border)'>#</th><th style='text-align:left;padding:4px;border-bottom:1px solid var(--border)'>买时</th><th style='text-align:left;padding:4px;border-bottom:1px solid var(--border)'>卖时</th><th style='text-align:left;padding:4px;border-bottom:1px solid var(--border)'>卖因</th><th style='text-align:right;padding:4px;border-bottom:1px solid var(--border)'>驱动step</th><th style='text-align:right;padding:4px;border-bottom:1px solid var(--border)'>买价</th><th style='text-align:right;padding:4px;border-bottom:1px solid var(--border)'>卖价</th><th style='text-align:right;padding:4px;border-bottom:1px solid var(--border)'>盈亏</th></tr>";
  tbl.appendChild(head);
  const body = document.createElement("tbody");
  const rows = Array.isArray(res.trades) ? res.trades : [];
  rows.forEach((tr, idx) => {
    const r = document.createElement("tr");
    r.className = "btTradeRow";
    r.dataset.buyIdx = String(tr.buy_idx != null ? tr.buy_idx : "");
    r.innerHTML = `<td style="padding:4px;border-bottom:1px dashed var(--grid)">${idx + 1}</td><td style="padding:4px;border-bottom:1px dashed var(--grid)">${escapeHtmlAttr(tr.buy_t || "")}</td><td style="padding:4px;border-bottom:1px dashed var(--grid)">${escapeHtmlAttr(tr.sell_t || "")}</td><td style="padding:4px;border-bottom:1px dashed var(--grid)">${escapeHtmlAttr(tr.sell_reason || "")}</td><td style="padding:4px;text-align:right;border-bottom:1px dashed var(--grid)">${tr.driver_step != null ? tr.driver_step : "-"}</td><td style="padding:4px;text-align:right;border-bottom:1px dashed var(--grid)">${tr.buy_price != null ? tr.buy_price : "-"}</td><td style="padding:4px;text-align:right;border-bottom:1px dashed var(--grid)">${tr.sell_price != null ? tr.sell_price : "-"}</td><td style="padding:4px;text-align:right;border-bottom:1px dashed var(--grid)">${tr.pnl != null ? tr.pnl : "-"}</td>`;
    r.addEventListener("dblclick", () => {
      const bi = parseInt(r.dataset.buyIdx, 10);
      if (!Number.isFinite(bi) || bi < 0) return;
      void jumpToBacktestBuy(bi);
    });
    body.appendChild(r);
  });
  tbl.appendChild(body);
  wrap.appendChild(tbl);
}

async function jumpToBacktestBuy(buyIdx) {
  setMainTab("1");
  if (!lastPayload || !lastPayload.ready) {
    showToast("请先在标签1点击「加载会话」。");
    return;
  }
  setGlobalLoading(true, "正在跳转K线…");
  try {
    const p = await api("/api/goto_step", {
      step_idx: buyIdx,
      active_chart_id: (lastPayload && lastPayload.active_chart_id) ? lastPayload.active_chart_id : "chart1",
    });
    refreshUI(p, { afterStep: false });
    showToast("已跳转到该笔买入所在K线。");
  } catch (e) {
    showToast("跳转失败：" + e.message);
  } finally {
    hideGlobalLoading();
  }
}

if ($("btnStrategyBacktestRun")) {
  $("btnStrategyBacktestRun").addEventListener("click", async () => {
    initBtCondGrids();
    const useHold = $("btUseExitHold") && $("btUseExitHold").checked;
    const n = Math.max(1, parseInt($("btExitHoldN") && $("btExitHoldN").value, 10) || 5);
    if ($("btExitHoldN")) $("btExitHoldN").value = String(n);
    const entryConds = buildBtConditionsFromCascade("btEntryCondCascade");
    if (!entryConds.length) {
      showToast("请至少勾选一条入场条件。");
      return;
    }
    const exitConds = buildBtConditionsFromCascade("btExitCondCascade");
    const processedConfig = _processedChanConfigForApi();
    const rawN = getRawKlineCount();
    const buildBody = (extra = {}) => ({
      code: $("code").value,
      begin_date: $("begin").value,
      end_date: $("end").value || null,
      initial_cash: Number($("cash").value),
      autype: $("autype").value,
      chan_config: processedConfig,
      k_type: $("btKType1") ? $("btKType1").value : $("kType").value,
      chart_mode: $("btChartMode") ? $("btChartMode").value : "single",
      k_type_2: $("btKType2") ? $("btKType2").value : $("kType").value,
      step_driver: $("btStepDriver") ? $("btStepDriver").value : "auto",
      entry_conditions: entryConds,
      entry_combine: $("btEntryCombineMode") ? $("btEntryCombineMode").value : "and",
      exit_conditions: exitConds,
      exit_combine: $("btExitCombineMode") ? $("btExitCombineMode").value : "and",
      exit_hold_bars: useHold ? n : null,
      data_form_mode: normalizeDataFormMode(dataFormConfig.mode),
      data_form_quantity: clampDataFormQuantity(dataFormConfig.quantity, rawN > 0 ? rawN : 1),
      ...extra,
    });
    setGlobalLoading(true, "指标回测计算中…");
    try {
      let res;
      try {
        res = await api("/api/indicator_backtest", buildBody({}));
      } catch (e) {
        if (e.offlineConfirm && Number(e.httpStatus) === 409) {
          const oc = e.offlineConfirm;
          const tip = `${oc.display_code}使用${oc.failed_label}获取数据失败，原因为【${oc.reason_tag}】是否使用离线数据继续？`;
          if (confirmAndLog(tip)) {
            res = await api("/api/indicator_backtest", buildBody({ confirm_offline: true }));
          } else {
            let p = (systemConfig.dataSourcePriority || []).filter((x) => x !== "离线数据");
            if (!p.length) p = DEFAULT_SYSTEM_CONFIG.dataSourcePriority.filter((x) => x !== "离线数据");
            res = await api("/api/indicator_backtest", buildBody({ data_source_priority: p }));
          }
        } else {
          throw e;
        }
      }
      if (res) renderStrategyBacktestResult(res);
    } catch (e) {
      showToast("回测失败：" + e.message);
    } finally {
      hideGlobalLoading();
    }
  });
}

function verifyCriticalUiBindings() {
  const checks = [
    { id: "btnInit", ok: () => typeof $("btnInit").onclick === "function" || $("btnInit").dataset.bound === "1" },
    { id: "btnStep", ok: () => typeof $("btnStep").onclick === "function" || $("btnStep").dataset.bound === "1" },
    { id: "btnBuy", ok: () => typeof $("btnBuy").onclick === "function" || $("btnBuy").dataset.bound === "1" },
    { id: "btnSell", ok: () => typeof $("btnSell").onclick === "function" || $("btnSell").dataset.bound === "1" },
    { id: "btnSettingsOpen", ok: () => $("btnSettingsOpen").dataset.bound === "1" },
    { id: "btnFullscreen", ok: () => typeof $("btnFullscreen").onclick === "function" || $("btnFullscreen").dataset.bound === "1" },
    { id: "toolHorizontalRay", ok: () => $("toolHorizontalRay").dataset.bound === "1" },
    { id: "toolBiRay", ok: () => $("toolBiRay").dataset.bound === "1" },
    { id: "toolParallelogram", ok: () => $("toolParallelogram").dataset.bound === "1" },
  ];
  const broken = checks
    .map((check) => {
      const el = $(check.id);
      if (!el) return `${check.id}: 缺少 DOM 节点`;
      try {
        return check.ok() ? null : `${check.id}: 事件绑定缺失`;
      } catch (err) {
        return `${check.id}: 自检异常 (${err && err.message ? err.message : err})`;
      }
    })
    .filter(Boolean);
  if (broken.length <= 0) {
    console.info("UI binding self-check passed.");
    return;
  }
  const text = `前端脚本自检发现异常：\n${broken.join("\n")}\n请重点检查 forEach 回调里是否误用了 continue。`;
  console.error(text);
  setTimeout(() => showToast(text, { record: false }), 0);
}

(async () => {
  loadSessionConfig();
  refreshKTypesMultiOrderLabels();
  applyThemeFromSelect();
  hideGlobalLoading();
  try {
    const payload = await api("/api/state", null, "GET");
    if (payload && payload.ready) {
      document.title = `chan.py 复盘训练器 - ${(payload.name ? payload.name : payload.code)}`;
      $("btnInit").disabled = true;
      // $("btnChanSettingsOpen").disabled = true;
      $("code").disabled = true;
      $("begin").disabled = true;
      $("end").disabled = true;
      $("cash").disabled = true;
      $("autype").disabled = true;
      refreshUI(payload);
      setMsg("已自动恢复上次会话。");
      const srcHistLine = buildSessionSourceHistoryLine(payload);
      if (srcHistLine) appendMsgHistory(srcHistLine);
    }
  } catch (e) {
    console.error("恢复会话失败:", e);
  }
  updateDataSourceStatus(lastPayload);
  updateCompactLayout();
  verifyCriticalUiBindings();
})();

// 数据源管理相关函数
let draggedItem = null;

function onDragStart(e, item) {
    draggedItem = item;
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', item.dataset.index);
    setTimeout(() => item.style.opacity = '0.5', 0);
}

function onDragEnd(e) {
    e.target.style.opacity = '1';
    draggedItem = null;
}

function onDrop(e, targetItem) {
    e.preventDefault();
    if (!draggedItem || draggedItem === targetItem) return;
    
    const list = document.getElementById('dataSourceList');
    const items = Array.from(list.children);
    const fromIndex = parseInt(draggedItem.dataset.index);
    const toIndex = parseInt(targetItem.dataset.index);
    
    if (fromIndex < toIndex) {
        list.insertBefore(draggedItem, targetItem.nextSibling);
    } else {
        list.insertBefore(draggedItem, targetItem);
    }
    
    // 更新索引
    updateDataSourceIndexes();
}

function updateDataSourceIndexes() {
    const list = document.getElementById('dataSourceList');
    if (!list) return;
    const items = Array.from(list.children);
    items.forEach((item, idx) => {
        item.dataset.index = idx;
    });
}

function moveDataSource(index, direction) {
    const list = document.getElementById('dataSourceList');
    if (!list) return;
    const items = Array.from(list.children);
    const newIndex = index + direction;
    if (newIndex < 0 || newIndex >= items.length) return;
    
    const item = items[index];
    const swapItem = items[newIndex];
    
    if (direction === -1) {
        list.insertBefore(item, swapItem);
    } else {
        list.insertBefore(swapItem, item);
    }
    
    updateDataSourceIndexes();
}

async function checkDataSource(srcName) {
    const statusSpans = document.querySelectorAll(".dataSourceStatus");
    statusSpans.forEach((span) => {
        const par = span.parentElement;
        if (par && par.dataset && par.dataset.name === srcName) {
            span.textContent = "…";
            span.style.color = "#f59e0b";
            span.title = "检测中";
        }
    });
    try {
        const res = await api("/api/check_data_source", { name: srcName });
        const ok = !!(res && res.ok);
        const msg = (res && res.message) ? String(res.message) : (ok ? "可用" : "不可用");
        statusSpans.forEach((span) => {
            const par = span.parentElement;
            if (par && par.dataset && par.dataset.name === srcName) {
                span.textContent = ok ? "●" : "○";
                span.style.color = ok ? "#22c55e" : "#ef4444";
                span.title = msg;
            }
        });
    } catch (e) {
        statusSpans.forEach((span) => {
            const par = span.parentElement;
            if (par && par.dataset && par.dataset.name === srcName) {
                span.textContent = "○";
                span.style.color = "#ef4444";
                span.title = e && e.message ? e.message : "检测失败";
            }
        });
    }
}

function getDataSourcePriority() {
    const list = document.getElementById('dataSourceList');
    if (!list) return [];
    const items = Array.from(list.children);
    return items.map(item => item.dataset.name).filter(name => name);
}

</script>
</body>
</html>
"""


APP_PERF_ENGINE = PerfEngine()
APP_STATE = AppState()
APP_STOCK_NAME: Optional[str] = None

# ---------- 加载会话进度 / 终止 ----------
class InitCancelledError(Exception):
    """用户终止加载会话。"""


_INIT_STATUS_LOCK = threading.Lock()
_INIT_CANCEL = threading.Event()
_INIT_STATUS: dict[str, Any] = {
    "busy": False,
    "stage": "",
    "stage_label": "",
    "progress_pct": 0,
    "started_at": 0.0,
    "stage_started_at": 0.0,
}

_INIT_STAGE_LABELS: dict[str, str] = {
    "data_kline": "加载K线数据",
    "data_chip": "加载筹码底座",
    "chip_refresh": "刷新筹码底座",
    "chan_record": "跳过本地缓存",
    "perf_engine_load": "加载性能引擎",
    "chan_bootstrap": "计算缠论结构",
    "bsp_snapshot": "生成买卖点快照",
    "presentation_end": "一次性呈现到末根",
    "initial_step": "初始化首根K线",
    "build_payload": "构建图表首包",
    "chart_lazy_layers": "加载图表懒加载图层",
}

_INIT_STAGE_PROGRESS: dict[str, int] = {
    "data_kline": 8,
    "data_chip": 18,
    "chip_refresh": 22,
    "chan_record": 32,
    "perf_engine_load": 38,
    "chan_bootstrap": 52,
    "bsp_snapshot": 68,
    "presentation_end": 72,
    "initial_step": 72,
    "build_payload": 92,
    "chart_lazy_layers": 96,
}


def _init_stage_core(name: str) -> str:
    """历史记录核心标识：性能引擎按实际模式，其余初始化默认 Python。"""
    raw = str(name or "")
    if raw == "perf_engine_load":
        mode = str(getattr(APP_PERF_ENGINE, "requested_mode", "") or "").lower()
        return "python" if mode == "python_legacy" else "rust"
    return "python"


def _init_trace_prefix(stage: str, status: str) -> str:
    return f"{_init_stage_core(stage)}<{status}>"


def _init_stage_label(name: str) -> str:
    raw = str(name or "")
    if raw in _INIT_STAGE_LABELS:
        return _INIT_STAGE_LABELS[raw]
    if raw.startswith("fetch_"):
        parts = raw.split("_", 2)
        use_for = {"kline": "K线", "chip": "筹码"}.get(parts[1] if len(parts) > 1 else "", "数据")
        src = parts[2] if len(parts) > 2 else "数据源"
        return f"读取{use_for}数据：{src}"
    if raw.startswith("disk_cache_"):
        return "跳过历史磁盘缓存"
    return raw or "处理中"


def _init_status_begin(message: Optional[str] = None) -> None:
    _INIT_CANCEL.clear()
    # 新任务先倒掉旧进度桶，避免前端清屏后又被旧日志灌回来。
    drain_record_trace()
    with _INIT_STATUS_LOCK:
        _INIT_STATUS.update(
            {
                "busy": True,
                "stage": "start",
                "stage_label": "准备加载",
                "progress_pct": 1,
                "started_at": time.time(),
                "stage_started_at": time.time(),
            }
        )
    push_record_trace(message or "开始加载会话：固定使用 a_Data 重新计算，不读取历史缓存")


def _init_status_end() -> None:
    with _INIT_STATUS_LOCK:
        _INIT_STATUS.update(
            {
                "busy": False,
                "stage": "",
                "stage_label": "",
                "progress_pct": 100,
            }
        )
    _INIT_CANCEL.clear()


def _init_status_on_stage(event: str, stage: str) -> None:
    label = _init_stage_label(stage)
    if event == "exit":
        with _INIT_STATUS_LOCK:
            stage_started = float(_INIT_STATUS.get("stage_started_at") or time.time())
        cost = max(0.0, time.time() - stage_started)
        push_record_trace(f"{_init_trace_prefix(stage, '成功')}：{label}（耗时 {cost:.1f} 秒）")
        return
    if event != "enter":
        return
    pct = int(_INIT_STAGE_PROGRESS.get(stage, 0))
    if pct <= 0:
        pct = 3
    with _INIT_STATUS_LOCK:
        cur = int(_INIT_STATUS.get("progress_pct") or 0)
        _INIT_STATUS.update(
            {
                "stage": stage,
                "stage_label": label,
                "progress_pct": max(cur, pct),
                "stage_started_at": time.time(),
            }
        )
    push_record_trace(f"{_init_trace_prefix(stage, '进行中')}：{label}（{max(cur, pct)}%）")


def _init_status_set_subprogress(pct: int, label: str, *, push_trace: bool = False) -> None:
    with _INIT_STATUS_LOCK:
        cur = int(_INIT_STATUS.get("progress_pct") or 0)
        _INIT_STATUS.update(
            {
                "stage_label": str(label or _INIT_STATUS.get("stage_label") or ""),
                "progress_pct": max(cur, int(pct)),
            }
        )
    if push_trace:
        push_record_trace(str(label))


def _init_status_snapshot() -> dict[str, Any]:
    with _INIT_STATUS_LOCK:
        st = dict(_INIT_STATUS)
    traces = peek_record_trace()
    elapsed = max(0.0, time.time() - float(st.get("started_at") or time.time()))
    stage_elapsed = max(0.0, time.time() - float(st.get("stage_started_at") or time.time()))
    pct = int(st.get("progress_pct") or 0)
    eta_sec = None
    if st.get("busy") and pct > 2 and pct < 99:
        eta_sec = max(1.0, elapsed * (100.0 - pct) / pct)
    return {
        "busy": bool(st.get("busy")),
        "stage": st.get("stage") or "",
        "stage_label": st.get("stage_label") or "",
        "progress_pct": pct,
        "elapsed_sec": round(elapsed, 1),
        "stage_elapsed_sec": round(stage_elapsed, 1),
        "eta_sec": round(eta_sec, 1) if eta_sec is not None else None,
        "traces": traces,
        "trace_count": len(traces),
    }


def _check_init_cancelled() -> None:
    if _INIT_CANCEL.is_set():
        raise InitCancelledError("已手动终止加载")


set_init_stage_listener(_init_status_on_stage)


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield
    CBaoStock.do_close()


app = FastAPI(title="chan.py replay trainer", lifespan=lifespan)


_AGENT_DEBUG_LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "debug-cb2ced.log")


def _agent_debug_log_backend(
    hypothesis_id: str,
    location: str,
    message: str,
    data: dict[str, Any],
    *,
    run_id: str = "post-fix2",
) -> None:
    """Python 侧调试埋点（NDJSON 落盘）。"""
    return
    try:
        import time

        line = json.dumps(
            {
                "sessionId": "cb2ced",
                "runId": run_id,
                "hypothesisId": hypothesis_id,
                "location": location,
                "message": message,
                "data": data,
                "timestamp": int(time.time() * 1000),
            },
            ensure_ascii=False,
        )
        with open(_AGENT_DEBUG_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def _init_perf_history_lines(perf: dict[str, Any]) -> list[str]:
    """把初始化节点耗时写入前端历史记录，使用中文功能名与秒/分钟。"""
    if not perf:
        return []
    stage_name_map = {
        "data_kline": "加载K线数据",
        "data_chip": "加载筹码底座",
        "chan_record": "跳过本地缓存",
        "perf_engine_load": "加载性能引擎",
        "chan_bootstrap": "计算缠论结构",
        "bsp_snapshot": "生成买卖点快照",
        "initial_step": "初始化首根K线",
        "presentation_end": "一次性呈现到末根",
        "build_payload": "构建图表首包",
        "chip_refresh": "刷新筹码底座",
        "chip_kline_all_api": "懒加载筹码底座",
        "chart_lazy_layers": "加载图表懒加载图层",
    }
    stage_core_map = {
        "data_kline": "python",
        "data_chip": "python",
        "chan_record": "python",
        "perf_engine_load": "rust" if str(perf.get("engine_mode") or "").lower() != "python-legacy" else "python",
        "chan_bootstrap": "python",
        "bsp_snapshot": "python",
        "initial_step": "python",
        "presentation_end": "python",
        "build_payload": "python",
        "chip_refresh": "python",
        "chip_kline_all_api": "python",
        "chart_lazy_layers": "python",
    }

    def fmt_cost(ms: float) -> str:
        sec = max(0.0, float(ms) / 1000.0)
        if sec >= 60.0:
            return f"{sec / 60.0:.2f}分钟"
        return f"{sec:.2f}秒"

    out = [f"python<汇总>：加载节点总耗时 {fmt_cost(float(perf.get('total_ms') or 0.0))}"]
    for row in perf.get("rank") or []:
        raw_stage = str(row.get("stage", ""))
        stage = stage_name_map.get(raw_stage, _init_stage_label(raw_stage))
        core = stage_core_map.get(raw_stage, _init_stage_core(raw_stage))
        ms = float(row.get("ms") or 0.0)
        pct = float(row.get("pct") or 0.0)
        if stage:
            out.append(f"{core}<成功>加载节点：{stage} {fmt_cost(ms)}（{pct:.1f}%）")
    return out


def _rust_error_history_lines() -> list[str]:
    """把最近 Rust 失败细节写给前端历史记录，便于复制排查。"""
    status = APP_PERF_ENGINE.cache_status()
    rows = status.get("last_rust_errors") or []
    out: list[str] = []
    seen: set[tuple[str, str, str]] = set()
    for item in rows[-5:]:
        feature = str(item.get("feature") or "未知")
        detail = str(item.get("detail") or "").strip()
        tb = str(item.get("traceback") or "").strip()
        key = (feature, detail, tb)
        if key in seen:
            continue
        seen.add(key)
        if detail:
            out.append(f"Rust失败详情：{feature}：{detail}")
        if tb and tb != detail:
            out.append(f"Rust失败堆栈：{feature}：{tb}")
    return out


def _error_detail_with_rust(exc: Exception) -> str:
    """HTTP 错误里附带 Rust 最近细节，前端弹窗和历史记录都能看到。"""
    return str(exc)


@app.post("/api/_agent_debug_log")
def api_agent_debug_log(body: dict[str, Any]):
    """调试埋点：前端 NDJSON 落盘（debug 会话 cb2ced）。"""
    return {"ok": True}


@app.get("/", response_class=HTMLResponse)
def index():
    return HTML


@app.post("/api/init")
async def api_init(req: InitReq):
    _init_status_begin()
    try:
        def _run_init() -> dict[str, Any]:
            with init_perf_run("api_init") as perf_col:
                return _api_init_impl(req, perf_col)

        return await run_in_threadpool(_run_init)
    except InitCancelledError as exc:
        APP_STATE.ready = False
        raise HTTPException(status_code=499, detail=str(exc)) from exc
    finally:
        _init_status_end()


@app.get("/api/init_status")
def api_init_status():
    """加载会话进度与实时跟踪日志（供前端轮询）。"""
    return _init_status_snapshot()


@app.post("/api/init_cancel")
def api_init_cancel():
    """请求终止当前加载会话（长循环内会检测并中断）。"""
    _INIT_CANCEL.set()
    push_record_trace("已请求终止加载…")
    return {"ok": True}


def _api_init_impl(req: InitReq, perf_col: Optional[dict[str, Any]] = None) -> dict[str, Any]:
    try:
        autype_map = {"qfq": AUTYPE.QFQ, "hfq": AUTYPE.HFQ, "none": AUTYPE.NONE}
        autype = autype_map.get(req.autype.lower(), AUTYPE.QFQ)
        if req.initial_cash <= 0:
            raise ValueError("初始资金必须大于0")
        code_norm = normalize_code(req.code)
        APP_PERF_ENGINE.requested_mode = str(getattr(req, "performance_engine_mode", "rust_auto") or "rust_auto")
        for line in rust_session_env_trace_lines():
            push_record_trace(line)

        try:
            cm_init = normalize_replay_chart_mode(req.chart_mode)
            APP_STATE.multi_steppers = []
            APP_STATE.stepper2 = None

            if cm_init == "multi":
                if not offline_tick_files_exist_for_range(code_norm, req.begin_date, req.end_date):
                    raise ValueError("单品种多周期单图仅支持离线分笔：当前代码与日期区间内未找到 a_Data 分笔文件（YYYYMMDD_代码.txt）")
                driver_k, passive_ks = resolve_multi_k_types_from_request(getattr(req, "k_types_multi", None))
                APP_STATE.stepper.init(
                    code_norm,
                    req.begin_date,
                    req.end_date,
                    autype,
                    chan_config=req.chan_config,
                    k_type=driver_k,
                    confirm_offline=True,
                    data_source_priority=["离线数据"],
                    data_form_mode=req.data_form_mode,
                    data_form_quantity=req.data_form_quantity,
                    data_form_quantity_alloc=getattr(req, "data_form_quantity_alloc", "front"),
                    data_feed_mode=getattr(req, "data_feed_mode", "step"),
                    offline_data_custom=getattr(req, "offline_data_custom", "native"),
                    chan_record_enabled=bool(getattr(req, "chan_record_enabled", False)),
                    chart_lazy_layers=getattr(req, "chart_lazy_layers", None),
                )
                if APP_STATE.stepper.data_src_used != OFFLINE_INLINE_SRC:
                    raise ValueError(
                        "单品种多周期单图仅允许离线数据包（a_Data 分笔）；请勾选确认离线或调整数据源优先级使离线成功"
                    )
                APP_STATE.chart_mode = "multi"
                APP_STATE.active_chart_id = "chart1"
                for pk in passive_ks:
                    st = ChanStepper()
                    st.init(
                        code_norm,
                        req.begin_date,
                        req.end_date,
                        autype,
                        chan_config=req.chan_config,
                        k_type=pk,
                        confirm_offline=True,
                        data_source_priority=["离线数据"],
                        data_form_mode=req.data_form_mode,
                        data_form_quantity=req.data_form_quantity,
                        data_form_quantity_alloc=getattr(req, "data_form_quantity_alloc", "front"),
                        data_feed_mode=getattr(req, "data_feed_mode", "step"),
                        offline_data_custom=getattr(req, "offline_data_custom", "native"),
                        chan_record_enabled=bool(getattr(req, "chan_record_enabled", False)),
                        chart_lazy_layers=getattr(req, "chart_lazy_layers", None),
                    )
                    APP_STATE.multi_steppers.append(st)
            else:
                APP_STATE.stepper.init(
                    code_norm,
                    req.begin_date,
                    req.end_date,
                    autype,
                    chan_config=req.chan_config,
                    k_type=req.k_type,
                    confirm_offline=True,
                    data_source_priority=["离线数据"],
                    data_form_mode=req.data_form_mode,
                    data_form_quantity=req.data_form_quantity,
                    data_form_quantity_alloc=getattr(req, "data_form_quantity_alloc", "front"),
                    data_feed_mode=getattr(req, "data_feed_mode", "step"),
                    offline_data_custom=getattr(req, "offline_data_custom", "native"),
                    chan_record_enabled=bool(getattr(req, "chan_record_enabled", False)),
                    chart_lazy_layers=getattr(req, "chart_lazy_layers", None),
                )
                chart_mode = "dual" if cm_init == "dual" else "single"
                APP_STATE.chart_mode = chart_mode
                APP_STATE.active_chart_id = (
                    "chart2" if (chart_mode == "dual" and str(req.active_chart_id or "").strip().lower() == "chart2") else "chart1"
                )
                if chart_mode == "dual":
                    k_type_2 = str(req.k_type_2 or req.k_type or "daily").strip()
                    APP_STATE.stepper2 = ChanStepper()
                    APP_STATE.stepper2.init(
                        code_norm,
                        req.begin_date,
                        req.end_date,
                        autype,
                        chan_config=req.chan_config,
                        k_type=k_type_2,
                        confirm_offline=True,
                        data_source_priority=["离线数据"],
                        data_form_mode=req.data_form_mode,
                        data_form_quantity=req.data_form_quantity,
                        data_form_quantity_alloc=getattr(req, "data_form_quantity_alloc", "front"),
                        data_feed_mode=getattr(req, "data_feed_mode", "step"),
                        offline_data_custom=getattr(req, "offline_data_custom", "native"),
                        chan_record_enabled=bool(getattr(req, "chan_record_enabled", False)),
                        chart_lazy_layers=getattr(req, "chart_lazy_layers", None),
                    )
        except OfflineDataConfirmRequired as exc:
            raise HTTPException(
                status_code=409,
                detail={
                    "type": "offline_confirm",
                    "display_code": exc.display_code,
                    "failed_label": exc.failed_label,
                    "reason_tag": exc.reason_tag,
                    "reason_detail": exc.reason_detail,
                },
            ) from exc
        global APP_STOCK_NAME
        APP_STOCK_NAME = APP_STATE.stepper.stock_name
        APP_STATE.account.reset(req.initial_cash)
        APP_STATE.ready = True
        APP_STATE.finished = False
        APP_STATE._set_rollback_config(
            cache_depth=req.rollback_cache_depth,
            full_snapshot_interval=req.rollback_full_snapshot_interval,
            capture_max_bars=req.rollback_capture_max_bars,
        )
        APP_STATE.session_params = {
            "code": code_norm,
            "begin_date": req.begin_date,
            "end_date": req.end_date,
            "autype": autype,
            "chan_record_enabled": False,
            "initial_cash": req.initial_cash,
            "chan_config": req.chan_config,
            "k_type": k_type_to_api_key(APP_STATE.stepper.k_type),
            "chart_mode": APP_STATE.chart_mode,
            "k_type_2": req.k_type_2,
            "k_types_multi": (
                [k_type_to_api_key(APP_STATE.stepper.k_type)]
                + [k_type_to_api_key(s.k_type) for s in APP_STATE.multi_steppers]
                if APP_STATE.chart_mode == "multi"
                else None
            ),
            "active_chart_id": APP_STATE.active_chart_id,
            # 与 ChanStepper.init 的 session_key 一致，供 reconfig/back_n 重建时命中 K 线缓存、避免重复联网
            "confirm_offline": True,
            "data_source_priority": ["离线数据"],
            "data_form_mode": normalize_data_form_mode(req.data_form_mode),
            "data_form_quantity": req.data_form_quantity,
            "data_form_quantity_alloc": normalize_data_form_quantity_alloc(
                getattr(req, "data_form_quantity_alloc", "front")
            ),
            "data_feed_mode": normalize_data_feed_mode(getattr(req, "data_feed_mode", "step")),
            "offline_data_custom": normalize_offline_data_custom(getattr(req, "offline_data_custom", "native")),
            "kline_presentation_mode": normalize_kline_presentation_mode(
                getattr(req, "kline_presentation_mode", "step")
            ),
            "rollback_cache_depth": req.rollback_cache_depth,
            "rollback_full_snapshot_interval": req.rollback_full_snapshot_interval,
            "rollback_capture_max_bars": req.rollback_capture_max_bars,
            "performance_engine_mode": str(getattr(req, "performance_engine_mode", "rust_auto") or "rust_auto"),
            "chip_bucket_step": getattr(req, "chip_bucket_step", None),
            "chart_lazy_layers": normalize_chart_lazy_layers(getattr(req, "chart_lazy_layers", None)),
        }
        APP_STATE.trade_events = []
        APP_STATE.bsp_history = []
        APP_STATE._reset_bsp_incremental_cache()
        APP_STATE._reset_rhythm_history()
        APP_STATE.bsp_judge_logs = []
        APP_STATE._last_level_dirs = {level: None for level in set(JUDGE_TRIGGER_LEVELS.values())}
        APP_STATE._clear_rollback_cache()
        pres_init = normalize_kline_presentation_mode(
            getattr(req, "kline_presentation_mode", "step")
        )
        if pres_init == "instant":
            with init_perf_stage("presentation_end"):
                APP_STATE.apply_kline_presentation_end()
            with init_perf_stage("bsp_snapshot"):
                # 一次性呈现已全量计算缠论，直接复用当前结构生成 BSP 快照。
                APP_STATE.rebuild_bsp_all_snapshot_from_current()
        else:
            with init_perf_stage("bsp_snapshot"):
                APP_STATE.rebuild_bsp_all_snapshot()
            # init 后先推进一根，确保前端有可视数据并可交互
            with init_perf_stage("initial_step"):
                APP_STATE.stepper.step()
                if APP_STATE.chart_mode == "dual" and APP_STATE.stepper2 is not None:
                    APP_STATE.stepper2.step()
                    APP_STATE._sync_stepper_to_anchor(APP_STATE.stepper2, APP_STATE.stepper.current_time())
                elif APP_STATE.chart_mode == "multi" and APP_STATE.multi_steppers:
                    APP_STATE._sync_passives_to_anchor(APP_STATE.stepper.current_time())
                APP_STATE._dual_rebuild_coarse_chan_anti_future(APP_STATE.get_active_stepper().current_time())
                APP_STATE.sync_bsp_history()
                APP_STATE.sync_rhythm_history()
                APP_STATE.after_step_update()
        APP_STATE._rhythm_notice_hits = []
        with init_perf_stage("build_payload"):
            # init 首包省略 kline_all，显著减小 JSON；筹码由 /api/chip_kline_all 懒加载
            payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
        source_label = data_source_label(APP_STATE.stepper.data_src_used)
        if APP_STATE.chart_mode == "dual":
            mode_desc = f"双周期({k_type_to_api_key(APP_STATE.stepper.k_type)}/{k_type_to_api_key(APP_STATE.stepper2.k_type)})"
        elif APP_STATE.chart_mode == "multi":
            mode_desc = "多周期单图(" + ",".join(k_type_to_api_key(s.k_type) for s in [APP_STATE.stepper, *APP_STATE.multi_steppers]) + ")"
        else:
            mode_desc = f"单周期({k_type_to_api_key(APP_STATE.stepper.k_type)})"
        if source_label in ("AKShare", "离线数据"):
            payload["message"] = f"加载成功：{APP_STOCK_NAME or code_norm}，当前数据源 {source_label}，{mode_desc}。"
        else:
            payload["message"] = f"加载成功：{APP_STOCK_NAME or code_norm}，已自动切换到 {source_label}，{mode_desc}。"
        rec_apply = getattr(APP_STATE.stepper, "_chan_record_apply", None)
        trace_extra = drain_record_trace()
        if trace_extra:
            existing = list(payload.get("record_trace") or [])
            payload["record_trace"] = existing + trace_extra
        if init_perf_enabled() and perf_col is not None:
            init_perf_payload = init_perf_report(
                {
                    "chart_mode": APP_STATE.chart_mode,
                    "chan_record_applied": bool(rec_apply and getattr(rec_apply, "applied", False)),
                    "engine_mode": getattr(APP_STATE.stepper, "perf_engine_mode", ""),
                }
            )
            payload["init_perf"] = init_perf_payload
            existing_trace = list(payload.get("record_trace") or [])
            payload["record_trace"] = existing_trace + _init_perf_history_lines(init_perf_payload)
        payload["chip_kline_all_lazy"] = stepper_needs_chip_kline_all(APP_STATE.stepper)
        return payload
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=_error_detail_with_rust(e)) from e


@app.get("/api/chip_kline_all")
def api_chip_kline_all(chart_id: str = "active"):
    """懒加载筹码全历史 kline_all（init 首包已省略以提速）。"""
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先加载会话")
    try:
        st = _stepper_for_session_kline_view(chart_id, None)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not stepper_needs_chip_kline_all(st):
        return {"kline_all": [], "chart_id": chart_id}
    with init_perf_stage("chip_kline_all_api"):
        if (
            getattr(st, "data_src_used", None) == OFFLINE_INLINE_SRC
            and not _kline_all_likely_full_history(st)
            and getattr(st, "k_type", None) in _offline_chip_supported_ktypes()
            and offline_tick_files_exist_for_range(getattr(st, "code", ""), "1990-01-01", None)
        ):
            # 筹码底座只影响筹码分布，放到懒加载接口，避免阻塞“加载会话”。
            _refresh_stepper_chip_kline_all_base(
                st,
                (APP_STATE.session_params or {}).get("autype", AUTYPE.QFQ),
            )
        bars = _kline_all_for_chip_payload(list(st.kline_all or []), getattr(st, "_session_end_date", None))
        if (
            getattr(st, "data_src_used", None) == OFFLINE_INLINE_SRC
            and bars
            and getattr(st, "k_type", None) in _offline_chip_supported_ktypes()
            and offline_tick_files_exist_for_range(getattr(st, "code", ""), getattr(st, "_session_begin_date", None), getattr(st, "_session_end_date", None))
        ):
            # 懒加载只补会话区间，避免 28万根全历史分笔补全卡住前端动态筹码。
            _enrich_kline_all_offline_chip_non_triangle(
                getattr(st, "code", ""),
                bars,
                getattr(st, "_session_end_date", None),
                getattr(st, "k_type", None),
            )
    return {
        "chart_id": chart_id,
        "kline_all": bars,
        "count": len(bars),
        "range_hint": _chip_range_text(
            list(getattr(st, "kline_all", None) or []),
            getattr(st, "_session_begin_date", None),
            getattr(st, "_session_end_date", None),
        ),
    }


@app.post("/api/load_chart_layers")
async def api_load_chart_layers(req: LoadChartLayersReq):
    """按需计算图表重图层（节奏线/各级买卖点）。"""
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先加载会话")
    _init_status_begin("图表懒加载：开始按当前勾选补算图层，不重新加载会话")
    try:
        def _run() -> dict[str, Any]:
            with init_perf_run("chart_lazy_layers") as perf_col:
                payload = APP_STATE.load_chart_layers(req.chart_lazy_layers or {})
                payload["message"] = "图表懒加载图层加载完成"
                if init_perf_enabled() and perf_col is not None:
                    init_perf_payload = init_perf_report(
                        {
                            "chart_mode": APP_STATE.chart_mode,
                            "engine_mode": getattr(APP_STATE.stepper, "perf_engine_mode", ""),
                        }
                    )
                    payload["init_perf"] = init_perf_payload
                    existing = list(payload.get("record_trace") or [])
                    payload["record_trace"] = existing + _init_perf_history_lines(init_perf_payload)
                return payload
        return await run_in_threadpool(_run)
    except InitCancelledError as exc:
        raise HTTPException(status_code=499, detail=str(exc)) from exc
    except Exception as e:
        raise HTTPException(status_code=400, detail=_error_detail_with_rust(e)) from e
    finally:
        _init_status_end()


@app.post("/api/reconfig")
def api_reconfig(req: ReconfigReq):
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    _init_status_begin("配置重算：开始按当前设置重建会话")
    try:
        with init_perf_run("api_reconfig") as perf_col:
            APP_STATE.reconfig(
                req.chan_config,
                data_form_mode=req.data_form_mode,
                data_form_quantity=req.data_form_quantity,
                data_form_quantity_alloc=getattr(req, "data_form_quantity_alloc", None),
                data_feed_mode=getattr(req, "data_feed_mode", "step"),
                offline_data_custom=getattr(req, "offline_data_custom", None),
                kline_presentation_mode=getattr(req, "kline_presentation_mode", None),
                rollback_cache_depth=req.rollback_cache_depth,
                rollback_full_snapshot_interval=req.rollback_full_snapshot_interval,
                rollback_capture_max_bars=req.rollback_capture_max_bars,
                performance_engine_mode=getattr(req, "performance_engine_mode", None),
                chip_bucket_step=getattr(req, "chip_bucket_step", None),
                chart_lazy_layers=getattr(req, "chart_lazy_layers", None),
            )
            APP_STATE._rhythm_notice_hits = []
            include_kline_all = stepper_needs_chip_kline_all(APP_STATE.stepper)
            payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=include_kline_all)
            payload["message"] = "配置更新成功，已按新逻辑重新计算并清除模拟持仓。"
            if init_perf_enabled() and perf_col is not None:
                init_perf_payload = init_perf_report(
                    {
                        "chart_mode": APP_STATE.chart_mode,
                        "engine_mode": getattr(APP_STATE.stepper, "perf_engine_mode", ""),
                    }
                )
                payload["init_perf"] = init_perf_payload
                trace_extra = drain_record_trace()
                payload["record_trace"] = list(payload.get("record_trace") or []) + trace_extra + _init_perf_history_lines(init_perf_payload)
        return payload
    except InitCancelledError as exc:
        APP_STATE.ready = False
        raise HTTPException(status_code=499, detail=str(exc)) from exc
    except Exception as e:
        raise HTTPException(status_code=400, detail=_error_detail_with_rust(e)) from e
    finally:
        _init_status_end()


@app.post("/api/step")
def api_step(req: StepReq):
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
    try:
        step_n = max(1, int(getattr(req, "n", 1) or 1))
        if req.active_chart_id:
            APP_STATE.active_chart_id = APP_STATE._normalize_chart_id(req.active_chart_id)
        active_stepper = APP_STATE.get_active_stepper()
        APP_STATE._push_rollback_snapshot()
        ok = True
        done = 0
        for _ in range(step_n):
            ok = active_stepper.step()
            if not ok:
                break
            done += 1
        if done > 0:
            APP_STATE._sync_passives_to_anchor(active_stepper.current_time())
            APP_STATE._dual_rebuild_coarse_chan_anti_future(active_stepper.current_time())
        APP_STATE.sync_bsp_history()
        APP_STATE.sync_rhythm_history()
        mode = (req.judge_mode or "auto").lower().strip()
        if mode != "manual":
            APP_STATE.after_step_update()
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
        if done <= 0:
            payload["message"] = "已到最后一根K线"
        elif step_n == 1:
            payload["message"] = "步进成功"
        else:
            payload["message"] = f"步进成功（{done}/{step_n}）"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=_error_detail_with_rust(e)) from e


@app.post("/api/judge_bsp")
def api_judge_bsp(req: JudgeBspReq):
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
    try:
        APP_STATE._judge_bsp_against_all(reason=str(req.reason or "manual_check"))
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
        payload["message"] = "买卖点判定完成"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=_error_detail_with_rust(e)) from e


@app.post("/api/buy")
def api_buy():
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
    if normalize_data_feed_mode((APP_STATE.session_params or {}).get("data_feed_mode", "step")) == "unified":
        raise HTTPException(status_code=400, detail="统一喂数据模式仅用于看图，不支持模拟操盘")
    try:
        active_stepper = APP_STATE.get_active_stepper()
        price = active_stepper.current_price()
        step_idx = active_stepper.step_idx
        detail = APP_STATE.account.buy_with_all_cash(price, step_idx)
        APP_STATE.trade_events.append(
            {
                "side": "buy",
                "step_idx": step_idx,
                "x": APP_STATE._current_kline_x(),
                "price": float(price),
                "shares": int(detail.get("shares", 0)),
            }
        )
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
        if trade_events_same_bar_flip(APP_STATE.trade_events, "cover", "buy"):
            sh = int(detail.get("shares", 0))
            payload["message"] = f"当根反手：平空后已开多（{sh} 股）。图表同根「平/买」标记已纵向错开。"
        else:
            payload["message"] = msg_buy(detail)
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=_error_detail_with_rust(e)) from e


@app.post("/api/sell")
def api_sell():
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
    if normalize_data_feed_mode((APP_STATE.session_params or {}).get("data_feed_mode", "step")) == "unified":
        raise HTTPException(status_code=400, detail="统一喂数据模式仅用于看图，不支持模拟操盘")
    try:
        active_stepper = APP_STATE.get_active_stepper()
        price = active_stepper.current_price()
        step_idx = active_stepper.step_idx
        detail = APP_STATE.account.sell_all(price, step_idx)
        APP_STATE.trade_events.append(
            {
                "side": "sell",
                "step_idx": step_idx,
                "x": APP_STATE._current_kline_x(),
                "price": float(price),
                "shares": int(detail.get("shares", 0)),
            }
        )
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
        payload["message"] = msg_sell(detail)
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=_error_detail_with_rust(e)) from e


@app.post("/api/short")
def api_short():
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
    if normalize_data_feed_mode((APP_STATE.session_params or {}).get("data_feed_mode", "step")) == "unified":
        raise HTTPException(status_code=400, detail="统一喂数据模式仅用于看图，不支持模拟操盘")
    try:
        active_stepper = APP_STATE.get_active_stepper()
        price = active_stepper.current_price()
        step_idx = active_stepper.step_idx
        detail = APP_STATE.account.short_with_all_cash(price, step_idx)
        APP_STATE.trade_events.append(
            {
                "side": "short",
                "step_idx": step_idx,
                "x": APP_STATE._current_kline_x(),
                "price": float(price),
                "shares": int(detail.get("shares", 0)),
            }
        )
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
        if trade_events_same_bar_flip(APP_STATE.trade_events, "sell", "short"):
            sh = int(detail.get("shares", 0))
            payload["message"] = f"当根反手：平多后已开空（{sh} 股）。图表同根「卖/空」标记已纵向错开。"
        else:
            payload["message"] = msg_short(detail)
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=_error_detail_with_rust(e)) from e


@app.post("/api/cover")
def api_cover():
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
    if normalize_data_feed_mode((APP_STATE.session_params or {}).get("data_feed_mode", "step")) == "unified":
        raise HTTPException(status_code=400, detail="统一喂数据模式仅用于看图，不支持模拟操盘")
    try:
        active_stepper = APP_STATE.get_active_stepper()
        price = active_stepper.current_price()
        step_idx = active_stepper.step_idx
        detail = APP_STATE.account.cover_all(price, step_idx)
        APP_STATE.trade_events.append(
            {
                "side": "cover",
                "step_idx": step_idx,
                "x": APP_STATE._current_kline_x(),
                "price": float(price),
                "shares": int(detail.get("shares", 0)),
            }
        )
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
        payload["message"] = msg_cover(detail)
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=_error_detail_with_rust(e)) from e


@app.post("/api/goto_step")
def api_goto_step(req: GotoStepReq):
    """将当前复盘会话重建到指定 step_idx（便于从回测成交跳转）。"""
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先加载会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
    try:
        if getattr(req, "active_chart_id", None):
            APP_STATE.active_chart_id = APP_STATE._normalize_chart_id(req.active_chart_id)
        if normalize_data_feed_mode((APP_STATE.session_params or {}).get("data_feed_mode", "step")) == "unified":
            target_raw = max(0, int(req.step_idx))
            active = APP_STATE.get_active_stepper()
            effective = active.unified_set_step_idx(target_raw)
            passive = APP_STATE.get_passive_stepper()
            if passive is not None:
                APP_STATE._sync_stepper_to_anchor(passive, active.current_time())
            elif APP_STATE.chart_mode == "multi" and APP_STATE.multi_steppers:
                APP_STATE._sync_passives_to_anchor(active.current_time())
            APP_STATE._dual_rebuild_coarse_chan_anti_future(active.current_time())
            APP_STATE.sync_bsp_history()
            APP_STATE.sync_rhythm_history()
            APP_STATE.after_step_update()
            payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
            if effective < 0:
                payload["message"] = "跳转失败：无 K 线数据"
            elif effective != target_raw:
                payload["message"] = f"已跳转 step={effective}（请求 {target_raw} 已钳制到合法范围，统一喂数据·仅切片）"
            else:
                payload["message"] = f"已跳转 step={effective}（统一喂数据·仅切片）"
            return payload

        target = max(0, int(req.step_idx))
        cur = int(APP_STATE.get_active_stepper().step_idx)
        if target == cur:
            payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
            payload["message"] = f"已在目标步进 step={target}"
            return payload
        if target < cur:
            APP_STATE.rebuild_to_step(target)
            APP_STATE._rhythm_notice_hits = []
            payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
            payload["message"] = f"已跳转到 step={target}"
            return payload
        # 向前跳转：先回到 0 再步进到 target（步数可能较多）
        APP_STATE.rebuild_to_step(0)
        APP_STATE._rhythm_notice_hits = []
        for _ in range(target):
            active = APP_STATE.get_active_stepper()
            ok = active.step()
            if ok:
                APP_STATE._sync_passives_to_anchor(active.current_time())
            APP_STATE._dual_rebuild_coarse_chan_anti_future(active.current_time())
            APP_STATE.sync_bsp_history()
            APP_STATE.sync_rhythm_history()
            APP_STATE.after_step_update()
            if not ok:
                break
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
        payload["message"] = f"已跳转到 step={APP_STATE.get_active_stepper().step_idx}"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=_error_detail_with_rust(e)) from e


def _indicator_backtest_http(req: IndicatorBacktestReq) -> dict[str, Any]:
    if req.initial_cash <= 0:
        raise ValueError("初始资金必须大于0")
    if req.exit_hold_bars is not None and int(req.exit_hold_bars) < 1:
        raise ValueError("exit_hold_bars 必须>=1 或未传（仅用出场公式）")
    if req.sell_hold_bars is not None and int(req.sell_hold_bars) < 1:
        raise ValueError("兼容字段 sell_hold_bars 必须>=1")
    return run_indicator_backtest(req)


@app.post("/api/indicator_backtest")
def api_indicator_backtest(req: IndicatorBacktestReq):
    """指标+买卖点组合回测（与复盘同序步进+防未来粗末根；BSP 用步进增量 diff）。"""
    try:
        return _indicator_backtest_http(req)
    except OfflineDataConfirmRequired as exc:
        raise HTTPException(
            status_code=409,
            detail={
                "type": "offline_confirm",
                "display_code": exc.display_code,
                "failed_label": exc.failed_label,
                "reason_tag": exc.reason_tag,
                "reason_detail": exc.reason_detail,
            },
        ) from exc
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/strategy_backtest")
def api_strategy_backtest(req: IndicatorBacktestReq):
    """兼容旧路径，逻辑同 /api/indicator_backtest。"""
    return api_indicator_backtest(req)


@app.post("/api/back_n")
def api_back_n(req: BackNReq):
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    try:
        n = int(req.n)
        if n < 1:
            raise ValueError("N 必须>=1")
        moved_mem = APP_STATE._rollback_n_steps_from_memory(n)
        if moved_mem == n:
            payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
            payload["message"] = f"内存快速回退：已后退 {moved_mem} 根"
            return payload
        if moved_mem > 0:
            n -= moved_mem
        cur = APP_STATE.get_active_stepper().step_idx
        target = max(0, cur - n)
        APP_STATE.rebuild_to_step(target)
        APP_STATE._rhythm_notice_hits = []
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
        payload["message"] = f"自动重建回放：已后退 {cur - target} 根（目标 step={target}）"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.get("/api/state")
def api_state():
    return APP_STATE.build_payload(stock_name=APP_STOCK_NAME)


@app.post("/api/finish")
def api_finish():
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    APP_STATE.finished = True
    payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
    payload["message"] = "训练结束"
    return payload


@app.post("/api/set_data_source_priority")
def api_set_data_source_priority(req: dict):
    """设置数据源优先级（K 线与筹码共用此顺序，两套链同步更新）。"""
    try:
        priority = req.get("priority", [])
        if not isinstance(priority, list):
            raise ValueError("priority 必须是数组")
        apply_data_source_priority([str(x) for x in priority])
        system_config = APP_STATE.stepper.effective_cfg_dict or {}
        system_config["data_source_priority"] = priority
        APP_STATE.stepper.effective_cfg_dict = system_config
        return {"message": f"数据源优先级已更新：{priority}"}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/check_data_source")
def api_check_data_source(req: dict):
    """探测单个数据源能否拉到测试股票的日线（含爬虫类源）。"""
    name = str((req or {}).get("name") or "").strip()
    pair = _DATA_SOURCE_NAME_TO_PAIR.get(name)
    if not pair:
        raise HTTPException(status_code=400, detail=f"未知数据源：{name}")
    _label, data_src = pair
    if data_src == OFFLINE_INLINE_SRC:
        for probe in ("sz.000001", "sh.600000"):
            if offline_bundle_exists(probe, "1990-01-01", "2099-12-31"):
                return {"ok": True, "name": name, "message": f"a_Data 下存在 {offline_folder_from_code(probe)} 分笔目录（含日期范围内 YYYYMMDD_代码.txt）"}
        return {"ok": False, "name": name, "message": "a_Data 下未发现探测用股票（如 000001）的离线分笔：需 a_Data/六位代码/YYYYMMDD_六位代码.txt"}
    test_code = "sz.000001"
    begin = "2024-06-01"
    end = "2024-06-15"
    cfg_fetch = CChanConfig({"trigger_step": False, "print_warning": False, "print_err_time": False})
    try:
        fetch_chan = ReplayDataChan(
            code=test_code,
            begin_time=begin,
            end_time=end,
            data_src=data_src,
            lv_list=[KL_TYPE.K_DAY],
            config=cfg_fetch,
            autype=AUTYPE.QFQ,
        )
        n = 0
        for _ in zip(fetch_chan[0].klu_iter(), range(5)):
            n += 1
        if n == 0:
            return {"ok": False, "name": name, "message": "迭代为空"}
        return {"ok": True, "name": name, "message": f"{name} 可拉取日线样本（{n} 根）"}
    except Exception as e:
        return {"ok": False, "name": name, "message": format_source_error(e)}


@app.get("/api/perf_cache_status")
def api_perf_cache_status():
    """性能引擎缓存状态：前端系统设置弹窗展示与调试使用。"""
    return APP_PERF_ENGINE.cache_status()


@app.post("/api/perf_clear_cache")
def api_perf_clear_cache():
    """清理 a_replay_cache/a_perf_engine_cache 下的性能缓存。"""
    try:
        return APP_PERF_ENGINE.clear_cache()
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/session_kline_view")
def api_session_kline_view(req: SessionKlineViewReq):
    """供前端「查看数据」：从服务端 kline_all 取全量，避免步进后前端未带全量 JSON。"""
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先加载会话")
    try:
        stepper = _stepper_for_session_kline_view(req.chart_id, req.layer_k_type)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    try:
        rows = _kline_view_rows_filtered(list(stepper.kline_all or []), req.view)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    resolved = "chart2" if stepper is APP_STATE.stepper2 else "chart1"
    return {
        "code": stepper.code,
        "k_type": k_type_to_api_key(stepper.k_type),
        "chart_id": resolved,
        "layer_k_type": str(req.layer_k_type).strip().lower() if req.layer_k_type else None,
        "view": str(req.view or "").strip().lower(),
        "bar_count": len(rows),
        "rows": rows,
    }


@app.post("/api/reset")
def api_reset():
    global APP_STOCK_NAME
    APP_STOCK_NAME = None
    APP_STATE.stepper = ChanStepper()
    APP_STATE.stepper2 = None
    APP_STATE.chart_mode = "single"
    APP_STATE.active_chart_id = "chart1"
    APP_STATE.account = PaperAccount(initial_cash=10_000, cash=10_000)
    APP_STATE.ready = False
    APP_STATE.finished = False
    APP_STATE.session_params = None
    APP_STATE.trade_events = []
    APP_STATE.bsp_history = []
    APP_STATE._reset_bsp_incremental_cache()
    APP_STATE._reset_rhythm_history()
    APP_STATE.bsp_all_snapshot = []
    APP_STATE.bsp_judge_logs = []
    APP_STATE._last_level_dirs = {level: None for level in set(JUDGE_TRIGGER_LEVELS.values())}
    APP_STATE._reset_judge_state()
    APP_STATE._clear_rollback_cache()
    return APP_STATE.build_payload(stock_name=APP_STOCK_NAME)


@app.post("/api/exit")
def api_exit():
    import os
    import signal
    os.kill(os.getpid(), signal.SIGTERM)
    return {"message": "Server is exiting..."}


if __name__ == "__main__":
    import os
    import socket

    def _can_bind_port(host: str, port: int) -> tuple[bool, str]:
        """启动前探测端口；10013 通常是 Windows 保留/安全策略拒绝。"""
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                s.bind((host, int(port)))
            return True, ""
        except OSError as exc:
            return False, str(exc)

    def _pick_server_port(host: str = "127.0.0.1") -> int:
        """优先 8000；被占用或被系统拒绝时自动换端口。"""
        env_port = str(os.environ.get("A_REPLAY_PORT") or "").strip()
        candidates: list[int] = []
        if env_port:
            try:
                candidates.append(int(env_port))
            except ValueError:
                print(f"A_REPLAY_PORT={env_port!r} 不是合法端口，已忽略。")
        candidates.extend([8000, 8765, 8766, 8767, 8768, 8769, 8770, 18000, 18001])
        seen: set[int] = set()
        last_error = ""
        for port in candidates:
            if port in seen:
                continue
            seen.add(port)
            ok, reason = _can_bind_port(host, port)
            if ok:
                if port != 8000:
                    print(f"8000 不可用或被系统拒绝，已自动改用端口 {port}。")
                return port
            last_error = reason
            print(f"端口 {port} 不可用：{reason}")
        raise RuntimeError(f"没有找到可用端口，最后错误：{last_error}")

    host = "127.0.0.1"
    port = _pick_server_port(host)
    print(f"复盘训练器已准备启动：请访问 http://{host}:{port}/")
    uvicorn.run(app, host=host, port=port)


