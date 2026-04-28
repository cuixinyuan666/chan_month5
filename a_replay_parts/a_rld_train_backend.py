import copy
import math
import re
from dataclasses import dataclass, field
from datetime import datetime
from threading import RLock
from typing import Any, Optional

from pydantic import BaseModel, Field

from .a_data_extra import (
    balanced_group_boundaries,
    fetch_tick_trades_cached,
    get_shared_settings,
    klu_items_to_rows,
    merge_price_rows,
    rows_to_klu_items,
)
from .a_rld_backend import *
from KLine.KLine_Unit import CKLine_Unit


TRAIN_LEVEL_TOKEN_RE = re.compile(r"^(year|quarter|month|mon|week|day|60m|30m|15m|5m|3m|1m)(\d+)?$", re.I)


class RldTrainInitReq(BaseModel):
    code: str
    begin_date: str
    end_date: Optional[str] = None
    autype: str = "qfq"
    lv_list: list[str] = Field(default_factory=list)
    chan_config: Optional[dict[str, Any]] = None
    initial_cash: float = 100000.0


class RldTrainStepReq(BaseModel):
    level: str
    n: int = 1


class RldTrainTradeReq(BaseModel):
    level: str
    side: str


class RldTrainReconfigReq(BaseModel):
    lv_list: Optional[list[str]] = None
    chan_config: Optional[dict[str, Any]] = None
    initial_cash: Optional[float] = None


@dataclass
class TrainLevelSpec:
    token: str
    base_lv: KL_TYPE
    parts: int
    label: str
    rank: int


@dataclass
class TrainGroup:
    raw_start: int
    raw_end: int
    full_row: dict[str, Any]


@dataclass
class TrainSession:
    code: str
    begin_date: str
    end_date: Optional[str]
    autype: AUTYPE
    raw_lv: KL_TYPE
    raw_items: list[CKLine_Unit]
    raw_rows: list[dict[str, Any]]
    source_label: str
    source_logs: list[str]
    stock_name: Optional[str]
    specs: list[TrainLevelSpec]
    group_cache: dict[str, list[TrainGroup]] = field(default_factory=dict)
    tick_cache: Optional[tuple[list[dict[str, Any]], str]] = None


def parse_train_level_spec(raw: Any) -> TrainLevelSpec:
    text = str(raw or "").strip().lower()
    if not text:
        raise ValueError("训练周期不能为空")
    match = TRAIN_LEVEL_TOKEN_RE.match(text)
    if not match:
        raise ValueError(f"不支持的训练周期：{raw}")
    base_token = match.group(1)
    parts = max(1, int(match.group(2) or "1"))
    if base_token == "mon":
        base_token = "month"
    base_lv = parse_kl_type(base_token)
    label = kl_type_to_label(base_lv) if parts <= 1 else f"{kl_type_to_label(base_lv)}{parts}"
    return TrainLevelSpec(
        token=f"{kl_type_to_name(base_lv)}{parts if parts > 1 else ''}",
        base_lv=base_lv,
        parts=parts,
        label=label,
        rank=RLD_LEVEL_RANK.get(base_lv, 999),
    )


def normalize_train_level_specs(raw: Any) -> list[TrainLevelSpec]:
    if raw is None:
        raw = ["day", "60m", "15m"]
    if isinstance(raw, str):
        parts = [part for part in re.split(r"[\s,，;/]+", raw) if part]
    else:
        parts = list(raw)
    specs: list[TrainLevelSpec] = []
    seen: set[str] = set()
    for item in parts:
        try:
            spec = parse_train_level_spec(item)
        except Exception:
            continue
        if spec.token in seen:
            continue
        seen.add(spec.token)
        specs.append(spec)
    if not specs:
        specs = [parse_train_level_spec(item) for item in ["day", "60m", "15m"]]
    specs.sort(key=lambda item: (item.rank, item.parts, item.token))
    return specs


def group_key_for_row(dt, lv: KL_TYPE):
    if lv == KL_TYPE.K_1M:
        return ("1m", dt.year, dt.month, dt.day, dt.hour, dt.minute)
    minute_map = {
        KL_TYPE.K_3M: 3,
        KL_TYPE.K_5M: 5,
        KL_TYPE.K_15M: 15,
        KL_TYPE.K_30M: 30,
        KL_TYPE.K_60M: 60,
    }
    if lv in minute_map:
        base = datetime(dt.year, dt.month, dt.day, 9, 30) if dt.hour < 12 else datetime(dt.year, dt.month, dt.day, 13, 0)
        bucket = max(0, int((dt - base).total_seconds() // 60) // minute_map[lv])
        return ("m", dt.year, dt.month, dt.day, 0 if dt.hour < 12 else 1, bucket)
    if lv == KL_TYPE.K_DAY:
        return ("day", dt.year, dt.month, dt.day)
    if lv == KL_TYPE.K_WEEK:
        iso = dt.isocalendar()
        return ("week", iso.year, iso.week)
    if lv == KL_TYPE.K_MON:
        return ("month", dt.year, dt.month)
    if lv == KL_TYPE.K_QUARTER:
        return ("quarter", dt.year, (dt.month - 1) // 3 + 1)
    if lv == KL_TYPE.K_YEAR:
        return ("year", dt.year)
    raise ValueError(f"不支持的训练聚合周期：{lv}")


def build_standard_groups(raw_rows: list[dict[str, Any]], lv: KL_TYPE) -> list[TrainGroup]:
    if not raw_rows:
        return []
    groups: list[TrainGroup] = []
    current_key = None
    start_idx = 0
    for idx, row in enumerate(raw_rows):
        key = group_key_for_row(row["dt"], lv)
        if current_key is None:
            current_key = key
            start_idx = idx
            continue
        if key != current_key:
            groups.append(
                TrainGroup(
                    raw_start=start_idx,
                    raw_end=idx - 1,
                    full_row=merge_price_rows(raw_rows[start_idx:idx], lv),
                )
            )
            start_idx = idx
            current_key = key
    groups.append(
        TrainGroup(
            raw_start=start_idx,
            raw_end=len(raw_rows) - 1,
            full_row=merge_price_rows(raw_rows[start_idx:], lv),
        )
    )
    return groups


def build_groups_for_spec(raw_rows: list[dict[str, Any]], spec: TrainLevelSpec) -> list[TrainGroup]:
    base_groups = build_standard_groups(raw_rows, spec.base_lv)
    if spec.parts <= 1:
        return base_groups
    boundaries = balanced_group_boundaries(len(base_groups), spec.parts)
    groups: list[TrainGroup] = []
    for start, end in boundaries:
        part_groups = base_groups[start:end]
        if not part_groups:
            continue
        raw_start = part_groups[0].raw_start
        raw_end = part_groups[-1].raw_end
        groups.append(
            TrainGroup(
                raw_start=raw_start,
                raw_end=raw_end,
                full_row=merge_price_rows(raw_rows[raw_start : raw_end + 1], spec.base_lv),
            )
        )
    return groups


def build_visible_rows(raw_rows: list[dict[str, Any]], groups: list[TrainGroup], current_raw_index: int, spec: TrainLevelSpec) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for group in groups:
        if current_raw_index < group.raw_start:
            break
        if current_raw_index >= group.raw_end:
            rows.append(copy.deepcopy(group.full_row))
            continue
        rows.append(merge_price_rows(raw_rows[group.raw_start : current_raw_index + 1], spec.base_lv))
        break
    return rows


def resolve_boundary_index(groups: list[TrainGroup], current_raw_index: int, step_n: int, *, forward: bool) -> int:
    if not groups:
        return current_raw_index
    current = current_raw_index
    n = max(1, int(step_n))
    for _ in range(n):
        group_idx = 0
        for idx, group in enumerate(groups):
            if current <= group.raw_end:
                group_idx = idx
                break
            group_idx = idx
        if forward:
            group = groups[group_idx]
            if current < group.raw_end:
                current = group.raw_end
            elif group_idx + 1 < len(groups):
                current = groups[group_idx + 1].raw_end
        else:
            if group_idx <= 0:
                current = 0
            else:
                current = groups[group_idx - 1].raw_end
    return current


def build_chip_profile_from_bars(rows: list[dict[str, Any]], *, bucket_step: float) -> dict[str, Any]:
    if not rows:
        return {"available": False, "source": "KLineChip", "buckets": []}
    hist: dict[float, float] = {}
    step = max(0.001, float(bucket_step))
    for row in rows:
        price = float(row.get(DATA_FIELD.FIELD_CLOSE, 0.0) or 0.0)
        volume = float(row.get(DATA_FIELD.FIELD_VOLUME, 0.0) or 0.0)
        bucket = round(round(price / step) * step, 4)
        hist[bucket] = hist.get(bucket, 0.0) + max(volume, 1.0)
    buckets = [{"price": price, "volume": round(volume, 4)} for price, volume in sorted(hist.items())]
    return {"available": True, "source": "KLineChip", "buckets": buckets}


def build_chip_profile_from_ticks(rows: list[dict[str, Any]], *, current_dt, bucket_step: float, source_label: str) -> dict[str, Any]:
    step = max(0.001, float(bucket_step))
    hist: dict[float, float] = {}
    for item in rows:
        dt = item.get("dt")
        if dt is None or dt > current_dt:
            break
        price = float(item.get("price", 0.0) or 0.0)
        volume = float(item.get("volume", 0.0) or 0.0)
        bucket = round(round(price / step) * step, 4)
        hist[bucket] = hist.get(bucket, 0.0) + max(volume, 1.0)
    if not hist:
        return {"available": False, "source": source_label, "buckets": []}
    buckets = [{"price": price, "volume": round(volume, 4)} for price, volume in sorted(hist.items())]
    return {"available": True, "source": source_label, "buckets": buckets}


def build_single_level_payload(
    session: TrainSession,
    spec: TrainLevelSpec,
    visible_rows: list[dict[str, Any]],
    effective_cfg_dict: dict[str, Any],
    current_raw_index: int,
) -> dict[str, Any]:
    if not visible_rows:
        return {
            "token": spec.token,
            "label": spec.label,
            "level": kl_type_to_name(spec.base_lv),
            "chart": {"kline": [], "fract": [], "bi": [], "seg": [], "segseg": [], "fract_zs": [], "bi_zs": [], "seg_zs": [], "segseg_zs": [], "bsp": [], "trend_lines": [], "indicators": []},
            "summary": {"trend_sign": 0, "trend_label": "震荡", "zs_state": {"label": "无数据", "kind": "无", "low": None, "high": None, "bias": 0}, "latest_bsp": None, "macd_bi_area": None, "macd_seg_area": None, "macd_bias": 0.0, "chdl_score": 0.0, "divergence_bias": 0, "reasons": ["当前周期无可见数据"]},
            "chip": {"available": False, "source": "None", "buckets": []},
        }
    items = rows_to_klu_items(visible_rows, spec.base_lv)
    cfg = CChanConfig(strip_chan_algo(effective_cfg_dict))
    chan = ReplayChan(
        code=session.code,
        begin_time=session.begin_date,
        end_time=session.end_date,
        data_src=DATA_SRC.BAO_STOCK,
        lv_list=[spec.base_lv],
        config=cfg,
        autype=session.autype,
        replay_klus_master=items,
    )
    for _ in chan.load(step=False):
        pass
    chart, summary = build_level_chart_payload(
        chan[0],
        effective_cfg_dict.get("chan_algo", CHAN_ALGO_CLASSIC),
        effective_cfg_dict.get("macd") if isinstance(effective_cfg_dict.get("macd"), dict) else {},
    )
    shared = get_shared_settings()
    bucket_step = 0.05
    chip_mode = str(shared.get("chip_data_quality") or "kline_estimate").strip().lower()
    chip_payload: dict[str, Any]
    current_dt = session.raw_rows[current_raw_index]["dt"]
    if chip_mode == "network_tick":
        tick_rows, source_label = session.tick_cache or ([], "ADataTick")
        chip_payload = build_chip_profile_from_ticks(tick_rows, current_dt=current_dt, bucket_step=bucket_step, source_label=source_label)
    elif chip_mode == "offline_tick":
        tick_rows, source_label = session.tick_cache or ([], "OfflineTick")
        chip_payload = build_chip_profile_from_ticks(tick_rows, current_dt=current_dt, bucket_step=bucket_step, source_label=source_label)
    else:
        chip_payload = build_chip_profile_from_bars(visible_rows, bucket_step=bucket_step)
    last_bar = chart["kline"][-1] if chart["kline"] else None
    return {
        "token": spec.token,
        "label": spec.label,
        "level": kl_type_to_name(spec.base_lv),
        "parts": spec.parts,
        "chart": chart,
        "summary": summary,
        "chip": chip_payload,
        "last_time": last_bar["t"] if last_bar else None,
        "last_price": last_bar["c"] if last_bar else None,
    }


def build_train_session(
    code: str,
    begin_date: str,
    end_date: Optional[str],
    autype: AUTYPE,
    specs: list[TrainLevelSpec],
) -> TrainSession:
    raw_lv = sorted(specs, key=lambda item: item.rank, reverse=True)[0].base_lv
    selection = select_runtime_data_source_for_level(
        code=code,
        begin_date=begin_date,
        end_date=end_date,
        autype=autype,
        lv=raw_lv,
    )
    raw_rows = klu_items_to_rows(selection.items)
    group_cache = {spec.token: build_groups_for_spec(raw_rows, spec) for spec in specs}
    shared = get_shared_settings()
    chip_mode = str(shared.get("chip_data_quality") or "kline_estimate").strip().lower()
    tick_cache = None
    if chip_mode in {"network_tick", "offline_tick"}:
        tick_cache = fetch_tick_trades_cached(chip_mode, code, begin_date, end_date, OFFLINE_DATA_ROOT)
        if chip_mode == "offline_tick" and not tick_cache[0]:
            raise FileNotFoundError("离线分笔读取失败，请在设置 > 共享中检查离线分笔路径或分笔文件日期范围")
    return TrainSession(
        code=code,
        begin_date=begin_date,
        end_date=end_date,
        autype=autype,
        raw_lv=raw_lv,
        raw_items=selection.items,
        raw_rows=raw_rows,
        source_label=selection.label,
        source_logs=list(selection.logs),
        stock_name=selection.stock_name,
        specs=specs,
        group_cache=group_cache,
        tick_cache=tick_cache,
    )


class RldTrainAppState:
    def __init__(self) -> None:
        self._lock = RLock()
        self.reset()

    def reset(self) -> None:
        self.ready = False
        self.session: Optional[TrainSession] = None
        self.account = PaperAccount(initial_cash=100000.0, cash=100000.0)
        self.trade_events: list[dict[str, Any]] = []
        self.current_raw_index = 0
        self.effective_cfg_dict: dict[str, Any] = {}
        self.session_params: Optional[dict[str, Any]] = None
        self._payload_cache_key: Optional[tuple[Any, ...]] = None
        self._payload_cache_value: Optional[dict[str, Any]] = None

    def _invalidate_cache(self) -> None:
        self._payload_cache_key = None
        self._payload_cache_value = None

    def init(self, req: RldTrainInitReq) -> None:
        autype_map = {"qfq": AUTYPE.QFQ, "hfq": AUTYPE.HFQ, "none": AUTYPE.NONE}
        autype = autype_map.get(str(req.autype).lower(), AUTYPE.QFQ)
        specs = normalize_train_level_specs(req.lv_list)
        code = normalize_code(req.code)
        session = build_train_session(code, req.begin_date, req.end_date, autype, specs)
        self.session = session
        self.effective_cfg_dict = build_chan_config_dict(req.chan_config, trigger_step=False)
        self.account.reset(float(req.initial_cash or 100000.0))
        self.trade_events = []
        self.current_raw_index = 0 if not session.raw_rows else min(len(session.raw_rows) - 1, 0)
        self.session_params = {
            "code": code,
            "begin_date": req.begin_date,
            "end_date": req.end_date,
            "autype": autype,
            "lv_list": [spec.token for spec in specs],
            "chan_config": req.chan_config or {},
            "initial_cash": float(req.initial_cash or 100000.0),
        }
        self.ready = True
        self._invalidate_cache()

    def _require_ready(self) -> None:
        if not self.ready or self.session is None:
            raise ValueError("请先加载融立得缠论训练")

    def _find_spec(self, token: str) -> TrainLevelSpec:
        self._require_ready()
        assert self.session is not None
        needle = parse_train_level_spec(token).token
        for spec in self.session.specs:
            if spec.token == needle:
                return spec
        raise ValueError(f"未找到训练周期：{token}")

    def step(self, req: RldTrainStepReq, *, forward: bool) -> None:
        self._require_ready()
        assert self.session is not None
        spec = self._find_spec(req.level)
        groups = self.session.group_cache.get(spec.token, [])
        self.current_raw_index = resolve_boundary_index(groups, self.current_raw_index, req.n, forward=forward)
        self._invalidate_cache()

    def trade(self, req: RldTrainTradeReq) -> dict[str, Any]:
        self._require_ready()
        assert self.session is not None
        spec = self._find_spec(req.level)
        groups = self.session.group_cache.get(spec.token, [])
        visible_rows = build_visible_rows(self.session.raw_rows, groups, self.current_raw_index, spec)
        if not visible_rows:
            raise ValueError("当前周期无可交易K线")
        price = float(visible_rows[-1][DATA_FIELD.FIELD_CLOSE])
        side = str(req.side or "").strip().lower()
        if side == "buy":
            detail = self.account.buy_with_all_cash(price, self.current_raw_index)
            self.trade_events.append(
                {
                    "side": "buy",
                    "level": spec.token,
                    "label": spec.label,
                    "raw_index": self.current_raw_index,
                    "time": visible_rows[-1][DATA_FIELD.FIELD_TIME].to_str(),
                    "price": price,
                    "shares": int(detail.get("shares", 0)),
                }
            )
        elif side == "sell":
            detail = self.account.sell_all(price, self.current_raw_index)
            if detail.get("noop"):
                return detail
            self.trade_events.append(
                {
                    "side": "sell",
                    "level": spec.token,
                    "label": spec.label,
                    "raw_index": self.current_raw_index,
                    "time": visible_rows[-1][DATA_FIELD.FIELD_TIME].to_str(),
                    "price": price,
                    "shares": int(detail.get("shares", 0)),
                    "pnl": float(detail.get("pnl", 0.0)),
                }
            )
        else:
            raise ValueError(f"不支持的交易方向：{req.side}")
        self._invalidate_cache()
        return detail

    def reconfig(self, req: RldTrainReconfigReq) -> None:
        self._require_ready()
        assert self.session_params is not None
        lv_list = req.lv_list if req.lv_list is not None else self.session_params.get("lv_list")
        chan_config = req.chan_config if req.chan_config is not None else self.session_params.get("chan_config")
        initial_cash = float(req.initial_cash if req.initial_cash is not None else self.session_params.get("initial_cash", 100000.0))
        init_req = RldTrainInitReq(
            code=self.session_params["code"],
            begin_date=self.session_params["begin_date"],
            end_date=self.session_params["end_date"],
            autype=self.session_params["autype"].name.lower() if isinstance(self.session_params["autype"], AUTYPE) else str(self.session_params["autype"]),
            lv_list=list(lv_list or []),
            chan_config=chan_config,
            initial_cash=initial_cash,
        )
        self.init(init_req)

    def _build_trade_state(self) -> dict[str, Any]:
        history: list[dict[str, Any]] = []
        active: Optional[dict[str, Any]] = None
        for event in self.trade_events:
            if event.get("side") == "buy":
                active = {
                    "buyLevel": event.get("level"),
                    "buyLabel": event.get("label"),
                    "buyTime": event.get("time"),
                    "buyPrice": event.get("price"),
                    "buyX": event.get("raw_index"),
                    "shares": event.get("shares"),
                    "sellPrice": None,
                    "sellTime": None,
                    "sellX": None,
                }
            elif event.get("side") == "sell" and active is not None:
                history.append(
                    {
                        **active,
                        "sellLevel": event.get("level"),
                        "sellLabel": event.get("label"),
                        "sellTime": event.get("time"),
                        "sellPrice": event.get("price"),
                        "sellX": event.get("raw_index"),
                        "pnl": event.get("pnl"),
                    }
                )
                active = None
        return {"history": history, "active": active}

    def build_payload(self) -> dict[str, Any]:
        self._require_ready()
        assert self.session is not None
        cache_key = (
            self.current_raw_index,
            self.account.cash,
            self.account.position,
            self.account.avg_cost,
            tuple((item.get("side"), item.get("raw_index"), item.get("price"), item.get("level")) for item in self.trade_events),
        )
        if self._payload_cache_key == cache_key and self._payload_cache_value is not None:
            return copy.deepcopy(self._payload_cache_value)
        levels: list[dict[str, Any]] = []
        for spec in self.session.specs:
            visible_rows = build_visible_rows(self.session.raw_rows, self.session.group_cache.get(spec.token, []), self.current_raw_index, spec)
            levels.append(build_single_level_payload(self.session, spec, visible_rows, self.effective_cfg_dict, self.current_raw_index))
        current_row = self.session.raw_rows[self.current_raw_index]
        current_price = float(current_row[DATA_FIELD.FIELD_CLOSE])
        timeline = [
            {
                "token": item["token"],
                "label": item["label"],
                "time": item.get("last_time"),
                "price": item.get("last_price"),
                "trend": item["summary"].get("trend_label"),
                "bsp": item["summary"].get("latest_bsp", {}).get("display_label") if item["summary"].get("latest_bsp") else "无",
                "chdl": item["summary"].get("chdl_score"),
                "macd": item["summary"].get("macd_bias"),
            }
            for item in levels
        ]
        payload = {
            "ready": True,
            "mode": "rld_train",
            "code": self.session.code,
            "name": self.session.stock_name,
            "begin_date": self.session.begin_date,
            "end_date": self.session.end_date,
            "time": current_row[DATA_FIELD.FIELD_TIME].to_str(),
            "raw_level": kl_type_to_name(self.session.raw_lv),
            "raw_level_label": kl_type_to_label(self.session.raw_lv),
            "raw_index": self.current_raw_index,
            "raw_total": len(self.session.raw_rows),
            "data_source": {
                "label": self.session.source_label,
                "logs": list(self.session.source_logs),
            },
            "shared_settings": get_shared_settings(),
            "levels": levels,
            "timeline": timeline,
            "account": {
                "initial_cash": round(self.account.initial_cash, 2),
                "cash": round(self.account.cash, 2),
                "position": self.account.position,
                "avg_cost": round(self.account.avg_cost, 4),
                "equity": round(self.account.equity(current_price), 2),
                "can_sell": bool(self.account.can_sell(self.current_raw_index)),
            },
            "trades": self._build_trade_state(),
        }
        self._payload_cache_key = cache_key
        self._payload_cache_value = copy.deepcopy(payload)
        return payload
