import copy
import json
import math
import re
from datetime import datetime, timedelta
from pathlib import Path
from threading import RLock
from typing import Any, Optional

import pandas as pd
import requests
from pydantic import BaseModel

from Common.CEnum import AUTYPE, DATA_FIELD, KL_TYPE
from Common.CTime import CTime
from Common.func_util import str2float
from DataAPI.CommonStockAPI import CCommonStockApi
from KLine.KLine_Unit import CKLine_Unit
from .a_persist import read_runtime_pref, write_runtime_pref

try:
    from adata import stock as adata_stock
except Exception:
    adata_stock = None


def safe_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except Exception:
        return float(default)


ASHARE_INLINE_SRC = "inline:ashare"
ADATA_INLINE_SRC = "inline:adata"
TENCENT_INLINE_SRC = "inline:tencent"
SINA_INLINE_SRC = "inline:sina"
EASTMONEY_INLINE_SRC = "inline:eastmoney"
YAHOO_INLINE_SRC = "inline:yahoo"

ASHARE_LEVELS = {
    KL_TYPE.K_DAY,
    KL_TYPE.K_WEEK,
    KL_TYPE.K_MON,
    KL_TYPE.K_1M,
    KL_TYPE.K_5M,
    KL_TYPE.K_15M,
    KL_TYPE.K_30M,
    KL_TYPE.K_60M,
}
ADATA_LEVELS = {
    KL_TYPE.K_DAY,
    KL_TYPE.K_WEEK,
    KL_TYPE.K_MON,
    KL_TYPE.K_QUARTER,
    KL_TYPE.K_1M,
    KL_TYPE.K_5M,
    KL_TYPE.K_15M,
    KL_TYPE.K_30M,
    KL_TYPE.K_60M,
}
TENCENT_LEVELS = {
    KL_TYPE.K_DAY,
    KL_TYPE.K_WEEK,
    KL_TYPE.K_MON,
    KL_TYPE.K_1M,
    KL_TYPE.K_5M,
    KL_TYPE.K_15M,
    KL_TYPE.K_30M,
    KL_TYPE.K_60M,
}
SINA_LEVELS = {
    KL_TYPE.K_DAY,
    KL_TYPE.K_WEEK,
    KL_TYPE.K_MON,
    KL_TYPE.K_5M,
    KL_TYPE.K_15M,
    KL_TYPE.K_30M,
    KL_TYPE.K_60M,
}
EASTMONEY_LEVELS = {
    KL_TYPE.K_DAY,
    KL_TYPE.K_WEEK,
    KL_TYPE.K_MON,
    KL_TYPE.K_1M,
    KL_TYPE.K_5M,
    KL_TYPE.K_15M,
    KL_TYPE.K_30M,
    KL_TYPE.K_60M,
}
YAHOO_LEVELS = {KL_TYPE.K_DAY, KL_TYPE.K_WEEK, KL_TYPE.K_MON}

EXTRA_DATA_SOURCE_CHAIN: list[tuple[str, Any]] = [
    ("Ashare", ASHARE_INLINE_SRC),
    ("AData", ADATA_INLINE_SRC),
    ("Tencent", TENCENT_INLINE_SRC),
    ("Sina", SINA_INLINE_SRC),
    ("Eastmoney", EASTMONEY_INLINE_SRC),
    ("Yahoo", YAHOO_INLINE_SRC),
]

EXTRA_SOURCE_LEVELS: dict[Any, set[KL_TYPE]] = {
    ASHARE_INLINE_SRC: ASHARE_LEVELS,
    ADATA_INLINE_SRC: ADATA_LEVELS,
    TENCENT_INLINE_SRC: TENCENT_LEVELS,
    SINA_INLINE_SRC: SINA_LEVELS,
    EASTMONEY_INLINE_SRC: EASTMONEY_LEVELS,
    YAHOO_INLINE_SRC: YAHOO_LEVELS,
}

DEFAULT_SHARED_SETTINGS = {
    "data_quality": "network_direct",
    "cycle_form": "standard",
    "chip_data_quality": "kline_estimate",
    "offline_kline_path": "",
    "offline_tick_path": "",
}
SHARED_SETTINGS_LOCK = RLock()
SHARED_SETTINGS = copy.deepcopy(DEFAULT_SHARED_SETTINGS)

HTTP_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/136.0.0.0 Safari/537.36"
    )
}

TICK_FETCH_CACHE_LOCK = RLock()
TICK_FETCH_CACHE: dict[tuple[str, str, str, str], list[dict[str, Any]]] = {}


class SharedSettingsReq(BaseModel):
    data_quality: Optional[str] = None
    cycle_form: Optional[str] = None
    chip_data_quality: Optional[str] = None
    offline_kline_path: Optional[str] = None
    offline_tick_path: Optional[str] = None


def normalize_shared_settings_payload(raw: Optional[dict[str, Any]]) -> dict[str, Any]:
    data = copy.deepcopy(DEFAULT_SHARED_SETTINGS)
    raw = raw or {}
    data_quality = str(raw.get("data_quality") or data["data_quality"]).strip().lower()
    if data_quality not in {"network_direct", "network_agg", "offline_direct", "offline_agg"}:
        data_quality = DEFAULT_SHARED_SETTINGS["data_quality"]
    cycle_form = str(raw.get("cycle_form") or data["cycle_form"]).strip().lower()
    if cycle_form not in {"standard", "custom_group"}:
        cycle_form = DEFAULT_SHARED_SETTINGS["cycle_form"]
    chip_quality = str(raw.get("chip_data_quality") or data["chip_data_quality"]).strip().lower()
    if chip_quality not in {"kline_estimate", "network_tick", "offline_tick"}:
        chip_quality = DEFAULT_SHARED_SETTINGS["chip_data_quality"]
    data["data_quality"] = data_quality
    data["cycle_form"] = cycle_form
    data["chip_data_quality"] = chip_quality
    data["offline_kline_path"] = str(raw.get("offline_kline_path") or "").strip()
    data["offline_tick_path"] = str(raw.get("offline_tick_path") or "").strip()
    return data


def get_shared_settings() -> dict[str, Any]:
    with SHARED_SETTINGS_LOCK:
        return copy.deepcopy(SHARED_SETTINGS)


def set_shared_settings(raw: Optional[dict[str, Any]]) -> dict[str, Any]:
    normalized = normalize_shared_settings_payload(raw)
    with SHARED_SETTINGS_LOCK:
        SHARED_SETTINGS.update(normalized)
        snapshot = copy.deepcopy(SHARED_SETTINGS)
    write_runtime_pref("shared_settings", snapshot)
    return snapshot


_persisted_shared_settings = normalize_shared_settings_payload(
    read_runtime_pref("shared_settings", DEFAULT_SHARED_SETTINGS)
)
with SHARED_SETTINGS_LOCK:
    SHARED_SETTINGS.update(_persisted_shared_settings)


def _strip_market_prefix(code: str) -> str:
    text = str(code or "").strip().lower()
    if text.startswith(("sh.", "sz.")):
        return text.split(".", 1)[1]
    if text.startswith(("sh", "sz")):
        return text[2:]
    return text


def detect_market(code: str) -> str:
    symbol = _strip_market_prefix(code)
    return "sh" if symbol.startswith(("5", "6", "9")) else "sz"


def to_ts_code(code: str) -> str:
    symbol = _strip_market_prefix(code)
    return f"{symbol}.SH" if detect_market(symbol) == "sh" else f"{symbol}.SZ"


def to_yahoo_symbol(code: str) -> str:
    symbol = _strip_market_prefix(code)
    return f"{symbol}.SS" if detect_market(symbol) == "sh" else f"{symbol}.SZ"


def to_tencent_symbol(code: str) -> str:
    symbol = _strip_market_prefix(code)
    return f"{detect_market(symbol)}{symbol}"


def to_eastmoney_secid(code: str) -> str:
    symbol = _strip_market_prefix(code)
    market_id = "1" if detect_market(symbol) == "sh" else "0"
    return f"{market_id}.{symbol}"


def parse_date_value(value: Any, *, default_time: tuple[int, int] = (0, 0)) -> tuple[CTime, datetime]:
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


def row_to_klu_item(row: dict[str, Any], lv: KL_TYPE) -> CKLine_Unit:
    item = {
        DATA_FIELD.FIELD_TIME: row[DATA_FIELD.FIELD_TIME],
        DATA_FIELD.FIELD_OPEN: float(row[DATA_FIELD.FIELD_OPEN]),
        DATA_FIELD.FIELD_HIGH: float(row[DATA_FIELD.FIELD_HIGH]),
        DATA_FIELD.FIELD_LOW: float(row[DATA_FIELD.FIELD_LOW]),
        DATA_FIELD.FIELD_CLOSE: float(row[DATA_FIELD.FIELD_CLOSE]),
        DATA_FIELD.FIELD_VOLUME: float(row.get(DATA_FIELD.FIELD_VOLUME, 0.0) or 0.0),
        DATA_FIELD.FIELD_TURNOVER: float(row.get(DATA_FIELD.FIELD_TURNOVER, 0.0) or 0.0),
    }
    klu = CKLine_Unit(item)
    klu.kl_type = lv
    if not hasattr(klu, "macd"):
        klu.macd = None
    if not hasattr(klu, "boll"):
        klu.boll = None
    return klu


def klu_items_to_rows(items: list[CKLine_Unit]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for item in items:
        dt = datetime(item.time.year, item.time.month, item.time.day, item.time.hour, item.time.minute)
        rows.append(
            {
                "dt": dt,
                DATA_FIELD.FIELD_TIME: item.time,
                DATA_FIELD.FIELD_OPEN: float(item.open),
                DATA_FIELD.FIELD_HIGH: float(item.high),
                DATA_FIELD.FIELD_LOW: float(item.low),
                DATA_FIELD.FIELD_CLOSE: float(item.close),
                DATA_FIELD.FIELD_VOLUME: float(getattr(item, "volume", getattr(item, "vol", 0.0)) or 0.0),
                DATA_FIELD.FIELD_TURNOVER: float(getattr(item, "turnover", 0.0) or 0.0),
            }
        )
    return rows


def merge_price_rows(rows: list[dict[str, Any]], k_type: KL_TYPE) -> dict[str, Any]:
    last_dt = rows[-1]["dt"]
    if k_type in {KL_TYPE.K_DAY, KL_TYPE.K_WEEK, KL_TYPE.K_MON, KL_TYPE.K_QUARTER, KL_TYPE.K_YEAR}:
        ctime = CTime(last_dt.year, last_dt.month, last_dt.day, 0, 0)
    else:
        ctime = CTime(last_dt.year, last_dt.month, last_dt.day, last_dt.hour, last_dt.minute)
    return {
        "dt": last_dt,
        DATA_FIELD.FIELD_TIME: ctime,
        DATA_FIELD.FIELD_OPEN: rows[0][DATA_FIELD.FIELD_OPEN],
        DATA_FIELD.FIELD_HIGH: max(item[DATA_FIELD.FIELD_HIGH] for item in rows),
        DATA_FIELD.FIELD_LOW: min(item[DATA_FIELD.FIELD_LOW] for item in rows),
        DATA_FIELD.FIELD_CLOSE: rows[-1][DATA_FIELD.FIELD_CLOSE],
        DATA_FIELD.FIELD_VOLUME: sum(float(item.get(DATA_FIELD.FIELD_VOLUME, 0.0) or 0.0) for item in rows),
        DATA_FIELD.FIELD_TURNOVER: sum(float(item.get(DATA_FIELD.FIELD_TURNOVER, 0.0) or 0.0) for item in rows),
    }


def aggregate_price_rows(rows: list[dict[str, Any]], k_type: KL_TYPE) -> list[dict[str, Any]]:
    if not rows:
        return []
    if k_type == KL_TYPE.K_1M:
        return [merge_price_rows([row], k_type) for row in rows]
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
            raise ValueError(f"unsupported aggregate level: {k_type}")
        if current_key != key:
            if current_group:
                grouped.append(current_group)
            current_key = key
            current_group = [row]
        else:
            current_group.append(row)
    if current_group:
        grouped.append(current_group)
    return [merge_price_rows(group, k_type) for group in grouped]


def rows_to_klu_items(rows: list[dict[str, Any]], k_type: KL_TYPE) -> list[CKLine_Unit]:
    items: list[CKLine_Unit] = []
    for idx, row in enumerate(rows):
        klu = row_to_klu_item(row, k_type)
        klu.set_idx(idx)
        items.append(klu)
    return items


def aggregate_klu_items(items: list[CKLine_Unit], k_type: KL_TYPE) -> list[CKLine_Unit]:
    return rows_to_klu_items(aggregate_price_rows(klu_items_to_rows(items), k_type), k_type)


def balanced_group_boundaries(total: int, parts: int) -> list[tuple[int, int]]:
    total = max(0, int(total))
    parts = max(1, int(parts))
    if total <= 0:
        return []
    parts = min(parts, total)
    q, r = divmod(total, parts)
    boundaries: list[tuple[int, int]] = []
    start = 0
    for idx in range(parts):
        size = q + (1 if idx < r else 0)
        end = start + size
        if end > start:
            boundaries.append((start, end))
        start = end
    return boundaries


def aggregate_custom_group_rows(
    full_standard_rows: list[dict[str, Any]],
    current_standard_rows: list[dict[str, Any]],
    parts: int,
    k_type: KL_TYPE,
) -> list[dict[str, Any]]:
    boundaries = balanced_group_boundaries(len(full_standard_rows), parts)
    if not boundaries:
        return []
    current_len = len(current_standard_rows)
    result: list[dict[str, Any]] = []
    for start, end in boundaries:
        if current_len <= start:
            break
        chunk = current_standard_rows[start:min(end, current_len)]
        if not chunk:
            break
        result.append(merge_price_rows(chunk, k_type))
    return result


def request_text(url: str, *, encoding: Optional[str] = None) -> str:
    response = requests.get(url, headers=HTTP_HEADERS, timeout=20)
    response.raise_for_status()
    if encoding:
        return response.content.decode(encoding, errors="ignore")
    return response.text


def request_json(url: str, *, encoding: Optional[str] = None) -> Any:
    text = request_text(url, encoding=encoding)
    return json.loads(text)


def normalize_kl_type_name(k_type: KL_TYPE) -> str:
    mapping = {
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
    return mapping.get(k_type, str(k_type.name).lower())


def build_rows_from_dataframe(df: pd.DataFrame, *, time_col: str, open_col: str, high_col: str, low_col: str, close_col: str, volume_col: Optional[str] = None, amount_col: Optional[str] = None, default_time: tuple[int, int] = (0, 0)) -> list[dict[str, Any]]:
    if df is None or df.empty:
        return []
    rows: list[dict[str, Any]] = []
    for _, row in df.iterrows():
        ctime, dt = parse_date_value(row[time_col], default_time=default_time)
        rows.append(
            {
                "dt": dt,
                DATA_FIELD.FIELD_TIME: ctime,
                DATA_FIELD.FIELD_OPEN: str2float(row[open_col]),
                DATA_FIELD.FIELD_HIGH: str2float(row[high_col]),
                DATA_FIELD.FIELD_LOW: str2float(row[low_col]),
                DATA_FIELD.FIELD_CLOSE: str2float(row[close_col]),
                DATA_FIELD.FIELD_VOLUME: safe_float(row[volume_col], 0.0) if volume_col else 0.0,
                DATA_FIELD.FIELD_TURNOVER: safe_float(row[amount_col], 0.0) if amount_col else 0.0,
            }
        )
    rows.sort(key=lambda item: item["dt"])
    return rows


class CAshareInline(CCommonStockApi):
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.symbol = _strip_market_prefix(code)
        self.market_symbol = to_tencent_symbol(code)
        super(CAshareInline, self).__init__(code, k_type, begin_date, end_date, autype)

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass

    def _fetch_rows(self) -> list[dict[str, Any]]:
        if self.k_type in {KL_TYPE.K_DAY, KL_TYPE.K_WEEK, KL_TYPE.K_MON}:
            try:
                return CSinaInline.fetch_rows_static(self.code, self.k_type, self.begin_date, self.end_date)
            except Exception:
                return CTencentInline.fetch_rows_static(self.code, self.k_type, self.begin_date, self.end_date)
        if self.k_type == KL_TYPE.K_1M:
            return CTencentInline.fetch_rows_static(self.code, self.k_type, self.begin_date, self.end_date)
        try:
            return CSinaInline.fetch_rows_static(self.code, self.k_type, self.begin_date, self.end_date)
        except Exception:
            return CTencentInline.fetch_rows_static(self.code, self.k_type, self.begin_date, self.end_date)

    def get_kl_data(self):
        for item in rows_to_klu_items(self._fetch_rows(), self.k_type):
            yield item


class CAdataInline(CCommonStockApi):
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.symbol = _strip_market_prefix(code)
        super(CAdataInline, self).__init__(code, k_type, begin_date, end_date, autype)

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass

    def _fetch_rows(self) -> list[dict[str, Any]]:
        if adata_stock is None:
            raise RuntimeError("AData 未安装")
        k_type_map = {
            KL_TYPE.K_DAY: 1,
            KL_TYPE.K_WEEK: 2,
            KL_TYPE.K_MON: 3,
            KL_TYPE.K_QUARTER: 4,
            KL_TYPE.K_5M: 5,
            KL_TYPE.K_15M: 15,
            KL_TYPE.K_30M: 30,
            KL_TYPE.K_60M: 60,
        }
        if self.k_type in k_type_map:
            df = adata_stock.market.get_market(
                self.symbol,
                start_date=self.begin_date or "1990-01-01",
                end_date=self.end_date,
                k_type=k_type_map[self.k_type],
                adjust_type=1 if self.autype == AUTYPE.QFQ else 2 if self.autype == AUTYPE.HFQ else 0,
            )
            rows = build_rows_from_dataframe(
                df,
                time_col="trade_time",
                open_col="open",
                high_col="high",
                low_col="low",
                close_col="close",
                volume_col="volume",
                amount_col="amount",
            )
            if rows:
                return rows
        if self.k_type == KL_TYPE.K_1M:
            df = adata_stock.market.get_market_min(self.symbol)
            rows: list[dict[str, Any]] = []
            for _, row in df.iterrows():
                day = self.end_date or datetime.now().strftime("%Y-%m-%d")
                ctime, dt = parse_date_value(f"{day} {str(row['trade_time']).strip()[:5]}")
                rows.append(
                    {
                        "dt": dt,
                        DATA_FIELD.FIELD_TIME: ctime,
                        DATA_FIELD.FIELD_OPEN: str2float(row["price"]),
                        DATA_FIELD.FIELD_HIGH: str2float(row["price"]),
                        DATA_FIELD.FIELD_LOW: str2float(row["price"]),
                        DATA_FIELD.FIELD_CLOSE: str2float(row["price"]),
                        DATA_FIELD.FIELD_VOLUME: str2float(row.get("volume", 0.0)),
                        DATA_FIELD.FIELD_TURNOVER: str2float(row.get("amount", 0.0)),
                    }
                )
            if rows:
                return rows
        raise ValueError(f"AData 暂未返回 {normalize_kl_type_name(self.k_type)} 数据")

    def get_kl_data(self):
        for item in rows_to_klu_items(self._fetch_rows(), self.k_type):
            yield item


class CTencentInline(CCommonStockApi):
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.market_symbol = to_tencent_symbol(code)
        super(CTencentInline, self).__init__(code, k_type, begin_date, end_date, autype)

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass

    @staticmethod
    def fetch_rows_static(code: str, k_type: KL_TYPE, begin_date: Optional[str], end_date: Optional[str]) -> list[dict[str, Any]]:
        symbol = to_tencent_symbol(code)
        if k_type in {KL_TYPE.K_DAY, KL_TYPE.K_WEEK, KL_TYPE.K_MON}:
            unit = "day"
            if k_type == KL_TYPE.K_WEEK:
                unit = "week"
            elif k_type == KL_TYPE.K_MON:
                unit = "month"
            end_token = ""
            if end_date and end_date != datetime.now().strftime("%Y-%m-%d"):
                end_token = end_date
            url = f"https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param={symbol},{unit},,{end_token},800,qfq"
            payload = request_json(url)
            node = payload.get("data", {}).get(symbol, {})
            rows_raw = node.get(f"qfq{unit}") or node.get(unit) or []
            rows: list[dict[str, Any]] = []
            for item in rows_raw:
                ctime, dt = parse_date_value(item[0])
                day_key = dt.strftime("%Y-%m-%d")
                if begin_date and day_key < begin_date:
                    continue
                if end_date and day_key > end_date:
                    continue
                rows.append(
                    {
                        "dt": dt,
                        DATA_FIELD.FIELD_TIME: ctime,
                        DATA_FIELD.FIELD_OPEN: str2float(item[1]),
                        DATA_FIELD.FIELD_CLOSE: str2float(item[2]),
                        DATA_FIELD.FIELD_HIGH: str2float(item[3]),
                        DATA_FIELD.FIELD_LOW: str2float(item[4]),
                        DATA_FIELD.FIELD_VOLUME: str2float(item[5]) * 100.0,
                        DATA_FIELD.FIELD_TURNOVER: 0.0,
                    }
                )
            return rows
        minute = {
            KL_TYPE.K_1M: 1,
            KL_TYPE.K_5M: 5,
            KL_TYPE.K_15M: 15,
            KL_TYPE.K_30M: 30,
            KL_TYPE.K_60M: 60,
        }.get(k_type)
        if minute is None:
            raise ValueError(f"Tencent 暂不支持 {normalize_kl_type_name(k_type)}")
        url = f"https://ifzq.gtimg.cn/appstock/app/kline/mkline?param={symbol},m{minute},,800"
        payload = request_json(url)
        rows_raw = payload.get("data", {}).get(symbol, {}).get(f"m{minute}") or []
        rows: list[dict[str, Any]] = []
        for item in rows_raw:
            ctime, dt = parse_date_value(item[0])
            day_key = dt.strftime("%Y-%m-%d")
            if begin_date and day_key < begin_date:
                continue
            if end_date and day_key > end_date:
                continue
            rows.append(
                {
                    "dt": dt,
                    DATA_FIELD.FIELD_TIME: ctime,
                    DATA_FIELD.FIELD_OPEN: str2float(item[1]),
                    DATA_FIELD.FIELD_CLOSE: str2float(item[2]),
                    DATA_FIELD.FIELD_HIGH: str2float(item[3]),
                    DATA_FIELD.FIELD_LOW: str2float(item[4]),
                    DATA_FIELD.FIELD_VOLUME: str2float(item[5]) * 100.0,
                    DATA_FIELD.FIELD_TURNOVER: 0.0,
                }
            )
        return rows

    def get_kl_data(self):
        for item in rows_to_klu_items(self.fetch_rows_static(self.code, self.k_type, self.begin_date, self.end_date), self.k_type):
            yield item


class CSinaInline(CCommonStockApi):
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.market_symbol = to_tencent_symbol(code)
        super(CSinaInline, self).__init__(code, k_type, begin_date, end_date, autype)

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass

    @staticmethod
    def fetch_rows_static(code: str, k_type: KL_TYPE, begin_date: Optional[str], end_date: Optional[str]) -> list[dict[str, Any]]:
        symbol = to_tencent_symbol(code)
        scale_map = {
            KL_TYPE.K_DAY: 240,
            KL_TYPE.K_WEEK: 1200,
            KL_TYPE.K_MON: 7200,
            KL_TYPE.K_5M: 5,
            KL_TYPE.K_15M: 15,
            KL_TYPE.K_30M: 30,
            KL_TYPE.K_60M: 60,
        }
        scale = scale_map.get(k_type)
        if scale is None:
            raise ValueError(f"Sina 暂不支持 {normalize_kl_type_name(k_type)}")
        url = (
            "https://money.finance.sina.com.cn/quotes_service/api/json_v2.php/"
            f"CN_MarketData.getKLineData?symbol={symbol}&scale={scale}&ma=no&datalen=800"
        )
        payload = request_json(url)
        rows: list[dict[str, Any]] = []
        for item in payload or []:
            time_key = item.get("day")
            ctime, dt = parse_date_value(time_key, default_time=(0, 0))
            day_key = dt.strftime("%Y-%m-%d")
            if begin_date and day_key < begin_date:
                continue
            if end_date and day_key > end_date:
                continue
            rows.append(
                {
                    "dt": dt,
                    DATA_FIELD.FIELD_TIME: ctime,
                    DATA_FIELD.FIELD_OPEN: str2float(item.get("open")),
                    DATA_FIELD.FIELD_HIGH: str2float(item.get("high")),
                    DATA_FIELD.FIELD_LOW: str2float(item.get("low")),
                    DATA_FIELD.FIELD_CLOSE: str2float(item.get("close")),
                    DATA_FIELD.FIELD_VOLUME: str2float(item.get("volume", 0.0)) * 100.0,
                    DATA_FIELD.FIELD_TURNOVER: 0.0,
                }
            )
        return rows

    def get_kl_data(self):
        for item in rows_to_klu_items(self.fetch_rows_static(self.code, self.k_type, self.begin_date, self.end_date), self.k_type):
            yield item


class CEastmoneyInline(CCommonStockApi):
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.secid = to_eastmoney_secid(code)
        super(CEastmoneyInline, self).__init__(code, k_type, begin_date, end_date, autype)

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass

    def _fetch_rows(self) -> list[dict[str, Any]]:
        klt_map = {
            KL_TYPE.K_1M: 1,
            KL_TYPE.K_5M: 5,
            KL_TYPE.K_15M: 15,
            KL_TYPE.K_30M: 30,
            KL_TYPE.K_60M: 60,
            KL_TYPE.K_DAY: 101,
            KL_TYPE.K_WEEK: 102,
            KL_TYPE.K_MON: 103,
        }
        klt = klt_map.get(self.k_type)
        if klt is None:
            raise ValueError(f"Eastmoney 暂不支持 {normalize_kl_type_name(self.k_type)}")
        beg = (self.begin_date or "1990-01-01").replace("-", "")
        end = (self.end_date or "2099-12-31").replace("-", "")
        adjust = 1 if self.autype == AUTYPE.QFQ else 2 if self.autype == AUTYPE.HFQ else 0
        url = (
            "https://push2his.eastmoney.com/api/qt/stock/kline/get"
            f"?secid={self.secid}&fields1=f1,f2,f3&fields2=f51,f52,f53,f54,f55,f56,f57,f58&"
            f"klt={klt}&fqt={adjust}&beg={beg}&end={end}&lmt=800"
        )
        payload = request_json(url)
        lines = payload.get("data", {}).get("klines") or []
        rows: list[dict[str, Any]] = []
        for line in lines:
            parts = str(line).split(",")
            if len(parts) < 7:
                continue
            ctime, dt = parse_date_value(parts[0], default_time=(0, 0))
            rows.append(
                {
                    "dt": dt,
                    DATA_FIELD.FIELD_TIME: ctime,
                    DATA_FIELD.FIELD_OPEN: str2float(parts[1]),
                    DATA_FIELD.FIELD_CLOSE: str2float(parts[2]),
                    DATA_FIELD.FIELD_HIGH: str2float(parts[3]),
                    DATA_FIELD.FIELD_LOW: str2float(parts[4]),
                    DATA_FIELD.FIELD_VOLUME: str2float(parts[5]),
                    DATA_FIELD.FIELD_TURNOVER: str2float(parts[6]),
                }
            )
        return rows

    def get_kl_data(self):
        for item in rows_to_klu_items(self._fetch_rows(), self.k_type):
            yield item


class CYahooInline(CCommonStockApi):
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        self.symbol = to_yahoo_symbol(code)
        super(CYahooInline, self).__init__(code, k_type, begin_date, end_date, autype)

    def SetBasciInfo(self):
        self.name = self.code
        self.is_stock = True

    @classmethod
    def do_init(cls):
        pass

    @classmethod
    def do_close(cls):
        pass

    def _fetch_rows(self) -> list[dict[str, Any]]:
        interval_map = {KL_TYPE.K_DAY: "1d", KL_TYPE.K_WEEK: "1wk", KL_TYPE.K_MON: "1mo"}
        interval = interval_map.get(self.k_type)
        if interval is None:
            raise ValueError(f"Yahoo 暂不支持 {normalize_kl_type_name(self.k_type)}")
        start_dt = datetime.strptime(self.begin_date or "1990-01-01", "%Y-%m-%d")
        end_dt = datetime.strptime(self.end_date or "2099-12-31", "%Y-%m-%d") + timedelta(days=1)
        url = (
            f"https://query1.finance.yahoo.com/v8/finance/chart/{self.symbol}"
            f"?interval={interval}&period1={int(start_dt.timestamp())}&period2={int(end_dt.timestamp())}&includeAdjustedClose=true"
        )
        payload = request_json(url)
        result = (payload.get("chart") or {}).get("result") or []
        if not result:
            return []
        node = result[0]
        quote = (((node.get("indicators") or {}).get("quote") or [{}])[0]) or {}
        ts_list = node.get("timestamp") or []
        rows: list[dict[str, Any]] = []
        for idx, ts in enumerate(ts_list):
            if quote.get("open", [None])[idx] is None:
                continue
            dt = datetime.fromtimestamp(int(ts))
            ctime = CTime(dt.year, dt.month, dt.day, 0, 0)
            rows.append(
                {
                    "dt": dt,
                    DATA_FIELD.FIELD_TIME: ctime,
                    DATA_FIELD.FIELD_OPEN: str2float(quote.get("open", [0])[idx]),
                    DATA_FIELD.FIELD_HIGH: str2float(quote.get("high", [0])[idx]),
                    DATA_FIELD.FIELD_LOW: str2float(quote.get("low", [0])[idx]),
                    DATA_FIELD.FIELD_CLOSE: str2float(quote.get("close", [0])[idx]),
                    DATA_FIELD.FIELD_VOLUME: str2float(quote.get("volume", [0])[idx]),
                    DATA_FIELD.FIELD_TURNOVER: 0.0,
                }
            )
        return rows

    def get_kl_data(self):
        for item in rows_to_klu_items(self._fetch_rows(), self.k_type):
            yield item


def resolve_override_path(raw_value: str) -> Optional[Path]:
    text = str(raw_value or "").strip()
    if not text:
        return None
    path = Path(text)
    return path if path.exists() else None


def resolve_offline_tick_paths(code: str, begin_date: Optional[str], end_date: Optional[str], default_root: Path) -> list[Path]:
    symbol = _strip_market_prefix(code)
    settings = get_shared_settings()
    override = resolve_override_path(settings.get("offline_tick_path", ""))
    candidates: list[Path] = []
    if override:
        if override.is_file():
            candidates = [override]
        elif override.is_dir():
            candidates = sorted(override.glob(f"*{symbol}.txt"))
    if not candidates:
        candidates = sorted(default_root.glob(f"*#{symbol}/TickData/*_{symbol}.txt"))
    begin_token = str(begin_date or "").replace("-", "")
    end_token = str(end_date or "").replace("-", "")
    filtered: list[Path] = []
    for path in candidates:
        match = re.search(r"(\d{8})", path.stem)
        if match:
            day = match.group(1)
            if begin_token and day < begin_token:
                continue
            if end_token and day > end_token:
                continue
        filtered.append(path)
    return filtered


def parse_offline_tick_file(path: Path) -> list[dict[str, Any]]:
    match = re.search(r"(\d{8})", path.stem)
    if not match:
        return []
    trade_day = match.group(1)
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    rows: list[dict[str, Any]] = []
    for raw in lines[4:]:
        text = raw.strip()
        if not text:
            continue
        parts = re.split(r"\s+", text)
        if len(parts) < 3:
            continue
        time_text = str(parts[0]).strip()
        if not re.match(r"^\d{2}:\d{2}", time_text):
            continue
        price = safe_float(parts[1], 0.0)
        volume = safe_float(parts[2], 0.0)
        bs_type = parts[4].strip().upper() if len(parts) >= 5 and parts[4].strip().upper() in {"B", "S"} else ""
        ctime, dt = parse_date_value(f"{trade_day[:4]}-{trade_day[4:6]}-{trade_day[6:8]} {time_text[:5]}")
        rows.append(
            {
                "dt": dt,
                "time": ctime.to_str(),
                "price": price,
                "volume": volume,
                "bs_type": bs_type,
            }
        )
    return rows


def load_offline_tick_trades(code: str, begin_date: Optional[str], end_date: Optional[str], default_root: Path) -> tuple[list[dict[str, Any]], str]:
    paths = resolve_offline_tick_paths(code, begin_date, end_date, default_root)
    rows: list[dict[str, Any]] = []
    for path in paths:
        rows.extend(parse_offline_tick_file(path))
    rows.sort(key=lambda item: item["dt"])
    return rows, "OfflineTick"


def load_network_tick_trades(code: str, begin_date: Optional[str], end_date: Optional[str]) -> tuple[list[dict[str, Any]], str]:
    if adata_stock is None:
        return [], "NetworkTick"
    today = datetime.now().strftime("%Y-%m-%d")
    if begin_date and begin_date > today:
        return [], "NetworkTick"
    if end_date and end_date < today:
        return [], "NetworkTick"
    df = adata_stock.market.get_market_bar(_strip_market_prefix(code))
    if df is None or df.empty:
        return [], "NetworkTick"
    rows: list[dict[str, Any]] = []
    for _, row in df.iterrows():
        ctime, dt = parse_date_value(f"{today} {str(row['trade_time'])[:5]}")
        rows.append(
            {
                "dt": dt,
                "time": ctime.to_str(),
                "price": str2float(row.get("price", 0.0)),
                "volume": str2float(row.get("volume", 0.0)),
                "bs_type": str(row.get("bs_type", "") or "").upper(),
            }
        )
    rows.sort(key=lambda item: item["dt"])
    return rows, "ADataTick"


def fetch_tick_trades_cached(
    mode: str,
    code: str,
    begin_date: Optional[str],
    end_date: Optional[str],
    default_root: Path,
) -> tuple[list[dict[str, Any]], str]:
    key = (mode, _strip_market_prefix(code), str(begin_date or ""), str(end_date or ""))
    with TICK_FETCH_CACHE_LOCK:
        cached = TICK_FETCH_CACHE.get(key)
    if cached is not None:
        return copy.deepcopy(cached), "cache"
    if mode == "offline_tick":
        rows, label = load_offline_tick_trades(code, begin_date, end_date, default_root)
    elif mode == "network_tick":
        rows, label = load_network_tick_trades(code, begin_date, end_date)
    else:
        rows, label = [], "KLineChip"
    with TICK_FETCH_CACHE_LOCK:
        TICK_FETCH_CACHE[key] = copy.deepcopy(rows)
    return copy.deepcopy(rows), label
