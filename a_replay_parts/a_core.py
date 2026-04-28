import copy
import json
import math
import re
import socket
import subprocess
import sys
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from threading import RLock
from typing import Any, Iterable, Optional

import akshare as ak
import pandas as pd
import tushare as ts
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from Bi.Bi import CBi
from BuySellPoint.BSPointList import CBSPointList
from Chan import CChan
from ChanConfig import CChanConfig
from Common.CEnum import AUTYPE, BI_DIR, DATA_FIELD, DATA_SRC, FX_TYPE, KL_TYPE, KLINE_DIR, SEG_TYPE, TREND_LINE_SIDE
from Common.ChanException import CChanException, ErrCode
from Common.CTime import CTime
from DataAPI.BaoStockAPI import CBaoStock
from DataAPI.CommonStockAPI import CCommonStockApi
from Common.func_util import check_kltype_order, str2float
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
from .a_data_extra import (
    ADATA_INLINE_SRC,
    ASHARE_INLINE_SRC,
    EASTMONEY_INLINE_SRC,
    EXTRA_DATA_SOURCE_CHAIN,
    EXTRA_SOURCE_LEVELS,
    SINA_INLINE_SRC,
    TENCENT_INLINE_SRC,
    YAHOO_INLINE_SRC,
    CAdataInline,
    CAshareInline,
    CEastmoneyInline,
    CSinaInline,
    CTencentInline,
    CYahooInline,
    SharedSettingsReq,
    aggregate_klu_items,
    fetch_tick_trades_cached,
    get_shared_settings,
    normalize_kl_type_name,
    resolve_override_path,
    set_shared_settings,
)
from .a_persist import read_runtime_pref, write_runtime_pref


class ReplayChan(CChan):
    """使用会话内缓存的日线 K 线单元重建缠论计算，避免重复请求行情。

    trigger_step 模式下每次 load() 从内存快照 deepcopy 后喂给 load_iterator，
    笔/线段/中枢/买卖点均随 ChanConfig 重新计算；数据层与配置层解耦。
    """

    def __init__(self, *args: Any, replay_klus_master: Optional[list] = None, **kwargs: Any) -> None:
        self._replay_klus_master: Optional[list] = replay_klus_master
        super().__init__(*args, **kwargs)

    def load(self, step: bool = False):
        if self._replay_klus_master is None:
            yield from super().load(step)
            return
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
LEVEL_LABELS = {"bi": "笔", "seg": "段", "segseg": "2段"}
STRUCTURE_LEVEL_LABELS = {"fract": "分型", **LEVEL_LABELS}
RHYTHM_LEVEL_LABELS = {"fract": "分型", "bi": "笔", "seg": "线段", "segseg": "二段"}
JUDGE_TRIGGER_LEVELS = {"bi": "seg", "seg": "segseg", "segseg": "segsegseg"}
DEFAULT_TUSHARE_TOKEN = "0de8d8ce7b0d4758c52959230694d55e0571d57c9b1f37ef3ffe72ca"
AKSHARE_INLINE_SRC = "inline:akshare"
TUSHARE_INLINE_SRC = "inline:tushare"
OFFLINE_TXT_INLINE_SRC = "inline:offline_txt"
OFFLINE_DATA_ROOT = Path(__file__).resolve().parent.parent / "a_Data"
DATA_SOURCE_CHAIN: list[tuple[str, Any]] = [
    ("BaoStock", DATA_SRC.BAO_STOCK),
    ("AKShare", AKSHARE_INLINE_SRC),
    ("Ashare", ASHARE_INLINE_SRC),
    ("AData", ADATA_INLINE_SRC),
    ("Tushare", TUSHARE_INLINE_SRC),
    ("OfflineTXT", OFFLINE_TXT_INLINE_SRC),
    ("Tencent", TENCENT_INLINE_SRC),
    ("Sina", SINA_INLINE_SRC),
    ("Eastmoney", EASTMONEY_INLINE_SRC),
    ("Yahoo", YAHOO_INLINE_SRC),
]
DEFAULT_DATA_SOURCE_PRIORITY = [label for label, _ in DATA_SOURCE_CHAIN]
DATA_SOURCE_PRIORITY_LOCK = RLock()
_persisted_source_priority = read_runtime_pref("source_priority", DEFAULT_DATA_SOURCE_PRIORITY)
DATA_SOURCE_PRIORITY = list(DEFAULT_DATA_SOURCE_PRIORITY)
LEVEL_FETCH_CACHE_LOCK = RLock()
LEVEL_FETCH_CACHE: dict[tuple[Any, ...], tuple[list[CKLine_Unit], Optional[str]]] = {}
RUNTIME_LEVEL_FETCH_CACHE_LOCK = RLock()
RUNTIME_LEVEL_FETCH_CACHE: dict[tuple[Any, ...], tuple[list[CKLine_Unit], Optional[str], Any, str, list[str]]] = {}
BAOSTOCK_HEALTH_LOCK = RLock()
BAOSTOCK_HEALTH_STATE = {"checked_at": 0.0, "ok": True, "detail": ""}
BAOSTOCK_LEVELS = {KL_TYPE.K_DAY, KL_TYPE.K_WEEK, KL_TYPE.K_MON, KL_TYPE.K_5M, KL_TYPE.K_15M, KL_TYPE.K_30M, KL_TYPE.K_60M}
AKSHARE_LEVELS = {KL_TYPE.K_DAY, KL_TYPE.K_WEEK, KL_TYPE.K_MON}
TUSHARE_LEVELS = {KL_TYPE.K_DAY, KL_TYPE.K_WEEK, KL_TYPE.K_MON}
OFFLINE_LEVELS = {KL_TYPE.K_1M, KL_TYPE.K_3M, KL_TYPE.K_5M, KL_TYPE.K_15M, KL_TYPE.K_30M, KL_TYPE.K_60M, KL_TYPE.K_DAY, KL_TYPE.K_WEEK, KL_TYPE.K_MON, KL_TYPE.K_QUARTER, KL_TYPE.K_YEAR}


def _normalize_persisted_priority(raw_priority: Any) -> list[str]:
    preferred = [str(item or "").strip() for item in (raw_priority or []) if str(item or "").strip()]
    if not preferred:
        return list(DEFAULT_DATA_SOURCE_PRIORITY)
    seen = set()
    merged: list[str] = []
    for item in preferred + DEFAULT_DATA_SOURCE_PRIORITY:
        if item in seen or item not in DEFAULT_DATA_SOURCE_PRIORITY:
            continue
        merged.append(item)
        seen.add(item)
    return merged


with DATA_SOURCE_PRIORITY_LOCK:
    DATA_SOURCE_PRIORITY[:] = _normalize_persisted_priority(_persisted_source_priority)


def normalize_chan_algo(raw: Any) -> str:
    text = str(raw or CHAN_ALGO_CLASSIC).strip().lower()
    return CHAN_ALGO_NEW if text == CHAN_ALGO_NEW else CHAN_ALGO_CLASSIC


def data_source_label(data_src: Any) -> str:
    if data_src == DATA_SRC.AKSHARE or data_src == AKSHARE_INLINE_SRC:
        return "AKShare"
    if data_src == DATA_SRC.BAO_STOCK:
        return "BaoStock"
    if data_src == ASHARE_INLINE_SRC:
        return "Ashare"
    if data_src == ADATA_INLINE_SRC:
        return "AData"
    if data_src == TUSHARE_INLINE_SRC:
        return "Tushare"
    if data_src == OFFLINE_TXT_INLINE_SRC:
        return "OfflineTXT"
    if data_src == TENCENT_INLINE_SRC:
        return "Tencent"
    if data_src == SINA_INLINE_SRC:
        return "Sina"
    if data_src == EASTMONEY_INLINE_SRC:
        return "Eastmoney"
    if data_src == YAHOO_INLINE_SRC:
        return "Yahoo"
    if isinstance(data_src, DATA_SRC):
        return data_src.name
    return str(data_src)


def data_source_supports_level(data_src: Any, lv: KL_TYPE) -> bool:
    if data_src == DATA_SRC.BAO_STOCK:
        return lv in BAOSTOCK_LEVELS
    if data_src == DATA_SRC.AKSHARE or data_src == AKSHARE_INLINE_SRC:
        return lv in AKSHARE_LEVELS
    if data_src == TUSHARE_INLINE_SRC:
        return lv in TUSHARE_LEVELS
    if data_src == OFFLINE_TXT_INLINE_SRC:
        return lv in OFFLINE_LEVELS
    if data_src in EXTRA_SOURCE_LEVELS:
        return lv in EXTRA_SOURCE_LEVELS[data_src]
    return True


def get_data_source_chain(priority: Optional[list[str]] = None) -> list[tuple[str, Any]]:
    ordered = list(priority or DATA_SOURCE_PRIORITY)
    seen = set()
    result: list[tuple[str, Any]] = []
    for label in ordered + DEFAULT_DATA_SOURCE_PRIORITY:
        if label in seen:
            continue
        for item_label, data_src in DATA_SOURCE_CHAIN:
            if item_label == label:
                seen.add(label)
                result.append((item_label, data_src))
                break
    return result


def ensure_baostock_available(force: bool = False) -> None:
    now = time.time()
    with BAOSTOCK_HEALTH_LOCK:
        checked_at = float(BAOSTOCK_HEALTH_STATE.get("checked_at") or 0.0)
        if not force and checked_at and now - checked_at < 300:
            if BAOSTOCK_HEALTH_STATE.get("ok"):
                return
            raise RuntimeError(str(BAOSTOCK_HEALTH_STATE.get("detail") or "BaoStock unavailable"))
    probe_code = (
        "import sys, baostock as bs\n"
        "lg = bs.login()\n"
        "ok = getattr(lg, 'error_code', '') == '0'\n"
        "msg = getattr(lg, 'error_msg', '') or ''\n"
        "try:\n"
        "    bs.logout()\n"
        "except Exception:\n"
        "    pass\n"
        "print(msg)\n"
        "sys.exit(0 if ok else 1)\n"
    )
    ok = False
    detail = ""
    try:
        result = subprocess.run(
            [sys.executable, "-c", probe_code],
            capture_output=True,
            text=True,
            timeout=6,
            check=False,
        )
        ok = result.returncode == 0
        detail = (result.stdout or result.stderr or "").strip()
        if not ok and not detail:
            detail = f"returncode={result.returncode}"
    except subprocess.TimeoutExpired:
        detail = "login timeout"
    except Exception as exc:
        detail = str(exc or exc.__class__.__name__).strip() or exc.__class__.__name__
    with BAOSTOCK_HEALTH_LOCK:
        BAOSTOCK_HEALTH_STATE.update({"checked_at": now, "ok": ok, "detail": detail})
    if not ok:
        raise RuntimeError(f"BaoStock unavailable: {detail}")


def get_data_source_settings() -> dict[str, Any]:
    with DATA_SOURCE_PRIORITY_LOCK:
        priority = list(DATA_SOURCE_PRIORITY)
    return {
        "priority": priority,
        "available": list(DEFAULT_DATA_SOURCE_PRIORITY),
    }


def set_data_source_priority(priority: list[str]) -> dict[str, Any]:
    cleaned = [str(item or "").strip() for item in priority if str(item or "").strip()]
    if not cleaned:
        cleaned = list(DEFAULT_DATA_SOURCE_PRIORITY)
    unknown = [item for item in cleaned if item not in DEFAULT_DATA_SOURCE_PRIORITY]
    if unknown:
        raise ValueError(f"未知数据源：{'、'.join(unknown)}")
    merged = cleaned + [item for item in DEFAULT_DATA_SOURCE_PRIORITY if item not in cleaned]
    with DATA_SOURCE_PRIORITY_LOCK:
        DATA_SOURCE_PRIORITY[:] = merged
        snapshot = list(DATA_SOURCE_PRIORITY)
    write_runtime_pref("source_priority", snapshot)
    return get_data_source_settings()


class DataSourceSettingsReq(BaseModel):
    priority: list[str] = Field(default_factory=list)


def get_stock_api_cls(data_src: Any):
    if data_src == DATA_SRC.AKSHARE or data_src == AKSHARE_INLINE_SRC:
        return CAkshareInline
    if data_src == DATA_SRC.BAO_STOCK:
        return CBaoStock
    if data_src == ASHARE_INLINE_SRC:
        return CAshareInline
    if data_src == ADATA_INLINE_SRC:
        return CAdataInline
    if data_src == TUSHARE_INLINE_SRC:
        return CTushareInline
    if data_src == OFFLINE_TXT_INLINE_SRC:
        return COfflineTxtApi
    if data_src == TENCENT_INLINE_SRC:
        return CTencentInline
    if data_src == SINA_INLINE_SRC:
        return CSinaInline
    if data_src == EASTMONEY_INLINE_SRC:
        return CEastmoneyInline
    if data_src == YAHOO_INLINE_SRC:
        return CYahooInline
    raise ValueError(f"unsupported data source: {data_src}")


def create_stock_api_instance(
    data_src: Any,
    code: str,
    begin_date: Optional[str],
    end_date: Optional[str],
    autype: AUTYPE,
    k_type: KL_TYPE = KL_TYPE.K_DAY,
) -> CCommonStockApi:
    api_cls = get_stock_api_cls(data_src)
    prev_timeout = None
    try:
        if data_src == DATA_SRC.BAO_STOCK:
            ensure_baostock_available()
            prev_timeout = socket.getdefaulttimeout()
            socket.setdefaulttimeout(8.0)
        api_cls.do_init()
        return api_cls(code=code, k_type=k_type, begin_date=begin_date, end_date=end_date, autype=autype)
    except Exception:
        api_cls.do_close()
        raise
    finally:
        if data_src == DATA_SRC.BAO_STOCK:
            socket.setdefaulttimeout(prev_timeout)


def _offline_symbol(code: str) -> str:
    return re.sub(r"[^0-9]", "", _strip_market_prefix(code))


def _offline_market(code: str) -> str:
    symbol = _offline_symbol(code)
    return "SH" if symbol.startswith(("5", "6", "9")) else "SZ"


def resolve_offline_kline_path(code: str) -> Optional[Path]:
    symbol = _offline_symbol(code)
    if not symbol:
        return None
    settings = get_shared_settings()
    override = resolve_override_path(settings.get("offline_kline_path", ""))
    if override:
        if override.is_file():
            return override
        if override.is_dir():
            matches = sorted(override.glob(f"*#{symbol}.txt"))
            if matches:
                return matches[0]
    market = _offline_market(code)
    direct = OFFLINE_DATA_ROOT / f"{market}#{symbol}" / "KLine" / f"{market}#{symbol}.txt"
    if direct.exists():
        return direct
    matches = sorted(OFFLINE_DATA_ROOT.glob(f"*#{symbol}/KLine/*#{symbol}.txt"))
    return matches[0] if matches else None


def _parse_offline_time(date_text: str, time_text: str) -> tuple[CTime, datetime]:
    date_value = str(date_text or "").strip().replace("/", "-")
    time_value = str(time_text or "").strip().zfill(4)
    dt = datetime(
        int(date_value[:4]),
        int(date_value[5:7]),
        int(date_value[8:10]),
        int(time_value[:2]),
        int(time_value[2:4]),
    )
    return CTime(dt.year, dt.month, dt.day, dt.hour, dt.minute), dt


def _offline_rows_from_txt(path: Path, begin_date: Optional[str], end_date: Optional[str]) -> list[dict[str, Any]]:
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    rows: list[dict[str, Any]] = []
    for raw in lines[2:]:
        text = raw.strip()
        if not text:
            continue
        parts = re.split(r"\s+", text)
        if len(parts) < 8:
            continue
        ctime, dt = _parse_offline_time(parts[0], parts[1])
        day_key = f"{dt.year:04d}-{dt.month:02d}-{dt.day:02d}"
        if begin_date and day_key < str(begin_date):
            continue
        if end_date and day_key > str(end_date):
            continue
        rows.append(
            {
                "dt": dt,
                DATA_FIELD.FIELD_TIME: ctime,
                DATA_FIELD.FIELD_OPEN: str2float(parts[2]),
                DATA_FIELD.FIELD_HIGH: str2float(parts[3]),
                DATA_FIELD.FIELD_LOW: str2float(parts[4]),
                DATA_FIELD.FIELD_CLOSE: str2float(parts[5]),
                DATA_FIELD.FIELD_VOLUME: str2float(parts[6]),
                DATA_FIELD.FIELD_TURNOVER: str2float(parts[7]),
            }
        )
    return rows


def _merge_offline_rows(rows: list[dict[str, Any]], k_type: KL_TYPE) -> dict[str, Any]:
    last_dt = rows[-1]["dt"]
    time_value = CTime(last_dt.year, last_dt.month, last_dt.day, 0, 0) if k_type in {KL_TYPE.K_DAY, KL_TYPE.K_WEEK, KL_TYPE.K_MON, KL_TYPE.K_QUARTER, KL_TYPE.K_YEAR} else CTime(last_dt.year, last_dt.month, last_dt.day, last_dt.hour, last_dt.minute)
    return {
        DATA_FIELD.FIELD_TIME: time_value,
        DATA_FIELD.FIELD_OPEN: rows[0][DATA_FIELD.FIELD_OPEN],
        DATA_FIELD.FIELD_HIGH: max(item[DATA_FIELD.FIELD_HIGH] for item in rows),
        DATA_FIELD.FIELD_LOW: min(item[DATA_FIELD.FIELD_LOW] for item in rows),
        DATA_FIELD.FIELD_CLOSE: rows[-1][DATA_FIELD.FIELD_CLOSE],
        DATA_FIELD.FIELD_VOLUME: sum(item.get(DATA_FIELD.FIELD_VOLUME, 0.0) for item in rows),
        DATA_FIELD.FIELD_TURNOVER: sum(item.get(DATA_FIELD.FIELD_TURNOVER, 0.0) for item in rows),
    }


def _aggregate_offline_rows(rows: list[dict[str, Any]], k_type: KL_TYPE) -> list[dict[str, Any]]:
    if k_type == KL_TYPE.K_1M:
        return [_merge_offline_rows([row], k_type) for row in rows]
    if not rows:
        return []
    minute_map = {
        KL_TYPE.K_3M: 3,
        KL_TYPE.K_5M: 5,
        KL_TYPE.K_15M: 15,
        KL_TYPE.K_30M: 30,
        KL_TYPE.K_60M: 60,
    }
    grouped: list[list[dict[str, Any]]] = []
    current_key = None
    current_group: list[dict[str, Any]] = []
    for row in rows:
        dt = row["dt"]
        if k_type in minute_map:
            base = datetime(dt.year, dt.month, dt.day, 9, 30) if dt.hour < 12 else datetime(dt.year, dt.month, dt.day, 13, 0)
            bucket = max(0, int((dt - base).total_seconds() // 60) // minute_map[k_type])
            key = (dt.date().isoformat(), 0 if dt.hour < 12 else 1, bucket)
        elif k_type == KL_TYPE.K_DAY:
            key = (dt.year, dt.month, dt.day)
        elif k_type == KL_TYPE.K_WEEK:
            iso = dt.isocalendar()
            key = ("week", iso.year, iso.week)
        elif k_type == KL_TYPE.K_MON:
            key = ("month", dt.year, dt.month)
        elif k_type == KL_TYPE.K_QUARTER:
            key = ("quarter", dt.year, (dt.month - 1) // 3 + 1)
        elif k_type == KL_TYPE.K_YEAR:
            key = ("year", dt.year)
        else:
            raise ValueError(f"OfflineTXT 暂不支持 {k_type}")
        if current_key != key:
            if current_group:
                grouped.append(current_group)
            current_key = key
            current_group = [row]
        else:
            current_group.append(row)
    if current_group:
        grouped.append(current_group)
    return [_merge_offline_rows(group, k_type) for group in grouped]


class COfflineTxtApi(CCommonStockApi):
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.file_path: Optional[Path] = None
        super(COfflineTxtApi, self).__init__(code, k_type, begin_date, end_date, autype)

    def SetBasciInfo(self):
        self.file_path = resolve_offline_kline_path(self.code)
        if self.file_path is None:
            raise FileNotFoundError(f"离线 K 线文件不存在：{self.code}")
        lines = self.file_path.read_text(encoding="utf-8", errors="ignore").splitlines()
        header = lines[0].strip() if lines else str(self.code)
        parts = re.split(r"\s+", header)
        self.name = parts[1] if len(parts) >= 2 else str(self.code)
        self.is_stock = True

    def get_kl_data(self):
        if self.file_path is None:
            raise FileNotFoundError(f"离线 K 线文件不存在：{self.code}")
        raw_rows = _offline_rows_from_txt(self.file_path, self.begin_date, self.end_date)
        for idx, item in enumerate(_aggregate_offline_rows(raw_rows, self.k_type)):
            klu = CKLine_Unit(item)
            klu.set_idx(idx)
            klu.kl_type = self.k_type
            if not hasattr(klu, "macd"):
                klu.macd = None
            if not hasattr(klu, "boll"):
                klu.boll = None
            yield klu

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass


def fetch_klu_list_from_api(api: CCommonStockApi, lv: KL_TYPE) -> list[CKLine_Unit]:
    items: list[CKLine_Unit] = []
    for idx, klu in enumerate(api.get_kl_data()):
        klu.set_idx(idx)
        klu.kl_type = lv
        if not hasattr(klu, "macd"):
            klu.macd = None
        if not hasattr(klu, "boll"):
            klu.boll = None
        items.append(klu)
    return items


def _level_fetch_cache_key(data_src: Any, code: str, begin_date: Optional[str], end_date: Optional[str], autype: AUTYPE, lv: KL_TYPE) -> tuple[Any, ...]:
    autype_key = autype.name if isinstance(autype, AUTYPE) else str(autype)
    return (
        data_source_label(data_src),
        _strip_market_prefix(code),
        str(begin_date or ""),
        str(end_date or ""),
        autype_key,
        lv.name,
    )


def fetch_level_klus_cached(
    data_src: Any,
    code: str,
    begin_date: Optional[str],
    end_date: Optional[str],
    autype: AUTYPE,
    lv: KL_TYPE,
) -> tuple[list[CKLine_Unit], Optional[str], bool]:
    if not data_source_supports_level(data_src, lv):
        raise ValueError(f"{data_source_label(data_src)} 暂不支持 {lv.name}")
    cache_key = _level_fetch_cache_key(data_src, code, begin_date, end_date, autype, lv)
    with LEVEL_FETCH_CACHE_LOCK:
        cached = LEVEL_FETCH_CACHE.get(cache_key)
    if cached is not None:
        items, stock_name = cached
        return copy.deepcopy(items), stock_name, True
    api = create_stock_api_instance(data_src, code, begin_date, end_date, autype, k_type=lv)
    try:
        stock_name = getattr(api, "name", None) or None
        items = fetch_klu_list_from_api(api, lv)
    finally:
        try:
            get_stock_api_cls(data_src).do_close()
        except Exception:
            pass
    if not items:
        raise ValueError("未获取到任何数据")
    with LEVEL_FETCH_CACHE_LOCK:
        LEVEL_FETCH_CACHE[cache_key] = (copy.deepcopy(items), stock_name)
    return copy.deepcopy(items), stock_name, False


@dataclass
class RuntimeLevelSelection:
    data_src: Any
    label: str
    logs: list[str]
    items: list[CKLine_Unit]
    stock_name: Optional[str]
    target_lv: KL_TYPE
    fetch_lv: KL_TYPE


def runtime_fetch_base_level(target_lv: KL_TYPE, mode: Optional[str] = None) -> KL_TYPE:
    quality = str(mode or get_shared_settings().get("data_quality") or "network_direct").strip().lower()
    if quality not in {"network_agg", "offline_agg"}:
        return target_lv
    if target_lv in {KL_TYPE.K_3M, KL_TYPE.K_5M, KL_TYPE.K_15M, KL_TYPE.K_30M, KL_TYPE.K_60M}:
        return KL_TYPE.K_1M
    if target_lv in {KL_TYPE.K_DAY, KL_TYPE.K_WEEK, KL_TYPE.K_MON, KL_TYPE.K_QUARTER, KL_TYPE.K_YEAR}:
        return KL_TYPE.K_DAY
    return target_lv


def get_runtime_data_source_chain() -> list[tuple[str, Any]]:
    shared = get_shared_settings()
    chain = list(get_data_source_chain())
    if str(shared.get("data_quality") or "").lower().startswith("offline"):
        current_order = {label: idx for idx, (label, _) in enumerate(chain)}
        chain.sort(key=lambda item: (0 if item[0] == "OfflineTXT" else 1, current_order.get(item[0], 999)))
    return chain


def _runtime_level_fetch_cache_key(
    code: str,
    begin_date: Optional[str],
    end_date: Optional[str],
    autype: AUTYPE,
    lv: KL_TYPE,
) -> tuple[Any, ...]:
    shared = get_shared_settings()
    source_chain = [label for label, _ in get_runtime_data_source_chain()]
    autype_key = autype.name if isinstance(autype, AUTYPE) else str(autype)
    return (
        str(shared.get("data_quality") or "network_direct"),
        str(shared.get("offline_kline_path") or ""),
        tuple(source_chain),
        _strip_market_prefix(code),
        str(begin_date or ""),
        str(end_date or ""),
        autype_key,
        lv.name,
    )


def select_runtime_data_source_for_level(
    code: str,
    begin_date: Optional[str],
    end_date: Optional[str],
    autype: AUTYPE,
    lv: KL_TYPE,
) -> RuntimeLevelSelection:
    cache_key = _runtime_level_fetch_cache_key(code, begin_date, end_date, autype, lv)
    with RUNTIME_LEVEL_FETCH_CACHE_LOCK:
        cached = RUNTIME_LEVEL_FETCH_CACHE.get(cache_key)
    if cached is not None:
        items, stock_name, data_src, label, logs = cached
        return RuntimeLevelSelection(
            data_src=data_src,
            label=label,
            logs=list(logs),
            items=copy.deepcopy(items),
            stock_name=stock_name,
            target_lv=lv,
            fetch_lv=runtime_fetch_base_level(lv),
        )
    shared = get_shared_settings()
    mode = str(shared.get("data_quality") or "network_direct").strip().lower()
    fetch_lv = runtime_fetch_base_level(lv, mode)
    errors: list[str] = []
    logs: list[str] = [f"取数策略：{mode}"]
    for label, data_src in get_runtime_data_source_chain():
        if not data_source_supports_level(data_src, fetch_lv):
            errors.append(f"{label}:不支持{normalize_kl_type_name(fetch_lv)}")
            continue
        try:
            base_items, stock_name, _ = fetch_level_klus_cached(
                data_src=data_src,
                code=code,
                begin_date=begin_date,
                end_date=end_date,
                autype=autype,
                lv=fetch_lv,
            )
            items = aggregate_klu_items(base_items, lv) if fetch_lv != lv else base_items
            if len(items) <= 0:
                raise ValueError("未获取到任何数据")
            if fetch_lv != lv:
                logs.append(f"{normalize_kl_type_name(lv)} 使用 {label}，先取 {normalize_kl_type_name(fetch_lv)} 再聚合")
            else:
                logs.append(f"{normalize_kl_type_name(lv)} 使用 {label} 直接加载")
            result = RuntimeLevelSelection(
                data_src=data_src,
                label=label,
                logs=logs + errors,
                items=copy.deepcopy(items),
                stock_name=stock_name,
                target_lv=lv,
                fetch_lv=fetch_lv,
            )
            with RUNTIME_LEVEL_FETCH_CACHE_LOCK:
                RUNTIME_LEVEL_FETCH_CACHE[cache_key] = (
                    copy.deepcopy(items),
                    stock_name,
                    data_src,
                    label,
                    list(result.logs),
                )
            return result
        except Exception as exc:
            errors.append(f"{label}:{format_source_error(exc)}")
    raise RuntimeError(f"{normalize_kl_type_name(lv)} 数据源全部失败：{'；'.join(errors)}")


def format_source_error(exc: Exception) -> str:
    text = str(exc or exc.__class__.__name__).strip()
    if not text:
        text = exc.__class__.__name__
    return " ".join(text.split())


def _strip_market_prefix(code: str) -> str:
    text = str(code or "").strip().lower()
    if text.startswith("sh.") or text.startswith("sz."):
        return text.split(".", 1)[1]
    if text.startswith("sh") or text.startswith("sz"):
        return text[2:]
    return text


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


class CAkshareInline(CCommonStockApi):
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.symbol = _strip_market_prefix(code)
        super(CAkshareInline, self).__init__(code, k_type, begin_date, end_date, autype)

    def get_kl_data(self):
        adjust_map = {AUTYPE.QFQ: "qfq", AUTYPE.HFQ: "hfq", AUTYPE.NONE: ""}
        period_map = {KL_TYPE.K_DAY: "daily", KL_TYPE.K_WEEK: "weekly", KL_TYPE.K_MON: "monthly"}
        if self.k_type not in period_map:
            raise ValueError(f"AKShare 暂不支持 {self.k_type} 级别")

        start_date = (self.begin_date or "1990-01-01").replace("-", "")
        end_date = (self.end_date or "2099-12-31").replace("-", "")
        if self.is_stock:
            df = ak.stock_zh_a_hist(
                symbol=self.symbol,
                period=period_map[self.k_type],
                start_date=start_date,
                end_date=end_date,
                adjust=adjust_map.get(self.autype, "qfq"),
            )
        else:
            market = "sh" if str(self.code).lower().startswith("sh") else "sz"
            raw_df = ak.stock_zh_index_daily(symbol=f"{market}{self.symbol}")
            df = raw_df.rename(columns={"date": "日期", "open": "开盘", "high": "最高", "low": "最低", "close": "收盘", "volume": "成交量", "amount": "成交额"})
            df["日期"] = df["日期"].astype(str).str.replace("-", "", regex=False)
            df = df[(df["日期"] >= start_date) & (df["日期"] <= end_date)]
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
        if self.k_type not in {KL_TYPE.K_DAY, KL_TYPE.K_WEEK, KL_TYPE.K_MON}:
            raise ValueError(f"Tushare 暂不支持 {self.k_type} 级别")
        self.do_init()
        if self.pro is None:
            raise RuntimeError("Tushare Pro 未初始化")
        start_date = (self.begin_date or "1990-01-01").replace("-", "")
        end_date = (self.end_date or "2099-12-31").replace("-", "")
        freq_map = {KL_TYPE.K_DAY: "D", KL_TYPE.K_WEEK: "W", KL_TYPE.K_MON: "M"}
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


class ReplayDataChan(CChan):
    def GetStockAPI(self):
        if self.data_src == AKSHARE_INLINE_SRC:
            return CAkshareInline
        if self.data_src == TUSHARE_INLINE_SRC:
            return CTushareInline
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
    return STRUCTURE_LEVEL_LABELS.get(level, level)


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


def make_rhythm_display_label(round_current: int, round_ref: int) -> str:
    return f"节奏线{round_current}" if round_current == round_ref else f"节奏线{round_current}_{round_ref}"


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
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Build rhythm lines for one parent structure.

    The user-defined term "推进峰值端点" means the endpoint of the child line
    that moves in the same direction as the parent structure:
    - up parent: D / F / H ...
    - down parent: mirrored low endpoints

    For line k_j:
    - j controls which historic retracement ratio is reused
    - k controls which current retracement round is being projected
    - x1 starts from the j-th same-direction peak endpoint
    - x2 ends at the (k+1)-th same-direction peak endpoint
    """
    parent_dir = getattr(parent_line, "dir", None)
    if parent_dir not in (BI_DIR.UP, BI_DIR.DOWN):
        return [], []
    seq = build_alternating_child_sequence(child_lines, parent_dir)
    if len(seq) < 5:
        return [], []

    parent_key = make_line_key(parent_level, parent_line)
    parent_label = rhythm_level_label(parent_level)
    level_label_cn = rhythm_level_label(level)
    a0 = float(parent_line.get_begin_val())
    lines: list[dict[str, Any]] = []
    hits: list[dict[str, Any]] = []
    max_round = max(0, (len(seq) - 3) // 2)

    for round_current in range(1, max_round + 1):
        d_line = seq[2 * round_current]
        next_peak_line = seq[2 * (round_current + 1)]
        d_val = float(d_line.get_end_val())
        threshold: Optional[float] = None
        c_line_for_hit = None
        for round_ref in range(1, round_current + 1):
            b_line = seq[2 * (round_ref - 1)]
            c_line = seq[2 * (round_ref - 1) + 1]
            start_peak_line = seq[2 * round_ref]
            b_val = float(b_line.get_end_val())
            c_val = float(c_line.get_end_val())
            if parent_dir == BI_DIR.UP:
                denom = b_val - a0
                ratio = (b_val - c_val) / denom if abs(denom) > 1e-12 else None
                rhythm_price = d_val - (d_val - a0) * ratio if ratio is not None else None
                threshold = c_val + (b_val - c_val) * 1.382 if ratio is not None else None
            else:
                denom = a0 - b_val
                ratio = (c_val - b_val) / denom if abs(denom) > 1e-12 else None
                rhythm_price = d_val + (a0 - d_val) * ratio if ratio is not None else None
                threshold = c_val - (c_val - b_val) * 1.382 if ratio is not None else None
            if ratio is None or rhythm_price is None or threshold is None:
                continue
            if not (ratio >= 0 and abs(rhythm_price) < float("inf") and abs(threshold) < float("inf")):
                continue
            label_left = str(round_current) if round_current == round_ref else f"{round_current}_{round_ref}"
            label_right = format_rhythm_ratio(ratio)
            color_group = f"rhythm{round_ref}"
            lines.append(
                {
                    "key": f"{parent_key}|line|{round_current}|{round_ref}",
                    "level": level,
                    "parent_level": parent_level,
                    "parent_key": parent_key,
                    "parent_label": parent_label,
                    "display_label": make_rhythm_display_label(round_current, round_ref),
                    "round_current": round_current,
                    "round_ref": round_ref,
                    "color_group": color_group,
                    "dir": "UP" if parent_dir == BI_DIR.UP else "DOWN",
                    "ratio": float(ratio),
                    "label_left": label_left,
                    "label_right": label_right,
                    "x1": line_end_x(start_peak_line),
                    "y1": float(rhythm_price),
                    "x2": line_end_x(next_peak_line),
                    "y2": float(rhythm_price),
                }
            )
            if round_ref == round_current:
                c_line_for_hit = c_line
        if threshold is None or c_line_for_hit is None:
            continue
        for hit in find_1382_hits(klus, start_x=line_end_x(c_line_for_hit), direction=parent_dir, threshold=float(threshold)):
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
            if parent_level in ("seg", "segseg"):
                parent_children = list(getattr(parent_line, "bi_list", []) or child_lines_within_parent(parent_line, source_children))
            else:
                parent_children = child_lines_within_parent(parent_line, source_children)
            lines, hits = build_parent_rhythm_entries(
                level=level,
                parent_level=parent_level,
                parent_line=parent_line,
                child_lines=parent_children,
                klus=klus,
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


def build_level_bsp(base_lines: Any, upper_lines: Any, bsp_conf) -> CBSPointList:
    bsp_list = CBSPointList(bs_point_config=bsp_conf)
    try:
        bsp_list.cal(base_lines, upper_lines)
    except Exception:
        return CBSPointList(bs_point_config=bsp_conf)
    return bsp_list


def build_hidden_seg_layer(source_lines: Any, conf: CChanConfig):
    hidden_seg_list = get_seglist_instance(seg_config=conf.seg_conf, lv=SEG_TYPE.SEG)
    try:
        cal_seg(source_lines, hidden_seg_list, -1)
    except Exception:
        return hidden_seg_list
    return hidden_seg_list


def build_classic_bundle(chan: CChan) -> ChanStructureBundle:
    kl_list = chan[0]
    conf = chan.conf
    segsegseg_list = build_hidden_seg_layer(kl_list.segseg_list, conf)
    fract_list = SimpleLineList()
    rhythm_fract_children = build_new_bi_list(kl_list)
    fractzs_list = empty_zs_list(conf.zs_conf)
    segsegzs_list = build_level_zs(kl_list.segseg_list, segsegseg_list, conf.zs_conf)
    segseg_bs_point_lst = build_level_bsp(kl_list.segseg_list, segsegseg_list, conf.seg_bs_point_conf)
    rhythm_lines, rhythm_hits = build_rhythm_structures(
        kl_list=kl_list,
        fract_children=rhythm_fract_children,
        bi_children=list(kl_list.bi_list),
        seg_children=list(kl_list.seg_list),
        bi_parents=kl_list.bi_list,
        seg_parents=kl_list.seg_list,
        segseg_parents=kl_list.segseg_list,
    )
    return ChanStructureBundle(
        chan_algo=CHAN_ALGO_CLASSIC,
        fract_list=fract_list,
        bi_list=kl_list.bi_list,
        seg_list=kl_list.seg_list,
        segseg_list=kl_list.segseg_list,
        segsegseg_list=segsegseg_list,
        fractzs_list=fractzs_list,
        zs_list=kl_list.zs_list,
        segzs_list=kl_list.segzs_list,
        segsegzs_list=segsegzs_list,
        bs_point_lst=kl_list.bs_point_lst,
        seg_bs_point_lst=kl_list.seg_bs_point_lst,
        segseg_bs_point_lst=segseg_bs_point_lst,
        trend_lines=build_trend_lines_from_bi_list(list(kl_list.bi_list)),
        fx_lines=build_fx_lines(kl_list),
        rhythm_lines=rhythm_lines,
        rhythm_hits=rhythm_hits,
    )


def build_new_bundle(chan: CChan) -> ChanStructureBundle:
    kl_list = chan[0]
    conf = chan.conf
    # 新缠论：分型端点 -> 新K线 -> 分型 -> 笔 -> 段 -> 2段；额外再递推一层隐藏结构支撑 2段 中枢/BSP。
    fract_list = build_new_bi_list(kl_list)
    bi_list = build_new_seg_list(fract_list, "new_chan_bi")
    seg_list = build_new_seg_list(bi_list, "new_chan_seg")
    segseg_list = build_new_seg_list(seg_list, "new_chan_segseg")
    segsegseg_list = build_new_seg_list(segseg_list, "new_chan_hidden_upper")
    fractzs_list = build_level_zs(fract_list, bi_list, conf.zs_conf)
    zs_list = build_level_zs(bi_list, seg_list, conf.zs_conf)
    segzs_list = build_level_zs(seg_list, segseg_list, conf.zs_conf)
    segsegzs_list = build_level_zs(segseg_list, segsegseg_list, conf.zs_conf)
    bs_point_lst = build_level_bsp(bi_list, seg_list, conf.bs_point_conf)
    seg_bs_point_lst = build_level_bsp(seg_list, segseg_list, conf.seg_bs_point_conf)
    segseg_bs_point_lst = build_level_bsp(segseg_list, segsegseg_list, conf.seg_bs_point_conf)
    rhythm_lines, rhythm_hits = build_rhythm_structures(
        kl_list=kl_list,
        fract_children=list(fract_list),
        bi_children=list(bi_list),
        seg_children=list(seg_list),
        bi_parents=bi_list,
        seg_parents=seg_list,
        segseg_parents=segseg_list,
    )
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
    )


def build_structure_bundle(chan: CChan, chan_algo: str) -> ChanStructureBundle:
    algo = normalize_chan_algo(chan_algo)
    return build_new_bundle(chan) if algo == CHAN_ALGO_NEW else build_classic_bundle(chan)


def get_bundle_line_list(bundle: ChanStructureBundle, level: str):
    mapping = {
        "fract": bundle.fract_list,
        "bi": bundle.bi_list,
        "seg": bundle.seg_list,
        "segseg": bundle.segseg_list,
        "segsegseg": bundle.segsegseg_list,
    }
    return mapping[level]


def get_bundle_bsp_list(bundle: ChanStructureBundle, level: str):
    mapping = {
        "bi": bundle.bs_point_lst,
        "seg": bundle.seg_bs_point_lst,
        "segseg": bundle.segseg_bs_point_lst,
    }
    return mapping[level]


def level_label(level: str) -> str:
    return LEVEL_LABELS.get(level, level)


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


