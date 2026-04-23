import copy
import json
import math
import re
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
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
DATA_SOURCE_CHAIN: list[tuple[str, Any]] = [
    ("AKShare", AKSHARE_INLINE_SRC),
    ("BaoStock", DATA_SRC.BAO_STOCK),
    ("Tushare", TUSHARE_INLINE_SRC),
]


def normalize_chan_algo(raw: Any) -> str:
    text = str(raw or CHAN_ALGO_CLASSIC).strip().lower()
    return CHAN_ALGO_NEW if text == CHAN_ALGO_NEW else CHAN_ALGO_CLASSIC


def data_source_label(data_src: Any) -> str:
    if data_src == DATA_SRC.AKSHARE or data_src == AKSHARE_INLINE_SRC:
        return "AKShare"
    if data_src == DATA_SRC.BAO_STOCK:
        return "BaoStock"
    if data_src == TUSHARE_INLINE_SRC:
        return "Tushare"
    if isinstance(data_src, DATA_SRC):
        return data_src.name
    return str(data_src)


def get_stock_api_cls(data_src: Any):
    if data_src == DATA_SRC.AKSHARE or data_src == AKSHARE_INLINE_SRC:
        return CAkshareInline
    if data_src == DATA_SRC.BAO_STOCK:
        return CBaoStock
    if data_src == TUSHARE_INLINE_SRC:
        return CTushareInline
    raise ValueError(f"unsupported data source: {data_src}")


def create_stock_api_instance(data_src: Any, code: str, begin_date: Optional[str], end_date: Optional[str], autype: AUTYPE) -> CCommonStockApi:
    api_cls = get_stock_api_cls(data_src)
    api_cls.do_init()
    try:
        return api_cls(code=code, k_type=KL_TYPE.K_DAY, begin_date=begin_date, end_date=end_date, autype=autype)
    except Exception:
        api_cls.do_close()
        raise


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
        # 会话级行情缓存：同一股票代码与日期区间下只拉取一次，缠论/BSP 配置变更时仅重算结构。
        self._data_session_key: Optional[tuple[Any, ...]] = None
        self._replay_klus_master: Optional[list] = None
        self.data_src_used: Any = None
        self.data_src_logs: list[str] = []
        self.stock_name: Optional[str] = None
        self.structure_bundle: Optional[ChanStructureBundle] = None
        self._bundle_cache_step_idx: Optional[int] = None

    def _cfg_without_chan_algo(self, cfg_dict: dict[str, Any]) -> dict[str, Any]:
        return {k: v for k, v in cfg_dict.items() if k != "chan_algo"}

    def _fetch_from_single_source(
        self,
        data_src: Any,
        begin_date: str,
        end_date: Optional[str],
        autype: AUTYPE,
        chan_cfg_dict: dict[str, Any],
    ) -> tuple[list, list[dict[str, Any]], Optional[str]]:
        cfg_fetch = CChanConfig({**chan_cfg_dict, "trigger_step": False})
        fetch_chan = ReplayDataChan(
            code=self.code,
            begin_time=begin_date,
            end_time=end_date,
            data_src=data_src,
            lv_list=[KL_TYPE.K_DAY],
            config=cfg_fetch,
            autype=autype,
        )
        replay_klus_master = copy.deepcopy(list(fetch_chan[0].klu_iter()))
        if not replay_klus_master:
            raise ValueError("未获取到任何日线数据")

        stock_name: Optional[str] = None
        try:
            api = create_stock_api_instance(data_src, self.code, begin_date, end_date, autype)
            stock_name = getattr(api, "name", None) or None
        except Exception:
            stock_name = None
        finally:
            try:
                get_stock_api_cls(data_src).do_close()
            except Exception:
                pass

        chip_begin_date = "1990-01-01"
        try:
            cfg_all = CChanConfig({**chan_cfg_dict, "trigger_step": False})
            chan_all = ReplayDataChan(
                code=self.code,
                begin_time=chip_begin_date,
                end_time=end_date,
                data_src=data_src,
                lv_list=[KL_TYPE.K_DAY],
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
    ) -> DataSourceSelection:
        logs: list[str] = []
        errors: list[str] = []
        for idx, (label, data_src) in enumerate(DATA_SOURCE_CHAIN):
            print(f"[DataSource] try {label} for {self.code} {begin_date} -> {end_date or 'latest'}")
            try:
                replay_klus_master, kline_all, stock_name = self._fetch_from_single_source(data_src, begin_date, end_date, autype, chan_cfg_dict)
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
            except Exception as exc:
                detail = format_source_error(exc)
                errors.append(f"{label} 失败：{detail}")
                logs.append(f"数据源尝试失败：{label}")
                print(f"[DataSource] failed {label}: {detail}")
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

    def init(self, code: str, begin_date: str, end_date: Optional[str], autype: AUTYPE, chan_config: Optional[dict[str, Any]] = None) -> None:
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
                    else:
                        cfg_dict[k] = v

        self.chan_algo = normalize_chan_algo(cfg_dict.get("chan_algo"))
        cfg_dict["chan_algo"] = self.chan_algo
        self.effective_cfg_dict = cfg_dict.copy()
        chan_cfg_dict = self._cfg_without_chan_algo(cfg_dict)
        cfg = CChanConfig(chan_cfg_dict)
        self.code = normalize_code(code)
        self.stock_name = None
        session_key = (self.code, begin_date, end_date, autype)
        cache_hit = session_key == self._data_session_key and self._replay_klus_master is not None

        if not cache_hit:
            selection = self._select_data_source_with_fallback(begin_date, end_date, autype, chan_cfg_dict)
            self._replay_klus_master = selection.replay_klus_master
            self.kline_all = selection.kline_all
            self.data_src_used = selection.data_src
            self.data_src_logs = list(selection.logs)
            self._data_session_key = session_key
            if selection.stock_name:
                self.stock_name = selection.stock_name
        else:
            if self.data_src_logs:
                self.data_src_logs = [f"沿用已缓存数据源：{data_source_label(self.data_src_used)}"]

        self.chan = ReplayChan(
            code=self.code,
            begin_time=begin_date,
            end_time=end_date,
            data_src=self.data_src_used or DATA_SRC.AKSHARE,
            lv_list=[KL_TYPE.K_DAY],
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


class ReconfigReq(BaseModel):
    chan_config: dict[str, Any]


class BackNReq(BaseModel):
    n: int = 1


class StepReq(BaseModel):
    judge_mode: Optional[str] = None  # "auto" | "manual"


class JudgeBspReq(BaseModel):
    reason: str = "manual_check"


class AppState:
    def __init__(self) -> None:
        self.stepper = ChanStepper()
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
            lv_list=[KL_TYPE.K_DAY],
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
        if self.stepper.chan is None:
            return None
        kl_list = self.stepper.chan[0]
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
        if self.stepper.chan is None:
            return []
        bundle = self.stepper.get_structure_bundle()
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
        if current_x is None or self.stepper.chan is None:
            return
        bundle = self.stepper.get_structure_bundle()
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
                "time": str(item.get("time", self.stepper.current_time())),
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
        self.stepper.init(
            params["code"],
            params["begin_date"],
            params["end_date"],
            params["autype"],
            chan_config=params.get("chan_config"),
        )
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
        self.sync_bsp_history()
        self.sync_rhythm_history()
        self.after_step_update()
        for _ in range(target_step):
            if not self.stepper.step():
                break
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

    def reconfig(self, chan_config: dict[str, Any]) -> None:
        if self.session_params is None:
            raise ValueError("当前无可重配会话")
        
        # 1. Update session params
        self.session_params["chan_config"] = chan_config
        
        # 2. Clear simulation data (trades and account)
        self.trade_events = []
        self.account.reset(self.session_params["initial_cash"])
        
        # 3. Rebuild to current step
        target_step = self.stepper.step_idx
        self.rebuild_to_step(target_step)

    def build_payload(self, stock_name: Optional[str] = None) -> dict[str, Any]:
        if not self.ready or self.stepper.chan is None:
            return {
                "ready": False,
                "finished": self.finished,
                "message": "请先加载会话",
            }
        rhythm_notice_hits = list(self._rhythm_notice_hits)
        self._rhythm_notice_hits = []
        bundle = self.stepper.get_structure_bundle()
        chart = serialize_chan(
            self.stepper.chan,
            self.stepper.indicator_history,
            self.stepper.trend_lines,
            chan_algo=self.stepper.chan_algo,
            bundle=bundle,
            kline_all=self.stepper.kline_all,
        )
        price: Optional[float] = None
        if len(chart.get("kline", [])) > 0:
            price = self.stepper.current_price()
        return {
            "ready": True,
            "finished": self.finished,
            "code": self.stepper.code,
            "name": stock_name,
            "data_source": {
                "label": data_source_label(self.stepper.data_src_used),
                "logs": list(self.stepper.data_src_logs),
            },
            "chan_algo": self.stepper.chan_algo,
            "step_idx": self.stepper.step_idx,
            "time": self.stepper.current_time(),
            "price": price,
            "chart": chart,
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


def serialize_chan(
    chan: CChan,
    indicator_history: list,
    trend_lines: list,
    *,
    chan_algo: str = CHAN_ALGO_CLASSIC,
    bundle: Optional[ChanStructureBundle] = None,
    kline_all: Optional[list[dict[str, Any]]] = None,
) -> dict[str, Any]:
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
    bsp_bi_arr = serialize_bsp_collection("bi", active_bundle.bs_point_lst)
    bsp_seg_arr = serialize_bsp_collection("seg", active_bundle.seg_bs_point_lst)
    bsp_segseg_arr = serialize_bsp_collection("segseg", active_bundle.segseg_bs_point_lst)
    bsp_arr = sorted(
        [*bsp_bi_arr, *bsp_seg_arr, *bsp_segseg_arr],
        key=lambda item: (int(item["x"]), LEVEL_ORDER.get(str(item["level"]), 999), int(not bool(item["is_buy"]))),
    )

    return {
        "kline": klu_arr,
        "kline_all": kline_all or [],
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
    }


RLD_DEFAULT_LV_LIST = [KL_TYPE.K_DAY, KL_TYPE.K_60M, KL_TYPE.K_15M]
RLD_LEVEL_LABELS = {
    KL_TYPE.K_YEAR: "年线",
    KL_TYPE.K_QUARTER: "季线",
    KL_TYPE.K_MON: "月线",
    KL_TYPE.K_WEEK: "周线",
    KL_TYPE.K_DAY: "日线",
    KL_TYPE.K_60M: "60分钟",
    KL_TYPE.K_30M: "30分钟",
    KL_TYPE.K_15M: "15分钟",
    KL_TYPE.K_5M: "5分钟",
    KL_TYPE.K_3M: "3分钟",
    KL_TYPE.K_1M: "1分钟",
}
RLD_LEVEL_NAMES = {
    KL_TYPE.K_YEAR: "year",
    KL_TYPE.K_QUARTER: "quarter",
    KL_TYPE.K_MON: "month",
    KL_TYPE.K_WEEK: "week",
    KL_TYPE.K_DAY: "day",
    KL_TYPE.K_60M: "60m",
    KL_TYPE.K_30M: "30m",
    KL_TYPE.K_15M: "15m",
    KL_TYPE.K_5M: "5m",
    KL_TYPE.K_3M: "3m",
    KL_TYPE.K_1M: "1m",
}
RLD_LEVEL_RANK = {
    KL_TYPE.K_YEAR: 0,
    KL_TYPE.K_QUARTER: 1,
    KL_TYPE.K_MON: 2,
    KL_TYPE.K_WEEK: 3,
    KL_TYPE.K_DAY: 4,
    KL_TYPE.K_60M: 5,
    KL_TYPE.K_30M: 6,
    KL_TYPE.K_15M: 7,
    KL_TYPE.K_5M: 8,
    KL_TYPE.K_3M: 9,
    KL_TYPE.K_1M: 10,
}
RLD_INTRADAY_TYPES = {KL_TYPE.K_60M, KL_TYPE.K_30M, KL_TYPE.K_15M, KL_TYPE.K_5M, KL_TYPE.K_3M, KL_TYPE.K_1M}
RLD_ENTRY_RULES_DEFAULT = ["rld_bs_buy", "one_line"]
RLD_EXIT_RULES_DEFAULT = ["rld_bs_sell", "trend_down"]


def kl_type_to_name(lv: KL_TYPE) -> str:
    return RLD_LEVEL_NAMES.get(lv, str(lv.name).lower())


def kl_type_to_label(lv: KL_TYPE) -> str:
    return RLD_LEVEL_LABELS.get(lv, str(lv.name))


def is_intraday_kl_type(lv: KL_TYPE) -> bool:
    return lv in RLD_INTRADAY_TYPES


def parse_kl_type(raw: Any) -> KL_TYPE:
    if isinstance(raw, KL_TYPE):
        return raw
    text = str(raw or "").strip().lower()
    mapping = {
        "year": KL_TYPE.K_YEAR,
        "y": KL_TYPE.K_YEAR,
        "quarter": KL_TYPE.K_QUARTER,
        "q": KL_TYPE.K_QUARTER,
        "mon": KL_TYPE.K_MON,
        "month": KL_TYPE.K_MON,
        "m": KL_TYPE.K_MON,
        "week": KL_TYPE.K_WEEK,
        "w": KL_TYPE.K_WEEK,
        "day": KL_TYPE.K_DAY,
        "d": KL_TYPE.K_DAY,
        "60m": KL_TYPE.K_60M,
        "1h": KL_TYPE.K_60M,
        "30m": KL_TYPE.K_30M,
        "15m": KL_TYPE.K_15M,
        "5m": KL_TYPE.K_5M,
        "3m": KL_TYPE.K_3M,
        "1m": KL_TYPE.K_1M,
        "k_year": KL_TYPE.K_YEAR,
        "k_quarter": KL_TYPE.K_QUARTER,
        "k_mon": KL_TYPE.K_MON,
        "k_week": KL_TYPE.K_WEEK,
        "k_day": KL_TYPE.K_DAY,
        "k_60m": KL_TYPE.K_60M,
        "k_30m": KL_TYPE.K_30M,
        "k_15m": KL_TYPE.K_15M,
        "k_5m": KL_TYPE.K_5M,
        "k_3m": KL_TYPE.K_3M,
        "k_1m": KL_TYPE.K_1M,
    }
    if text in mapping:
        return mapping[text]
    raise ValueError(f"不支持的周期：{raw}")


def normalize_rld_lv_list(raw: Any) -> list[KL_TYPE]:
    if raw is None:
        return list(RLD_DEFAULT_LV_LIST)
    if isinstance(raw, str):
        parts = [part for part in re.split(r"[\s,，;；|/]+", raw) if part]
    elif isinstance(raw, Iterable):
        parts = list(raw)
    else:
        parts = [raw]
    levels: list[KL_TYPE] = []
    seen: set[KL_TYPE] = set()
    for part in parts:
        try:
            lv = parse_kl_type(part)
        except Exception:
            continue
        if lv not in seen:
            levels.append(lv)
            seen.add(lv)
    if len(levels) <= 0:
        levels = list(RLD_DEFAULT_LV_LIST)
    levels.sort(key=lambda lv: RLD_LEVEL_RANK.get(lv, 999))
    check_kltype_order(levels)
    return levels[:3]


def build_chan_config_dict(chan_config: Optional[dict[str, Any]] = None, *, trigger_step: bool) -> dict[str, Any]:
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
        "trigger_step": trigger_step,
        "skip_step": 0,
        "kl_data_check": True,
        "print_warning": False,
        "print_err_time": False,
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
        "macd": {"fast": 12, "slow": 26, "signal": 9},
    }
    if chan_config:
        for k, v in chan_config.items():
            if v is None or v == "":
                continue
            if k in ["divergence_rate", "max_bs2_rate"]:
                try:
                    cfg_dict[k] = float(v)
                except (TypeError, ValueError):
                    if isinstance(v, str) and v.lower() == "inf":
                        cfg_dict[k] = float("inf")
            elif k in ["min_zs_cnt", "bsp3a_max_zs_cnt", "boll_n", "rsi_cycle", "kdj_cycle", "skip_step"]:
                try:
                    cfg_dict[k] = int(v)
                except (TypeError, ValueError):
                    continue
            elif k == "macd" and isinstance(v, dict):
                macd_dict = cfg_dict["macd"].copy()
                for mk, mv in v.items():
                    if mv is None or mv == "":
                        continue
                    try:
                        macd_dict[mk] = int(mv)
                    except (TypeError, ValueError):
                        continue
                cfg_dict["macd"] = macd_dict
            else:
                cfg_dict[k] = v
    cfg_dict["chan_algo"] = normalize_chan_algo(cfg_dict.get("chan_algo"))
    cfg_dict["trigger_step"] = trigger_step
    return cfg_dict


def strip_chan_algo(cfg_dict: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in cfg_dict.items() if k != "chan_algo"}


class ReplayMultiLvChan(CChan):
    def __init__(self, *args: Any, replay_klus_map_master: Optional[dict[KL_TYPE, list]] = None, **kwargs: Any) -> None:
        self._replay_klus_map_master: Optional[dict[KL_TYPE, list]] = replay_klus_map_master
        super().__init__(*args, **kwargs)

    def load(self, step: bool = False):
        if self._replay_klus_map_master is None:
            yield from super().load(step)
            return
        frozen_map = {lv: copy.deepcopy(self._replay_klus_map_master.get(lv, [])) for lv in self.lv_list}
        self.klu_cache = [None for _ in self.lv_list]
        self.klu_last_t = [CTime(1980, 1, 1, 0, 0) for _ in self.lv_list]
        for lv_idx, lv in enumerate(self.lv_list):
            self.add_lv_iter(lv_idx, iter(frozen_map.get(lv, [])))
        yield from self.load_iterator(lv_idx=0, parent_klu=None, step=step)
        if not step:
            for lv in self.lv_list:
                self.kl_datas[lv].cal_seg_and_zs()
        if len(self[0]) == 0:
            raise CChanException("最高级别没有获得任何数据", ErrCode.NO_DATA)


class _SingleLevelChanView:
    def __init__(self, kl_list, conf: CChanConfig):
        self._kl_list = kl_list
        self.conf = conf

    def __getitem__(self, n):
        if n == 0:
            return self._kl_list
        raise IndexError(n)


def create_stock_api_instance_for_level(
    data_src: Any,
    code: str,
    begin_date: Optional[str],
    end_date: Optional[str],
    autype: AUTYPE,
    k_type: KL_TYPE,
) -> CCommonStockApi:
    api_cls = get_stock_api_cls(data_src)
    api_cls.do_init()
    try:
        return api_cls(code=code, k_type=k_type, begin_date=begin_date, end_date=end_date, autype=autype)
    except Exception:
        api_cls.do_close()
        raise


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


def fetch_level_klus_from_source(
    data_src: Any,
    code: str,
    begin_date: Optional[str],
    end_date: Optional[str],
    autype: AUTYPE,
    lv: KL_TYPE,
) -> tuple[list[CKLine_Unit], Optional[str]]:
    api_cls = get_stock_api_cls(data_src)
    api_cls.do_init()
    try:
        api = api_cls(code=code, k_type=lv, begin_date=begin_date, end_date=end_date, autype=autype)
        stock_name = getattr(api, "name", None) or None
        items = fetch_klu_list_from_api(api, lv)
        return items, stock_name
    finally:
        try:
            api_cls.do_close()
        except Exception:
            pass


def select_data_source_for_level(
    code: str,
    begin_date: str,
    end_date: Optional[str],
    autype: AUTYPE,
    lv: KL_TYPE,
) -> tuple[Any, str, list[CKLine_Unit], Optional[str], list[str]]:
    logs: list[str] = []
    if is_intraday_kl_type(lv):
        data_src = DATA_SRC.BAO_STOCK
        try:
            items, stock_name = fetch_level_klus_from_source(data_src, code, begin_date, end_date, autype, lv)
        except Exception as exc:
            raise RuntimeError(f"{kl_type_to_label(lv)} 仅支持 BaoStock，拉取失败：{format_source_error(exc)}") from exc
        if len(items) <= 0:
            raise RuntimeError(f"{kl_type_to_label(lv)} 未获取到任何数据")
        logs.append(f"{kl_type_to_label(lv)} 使用 BaoStock，加载 {len(items)} 根 K 线")
        return data_src, "BaoStock", items, stock_name, logs

    errors: list[str] = []
    for label, data_src in DATA_SOURCE_CHAIN:
        try:
            items, stock_name = fetch_level_klus_from_source(data_src, code, begin_date, end_date, autype, lv)
            if len(items) <= 0:
                raise RuntimeError("未获取到任何数据")
            logs.append(f"{kl_type_to_label(lv)} 使用 {label}，加载 {len(items)} 根 K 线")
            return data_src, label, items, stock_name, logs
        except Exception as exc:
            errors.append(f"{label}:{format_source_error(exc)}")
    raise RuntimeError(f"{kl_type_to_label(lv)} 数据源全部失败：{'；'.join(errors)}")


def serialize_rld_klu_iter(klu_iter) -> list[dict[str, Any]]:
    arr: list[dict[str, Any]] = []
    for klu in klu_iter:
        arr.append(
            {
                "x": int(klu.idx),
                "t": klu.time.to_str(),
                "o": float(klu.open),
                "h": float(klu.high),
                "l": float(klu.low),
                "c": float(klu.close),
                "v": float(getattr(klu, "volume", getattr(klu, "vol", 0.0)) or 0.0),
                "sup_x": int(klu.sup_kl.idx) if getattr(klu, "sup_kl", None) is not None else None,
                "sub_count": len(getattr(klu, "sub_kl_list", []) or []),
            }
        )
    return arr


@dataclass
class RldDataSession:
    code: str
    begin_date: str
    end_date: Optional[str]
    autype: AUTYPE
    lv_list: list[KL_TYPE]
    replay_klus_map: dict[KL_TYPE, list]
    source_map: dict[str, str]
    logs: list[str] = field(default_factory=list)
    stock_name: Optional[str] = None

    @classmethod
    def load(
        cls,
        code: str,
        begin_date: str,
        end_date: Optional[str],
        autype: AUTYPE,
        lv_list: list[KL_TYPE],
    ) -> "RldDataSession":
        replay_klus_map: dict[KL_TYPE, list] = {}
        source_map: dict[str, str] = {}
        logs: list[str] = []
        stock_name: Optional[str] = None
        valid_lv_list: list[KL_TYPE] = []
        for idx, lv in enumerate(lv_list):
            try:
                data_src, label, items, name, lv_logs = select_data_source_for_level(code, begin_date, end_date, autype, lv)
                replay_klus_map[lv] = items
                source_map[kl_type_to_name(lv)] = label
                logs.extend(lv_logs)
                valid_lv_list.append(lv)
                if stock_name is None and name:
                    stock_name = name
            except Exception as exc:
                if idx == 0:
                    raise
                logs.append(f"{kl_type_to_label(lv)} 降级跳过：{format_source_error(exc)}")
                continue
        if not valid_lv_list:
            raise RuntimeError("未能构建任何有效周期")
        return cls(
            code=code,
            begin_date=begin_date,
            end_date=end_date,
            autype=autype,
            lv_list=valid_lv_list,
            replay_klus_map=replay_klus_map,
            source_map=source_map,
            logs=logs,
            stock_name=stock_name,
        )

    def build_chan(self, chan_config: Optional[dict[str, Any]] = None, *, trigger_step: bool = False) -> tuple[ReplayMultiLvChan, dict[str, Any]]:
        cfg_dict = build_chan_config_dict(chan_config, trigger_step=trigger_step)
        cfg = CChanConfig(strip_chan_algo(cfg_dict))
        chan = ReplayMultiLvChan(
            code=self.code,
            begin_time=self.begin_date,
            end_time=self.end_date,
            data_src=DATA_SRC.BAO_STOCK,
            lv_list=self.lv_list,
            config=cfg,
            autype=self.autype,
            replay_klus_map_master=self.replay_klus_map,
        )
        return chan, cfg_dict


def build_level_macd_history(klus: list[Any], macd_cfg: Optional[dict[str, Any]] = None) -> list[dict[str, Any]]:
    macd_cfg = macd_cfg or {}
    eng = CMACD(
        fastperiod=int(macd_cfg.get("fast", 12) or 12),
        slowperiod=int(macd_cfg.get("slow", 26) or 26),
        signalperiod=int(macd_cfg.get("signal", 9) or 9),
    )
    arr: list[dict[str, Any]] = []
    for klu in klus:
        item = eng.add(float(klu.close))
        arr.append({"x": int(klu.idx), "macd": {"dif": float(item.DIF), "dea": float(item.DEA), "macd": float(item.macd)}})
    return arr


def line_dir_sign(line: Any) -> int:
    try:
        y1 = float(line.get_begin_val())
        y2 = float(line.get_end_val())
    except Exception:
        return 0
    if y2 > y1:
        return 1
    if y2 < y1:
        return -1
    return 0


def describe_trend(sign: int) -> str:
    if sign > 0:
        return "上升"
    if sign < 0:
        return "下降"
    return "震荡"


def get_latest_nonempty_line(bundle: ChanStructureBundle):
    for lines in (bundle.segseg_list, bundle.seg_list, bundle.bi_list, bundle.fract_list):
        if lines and len(lines) > 0:
            return lines[-1]
    return None


def latest_bundle_bsp(bundle: ChanStructureBundle) -> Optional[dict[str, Any]]:
    arr = []
    arr.extend(serialize_bsp_collection("bi", bundle.bs_point_lst))
    arr.extend(serialize_bsp_collection("seg", bundle.seg_bs_point_lst))
    arr.extend(serialize_bsp_collection("segseg", bundle.segseg_bs_point_lst))
    if not arr:
        return None
    arr.sort(key=lambda item: (int(item["x"]), LEVEL_ORDER.get(str(item["level"]), 999), int(not bool(item["is_buy"]))))
    return arr[-1]


def latest_zs_state(bundle: ChanStructureBundle, current_price: float) -> dict[str, Any]:
    last_zs = None
    last_kind = "笔中枢"
    for kind, zs_list in [("段中枢", bundle.segzs_list), ("笔中枢", bundle.zs_list), ("分型中枢", bundle.fractzs_list)]:
        zs_items = list(zs_list)
        if zs_items:
            last_zs = zs_items[-1]
            last_kind = kind
            break
    if last_zs is None:
        return {"label": "无中枢", "kind": "无", "low": None, "high": None, "bias": 0}
    low = float(last_zs.low)
    high = float(last_zs.high)
    if current_price > high:
        return {"label": "上离开", "kind": last_kind, "low": low, "high": high, "bias": 1}
    if current_price < low:
        return {"label": "下离开", "kind": last_kind, "low": low, "high": high, "bias": -1}
    return {"label": "中枢内", "kind": last_kind, "low": low, "high": high, "bias": 0}


def calc_macd_area(macd_history: list[dict[str, Any]], start_x: Optional[int], end_x: Optional[int]) -> Optional[float]:
    if start_x is None or end_x is None or end_x < start_x:
        return None
    total = 0.0
    hit = False
    for item in macd_history:
        x = int(item["x"])
        if x < start_x or x > end_x:
            continue
        total += abs(float(item["macd"]["macd"]))
        hit = True
    return round(total, 4) if hit else None


def find_previous_same_dir_line(lines: Any, latest_line: Any):
    if not lines or len(lines) <= 1:
        return None
    latest_sign = line_dir_sign(latest_line)
    if latest_sign == 0:
        return None
    for line in reversed(lines[:-1]):
        if line_dir_sign(line) == latest_sign:
            return line
    return None


def calc_divergence_bias(lines: Any, latest_line: Any, macd_history: list[dict[str, Any]]) -> int:
    if latest_line is None:
        return 0
    prev_line = find_previous_same_dir_line(lines, latest_line)
    if prev_line is None:
        return 0
    latest_area = calc_macd_area(macd_history, int(latest_line.get_begin_klu().idx), int(latest_line.get_end_klu().idx))
    prev_area = calc_macd_area(macd_history, int(prev_line.get_begin_klu().idx), int(prev_line.get_end_klu().idx))
    if latest_area is None or prev_area is None or prev_area <= 1e-9:
        return 0
    latest_sign = line_dir_sign(latest_line)
    if latest_area <= prev_area * 0.85:
        return -latest_sign
    if latest_area >= prev_area * 1.05:
        return latest_sign
    return 0


def last_macd_bias(macd_history: list[dict[str, Any]]) -> float:
    if not macd_history:
        return 0.0
    value = float(macd_history[-1]["macd"]["macd"])
    return float(math.tanh(value * 4.0) * 100.0)


def bsp_bias(item: Optional[dict[str, Any]], latest_x: int) -> tuple[int, list[str]]:
    if not item:
        return 0, ["最近未出现明确买卖点"]
    label_weight = {"1": 22, "1p": 18, "2": 16, "2s": 12, "3a": 18, "3b": 16}
    sign = 1 if bool(item.get("is_buy")) else -1
    weight = label_weight.get(str(item.get("label")), 10)
    reasons = [f"最近买卖点：{item.get('display_label') or item.get('label')}"]
    if latest_x - int(item.get("x", latest_x)) > 12:
        weight = int(weight * 0.55)
        reasons.append("买卖点距离当前较远，影响衰减")
    return sign * weight, reasons


def build_level_chart_payload(kl_list, chan_algo: str, macd_cfg: Optional[dict[str, Any]] = None) -> tuple[dict[str, Any], dict[str, Any]]:
    klu_items = list(kl_list.klu_iter())
    chart = {"kline": [], "fract": [], "bi": [], "seg": [], "segseg": [], "fract_zs": [], "bi_zs": [], "seg_zs": [], "segseg_zs": [], "bsp": [], "trend_lines": [], "indicators": []}
    if not klu_items:
        return chart, {
            "trend_sign": 0,
            "trend_label": "震荡",
            "zs_state": {"label": "无数据", "kind": "无", "low": None, "high": None, "bias": 0},
            "latest_bsp": None,
            "macd_bi_area": None,
            "macd_seg_area": None,
            "macd_bias": 0.0,
            "chdl_score": 0.0,
            "divergence_bias": 0,
            "reasons": ["当前级别无数据"],
        }
    view = _SingleLevelChanView(kl_list, kl_list.config)
    bundle = build_structure_bundle(view, chan_algo)
    macd_history = build_level_macd_history(klu_items, macd_cfg)
    current_price = float(klu_items[-1].close)
    latest_x = int(klu_items[-1].idx)
    latest_line = get_latest_nonempty_line(bundle)
    trend_sign = line_dir_sign(latest_line) if latest_line is not None else 0
    trend_label = describe_trend(trend_sign)
    zs_state = latest_zs_state(bundle, current_price)
    latest_bsp = latest_bundle_bsp(bundle)
    bi_line = bundle.bi_list[-1] if bundle.bi_list and len(bundle.bi_list) > 0 else None
    seg_line = bundle.seg_list[-1] if bundle.seg_list and len(bundle.seg_list) > 0 else None
    macd_bi_area = calc_macd_area(macd_history, int(bi_line.get_begin_klu().idx), int(bi_line.get_end_klu().idx)) if bi_line is not None else None
    macd_seg_area = calc_macd_area(macd_history, int(seg_line.get_begin_klu().idx), int(seg_line.get_end_klu().idx)) if seg_line is not None else None
    divergence = calc_divergence_bias(bundle.bi_list if bundle.bi_list else bundle.seg_list, bi_line or seg_line, macd_history)
    macd_bias = last_macd_bias(macd_history)
    chdl = 0.0
    reasons: list[str] = [f"结构方向：{trend_label}"]
    chdl += trend_sign * 22.0
    chdl += float(zs_state["bias"]) * 14.0
    reasons.append(f"中枢状态：{zs_state['kind']}{zs_state['label']}")
    _bsp_bias, bsp_reasons = bsp_bias(latest_bsp, latest_x)
    chdl += float(_bsp_bias)
    reasons.extend(bsp_reasons)
    chdl += macd_bias * 0.18
    if abs(macd_bias) >= 8:
        reasons.append(f"MACD 动量：{macd_bias:+.1f}")
    chdl += divergence * 14.0
    if divergence > 0:
        reasons.append("最近结构出现正向背驰/动能改善")
    elif divergence < 0:
        reasons.append("最近结构出现反向背驰/动能衰减")
    chdl = round(max(-100.0, min(100.0, chdl)), 2)
    chart = {
        "kline": serialize_rld_klu_iter(klu_items),
        "fract": serialize_line_collection(bundle.fract_list),
        "bi": serialize_line_collection(bundle.bi_list),
        "seg": serialize_line_collection(bundle.seg_list),
        "segseg": serialize_line_collection(bundle.segseg_list),
        "fract_zs": serialize_zs_collection(bundle.fractzs_list),
        "bi_zs": serialize_zs_collection(bundle.zs_list),
        "seg_zs": serialize_zs_collection(bundle.segzs_list),
        "segseg_zs": serialize_zs_collection(bundle.segsegzs_list),
        "bsp": sorted(
            [
                *serialize_bsp_collection("bi", bundle.bs_point_lst),
                *serialize_bsp_collection("seg", bundle.seg_bs_point_lst),
                *serialize_bsp_collection("segseg", bundle.segseg_bs_point_lst),
            ],
            key=lambda item: (int(item["x"]), LEVEL_ORDER.get(str(item["level"]), 999), int(not bool(item["is_buy"]))),
        ),
        "trend_lines": bundle.trend_lines,
        "indicators": macd_history,
    }
    return chart, {
        "trend_sign": trend_sign,
        "trend_label": trend_label,
        "zs_state": zs_state,
        "latest_bsp": latest_bsp,
        "macd_bi_area": macd_bi_area,
        "macd_seg_area": macd_seg_area,
        "macd_bias": round(macd_bias, 2),
        "chdl_score": chdl,
        "divergence_bias": divergence,
        "reasons": reasons,
    }


def normalize_strategy_config(strategy_config: Optional[dict[str, Any]], lv_list: list[KL_TYPE]) -> dict[str, Any]:
    default_weights = [50.0, 30.0, 20.0]
    weights_raw = []
    if isinstance(strategy_config, dict):
        weights_raw = list(strategy_config.get("weights", []) or [])
    weights: list[float] = []
    for idx, lv in enumerate(lv_list):
        try:
            weights.append(float(weights_raw[idx]))
        except Exception:
            weights.append(default_weights[idx] if idx < len(default_weights) else max(5.0, 20.0 - idx * 3.0))
    total = sum(abs(weight) for weight in weights) or 1.0
    normalized = [round(weight / total * 100.0, 3) for weight in weights]
    return {"weights": normalized}


def build_rld_summary(level_snapshots: list[dict[str, Any]], strategy_config: dict[str, Any]) -> dict[str, Any]:
    if not level_snapshots:
        return {"weighted_chdl": 0.0, "three_macd": 0.0, "one_line": False, "stupid_buy_bi": False, "stupid_buy_seg": False, "rld_bs": {"side": "neutral", "score": 0.0, "reasons": ["暂无数据"]}, "weights": []}
    weights = strategy_config.get("weights", [])
    weighted_chdl = 0.0
    weighted_macd = 0.0
    trend_signs: list[int] = []
    reasons: list[str] = []
    for idx, item in enumerate(level_snapshots):
        weight = float(weights[idx] if idx < len(weights) else 0.0)
        weighted_chdl += float(item["summary"]["chdl_score"]) * weight / 100.0
        weighted_macd += float(item["summary"]["macd_bias"]) * weight / 100.0
        trend_signs.append(int(item["summary"]["trend_sign"]))
        reasons.append(f"{item['label']} CHDL={item['summary']['chdl_score']:+.1f}")
    nonzero_signs = [sign for sign in trend_signs if sign != 0]
    aligned = len(nonzero_signs) == len(level_snapshots) and len(set(nonzero_signs)) == 1
    no_recent_opposite = all(
        snapshot["summary"]["latest_bsp"] is None
        or (
            snapshot["summary"]["trend_sign"] == 0
            or (
                (snapshot["summary"]["trend_sign"] > 0 and bool(snapshot["summary"]["latest_bsp"].get("is_buy")))
                or (snapshot["summary"]["trend_sign"] < 0 and not bool(snapshot["summary"]["latest_bsp"].get("is_buy")))
            )
        )
        for snapshot in level_snapshots
    )
    one_line = bool(aligned and no_recent_opposite and abs(weighted_chdl) >= 12)
    stupid_buy_bi = bool(weighted_chdl >= 20 and aligned and all(item["summary"]["macd_bi_area"] is not None for item in level_snapshots[:2]))
    stupid_buy_seg = bool(weighted_chdl >= 38 and aligned and all(item["summary"]["zs_state"]["bias"] >= 0 for item in level_snapshots[:2]))
    rld_bs_score = round(max(-100.0, min(100.0, weighted_chdl * 0.7 + weighted_macd * 0.3 + (12.0 if one_line else 0.0))), 2)
    if rld_bs_score >= 25:
        side = "buy"
        reasons.append("多周期合成分偏多")
    elif rld_bs_score <= -25:
        side = "sell"
        reasons.append("多周期合成分偏空")
    else:
        side = "neutral"
        reasons.append("多周期分歧较大，维持中性")
    if one_line:
        reasons.append("三周期同向且最近未见明显逆向破坏")
    if stupid_buy_bi:
        reasons.append("满足无脑买入（笔）模板")
    if stupid_buy_seg:
        reasons.append("满足无脑买入（线段）模板")
    return {
        "weighted_chdl": round(weighted_chdl, 2),
        "three_macd": round(weighted_macd, 2),
        "one_line": one_line,
        "stupid_buy_bi": stupid_buy_bi,
        "stupid_buy_seg": stupid_buy_seg,
        "rld_bs": {"side": side, "score": rld_bs_score, "reasons": reasons},
        "weights": list(weights),
    }


def build_level_matrix(level_snapshots: list[dict[str, Any]], aggregate: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    metrics = [
        ("趋势", lambda item: item["summary"]["trend_label"]),
        ("BSP", lambda item: item["summary"]["latest_bsp"]["display_label"] if item["summary"]["latest_bsp"] else "无"),
        ("ZS状态", lambda item: f"{item['summary']['zs_state']['kind']}{item['summary']['zs_state']['label']}"),
        ("CHDL", lambda item: f"{item['summary']['chdl_score']:+.2f}"),
        ("MACD笔面积", lambda item: "-" if item["summary"]["macd_bi_area"] is None else f"{float(item['summary']['macd_bi_area']):.3f}"),
        ("MACD段面积", lambda item: "-" if item["summary"]["macd_seg_area"] is None else f"{float(item['summary']['macd_seg_area']):.3f}"),
        ("三级别MACD", lambda item: f"{item['summary']['macd_bias']:+.2f}"),
    ]
    for metric, getter in metrics:
        row = {"metric": metric}
        for item in level_snapshots:
            row[item["label"]] = getter(item)
        rows.append(row)
    rows.append({"metric": "一根筋", **{item["label"]: ("是" if aggregate["one_line"] else "否") for item in level_snapshots}})
    rows.append({"metric": "无脑买入(笔)", **{item["label"]: ("是" if aggregate["stupid_buy_bi"] else "否") for item in level_snapshots}})
    rows.append({"metric": "无脑买入(线段)", **{item["label"]: ("是" if aggregate["stupid_buy_seg"] else "否") for item in level_snapshots}})
    rows.append({"metric": "RLD_BS", **{item["label"]: f"{aggregate['rld_bs']['side']} {aggregate['rld_bs']['score']:+.2f}" for item in level_snapshots}})
    return rows


def analyze_rld_chan(chan: ReplayMultiLvChan, effective_cfg_dict: dict[str, Any], strategy_config: Optional[dict[str, Any]] = None, *, include_chart: bool = True) -> dict[str, Any]:
    level_snapshots: list[dict[str, Any]] = []
    normalized_strategy = normalize_strategy_config(strategy_config, list(chan.lv_list))
    macd_cfg = effective_cfg_dict.get("macd") if isinstance(effective_cfg_dict.get("macd"), dict) else {}
    for lv in chan.lv_list:
        kl_list = chan[lv]
        chart, summary = build_level_chart_payload(kl_list, effective_cfg_dict.get("chan_algo", CHAN_ALGO_CLASSIC), macd_cfg)
        level_snapshots.append(
            {
                "level": kl_type_to_name(lv),
                "label": kl_type_to_label(lv),
                "chart": chart if include_chart else None,
                "summary": summary,
                "last_time": chart["kline"][-1]["t"] if chart["kline"] else "-",
                "last_price": chart["kline"][-1]["c"] if chart["kline"] else None,
            }
        )
    aggregate = build_rld_summary(level_snapshots, normalized_strategy)
    return {
        "levels": level_snapshots,
        "aggregate": aggregate,
        "level_matrix": build_level_matrix(level_snapshots, aggregate),
        "strategy_config": normalized_strategy,
    }


def parse_watchlist_codes(raw: Any) -> list[str]:
    if raw is None:
        return []
    if isinstance(raw, list):
        candidates = raw
    else:
        candidates = re.findall(r"\d{6}", str(raw))
    normalized: list[str] = []
    seen: set[str] = set()
    for item in candidates:
        try:
            code = normalize_code(str(item)[-6:])
        except Exception:
            continue
        if code not in seen:
            normalized.append(code)
            seen.add(code)
    return normalized


def resolve_watchlist_or_sector(raw: Any, *, limit: int = 18) -> tuple[list[str], str]:
    codes = parse_watchlist_codes(raw)
    if codes:
        return codes[:limit], "manual"
    name = str(raw or "").strip()
    if not name:
        return [], "empty"
    loaders = [
        ("概念板块", getattr(ak, "stock_board_concept_cons_em", None)),
        ("行业板块", getattr(ak, "stock_board_industry_cons_em", None)),
    ]
    for label, loader in loaders:
        if loader is None:
            continue
        try:
            df = loader(symbol=name)
            if df is None or df.empty:
                continue
            code_col = next((col for col in ["代码", "code", "证券代码", "股票代码"] if col in df.columns), None)
            if code_col is None:
                continue
            resolved = parse_watchlist_codes(df[code_col].astype(str).tolist())
            if resolved:
                return resolved[:limit], label
        except Exception:
            continue
    return [], "unknown"


def compact_reasons(reasons: list[str], *, limit: int = 5) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for reason in reasons:
        text = str(reason or "").strip()
        if not text or text in seen:
            continue
        seen.add(text)
        result.append(text)
        if len(result) >= limit:
            break
    return result


def build_matrix_row(code: str, payload: dict[str, Any], *, stock_name: Optional[str] = None) -> dict[str, Any]:
    levels = payload["analysis"]["levels"]
    agg = payload["analysis"]["aggregate"]
    row = {
        "code": code,
        "name": stock_name,
        "rotation_score": round((agg["weighted_chdl"] * 0.55) + (agg["three_macd"] * 0.25) + (20.0 if agg["one_line"] else 0.0), 2),
        "chdl": agg["weighted_chdl"],
        "three_macd": agg["three_macd"],
        "one_line": agg["one_line"],
        "stupid_buy_bi": agg["stupid_buy_bi"],
        "stupid_buy_seg": agg["stupid_buy_seg"],
        "rld_bs_side": agg["rld_bs"]["side"],
        "rld_bs_score": agg["rld_bs"]["score"],
    }
    for idx, level in enumerate(levels):
        prefix = f"lv{idx + 1}"
        row[f"{prefix}_name"] = level["label"]
        row[f"{prefix}_trend"] = level["summary"]["trend_label"]
        row[f"{prefix}_bsp"] = level["summary"]["latest_bsp"]["display_label"] if level["summary"]["latest_bsp"] else "无"
        row[f"{prefix}_zs"] = f"{level['summary']['zs_state']['kind']}{level['summary']['zs_state']['label']}"
        row[f"{prefix}_chdl"] = level["summary"]["chdl_score"]
    row["reasons"] = compact_reasons(list(agg["rld_bs"]["reasons"]))
    return row


def evaluate_entry_rule(rule: str, analysis: dict[str, Any]) -> bool:
    agg = analysis["aggregate"]
    top = analysis["levels"][0]["summary"] if analysis["levels"] else {}
    rule = str(rule or "").strip().lower()
    if rule == "rld_bs_buy":
        return agg["rld_bs"]["side"] == "buy"
    if rule == "one_line":
        return bool(agg["one_line"])
    if rule == "stupid_buy_bi":
        return bool(agg["stupid_buy_bi"])
    if rule == "stupid_buy_seg":
        return bool(agg["stupid_buy_seg"])
    if rule == "bsp_buy":
        return bool(top.get("latest_bsp") and top["latest_bsp"].get("is_buy"))
    if rule == "zs_breakout_up":
        return int(top.get("zs_state", {}).get("bias", 0)) > 0
    if rule == "chdl_ge_20":
        return float(agg["weighted_chdl"]) >= 20.0
    if rule == "chdl_ge_40":
        return float(agg["weighted_chdl"]) >= 40.0
    return False


def evaluate_exit_rule(rule: str, analysis: dict[str, Any], *, pnl_pct: Optional[float] = None) -> bool:
    agg = analysis["aggregate"]
    top = analysis["levels"][0]["summary"] if analysis["levels"] else {}
    rule = str(rule or "").strip().lower()
    if rule == "rld_bs_sell":
        return agg["rld_bs"]["side"] == "sell"
    if rule == "trend_down":
        return int(top.get("trend_sign", 0)) < 0
    if rule == "bsp_sell":
        return bool(top.get("latest_bsp") and not top["latest_bsp"].get("is_buy"))
    if rule == "chdl_le_-20":
        return float(agg["weighted_chdl"]) <= -20.0
    if rule == "chdl_le_-40":
        return float(agg["weighted_chdl"]) <= -40.0
    if rule == "take_profit_8":
        return pnl_pct is not None and pnl_pct >= 0.08
    if rule == "stop_loss_5":
        return pnl_pct is not None and pnl_pct <= -0.05
    return False


def evaluate_rules(rule_ids: list[str], analysis: dict[str, Any], *, logic: str, pnl_pct: Optional[float] = None, exit_mode: bool = False) -> bool:
    if not rule_ids:
        return False
    results = []
    for rule in rule_ids:
        if exit_mode:
            results.append(evaluate_exit_rule(rule, analysis, pnl_pct=pnl_pct))
        else:
            results.append(evaluate_entry_rule(rule, analysis))
    mode = str(logic or "and").strip().lower()
    return all(results) if mode == "and" else any(results)


def compute_max_drawdown(points: list[dict[str, Any]]) -> float:
    if not points:
        return 0.0
    peak = float(points[0]["equity"])
    max_dd = 0.0
    for point in points:
        equity = float(point["equity"])
        if equity > peak:
            peak = equity
        if peak > 1e-9:
            max_dd = min(max_dd, (equity - peak) / peak)
    return round(max_dd, 4)


def run_backtest_for_code(
    session: RldDataSession,
    chan_config: dict[str, Any],
    strategy_config: dict[str, Any],
    entry_rules: list[str],
    exit_rules: list[str],
    *,
    logic: str,
    fee: float,
    slippage: float,
) -> dict[str, Any]:
    chan, effective_cfg_dict = session.build_chan(chan_config, trigger_step=True)
    iterator = chan.step_load()
    top_lv = session.lv_list[0]
    top_master = session.replay_klus_map[top_lv]
    cash = 100000.0
    position = 0
    avg_cost = 0.0
    buy_idx: Optional[int] = None
    pending_order: Optional[dict[str, Any]] = None
    trades: list[dict[str, Any]] = []
    equity_curve: list[dict[str, Any]] = []
    wins = 0
    losses = 0
    while True:
        try:
            next(iterator)
        except StopIteration:
            break
        current_klu = chan[top_lv].lst[-1].lst[-1]
        current_idx = int(current_klu.idx)
        if pending_order and int(pending_order["execute_idx"]) == current_idx:
            open_price = float(current_klu.open)
            if pending_order["side"] == "buy" and position <= 0:
                exec_price = open_price * (1.0 + slippage)
                hand_cost = exec_price * 100 * (1.0 + fee)
                hands = int(cash // hand_cost)
                if hands > 0:
                    shares = hands * 100
                    gross = exec_price * shares
                    commission = gross * fee
                    cash -= gross + commission
                    position = shares
                    avg_cost = exec_price
                    buy_idx = current_idx
                    trades.append({"side": "buy", "idx": current_idx, "time": current_klu.time.to_str(), "price": round(exec_price, 4), "shares": shares, "reason": list(pending_order.get("reasons", []))})
            elif pending_order["side"] == "sell" and position > 0:
                exec_price = open_price * (1.0 - slippage)
                gross = exec_price * position
                commission = gross * fee
                pnl = gross - commission - position * avg_cost
                pnl_pct = pnl / (position * avg_cost) if position * avg_cost > 1e-9 else 0.0
                cash += gross - commission
                trades.append({"side": "sell", "idx": current_idx, "time": current_klu.time.to_str(), "price": round(exec_price, 4), "shares": position, "pnl": round(pnl, 2), "pnl_pct": round(pnl_pct, 4), "reason": list(pending_order.get("reasons", []))})
                if pnl >= 0:
                    wins += 1
                else:
                    losses += 1
                position = 0
                avg_cost = 0.0
                buy_idx = None
            pending_order = None

        analysis = analyze_rld_chan(chan, effective_cfg_dict, strategy_config, include_chart=False)
        current_close = float(current_klu.close)
        equity_curve.append({"idx": current_idx, "time": current_klu.time.to_str(), "equity": round(cash + position * current_close, 2)})

        if current_idx >= len(top_master) - 1 or pending_order is not None:
            continue
        pnl_pct = None
        if position > 0 and avg_cost > 1e-9:
            pnl_pct = (current_close - avg_cost) / avg_cost
        if position > 0:
            can_sell = buy_idx is None or current_idx >= buy_idx + 1
            if can_sell and evaluate_rules(exit_rules, analysis, logic=logic, pnl_pct=pnl_pct, exit_mode=True):
                pending_order = {"side": "sell", "execute_idx": current_idx + 1, "reasons": compact_reasons(list(analysis["aggregate"]["rld_bs"]["reasons"]))}
        else:
            if evaluate_rules(entry_rules, analysis, logic=logic, exit_mode=False):
                pending_order = {"side": "buy", "execute_idx": current_idx + 1, "reasons": compact_reasons(list(analysis["aggregate"]["rld_bs"]["reasons"]))}

    if position > 0 and top_master:
        last_klu = top_master[-1]
        exit_price = float(last_klu.close) * (1.0 - slippage)
        gross = exit_price * position
        commission = gross * fee
        pnl = gross - commission - position * avg_cost
        pnl_pct = pnl / (position * avg_cost) if position * avg_cost > 1e-9 else 0.0
        cash += gross - commission
        trades.append({"side": "sell", "idx": int(last_klu.idx), "time": last_klu.time.to_str(), "price": round(exit_price, 4), "shares": position, "pnl": round(pnl, 2), "pnl_pct": round(pnl_pct, 4), "reason": ["回测结束强制平仓"]})
        if pnl >= 0:
            wins += 1
        else:
            losses += 1

    completed = sum(1 for item in trades if item["side"] == "sell")
    total_return = (cash - 100000.0) / 100000.0
    pnl_values = [float(item.get("pnl", 0.0)) for item in trades if item["side"] == "sell"]
    gross_profit = sum(value for value in pnl_values if value > 0)
    gross_loss = -sum(value for value in pnl_values if value < 0)
    profit_factor = gross_profit / gross_loss if gross_loss > 1e-9 else None
    return {
        "code": session.code,
        "name": session.stock_name,
        "trade_count": completed,
        "win_rate": round((wins / completed) if completed > 0 else 0.0, 4),
        "return": round(total_return, 4),
        "max_drawdown": compute_max_drawdown(equity_curve),
        "profit_factor": round(profit_factor, 4) if profit_factor is not None else None,
        "equity_curve": equity_curve,
        "trades": trades,
    }


class RldInitReq(BaseModel):
    code: str
    begin_date: str
    end_date: Optional[str] = None
    autype: str = "qfq"
    lv_list: Optional[list[str]] = None
    chan_config: Optional[dict[str, Any]] = None
    strategy_config: Optional[dict[str, Any]] = None
    watchlist_or_sector: Optional[str] = None


class RldMatrixReq(BaseModel):
    codes: Optional[list[str]] = None
    watchlist_or_sector: Optional[str] = None


class RldBacktestReq(BaseModel):
    codes: Optional[list[str]] = None
    watchlist_or_sector: Optional[str] = None
    entry_rules: list[str] = Field(default_factory=list)
    exit_rules: list[str] = Field(default_factory=list)
    logic: str = "and"
    execution_mode: str = "next_open"
    fee: float = 0.001
    slippage: float = 0.0005


class RldReconfigReq(BaseModel):
    chan_config: Optional[dict[str, Any]] = None
    strategy_config: Optional[dict[str, Any]] = None
    watchlist_or_sector: Optional[str] = None
    lv_list: Optional[list[str]] = None


class RldAppState:
    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.ready = False
        self.session: Optional[RldDataSession] = None
        self.chan: Optional[ReplayMultiLvChan] = None
        self.effective_cfg_dict: dict[str, Any] = {}
        self.analysis: Optional[dict[str, Any]] = None
        self.session_params: Optional[dict[str, Any]] = None
        self.matrix_rows: list[dict[str, Any]] = []
        self.matrix_meta: dict[str, Any] = {}
        self.backtest_result: Optional[dict[str, Any]] = None

    def init(self, req: RldInitReq) -> None:
        autype_map = {"qfq": AUTYPE.QFQ, "hfq": AUTYPE.HFQ, "none": AUTYPE.NONE}
        autype = autype_map.get(str(req.autype).lower(), AUTYPE.QFQ)
        code = normalize_code(req.code)
        lv_list = normalize_rld_lv_list(req.lv_list)
        self.session = RldDataSession.load(code, req.begin_date, req.end_date, autype, lv_list)
        self.chan, self.effective_cfg_dict = self.session.build_chan(req.chan_config, trigger_step=False)
        self.analysis = analyze_rld_chan(self.chan, self.effective_cfg_dict, req.strategy_config, include_chart=True)
        self.session_params = {
            "code": code,
            "begin_date": req.begin_date,
            "end_date": req.end_date,
            "autype": autype,
            "lv_list": lv_list,
            "chan_config": req.chan_config or {},
            "strategy_config": req.strategy_config or {},
            "watchlist_or_sector": req.watchlist_or_sector,
        }
        self.ready = True
        self.matrix_rows = []
        self.matrix_meta = {}
        self.backtest_result = None

    def reconfig(self, req: RldReconfigReq) -> None:
        if not self.ready or self.session is None or self.session_params is None:
            raise ValueError("请先初始化融立得工作台")
        lv_list = normalize_rld_lv_list(req.lv_list) if req.lv_list else list(self.session.lv_list)
        if lv_list != self.session.lv_list:
            self.session = RldDataSession.load(self.session.code, self.session.begin_date, self.session.end_date, self.session.autype, lv_list)
        chan_config = req.chan_config if req.chan_config is not None else self.session_params.get("chan_config", {})
        strategy_config = req.strategy_config if req.strategy_config is not None else self.session_params.get("strategy_config", {})
        watchlist_or_sector = req.watchlist_or_sector if req.watchlist_or_sector is not None else self.session_params.get("watchlist_or_sector")
        self.chan, self.effective_cfg_dict = self.session.build_chan(chan_config, trigger_step=False)
        self.analysis = analyze_rld_chan(self.chan, self.effective_cfg_dict, strategy_config, include_chart=True)
        self.session_params.update({"lv_list": lv_list, "chan_config": chan_config, "strategy_config": strategy_config, "watchlist_or_sector": watchlist_or_sector})
        self.matrix_rows = []
        self.matrix_meta = {}
        self.backtest_result = None

    def build_payload(self) -> dict[str, Any]:
        if not self.ready or self.session is None or self.analysis is None:
            return {"ready": False, "message": "请先加载融立得工作台"}
        levels = []
        for snapshot in self.analysis["levels"]:
            item = {"level": snapshot["level"], "label": snapshot["label"], "summary": snapshot["summary"]}
            if snapshot["chart"] is not None:
                item["chart"] = snapshot["chart"]
            levels.append(item)
        return {
            "ready": True,
            "code": self.session.code,
            "name": self.session.stock_name,
            "begin_date": self.session.begin_date,
            "end_date": self.session.end_date,
            "lv_list": [kl_type_to_name(lv) for lv in self.session.lv_list],
            "lv_labels": [kl_type_to_label(lv) for lv in self.session.lv_list],
            "data_source": {"levels": dict(self.session.source_map), "logs": list(self.session.logs)},
            "analysis": {"levels": levels, "aggregate": self.analysis["aggregate"], "level_matrix": self.analysis["level_matrix"], "strategy_config": self.analysis["strategy_config"]},
            "matrix": {"rows": self.matrix_rows, "meta": self.matrix_meta},
            "backtest": self.backtest_result,
        }

    def _require_ready(self) -> None:
        if not self.ready or self.session is None or self.analysis is None or self.session_params is None:
            raise ValueError("请先初始化融立得工作台")

    def build_matrix(self, req: Optional[RldMatrixReq] = None) -> dict[str, Any]:
        self._require_ready()
        assert self.session_params is not None
        codes = parse_watchlist_codes(req.codes) if req and req.codes else []
        source_kind = "manual"
        if not codes:
            source_value = req.watchlist_or_sector if req and req.watchlist_or_sector is not None else self.session_params.get("watchlist_or_sector")
            codes, source_kind = resolve_watchlist_or_sector(source_value)
        if not codes:
            codes = [self.session.code]
            source_kind = "current"
        rows: list[dict[str, Any]] = []
        failures: list[str] = []
        for code in codes:
            try:
                if self.session and code == self.session.code:
                    payload = self.build_payload()
                    rows.append(build_matrix_row(code, payload, stock_name=self.session.stock_name))
                    continue
                session = RldDataSession.load(
                    code,
                    self.session_params["begin_date"],
                    self.session_params["end_date"],
                    self.session_params["autype"],
                    list(self.session_params["lv_list"]),
                )
                chan, effective_cfg_dict = session.build_chan(self.session_params.get("chan_config"), trigger_step=False)
                analysis = analyze_rld_chan(chan, effective_cfg_dict, self.session_params.get("strategy_config"), include_chart=False)
                rows.append(
                    build_matrix_row(
                        code,
                        {
                            "analysis": analysis,
                        },
                        stock_name=session.stock_name,
                    )
                )
            except Exception as exc:
                failures.append(f"{code}:{format_source_error(exc)}")
        rows.sort(key=lambda item: float(item.get("rotation_score", 0.0)), reverse=True)
        avg_chdl = sum(float(item.get("chdl", 0.0)) for item in rows) / len(rows) if rows else 0.0
        buy_breadth = (sum(1 for item in rows if item.get("rld_bs_side") == "buy") / len(rows)) if rows else 0.0
        macd_breadth = (sum(1 for item in rows if float(item.get("three_macd", 0.0)) > 0.0) / len(rows)) if rows else 0.0
        self.matrix_rows = rows
        self.matrix_meta = {
            "source_kind": source_kind,
            "count": len(rows),
            "avg_chdl": round(avg_chdl, 2),
            "buy_breadth": round(buy_breadth, 4),
            "macd_breadth": round(macd_breadth, 4),
            "failures": failures,
        }
        return {"rows": self.matrix_rows, "meta": self.matrix_meta}

    def run_backtest(self, req: RldBacktestReq) -> dict[str, Any]:
        self._require_ready()
        assert self.session_params is not None
        codes = parse_watchlist_codes(req.codes) if req.codes else []
        if not codes:
            source_value = req.watchlist_or_sector if req.watchlist_or_sector is not None else self.session_params.get("watchlist_or_sector")
            codes, _ = resolve_watchlist_or_sector(source_value, limit=12)
        if not codes:
            codes = [self.session.code]
        entry_rules = req.entry_rules or list(RLD_ENTRY_RULES_DEFAULT)
        exit_rules = req.exit_rules or list(RLD_EXIT_RULES_DEFAULT)
        logic = str(req.logic or "and").strip().lower()
        if logic not in {"and", "or"}:
            logic = "and"
        fee = max(0.0, float(req.fee or 0.0))
        slippage = max(0.0, float(req.slippage or 0.0))
        rows: list[dict[str, Any]] = []
        curves: list[dict[str, Any]] = []
        trades: list[dict[str, Any]] = []
        failures: list[str] = []
        for code in codes:
            try:
                session = self.session if self.session and code == self.session.code else RldDataSession.load(
                    code,
                    self.session_params["begin_date"],
                    self.session_params["end_date"],
                    self.session_params["autype"],
                    list(self.session_params["lv_list"]),
                )
                result = run_backtest_for_code(
                    session,
                    self.session_params.get("chan_config", {}),
                    self.session_params.get("strategy_config", {}),
                    entry_rules,
                    exit_rules,
                    logic=logic,
                    fee=fee,
                    slippage=slippage,
                )
                rows.append(
                    {
                        "code": result["code"],
                        "name": result.get("name"),
                        "trade_count": result["trade_count"],
                        "return": result["return"],
                        "max_drawdown": result["max_drawdown"],
                        "win_rate": result["win_rate"],
                        "profit_factor": result["profit_factor"],
                    }
                )
                curves.append({"code": result["code"], "name": result.get("name"), "points": result["equity_curve"]})
                for item in result["trades"]:
                    trade_item = {"code": result["code"], "name": result.get("name"), **item}
                    trades.append(trade_item)
            except Exception as exc:
                failures.append(f"{code}:{format_source_error(exc)}")
        avg_return = sum(float(item.get("return", 0.0)) for item in rows) / len(rows) if rows else 0.0
        avg_mdd = sum(float(item.get("max_drawdown", 0.0)) for item in rows) / len(rows) if rows else 0.0
        self.backtest_result = {
            "params": {
                "entry_rules": entry_rules,
                "exit_rules": exit_rules,
                "logic": logic,
                "execution_mode": "next_open",
                "fee": fee,
                "slippage": slippage,
            },
            "summary": {
                "count": len(rows),
                "avg_return": round(avg_return, 4),
                "avg_max_drawdown": round(avg_mdd, 4),
                "failures": failures,
            },
            "rows": rows,
            "equity_curves": curves,
            "trades": trades[:200],
        }
        return self.backtest_result

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

      <canvas id="chart"></canvas>
    </div>
  </div>
<script>
const $ = (id) => document.getElementById(id);
function markUiBound(id) {
  const el = $(id);
  if (el) el.dataset.bound = "1";
}
const canvas = $("chart");
const ctx = canvas.getContext("2d");
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
let canvasHovered = false;
let signalHoverBoxes = [];
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
  xAxis: { fontSize: 12, rotation: -45, fontWeight: "normal", interval: 10 },
  yAxis: { fontSize: 12, fontWeight: "normal", interval: 0.5 },
  toast: { fontSize: 16, fontWeight: "bold", speed: 3000 },
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
  return next;
}

let savedChartConfig = ensureObject(safeJsonParse(storageGet("chan_chart_config"), {}), {});
let chartConfig = deepMerge(JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG)), migrateChartConfig(savedChartConfig));

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
  stepN: "5"
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
  }, {})
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

function saveSystemConfig() {
  normalizeSystemConfig();
  storageSet("chan_system_config", JSON.stringify(systemConfig));
  rebuildShortcutRegistry();
  updateShortcutUI();
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
    stepN: $("stepN").value
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
  // No longer setting DOM for chip/biZs/segZs here as they are in chartConfig
  if (sessionConfig.stepN !== undefined) $("stepN").value = sessionConfig.stepN;
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
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 24 },
        { label: "文字方向(度)", subKey: "rotation", type: "number", min: -180, max: 180 },
        { label: "文字粗细", subKey: "fontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "刻度间隔(K线)", subKey: "interval", type: "number", min: 1, max: 100 }
      ]
    },
    {
      title: "Y 轴设置",
      key: "yAxis",
      color: "#334155",
      bgColor: "rgba(51, 65, 85, 0.08)",
      items: [
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 24 },
        { label: "文字粗细", subKey: "fontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "刻度间隔(价格)", subKey: "interval", type: "number", min: 0.001, max: 100, step: 0.001 }
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
        { label: "消失速度(ms)", subKey: "speed", type: "number", min: 500, max: 10000, step: 100 }
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
    sec.items.forEach(item => {
      let val;
      if (sec.key === "theme_section") {
        val = chartConfig.theme;
      } else if (sec.key === "indicators") {
        if (item.subKey === "mainSlot") val = selectedMainIndicatorSlot;
        else if (item.subKey === "subSlot") val = selectedSubIndicatorSlot;
        else if (item.subKey === "mainType") val = indicatorMainSlots[String(selectedMainIndicatorSlot)] || [];
        else if (item.subKey === "subType") val = indicatorSubSlots[String(selectedSubIndicatorSlot)] || [];
      } else {
        val = chartConfig[sec.key][item.subKey];
      }
      
      const itemDiv = document.createElement("div");
      itemDiv.className = "settingsItem";
      
      // Add a line preview for sections with color/width
       if (sec.key !== "theme_section" && sec.key !== "indicators" && sec.key !== "toast" && sec.key !== "xAxis" && sec.key !== "yAxis") {
          const previewLine = document.createElement("div");
          previewLine.style.height = "2px";
          previewLine.style.width = "100%";
          previewLine.style.marginBottom = "4px";
          const color = chartConfig[sec.key].color || chartConfig[sec.key].lineColor || chartConfig[sec.key].upColor || "#ccc";
          previewLine.style.background = getCfgColor(color);
          itemDiv.appendChild(previewLine);
       }
       
       if (item.type === "select") {
          let optionsHtml = item.options.map(o => `<option value="${o.value}" ${String(val) === String(o.value) ? "selected" : ""}>${o.label}</option>`).join("");
          itemDiv.innerHTML += `
            <label>${buildLabelHtml(item)}</label>
            <select data-key="${sec.key}" data-subkey="${item.subKey}">${optionsHtml}</select>
          `;
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

function saveSettings() {
  const inputs = $("settingsContent").querySelectorAll("input, select");
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
  storageSet("chan_chart_config", JSON.stringify(chartConfig));
  closeSettings();
  if (lastPayload && lastPayload.ready && lastPayload.chart) draw(lastPayload.chart);
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
  if (confirmAndLog("确定要恢复默认快捷键配置吗？")) {
    systemConfig = JSON.parse(JSON.stringify(DEFAULT_SYSTEM_CONFIG));
    saveSystemConfig();
    renderSystemSettingsForm();
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
$("btnSettingsSave").addEventListener("click", saveSettings);
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

const IDS_SESSION_PARAMS = ["code", "begin", "end", "cash", "autype", "stepN"];
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

canvas.addEventListener(
  "wheel",
  (e) => {
    e.preventDefault();
    const rect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - rect.left;
    const factor = e.deltaY > 0 ? 1 / 1.15 : 1.15;
    if (e.ctrlKey) {
      if (e.deltaY > 0) {
        viewYZoomRatio /= 1.15;
      } else {
        viewYZoomRatio *= 1.15;
      }
      draw(lastPayload.chart);
      return;
    }
    zoomViewAt(factor, mouseX);
  },
  { passive: false }
);

canvas.addEventListener("mousedown", (e) => {
  if (e.button !== 0) return;
  if (!lastPayload || !lastPayload.ready || !viewReady) return;
  isPanning = true;
  panStartX = e.clientX;
  panStartY = e.clientY;
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
  if (chartMouseDownPos) {
    const moved = Math.abs(e.clientX - chartMouseDownPos.x) + Math.abs(e.clientY - chartMouseDownPos.y);
    if (moved >= 6) chartClickMoved = true;
  }
  const rect = canvas.getBoundingClientRect();
  if (e.clientY < rect.top || e.clientY > rect.bottom) return;
  const dx = e.clientX - panStartX;
  const dy = e.clientY - panStartY;
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
  draw(lastPayload.chart);
});

canvas.addEventListener("mousemove", (e) => {
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
  const rawX = e.clientX - rect.left;
  const rawY = e.clientY - rect.top;
  const clampedX = Math.max(PAD_L, Math.min(s.w - PAD_R, rawX));
  
  // Lock X if Ctrl is held
   if (!e.ctrlKey) {
     const targetX = s.xMin + ((clampedX - PAD_L) / Math.max(1, s.plotW)) * (s.xMax - s.xMin);
     const refK = nearestKByX(visibleKs, targetX);
     crosshairX = refK ? s.x(refK.x) : clampedX;
   }
  
   crosshairY = Math.max(PAD_T, Math.min(s.contentBottom, rawY));
   const hoveredSignal = (signalHoverBoxes || []).find((box) => rawX >= box.x1 && rawX <= box.x2 && rawY >= box.y1 && rawY <= box.y2);
   if (hoveredSignal && hoveredSignal.text) {
     showFloatingTip(hoveredSignal.text, e.clientX, e.clientY);
   } else {
     hideFloatingTip();
   }
   draw(lastPayload.chart);
});

canvas.addEventListener("mouseleave", () => {
  canvasHovered = false;
  crosshairX = null;
  crosshairY = null;
  hideFloatingTip();
  if (lastPayload && lastPayload.ready) draw(lastPayload.chart);
});

canvas.addEventListener("dblclick", (e) => {
  if (crosshairX !== null && crosshairY !== null) {
    const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
    const rect = canvas.getBoundingClientRect();
    const xp = (e && typeof e.clientX === "number") ? (e.clientX - rect.left) : crosshairX;
    const yp = (e && typeof e.clientY === "number") ? (e.clientY - rect.top) : crosshairY;
    
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
      draw(lastPayload.chart);
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
      draw(lastPayload.chart);
      return;
    }
  }

  crosshairEnabled = !crosshairEnabled;
  canvas.style.cursor = crosshairEnabled ? "crosshair" : "default";
  if (lastPayload && lastPayload.ready) draw(lastPayload.chart);
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
  chartClickMoved = false;
  chartMouseDownPos = { x: e.clientX, y: e.clientY };
});

canvas.addEventListener("click", (e) => {
  if (!lastPayload || !lastPayload.ready || !viewReady) return;
  if (chartClickMoved) return;
  const rect = canvas.getBoundingClientRect();
  const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
  const y = e.clientY - rect.top;
  const x = e.clientX - rect.left;

  const wantHorizontalRay = !!e.ctrlKey || activeTool === "horizontalRay";
  const wantBiRay = !!e.shiftKey || activeTool === "biRay";

  // Ctrl + Left Click (or toolbox): Horizontal Ray
  if (wantHorizontalRay) {
    const refK = getReferenceK(lastPayload.chart, s);
    if (refK) {
      const yVal = s.yFromPx(y);
      userRays.push({ x: refK.x, y: yVal });
      storageSet("chan_user_rays", JSON.stringify(userRays));
      setMsg(`已生成射线: ${yVal.toFixed(2)}`);
      draw(lastPayload.chart);
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
      draw(lastPayload.chart);
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
    draw(lastPayload.chart);
    return;
  }

  if (activeTool === "none") {
    const picked = pickDrawingAt(s, x, y);
    if (picked) {
      selectedDrawing = picked;
      setMsg(picked.type === "biRay" ? "已选中笔端点射线，可点击“画线属性”编辑。" : "已选中水平射线，可点击“画线属性”编辑。");
      draw(lastPayload.chart);
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
      saveSettings();
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
  if (bspNotice && Array.isArray(bspNotice.lines) && bspNotice.lines.length > 0) {
    sections.push(formatCombinedNoticeSection("买卖点提示", bspNotice.lines));
  }
  const rhythmTexts = getRhythmNoticeTexts(payload);
  if (rhythmTexts.length > 0) {
    sections.push(formatCombinedNoticeSection("1382提示", rhythmTexts));
  }
  if (payload && payload.judge_notice) {
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
  const text = judgeStatsText(payload && payload.judge_stats ? payload.judge_stats : null) || "买卖点判定";
  showToast(text, { record: false });
  setMsg(text, true);
}

function showRhythmHitNotices(payload) {
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

function toScaler(chart, xMin, xMax) {
  const w = canvas.clientWidth;
  const h = canvas.clientHeight;

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
  const tickStep = chartConfig.yAxis.interval || 0.5;
  const startTick = Math.ceil(s.yMin / tickStep);
  const endTick = Math.floor(s.yMax / tickStep);
  ctx.save();
  ctx.strokeStyle = cssVar("--grid", "#e2e8f0");
  ctx.fillStyle = cssVar("--muted", "#475569");
  ctx.font = `${chartConfig.yAxis.fontWeight || "normal"} ${chartConfig.yAxis.fontSize || 12}px Consolas`;
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
    const txt = formatPriceText(p, 2);
    ctx.fillText(txt, 4, y + (chartConfig.yAxis.fontSize / 2.5));
    const tw = ctx.measureText(txt).width;
    ctx.fillText(txt, s.w - tw - 4, y + (chartConfig.yAxis.fontSize / 2.5));
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
  const interval = chartConfig.xAxis.interval || 10;
  const tickXs = [];
  const startX = Math.ceil(s.xMin / interval) * interval;
  for (let x = startX; x <= s.xMax; x += interval) {
    tickXs.push(x);
  }
  const uniq = [...new Set(tickXs)];

  ctx.save();
  ctx.font = `${chartConfig.xAxis.fontWeight || "normal"} ${chartConfig.xAxis.fontSize || 12}px Consolas`;
  for (const x of uniq) {
    const xp = s.x(x);
    ctx.strokeStyle = cssVar("--grid", "#e2e8f0");
    ctx.beginPath();
    ctx.moveTo(xp, yPos);
    ctx.lineTo(xp, yPos + 4);
    ctx.stroke();

    const t = s.xToTime[x];
    if (!t) continue;
    ctx.save();
    ctx.translate(xp, yPos + 20);
    const rad = (chartConfig.xAxis.rotation || -45) * (Math.PI / 180);
    ctx.rotate(rad);
    ctx.fillStyle = cssVar("--muted", "#475569");
    ctx.fillText(t, 0, 0);
    ctx.restore();
  }
  ctx.restore();
}

function drawCrosshair(s) {
  if (!crosshairEnabled || crosshairX === null || crosshairY === null) return;
  const chart = lastPayload && lastPayload.chart ? lastPayload.chart : null;
  if (!chart) return;
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
  }
  if (!isFinite(allMin) || !isFinite(allMax)) return;
  const minTick = Math.floor(allMin * stepMul);
  const maxTick = Math.ceil(allMax * stepMul);
  const tickCount = Math.max(1, maxTick - minTick + 1);
  const arr = new Array(tickCount).fill(0);

  for (const k of useKs) {
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
  const cw = canvas.clientWidth;
  const ch = canvas.clientHeight;
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
  drawCrosshair(s);
  drawLegend();
}

async function api(path, body, method = "POST") {
  const options = {
    method,
    headers: {"Content-Type": "application/json"}
  };
  if (body !== null && body !== undefined) options.body = JSON.stringify(body);
  const res = await fetch(path, options);
  const data = await res.json();
  if (!res.ok) throw new Error(data.detail || JSON.stringify(data));
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
  const payload = await api("/api/step", { judge_mode: systemConfig.bspJudgeMode || "auto" });
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
  const logs = Array.isArray(info.logs) ? info.logs.map((item) => String(item || "").trim()).filter(Boolean) : [];
  el.textContent = `当前数据源：${label}`;
  el.title = logs.join("\n");
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

function refreshUI(payload, options) {
  const afterStep = options && options.afterStep;
  const showStandaloneNotices = options && Object.prototype.hasOwnProperty.call(options, "showStandaloneNotices")
    ? !!options.showStandaloneNotices
    : !afterStep;
  lastPayload = payload;
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
    const ks = payload.chart && payload.chart.kline ? payload.chart.kline : [];
    if (ks.length > 0) {
      allXMin = ks[0].x;
      allXMax = ks[ks.length - 1].x;
      if (!viewReady) {
        viewXMin = allXMin;
        viewXMax = allXMax;
        viewReady = true;
      } else {
        if (!userAdjustedView) {
          // 未手动操作视窗前，始终自动展示全量
          viewXMin = allXMin;
          viewXMax = allXMax;
        } else {
          // 手动操作后仅做边界修正
          if (viewXMin < allXMin) viewXMin = allXMin;
          if (viewXMin >= viewXMax) {
            viewXMin = allXMin;
            viewXMax = allXMax;
            userAdjustedView = false;
          }
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
    const payload = await api("/api/init", {
      code: $("code").value,
      begin_date: $("begin").value,
      end_date: $("end").value || null,
      initial_cash: Number($("cash").value),
      autype: $("autype").value,
      chan_config: processedConfig
    });
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
    sessionFinished = false;
    stepInFlight = false;
    userAdjustedView = false;
    viewReady = false;
    viewYShiftRatio = 0;
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

let rldPayload = null;
let rldCrosshairTime = null;
let rldActiveTopTab = "trainer";
const RLD_LEVEL_OPTIONS = [
  { value: "day", label: "日线" },
  { value: "week", label: "周线" },
  { value: "month", label: "月线" },
  { value: "60m", label: "60分钟" },
  { value: "30m", label: "30分钟" },
  { value: "15m", label: "15分钟" },
  { value: "5m", label: "5分钟" },
  { value: "3m", label: "3分钟" },
  { value: "1m", label: "1分钟" },
];
const RLD_ENTRY_RULE_OPTIONS = [
  { value: "rld_bs_buy", label: "RLD_BS 买入" },
  { value: "one_line", label: "一根筋" },
  { value: "stupid_buy_bi", label: "无脑买入(笔)" },
  { value: "stupid_buy_seg", label: "无脑买入(线段)" },
  { value: "bsp_buy", label: "最近买点" },
  { value: "zs_breakout_up", label: "上离开中枢" },
  { value: "chdl_ge_20", label: "CHDL>=20" },
  { value: "chdl_ge_40", label: "CHDL>=40" },
];
const RLD_EXIT_RULE_OPTIONS = [
  { value: "rld_bs_sell", label: "RLD_BS 卖出" },
  { value: "trend_down", label: "趋势转空" },
  { value: "bsp_sell", label: "最近卖点" },
  { value: "chdl_le_-20", label: "CHDL<=-20" },
  { value: "chdl_le_-40", label: "CHDL<=-40" },
  { value: "take_profit_8", label: "止盈8%" },
  { value: "stop_loss_5", label: "止损5%" },
];

function rldStorageKey(key) {
  return `rld_${key}`;
}

function rldGetStoredJson(key, fallback) {
  return safeJsonParse(storageGet(rldStorageKey(key)), fallback);
}

function rldSetStoredJson(key, value) {
  storageSet(rldStorageKey(key), JSON.stringify(value));
}

function rldInjectStyles() {
  if ($("rldWorkbenchStyles")) return;
  const style = document.createElement("style");
  style.id = "rldWorkbenchStyles";
  style.textContent = `
    .topTabBar {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 10px 14px;
      border-bottom: 1px solid var(--border);
      background: linear-gradient(180deg, rgba(255,255,255,0.96), rgba(241,245,249,0.96));
      position: relative;
      z-index: 40;
    }
    .topTabBar .tabButton {
      border-radius: 999px;
      padding: 8px 16px;
      font-weight: 700;
      background: rgba(255,255,255,0.75);
      border: 1px solid var(--border);
      width: auto;
      text-align: center;
    }
    .topTabBar .tabButton.active {
      background: #0f172a;
      color: #fff;
      border-color: #0f172a;
      box-shadow: 0 8px 24px rgba(15, 23, 42, 0.2);
    }
    #topPageShell {
      height: calc(100vh - 58px);
      overflow: hidden;
    }
    .topPage {
      display: none;
      height: 100%;
    }
    .topPage.active {
      display: block;
    }
    .topPage .wrap {
      height: 100%;
    }
    .rldWorkbench {
      display: grid;
      grid-template-columns: 360px minmax(0, 1fr);
      gap: 14px;
      height: 100%;
      padding: 14px;
      box-sizing: border-box;
      background:
        radial-gradient(circle at top right, rgba(14,165,233,0.12), transparent 28%),
        radial-gradient(circle at bottom left, rgba(249,115,22,0.12), transparent 32%),
        linear-gradient(180deg, #f8fafc, #eef2f7);
    }
    .rldSidebar, .rldMain {
      min-height: 0;
      display: flex;
      flex-direction: column;
      gap: 12px;
    }
    .rldCard, .rldPanel {
      border: 1px solid rgba(148,163,184,0.5);
      background: rgba(255,255,255,0.92);
      border-radius: 16px;
      box-shadow: 0 10px 30px rgba(15,23,42,0.08);
      padding: 14px;
      min-height: 0;
      backdrop-filter: blur(6px);
    }
    .rldCardTitle {
      font-size: 15px;
      font-weight: 800;
      margin-bottom: 12px;
      color: #0f172a;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .rldStatus {
      color: #334155;
      font-size: 12px;
      white-space: pre-wrap;
      line-height: 1.6;
      max-height: 140px;
      overflow: auto;
    }
    .rldFormGrid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
    }
    .rldField {
      display: flex;
      flex-direction: column;
      gap: 6px;
    }
    .rldField.full {
      grid-column: 1 / -1;
    }
    .rldField label {
      width: auto;
      font-size: 12px;
      color: #475569;
      font-weight: 700;
    }
    .rldField input, .rldField select, .rldField textarea {
      width: 100%;
      box-sizing: border-box;
      border-radius: 10px;
      border: 1px solid rgba(148,163,184,0.6);
      background: rgba(255,255,255,0.92);
      padding: 8px 10px;
      resize: vertical;
    }
    .rldActions {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 8px;
      margin-top: 10px;
    }
    .rldActions button {
      width: 100%;
      text-align: center;
      border-radius: 12px;
      padding: 9px 10px;
      font-weight: 700;
    }
    .rldRuleList {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 6px;
      font-size: 12px;
    }
    .rldRuleItem {
      display: flex;
      align-items: center;
      gap: 6px;
      border: 1px solid rgba(226,232,240,0.8);
      border-radius: 10px;
      padding: 6px 8px;
      background: rgba(248,250,252,0.85);
    }
    .rldRuleItem input {
      width: auto;
      flex: none;
    }
    .rldHeaderBar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
      margin-bottom: 4px;
    }
    .rldHeaderText {
      font-weight: 800;
      color: #0f172a;
      font-size: 18px;
    }
    .rldHeaderSub {
      color: #64748b;
      font-size: 12px;
    }
    .rldSummaryGrid {
      display: grid;
      grid-template-columns: repeat(6, minmax(0, 1fr));
      gap: 10px;
    }
    .rldSummaryCard {
      border-radius: 14px;
      padding: 12px;
      background: linear-gradient(180deg, rgba(255,255,255,0.98), rgba(241,245,249,0.95));
      border: 1px solid rgba(148,163,184,0.45);
      min-height: 88px;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      gap: 6px;
    }
    .rldSummaryCard .k {
      font-size: 11px;
      color: #64748b;
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }
    .rldSummaryCard .v {
      font-size: 22px;
      font-weight: 800;
      color: #0f172a;
    }
    .rldSummaryCard .d {
      font-size: 12px;
      color: #475569;
    }
    .rldChartStack {
      display: grid;
      grid-template-rows: repeat(3, minmax(0, 1fr));
      gap: 10px;
      min-height: 0;
      flex: 1;
    }
    .rldChartCard {
      border: 1px solid rgba(148,163,184,0.55);
      background: rgba(255,255,255,0.95);
      border-radius: 16px;
      padding: 10px;
      min-height: 0;
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .rldChartHead {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 12px;
      color: #475569;
      font-weight: 700;
    }
    .rldChartCanvas {
      width: 100%;
      height: 210px;
      display: block;
      border-radius: 12px;
      background:
        linear-gradient(180deg, rgba(255,255,255,0.95), rgba(248,250,252,0.95)),
        linear-gradient(90deg, rgba(148,163,184,0.08), transparent);
      border: 1px solid rgba(226,232,240,0.85);
    }
    .rldBottomGrid {
      display: grid;
      grid-template-columns: 1.15fr 1fr;
      gap: 12px;
      min-height: 280px;
    }
    .rldScroll {
      min-height: 0;
      overflow: auto;
    }
    .rldPerspectiveTime {
      font-size: 16px;
      font-weight: 800;
      color: #0f172a;
      margin-bottom: 10px;
    }
    .rldPerspectiveGrid {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 10px;
    }
    .rldPerspectiveCard {
      border-radius: 12px;
      border: 1px solid rgba(148,163,184,0.35);
      background: rgba(248,250,252,0.92);
      padding: 10px;
      font-size: 12px;
      color: #334155;
      line-height: 1.6;
    }
    .rldTable {
      width: 100%;
      border-collapse: collapse;
      font-size: 12px;
    }
    .rldTable th, .rldTable td {
      border-bottom: 1px solid rgba(226,232,240,0.9);
      padding: 8px 6px;
      text-align: left;
      white-space: nowrap;
    }
    .rldTable th {
      position: sticky;
      top: 0;
      background: rgba(248,250,252,0.98);
      z-index: 1;
    }
    .rldBadge {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      border-radius: 999px;
      padding: 2px 10px;
      font-size: 11px;
      font-weight: 700;
      background: rgba(226,232,240,0.75);
      color: #0f172a;
    }
    .rldBadge.buy {
      background: rgba(220,38,38,0.12);
      color: #b91c1c;
    }
    .rldBadge.sell {
      background: rgba(22,163,74,0.12);
      color: #15803d;
    }
    .rldMetaRow {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-bottom: 8px;
      font-size: 12px;
      color: #475569;
    }
    @media (max-width: 1380px) {
      .rldWorkbench {
        grid-template-columns: 320px minmax(0, 1fr);
      }
      .rldSummaryGrid {
        grid-template-columns: repeat(3, minmax(0, 1fr));
      }
      .rldBottomGrid {
        grid-template-columns: 1fr;
      }
    }
    @media (max-width: 1024px) {
      .rldWorkbench {
        grid-template-columns: 1fr;
      }
      .rldSummaryGrid, .rldPerspectiveGrid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }
    }
  `;
  document.head.appendChild(style);
}

function rldRuleHtml(name, options, checked) {
  return options.map((item) => {
    const isChecked = checked.includes(item.value) ? "checked" : "";
    return `<label class="rldRuleItem"><input type="checkbox" name="${name}" value="${item.value}" ${isChecked} /> <span>${item.label}</span></label>`;
  }).join("");
}

function rldWorkbenchMarkup() {
  const saved = ensureObject(rldGetStoredJson("form", {}), {});
  const entryRules = ensureArray(saved.entry_rules, ["rld_bs_buy", "one_line"]);
  const exitRules = ensureArray(saved.exit_rules, ["rld_bs_sell", "trend_down"]);
  return `
    <div class="rldWorkbench">
      <div class="rldSidebar">
        <div class="rldCard">
          <div class="rldCardTitle">融立得高级工作台</div>
          <div class="rldFormGrid">
            <div class="rldField"><label>代码</label><input id="rldCode" value="${escapeHtmlAttr(saved.code || "600340")}" /></div>
            <div class="rldField"><label>复权</label><select id="rldAutype"><option value="qfq">前复权</option><option value="hfq">后复权</option><option value="none">不复权</option></select></div>
            <div class="rldField"><label>开始日期</label><input id="rldBegin" type="date" value="${escapeHtmlAttr(saved.begin_date || "2018-01-01")}" /></div>
            <div class="rldField"><label>结束日期</label><input id="rldEnd" type="date" value="${escapeHtmlAttr(saved.end_date || "")}" /></div>
            <div class="rldField"><label>周期1</label><select id="rldLv1"></select></div>
            <div class="rldField"><label>周期2</label><select id="rldLv2"></select></div>
            <div class="rldField"><label>周期3</label><select id="rldLv3"></select></div>
            <div class="rldField"><label>逻辑</label><select id="rldRuleLogic"><option value="and">AND</option><option value="or">OR</option></select></div>
            <div class="rldField full"><label>股票池 / 板块</label><textarea id="rldWatchlist" rows="3" placeholder="输入 600340,000001,600519 或板块名">${escapeHtmlAttr(saved.watchlist_or_sector || "600340,000001,600519")}</textarea></div>
            <div class="rldField"><label>权重1</label><input id="rldWeight1" type="number" step="1" value="${escapeHtmlAttr(saved.weight1 || "50")}" /></div>
            <div class="rldField"><label>权重2</label><input id="rldWeight2" type="number" step="1" value="${escapeHtmlAttr(saved.weight2 || "30")}" /></div>
            <div class="rldField"><label>权重3</label><input id="rldWeight3" type="number" step="1" value="${escapeHtmlAttr(saved.weight3 || "20")}" /></div>
            <div class="rldField"><label>手续费</label><input id="rldFee" type="number" step="0.0001" value="${escapeHtmlAttr(saved.fee || "0.001")}" /></div>
            <div class="rldField"><label>滑点</label><input id="rldSlippage" type="number" step="0.0001" value="${escapeHtmlAttr(saved.slippage || "0.0005")}" /></div>
          </div>
          <div class="rldActions">
            <button id="rldBtnInit">加载工作台</button>
            <button id="rldBtnReconfig">应用配置</button>
            <button id="rldBtnMatrix">刷新矩阵</button>
            <button id="rldBtnBacktest">运行回测</button>
            <button id="rldBtnReset">重置</button>
          </div>
        </div>
        <div class="rldCard">
          <div class="rldCardTitle">回测规则</div>
          <div class="rldField full">
            <label>入场规则</label>
            <div class="rldRuleList">${rldRuleHtml("rldEntryRule", RLD_ENTRY_RULE_OPTIONS, entryRules)}</div>
          </div>
          <div class="rldField full" style="margin-top:10px;">
            <label>出场规则</label>
            <div class="rldRuleList">${rldRuleHtml("rldExitRule", RLD_EXIT_RULE_OPTIONS, exitRules)}</div>
          </div>
        </div>
        <div class="rldCard">
          <div class="rldCardTitle">状态 / 数据源</div>
          <div id="rldStatus" class="rldStatus">等待加载...</div>
        </div>
      </div>
      <div class="rldMain">
        <div class="rldPanel">
          <div class="rldHeaderBar">
            <div>
              <div class="rldHeaderText">融立得多周期联动 / 多级联立工作台</div>
              <div id="rldHeaderSub" class="rldHeaderSub">尚未加载数据</div>
            </div>
            <div id="rldHeaderBadge" class="rldBadge">空闲</div>
          </div>
          <div id="rldSummaryGrid" class="rldSummaryGrid"></div>
        </div>
        <div class="rldChartStack">
          <div class="rldChartCard"><div id="rldChartHead1" class="rldChartHead">周期1</div><canvas id="rldChart1" class="rldChartCanvas"></canvas></div>
          <div class="rldChartCard"><div id="rldChartHead2" class="rldChartHead">周期2</div><canvas id="rldChart2" class="rldChartCanvas"></canvas></div>
          <div class="rldChartCard"><div id="rldChartHead3" class="rldChartHead">周期3</div><canvas id="rldChart3" class="rldChartCanvas"></canvas></div>
        </div>
        <div class="rldBottomGrid">
          <div class="rldPanel rldScroll">
            <div class="rldCardTitle">时间线 / 透视窗</div>
            <div id="rldPerspective"></div>
          </div>
          <div class="rldPanel rldScroll">
            <div class="rldCardTitle">个股矩阵 / 板块轮动</div>
            <div id="rldMatrixContainer"></div>
          </div>
        </div>
        <div class="rldPanel rldScroll">
          <div class="rldCardTitle">回归评测系统</div>
          <div id="rldBacktestContainer"></div>
        </div>
      </div>
    </div>
  `;
}

function rldEnsureShell() {
  rldInjectStyles();
  if ($("topPageShell")) return;
  const wrap = document.querySelector(".wrap");
  if (!wrap) return;
  const tabBar = document.createElement("div");
  tabBar.id = "topTabBar";
  tabBar.className = "topTabBar";
  tabBar.innerHTML = `
    <button id="topTabTrainer" class="tabButton active" type="button">chan.py 复盘训练器</button>
    <button id="topTabRld" class="tabButton" type="button">融立得</button>
  `;
  const shell = document.createElement("div");
  shell.id = "topPageShell";
  const trainerPage = document.createElement("div");
  trainerPage.id = "pageTrainer";
  trainerPage.className = "topPage active";
  const rldPage = document.createElement("div");
  rldPage.id = "pageRld";
  rldPage.className = "topPage";
  rldPage.innerHTML = rldWorkbenchMarkup();
  wrap.parentNode.insertBefore(tabBar, wrap);
  wrap.parentNode.insertBefore(shell, wrap);
  trainerPage.appendChild(wrap);
  shell.appendChild(trainerPage);
  shell.appendChild(rldPage);
}

function rldPopulateLevelSelect(id, value) {
  const el = $(id);
  if (!el) return;
  el.innerHTML = RLD_LEVEL_OPTIONS.map((item) => `<option value="${item.value}">${item.label}</option>`).join("");
  el.value = value;
}

function rldSaveForm() {
  const form = rldCollectForm();
  rldSetStoredJson("form", {
    ...form,
    weight1: $("rldWeight1") ? $("rldWeight1").value : "50",
    weight2: $("rldWeight2") ? $("rldWeight2").value : "30",
    weight3: $("rldWeight3") ? $("rldWeight3").value : "20",
    fee: $("rldFee") ? $("rldFee").value : "0.001",
    slippage: $("rldSlippage") ? $("rldSlippage").value : "0.0005",
    entry_rules: rldGetSelectedRules("rldEntryRule"),
    exit_rules: rldGetSelectedRules("rldExitRule"),
  });
}

function rldSetStatus(text, tone = "idle") {
  const el = $("rldStatus");
  if (el) el.textContent = text || "等待加载...";
  const badge = $("rldHeaderBadge");
  if (badge) {
    badge.textContent = tone === "error" ? "错误" : tone === "busy" ? "处理中" : tone === "ready" ? "已就绪" : "空闲";
    badge.className = `rldBadge ${tone === "error" ? "sell" : tone === "ready" ? "buy" : ""}`;
  }
}

function rldCollectForm() {
  const lvList = [
    $("rldLv1") ? $("rldLv1").value : "day",
    $("rldLv2") ? $("rldLv2").value : "60m",
    $("rldLv3") ? $("rldLv3").value : "15m",
  ];
  return {
    code: $("rldCode") ? $("rldCode").value : "600340",
    begin_date: $("rldBegin") ? $("rldBegin").value : "2018-01-01",
    end_date: $("rldEnd") && $("rldEnd").value ? $("rldEnd").value : null,
    autype: $("rldAutype") ? $("rldAutype").value : "qfq",
    lv_list: lvList,
    watchlist_or_sector: $("rldWatchlist") ? $("rldWatchlist").value : "",
    strategy_config: {
      weights: [
        Number($("rldWeight1") ? $("rldWeight1").value : 50),
        Number($("rldWeight2") ? $("rldWeight2").value : 30),
        Number($("rldWeight3") ? $("rldWeight3").value : 20),
      ]
    },
    chan_config: {
      chan_algo: chanConfig.chan_algo,
      bi_strict: chanConfig.bi_strict,
      bi_algo: chanConfig.bi_algo,
      bi_fx_check: chanConfig.bi_fx_check,
      gap_as_kl: chanConfig.gap_as_kl,
      bi_end_is_peak: chanConfig.bi_end_is_peak,
      bi_allow_sub_peak: chanConfig.bi_allow_sub_peak,
      seg_algo: chanConfig.seg_algo,
      left_seg_method: chanConfig.left_seg_method,
      zs_algo: chanConfig.zs_algo,
      zs_combine: chanConfig.zs_combine,
      zs_combine_mode: chanConfig.zs_combine_mode,
      one_bi_zs: chanConfig.one_bi_zs,
      divergence_rate: chanConfig.divergence_rate,
      min_zs_cnt: chanConfig.min_zs_cnt,
      bsp1_only_multibi_zs: chanConfig.bsp1_only_multibi_zs,
      max_bs2_rate: chanConfig.max_bs2_rate,
      macd_algo: chanConfig.macd_algo,
      bs1_peak: chanConfig.bs1_peak,
      bs_type: chanConfig.bs_type,
      bsp2_follow_1: chanConfig.bsp2_follow_1,
      bsp3_follow_1: chanConfig.bsp3_follow_1,
      bsp3_peak: chanConfig.bsp3_peak,
      bsp2s_follow_2: chanConfig.bsp2s_follow_2,
      max_bsp2s_lv: chanConfig.max_bsp2s_lv,
      strict_bsp3: chanConfig.strict_bsp3,
      bsp3a_max_zs_cnt: chanConfig.bsp3a_max_zs_cnt,
      macd: chanConfig.macd,
    },
  };
}

function rldGetSelectedRules(name) {
  return Array.from(document.querySelectorAll(`input[name="${name}"]:checked`)).map((node) => node.value);
}

async function rldCall(path, body, method = "POST", loadingText = "融立得工作台处理中...") {
  setGlobalLoading(true, loadingText);
  try {
    return await api(path, body, method);
  } finally {
    hideGlobalLoading();
  }
}

function rldNumber(value, digits = 2) {
  if (value === null || value === undefined || value === "" || Number.isNaN(Number(value))) return "-";
  return Number(value).toFixed(digits);
}

function rldPct(value, digits = 2) {
  if (value === null || value === undefined || value === "" || Number.isNaN(Number(value))) return "-";
  return `${(Number(value) * 100).toFixed(digits)}%`;
}

function rldSideBadge(side) {
  const cls = side === "buy" ? "buy" : side === "sell" ? "sell" : "";
  const text = side === "buy" ? "偏多" : side === "sell" ? "偏空" : "中性";
  return `<span class="rldBadge ${cls}">${text}</span>`;
}

function rldRenderSummary(payload) {
  const grid = $("rldSummaryGrid");
  if (!grid) return;
  if (!payload || !payload.ready || !payload.analysis) {
    grid.innerHTML = `<div class="rldSummaryCard"><div class="k">状态</div><div class="v">未加载</div><div class="d">请先加载融立得工作台。</div></div>`;
    return;
  }
  const agg = payload.analysis.aggregate || {};
  const rows = [
    { k: "CHDL", v: rldNumber(agg.weighted_chdl), d: "结构方向 + 中枢位置 + BSP + MACD 面积的综合分" },
    { k: "三级别 MACD", v: rldNumber(agg.three_macd), d: "三周期 MACD 动量加权结果" },
    { k: "一根筋", v: agg.one_line ? "是" : "否", d: "三周期同向且最近无明显逆向破坏" },
    { k: "无脑买入(笔)", v: agg.stupid_buy_bi ? "触发" : "未触发", d: "激进笔级模板" },
    { k: "无脑买入(线段)", v: agg.stupid_buy_seg ? "触发" : "未触发", d: "激进线段模板" },
    { k: "RLD_BS", v: `${agg.rld_bs ? rldNumber(agg.rld_bs.score) : "-"} ${agg.rld_bs ? (agg.rld_bs.side || "neutral") : ""}`, d: agg.rld_bs && agg.rld_bs.reasons ? compactReasText(agg.rld_bs.reasons) : "解释型交易建议" },
  ];
  grid.innerHTML = rows.map((item) => `<div class="rldSummaryCard"><div class="k">${item.k}</div><div class="v">${item.v}</div><div class="d">${item.d}</div></div>`).join("");
}

function compactReasText(reasons) {
  return ensureArray(reasons, []).slice(0, 3).join("；") || "-";
}

function rldRenderHeader(payload) {
  const headerSub = $("rldHeaderSub");
  if (!headerSub) return;
  if (!payload || !payload.ready) {
    headerSub.textContent = "尚未加载数据";
    return;
  }
  const lvLabels = ensureArray(payload.lv_labels, []).join(" / ");
  headerSub.textContent = `${payload.name || payload.code} | ${lvLabels}`;
}

function rldRenderStatus(payload, fallbackText) {
  if (fallbackText) {
    rldSetStatus(fallbackText, payload && payload.ready ? "ready" : "idle");
    return;
  }
  if (!payload || !payload.ready) {
    rldSetStatus("请先加载融立得工作台。");
    return;
  }
  const logs = payload.data_source && payload.data_source.logs ? payload.data_source.logs : [];
  const lines = [
    `标的：${payload.name || payload.code}`,
    `周期：${ensureArray(payload.lv_labels, []).join(" / ")}`,
    ...logs,
  ];
  rldSetStatus(lines.join("\n"), "ready");
}

function rldFindNearestK(chart, timeText) {
  const ks = chart && chart.kline ? chart.kline : [];
  if (ks.length <= 0) return null;
  if (!timeText) return ks[ks.length - 1];
  const target = rldToTs(timeText);
  let best = ks[0];
  let bestGap = Math.abs(rldToTs(best.t) - target);
  for (const item of ks) {
    const gap = Math.abs(rldToTs(item.t) - target);
    if (gap < bestGap) {
      best = item;
      bestGap = gap;
    }
  }
  return best;
}

function rldToTs(text) {
  const raw = String(text || "").trim().replace(/\//g, "-");
  const dt = new Date(raw);
  const t = dt.getTime();
  return Number.isFinite(t) ? t : 0;
}

function rldChartColor(kind) {
  const palette = {
    candleUp: "#dc2626",
    candleDown: "#16a34a",
    bi: "#f59e0b",
    seg: "#059669",
    segseg: "#2563eb",
    zs: "rgba(14,165,233,0.12)",
    macdPos: "rgba(220,38,38,0.45)",
    macdNeg: "rgba(22,163,74,0.45)",
    cross: "#0f172a",
  };
  return palette[kind] || "#334155";
}

function rldPrepareCanvas(canvas) {
  if (!canvas) return null;
  const rect = canvas.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const width = Math.max(320, Math.floor(rect.width));
  const height = Math.max(180, Math.floor(rect.height || 210));
  if (canvas.width !== Math.floor(width * dpr) || canvas.height !== Math.floor(height * dpr)) {
    canvas.width = Math.floor(width * dpr);
    canvas.height = Math.floor(height * dpr);
  }
  const ctx2 = canvas.getContext("2d");
  ctx2.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { ctx: ctx2, width, height };
}

function rldDrawChart(canvas, levelItem) {
  const prepared = rldPrepareCanvas(canvas);
  if (!prepared) return;
  const { ctx: ctx2, width, height } = prepared;
  ctx2.clearRect(0, 0, width, height);
  ctx2.fillStyle = "#ffffff";
  ctx2.fillRect(0, 0, width, height);
  if (!levelItem || !levelItem.chart || !Array.isArray(levelItem.chart.kline) || levelItem.chart.kline.length <= 0) {
    ctx2.fillStyle = "#64748b";
    ctx2.font = "12px Arial";
    ctx2.fillText("暂无数据", 20, 24);
    return;
  }
  const chart = levelItem.chart;
  const ks = chart.kline;
  const padL = 56;
  const padR = 14;
  const padT = 16;
  const padB = 26;
  const macdH = Math.max(38, Math.floor(height * 0.2));
  const priceH = height - macdH - padT - padB - 8;
  const maxPrice = Math.max(...ks.map((k) => Number(k.h)), ...chart.seg_zs.map((z) => Number(z.high)));
  const minPrice = Math.min(...ks.map((k) => Number(k.l)), ...chart.seg_zs.map((z) => Number(z.low)));
  const range = Math.max(1e-6, maxPrice - minPrice);
  const stepX = (width - padL - padR) / Math.max(1, ks.length - 1);
  const xByIndex = (idx) => padL + idx * stepX;
  const yByPrice = (price) => padT + priceH - ((price - minPrice) / range) * priceH;
  const macdItems = chart.indicators || [];
  const macdAbs = Math.max(1e-6, ...macdItems.map((item) => Math.abs(Number(item.macd && item.macd.macd || 0))));
  const macdBaseY = padT + priceH + 12 + macdH / 2;
  const macdScale = (macdH / 2 - 8) / macdAbs;

  ctx2.strokeStyle = "rgba(148,163,184,0.35)";
  ctx2.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const y = padT + (priceH / 4) * i;
    ctx2.beginPath();
    ctx2.moveTo(padL, y);
    ctx2.lineTo(width - padR, y);
    ctx2.stroke();
  }
  ctx2.fillStyle = "#64748b";
  ctx2.font = "11px Arial";
  for (let i = 0; i <= 4; i++) {
    const price = maxPrice - (range / 4) * i;
    const y = padT + (priceH / 4) * i;
    ctx2.fillText(Number(price).toFixed(2), 8, y + 4);
  }

  for (let i = 0; i < ks.length; i++) {
    const k = ks[i];
    const x = xByIndex(i);
    const openY = yByPrice(Number(k.o));
    const closeY = yByPrice(Number(k.c));
    const highY = yByPrice(Number(k.h));
    const lowY = yByPrice(Number(k.l));
    const isUp = Number(k.c) >= Number(k.o);
    ctx2.strokeStyle = isUp ? rldChartColor("candleUp") : rldChartColor("candleDown");
    ctx2.beginPath();
    ctx2.moveTo(x, highY);
    ctx2.lineTo(x, lowY);
    ctx2.stroke();
    ctx2.fillStyle = isUp ? "rgba(220,38,38,0.2)" : "rgba(22,163,74,0.55)";
    const bodyY = Math.min(openY, closeY);
    const bodyH = Math.max(2, Math.abs(closeY - openY));
    ctx2.fillRect(x - Math.max(1.4, stepX * 0.24), bodyY, Math.max(3, stepX * 0.48), bodyH);
  }

  const drawLineSet = (arr, color, widthPx) => {
    ctx2.strokeStyle = color;
    ctx2.lineWidth = widthPx;
    for (const line of arr || []) {
      ctx2.beginPath();
      ctx2.moveTo(xByIndex(Number(line.x1)), yByPrice(Number(line.y1)));
      ctx2.lineTo(xByIndex(Number(line.x2)), yByPrice(Number(line.y2)));
      ctx2.stroke();
    }
  };
  const drawZsSet = (arr, stroke, fill) => {
    for (const zs of arr || []) {
      const x1 = xByIndex(Number(zs.x1));
      const x2 = xByIndex(Number(zs.x2));
      const y1 = yByPrice(Number(zs.high));
      const y2 = yByPrice(Number(zs.low));
      ctx2.fillStyle = fill;
      ctx2.fillRect(x1, y1, Math.max(4, x2 - x1), Math.max(4, y2 - y1));
      ctx2.strokeStyle = stroke;
      ctx2.lineWidth = 1;
      ctx2.strokeRect(x1, y1, Math.max(4, x2 - x1), Math.max(4, y2 - y1));
    }
  };
  drawZsSet(chart.bi_zs || [], "rgba(249,115,22,0.45)", "rgba(249,115,22,0.08)");
  drawZsSet(chart.seg_zs || [], "rgba(14,165,233,0.45)", "rgba(14,165,233,0.08)");
  drawLineSet(chart.bi || [], rldChartColor("bi"), 1.3);
  drawLineSet(chart.seg || [], rldChartColor("seg"), 2.0);
  drawLineSet(chart.segseg || [], rldChartColor("segseg"), 2.6);

  for (const item of chart.bsp || []) {
    const x = xByIndex(Number(item.x));
    const y = item.is_buy ? yByPrice(Number(item.y)) + 14 : yByPrice(Number(item.y)) - 12;
    ctx2.fillStyle = item.is_buy ? "#b91c1c" : "#15803d";
    ctx2.font = "bold 11px Arial";
    ctx2.fillText(item.display_label || item.label || "", x - 10, y);
  }

  ctx2.strokeStyle = "rgba(100,116,139,0.35)";
  ctx2.beginPath();
  ctx2.moveTo(padL, macdBaseY);
  ctx2.lineTo(width - padR, macdBaseY);
  ctx2.stroke();
  for (let i = 0; i < macdItems.length; i++) {
    const item = macdItems[i];
    const x = xByIndex(i);
    const val = Number(item.macd && item.macd.macd || 0);
    const barH = val * macdScale;
    ctx2.strokeStyle = val >= 0 ? rldChartColor("macdPos") : rldChartColor("macdNeg");
    ctx2.beginPath();
    ctx2.moveTo(x, macdBaseY);
    ctx2.lineTo(x, macdBaseY - barH);
    ctx2.stroke();
  }

  const selectedK = rldFindNearestK(chart, rldCrosshairTime);
  if (selectedK) {
    const idx = ks.findIndex((item) => Number(item.x) === Number(selectedK.x));
    const x = xByIndex(Math.max(0, idx));
    ctx2.strokeStyle = rldChartColor("cross");
    ctx2.setLineDash([5, 4]);
    ctx2.beginPath();
    ctx2.moveTo(x, padT);
    ctx2.lineTo(x, height - padB);
    ctx2.stroke();
    ctx2.setLineDash([]);
    ctx2.fillStyle = "#0f172a";
    ctx2.font = "11px Arial";
    ctx2.fillText(String(selectedK.t), Math.max(padL, x - 50), height - 8);
  }
}

function rldDrawAllCharts() {
  if (!rldPayload || !rldPayload.ready || !rldPayload.analysis) return;
  const levels = ensureArray(rldPayload.analysis.levels, []);
  for (let i = 0; i < 3; i++) {
    const levelItem = levels[i];
    const head = $(`rldChartHead${i + 1}`);
    if (head) {
      head.innerHTML = levelItem ? `${levelItem.label} <span>${levelItem.summary ? `${levelItem.summary.trend_label} / CHDL ${rldNumber(levelItem.summary.chdl_score)}` : ""}</span>` : `周期${i + 1}`;
    }
    rldDrawChart($(`rldChart${i + 1}`), levelItem);
  }
}

function rldRenderPerspective() {
  const box = $("rldPerspective");
  if (!box) return;
  if (!rldPayload || !rldPayload.ready || !rldPayload.analysis) {
    box.innerHTML = `<div class="rldPerspectiveTime">等待加载</div>`;
    return;
  }
  const levels = ensureArray(rldPayload.analysis.levels, []);
  let pivotTime = rldCrosshairTime;
  if (!pivotTime && levels[0] && levels[0].chart && levels[0].chart.kline && levels[0].chart.kline.length > 0) {
    pivotTime = levels[0].chart.kline[levels[0].chart.kline.length - 1].t;
  }
  const cards = levels.map((level) => {
    const nearest = rldFindNearestK(level.chart, pivotTime);
    const ind = ensureArray(level.chart && level.chart.indicators, []).find((item) => nearest && Number(item.x) === Number(nearest.x));
    return `
      <div class="rldPerspectiveCard">
        <div style="font-weight:800;color:#0f172a;margin-bottom:6px;">${level.label}</div>
        <div>时间：${nearest ? nearest.t : "-"}</div>
        <div>OHLC：${nearest ? `${rldNumber(nearest.o, 3)} / ${rldNumber(nearest.h, 3)} / ${rldNumber(nearest.l, 3)} / ${rldNumber(nearest.c, 3)}` : "-"}</div>
        <div>趋势：${level.summary.trend_label}</div>
        <div>BSP：${level.summary.latest_bsp ? level.summary.latest_bsp.display_label : "无"}</div>
        <div>中枢：${level.summary.zs_state.kind}${level.summary.zs_state.label}</div>
        <div>MACD：${ind && ind.macd ? rldNumber(ind.macd.macd, 4) : "-"}</div>
        <div>笔面积 / 段面积：${rldNumber(level.summary.macd_bi_area, 3)} / ${rldNumber(level.summary.macd_seg_area, 3)}</div>
        <div>CHDL：${rldNumber(level.summary.chdl_score)}</div>
      </div>
    `;
  }).join("");
  const agg = rldPayload.analysis.aggregate || {};
  box.innerHTML = `
    <div class="rldPerspectiveTime">${pivotTime || "-"}</div>
    <div class="rldMetaRow">
      ${rldSideBadge(agg.rld_bs ? agg.rld_bs.side : "neutral")}
      <span>RLD_BS 分数：${agg.rld_bs ? rldNumber(agg.rld_bs.score) : "-"}</span>
      <span>一根筋：${agg.one_line ? "是" : "否"}</span>
      <span>无脑买入(笔)：${agg.stupid_buy_bi ? "是" : "否"}</span>
      <span>无脑买入(线段)：${agg.stupid_buy_seg ? "是" : "否"}</span>
    </div>
    <div class="rldPerspectiveGrid">${cards}</div>
    <div style="margin-top:10px;font-size:12px;color:#475569;line-height:1.6;">${agg.rld_bs && agg.rld_bs.reasons ? compactReasText(agg.rld_bs.reasons) : "-"}</div>
  `;
}

function rldRenderLevelMatrix(payload) {
  const target = $("rldMatrixContainer");
  if (!target) return;
  if (!payload || !payload.analysis || !Array.isArray(payload.analysis.level_matrix)) {
    target.innerHTML = `<div class="muted">尚未生成矩阵。</div>`;
    return;
  }
  const headers = ensureArray(payload.lv_labels, []);
  const rows = ensureArray(payload.analysis.level_matrix, []);
  const matrixTable = `
    <div class="rldCardTitle" style="margin-top:0;">当前标的矩阵</div>
    <div class="rldScroll" style="max-height:220px;">
      <table class="rldTable">
        <thead><tr><th>指标</th>${headers.map((h) => `<th>${h}</th>`).join("")}</tr></thead>
        <tbody>
          ${rows.map((row) => `<tr><td>${row.metric || "-"}</td>${headers.map((h) => `<td>${row[h] || "-"}</td>`).join("")}</tr>`).join("")}
        </tbody>
      </table>
    </div>
  `;
  const multi = payload.matrix && payload.matrix.rows && payload.matrix.rows.length > 0 ? `
    <div class="rldCardTitle" style="margin-top:14px;">多股矩阵 / 板块轮动</div>
    <div class="rldMetaRow">
      <span>标的数：${payload.matrix.meta ? payload.matrix.meta.count : 0}</span>
      <span>平均 CHDL：${payload.matrix.meta ? rldNumber(payload.matrix.meta.avg_chdl) : "-"}</span>
      <span>买入广度：${payload.matrix.meta ? rldPct(payload.matrix.meta.buy_breadth, 1) : "-"}</span>
      <span>MACD 广度：${payload.matrix.meta ? rldPct(payload.matrix.meta.macd_breadth, 1) : "-"}</span>
    </div>
    <div class="rldScroll" style="max-height:280px;">
      <table class="rldTable">
        <thead>
          <tr>
            <th>代码</th><th>名称</th><th>轮动分</th><th>CHDL</th><th>三级别MACD</th><th>一根筋</th><th>无脑买入(笔)</th><th>无脑买入(段)</th><th>RLD_BS</th><th>原因</th>
          </tr>
        </thead>
        <tbody>
          ${payload.matrix.rows.map((row) => `
            <tr>
              <td>${row.code || "-"}</td>
              <td>${row.name || "-"}</td>
              <td>${rldNumber(row.rotation_score)}</td>
              <td>${rldNumber(row.chdl)}</td>
              <td>${rldNumber(row.three_macd)}</td>
              <td>${row.one_line ? "是" : "否"}</td>
              <td>${row.stupid_buy_bi ? "是" : "否"}</td>
              <td>${row.stupid_buy_seg ? "是" : "否"}</td>
              <td>${row.rld_bs_side || "-"} ${rldNumber(row.rld_bs_score)}</td>
              <td>${ensureArray(row.reasons, []).join("；")}</td>
            </tr>`).join("")}
        </tbody>
      </table>
    </div>
  ` : `<div class="muted" style="margin-top:10px;">尚未生成多股矩阵，可点击“刷新矩阵”。</div>`;
  target.innerHTML = matrixTable + multi;
}

function rldRenderBacktest(payload) {
  const target = $("rldBacktestContainer");
  if (!target) return;
  const backtest = payload && payload.backtest;
  if (!backtest || !Array.isArray(backtest.rows) || backtest.rows.length <= 0) {
    target.innerHTML = `<div class="muted">尚未执行回测。</div>`;
    return;
  }
  target.innerHTML = `
    <div class="rldMetaRow">
      <span>标的数：${backtest.summary ? backtest.summary.count : 0}</span>
      <span>平均收益：${backtest.summary ? rldPct(backtest.summary.avg_return) : "-"}</span>
      <span>平均回撤：${backtest.summary ? rldPct(backtest.summary.avg_max_drawdown) : "-"}</span>
      <span>入场规则：${ensureArray(backtest.params && backtest.params.entry_rules, []).join(" + ")}</span>
      <span>出场规则：${ensureArray(backtest.params && backtest.params.exit_rules, []).join(" + ")}</span>
    </div>
    <div class="rldScroll" style="max-height:260px;">
      <table class="rldTable">
        <thead><tr><th>代码</th><th>名称</th><th>交易数</th><th>收益</th><th>最大回撤</th><th>胜率</th><th>Profit Factor</th></tr></thead>
        <tbody>
          ${backtest.rows.map((row) => `<tr><td>${row.code}</td><td>${row.name || "-"}</td><td>${row.trade_count}</td><td>${rldPct(row.return)}</td><td>${rldPct(row.max_drawdown)}</td><td>${rldPct(row.win_rate)}</td><td>${row.profit_factor === null || row.profit_factor === undefined ? "-" : rldNumber(row.profit_factor, 3)}</td></tr>`).join("")}
        </tbody>
      </table>
    </div>
    <div class="rldCardTitle" style="margin-top:12px;">最近交易明细</div>
    <div class="rldScroll" style="max-height:220px;">
      <table class="rldTable">
        <thead><tr><th>代码</th><th>方向</th><th>时间</th><th>价格</th><th>股数</th><th>盈亏</th><th>原因</th></tr></thead>
        <tbody>
          ${ensureArray(backtest.trades, []).slice(-80).reverse().map((row) => `<tr><td>${row.code}</td><td>${row.side}</td><td>${row.time || "-"}</td><td>${rldNumber(row.price, 4)}</td><td>${row.shares || "-"}</td><td>${row.pnl === undefined ? "-" : rldNumber(row.pnl, 2)}</td><td>${ensureArray(row.reason, []).join("；")}</td></tr>`).join("")}
        </tbody>
      </table>
    </div>
  `;
}

function rldRefresh(payload, message) {
  rldPayload = payload;
  rldRenderHeader(payload);
  rldRenderSummary(payload);
  rldRenderLevelMatrix(payload);
  rldRenderBacktest(payload);
  rldRenderStatus(payload, message || payload.message || "");
  const firstLevel = payload && payload.analysis && payload.analysis.levels && payload.analysis.levels[0];
  if (!rldCrosshairTime && firstLevel && firstLevel.chart && firstLevel.chart.kline && firstLevel.chart.kline.length > 0) {
    rldCrosshairTime = firstLevel.chart.kline[firstLevel.chart.kline.length - 1].t;
  }
  rldRenderPerspective();
  rldDrawAllCharts();
}

function rldBindCanvasInteractions() {
  for (let i = 1; i <= 3; i++) {
    const canvasEl = $(`rldChart${i}`);
    if (!canvasEl || canvasEl.dataset.bound === "1") continue;
    canvasEl.dataset.bound = "1";
    canvasEl.addEventListener("mousemove", (e) => {
      if (!rldPayload || !rldPayload.ready) return;
      const levelItem = rldPayload.analysis && rldPayload.analysis.levels ? rldPayload.analysis.levels[i - 1] : null;
      const chart = levelItem && levelItem.chart;
      if (!chart || !chart.kline || chart.kline.length <= 0) return;
      const rect = canvasEl.getBoundingClientRect();
      const x = e.clientX - rect.left;
      const idx = Math.max(0, Math.min(chart.kline.length - 1, Math.round(((x - 56) / Math.max(1, rect.width - 70)) * (chart.kline.length - 1))));
      const k = chart.kline[idx];
      if (!k) return;
      rldCrosshairTime = k.t;
      rldRenderPerspective();
      rldDrawAllCharts();
    });
  }
}

function rldSetTopTab(tab) {
  rldActiveTopTab = tab === "rld" ? "rld" : "trainer";
  storageSet("chan_top_active_tab", rldActiveTopTab);
  $("topTabTrainer").classList.toggle("active", rldActiveTopTab === "trainer");
  $("topTabRld").classList.toggle("active", rldActiveTopTab === "rld");
  $("pageTrainer").classList.toggle("active", rldActiveTopTab === "trainer");
  $("pageRld").classList.toggle("active", rldActiveTopTab === "rld");
  if (rldActiveTopTab === "trainer") {
    requestAnimationFrame(() => {
      resizeCanvas();
      if (lastPayload && lastPayload.ready) draw(lastPayload.chart);
      updateCompactLayout();
    });
  } else {
    requestAnimationFrame(() => {
      rldDrawAllCharts();
      rldRenderPerspective();
    });
  }
}

function rldBindUi() {
  rldPopulateLevelSelect("rldLv1", storageGet(rldStorageKey("lv1")) || "day");
  rldPopulateLevelSelect("rldLv2", storageGet(rldStorageKey("lv2")) || "60m");
  rldPopulateLevelSelect("rldLv3", storageGet(rldStorageKey("lv3")) || "15m");
  if ($("rldAutype")) $("rldAutype").value = storageGet(rldStorageKey("autype")) || "qfq";
  if ($("rldRuleLogic")) $("rldRuleLogic").value = storageGet(rldStorageKey("logic")) || "and";
  if ($("topTabTrainer") && !$("topTabTrainer").dataset.bound) {
    $("topTabTrainer").dataset.bound = "1";
    $("topTabTrainer").onclick = () => rldSetTopTab("trainer");
    $("topTabRld").onclick = () => rldSetTopTab("rld");
  }
  const bindBtn = (id, fn) => {
    const el = $(id);
    if (!el || el.dataset.bound === "1") return;
    el.dataset.bound = "1";
    el.onclick = fn;
  };
  bindBtn("rldBtnInit", async () => {
    try {
      const body = rldCollectForm();
      const payload = await rldCall("/api/rld/init", body, "POST", "正在加载融立得工作台...");
      storageSet(rldStorageKey("lv1"), body.lv_list[0]);
      storageSet(rldStorageKey("lv2"), body.lv_list[1]);
      storageSet(rldStorageKey("lv3"), body.lv_list[2]);
      storageSet(rldStorageKey("autype"), body.autype);
      storageSet(rldStorageKey("logic"), $("rldRuleLogic").value);
      rldSaveForm();
      rldRefresh(payload, payload.message || "加载成功");
    } catch (e) {
      rldSetStatus(`加载失败：${e.message}`, "error");
    }
  });
  bindBtn("rldBtnReconfig", async () => {
    try {
      const form = rldCollectForm();
      const payload = await rldCall("/api/rld/reconfig", {
        chan_config: form.chan_config,
        strategy_config: form.strategy_config,
        watchlist_or_sector: form.watchlist_or_sector,
        lv_list: form.lv_list,
      }, "POST", "正在应用融立得配置...");
      rldSaveForm();
      rldRefresh(payload, payload.message || "配置已更新");
    } catch (e) {
      rldSetStatus(`应用配置失败：${e.message}`, "error");
    }
  });
  bindBtn("rldBtnMatrix", async () => {
    try {
      const payload = await rldCall("/api/rld/matrix", {
        watchlist_or_sector: $("rldWatchlist").value,
      }, "POST", "正在刷新多股矩阵...");
      rldRefresh(payload, payload.message || "矩阵已刷新");
    } catch (e) {
      rldSetStatus(`矩阵刷新失败：${e.message}`, "error");
    }
  });
  bindBtn("rldBtnBacktest", async () => {
    try {
      const payload = await rldCall("/api/rld/backtest", {
        entry_rules: rldGetSelectedRules("rldEntryRule"),
        exit_rules: rldGetSelectedRules("rldExitRule"),
        logic: $("rldRuleLogic").value,
        execution_mode: "next_open",
        fee: Number($("rldFee").value),
        slippage: Number($("rldSlippage").value),
        codes: parseCodeListForBacktest($("rldWatchlist").value),
        watchlist_or_sector: $("rldWatchlist").value,
      }, "POST", "正在运行回归评测...");
      rldSaveForm();
      rldRefresh(payload, payload.message || "回测完成");
    } catch (e) {
      rldSetStatus(`回测失败：${e.message}`, "error");
    }
  });
  bindBtn("rldBtnReset", async () => {
    try {
      const payload = await rldCall("/api/rld/reset", {}, "POST", "正在重置融立得工作台...");
      rldPayload = null;
      rldCrosshairTime = null;
      rldRefresh(payload, payload.message || "已重置");
    } catch (e) {
      rldSetStatus(`重置失败：${e.message}`, "error");
    }
  });
  rldBindCanvasInteractions();
  const savedTab = storageGet("chan_top_active_tab") || "trainer";
  rldSetTopTab(savedTab);
}

function parseCodeListForBacktest(text) {
  const matched = String(text || "").match(/\d{6}/g);
  return matched ? matched.slice(0, 12) : [];
}

async function rldRestoreState() {
  try {
    const payload = await api("/api/rld/state", null, "GET");
    if (payload && payload.ready) {
      rldRefresh(payload, "已恢复融立得工作台会话。");
    } else {
      rldRenderSummary(null);
      rldRenderLevelMatrix(null);
      rldRenderBacktest(null);
      rldRenderPerspective();
    }
  } catch (e) {
    console.warn("恢复融立得工作台失败:", e);
  }
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
  rldEnsureShell();
  rldBindUi();
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
  await rldRestoreState();
  verifyCriticalUiBindings();
})();
</script>
</body>
</html>
"""


APP_STATE = AppState()
APP_STOCK_NAME: Optional[str] = None
RLD_APP_STATE = RldAppState()


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

        APP_STATE.stepper.init(code_norm, req.begin_date, req.end_date, autype, chan_config=req.chan_config)
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
        }
        APP_STATE.trade_events = []
        APP_STATE.bsp_history = []
        APP_STATE._reset_rhythm_history()
        APP_STATE.bsp_judge_logs = []
        APP_STATE._last_level_dirs = {level: None for level in set(JUDGE_TRIGGER_LEVELS.values())}
        # init后先推进一根，确保前端有可视数据并可交互
        APP_STATE.rebuild_bsp_all_snapshot()
        APP_STATE.stepper.step()
        APP_STATE.sync_bsp_history()
        APP_STATE.sync_rhythm_history()
        APP_STATE._rhythm_notice_hits = []
        APP_STATE.after_step_update()
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
        source_label = data_source_label(APP_STATE.stepper.data_src_used)
        if source_label == "AKShare":
            payload["message"] = f"加载成功：{APP_STOCK_NAME or code_norm}，当前数据源 {source_label}。"
        else:
            payload["message"] = f"加载成功：{APP_STOCK_NAME or code_norm}，已自动切换到 {source_label}。"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/reconfig")
def api_reconfig(req: ReconfigReq):
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    try:
        APP_STATE.reconfig(req.chan_config)
        APP_STATE._rhythm_notice_hits = []
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
        payload["message"] = "缠论配置更新成功，已按新逻辑重新计算并清除模拟持仓。"
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
        ok = APP_STATE.stepper.step()
        APP_STATE.sync_bsp_history()
        APP_STATE.sync_rhythm_history()
        mode = (req.judge_mode or "auto").lower().strip()
        if mode != "manual":
            APP_STATE.after_step_update()
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
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
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
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
        price = APP_STATE.stepper.current_price()
        step_idx = APP_STATE.stepper.step_idx
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
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
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
        price = APP_STATE.stepper.current_price()
        step_idx = APP_STATE.stepper.step_idx
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
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
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
        cur = APP_STATE.stepper.step_idx
        target = max(0, cur - n)
        APP_STATE.rebuild_to_step(target)
        APP_STATE._rhythm_notice_hits = []
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
        payload["message"] = f"自动重建回放：已后退 {cur - target} 根（目标 step={target}）"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.get("/api/state")
def api_state():
    return APP_STATE.build_payload(stock_name=APP_STOCK_NAME)


@app.post("/api/rld/init")
def api_rld_init(req: RldInitReq):
    try:
        RLD_APP_STATE.init(req)
        payload = RLD_APP_STATE.build_payload()
        payload["message"] = f"融立得工作台已加载：{payload.get('name') or payload.get('code')}"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.get("/api/rld/state")
def api_rld_state():
    return RLD_APP_STATE.build_payload()


@app.post("/api/rld/reconfig")
def api_rld_reconfig(req: RldReconfigReq):
    try:
        RLD_APP_STATE.reconfig(req)
        payload = RLD_APP_STATE.build_payload()
        payload["message"] = "融立得工作台配置已更新"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/rld/matrix")
def api_rld_matrix(req: RldMatrixReq):
    try:
        result = RLD_APP_STATE.build_matrix(req)
        payload = RLD_APP_STATE.build_payload()
        payload["matrix"] = result
        payload["message"] = f"矩阵评估完成，共 {result['meta'].get('count', 0)} 个标的"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/rld/backtest")
def api_rld_backtest(req: RldBacktestReq):
    try:
        result = RLD_APP_STATE.run_backtest(req)
        payload = RLD_APP_STATE.build_payload()
        payload["backtest"] = result
        payload["message"] = f"回归评测完成，共 {result['summary'].get('count', 0)} 个标的"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/rld/reset")
def api_rld_reset():
    RLD_APP_STATE.reset()
    payload = RLD_APP_STATE.build_payload()
    payload["message"] = "融立得工作台已重置"
    return payload


@app.post("/api/finish")
def api_finish():
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    APP_STATE.finished = True
    payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
    payload["message"] = "训练结束"
    return payload


@app.post("/api/reset")
def api_reset():
    global APP_STOCK_NAME
    APP_STOCK_NAME = None
    APP_STATE.stepper = ChanStepper()
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


