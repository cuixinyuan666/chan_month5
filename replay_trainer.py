import copy
import inspect
import json
import os
import re
import warnings
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta
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
from pydantic import BaseModel

# 尝试导入其他数据源库（缺失时启动阶段给出明确安装提示）
ASHARE_MOD = None  # ashare 或 PyPI 的 ashares，供 get_price 使用
try:
    import ashare as ASHARE_MOD
    HAS_ASHARE = True
except ImportError:
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
PYTDX_INLINE_SRC = "inline:pytdx"
SINA_INLINE_SRC = "inline:sina"
TENCENT_INLINE_SRC = "inline:tencent"
YAHOO_INLINE_SRC = "inline:yahoo"
EASTMONEY_INLINE_SRC = "inline:eastmoney"
AKTX_INLINE_SRC = "inline:aktx"
GITHUB_CSV_INLINE_SRC = "inline:github_csv"
# 本地 a_Data 离线包（分笔优先，否则 1 分钟合成高周期）
OFFLINE_INLINE_SRC = "inline:offline"
# 可配置的数据源优先级（从系统配置读取）
CONFIG_DATA_SRC_PRIORITY: list = []
CONFIG_OHLC_SRC: Any = None  # 开高低收数据源，默认第一个可用
CONFIG_VOL_SRC: Any = None   # 成交量数据源，默认第一个可用

# 默认优先级显示名（与前端 systemConfig.dataSourcePriority 一致）
DEFAULT_DATA_SOURCE_PRIORITY_NAMES: list[str] = [
    "AKShare",
    "AKShare-腾讯历史",
    "Ashare",
    "AData",
    "pytdx",
    "BaoStock",
    "离线数据",
    "Tushare",
    "新浪财经",
    "腾讯财经",
    "雅虎财经",
    "东方财富",
    "GitHub-CSV",
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


def normalize_data_form_mode(raw: Any) -> str:
    mode = str(raw or "traditional").strip().lower()
    return "quantity" if mode == "quantity" else "traditional"


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


def _ensure_klu_deepcopy_attrs(klus: list[Any]) -> None:
    """兼容旧会话/聚合K线：补齐 CKLine_Unit.__deepcopy__ 依赖字段。"""
    for klu in klus:
        # CKLine_Unit.__deepcopy__ 会直接访问 macd/boll，缺失会在重配时报错
        if not hasattr(klu, "macd"):
            klu.macd = None
        if not hasattr(klu, "boll"):
            klu.boll = None


def aggregate_klu_by_quantity(klus: list[Any], quantity: int) -> list[Any]:
    """按数量Q聚合K线：前面等分，余数全部放最后一组。"""
    _ensure_klu_deepcopy_attrs(klus)
    total = len(klus)
    if total == 0:
        return []
    q = normalize_data_form_quantity(quantity, total)
    if q >= total:
        return list(copy.deepcopy(klus))

    base = total // q
    rem = total % q
    out: list[Any] = []
    start = 0
    for i in range(q):
        seg_len = base + (rem if i == q - 1 else 0)
        end = start + seg_len
        chunk = klus[start:end]
        start = end
        if not chunk:
            continue
        first = chunk[0]
        last = chunk[-1]
        high = max(float(getattr(k, "high", 0.0)) for k in chunk)
        low = min(float(getattr(k, "low", 0.0)) for k in chunk)
        volume = sum(float(getattr(k, "volume", getattr(k, "vol", 0.0)) or 0.0) for k in chunk)
        turnover = sum(float(getattr(k, "turnover", 0.0) or 0.0) for k in chunk)
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
    api_cls.do_init()
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
    """sz.001312 -> SZ#001312"""
    c = str(code or "").strip().lower()
    if c.startswith("sh."):
        return "SH#" + c[3:9] if len(c) >= 9 else "SH#" + c[3:]
    if c.startswith("sz."):
        return "SZ#" + c[3:9] if len(c) >= 9 else "SZ#" + c[3:]
    sym = _strip_market_prefix(code)
    if len(sym) == 6 and sym.isdigit():
        return ("SH#" if sym.startswith("6") else "SZ#") + sym
    return "SZ#" + sym


def _offline_date_bounds(begin_date: Optional[str], end_date: Optional[str]) -> tuple[int, int]:
    """返回 YYYYMMDD 整数闭区间，便于与分笔文件名比较。"""
    b = (begin_date or "1990-01-01").replace("/", "-").strip()
    e = (end_date or "2099-12-31").replace("/", "-").strip()
    b8 = int(b[:4] + b[5:7] + b[8:10]) if len(b) >= 10 else 19900101
    e8 = int(e[:4] + e[5:7] + e[8:10]) if len(e) >= 10 else 20991231
    return b8, e8


def offline_bundle_exists(code: str, begin_date: Optional[str], end_date: Optional[str]) -> bool:
    """会话加载前探测：是否有可用离线包（分笔或 1 分钟文件）。"""
    folder = os.path.join(_offline_root_dir(), offline_folder_from_code(code))
    if not os.path.isdir(folder):
        return False
    code6 = _strip_market_prefix(code)
    b8, e8 = _offline_date_bounds(begin_date, end_date)
    tick_dir = os.path.join(folder, "TickData")
    if os.path.isdir(tick_dir):
        pat = re.compile(r"^(\d{8})_" + re.escape(code6) + r"\.txt$", re.I)
        for fn in os.listdir(tick_dir):
            m = pat.match(fn)
            if m:
                d8 = int(m.group(1))
                if b8 <= d8 <= e8:
                    return True
    k1 = os.path.join(folder, "KLine", "1MINUTE", offline_folder_from_code(code) + ".txt")
    return os.path.isfile(k1) and os.path.getsize(k1) > 80


def offline_tick_files_exist_for_range(code: str, begin_date: Optional[str], end_date: Optional[str]) -> bool:
    """指定日期闭区间内是否存在可分笔 TickData 文件（与 offline_bundle_exists 中分笔判定一致）。"""
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


def offline_1m_file_exists(code: str) -> bool:
    """a_Data 下是否存在可用的 1 分钟 K 线文本（无分笔时用于分钟收盘点质量化筹码）。"""
    folder = os.path.join(_offline_root_dir(), offline_folder_from_code(code))
    fn = offline_folder_from_code(code) + ".txt"
    p = os.path.join(folder, "KLine", "1MINUTE", fn)
    return os.path.isfile(p) and os.path.getsize(p) > 80


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
    """与 Offline 合成 K 的分桶一致：分笔或 1 分钟行归入同一根 K。"""
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


def _enrich_kline_all_offline_chip_non_triangle(
    code: str, kline_all: list[dict[str, Any]], end_date: Optional[str], k_type: KL_TYPE
) -> None:
    """
    离线任意支持周期：写入 chip_tick_bins（分笔价量直加；无分笔则用 1 分钟收盘点质量化），前端不走 OHLC 三角分摊。
    """
    from collections import defaultdict

    if k_type not in _offline_chip_supported_ktypes():
        return
    folder = os.path.join(_offline_root_dir(), offline_folder_from_code(code))
    if not kline_all or not os.path.isdir(folder):
        return
    code6 = _strip_market_prefix(code)
    b8, e8 = _offline_date_bounds("1990-01-01", end_date)
    key_to_rows: dict[tuple, list[tuple[float, float]]] = defaultdict(list)

    paths = _offline_list_tick_paths(folder, code6, b8, e8)
    if paths:
        ticks = _offline_load_ticks(paths)
        if not ticks:
            return
        for t, price, vol in ticks:
            try:
                bk = _offline_chip_bar_bucket_key(t, k_type)
            except ValueError:
                continue
            key_to_rows[bk].append((float(price), float(vol)))
    else:
        p1m = os.path.join(folder, "KLine", "1MINUTE", offline_folder_from_code(code) + ".txt")
        if not (os.path.isfile(p1m) and os.path.getsize(p1m) > 80):
            return
        rows_1m = _offline_load_1m_rows(p1m, b8, e8)
        if not rows_1m:
            return
        for r in rows_1m:
            ct = r["t"]
            try:
                bk = _offline_chip_bar_bucket_key(ct, k_type)
            except ValueError:
                continue
            key_to_rows[bk].append((float(r["c"]), float(r["v"])))

    if not key_to_rows:
        return
    key_to_bins: dict[tuple, tuple[list[float], list[float]]] = {}
    for bk, arr in key_to_rows.items():
        ps, ws = _fold_price_vols(arr)
        if ps:
            key_to_bins[bk] = (ps, ws)

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
        bar["chip_tick_bins"] = {"p": tup[0], "w": tup[1]}


def _strip_market_prefix(code: str) -> str:
    text = str(code or "").strip().lower()
    if text.startswith("sh.") or text.startswith("sz."):
        return text.split(".", 1)[1]
    if text.startswith("sh") or text.startswith("sz"):
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
        raise ValueError(f"离线数据暂不支持从 1 分钟合成的周期：{klt}")
    return m[klt]


def _offline_parse_slash_date(s: str) -> tuple[int, int, int]:
    s = s.strip().replace("-", "/")
    a = s.split("/")
    if len(a) < 3:
        raise ValueError(s)
    return int(a[0]), int(a[1]), int(a[2])


def _offline_parse_hhmm(s: str) -> tuple[int, int]:
    s = str(s).strip()
    if ":" in s:
        a, b = s.split(":", 1)
        return int(a), int(b)
    if len(s) == 4 and s.isdigit():
        return int(s[:2]), int(s[2:])
    raise ValueError(s)


def _offline_load_1m_rows(path: str, b8: int, e8: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.rstrip("\n\r")
            if not line.strip():
                continue
            raw = line.replace("\t", " ")
            if "日期" in raw and "时间" in raw:
                continue
            if "分钟线" in raw or re.match(r"^\d{6}\s", raw.strip()):
                continue
            parts = [p for p in line.split("\t") if p != ""]
            if len(parts) < 8:
                parts = re.split(r"\s+", raw.strip())
            if len(parts) < 8:
                continue
            try:
                y, mo, d = _offline_parse_slash_date(parts[0])
                d8 = y * 10000 + mo * 100 + d
                if d8 < b8 or d8 > e8:
                    continue
                hh, mm = _offline_parse_hhmm(parts[1])
                ct = CTime(y, mo, d, hh, mm, auto=False)
                rows.append(
                    {
                        "t": ct,
                        "o": str2float(parts[2]),
                        "h": str2float(parts[3]),
                        "l": str2float(parts[4]),
                        "c": str2float(parts[5]),
                        "v": str2float(parts[6]),
                        "amt": str2float(parts[7]),
                    }
                )
            except (ValueError, TypeError, IndexError):
                continue
    rows.sort(key=lambda r: r["t"].ts)
    return rows


def _offline_list_tick_paths(folder: str, code6: str, b8: int, e8: int) -> list[str]:
    tick_dir = os.path.join(folder, "TickData")
    if not os.path.isdir(tick_dir):
        return []
    pat = re.compile(r"^(\d{8})_" + re.escape(code6) + r"\.txt$", re.I)
    out: list[tuple[int, str]] = []
    for fn in os.listdir(tick_dir):
        m = pat.match(fn)
        if not m:
            continue
        d8 = int(m.group(1))
        if b8 <= d8 <= e8:
            out.append((d8, os.path.join(tick_dir, fn)))
    out.sort(key=lambda x: x[0])
    return [p for _, p in out]


def _offline_load_ticks(paths: list[str]) -> list[tuple[CTime, float, float]]:
    ticks: list[tuple[CTime, float, float]] = []
    for p in paths:
        base = os.path.basename(p)
        d8 = int(base.split("_")[0])
        y, mo, d0 = d8 // 10000, (d8 // 100) % 100, d8 % 100
        with open(p, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = re.split(r"\s+", line)
                if len(parts) < 3:
                    continue
                if parts[0] in ("时间", "---") or parts[0].startswith("时间"):
                    continue
                if not re.match(r"^\d{1,2}:\d{2}$", parts[0]):
                    continue
                a, b = parts[0].split(":", 1)
                hh, mm = int(a), int(b)
                price = str2float(parts[1])
                vol = str2float(parts[2])
                ticks.append((CTime(y, mo, d0, hh, mm, auto=False), price, vol))
    ticks.sort(key=lambda x: x[0].ts)
    return ticks


def _offline_ticks_to_1m(ticks: list[tuple[CTime, float, float]]) -> list[dict[str, Any]]:
    from collections import defaultdict

    buck: dict[tuple[int, int, int, int, int], list[tuple[float, float]]] = defaultdict(list)
    for t, price, vol in ticks:
        key = (t.year, t.month, t.day, t.hour, t.minute)
        buck[key].append((price, vol))
    rows: list[dict[str, Any]] = []
    for key in sorted(buck):
        y, mo, d, hh, mm = key
        arr = buck[key]
        o0 = arr[0][0]
        c0 = arr[-1][0]
        hi = max(x[0] for x in arr)
        lo = min(x[0] for x in arr)
        v0 = sum(x[1] for x in arr)
        amt0 = sum(x[0] * x[1] for x in arr)
        rows.append({"t": CTime(y, mo, d, hh, mm, auto=False), "o": o0, "h": hi, "l": lo, "c": c0, "v": v0, "amt": amt0})
    return rows


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
    """读取 a_Data/{SH|SZ}#代码/ 下分笔或 1 分钟文本，合成任意请求周期。"""

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
        rows_1m: list[dict[str, Any]]
        if tick_paths:
            ticks = _offline_load_ticks(tick_paths)
            if not ticks:
                raise ValueError("分笔文件在日期区间内无有效成交行")
            rows_1m = _offline_ticks_to_1m(ticks)
        else:
            p1m = os.path.join(self._base, "KLine", "1MINUTE", self._folder_name + ".txt")
            if not os.path.isfile(p1m):
                # 离线包以分笔或 1 分钟为基础数据，再合成到目标周期
                raise ValueError(f"未找到离线基础数据文件（1分钟）：{p1m}，当前请求周期：{_k_type_label_cn(self.k_type)}")
            rows_1m = _offline_load_1m_rows(p1m, b8, e8)
            if not rows_1m:
                raise ValueError(f"离线基础数据（1分钟）在指定日期区间为空，当前请求周期：{_k_type_label_cn(self.k_type)}")
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


@dataclass
class PaperAccount:
    initial_cash: float
    cash: float
    position: int = 0
    avg_cost: float = 0.0
    last_buy_step: Optional[int] = None
    last_trade_step: Optional[int] = None

    def reset(self, initial_cash: float) -> None:
        self.initial_cash = initial_cash
        self.cash = initial_cash
        self.position = 0
        self.avg_cost = 0.0
        self.last_buy_step = None
        self.last_trade_step = None

    def buy_with_all_cash(self, price: float, step_idx: int) -> dict[str, Any]:
        if self.position > 0:
            raise ValueError("当前已有持仓，需先卖出全部再买入。")
        if self.last_trade_step == step_idx:
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
        self.last_buy_step = step_idx
        self.last_trade_step = step_idx
        return {"hands": hands, "shares": self.position, "cost": round(cost, 2)}

    def can_sell(self, step_idx: int) -> bool:
        if self.position <= 0:
            return False
        if self.last_buy_step is None:
            return False
        return step_idx >= self.last_buy_step + 1

    def sell_all(self, price: float, step_idx: int) -> dict[str, Any]:
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
        self.last_buy_step = None
        self.last_trade_step = step_idx
        return {
            "shares": shares,
            "proceeds": round(proceeds, 2),
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
        self.data_form_mode: str = "traditional"
        self.data_form_quantity: int = 0
        self.raw_kline_count: int = 0

    def _cfg_without_chan_algo(self, cfg_dict: dict[str, Any]) -> dict[str, Any]:
        # 训练器自用键，勿传入 CChanConfig（否则会触发 unknown para）
        skip = frozenset({"chan_algo"})
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
                api_cls.do_init()
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
            api = api_cls(code=self.code, k_type=self.k_type, begin_date=begin_date, end_date=end_date, autype=autype)
            api.do_init()
            stock_name = getattr(api, "name", None) or None
            api.do_close()
        except Exception:
            stock_name = None

        # 筹码全历史与当前候选 data_src 一致（筹码链独立回退时在循环里换 data_src）
        chip_src = data_src
        chip_begin_date = "1990-01-01"
        try:
            cfg_all = CChanConfig({**chan_cfg_dict, "trigger_step": False})
            chan_all = ReplayDataChan(
                code=self.code,
                begin_time=chip_begin_date,
                end_time=end_date,
                data_src=chip_src,
                lv_list=[self.k_type],
                config=cfg_all,
                autype=autype,
            )
            kline_all = serialize_klu_iter(chan_all[0].klu_iter())
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
    ) -> DataSourceSelection:
        """按优先级链选择数据源；K 线与筹码共用排序逻辑，链独立故可选用不同实际源。"""
        logs: list[str] = []
        errors: list[str] = []
        data_chain = chain_override or (DATA_SOURCE_CHAIN_KLINE if use_for == "kline" else DATA_SOURCE_CHAIN_CHIP)
        for idx, (label, data_src) in enumerate(data_chain):
            print(f"[DataSource] try {label} for {self.code} {begin_date} -> {end_date or 'latest'}")
            try:
                replay_klus_master, kline_all, stock_name = self._fetch_from_single_source(
                    data_src, begin_date, end_date, autype, chan_cfg_dict, use_for=use_for
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
        bundle = build_structure_bundle(target_chan, self.chan_algo)
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
    ) -> None:
        # 解析并设置周期类型
        self.k_type = parse_k_type(k_type)
        
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
            "trigger_step": True,
            "skip_step": 0,
            "kl_data_check": True,
            "print_warning": False,
            "print_err_time": False,
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
                    elif k == "macd" and isinstance(v, dict):
                        macd_dict = cfg_dict.get("macd", {"fast": 12, "slow": 26, "signal": 9}).copy()
                        for mk, mv in v.items():
                            if mv is not None and mv != "":
                                try:
                                    macd_dict[mk] = int(mv)
                                except (ValueError, TypeError):
                                    pass
                        cfg_dict["macd"] = macd_dict
                    elif k in ("data_src_kline", "data_src_chip"):
                        # 旧版前端/会话字段，忽略以免传入 CChanConfig 触发 unknown
                        pass
                    else:
                        cfg_dict[k] = v

        self.chan_algo = normalize_chan_algo(cfg_dict.get("chan_algo"))
        cfg_dict["chan_algo"] = self.chan_algo
        self.effective_cfg_dict = cfg_dict.copy()
        chan_cfg_dict = self._cfg_without_chan_algo(cfg_dict)
        cfg = CChanConfig(chan_cfg_dict)
        self.code = normalize_code(code)
        self.stock_name = None
        chain_override: Optional[list[tuple[str, Any]]] = None
        if data_source_priority:
            chain_override = chains_from_priority([str(x) for x in data_source_priority])
            if not chain_override:
                chain_override = None
        prio_fp = (tuple(data_source_priority) if data_source_priority else (), bool(confirm_offline))
        session_key = (self.code, begin_date, end_date, autype, self.k_type, prio_fp)
        cache_hit = session_key == self._data_session_key and self._replay_klus_master is not None

        if not cache_hit:
            k_sel = self._select_data_source_with_fallback(
                begin_date,
                end_date,
                autype,
                chan_cfg_dict,
                use_for="kline",
                chain_override=chain_override,
                offline_confirm_suppressed=confirm_offline,
            )
            try:
                chip_sel = self._select_data_source_with_fallback(
                    begin_date,
                    end_date,
                    autype,
                    chan_cfg_dict,
                    use_for="chip",
                    chain_override=chain_override,
                    offline_confirm_suppressed=confirm_offline,
                )
            except OfflineDataConfirmRequired:
                raise
            except RuntimeError as exc:
                self._replay_klus_master = k_sel.replay_klus_master
                self._replay_klus_master_raw = copy.deepcopy(k_sel.replay_klus_master)
                self.kline_all = k_sel.kline_all
                self.data_src_used = k_sel.data_src
                self.data_src_chip_used = k_sel.data_src
                self.data_src_logs = list(k_sel.logs) + [f"筹码全历史与K线同源（筹码链不可用：{format_source_error(exc)}）"]
            else:
                self._replay_klus_master = k_sel.replay_klus_master
                self._replay_klus_master_raw = copy.deepcopy(k_sel.replay_klus_master)
                # K 线来自离线包时，筹码全历史必须与 K 线同源；否则易出现「K 为分笔合成日线、筹码却走筹码链上先成功的在线日线」
                if k_sel.data_src == OFFLINE_INLINE_SRC:
                    self.kline_all = k_sel.kline_all
                    self.data_src_chip_used = k_sel.data_src
                    if chip_sel.data_src == OFFLINE_INLINE_SRC:
                        chip_logs_extra = [f"筹码全历史：{chip_sel.label}"] + list(chip_sel.logs)
                    else:
                        chip_logs_extra = [
                            f"筹码全历史与离线K线同源（已忽略筹码链上的在线源：{chip_sel.label}）"
                        ] + list(chip_sel.logs)
                else:
                    self.kline_all = chip_sel.kline_all
                    self.data_src_chip_used = chip_sel.data_src
                    chip_logs_extra = [f"筹码全历史：{chip_sel.label}"] + list(chip_sel.logs)
                self.data_src_used = k_sel.data_src
                self.data_src_logs = list(k_sel.logs) + chip_logs_extra
            self._data_session_key = session_key
            if k_sel.stock_name:
                self.stock_name = k_sel.stock_name
            # 离线 + 支持周期：为 kline_all 写 chip_tick_bins（分笔或 1 分钟收盘点质量化），全周期前端不走三角分摊
            if (
                self.data_src_used == OFFLINE_INLINE_SRC
                and self.kline_all
                and self.k_type in _offline_chip_supported_ktypes()
                and (
                    offline_tick_files_exist_for_range(self.code, "1990-01-01", end_date)
                    or offline_1m_file_exists(self.code)
                )
            ):
                _enrich_kline_all_offline_chip_non_triangle(self.code, self.kline_all, end_date, self.k_type)
        else:
            if self.data_src_logs:
                self.data_src_logs = [
                    "沿用已缓存：K线 "
                    + data_source_label(self.data_src_used)
                    + "，筹码 "
                    + data_source_label(self.data_src_chip_used or self.data_src_used)
                ]

        raw_master = self._replay_klus_master_raw or self._replay_klus_master or []
        self.raw_kline_count = len(raw_master)
        self.data_form_mode = normalize_data_form_mode(data_form_mode)
        self.data_form_quantity = normalize_data_form_quantity(
            data_form_quantity if data_form_quantity is not None else self.raw_kline_count,
            self.raw_kline_count,
        )
        if self.data_form_mode == "quantity" and self.raw_kline_count > 0:
            self._replay_klus_master = aggregate_klu_by_quantity(raw_master, self.data_form_quantity)
        else:
            self._replay_klus_master = copy.deepcopy(raw_master)

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
        self._iter = self.chan.step_load()
        self.step_idx = -1
        self.indicators = {
            "macd": CMACD(),
            "kdj": KDJ(),
            "rsi": RSI(),
            "boll": BollModel(),
            "demark": CDemarkEngine(),
        }
        self.indicator_history = []
        self.trend_lines = []
        self.structure_bundle = None
        self._bundle_cache_step_idx = None

    def step(self) -> bool:
        if self._iter is None:
            raise ValueError("请先初始化会话。")
        try:
            next(self._iter)
            self.step_idx += 1
            self.structure_bundle = None
            self._bundle_cache_step_idx = None
            # Update indicators
            kl_list = self.chan[0]
            latest_klu = kl_list.lst[-1].lst[-1]
            h, l, c = float(latest_klu.high), float(latest_klu.low), float(latest_klu.close)
            
            macd_item = self.indicators["macd"].add(c)
            kdj_item = self.indicators["kdj"].add(h, l, c)
            rsi_val = self.indicators["rsi"].add(c)
            boll_item = self.indicators["boll"].add(c)
            demark_idx = self.indicators["demark"].update(latest_klu.idx, c, h, l)
            
            # Extract current demark points
            demark_pts = []
            for item in demark_idx.data:
                demark_pts.append({
                    "type": item["type"],
                    "dir": "UP" if item["dir"].name == "UP" else "DOWN",
                    "val": item["idx"],
                    "x": item["idx_in_kl"] if "idx_in_kl" in item else latest_klu.idx # Fallback to current
                })

            self.indicator_history.append({
                "x": latest_klu.idx,
                "macd": {"dif": macd_item.DIF, "dea": macd_item.DEA, "macd": macd_item.macd},
                "kdj": {"k": kdj_item.k, "d": kdj_item.d, "j": kdj_item.j},
                "rsi": rsi_val,
                "boll": {"mid": boll_item.MID, "up": boll_item.UP, "down": boll_item.DOWN},
                "demark": demark_pts
            })
            
            # 新缠论/原缠论统一从 bundle 获取趋势线，避免前端与当前笔级别脱节。
            self.get_structure_bundle(force=True)
            return True
        except StopIteration:
            return False

    def current_price(self) -> float:
        if self.chan is None:
            raise ValueError("会话未初始化")
        kl_list = self.chan[0]
        if len(kl_list.lst) == 0:
            raise ValueError("当前无K线数据")
        return kl_list.lst[-1].lst[-1].close

    def current_time(self) -> str:
        if self.chan is None:
            return "-"
        kl_list = self.chan[0]
        if len(kl_list.lst) == 0:
            return "-"
        return kl_list.lst[-1].lst[-1].time.to_str()


class InitReq(BaseModel):
    code: str
    begin_date: str
    end_date: Optional[str] = None
    initial_cash: float = 10_000
    autype: str = "qfq"
    chan_config: Optional[dict[str, Any]] = None
    k_type: str = "daily"  # 周期类型
    chart_mode: str = "single"  # single | dual
    k_type_2: Optional[str] = None  # 双周期下第二周期
    active_chart_id: str = "chart1"  # chart1 | chart2
    # 用户确认使用离线源后二次 init 传 True；单次 init 可传 data_source_priority 覆盖链（不改服务端全局）
    confirm_offline: bool = False
    data_source_priority: Optional[list[str]] = None
    data_form_mode: str = "traditional"
    data_form_quantity: Optional[int] = None


class ReconfigReq(BaseModel):
    chan_config: dict[str, Any]
    data_form_mode: Optional[str] = None
    data_form_quantity: Optional[int] = None


class BackNReq(BaseModel):
    n: int = 1


class StepReq(BaseModel):
    judge_mode: Optional[str] = None  # "auto" | "manual"
    active_chart_id: Optional[str] = None


class JudgeBspReq(BaseModel):
    reason: str = "manual_check"


class AppState:
    def __init__(self) -> None:
        self.stepper = ChanStepper()
        self.stepper2: Optional[ChanStepper] = None
        self.chart_mode: str = "single"
        self.active_chart_id: str = "chart1"
        self.account = PaperAccount(initial_cash=10_000, cash=10_000)
        self.ready = False
        self.finished = False
        self.session_params: Optional[dict[str, Any]] = None
        self.trade_events: list[dict[str, Any]] = []
        self.bsp_history: list[dict[str, Any]] = []
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

    def _sync_stepper_to_anchor(self, stepper: ChanStepper, anchor_time: str) -> None:
        """将目标周期步进到 anchor_time（包含优先，兜底左侧最近）。"""
        t_anchor = self._parse_time_safe(anchor_time)
        if t_anchor is None:
            return
        if stepper.chan is None:
            return
        # 已到末尾直接返回
        prev_step = int(stepper.step_idx)
        while True:
            cur_t = self._parse_time_safe(stepper.current_time())
            if cur_t is None:
                break
            # 当前已在锚点右侧时，不再前进，保留左侧最近
            if cur_t >= t_anchor:
                break
            if not stepper.step():
                break
        if int(stepper.step_idx) != prev_step:
            # 同步被动周期时重建结构缓存
            stepper.structure_bundle = None
            stepper._bundle_cache_step_idx = None

    def _apply_partial_last_bar(self, big_chart: dict[str, Any], small_chart: dict[str, Any], anchor_time: str) -> None:
        """防未来数据：用小周期截至锚点的数据重算大周期最后一根OHLCV。"""
        big_ks = big_chart.get("kline") if isinstance(big_chart, dict) else None
        small_ks = small_chart.get("kline") if isinstance(small_chart, dict) else None
        if not isinstance(big_ks, list) or not isinstance(small_ks, list) or len(big_ks) <= 0 or len(small_ks) <= 0:
            return
        t_anchor = self._parse_time_safe(anchor_time)
        if t_anchor is None:
            return
        last_big = big_ks[-1]
        prev_big = big_ks[-2] if len(big_ks) >= 2 else None
        t_prev = self._parse_time_safe(prev_big.get("t")) if isinstance(prev_big, dict) else None
        picked: list[dict[str, Any]] = []
        for bar in small_ks:
            t = self._parse_time_safe(str(bar.get("t", "")))
            if t is None:
                continue
            if t > t_anchor:
                continue
            if t_prev is not None and t <= t_prev:
                continue
            picked.append(bar)
        if not picked:
            return
        try:
            o = float(picked[0]["o"])
            h = max(float(x["h"]) for x in picked)
            l = min(float(x["l"]) for x in picked)
            c = float(picked[-1]["c"])
            v = sum(float(x.get("v", 0.0) or 0.0) for x in picked)
        except Exception:
            return
        last_big["o"] = o
        last_big["h"] = h
        last_big["l"] = l
        last_big["c"] = c
        last_big["v"] = v

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
        if self.stepper.chan is None:
            return None
        bundle = self.stepper.get_structure_bundle()
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
        bundle = build_structure_bundle(chan_all, self.stepper.chan_algo)
        snapshot: list[dict[str, Any]] = []
        for level in VISIBLE_BSP_LEVELS:
            bsp_list = get_bundle_bsp_list(bundle, level)
            for bsp in bsp_list.bsp_iter():
                item = make_bsp_item(level, bsp)
                item["key"] = self._bsp_key(item)
                snapshot.append(item)
        self.bsp_all_snapshot = sorted(
            snapshot,
            key=lambda item: (int(item.get("x", -1)), LEVEL_ORDER.get(str(item.get("level")), 999), int(not bool(item.get("is_buy")))),
        )

    def _judge_bsp_against_all(self, *, reason: str, levels: Optional[list[str]] = None) -> None:
        """在当前步进位置，对照（全量预计算）与（步进触发快照）进行 ×/✓ 判定。"""
        current_x = self._current_kline_x()
        if current_x is None:
            return
        if not self.bsp_all_snapshot:
            return
        active_levels = [level for level in (levels or list(VISIBLE_BSP_LEVELS)) if level in VISIBLE_BSP_LEVELS]
        if not active_levels:
            return
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
        cur_time = self.stepper.current_time() if self.stepper.chan is not None else "-"
        interval = {
            "from_x": self._last_judge_x,
            "to_x": int(current_x),
            "from_time": self._last_judge_time or "-",
            "to_time": cur_time,
        }
        stats = {
            "step_idx": int(self.stepper.step_idx),
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
        for level in VISIBLE_BSP_LEVELS:
            trigger_level = JUDGE_TRIGGER_LEVELS[level]
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
        if stepper.chan is None:
            return None
        kl_list = stepper.chan[0]
        if len(kl_list.lst) == 0:
            return None
        return int(kl_list.lst[-1].lst[-1].idx)

    def _build_trade_state(self) -> dict[str, Any]:
        history: list[dict[str, Any]] = []
        active: Optional[dict[str, Any]] = None
        for event in self.trade_events:
            if event.get("side") == "buy":
                active = {
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
        return {"history": history, "active": active}

    def _current_bsp_snapshot(self) -> list[dict[str, Any]]:
        stepper = self.get_active_stepper()
        if stepper.chan is None:
            return []
        bundle = stepper.get_structure_bundle()
        snapshot: list[dict[str, Any]] = []
        for level in VISIBLE_BSP_LEVELS:
            bsp_list = get_bundle_bsp_list(bundle, level)
            for bsp in bsp_list.bsp_iter():
                snapshot.append(make_bsp_item(level, bsp))
        return sorted(snapshot, key=lambda item: (int(item["x"]), LEVEL_ORDER.get(item["level"], 999), int(not bool(item["is_buy"]))))

    @staticmethod
    def _bsp_key(item: dict[str, Any]) -> str:
        return f'{item["level"]}|{int(item["x"])}|{item["label"]}|{1 if item["is_buy"] else 0}'

    def sync_bsp_history(self) -> None:
        """同步当前步进下的买卖点历史。

        注意：×/✓ 判定不在这里做，而是在“上一级结构变向”时对照全量快照进行。
        """
        current_x = self._current_kline_x()
        if current_x is None:
            self.bsp_history = []
            return

        snapshot = self._current_bsp_snapshot()

        existing_keys = {str(item.get("key")) for item in self.bsp_history}
        for item in snapshot:
            if int(item["x"]) != current_x:
                continue
            key = self._bsp_key(item)
            if key in existing_keys:
                continue
            self.bsp_history.append(
                {
                    "key": key,
                    "x": int(item["x"]),
                    "is_buy": bool(item["is_buy"]),
                    "label": item["label"],
                    "level": item["level"],
                    "level_label": item["level_label"],
                    "display_label": item["display_label"],
                    "status": None,
                }
            )
            existing_keys.add(key)

    def sync_rhythm_history(self) -> None:
        current_x = self._current_kline_x()
        self._rhythm_notice_hits = []
        stepper = self.get_active_stepper()
        if current_x is None or stepper.chan is None:
            return
        bundle = stepper.get_structure_bundle()
        for item in bundle.rhythm_hits:
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

    def rebuild_to_step(self, target_step: int) -> None:
        if self.session_params is None:
            raise ValueError("当前无可重建会话")
        params = self.session_params

        # 必须与首次 /api/init 传入的 data_source_priority、confirm_offline 一致，
        # 否则 session_key 中 prio_fp 变化会导致误判缓存未命中，重新拉行情并在 BaoStock 等源上失败。
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
        )
        if str(params.get("chart_mode", "single")).lower() == "dual":
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
            )
        else:
            self.chart_mode = "single"
            self.stepper2 = None

        # Account reset is handled by the caller if needed (e.g. in reconfig)
        # but for back_n it should stay consistent with history.
        # However, rebuild_to_step is also used by back_n which needs to replay trades.
        self.ready = True
        self.finished = False
        self.bsp_history = []
        self._reset_rhythm_history()
        self._last_level_dirs = {level: None for level in set(JUDGE_TRIGGER_LEVELS.values())}
        self._reset_judge_state()
        self.rebuild_bsp_all_snapshot()

        if not self.stepper.step():
            return
        if self.chart_mode == "dual" and self.stepper2 is not None:
            self.stepper2.step()
            self._sync_stepper_to_anchor(self.stepper2, self.stepper.current_time())
        self.sync_bsp_history()
        self.sync_rhythm_history()
        self.after_step_update()
        for _ in range(target_step):
            if not self.stepper.step():
                break
            if self.chart_mode == "dual" and self.stepper2 is not None:
                self._sync_stepper_to_anchor(self.stepper2, self.stepper.current_time())
            self.sync_bsp_history()
            self.sync_rhythm_history()
            self.after_step_update()

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
            except Exception:
                # Replay might fail if parameters changed drastically, but we try our best
                pass

    def reconfig(
        self,
        chan_config: dict[str, Any],
        *,
        data_form_mode: Optional[str] = None,
        data_form_quantity: Optional[int] = None,
    ) -> None:
        if self.session_params is None:
            raise ValueError("当前无可重配会话")
        
        # 1. Update session params
        self.session_params["chan_config"] = chan_config
        if data_form_mode is not None:
            self.session_params["data_form_mode"] = normalize_data_form_mode(data_form_mode)
        if data_form_quantity is not None:
            self.session_params["data_form_quantity"] = int(data_form_quantity)
        
        # 2. Clear simulation data (trades and account)
        self.trade_events = []
        self.account.reset(self.session_params["initial_cash"])
        
        # 3. Rebuild to current step
        target_step = self.stepper.step_idx
        self.rebuild_to_step(target_step)

    def build_payload(self, stock_name: Optional[str] = None, *, include_kline_all: bool = True) -> dict[str, Any]:
        if not self.ready or self.stepper.chan is None:
            return {
                "ready": False,
                "finished": self.finished,
                "message": "请先加载会话",
            }
        rhythm_notice_hits = list(self._rhythm_notice_hits)
        self._rhythm_notice_hits = []

        def _build_chart_payload(stepper: ChanStepper) -> dict[str, Any]:
            bundle = stepper.get_structure_bundle()
            return serialize_chan(
                stepper.chan,
                stepper.indicator_history,
                stepper.trend_lines,
                chan_algo=stepper.chan_algo,
                bundle=bundle,
                kline_all=(stepper.kline_all if include_kline_all else None),
            )

        chart = _build_chart_payload(self.stepper)
        chart2: Optional[dict[str, Any]] = None
        if self.chart_mode == "dual" and self.stepper2 is not None and self.stepper2.chan is not None:
            chart2 = _build_chart_payload(self.stepper2)

        active_stepper = self.get_active_stepper()
        anchor_time = active_stepper.current_time()
        if chart2 is not None:
            k1 = len(chart.get("kline", []))
            k2 = len(chart2.get("kline", []))
            # 数量模式或不同周期下，K线更少视作大周期，末根按锚点裁剪避免未来数据
            if k1 > 0 and k2 > 0 and k1 != k2:
                if k1 < k2:
                    self._apply_partial_last_bar(chart, chart2, anchor_time)
                else:
                    self._apply_partial_last_bar(chart2, chart, anchor_time)
        price: Optional[float] = None
        active_chart = chart2 if (self._normalize_chart_id(self.active_chart_id) == "chart2" and chart2 is not None) else chart
        if len(active_chart.get("kline", [])) > 0:
            price = active_stepper.current_price()
        charts_payload = {"chart1": chart}
        if chart2 is not None:
            charts_payload["chart2"] = chart2
        return {
            "ready": True,
            "finished": self.finished,
            "code": self.stepper.code,
            "name": stock_name,
            "data_source": {
                "label": data_source_label(self.stepper.data_src_used),
                "chip_label": data_source_label(getattr(self.stepper, "data_src_chip_used", None) or self.stepper.data_src_used),
                "logs": list(self.stepper.data_src_logs),
            },
            "chan_algo": self.stepper.chan_algo,
            "step_idx": active_stepper.step_idx,
            "time": active_stepper.current_time(),
            "price": price,
            "chart": chart,
            "charts": charts_payload,
            "chart_mode": self.chart_mode,
            "active_chart_id": self._normalize_chart_id(self.active_chart_id),
            "time_anchor": anchor_time,
            "data_form": {
                "mode": self.stepper.data_form_mode,
                "quantity": int(self.stepper.data_form_quantity or 0),
                "raw_count": int(self.stepper.raw_kline_count or 0),
                "current_count": int(len(active_chart.get("kline", []))),
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
                "can_sell": bool(price is not None and self.account.can_sell(self.stepper.step_idx)),
            },
            "trades": self._build_trade_state(),
        }


def serialize_klu_iter(klu_iter) -> list[dict[str, Any]]:
    arr: list[dict[str, Any]] = []
    for klu in klu_iter:
        arr.append(
            {
                "x": klu.idx,
                "t": klu.time.to_str(),
                "o": float(klu.open),
                "h": float(klu.high),
                "l": float(klu.low),
                "c": float(klu.close),
                "v": float(getattr(klu, "volume", getattr(klu, "vol", 0.0)) or 0.0),
            }
        )
    return arr


def serialize_kline_combine(kl_list) -> list[dict[str, Any]]:
    """序列化合并K线线框，供前端独立绘制。"""
    bars = build_combined_newk_bars(list(kl_list.lst))
    out: list[dict[str, Any]] = []
    for bar in bars:
        if len(bar.elements) == 0:
            continue
        first = bar.elements[0]
        last = bar.elements[-1]
        out.append(
            {
                "x1": int(first.begin_x),
                "x2": int(last.end_x),
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
) -> dict[str, Any]:
    """kline_all 为 None 时不写入 chart（与空列表不同：空列表表示确实无全量数据）。"""
    kl_list = chan[0]
    klu_arr = serialize_klu_iter(kl_list.klu_iter())
    active_bundle = bundle or build_structure_bundle(chan, chan_algo)
    fract_arr = serialize_line_collection(active_bundle.fract_list)
    bi_arr = serialize_line_collection(active_bundle.bi_list)
    seg_arr = serialize_line_collection(active_bundle.seg_list)
    segseg_arr = serialize_line_collection(active_bundle.segseg_list)
    fract_zs_arr = serialize_zs_collection(active_bundle.fractzs_list)
    bi_zs_arr = serialize_zs_collection(active_bundle.zs_list)
    seg_zs_arr = serialize_zs_collection(active_bundle.segzs_list)
    segseg_zs_arr = serialize_zs_collection(active_bundle.segsegzs_list)
    kline_combine_arr = serialize_kline_combine(kl_list)
    bsp_bi_arr = serialize_bsp_collection("bi", active_bundle.bs_point_lst)
    bsp_seg_arr = serialize_bsp_collection("seg", active_bundle.seg_bs_point_lst)
    bsp_segseg_arr = serialize_bsp_collection("segseg", active_bundle.segseg_bs_point_lst)
    bsp_arr = sorted(
        [*bsp_bi_arr, *bsp_seg_arr, *bsp_segseg_arr],
        key=lambda item: (int(item["x"]), LEVEL_ORDER.get(str(item["level"]), 999), int(not bool(item["is_buy"]))),
    )

    out: dict[str, Any] = {
        "kline": klu_arr,
        "fract": fract_arr,
        "bi": bi_arr,
        "seg": seg_arr,
        "segseg": segseg_arr,
        "fract_zs": fract_zs_arr,
        "bi_zs": bi_zs_arr,
        "seg_zs": seg_zs_arr,
        "segseg_zs": segseg_zs_arr,
        "bsp": bsp_arr,
        "bsp_bi": bsp_bi_arr,
        "bsp_seg": bsp_seg_arr,
        "bsp_segseg": bsp_segseg_arr,
        "rhythm_lines": active_bundle.rhythm_lines,
        "rhythm_hits": active_bundle.rhythm_hits,
        "fx_lines": active_bundle.fx_lines,
        "indicators": indicator_history,
        "trend_lines": active_bundle.trend_lines if active_bundle.trend_lines else trend_lines,
        "kline_combine": kline_combine_arr,
    }
    # None 表示「不下发」以减小步进等接口的 JSON；[] 仍表示真实空列表。
    if kline_all is not None:
        out["kline_all"] = kline_all
    return out


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
    .left { width: 360px; padding: 12px; border-right: none; border-left: 1px solid var(--border); box-sizing: border-box; overflow: hidden; background: var(--panel); position: relative; }
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
    .left.compact .title { margin-bottom: 8px; font-size: 15px; }
    .left.compact .sourceStatus { margin-bottom: 8px; font-size: 11px; }
    .left.compact .chartToolsPanel,
    .left.compact .card { padding: 10px; margin-bottom: 10px; }
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
      background: rgba(2, 6, 23, 0.6); z-index: 10006;
    }
    .msgHistoryModal.show { display: flex; }
    .msgHistoryModal .panel {
      width: 600px; max-height: 80vh; background: var(--panel); padding: 20px; border-radius: 12px;
      display: flex; flex-direction: column;
    }
    .msgHistoryList {
      flex: 1; overflow-y: auto; border: 1px solid var(--border); margin: 10px 0; padding: 10px;
      font-family: Consolas, monospace; font-size: 13px;
    }
    .msgHistoryItem { border-bottom: 1px dashed var(--grid); padding: 6px 0; }
    .msgHistoryItem .time { color: #2563eb; margin-right: 10px; }
    
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
    }
    .globalLoading.show { display: flex; }
    .globalLoading .panel {
      min-width: 260px;
      padding: 18px 20px;
      border-radius: 10px;
      border: 1px solid var(--legendBorder);
      background: var(--legendBg);
      color: var(--legendText);
      box-shadow: 0 14px 36px rgba(2, 6, 23, 0.26);
      display: flex;
      align-items: center;
      gap: 12px;
      font: 14px Consolas, monospace;
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
  </style>

</head>
<body>
  <div class="wrap">
    <div class="left">
      <div class="title">chan.py 复盘训练器 <span class="tip-icon" data-tip="Chan.py 缠论复盘交易系统"></span></div>
      <div id="dataSourceStatus" class="sourceStatus mono">当前数据源：未加载</div>
      <div id="leftContent" class="leftContent">
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
          <button id="toolLineProps" type="button" data-tip="先使用“选择”并点击某条画线，再点此按钮编辑粗细/颜色/线型。">画线属性</button>
        </div>
      </div>
      <div class="card" id="configCard">
        <div class="btnRow">
          <button id="btnChanSettingsOpen" data-tip="打开缠论逻辑配置面板，可调整笔、线段、中枢等算法。">缠论配置... <small>(L)</small></button>
          <button id="btnSettingsOpen" data-tip="打开图表显示设置面板，可调整主题、指标与绘制项。">图表显示设置... <small>(P)</small></button>
          <button id="btnSystemSettingsOpen" data-tip="打开系统配置面板，可统一维护快捷键。">系统配置... <small>(Shift+P)</small></button>
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
        <div class="row cfg-editable">
          <label>K线图模式</label>
          <select id="chartMode">
            <option value="single" selected>单品种单周期图</option>
            <option value="dual">单品种两周期图</option>
          </select>
          <span class="tip-icon" data-tip="单周期=原模式；两周期=上下两个周期联动分析。"></span>
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
        <div class="row cfg-editable" id="dualLayoutRow" style="display:none;">
          <label>排列方式</label>
          <select id="dualLayout">
            <option value="vertical" selected>上下</option>
            <option value="horizontal">左右</option>
          </select>
          <span class="tip-icon" data-tip="双周期模式下两张主图的排列方式：上下或左右。"></span>
        </div>
        <div class="row cfg-editable">
          <label>周期类型</label>
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
          <span class="tip-icon" data-tip="选择K线周期类型，不同数据源支持不同周期。"></span>
        </div>
        <div class="btnRow">
          <button id="btnInit" data-tip="根据当前代码、日期区间、初始资金加载复盘会话。首次加载历史数据可能较慢。">加载会话 <small>(Ctrl+I)</small></button>
          <button id="btnReset" data-tip="清空当前会话并恢复到可重新配置的初始状态。">重新训练 <small>(Ctrl+R)</small></button>
          <button id="btnFinish" data-tip="结束当前训练，并可选择导出本次交易总结文件。" disabled>结束训练</button>
          <button id="btnExit" data-tip="尝试关闭当前页面。浏览器可能会拦截关闭操作。">退出</button>
          <button id="btnStep" data-tip="步进到下一根K线。若当前K线命中买卖点或 1382 提示，会合并为一个弹窗提示。" disabled>下一根K线 <small>(Space)</small></button>
        </div>
        <div class="stepNRow">
          <label for="stepN">步进数量 N</label>
          <span id="tipStepN" class="tip-icon" data-tip="设置连续步进或回退时使用的根数。遇到买卖点将以弹窗提示（自动消失）。"></span>
          <input id="stepN" type="number" min="1" step="1" value="5" />
          <div class="btnRow" style="width:100%; margin-top:4px;">
            <button id="btnStepN" data-tip="按步进数量 N 连续推进，若中途遇到买卖点则自动停止。" disabled>步进 N 根 <small>(Ctrl+Alt+N)</small></button>
            <button id="btnBackN" data-tip="按步进数量 N 回退，会自动重建到更早的状态。" disabled>后退 N 根 <small>(Ctrl+Alt+M)</small></button>
          </div>
        </div>
        <div class="row" style="margin:6px 0 4px 0;">
          <span class="muted">交易规则</span>
          <span class="tip-icon" data-tip="规则：单持仓、T+1、每步最多一笔。"></span>
        </div>
        <div class="btnRow" style="margin-top:6px;">
          <button id="btnBuy" data-tip="按当前收盘价使用全部可用现金买入，遵循单持仓和每步最多一笔规则。" disabled>买入（全仓） <small>(PageUp)</small></button>
          <button id="btnSell" data-tip="按当前收盘价全部卖出，若受 T+1 约束则按钮不可用。" disabled>卖出（全量） <small>(PageDown)</small></button>
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
            <button id="btnMsgHistoryClear">清空记录</button>
            <button id="btnMsgHistoryOk">确 认</button>
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
          <div class="spinner"></div>
          <div id="globalLoadingText">正在加载数据...</div>
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
let allXMin = 0;
let allXMax = 0;
let viewXMin = 0;
let viewXMax = 0;
let viewReady = false;
let userAdjustedView = false;
let userRays = ensureArray(safeJsonParse(storageGet("chan_user_rays"), []), []);
let userBiRays = ensureArray(safeJsonParse(storageGet("chan_user_bi_rays"), []), []);
let userBiRaysDirty = false;
let pendingBiRayPts = [];
let activeTool = storageGet("chan_active_tool") || "none"; // none | horizontalRay | biRay
let selectedDrawing = null; // { type: "ray"|"biRay", index: number }
let chartClickMoved = false;
let chartMouseDownPos = null;

const PAD_L = 64;
const PAD_R = 64;
const PAD_T = 10;
const PAD_B = 90;
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
let canvasHovered = false;
let signalHoverBoxes = [];
let legendHoverBox = null;
let legendHoverActive = false;
function getSessionDualLayout() {
  const raw = ($("dualLayout") && $("dualLayout").value) || (sessionConfig && sessionConfig.dualLayout) || "vertical";
  return raw === "horizontal" ? "horizontal" : "vertical";
}

function getDualPaneRects() {
  const w = Math.max(1, canvas.clientWidth);
  const h = Math.max(1, canvas.clientHeight);
  const gap = 10;
  if (getSessionDualLayout() === "horizontal") {
    const half = Math.floor((w - gap) / 2);
    return {
      chart1: { x: 0, y: 0, w: half, h },
      chart2: { x: half + gap, y: 0, w: Math.max(1, w - half - gap), h },
    };
  }
  const half = Math.floor((h - gap) / 2);
  return {
    chart1: { x: 0, y: 0, w, h: half },
    chart2: { x: 0, y: half + gap, w, h: Math.max(1, h - half - gap) },
  };
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
let selectedSubIndicatorSlot = Number(storageGet("chan_selected_sub_indicator_slot") || "0");
let indicatorMainSlots = ensureObject(safeJsonParse(storageGet("chan_indicator_main_slots"), null), null);
let indicatorSubSlots = ensureObject(safeJsonParse(storageGet("chan_indicator_sub_slots"), null), null);

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
const MAIN_INDICATORS = new Set(["boll", "demark", "trendline"]);
const SUB_INDICATORS = new Set(["macd", "kdj", "rsi"]);

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
  mean_metrics: "",
  trend_metrics: "",
  macd: { fast: 12, slow: 26, signal: 9 },
  cal_demark: false,
  cal_rsi: false,
  cal_kdj: false,
  rsi_cycle: 14,
  kdj_cycle: 9,
  boll_n: 20,
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
  crosshair: { width: 5, color: "#000000", fontSize: 16 },
  fx: { width: 1.1, color: "#06b6d4", dashed: true },
  fract: { widthSure: 2.2, widthUnsure: 1.6, color: "#d97706" },
  bi: { widthSure: 3.1, widthUnsure: 2.2, color: "#f59e0b" },
  seg: { widthSure: 4.8, widthUnsure: 3.5, color: "#059669" },
  segseg: { widthSure: 6.0, widthUnsure: 4.6, color: "#2563eb" },
  fractZs: { width: 1.4, color: "#b45309", enabled: true },
  biZs: { width: 1.8, color: "#f59e0b", enabled: true },
  segZs: { width: 2.4, color: "#059669", enabled: true },
  segsegZs: { width: 2.8, color: "#2563eb", enabled: true },
  candle: { width: 1.4, upColor: "#ef4444", downColor: "#22c55e" },
  bspBi: { fontSize: 14, lineColor: "#94a3b8", lineWidth: 1, lineStyle: "dashed", lineDash: [5, 4] },
  bspSeg: { fontSize: 14, lineColor: "#64748b", lineWidth: 1.1, lineStyle: "dashed", lineDash: [5, 4] },
  bspSegseg: { fontSize: 14, lineColor: "#475569", lineWidth: 1.2, lineStyle: "dashed", lineDash: [5, 4] },
  rhythmLine: {
    enabled: true,
    fractToBiEnabled: true,
    biToSegEnabled: true,
    segToSegsegEnabled: true,
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
  toast: { fontSize: 16, fontWeight: "bold", speed: 3000, showBsp: true, showRhythm1382: true, showJudge: true },
  legend: { fontSize: 12, fontWeight: "normal", color: "#0f172a" },
  userRay: { color: "#f97316", width: 1.5, dash: [8, 4], fontSize: 12 }
};

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
  if (!next.rhythmLine) next.rhythmLine = {};
  if (!next.rhythmHit) next.rhythmHit = {};
  if (!next.xAxis) next.xAxis = {};
  if (!next.yAxis) next.yAxis = {};
  if (!next.klineCombineFrame) next.klineCombineFrame = {};
  if (!next.toast) next.toast = {};
  if (typeof next.toast.showBsp !== "boolean") next.toast.showBsp = true;
  if (typeof next.toast.showRhythm1382 !== "boolean") next.toast.showRhythm1382 = true;
  if (typeof next.toast.showJudge !== "boolean") next.toast.showJudge = true;
  return next;
}

let savedChartConfig = ensureObject(safeJsonParse(storageGet("chan_chart_config"), {}), {});
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
      },
      perChart: {
        chart1: migratedSingle,
        chart2: deepMerge(JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG)), migrateChartConfig(raw)),
      },
    };
  }
  const shared = ensureObject(raw.shared, {});
  const perChart = ensureObject(raw.perChart, {});
  return {
    shared: {
      mode: String(shared.mode || "single"),
      theme: String(shared.theme || "light"),
      crosshair: deepMerge(JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG.crosshair)), ensureObject(shared.crosshair, {})),
    },
    perChart: {
      chart1: deepMerge(JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG)), migrateChartConfig(ensureObject(perChart.chart1, {}))),
      chart2: deepMerge(JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG)), migrateChartConfig(ensureObject(perChart.chart2, {}))),
    },
  };
}
let chartConfigStore = buildChartConfigStore(savedChartConfig);
let chartConfig = chartConfigStore.perChart.chart1;
const DATA_FORM_DEFAULT = { mode: "traditional", quantity: 1 };
let dataFormConfig = { ...DATA_FORM_DEFAULT };

function normalizeDataFormMode(mode) {
  return String(mode || "traditional").toLowerCase() === "quantity" ? "quantity" : "traditional";
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
  kType2: "weekly",
  dualLayout: "vertical",
  activeChartId: "chart1"
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
  { id: "nextBar", label: "步进到下一根K线", description: "步进到下一根 K 线；若当前 K 线命中买卖点或 1382，会合并为一个弹窗提示。", defaults: ["space"], contexts: ["global"], buttonId: "btnStep" },
  { id: "stepForwardN", label: "步进 N 根", description: "按步进数量 N 连续推进，遇到买卖点自动停止，并合并当根提示。", defaults: ["ctrl+alt+n"], contexts: ["global"], buttonId: "btnStepN" },
  { id: "stepBackwardN", label: "后退 N 根", description: "按步进数量 N 回退，会自动重建到更早状态。", defaults: ["ctrl+alt+m"], contexts: ["global"], buttonId: "btnBackN" },
  { id: "buyAll", label: "买入（全仓）", description: "按当前收盘价使用全部可用现金买入。", defaults: ["pageup"], contexts: ["global"], buttonId: "btnBuy" },
  { id: "sellAll", label: "卖出（全量）", description: "按当前收盘价全部卖出。", defaults: ["pagedown"], contexts: ["global"], buttonId: "btnSell" },
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
  // K 线与筹码共用一套优先级顺序（服务端两套链独立按序回退）
  dataSourcePriority: ["AKShare", "Ashare", "AData", "pytdx", "BaoStock", "离线数据", "Tushare", "新浪财经", "腾讯财经", "雅虎财经", "东方财富"],
};

let systemConfig = ensureObject(
  safeJsonParse(storageGet("chan_system_config"), JSON.parse(JSON.stringify(DEFAULT_SYSTEM_CONFIG))),
  JSON.parse(JSON.stringify(DEFAULT_SYSTEM_CONFIG))
);

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
  setButtonShortcutLabel($("btnStep"), "下一根K线", "nextBar");
  setButtonShortcutLabel($("btnStepN"), "步进 N 根", "stepForwardN");
  setButtonShortcutLabel($("btnBackN"), "后退 N 根", "stepBackwardN");
  setButtonShortcutLabel($("btnBuy"), "买入（全仓）", "buyAll");
  setButtonShortcutLabel($("btnSell"), "卖出（全量）", "sellAll");
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
  $("btnStep").setAttribute("data-tip", `步进到下一根K线。若当前K线命中买卖点或 1382 提示，会合并为一个弹窗提示。快捷键：${getActionShortcutDisplay("nextBar") || "未设置"}。`);
  $("btnStepN").setAttribute("data-tip", `按步进数量 N 连续推进，若中途遇到买卖点则自动停止。快捷键：${getActionShortcutDisplay("stepForwardN") || "未设置"}。`);
  $("btnBackN").setAttribute("data-tip", `按步进数量 N 回退，会自动重建到更早的状态。快捷键：${getActionShortcutDisplay("stepBackwardN") || "未设置"}。`);
  $("btnBuy").setAttribute("data-tip", `按当前收盘价使用全部可用现金买入，遵循单持仓和每步最多一笔规则。快捷键：${getActionShortcutDisplay("buyAll") || "未设置"}。`);
  $("btnSell").setAttribute("data-tip", `按当前收盘价全部卖出，若受 T+1 约束则按钮不可用。快捷键：${getActionShortcutDisplay("sellAll") || "未设置"}。`);
  $("tipStepN").setAttribute("data-tip", `设置连续步进或回退时使用的根数。步进快捷键：${getActionShortcutDisplay("stepForwardN") || "未设置"}；回退快捷键：${getActionShortcutDisplay("stepBackwardN") || "未设置"}。`);
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

function saveSessionConfig() {
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
    kType2: $("kType2") ? $("kType2").value : $("kType").value,
    dualLayout: $("dualLayout") ? $("dualLayout").value : "vertical",
    activeChartId: String(lastPayload && lastPayload.active_chart_id ? lastPayload.active_chart_id : "chart1")
  };
  storageSet("chan_session_config", JSON.stringify(sessionConfig));
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
    // No longer setting DOM for chip/biZs/segZs here as they are in chartConfig
    if (sessionConfig.stepN !== undefined) $("stepN").value = sessionConfig.stepN;
    if ($("kType2Row")) $("kType2Row").style.display = ($("chartMode") && $("chartMode").value === "dual") ? "" : "none";
    if ($("dualLayoutRow")) $("dualLayoutRow").style.display = ($("chartMode") && $("chartMode").value === "dual") ? "" : "none";
}

function updateDualModeUI(payload = null) {
  const mode = payload && payload.chart_mode ? String(payload.chart_mode) : ($("chartMode") ? $("chartMode").value : "single");
  const dual = mode === "dual";
  if ($("kType2Row")) $("kType2Row").style.display = dual ? "" : "none";
  if ($("dualLayoutRow")) $("dualLayoutRow").style.display = dual ? "" : "none";
  // 双图激活改为点击图窗自动激活，去掉“图1/图2激活”按钮标签入口
  if ($("dualChartToolbar")) $("dualChartToolbar").style.display = "none";
  const active = payload && payload.active_chart_id ? String(payload.active_chart_id) : (sessionConfig.activeChartId || "chart1");
  dualActiveChartId = active === "chart2" ? "chart2" : "chart1";
  chartConfig = active === "chart2" ? chartConfigStore.perChart.chart2 : chartConfigStore.perChart.chart1;
  chartConfig.theme = chartConfigStore.shared.theme || chartConfig.theme;
  chartConfig.crosshair = deepMerge(JSON.parse(JSON.stringify(chartConfig.crosshair || {})), chartConfigStore.shared.crosshair || {});
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

function getBspConfig(level) {
  const key = BSP_LEVEL_CONFIG_KEY[level] || "bspBi";
  return chartConfig[key] || chartConfig.bspBi || DEFAULT_CHART_CONFIG.bspBi;
}

function getBspDisplayLabel(p) {
  if (!p) return "";
  if (p.display_label) return String(p.display_label);
  if (p.level_label && p.label) return `${p.level_label}${p.label}`;
  return String(p.label || "");
}

function isRhythmLevelEnabled(level) {
  const cfg = chartConfig.rhythmLine || DEFAULT_CHART_CONFIG.rhythmLine;
  const subKey = RHYTHM_LEVEL_ENABLED_KEY[level];
  if (!subKey) return true;
  return !!cfg[subKey];
}

function getRhythmGroupIndex(group) {
  const raw = String(group || "rhythm1").replace(/[^0-9]/g, "");
  const idx = Number(raw || "1");
  return Number.isFinite(idx) && idx >= 1 ? idx : 1;
}

function getRhythmVisualConfig(group) {
  const cfg = chartConfig.rhythmLine || DEFAULT_CHART_CONFIG.rhythmLine;
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

function saveChanSettings() {
  const inputs = $("chanSettingsContent").querySelectorAll("input, select");
  if (!chanConfig.macd) chanConfig.macd = { fast: 12, slow: 26, signal: 9 };
  
  inputs.forEach(input => {
    const key = input.dataset.key;
    if (input.type === "checkbox") {
      chanConfig[key] = input.checked;
    } else if (input.tagName === "SELECT") {
      const val = input.value;
      chanConfig[key] = (val === "true" ? true : (val === "false" ? false : val));
    } else if (input.type === "number") {
      const numVal = parseFloat(input.value);
      if (key === "macd_fast") chanConfig.macd.fast = numVal;
      else if (key === "macd_slow") chanConfig.macd.slow = numVal;
      else if (key === "macd_signal") chanConfig.macd.signal = numVal;
      else chanConfig[key] = numVal;
    } else if (key === "mean_metrics" || key === "trend_metrics" || key === "bs_type") {
      chanConfig[key] = input.value; // Store as string for easy editing
    } else {
      chanConfig[key] = input.value;
    }
  });
  
  // Create a deep copy for the final config to be sent to backend
  const finalConfig = JSON.parse(JSON.stringify(chanConfig));
  
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
      setGlobalLoading(true, "正在重新计算缠论逻辑...");
      api("/api/reconfig", { chan_config: finalConfig })
        .then(payload => {
          refreshUI(payload);
          if (payload.bsp_history && payload.bsp_history.length > 0) {
            payload.bsp_history.forEach(h => {
              setMsg(`[重算] 发现 ${h.display_label || h.label} @K线:${h.x}`, true);
            });
          }
          showToast(payload.message || "配置已更新，逻辑已重算。");
          closeChanSettings();
        })
        .catch(e => {
          showToast("配置应用失败：" + e.message);
        })
        .finally(() => {
          hideGlobalLoading();
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

function openSettings() {
  if (isSystemSettingsOpen()) closeSystemSettings();
  renderSettingsForm();
  $("settingsModal").classList.add("show");
}

function closeSettings() {
  $("settingsModal").classList.remove("show");
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
          { value: "quantity", label: "数量" }
        ], tip: "传统：原始K线。数量：将加载会话后的整段K线按数量Q聚合后再进入缠论计算。" },
        { label: "数量", subKey: "quantity", type: "number", min: 1, step: 1, tip: "数量模式下生效。范围为 1 到会话总K线数N；1=全合并，N=不聚合。" }
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
        { label: "副图配置槽位", subKey: "subSlot", type: "select", options: subSlotOptions, tip: slotTip },
        { label: "副图指标选择", subKey: "subType", type: "indicator_multi_sub" }
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
        { label: "下跌颜色", subKey: "downColor", type: "color" }
      ]
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
        { label: "启用节奏线", subKey: "enabled", type: "checkbox", tip: "总开关，关闭后不绘制任何节奏线。" },
        { label: "分型→笔", subKey: "fractToBiEnabled", type: "checkbox", tip: "是否绘制分型→笔层级的节奏线。" },
        { label: "笔→段", subKey: "biToSegEnabled", type: "checkbox", tip: "是否绘制笔→段层级的节奏线。" },
        { label: "段→2段", subKey: "segToSegsegEnabled", type: "checkbox", tip: "是否绘制段→2段层级的节奏线。" },
        { label: "节奏线1颜色", subKey: "group1LineColor", type: "color" },
        { label: "节奏线1粗细", subKey: "group1LineWidth", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "节奏线1线型", subKey: "group1LineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]},
        { label: "节奏线1数字颜色", subKey: "group1TextColor", type: "color" },
        { label: "节奏线1数字大小", subKey: "group1TextFontSize", type: "number", min: 8, max: 32, step: 1 },
        { label: "节奏线1数字粗细", subKey: "group1TextFontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "节奏线2颜色", subKey: "group2LineColor", type: "color" },
        { label: "节奏线2粗细", subKey: "group2LineWidth", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "节奏线2线型", subKey: "group2LineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]},
        { label: "节奏线2数字颜色", subKey: "group2TextColor", type: "color" },
        { label: "节奏线2数字大小", subKey: "group2TextFontSize", type: "number", min: 8, max: 32, step: 1 },
        { label: "节奏线2数字粗细", subKey: "group2TextFontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "节奏线3颜色", subKey: "group3LineColor", type: "color" },
        { label: "节奏线3粗细", subKey: "group3LineWidth", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "节奏线3线型", subKey: "group3LineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]},
        { label: "节奏线3数字颜色", subKey: "group3TextColor", type: "color" },
        { label: "节奏线3数字大小", subKey: "group3TextFontSize", type: "number", min: 8, max: 32, step: 1 },
        { label: "节奏线3数字粗细", subKey: "group3TextFontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "节奏线4颜色", subKey: "group4LineColor", type: "color" },
        { label: "节奏线4粗细", subKey: "group4LineWidth", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "节奏线4线型", subKey: "group4LineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]},
        { label: "节奏线4数字颜色", subKey: "group4TextColor", type: "color" },
        { label: "节奏线4数字大小", subKey: "group4TextFontSize", type: "number", min: 8, max: 32, step: 1 },
        { label: "节奏线4数字粗细", subKey: "group4TextFontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "节奏线5颜色", subKey: "group5LineColor", type: "color" },
        { label: "节奏线5粗细", subKey: "group5LineWidth", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "节奏线5线型", subKey: "group5LineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]},
        { label: "节奏线5数字颜色", subKey: "group5TextColor", type: "color" },
        { label: "节奏线5数字大小", subKey: "group5TextFontSize", type: "number", min: 8, max: 32, step: 1 },
        { label: "节奏线5数字粗细", subKey: "group5TextFontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]}
      ]
    },
    {
      title: "分型中枢",
      key: "fractZs",
      color: "#c2410c",
      bgColor: "rgba(194, 65, 12, 0.08)",
      items: [
        { label: "启用分型中枢", subKey: "enabled", type: "checkbox" },
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
        { label: "启用笔中枢", subKey: "enabled", type: "checkbox" },
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
        { label: "启用段中枢", subKey: "enabled", type: "checkbox" },
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
        { label: "启用2段中枢", subKey: "enabled", type: "checkbox" },
        { label: "2段中枢颜色", subKey: "color", type: "color" },
        { label: "2段中枢粗细", subKey: "width", type: "number", min: 0.1, max: 5, step: 0.1 }
      ]
    },
    {
      title: "笔买卖点",
      key: "bspBi",
      color: "#be123c",
      bgColor: "rgba(190, 18, 60, 0.08)",
      items: [
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 30 },
        { label: "连线颜色", subKey: "lineColor", type: "color" },
        { label: "连线粗细", subKey: "lineWidth", type: "number", min: 0.1, max: 5, step: 0.1 },
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
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 30 },
        { label: "连线颜色", subKey: "lineColor", type: "color" },
        { label: "连线粗细", subKey: "lineWidth", type: "number", min: 0.1, max: 5, step: 0.1 },
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
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 30 },
        { label: "连线颜色", subKey: "lineColor", type: "color" },
        { label: "连线粗细", subKey: "lineWidth", type: "number", min: 0.1, max: 5, step: 0.1 },
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
      title: "买卖文字标记",
      key: "trade",
      color: "#be123c",
      bgColor: "rgba(190, 18, 60, 0.08)",
      items: [
        { label: "买入颜色", subKey: "buyColor", type: "color" },
        { label: "卖出颜色", subKey: "sellColor", type: "color" },
        { label: "文字大小", subKey: "markerFontSize", type: "number", min: 10, max: 32 },
        { label: "文字粗细", subKey: "markerFontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "买卖竖线粗细", subKey: "markerLineWidth", type: "number", min: 0.5, max: 8, step: 0.1 },
        { label: "买卖竖线线型", subKey: "markerLineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]}
      ]
    },
    {
      title: "买卖收盘价指示线",
      key: "trade",
      color: "#0f766e",
      bgColor: "rgba(15, 118, 110, 0.08)",
      items: [
        { label: "指示线粗细", subKey: "closeLineWidth", type: "number", min: 0.5, max: 8, step: 0.1 },
        { label: "买入价线型", subKey: "buyCloseLineStyle", type: "select", options: [
          { value: "solid", label: "实线" },
          { value: "dashed", label: "虚线" },
          { value: "dotted", label: "点线" }
        ]},
        { label: "卖出价线型", subKey: "sellCloseLineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]}
      ]
    },
    {
      title: "持仓区间与盈亏区间",
      key: "trade",
      color: "#7c3aed",
      bgColor: "rgba(124, 58, 237, 0.08)",
      items: [
        { label: "持仓区间(买)背景", subKey: "rangeFillBuy", type: "color", tip: "用于买入后到卖出前整段背景色。" },
        { label: "持仓区间(卖)背景", subKey: "rangeFillSell", type: "color", tip: "用于已卖出历史交易区间整段背景色。" },
        { label: "盈利区间颜色", subKey: "profitBandColor", type: "color", tip: "用于买卖价之间的盈利区间填充色。" },
        { label: "亏损区间颜色", subKey: "lossBandColor", type: "color", tip: "用于买卖价之间的亏损区间填充色。" }
      ]
    },
    {
      title: "持仓浮窗字体",
      key: "tradeStatus",
      color: "#1d4ed8",
      bgColor: "rgba(29, 78, 216, 0.08)",
      items: [
        { label: "标题大小", subKey: "titleFontSize", type: "number", min: 10, max: 28, tip: "控制持仓状态窗口标题栏文字大小。" },
        { label: "标题粗细", subKey: "titleFontWeight", type: "select", options: [{ value: "normal", label: "常规" }, { value: "bold", label: "加粗" }], tip: "控制持仓状态窗口标题栏文字粗细。" },
        { label: "标题颜色", subKey: "titleColor", type: "color", tip: "控制持仓状态窗口标题栏文字颜色。" },
        { label: "名称大小", subKey: "labelFontSize", type: "number", min: 10, max: 24, tip: "控制持仓状态窗口左侧名称文字大小。" },
        { label: "名称粗细", subKey: "labelFontWeight", type: "select", options: [{ value: "normal", label: "常规" }, { value: "bold", label: "加粗" }], tip: "控制持仓状态窗口左侧名称文字粗细。" },
        { label: "名称颜色", subKey: "labelColor", type: "color", tip: "控制持仓状态窗口左侧名称文字颜色。" },
        { label: "数值大小", subKey: "valueFontSize", type: "number", min: 10, max: 28, tip: "控制持仓状态窗口右侧数值文字大小。" },
        { label: "数值粗细", subKey: "valueFontWeight", type: "select", options: [{ value: "normal", label: "常规" }, { value: "bold", label: "加粗" }], tip: "控制持仓状态窗口右侧数值文字粗细。" },
        { label: "数值颜色", subKey: "valueColor", type: "color", tip: "控制持仓状态窗口右侧数值默认颜色。" }
      ]
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
        { label: "文字大小", subKey: "fontSize", type: "number", min: 10, max: 30 },
        { label: "文字粗细", subKey: "fontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "消失速度(ms)", subKey: "speed", type: "number", min: 500, max: 10000, step: 100 },
        { label: "显示买卖点弹窗", subKey: "showBsp", type: "checkbox", tip: "勾选后显示买卖点（分型/笔/段/2段）相关弹窗。" },
        { label: "显示1382弹窗", subKey: "showRhythm1382", type: "checkbox", tip: "勾选后显示 1382 节奏提示弹窗。" },
        { label: "显示判定统计弹窗", subKey: "showJudge", type: "checkbox", tip: "勾选后显示买卖点 ×/✓ 判定统计弹窗。" }
      ]
    }
  ];

  sections.forEach(sec => {
    const div = document.createElement("div");
    div.className = "settingsSection";
    div.style.background = sec.bgColor;
    div.innerHTML = `<div class="settingsSectionTitle" style="color:${sec.color}">${sec.title}</div>`;
    const grid = document.createElement("div");
    grid.className = "settingsGrid";
    // 兜底处理：本地旧配置或异常配置可能把 section 写成 null，避免点击设置后渲染报错
    const sectionCfg = ensureObject(chartConfig[sec.key], {});
    sec.items.forEach(item => {
      let val;
      if (sec.key === "theme_section") {
        val = chartConfig.theme;
      } else if (sec.key === "dataForm") {
        val = dataFormConfig[item.subKey];
      } else if (sec.key === "indicators") {
        if (item.subKey === "mainSlot") val = selectedMainIndicatorSlot;
        else if (item.subKey === "subSlot") val = selectedSubIndicatorSlot;
        else if (item.subKey === "mainType") val = indicatorMainSlots[String(selectedMainIndicatorSlot)] || [];
        else if (item.subKey === "subType") val = indicatorSubSlots[String(selectedSubIndicatorSlot)] || [];
      } else {
        val = sectionCfg[item.subKey];
      }
      
      const itemDiv = document.createElement("div");
      itemDiv.className = "settingsItem";
      
      // Add a line preview for sections with color/width
       if (sec.key !== "theme_section" && sec.key !== "indicators" && sec.key !== "toast" && sec.key !== "xAxis" && sec.key !== "yAxis") {
          const previewLine = document.createElement("div");
          previewLine.style.height = "2px";
          previewLine.style.width = "100%";
          previewLine.style.marginBottom = "4px";
          const color = sectionCfg.color || sectionCfg.lineColor || sectionCfg.upColor || "#ccc";
          previewLine.style.background = getCfgColor(color);
          itemDiv.appendChild(previewLine);
       }
       
       if (item.type === "select") {
          let optionsHtml = item.options.map(o => `<option value="${o.value}" ${String(val) === String(o.value) ? "selected" : ""}>${o.label}</option>`).join("");
          itemDiv.innerHTML += `
            <label>${buildLabelHtml(item)}</label>
            <select data-key="${sec.key}" data-subkey="${item.subKey}">${optionsHtml}</select>
          `;
        if (sec.key === "dataForm" && item.subKey === "mode") {
           const select = itemDiv.querySelector("select");
           const loaded = !!(lastPayload && lastPayload.ready);
           if (!loaded) {
             const qOpt = Array.from(select.options).find((o) => o.value === "quantity");
             if (qOpt) qOpt.disabled = true;
             if (String(select.value) === "quantity") select.value = "traditional";
           }
        }
        if (sec.key === "indicators" && item.subKey === "mainSlot") {
           const select = itemDiv.querySelector("select");
           select.onchange = (e) => {
              selectedMainIndicatorSlot = Number(e.target.value);
              storageSet("chan_selected_main_indicator_slot", String(selectedMainIndicatorSlot));
              renderSettingsForm();
           };
        } else if (sec.key === "indicators" && item.subKey === "subSlot") {
           const select = itemDiv.querySelector("select");
           select.onchange = (e) => {
              selectedSubIndicatorSlot = Number(e.target.value);
              storageSet("chan_selected_sub_indicator_slot", String(selectedSubIndicatorSlot));
              renderSettingsForm();
           };
        }
      } else if (item.type === "indicator_multi_main") {
          let html = `<label>${buildLabelHtml(item)}</label>`;
          if (selectedMainIndicatorSlot === 0) {
            html += `
              <div class="muted" style="margin-top:8px;">当前主图槽位为 0，不显示主图指标。</div>
            `;
          } else {
            const currentList = Array.isArray(val) ? val : [];
            const options = [{v:"boll",l:"BOLL"}, {v:"demark",l:"Demark"}, {v:"trendline",l:"TrendLine"}];
            html += `<div style="display:flex; flex-direction:column; gap:4px; margin-top:8px;">`;
            options.forEach(opt => {
              const checked = currentList.includes(opt.v);
              html += `
                <label style="flex-direction:row; align-items:center; display:flex;">
                  <input type="checkbox" class="indicator-check-main" value="${opt.v}" ${checked ? "checked" : ""} 
                         data-key="indicators" data-subkey="mainType"
                         style="width:auto; margin-right:8px;">
                  ${opt.l}
                </label>
              `;
            });
            html += `</div>`;
          }
          itemDiv.innerHTML += html;
      } else if (item.type === "indicator_multi_sub") {
          let html = `<label>${buildLabelHtml(item)}</label>`;
          if (selectedSubIndicatorSlot === 0) {
            html += `
              <div class="muted" style="margin-top:8px;">当前副图槽位为 0，不显示任何副图指标。</div>
            `;
          } else {
            const currentList = Array.isArray(val) ? val : [];
            const options = [{v:"macd",l:"MACD"}, {v:"kdj",l:"KDJ"}, {v:"rsi",l:"RSI"}];
            html += `<div style="display:flex; flex-direction:column; gap:4px; margin-top:8px;">`;
            options.forEach(opt => {
              const checked = currentList.includes(opt.v);
              html += `
                <label style="flex-direction:row; align-items:center; display:flex;">
                  <input type="checkbox" class="indicator-check-sub" value="${opt.v}" ${checked ? "checked" : ""} 
                         data-key="indicators" data-subkey="subType"
                         style="width:auto; margin-right:8px;">
                  ${opt.l}
                </label>
              `;
            });
            html += `</div>`;
          }
          itemDiv.innerHTML += html;
      } else if (item.type === "checkbox") {
        itemDiv.innerHTML += `
          <label style="flex-direction:row; align-items:center; display:flex;">
            <input type="checkbox" ${val ? "checked" : ""} 
                   data-key="${sec.key}" data-subkey="${item.subKey}" 
                   style="width:auto; margin-right:8px;">
            ${item.label}
          </label>
        `;
      } else if (item.type === "color") {
        // Use a better color indicator for colors
        const safeVal = typeof val === "string" ? val : "#000000";
        itemDiv.innerHTML += `
          <label>${buildLabelHtml(item)}</label>
          <div style="display:flex; align-items:center; gap:8px;">
            <input type="color" value="${safeVal.startsWith('#') ? safeVal : '#000000'}" data-key="${sec.key}" data-subkey="${item.subKey}" style="width:40px; height:24px; padding:0; border:none; background:none; cursor:pointer;">
            <input type="text" value="${safeVal}" data-key="${sec.key}" data-subkey="${item.subKey}-text" style="flex:1; height:24px; padding:2px 4px; font-size:12px; font-family:monospace;">
          </div>
        `;
        const colorInput = itemDiv.querySelector('input[type="color"]');
        const textInput = itemDiv.querySelector('input[type="text"]');
        colorInput.oninput = (e) => { textInput.value = e.target.value; };
        textInput.oninput = (e) => { 
          if (/^#[0-9a-fA-F]{6}$/.test(e.target.value)) {
            colorInput.value = e.target.value;
          }
        };
      } else {
        let displayVal = val;
        if (item.subKey === "dash" && Array.isArray(val)) displayVal = val.join(", ");
        if (sec.key === "dataForm" && item.subKey === "quantity") {
          const n = getRawKlineCount();
          const minN = 1;
          const maxN = n > 0 ? n : 1;
          const disabled = !(lastPayload && lastPayload.ready);
          const finalVal = clampDataFormQuantity(displayVal, maxN);
          itemDiv.innerHTML += `
            <label>${buildLabelHtml(item)}</label>
            <input type="number"
                   value="${finalVal}"
                   min="${minN}"
                   max="${maxN}"
                   step="1"
                   ${disabled ? "disabled" : ""}
                   data-key="${sec.key}"
                   data-subkey="${item.subKey}">
            <div class="muted" style="font-size:12px;">${disabled ? "请先加载会话后再使用数量模式。" : `当前范围：1 - ${maxN}`}</div>
          `;
          grid.appendChild(itemDiv);
          return;
        }
        itemDiv.innerHTML += `
          <label>${buildLabelHtml(item)}</label>
          <input type="${item.type}" 
                 value="${displayVal}" 
                 step="${item.step || 1}" 
                 placeholder="${item.placeholder || ""}"
                 data-key="${sec.key}" 
                 data-subkey="${item.subKey}">
        `;
      }
      grid.appendChild(itemDiv);
    });
    div.appendChild(grid);
    container.appendChild(div);
  });
  initTooltips();
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

async function saveSettings() {
  const inputs = $("settingsContent").querySelectorAll("input, select");
  let nextDataFormMode = dataFormConfig.mode;
  let nextDataFormQuantity = dataFormConfig.quantity;
  inputs.forEach(input => {
    const key = input.dataset.key;
    const subkey = input.dataset.subkey;
    if (!key || !subkey || subkey.endsWith("-text")) return;
    
    let val;
    if (input.type === "checkbox") {
      val = input.checked;
    } else if (input.type === "number") {
      val = parseFloat(input.value);
    } else {
      val = input.value;
    }
    
    if (key === "theme_section") {
      chartConfig.theme = val;
      applyThemeFromSelect();
    } else if (key === "dataForm") {
      if (subkey === "mode") nextDataFormMode = normalizeDataFormMode(val);
      if (subkey === "quantity") nextDataFormQuantity = clampDataFormQuantity(val, dataFormConfig.quantity);
    } else if (key === "indicators") {
      if (subkey === "mainSlot") {
        selectedMainIndicatorSlot = Number(val);
        storageSet("chan_selected_main_indicator_slot", String(selectedMainIndicatorSlot));
      } else if (subkey === "subSlot") {
        selectedSubIndicatorSlot = Number(val);
        storageSet("chan_selected_sub_indicator_slot", String(selectedSubIndicatorSlot));
      } else if (subkey === "mainType") {
        const checks = $("settingsContent").querySelectorAll(".indicator-check-main");
        const selected = [];
        checks.forEach(c => { if (c.checked) selected.push(c.value); });
        indicatorMainSlots[String(selectedMainIndicatorSlot)] = selected;
      } else if (subkey === "subType") {
        const checks = $("settingsContent").querySelectorAll(".indicator-check-sub");
        const selected = [];
        checks.forEach(c => { if (c.checked) selected.push(c.value); });
        indicatorSubSlots[String(selectedSubIndicatorSlot)] = selected;
      }
      if (subkey === "mainType" || subkey === "subType" || subkey === "mainSlot" || subkey === "subSlot") {
        storageSet("chan_indicator_main_slots", JSON.stringify(indicatorMainSlots));
        storageSet("chan_indicator_sub_slots", JSON.stringify(indicatorSubSlots));
      } 
    } else if (key && subkey) {
      if (subkey === "dash" && typeof val === "string") {
        const arr = val.split(",").map(n => parseFloat(n.trim())).filter(n => !isNaN(n));
        val = arr.length > 0 ? arr : null;
      }
      if (!chartConfig[key]) chartConfig[key] = {};
      chartConfig[key][subkey] = val;
    }
  });
  dataFormConfig.mode = nextDataFormMode;
  dataFormConfig.quantity = nextDataFormQuantity;
  const activeCfgKey = (lastPayload && String(lastPayload.active_chart_id) === "chart2") ? "chart2" : "chart1";
  chartConfigStore.perChart[activeCfgKey] = JSON.parse(JSON.stringify(chartConfig));
  chartConfigStore.shared.theme = chartConfig.theme;
  chartConfigStore.shared.crosshair = JSON.parse(JSON.stringify(chartConfig.crosshair || chartConfigStore.shared.crosshair));
  chartConfigStore.shared.mode = $("chartMode") ? $("chartMode").value : chartConfigStore.shared.mode;
  storageSet("chan_chart_config", JSON.stringify(chartConfigStore));
  closeSettings();
  if (lastPayload && lastPayload.ready) {
    const n = getRawKlineCount();
    if (dataFormConfig.mode === "quantity" && n <= 0) {
      throw new Error("请先加载会话后再选择数量模式。");
    }
    const payload = await api("/api/reconfig", {
      chan_config: chanConfig,
      data_form_mode: dataFormConfig.mode,
      data_form_quantity: clampDataFormQuantity(dataFormConfig.quantity, n || 1),
    });
    refreshUI(payload, { afterStep: false });
    setMsg(payload.message || "图表设置更新成功");
  } else if (lastPayload && lastPayload.chart) {
    draw(lastPayload.chart);
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
    
    // 保存数据源配置
    const dataSourcePriority = getDataSourcePriority();
    if (dataSourcePriority && dataSourcePriority.length > 0) {
        systemConfig.dataSourcePriority = dataSourcePriority;
    }

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
  const showTooltip = (target) => {
    const text = target.getAttribute("data-tip");
    if (!text) return;
    const rect = target.getBoundingClientRect();
    showFloatingTip(text, rect.left + rect.width, rect.top + rect.height / 2, rect);
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
    chartConfig = JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG));
    indicatorMainSlots = { ...defaultMainSlots };
    indicatorSubSlots = { ...defaultSubSlots };
    selectedMainIndicatorSlot = 0;
    selectedSubIndicatorSlot = 0;
    storageSet("chan_indicator_main_slots", JSON.stringify(indicatorMainSlots));
    storageSet("chan_indicator_sub_slots", JSON.stringify(indicatorSubSlots));
    storageSet("chan_selected_main_indicator_slot", "0");
    storageSet("chan_selected_sub_indicator_slot", "0");
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
  return { mainTypes, subCharts };
}

function getChipBucketStep() {
  const v = Number(chartConfig.chip.bucketStep);
  return Number.isFinite(v) && v > 0 ? v : 0.1;
}

function setGlobalLoading(visible, text) {
  const overlay = $("globalLoading");
  if (!overlay) return;
  const txt = $("globalLoadingText");
  if (txt && text) txt.textContent = text;
  overlay.classList.toggle("show", !!visible);
}

function hideGlobalLoading() {
  setGlobalLoading(false);
}

function syncStepButtonState() {
  const disabled = !lastPayload || !lastPayload.ready || sessionFinished || stepInFlight;
  $("btnStep").disabled = disabled;
  $("btnStepN").disabled = disabled;
  $("btnBackN").disabled = !lastPayload || !lastPayload.ready || stepInFlight;
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
  tradeHistory = Array.isArray(payload.trades.history) ? payload.trades.history : [];
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
  if (lastPayload && lastPayload.ready && lastPayload.chart) draw(lastPayload.chart);
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
  const w = canvas.clientWidth;
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
  draw(lastPayload.chart);
}

function ensureLatestKVisible() {
  if (!lastPayload || !lastPayload.chart || !lastPayload.chart.kline.length) return;
  const lastX = lastPayload.chart.kline[lastPayload.chart.kline.length - 1].x;
  if (lastX >= viewXMin && lastX <= viewXMax) return;
  const span = viewXMax - viewXMin;
  if (span <= 1) return;
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
  draw(lastPayload.chart);
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
  if (lastPayload && lastPayload.ready) draw(lastPayload.chart);
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
    draw(lastPayload.chart);
  }
}

canvas.addEventListener(
  "wheel",
  (e) => {
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
      redrawCurrentPayload();
      return;
    }
    zoomViewAt(factor, mouseX);
    if (isDualRuntimeReady()) saveRuntimeState(dualActiveChartId);
  },
  { passive: false }
);

canvas.addEventListener("mousedown", (e) => {
  if (e.button !== 0) return;
  const pe = normalizePointerEventToActivePane(e, true);
  if (!pe) return;
  if (!lastPayload || !lastPayload.ready || !viewReady) return;
  isPanning = true;
  panStartX = pe.clientX;
  panStartY = pe.clientY;
  panStartViewMin = viewXMin;
  panStartViewMax = viewXMax;
  panStartYShiftRatio = viewYShiftRatio;
});
window.addEventListener("mouseup", () => {
  isPanning = false;
  chartMouseDownPos = null;
});
window.addEventListener("mousemove", (e) => {
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
  const usableW = Math.max(1, canvas.clientWidth - PAD_L - PAD_R);
  const dxBars = Math.round((-dx / usableW) * span);
  let newMin = panStartViewMin + dxBars;
  let newMax = panStartViewMax + dxBars;
  if (newMin < allXMin) {
    newMin = allXMin;
    newMax = newMin + span;
  }
  viewXMin = newMin;
  viewXMax = newMax;
  const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
  const plotH = Math.max(1, s.plotH);
  viewYShiftRatio = panStartYShiftRatio + (dy / plotH);
  viewYShiftRatio = Math.max(-3, Math.min(3, viewYShiftRatio));
  userAdjustedView = true;
  if (isDualRuntimeReady()) saveRuntimeState(dualActiveChartId);
  redrawCurrentPayload();
});

canvas.addEventListener("mousemove", (e) => {
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
  const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
  const visibleKs = getVisibleKs(lastPayload.chart, s.xMin, s.xMax);
  const rawX = pe.clientX - rect.left;
  const rawY = pe.clientY - rect.top;
  const hoveredLegend = !!(legendHoverBox && rawX >= legendHoverBox.x1 && rawX <= legendHoverBox.x2 && rawY >= legendHoverBox.y1 && rawY <= legendHoverBox.y2);
  legendHoverActive = hoveredLegend;
  const clampedX = Math.max(PAD_L, Math.min(s.w - PAD_R, rawX));
  
  // Lock X if Ctrl is held
   if (!pe.ctrlKey) {
     const targetX = s.xMin + ((clampedX - PAD_L) / Math.max(1, s.plotW)) * (s.xMax - s.xMin);
     const refK = nearestKByX(visibleKs, targetX);
     crosshairX = refK ? s.x(refK.x) : clampedX;
   }
  
   crosshairY = Math.max(PAD_T, Math.min(s.contentBottom, rawY));
   const hoveredSignal = (signalHoverBoxes || []).find((box) => rawX >= box.x1 && rawX <= box.x2 && rawY >= box.y1 && rawY <= box.y2);
   if (hoveredSignal && hoveredSignal.text) {
     showFloatingTip(hoveredSignal.text, pe.clientX, pe.clientY);
   } else {
     hideFloatingTip();
   }
   if (isDualRuntimeReady()) saveRuntimeState(dualActiveChartId);
   redrawCurrentPayload();
});

canvas.addEventListener("mouseleave", () => {
  canvasHovered = false;
  legendHoverActive = false;
  crosshairX = null;
  crosshairY = null;
  if (isDualRuntimeReady()) saveRuntimeState(dualActiveChartId);
  hideFloatingTip();
  if (lastPayload && lastPayload.ready) redrawCurrentPayload();
});

canvas.addEventListener("dblclick", (e) => {
  const pe = normalizePointerEventToActivePane(e, true);
  if (!pe) return;
  if (crosshairX !== null && crosshairY !== null) {
    const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
    const rect = canvas.getBoundingClientRect();
    const xp = (pe && typeof pe.clientX === "number") ? (pe.clientX - rect.left) : crosshairX;
    const yp = (pe && typeof pe.clientY === "number") ? (pe.clientY - rect.top) : crosshairY;
    
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

    // Check if we are deleting a Bi ray
    let removedBi = false;
    const xVal = xFromPx(s, xp);
    userBiRays = userBiRays.filter(r => {
      const x1 = Number(r.x1), y1 = Number(r.y1), x2 = Number(r.x2), y2 = Number(r.y2);
      const dx = (x2 - x1);
      if (!Number.isFinite(x1) || !Number.isFinite(y1) || !Number.isFinite(dx) || dx === 0) return true;
      if (xVal < x1) return true;
      const slope = (y2 - y1) / dx;
      const yOn = y1 + slope * (xVal - x1);
      const yPx = s.y(yOn);
      if (Math.abs(yPx - yp) < 8) {
        removedBi = true;
        return false;
      }
      return true;
    });
    if (removedBi) {
      userBiRaysDirty = true;
      if (selectedDrawing && selectedDrawing.type === "biRay") selectedDrawing = null;
      redrawCurrentPayload();
      return;
    }
  }

  crosshairEnabled = !crosshairEnabled;
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
      const s0 = toScaler(chartRef, Math.max(allXMin, viewXMin), viewXMax);
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
  const ids = ["toolNone", "toolHorizontalRay", "toolBiRay"];
  ids.forEach((id) => {
    const el = $(id);
    if (!el) return;
    el.classList.remove("active");
  });
  if (activeTool === "horizontalRay" && $("toolHorizontalRay")) $("toolHorizontalRay").classList.add("active");
  else if (activeTool === "biRay" && $("toolBiRay")) $("toolBiRay").classList.add("active");
  else if ($("toolNone")) $("toolNone").classList.add("active");
}

function setActiveTool(next) {
  const v = next === "horizontalRay" || next === "biRay" ? next : "none";
  activeTool = v;
  storageSet("chan_active_tool", v);
  if (v !== "biRay") pendingBiRayPts = [];
  if (v !== "none") selectedDrawing = null;
  updateToolboxUI();
  if (lastPayload && lastPayload.ready) draw(lastPayload.chart);
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

function pickDrawingAt(s, px, py) {
  const threshold = 8;
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
    if (lastPayload && lastPayload.ready) draw(lastPayload.chart);
  }
}

if ($("toolLineProps")) $("toolLineProps").addEventListener("click", editSelectedLineProps);

function persistUserBiRaysNow() {
  storageSet("chan_user_bi_rays", JSON.stringify(userBiRays));
  userBiRaysDirty = false;
}

function maybeSaveUserBiRaysOnExit() {
  if (!userBiRaysDirty || !Array.isArray(userBiRays) || userBiRays.length <= 0) return;
  const shouldSave = confirmAndLog("是否保存画线？");
  if (shouldSave) persistUserBiRaysNow();
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

canvas.addEventListener("mousedown", (e) => {
  if (e.button !== 0) return;
  if (isDualRuntimeReady()) {
    const hitId = resolveDualChartIdFromClient(e.clientX, e.clientY);
    if (hitId !== dualActiveChartId) setActiveChart(hitId, true);
  }
  const pe = normalizePointerEventToActivePane(e, true);
  if (!pe) return;
  chartClickMoved = false;
  chartMouseDownPos = { x: pe.clientX, y: pe.clientY };
});

canvas.addEventListener("click", (e) => {
  if (isDualRuntimeReady()) {
    const hitId = resolveDualChartIdFromClient(e.clientX, e.clientY);
    if (hitId !== dualActiveChartId) {
      setActiveChart(hitId, true);
      redrawCurrentPayload();
    }
  }
  const pe = normalizePointerEventToActivePane(e, true);
  if (!pe) return;
  if (!lastPayload || !lastPayload.ready || !viewReady) return;
  if (chartClickMoved) return;
  const rect = canvas.getBoundingClientRect();
  const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
  const y = pe.clientY - rect.top;
  const x = pe.clientX - rect.left;

  const wantHorizontalRay = !!pe.ctrlKey || activeTool === "horizontalRay";
  const wantBiRay = !!pe.shiftKey || activeTool === "biRay";

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

  if (activeTool === "none") {
    const picked = pickDrawingAt(s, x, y);
    if (picked) {
      selectedDrawing = picked;
      setMsg(picked.type === "biRay" ? "已选中笔端点射线，可点击“画线属性”编辑。" : "已选中水平射线，可点击“画线属性”编辑。");
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
    case "nextBar":
      if ($("btnStep").disabled || stepInFlight) return false;
      $("btnStep").click();
      return true;
    case "stepForwardN":
      if ($("btnStepN").disabled) return false;
      $("btnStepN").click();
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
    case "centerLatest":
      centerLatestK();
      return true;
    case "drawHorizontalRay": {
      if (!crosshairEnabled || crosshairX === null || crosshairY === null || !lastPayload || !lastPayload.ready) return false;
      const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
      const refK = getReferenceK(lastPayload.chart, s);
      if (!refK) return false;
      const yVal = s.yFromPx(crosshairY);
      userRays.push({ x: refK.x, y: yVal });
      storageSet("chan_user_rays", JSON.stringify(userRays));
      setMsg(`已生成射线: ${yVal.toFixed(2)}`);
      draw(lastPayload.chart);
      return true;
    }
    case "zoomYIn":
      if (!lastPayload || !lastPayload.ready) return false;
      viewYZoomRatio *= 1.15;
      draw(lastPayload.chart);
      return true;
    case "zoomYOut":
      if (!lastPayload || !lastPayload.ready) return false;
      viewYZoomRatio /= 1.15;
      draw(lastPayload.chart);
      return true;
    case "zoomXIn":
      if (!lastPayload || !lastPayload.ready) return false;
      zoomViewAt(1.15, canvas.clientWidth / 2);
      return true;
    case "zoomXOut":
      if (!lastPayload || !lastPayload.ready) return false;
      zoomViewAt(1 / 1.15, canvas.clientWidth / 2);
      return true;
    case "adjustCrosshairUp":
    case "adjustCrosshairDown": {
      if (!crosshairEnabled || crosshairY === null || !lastPayload || !lastPayload.ready) return false;
      const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
      const delta = actionId === "adjustCrosshairUp" ? -0.01 : 0.01;
      const curPrice = s.yFromPx(crosshairY);
      const newPrice = curPrice - delta;
      crosshairY = s.y(newPrice);
      draw(lastPayload.chart);
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
  const plotMidX = PAD_L + (canvas.clientWidth - PAD_L - PAD_R) / 2;
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
      const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
      const refK = getReferenceK(lastPayload.chart, s);
      if (refK) {
        const prev = nearestKByX(lastPayload.chart.kline.filter((k) => k.x < refK.x), refK.x - 1);
        if (prev) {
          crosshairX = s.x(prev.x);
          crosshairY = s.y(prev.c);
          draw(lastPayload.chart);
        }
      }
      return;
    }
    viewXMin = Math.max(allXMin, viewXMin - shift);
    viewXMax = viewXMin + span;
    userAdjustedView = true;
    draw(lastPayload.chart);
  } else if (e.code === "ArrowRight") {
    if (crosshairEnabled && crosshairX !== null) {
      e.preventDefault();
      const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
      const refK = getReferenceK(lastPayload.chart, s);
      if (refK) {
        const next = nearestKByX(lastPayload.chart.kline.filter((k) => k.x > refK.x), refK.x + 1);
        if (next) {
          crosshairX = s.x(next.x);
          crosshairY = s.y(next.c);
          draw(lastPayload.chart);
        }
      }
      return;
    }
    viewXMin = viewXMin + shift;
    viewXMax = viewXMax + shift;
    userAdjustedView = true;
    draw(lastPayload.chart);
  }
});

let msgHistory = ensureArray(safeJsonParse(storageGet("chan_msg_history"), []), []);
let lastToastText = "";
let lastToastAt = 0;

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
}

function setMsg(text, quiet = false) {
  appendMsgHistory(text);
  if (!quiet) showToast(text, { record: false });
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

function showMsgHistory() {
  const list = $("msgHistoryList");
  list.innerHTML = "";
  msgHistory.slice().reverse().forEach(m => {
    const item = document.createElement("div");
    item.className = "msgHistoryItem";
    item.innerHTML = `<span class="time">[${m.time}]</span><span class="text">${m.text}</span>`;
    list.appendChild(item);
  });
  $("msgHistoryModal").classList.add("show");
}

$("btnMsgHistory").onclick = showMsgHistory;
$("btnMsgHistoryClose").onclick = () => $("msgHistoryModal").classList.remove("show");
$("btnMsgHistoryOk").onclick = () => $("msgHistoryModal").classList.remove("show");
$("btnMsgHistoryClear").onclick = () => {
  if (confirmAndLog("确定要清空所有消息历史记录吗？")) {
    msgHistory = [];
    storageRemove("chan_msg_history");
    $("msgHistoryList").innerHTML = "";
  }
};

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
  const posPnlRaw = a.position > 0 && price !== null ? (price - a.avg_cost) * a.position : 0;
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
  if (!payload || !payload.ready || !payload.account || payload.account.position <= 0) {
    overlay.style.display = "none";
    return;
  }

  const a = payload.account;
  const price = payload.price;
  const buyX = activeTrade ? activeTrade.buyX : null;
  const lastX = payload.chart.kline[payload.chart.kline.length - 1].x;
  const holdBars = buyX !== null ? (lastX - buyX) : 0;
  const pnlRaw = (price - a.avg_cost) * a.position;
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
  setText("ts_buy_price", a.avg_cost.toFixed(4));
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

function nearestKByX(ks, targetX) {
  if (!ks || ks.length === 0) return null;
  return ks.reduce((best, cur) => {
    return Math.abs(cur.x - targetX) < Math.abs(best.x - targetX) ? cur : best;
  }, ks[0]);
}

function getChipBaseKs(chart) {
  // Use full history K-lines for chip distribution.
  // Accumulation cutoff is controlled by reference K (crosshair/latest), not by replay step.
  return (chart.kline_all && chart.kline_all.length > 0) ? chart.kline_all : (chart.kline || []);
}

function getReferenceKByBounds(chart, xMin, xMax, w) {
  const ksAll = getChipBaseKs(chart);
  if (ksAll.length === 0) return null;
  if (!crosshairEnabled || crosshairX === null) return ksAll[ksAll.length - 1];
  const plotW = Math.max(1, w - PAD_L - PAD_R);
  const clampedX = Math.max(PAD_L, Math.min(w - PAD_R, crosshairX));
  const targetX = xMin + ((clampedX - PAD_L) / plotW) * (xMax - xMin);
  const visibleKs = getVisibleKs(chart, xMin, xMax).filter((k) => k.x <= ksAll[ksAll.length - 1].x);
  return nearestKByX(visibleKs.length > 0 ? visibleKs : ksAll, targetX) || ksAll[ksAll.length - 1];
}

function getReferenceK(chart, s) {
  return getReferenceKByBounds(chart, s.xMin, s.xMax, s.w);
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

function toScaler(chart, xMin, xMax) {
  const { w, h } = readCanvasCssSize(canvas);

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
      if (!isRhythmLevelEnabled(rl.level)) continue;
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

  const totalChartH = h - PAD_T - PAD_B;
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
  const plotBottomY = h - PAD_B - totalSubH;
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
  const refK = getReferenceK(chart, s);
  if (!refK) return;
  const x = s.x(refK.x);
  const y = Math.max(PAD_T, Math.min(s.contentBottom, crosshairY));
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

function drawChips(chart, s) {
  if (!chartConfig.chip.enabled) return;
  const ksAll = getChipBaseKs(chart);
  const visibleKs = s.visibleK || [];
  const latestVisibleK = visibleKs.length > 0 ? visibleKs[visibleKs.length - 1] : ((chart.kline && chart.kline.length > 0) ? chart.kline[chart.kline.length - 1] : null);
  const crossRefK = (crosshairEnabled && crosshairX !== null && canvasHovered) ? getReferenceK(chart, s) : null;
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
  let refK = crossRefK;
  if (!refK) {
    if (refMode === "seg_turn") refK = getTurnRef("seg");
    else if (refMode === "bi_turn") refK = getTurnRef("bi");
    if (!refK) refK = latestVisibleK || (ksAll.length > 0 ? ksAll[ksAll.length - 1] : null);
  }
  const refText = `日期:${refK?.t || "-"}`;
  if (ksAll.length === 0 || !refK) return;
  const priceStep = chartConfig.chip.bucketStep || 0.1;
  const stepMul = 1 / priceStep;
  // Cutoff by date/time (stable across different x indexing bases)
  const refT = String(refK.t || "");
  const useKs = refT ? ksAll.filter((k) => String(k.t || "") <= refT) : ksAll;

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
  const arr = new Array(tickCount).fill(0);

  for (const k of useKs) {
    const tickBins = k.chip_tick_bins;
    if (tickBins && Array.isArray(tickBins.p) && Array.isArray(tickBins.w) && tickBins.p.length === tickBins.w.length) {
      for (let j = 0; j < tickBins.p.length; j++) {
        const p = Number(tickBins.p[j]);
        const w = Number(tickBins.w[j]);
        if (!Number.isFinite(p) || !Number.isFinite(w) || w <= 0) continue;
        const bi = Math.floor(p * stepMul);
        if (bi < minTick || bi > maxTick) continue;
        arr[bi - minTick] += w;
      }
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
      arr[i0 - minTick] += vol;
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
      arr[t - minTick] += (w / sumW) * vol;
    }
  }

  // Visual-only stretch (monotonic): keep all historical chips unchanged,
  // only amplify contrast on rendering.
  const stretchExp = getChipStretchExponent();
  const stretchVol = (v) => Math.pow(Math.max(0, v), stretchExp);
  let maxVVisible = 0;
  for (let i = 0; i < tickCount; i++) {
    const p = (minTick + i) / stepMul;
    const v = stretchVol(arr[i]);
    if (p < s.yMin || p > s.yMax) continue;
    if (v > maxVVisible) maxVVisible = v;
  }
  if (maxVVisible <= 0) return;
  const chipW = Math.max(96, Math.min(220, s.plotW * 0.2));
  const xR = s.w - PAD_R - 2;
  const xL = xR - chipW;
  const fill = getCfgColor(chartConfig.chip.color);
  const bg = cssVar("--chipBg", "rgba(148,163,184,0.12)");
  const edge = cssVar("--chipEdge", "rgba(59,130,246,0.75)");

  ctx.save();
  ctx.fillStyle = bg;
  ctx.fillRect(xL, PAD_T, chipW, s.plotBottomY - PAD_T);
  for (let i = 0; i < tickCount; i++) {
    const vRaw = arr[i];
    const v = stretchVol(vRaw);
    if (v <= 0) continue;
    const p = (minTick + i) / stepMul;
    if (p < s.yMin || p > s.yMax) continue;
    const len = (v / maxVVisible) * chipW;
    const yTop = s.y(p + priceStep);
    const yBot = s.y(p);
    const h = Math.max(1, yBot - yTop);
    ctx.fillStyle = fill;
    ctx.fillRect(xR - len, yTop, len, h);
  }
  ctx.strokeStyle = edge;
  ctx.lineWidth = 1;
  ctx.strokeRect(xL, PAD_T, chipW, s.plotBottomY - PAD_T);
  ctx.fillStyle = cssVar("--legendText", "#0f172a");
  ctx.font = "12px Consolas";
  ctx.fillText(`筹码(${refText})`, xL + 6, PAD_T + 14);
  const peaks = [];
  for (let i = 1; i < tickCount - 1; i++) {
    const cur = arr[i];
    if (!(cur > arr[i - 1] && cur > arr[i + 1])) continue;
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

function drawCandles(chart, s) {
  const ks = s.visibleK;
  const bodyW = Math.max(3, (s.plotW) / Math.max(42, ks.length * 1.28));
  const upS = getCfgColor(chartConfig.candle.upColor);
  const dnS = getCfgColor(chartConfig.candle.downColor);
  const upF = cssVar("--candleUpFill", "rgba(239,68,68,0.12)");
  const dnF = cssVar("--candleDownFill", "rgba(34,197,94,0.75)");
  for (const k of ks) {
    const x = s.x(k.x);
    const yo = s.y(k.o),
      yc = s.y(k.c),
      yh = s.y(k.h),
      yl = s.y(k.l);
    const up = k.c >= k.o;
    ctx.strokeStyle = up ? upS : dnS;
    ctx.fillStyle = up ? upF : dnF;
    ctx.lineWidth = chartConfig.candle.width;

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
}

function drawKlineCombineFrames(chart, s) {
  if (!chartConfig.klineCombineFrame || chartConfig.klineCombineFrame.enabled === false) return;
  const frames = Array.isArray(chart.kline_combine) ? chart.kline_combine : [];
  if (frames.length === 0) return;
  ctx.save();
  ctx.strokeStyle = getCfgColor(chartConfig.klineCombineFrame.color || "#6366f1");
  ctx.lineWidth = Number(chartConfig.klineCombineFrame.lineWidth || 1.2);
  ctx.setLineDash(getTradeLineDash(chartConfig.klineCombineFrame.lineStyle || "solid"));
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
  const lines = [
    { label: "分型辅助线", color: getCfgColor(chartConfig.fx.color), dashed: true, w: chartConfig.fx.width },
    { label: "分型(确定)", color: getCfgColor(chartConfig.fract.color), dashed: false, w: chartConfig.fract.widthSure },
    { label: "分型(未完成)", color: getCfgColor(chartConfig.fract.color), dashed: true, w: chartConfig.fract.widthUnsure },
    { label: "笔(确定)", color: getCfgColor(chartConfig.bi.color), dashed: false, w: chartConfig.bi.widthSure },
    { label: "笔(未完成)", color: getCfgColor(chartConfig.bi.color), dashed: true, w: chartConfig.bi.widthUnsure },
    { label: "段(确定)", color: getCfgColor(chartConfig.seg.color), dashed: false, w: chartConfig.seg.widthSure },
    { label: "段(未完成)", color: getCfgColor(chartConfig.seg.color), dashed: true, w: chartConfig.seg.widthUnsure },
    { label: "2段(确定)", color: getCfgColor(chartConfig.segseg.color), dashed: false, w: chartConfig.segseg.widthSure },
    { label: "2段(未完成)", color: getCfgColor(chartConfig.segseg.color), dashed: true, w: chartConfig.segseg.widthUnsure },
    { label: "节奏线1", color: getRhythmVisualConfig("rhythm1").lineColor, dashed: getRhythmVisualConfig("rhythm1").lineStyle !== "solid", w: getRhythmVisualConfig("rhythm1").lineWidth },
    { label: "节奏线2", color: getRhythmVisualConfig("rhythm2").lineColor, dashed: getRhythmVisualConfig("rhythm2").lineStyle !== "solid", w: getRhythmVisualConfig("rhythm2").lineWidth },
    { label: "节奏线3", color: getRhythmVisualConfig("rhythm3").lineColor, dashed: getRhythmVisualConfig("rhythm3").lineStyle !== "solid", w: getRhythmVisualConfig("rhythm3").lineWidth },
    { label: "节奏线4", color: getRhythmVisualConfig("rhythm4").lineColor, dashed: getRhythmVisualConfig("rhythm4").lineStyle !== "solid", w: getRhythmVisualConfig("rhythm4").lineWidth },
    { label: "节奏线5", color: getRhythmVisualConfig("rhythm5").lineColor, dashed: getRhythmVisualConfig("rhythm5").lineStyle !== "solid", w: getRhythmVisualConfig("rhythm5").lineWidth },
  ];
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
  const fillHoldBackground = (x1, x2, color, alphaMul) => {
    if (x1 == null || x2 == null) return;
    const lo = Math.min(x1, x2);
    const hi = Math.max(x1, x2);
    if (hi < s.xMin || lo > s.xMax) return;
    const xa = s.x(lo);
    const xb = s.x(hi);
    ctx.save();
    ctx.fillStyle = color;
    ctx.globalAlpha = alphaMul;
    ctx.fillRect(Math.min(xa, xb), PAD_T, Math.abs(xb - xa), s.plotBottomY - PAD_T);
    ctx.restore();
  };

  const fillPnlBand = (x1, x2, buyPrice, endPrice) => {
    if (x1 == null || x2 == null || buyPrice == null || endPrice == null) return;
    const lo = Math.min(x1, x2);
    const hi = Math.max(x1, x2);
    if (hi < s.xMin || lo > s.xMax) return;
    const xa = s.x(lo);
    const xb = s.x(hi);
    const yBuy = s.y(buyPrice);
    const yEnd = s.y(endPrice);
    const top = Math.min(yBuy, yEnd);
    const height = Math.max(1, Math.abs(yEnd - yBuy));
    const isProfit = endPrice >= buyPrice;
    const pnlColor = isProfit ? getCfgColor(chartConfig.trade.profitBandColor) : getCfgColor(chartConfig.trade.lossBandColor);
    ctx.save();
    ctx.fillStyle = pnlColor;
    ctx.globalAlpha = 0.28;
    ctx.fillRect(Math.min(xa, xb), top, Math.abs(xb - xa), height);
    ctx.restore();
  };

  for (const tr of tradeHistory) {
    if (tr.buyX != null && tr.sellX != null) {
      fillHoldBackground(tr.buyX, tr.sellX, getCfgColor(chartConfig.trade.rangeFillSell), 0.11);
      fillPnlBand(tr.buyX, tr.sellX, tr.buyPrice, tr.sellPrice);
    }
  }
  if (lastPayload.account.position > 0 && activeTrade && activeTrade.buyX != null) {
    fillHoldBackground(activeTrade.buyX, lastX, getCfgColor(chartConfig.trade.rangeFillBuy), 0.11);
    fillPnlBand(activeTrade.buyX, lastX, activeTrade.buyPrice, lastPayload.price);
  }
}

function drawTradeMarkers(s, chart) {
  if (!lastPayload || !lastPayload.ready) return;
  const buyC = getCfgColor(chartConfig.trade.buyColor);
  const sellC = getCfgColor(chartConfig.trade.sellColor);

  const mark = (xBar, color, tag) => {
    if (xBar < s.xMin || xBar > s.xMax) return;
    const xp = s.x(xBar);
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
    ctx.font = `${chartConfig.trade.markerFontWeight || "bold"} ${chartConfig.trade.markerFontSize}px Consolas`;
    ctx.textAlign = "center";
    ctx.fillText(tag, xp, s.plotBottomY + 18);
    ctx.restore();
  };

  for (const tr of tradeHistory) {
    if (tr.buyX != null) mark(tr.buyX, buyC, "买");
    if (tr.sellX != null) mark(tr.sellX, sellC, "卖");
  }
  if (lastPayload.account.position > 0 && activeTrade && activeTrade.buyX != null) {
    mark(activeTrade.buyX, buyC, "买");
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
  }
  if (activeTrade && activeTrade.buyX != null && activeTrade.buyPrice != null) {
    const rightTo = Math.max(s.xMax, activeTrade.buyX + 1);
    drawRay(activeTrade.buyX, activeTrade.buyPrice, rightTo, rayBuy, chartConfig.trade.buyCloseLineStyle || "solid");
  }
}

function drawIndicators(chart, s) {
  if (!chart || !chart.indicators || chart.indicators.length === 0) return;
  const visibleInd = s.visibleInd || [];
  if (visibleInd.length === 0) return;
  
  const theme = document.documentElement.getAttribute("data-theme") || "light";
  const lineMain = theme === "light" ? "#1e293b" : "#f8fafc";
  const mainTypeSet = new Set((s.mainTypes || []).map((m) => m.type));

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
  for (const panel of s.subPanels || []) drawSubPanel(panel);
}

function drawBsp(arr, s) {
  return drawBottomSignals({ bsp: arr || [], rhythm: [] }, s);
}

function drawRhythmLines(arr, s) {
  if (!chartConfig.rhythmLine || !chartConfig.rhythmLine.enabled) return;
  // 自定义术语说明：
  // - “推进峰值端点”指与父结构同向推进的子级端点（上升时对应 D/F/H...）。
  // - line.label_left 是节奏线编号，例如 2_1。
  // - line.label_right 是该线复用的回调比例，例如 0.618。
  for (const line of arr || []) {
    if (!line || !isRhythmLevelEnabled(line.level)) continue;
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
    const bspCfg = getBspConfig(p.level);
    const prefix = p.status === "correct" ? "✓" : (p.status === "wrong" ? "×" : "·");
    const text = `${prefix} ${getBspDisplayLabel(p)}`;
    const levelPriority = p.level === "segseg" ? 0 : (p.level === "seg" ? 1 : 2);
    const statusPriority = p.status === "correct" ? 0 : (p.status === "wrong" ? 1 : 2);
    push(Number(p.x), {
      kind: "bsp",
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
    });
  }
  return groups;
}

function drawBottomSignals(chart, s) {
  signalHoverBoxes = [];
  const groups = buildBottomSignalGroups(chart, bspHistory || []);
  const xs = Object.keys(groups).map((x) => Number(x)).filter((x) => x >= s.xMin && x <= s.xMax).sort((a, b) => a - b);
  const boxGap = 4;
  const boxPadX = 8;
  const boxPadY = 5;
  const overflowLimit = 6;
  const byX = new Map((s.visibleK || []).map((k) => [k.x, k]));

  for (const x of xs) {
    const xp = s.x(x);
    const items = (groups[x] || []).slice().sort((a, b) => (a.priority - b.priority) || (a.sortKey - b.sortKey) || String(a.text).localeCompare(String(b.text)));
    const groupTip = items.map((item) => item.tipText || item.text).join("\n");
    let renderItems = items.slice();
    if (items.length > overflowLimit) {
      renderItems = items.slice(0, Math.max(0, overflowLimit - 1));
      renderItems.push({
        kind: "overflow",
        priority: 999,
        sortKey: 999,
        text: "!",
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
      });
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
      if (k) {
        const anchorY = s.y(k.l);
        const toY = Math.max(PAD_T + 2, Math.min(s.h - PAD_B + 8, rectY - 6));
        ctx.save();
        ctx.lineWidth = Number(item.lineWidth || 1);
        ctx.setLineDash(getTradeLineDash(item.lineStyle || "dashed"));
        ctx.strokeStyle = item.lineColor;
        ctx.beginPath();
        ctx.moveTo(xp, anchorY);
        ctx.lineTo(xp, toY);
        ctx.stroke();
        ctx.restore();
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

function drawUserBiRays(s, chart) {
  if (!userBiRays || userBiRays.length === 0) return;
  ctx.save();
  // 同上：需要跳过当前回调时统一使用 return，避免继续踩到 JS 语法坑。
  userBiRays.forEach((r, idx) => {
    ctx.lineWidth = getRayLineWidth(r);
    ctx.strokeStyle = getRayLineColor(r);
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
  if (!pendingBiRayPts || pendingBiRayPts.length !== 1) return;
  const pt = pendingBiRayPts[0];
  if (!pt || !Number.isFinite(pt.x) || !Number.isFinite(pt.y)) return;
  const xp = s.x(pt.x);
  const yp = s.y(pt.y);
  if (!Number.isFinite(xp) || !Number.isFinite(yp)) return;
  ctx.save();
  ctx.beginPath();
  ctx.arc(xp, yp, 10, 0, Math.PI * 2);
  ctx.strokeStyle = "#2563eb";
  ctx.lineWidth = 2;
  ctx.setLineDash([]);
  ctx.stroke();
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
  drawCandles(chart, s);
  drawKlineCombineFrames(chart, s);
  if (chartConfig.fractZs.enabled) {
    drawZsRects(chart.fract_zs || [], s, getCfgColor(chartConfig.fractZs.color), chartConfig.fractZs.width);
  }
  if (chartConfig.biZs.enabled) {
    drawZsRects(chart.bi_zs || [], s, getCfgColor(chartConfig.biZs.color), chartConfig.biZs.width);
  }
  if (chartConfig.segZs.enabled) {
    drawZsRects(chart.seg_zs || [], s, getCfgColor(chartConfig.segZs.color), chartConfig.segZs.width);
  }
  if (chartConfig.segsegZs.enabled) {
    drawZsRects(chart.segseg_zs || [], s, getCfgColor(chartConfig.segsegZs.color), chartConfig.segsegZs.width);
  }
  // 分型辅助线最细虚线 → 分型 → 笔 → 段 → 2段
  drawLines(chart.fx_lines || [], s, getCfgColor(chartConfig.fx.color), chartConfig.fx.width, true);
  drawLines((chart.fract || []).filter((x) => x.is_sure), s, getCfgColor(chartConfig.fract.color), chartConfig.fract.widthSure, false);
  drawLines((chart.fract || []).filter((x) => !x.is_sure), s, getCfgColor(chartConfig.fract.color), chartConfig.fract.widthUnsure, true);
  drawLines((chart.bi || []).filter((x) => x.is_sure), s, getCfgColor(chartConfig.bi.color), chartConfig.bi.widthSure, false);
  drawLines((chart.bi || []).filter((x) => !x.is_sure), s, getCfgColor(chartConfig.bi.color), chartConfig.bi.widthUnsure, true);
  drawLines((chart.seg || []).filter((x) => x.is_sure), s, getCfgColor(chartConfig.seg.color), chartConfig.seg.widthSure, false);
  drawLines((chart.seg || []).filter((x) => !x.is_sure), s, getCfgColor(chartConfig.seg.color), chartConfig.seg.widthUnsure, true);
  drawLines((chart.segseg || []).filter((x) => x.is_sure), s, getCfgColor(chartConfig.segseg.color), chartConfig.segseg.widthSure, false);
  drawLines((chart.segseg || []).filter((x) => !x.is_sure), s, getCfgColor(chartConfig.segseg.color), chartConfig.segseg.widthUnsure, true);
  drawRhythmLines(chart.rhythm_lines || [], s);
  drawBottomSignals(chart, s);
  drawUserRays(s);
  drawUserBiRays(s, chart);
  drawPendingBiEndpointCircle(s);
  drawTradeMarkers(s, chart);
  drawCrosshair(chart, s);
  drawLegend();
}

function parseChartTimeToMs(text) {
  const raw = String(text || "").trim();
  if (!raw) return NaN;
  const normalized = raw.replace(/\//g, "-");
  const dt = new Date(normalized);
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
  const prevCanvas = canvas;
  const prevCtx = ctx;
  const temp = document.createElement("canvas");
  temp.width = Math.max(1, Math.round((prevCanvas.clientWidth || 1) * window.devicePixelRatio));
  temp.height = Math.max(1, Math.round((prevCanvas.clientHeight || 1) * window.devicePixelRatio));
  temp.style.width = `${Math.max(1, prevCanvas.clientWidth || 1)}px`;
  temp.style.height = `${Math.max(1, prevCanvas.clientHeight || 1)}px`;
  canvas = temp;
  ctx = temp.getContext("2d");
  if (!ctx) {
    canvas = prevCanvas;
    ctx = prevCtx;
    return;
  }
  loadRuntimeState(activeId);
  const sActive = toScaler(activeChart, Math.max(allXMin, viewXMin), viewXMax);
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
    const s = toScaler(chart, Math.max(allXMin, viewXMin), viewXMax);
    const nk = findNearestKByTime(chart, anchorTime);
    if (nk) {
      st.crosshairX = s.x(nk.x);
      if (!Number.isFinite(st.crosshairY)) st.crosshairY = s.y(nk.c);
    }
  });
  canvas = prevCanvas;
  ctx = prevCtx;
  loadRuntimeState(activeId);
}

function drawDualCharts(payload) {
  if (!payload || !payload.charts || !payload.charts.chart1 || !payload.charts.chart2) {
    draw(payload && payload.chart ? payload.chart : null);
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

async function api(path, body, method = "POST") {
  const options = {
    method,
    headers: {"Content-Type": "application/json"}
  };
  if (body !== null && body !== undefined) options.body = JSON.stringify(body);
  const res = await fetch(path, options);
  const data = await res.json();
  if (!res.ok) {
    const err = new Error(
      typeof data.detail === "string" ? data.detail : (data.detail && data.detail.reason_detail) || JSON.stringify(data.detail || data)
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
  const bspNotice = isBspJudgeManual() ? null : detectBspPromptOnLastBar(payload);
  const noticeText = buildStepNoticeText(payload, bspNotice);
  refreshUI(payload, { afterStep: true, showStandaloneNotices: false });
  const noticeShown = showCombinedNotice(noticeText);
  if (logMessage && !noticeShown) setMsg(payload.message || "步进成功");
  const reachedEnd = prevStepIdx !== null && Number(payload.step_idx) === prevStepIdx;
  return { payload, interrupted: !!bspNotice, reachedEnd, noticeShown };
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
  const content = $("leftContent");
  if (!left || !content) return;
  content.style.transform = "scale(1)";
  content.style.width = "100%";
  left.classList.remove("compact");
  const available = Math.max(100, left.clientHeight - 4);
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

function refreshUI(payload, options) {
  const afterStep = options && options.afterStep;
  const showStandaloneNotices = options && Object.prototype.hasOwnProperty.call(options, "showStandaloneNotices")
    ? !!options.showStandaloneNotices
    : !afterStep;
  const prev = lastPayload;
  // 后端在步进等接口省略 kline_all，避免 1 分钟全量重复 JSON 导致超时/断连（浏览器报 Failed to fetch）；此处沿用上一包全历史供筹码用。
  if (
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
    }
  }
  if (payload && payload.ready && payload.charts && typeof payload.charts === "object") {
    const activeId = String(payload.active_chart_id || "chart1") === "chart2" ? "chart2" : "chart1";
    sessionConfig.activeChartId = activeId;
    dualActiveChartId = activeId;
    if (payload.charts[activeId]) payload.chart = payload.charts[activeId];
    else if (payload.charts.chart1) payload.chart = payload.charts.chart1;
  }
  lastPayload = payload;
  updateDualModeUI(payload);
  if (payload && payload.ready && payload.data_form) {
    dataFormConfig.mode = normalizeDataFormMode(payload.data_form.mode);
    dataFormConfig.quantity = clampDataFormQuantity(payload.data_form.quantity, payload.data_form.raw_count || payload.data_form.current_count || 1);
  } else if (!payload || !payload.ready) {
    dataFormConfig = { ...DATA_FORM_DEFAULT };
  }
  sessionFinished = !!payload.finished;
  syncTradesFromPayload(payload);
  syncIndicatorControls();
  if (payload.ready && Array.isArray(payload.bsp_history)) {
    bspHistory = payload.bsp_history.slice();
    bspHistoryKey = new Set(bspHistory.map((p) => p.key || `${p.level}|${p.x}|${p.label}|${p.is_buy ? 1 : 0}`));
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
        if (afterStep) ensureLatestKVisible();
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
  $("btnBuy").disabled = !payload.ready || sessionFinished || payload.price === null || payload.account.position > 0;
  $("btnSell").disabled = !payload.ready || sessionFinished || !payload.account.can_sell;
  $("configCard").classList.toggle("collapsed", payload.ready);
  updateBspJudgeUI();
  requestAnimationFrame(updateCompactLayout);
}

$("btnInit").onclick = async () => {
  const initBtn = $("btnInit");
  if (initBtn.disabled) return;
  let initSucceeded = false;
  const initBtnHtml = initBtn.innerHTML;
  setGlobalLoading(true, "正在加载会话，首次加载历史数据可能需要约 30-40 秒，请稍候...");
  setMsg("正在加载会话...");
  initBtn.disabled = true;
  initBtn.innerHTML = "加载中...";
  try {
    const processedConfig = JSON.parse(JSON.stringify(chanConfig));
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
      active_chart_id: (sessionConfig && sessionConfig.activeChartId) ? sessionConfig.activeChartId : "chart1",
      data_form_mode: normalizeDataFormMode(dataFormConfig.mode),
      data_form_quantity: clampDataFormQuantity(dataFormConfig.quantity, getRawKlineCount() || 1),
      ...extra,
    });
    let payload;
    try {
      payload = await api("/api/init", buildInitBody({}));
    } catch (e) {
      if (e.offlineConfirm && Number(e.httpStatus) === 409) {
        const oc = e.offlineConfirm;
        const tip = `${oc.display_code}使用${oc.failed_label}获取数据失败，原因为【${oc.reason_tag}】是否使用离线数据继续获取？`;
        if (confirmAndLog(tip)) {
          payload = await api("/api/init", buildInitBody({ confirm_offline: true }));
        } else {
          let p = (systemConfig.dataSourcePriority || []).filter((x) => x !== "离线数据");
          if (!p.length) {
            p = DEFAULT_SYSTEM_CONFIG.dataSourcePriority.filter((x) => x !== "离线数据");
          }
          payload = await api("/api/init", buildInitBody({ data_source_priority: p }));
        }
      } else {
        throw e;
      }
    }
    initSucceeded = true;
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
    activeTrade = null;
    tradeHistory = [];
    bspHistory = [];
    bspHistoryKey = new Set();
    lastSeenBspKey = new Set();
    sessionFinished = false;
    stepInFlight = false;
    clearBspPrompt();
    refreshUI(payload);
  } catch (e) {
    setMsg("加载失败：" + e.message);
  } finally {
    if (!initSucceeded) {
      initBtn.disabled = false;
      initBtn.innerHTML = initBtnHtml;
      updateShortcutUI();
    }
    hideGlobalLoading();
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
  let done = 0;
  let lastResult = null;
  stepInFlight = true;
  syncStepButtonState();
  hideGlobalLoading();
  try {
    for (let i = 0; i < n; i++) {
      const result = await stepOnce(false);
      lastResult = result;
      done += 1;
      if (result.interrupted || result.reachedEnd) break;
    }
    if (!lastResult || !lastResult.noticeShown) {
      setMsg(`步进N（${done}）根完成`);
    }
  } catch (e) {
    setMsg("步进 N 失败：" + e.message);
  } finally {
    stepInFlight = false;
    syncStepButtonState();
  }
};

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
markUiBound("btnInit");
markUiBound("btnStep");
markUiBound("btnStepN");
markUiBound("btnBackN");
markUiBound("btnBuy");
markUiBound("btnSell");

if ($("chartMode")) {
  $("chartMode").addEventListener("change", () => {
    updateDualModeUI();
    saveSessionConfig();
  });
}
if ($("kType2")) {
  $("kType2").addEventListener("change", () => saveSessionConfig());
}
if ($("dualLayout")) {
  $("dualLayout").addEventListener("change", () => {
    saveSessionConfig();
    redrawCurrentPayload();
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
  if (!confirmAndLog("确定要结束当前训练吗？")) return;
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
  if (!confirmAndLog("确定要重新训练吗？当前会话状态将被清空。")) return;
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
    lastPayload = null;
    dataFormConfig = { ...DATA_FORM_DEFAULT };
    sessionFinished = false;
    stepInFlight = false;
    userAdjustedView = false;
    viewReady = false;
    viewYShiftRatio = 0;
    viewYZoomRatio = 1.0;
    DUAL_CHART_IDS.forEach((cid) => {
      dualChartRuntime[cid] = { allXMin: 0, allXMax: 0, viewXMin: 0, viewXMax: 0, viewReady: false, userAdjustedView: false, viewYShiftRatio: 0, viewYZoomRatio: 1, crosshairX: null, crosshairY: null };
    });
    dualActiveChartId = "chart1";
    clearBspPrompt();
    setState(payload);
    updateDataSourceStatus(payload);
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


APP_STATE = AppState()
APP_STOCK_NAME: Optional[str] = None


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield
    CBaoStock.do_close()


app = FastAPI(title="chan.py replay trainer", lifespan=lifespan)


@app.get("/", response_class=HTMLResponse)
def index():
    return HTML


@app.post("/api/init")
def api_init(req: InitReq):
    try:
        autype_map = {"qfq": AUTYPE.QFQ, "hfq": AUTYPE.HFQ, "none": AUTYPE.NONE}
        autype = autype_map.get(req.autype.lower(), AUTYPE.QFQ)
        if req.initial_cash <= 0:
            raise ValueError("初始资金必须大于0")
        code_norm = normalize_code(req.code)

        try:
            APP_STATE.stepper.init(
                code_norm,
                req.begin_date,
                req.end_date,
                autype,
                chan_config=req.chan_config,
                k_type=req.k_type,
                confirm_offline=bool(req.confirm_offline),
                data_source_priority=req.data_source_priority,
                data_form_mode=req.data_form_mode,
                data_form_quantity=req.data_form_quantity,
            )
            chart_mode = "dual" if str(req.chart_mode or "single").strip().lower() == "dual" else "single"
            APP_STATE.chart_mode = chart_mode
            APP_STATE.active_chart_id = "chart2" if (chart_mode == "dual" and str(req.active_chart_id or "").strip().lower() == "chart2") else "chart1"
            APP_STATE.stepper2 = None
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
                    confirm_offline=bool(req.confirm_offline),
                    data_source_priority=req.data_source_priority,
                    data_form_mode=req.data_form_mode,
                    data_form_quantity=req.data_form_quantity,
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
        APP_STATE.session_params = {
            "code": code_norm,
            "begin_date": req.begin_date,
            "end_date": req.end_date,
            "autype": autype,
            "initial_cash": req.initial_cash,
            "chan_config": req.chan_config,
            "k_type": req.k_type,  # 保存周期类型到会话参数
            "chart_mode": APP_STATE.chart_mode,
            "k_type_2": req.k_type_2,
            "active_chart_id": APP_STATE.active_chart_id,
            # 与 ChanStepper.init 的 session_key 一致，供 reconfig/back_n 重建时命中 K 线缓存、避免重复联网
            "confirm_offline": bool(req.confirm_offline),
            "data_source_priority": req.data_source_priority,
            "data_form_mode": normalize_data_form_mode(req.data_form_mode),
            "data_form_quantity": req.data_form_quantity,
        }
        APP_STATE.trade_events = []
        APP_STATE.bsp_history = []
        APP_STATE._reset_rhythm_history()
        APP_STATE.bsp_judge_logs = []
        APP_STATE._last_level_dirs = {level: None for level in set(JUDGE_TRIGGER_LEVELS.values())}
        # init后先推进一根，确保前端有可视数据并可交互
        APP_STATE.rebuild_bsp_all_snapshot()
        APP_STATE.stepper.step()
        if APP_STATE.chart_mode == "dual" and APP_STATE.stepper2 is not None:
            APP_STATE.stepper2.step()
            APP_STATE._sync_stepper_to_anchor(APP_STATE.stepper2, APP_STATE.stepper.current_time())
        APP_STATE.sync_bsp_history()
        APP_STATE.sync_rhythm_history()
        APP_STATE._rhythm_notice_hits = []
        APP_STATE.after_step_update()
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
        source_label = data_source_label(APP_STATE.stepper.data_src_used)
        mode_desc = f"双周期({req.k_type}/{(req.k_type_2 or req.k_type)})" if APP_STATE.chart_mode == "dual" else f"单周期({req.k_type})"
        if source_label in ("AKShare", "离线数据"):
            payload["message"] = f"加载成功：{APP_STOCK_NAME or code_norm}，当前数据源 {source_label}，{mode_desc}。"
        else:
            payload["message"] = f"加载成功：{APP_STOCK_NAME or code_norm}，已自动切换到 {source_label}，{mode_desc}。"
        return payload
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/reconfig")
def api_reconfig(req: ReconfigReq):
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    try:
        APP_STATE.reconfig(
            req.chan_config,
            data_form_mode=req.data_form_mode,
            data_form_quantity=req.data_form_quantity,
        )
        APP_STATE._rhythm_notice_hits = []
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
        payload["message"] = "配置更新成功，已按新逻辑重新计算并清除模拟持仓。"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/step")
def api_step(req: StepReq):
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
    try:
        if req.active_chart_id:
            APP_STATE.active_chart_id = APP_STATE._normalize_chart_id(req.active_chart_id)
        active_stepper = APP_STATE.get_active_stepper()
        passive_stepper = APP_STATE.get_passive_stepper()
        ok = active_stepper.step()
        if passive_stepper is not None and ok:
            APP_STATE._sync_stepper_to_anchor(passive_stepper, active_stepper.current_time())
        APP_STATE.sync_bsp_history()
        APP_STATE.sync_rhythm_history()
        mode = (req.judge_mode or "auto").lower().strip()
        if mode != "manual":
            APP_STATE.after_step_update()
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME, include_kline_all=False)
        payload["message"] = "已到最后一根K线" if not ok else "步进成功"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


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
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/buy")
def api_buy():
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
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
        payload["message"] = f"买入成功：{json.dumps(detail, ensure_ascii=False)}"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/sell")
def api_sell():
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
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
        payload["message"] = f"卖出结果：{json.dumps(detail, ensure_ascii=False)}"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/back_n")
def api_back_n(req: BackNReq):
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    try:
        n = int(req.n)
        if n < 1:
            raise ValueError("N 必须>=1")
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
                return {"ok": True, "name": name, "message": f"a_Data 下存在 {offline_folder_from_code(probe)} 离线包（1 分钟或分笔）"}
        return {"ok": False, "name": name, "message": "a_Data 下未发现 SH#000001 / SZ#000001 的 1 分钟或分笔数据"}
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
    APP_STATE._reset_rhythm_history()
    APP_STATE.bsp_all_snapshot = []
    APP_STATE.bsp_judge_logs = []
    APP_STATE._last_level_dirs = {level: None for level in set(JUDGE_TRIGGER_LEVELS.values())}
    APP_STATE._reset_judge_state()
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
    
    # 尝试检查并杀死占用 8000 端口的进程
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            if s.connect_ex(("127.0.0.1", 8000)) == 0:
                print("发现 8000 端口已被占用，尝试清理...")
                import subprocess
                # 在 Windows 下查找占用 8000 端口的 PID
                cmd = "netstat -ano | findstr :8000"
                res = subprocess.check_output(cmd, shell=True).decode()
                pids = set()
                for line in res.strip().split("\n"):
                    parts = line.split()
                    if len(parts) >= 5:
                        pids.add(parts[-1])
                for pid in pids:
                    if pid != "0":
                        print(f"终止进程 PID: {pid}")
                        subprocess.run(f"taskkill /F /PID {pid}", shell=True)
    except Exception as e:
        print(f"清理端口冲突时出错: {e}")

    uvicorn.run(app, host="127.0.0.1", port=8000)


