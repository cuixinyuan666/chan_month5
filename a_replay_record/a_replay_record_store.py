# -*- coding: utf-8 -*-
"""ReplayChan record cache hooks.

本工程当前禁用持久化 record：加载会话每次从 a_Data 重新计算，避免产生 pkl。
"""

from __future__ import annotations

import copy
import hashlib
import json
import os
import pickle
import re
import sys
import threading
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Callable, Optional

from a_replay_cache.a_step_rollback import capture_stepper_snapshot, restore_stepper_snapshot

RECORD_VERSION = 1
RECORD_DIR_NAME = "a_replay_record"
# ?? Chan.chan_dump_pickle ???????????? pre/next ??????????????????????
_PICKLE_RECURSION_LIMIT = 0x100000
# ???????? CHAN_RECORD=0 ???????
_ENV_DISABLE = True

_record_trace_lock = threading.Lock()
_record_trace_pending: list[str] = []


def push_record_trace(msg: str) -> None:
    """??????????????? record ?????????????????"""
    text = str(msg or "").strip()
    if not text:
        return
    with _record_trace_lock:
        _record_trace_pending.append(text)


def drain_record_trace() -> list[str]:
    with _record_trace_lock:
        out = list(_record_trace_pending)
        _record_trace_pending.clear()
        return out


def peek_record_trace() -> list[str]:
    """读取尚未 drain 的跟踪日志副本（供加载会话轮询）。"""
    with _record_trace_lock:
        return list(_record_trace_pending)


@dataclass
class ChanRecordApplyResult:
    applied: bool = False
    mode: str = "miss"  # exact | extend | overlap_replay | miss
    message: str = ""
    record_path: str = ""
    overlap_bars: int = 0
    skipped_step_bars: int = 0


@dataclass
class _ChanRecordPayload:
    version: int
    meta: dict[str, Any]
    replay_klus_master: list
    replay_klus_master_raw: Optional[list]
    kline_all: list
    snapshot: Any
    effective_cfg_dict: dict[str, Any]
    data_feed_mode: str
    data_form_mode: str
    chan_algo: str
    rhythm_calc_mode: str
    unified_full_payload: Optional[dict[str, Any]]
    data_src_used: Any
    data_src_chip_used: Any


@dataclass
class _MasterAlign:
    start_rec: int = 0
    start_new: int = 0
    match_len: int = 0


def record_root() -> str:
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, RECORD_DIR_NAME)


def is_chan_record_enabled(flag: Optional[bool] = None) -> bool:
    # 硬禁用：不读、不写 a_replay_record/*.pkl。
    return False


def _stable_json(obj: Any) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, default=str)


def build_chan_config_fingerprint(
    *,
    code: str,
    k_type_key: str,
    autype_key: str,
    chan_cfg_dict: dict[str, Any],
    data_form_mode: str,
    data_form_quantity: int,
    data_form_quantity_alloc: str,
    offline_data_custom: str,
    data_feed_mode: str,
    data_source_priority: Optional[list[str]],
    confirm_offline: bool,
) -> str:
    """????????????????????????????????? record??"""
    body = {
        "code": str(code or "").strip(),
        "k_type": str(k_type_key or "").strip().lower(),
        "autype": str(autype_key or "").strip().lower(),
        "chan_cfg": chan_cfg_dict,
        "data_form_mode": str(data_form_mode or "traditional"),
        "data_form_quantity": int(data_form_quantity or 0),
        "data_form_quantity_alloc": str(data_form_quantity_alloc or "front"),
        "offline_data_custom": str(offline_data_custom or "native"),
        "data_feed_mode": str(data_feed_mode or "step"),
        "data_source_priority": list(data_source_priority or []),
        "confirm_offline": bool(confirm_offline),
        "record_version": RECORD_VERSION,
    }
    digest = hashlib.sha256(_stable_json(body).encode("utf-8")).hexdigest()[:20]
    return digest


def _safe_slug(text: str, max_len: int = 48) -> str:
    s = re.sub(r"[^\w.\-]+", "_", str(text or "").strip())
    return (s[:max_len] if s else "na")


def _record_paths(fingerprint: str, code: str, k_type_key: str, autype_key: str, begin: str, end: Optional[str]) -> tuple[str, str]:
    folder = os.path.join(record_root(), fingerprint)
    end_s = _safe_slug(end or "latest", 24)
    base = f"{_safe_slug(code, 16)}_{_safe_slug(k_type_key, 12)}_{_safe_slug(autype_key, 8)}_{_safe_slug(begin, 16)}_{end_s}"
    return folder, os.path.join(folder, base)


def _klu_bar_key(klu: Any) -> tuple:
    try:
        t = klu.time.to_str()
    except Exception:
        t = str(getattr(klu, "time", ""))
    try:
        o, h, l, c = float(klu.open), float(klu.high), float(klu.low), float(klu.close)
        v = float(getattr(klu, "trade_metric", {}).get("volume", 0) if hasattr(klu, "trade_metric") else 0)
    except Exception:
        o = h = l = c = v = 0.0
    return (t, round(o, 6), round(h, 6), round(l, 6), round(c, 6), round(v, 4))


def _align_masters(new_master: list, rec_master: list) -> _MasterAlign:
    if not new_master or not rec_master:
        return _MasterAlign()
    n = len(new_master)
    r = len(rec_master)
    best = _MasterAlign()
    # ?? record ?????? new ????????????????? new ??????? record??
    new0 = _klu_bar_key(new_master[0])
    candidates = [i for i in range(r) if _klu_bar_key(rec_master[i]) == new0]
    if not candidates:
        return _MasterAlign()
    for start_rec in candidates:
        m = 0
        while (
            m < n
            and start_rec + m < r
            and _klu_bar_key(new_master[m]) == _klu_bar_key(rec_master[start_rec + m])
        ):
            m += 1
        if m > best.match_len:
            best = _MasterAlign(start_rec=start_rec, start_new=0, match_len=m)
    return best


def _load_meta(meta_path: str) -> Optional[dict[str, Any]]:
    if not os.path.isfile(meta_path):
        return None
    try:
        with open(meta_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _write_meta(meta_path: str, meta: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(meta_path), exist_ok=True)
    tmp = meta_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    os.replace(tmp, meta_path)


def _pick_best_record(
    fingerprint: str,
    code: str,
    k_type_key: str,
    autype_key: str,
    new_master: list,
) -> Optional[tuple[str, dict[str, Any], _MasterAlign]]:
    folder = os.path.join(record_root(), fingerprint)
    if not os.path.isdir(folder):
        return None
    prefix = f"{_safe_slug(code, 16)}_{_safe_slug(k_type_key, 12)}_{_safe_slug(autype_key, 8)}_"
    best: Optional[tuple[str, dict[str, Any], _MasterAlign]] = None
    for name in os.listdir(folder):
        if not name.endswith(".meta.json"):
            continue
        if not name.startswith(prefix):
            continue
        meta_path = os.path.join(folder, name)
        meta = _load_meta(meta_path)
        if not meta or int(meta.get("bar_count", 0) or 0) <= 0:
            continue
        pkl_path = meta_path[:-10] + ".pkl"  # strip .meta.json
        if not os.path.isfile(pkl_path):
            continue
        rec_bar_count = int(meta.get("bar_count", 0))
        # ???????????? meta ??????????? bar ????????????????? pkl ????
        align_hint = _MasterAlign(start_rec=0, start_new=0, match_len=min(len(new_master), rec_bar_count))
        if new_master and meta.get("first_bar_time") and meta.get("last_bar_time"):
            try:
                new_first = _klu_bar_key(new_master[0])[0]
                new_last = _klu_bar_key(new_master[-1])[0]
                rec_first = str(meta.get("first_bar_time", ""))
                rec_last = str(meta.get("last_bar_time", ""))
                if new_first > rec_last or new_last < rec_first:
                    continue
            except Exception:
                pass
        score = align_hint.match_len
        if best is None or score > best[2].match_len:
            best = (pkl_path, meta, align_hint)
    return best


def _safe_range_text(v: Any) -> str:
    return str(v or "").strip()


def _record_fully_covers_request(meta: dict[str, Any], begin_date: str, end_date: Optional[str]) -> bool:
    """请求区间被旧 record 完整覆盖时返回 True。"""
    req_begin = _safe_range_text(begin_date)
    req_end = _safe_range_text(end_date)
    rec_begin = _safe_range_text(meta.get("begin_date"))
    rec_end = _safe_range_text(meta.get("end_date"))
    if not req_begin or not req_end or not rec_begin or not rec_end:
        return False
    return rec_begin <= req_begin and req_end <= rec_end


def _find_covering_record_meta(
    fingerprint: str,
    code: str,
    k_type_key: str,
    autype_key: str,
    begin_date: str,
    end_date: Optional[str],
) -> Optional[str]:
    """
    查询是否已有同指纹 record 完整覆盖当前请求区间。
    命中则返回对应 pkl 路径（仅用于跳过重复保存）。
    """
    folder = os.path.join(record_root(), fingerprint)
    if not os.path.isdir(folder):
        return None
    prefix = f"{_safe_slug(code, 16)}_{_safe_slug(k_type_key, 12)}_{_safe_slug(autype_key, 8)}_"
    for name in os.listdir(folder):
        if not name.endswith(".meta.json") or not name.startswith(prefix):
            continue
        meta_path = os.path.join(folder, name)
        meta = _load_meta(meta_path)
        if not meta:
            continue
        # 关键元信息不一致则不复用，维持旧逻辑继续新建。
        if str(meta.get("fingerprint", "")) != str(fingerprint):
            continue
        if str(meta.get("code", "")) != str(code):
            continue
        if str(meta.get("k_type", "")) != str(k_type_key):
            continue
        if str(meta.get("autype", "")) != str(autype_key):
            continue
        if not _record_fully_covers_request(meta, begin_date, end_date):
            continue
        pkl_path = meta_path[:-10] + ".pkl"
        if os.path.isfile(pkl_path):
            return pkl_path
    return None


def _chan_break_pickle_links(chan: Any) -> None:
    """??? K ??/??/????????????? deepcopy/pickle ?? pre/next ?????"""
    for kl_list in chan.kl_datas.values():
        for klc in kl_list.lst:
            for klu in klc.lst:
                klu.pre = None
                klu.next = None
            klc.set_pre(None)
            klc.set_next(None)
        for bi in kl_list.bi_list:
            bi.pre = None
            bi.next = None
        for seg in kl_list.seg_list:
            seg.pre = None
            seg.next = None
        for segseg in kl_list.segseg_list:
            segseg.pre = None
            segseg.next = None


def _with_pickle_recursion(fn: Callable[[], Any]) -> Any:
    pre = sys.getrecursionlimit()
    sys.setrecursionlimit(_PICKLE_RECURSION_LIMIT)
    try:
        return fn()
    finally:
        sys.setrecursionlimit(pre)


def _load_payload(pkl_path: str) -> Optional[_ChanRecordPayload]:
    try:
        def _read() -> Any:
            with open(pkl_path, "rb") as f:
                return pickle.load(f)

        raw = _with_pickle_recursion(_read)
        if isinstance(raw, _ChanRecordPayload):
            return raw
        if isinstance(raw, dict):
            return _ChanRecordPayload(**raw)
    except Exception as exc:
        print(f"[ChanRecord] load failed {pkl_path}: {exc}")
    return None


def _pick_wider_kline_all(a: list, b: list) -> list:
    """取时间跨度更宽的 kline_all（供 record 恢复时不缩窄筹码底座）。"""
    if not a:
        return list(b or [])
    if not b:
        return list(a or [])

    def _key(arr: list) -> tuple:
        if not arr:
            return ("", "", 0)
        return (str(arr[0].get("t", "") or ""), str(arr[-1].get("t", "") or ""), len(arr))

    ka, kb = _key(a), _key(b)
    if kb[2] > ka[2]:
        return list(b)
    if kb[2] == ka[2] and kb[0] and ka[0] and kb[0] < ka[0]:
        return list(b)
    return list(a)


def _restore_snapshot(stepper: Any, payload: _ChanRecordPayload, *, target_step_idx: Optional[int] = None) -> None:
    restore_stepper_snapshot(stepper, payload.snapshot)
    # ????????????????????? pre/next
    if stepper.chan is not None and hasattr(stepper.chan, "chan_pickle_restore"):
        stepper.chan.chan_pickle_restore()
    stepper.effective_cfg_dict = dict(payload.effective_cfg_dict or {})
    stepper.chan_algo = payload.chan_algo
    stepper.rhythm_calc_mode = payload.rhythm_calc_mode
    stepper.data_feed_mode = payload.data_feed_mode
    stepper.data_form_mode = payload.data_form_mode
    stepper.data_src_used = payload.data_src_used
    stepper.data_src_chip_used = payload.data_src_chip_used
    incoming = list(payload.kline_all or [])
    existing = list(getattr(stepper, "kline_all", None) or [])
    stepper.kline_all = _pick_wider_kline_all(existing, incoming)
    stepper._unified_full_payload = copy.deepcopy(payload.unified_full_payload) if payload.unified_full_payload else None
    if payload.replay_klus_master_raw is not None:
        stepper._replay_klus_master_raw = copy.deepcopy(payload.replay_klus_master_raw)
    if str(getattr(stepper, "data_feed_mode", "step")) == "unified" and not stepper._unified_full_payload:
        _ensure = getattr(stepper, "ensure_unified_full_payload", None)
        if callable(_ensure):
            _ensure()
    if target_step_idx is not None and stepper.data_feed_mode == "unified" and stepper._unified_full_payload:
        stepper.unified_set_step_idx(int(target_step_idx))
    elif target_step_idx is not None and int(target_step_idx) >= 0:
        stepper.step_idx = int(target_step_idx)


def _feed_remaining_steps(stepper: Any, master: list, from_index: int) -> int:
    """?? master[from_index:] ???? step_load?????????????????"""
    if from_index <= 0:
        return 0
    fed = 0
    target = len(master)
    while stepper.step_idx + 1 < target:
        if not stepper.step():
            break
        fed += 1
    return fed


def _replay_prefix_steps(
    stepper: Any,
    master: list,
    prefix_len: int,
    *,
    create_replay_chan_fn: Callable[..., Any],
    cfg: Any,
    code: str,
    begin_date: str,
    end_date: Optional[str],
    autype: Any,
    k_type: Any,
    data_src: Any,
) -> int:
    """?????????????????? chan ???????????"""
    stepper.chan = create_replay_chan_fn(
        code=code,
        begin_time=begin_date,
        end_time=end_date,
        data_src=data_src,
        lv_list=[k_type],
        config=cfg,
        autype=autype,
        replay_klus_master=master,
    )
    # ????? init ?????????????? ChanStepper.init ???????
    from Math.BOLL import BollModel
    from Math.Demark import CDemarkEngine
    from Math.KDJ import KDJ
    from Math.MACD import CMACD
    from Math.RSI import RSI

    stepper.indicators = {
        "macd": CMACD(),
        "kdj": KDJ(),
        "rsi": RSI(),
        "boll": BollModel(),
        "demark": CDemarkEngine(),
    }
    stepper.indicator_history = []
    stepper.trend_lines = []
    stepper.structure_bundle = None
    stepper._bundle_cache_step_idx = None
    stepper._serialized_klu_cache = []
    stepper._chart_payload_cache = {}
    stepper._unified_full_payload = None
    if stepper.data_feed_mode == "unified":
        for _ in stepper.chan.load(step=False):
            pass
        stepper.step_idx = max(-1, prefix_len - 1)
        stepper._rebuild_indicator_history_from_chan()
        stepper.get_structure_bundle(force=True)
        _ensure = getattr(stepper, "ensure_unified_full_payload", None)
        if callable(_ensure):
            _ensure()
        return prefix_len
    stepper._iter = stepper.chan.step_load()
    stepper.step_idx = -1
    fed = 0
    while stepper.step_idx + 1 < prefix_len:
        if not stepper.step():
            break
        fed += 1
    return fed


def try_apply_chan_record(
    stepper: Any,
    *,
    enabled: bool,
    fingerprint: str,
    code: str,
    k_type_key: str,
    autype_key: str,
    begin_date: str,
    end_date: Optional[str],
    new_master: list,
    create_replay_chan_fn: Callable[..., Any],
    cfg: Any,
    autype: Any,
    k_type: Any,
    data_src: Any,
    allow_end_snapshot_restore: bool = False,
) -> ChanRecordApplyResult:
    """?? ReplayChan ?????/??????? record?????????? stepper ????"""
    out = ChanRecordApplyResult()
    if not is_chan_record_enabled(enabled) or not new_master:
        return out

    picked = _pick_best_record(fingerprint, code, k_type_key, autype_key, new_master)
    if not picked:
        return out

    pkl_path, meta, _ = picked
    payload = _load_payload(pkl_path)
    if payload is None:
        return out

    rec_master = payload.replay_klus_master or []
    align = _align_masters(new_master, rec_master)
    if align.match_len <= 0:
        return out

    n_new = len(new_master)
    n_rec = len(rec_master)
    stepper._replay_klus_master = copy.deepcopy(new_master)

    # --- ?????????master ?????????????? ---
    exact_master = (
        align.start_new == 0
        and align.start_rec == 0
        and align.match_len == n_new
        and align.match_len == n_rec
        and n_new == n_rec
    )
    if (
        exact_master
        and str(getattr(stepper, "data_feed_mode", "step")) == "unified"
        and int(payload.snapshot.step_idx) >= n_new - 1
    ):
        _restore_snapshot(stepper, payload, target_step_idx=n_new - 1)
        out.applied = True
        out.mode = "exact"
        out.record_path = pkl_path
        out.overlap_bars = n_new
        out.skipped_step_bars = n_new
        out.message = f"\u8c03\u7528record\u6210\u529f\uff1aexact unified\uff08{n_new} \u6839\uff09"
        print(f"[ChanRecord] exact unified {pkl_path}")
        push_record_trace(out.message)
        return out

    # --- ???????new ?? record ??????????????????? ---
    if (
        allow_end_snapshot_restore
        and align.start_new == 0
        and align.start_rec == 0
        and align.match_len == n_rec
        and n_new > n_rec
        and int(payload.snapshot.step_idx) >= n_rec - 1
    ):
        _restore_snapshot(stepper, payload, target_step_idx=n_rec - 1)
        if stepper.chan is not None:
            stepper.chan._replay_klus_master = stepper._replay_klus_master
        fed = _feed_remaining_steps(stepper, new_master, n_rec)
        out.applied = True
        out.mode = "extend"
        out.record_path = pkl_path
        out.overlap_bars = n_rec
        out.skipped_step_bars = n_rec
        out.message = f"\u8c03\u7528record\u6210\u529f\uff1aextend\uff08\u590d\u7528 {n_rec} \u6839\uff0c\u8865\u7b97 {fed} \u6839\uff09"
        print(f"[ChanRecord] extend hit {pkl_path} +{fed}")
        push_record_trace(out.message)
        return out

    # --- ??????????????? record ??????????????????????????? ---
    if align.match_len >= 1:
        prefix_len = align.match_len
        if (
            allow_end_snapshot_restore
            and align.start_new == 0
            and align.start_rec == 0
            and align.match_len == n_rec
            and int(payload.snapshot.step_idx) >= n_rec - 1
        ):
            _restore_snapshot(stepper, payload, target_step_idx=n_rec - 1)
            if stepper.chan is not None:
                stepper.chan._replay_klus_master = stepper._replay_klus_master
            fed = _feed_remaining_steps(stepper, new_master, n_rec)
            out.applied = True
            out.mode = "extend"
            out.record_path = pkl_path
            out.overlap_bars = n_rec
            out.skipped_step_bars = n_rec
            out.message = f"\u8c03\u7528record\u6210\u529f\uff1aextend\uff08\u590d\u7528 {n_rec} \u6839\uff0c\u8865\u7b97 {fed} \u6839\uff09"
            print(f"[ChanRecord] extend(hit-2) {pkl_path} +{fed}")
            push_record_trace(out.message)
            return out

        fed = _replay_prefix_steps(
            stepper,
            new_master,
            prefix_len,
            create_replay_chan_fn=create_replay_chan_fn,
            cfg=cfg,
            code=code,
            begin_date=begin_date,
            end_date=end_date,
            autype=autype,
            k_type=k_type,
            data_src=data_src,
        )
        extra = _feed_remaining_steps(stepper, new_master, prefix_len)
        out.applied = True
        out.mode = "overlap_replay"
        out.record_path = pkl_path
        out.overlap_bars = prefix_len
        out.skipped_step_bars = 0
        out.message = (
            f"\u8c03\u7528record\u6210\u529f\uff1aoverlap_replay\uff08\u91cd\u53e0 {prefix_len} \u6839\uff0c\u8865\u7b97 {extra} \u6839\uff09"
        )
        print(f"[ChanRecord] overlap replay {pkl_path} prefix={prefix_len} extra={extra}")
        push_record_trace(out.message)
        return out

    return out


def capture_chan_record_payload(stepper: Any, *, meta: dict[str, Any]) -> _ChanRecordPayload:
    snap = capture_stepper_snapshot(stepper)
    return _ChanRecordPayload(
        version=RECORD_VERSION,
        meta=dict(meta),
        replay_klus_master=copy.deepcopy(stepper._replay_klus_master or []),
        replay_klus_master_raw=copy.deepcopy(stepper._replay_klus_master_raw)
        if stepper._replay_klus_master_raw is not None
        else None,
        kline_all=list(stepper.kline_all or []),
        snapshot=snap,
        effective_cfg_dict=dict(stepper.effective_cfg_dict or {}),
        data_feed_mode=str(getattr(stepper, "data_feed_mode", "step")),
        data_form_mode=str(getattr(stepper, "data_form_mode", "traditional")),
        chan_algo=str(getattr(stepper, "chan_algo", "")),
        rhythm_calc_mode=str(getattr(stepper, "rhythm_calc_mode", "")),
        unified_full_payload=copy.deepcopy(stepper._unified_full_payload)
        if getattr(stepper, "_unified_full_payload", None)
        else None,
        data_src_used=getattr(stepper, "data_src_used", None),
        data_src_chip_used=getattr(stepper, "data_src_chip_used", None),
    )


def _save_record_sync(
    stepper: Any,
    *,
    fingerprint: str,
    code: str,
    k_type_key: str,
    autype_key: str,
    begin_date: str,
    end_date: Optional[str],
) -> None:
    # record 持久化已禁用，不生成 pkl/meta 文件。
    return


def warmup_stepper_to_end(stepper: Any) -> int:
    """???????????????????????? record??"""
    if str(getattr(stepper, "data_feed_mode", "step")) == "unified":
        return len((stepper._unified_full_payload or {}).get("kline") or [])
    n = 0
    while stepper.step():
        n += 1
    return n


_save_lock = threading.Lock()


def schedule_chan_record_save(
    stepper: Any,
    *,
    enabled: bool,
    fingerprint: str,
    code: str,
    k_type_key: str,
    autype_key: str,
    begin_date: str,
    end_date: Optional[str],
    warmup: bool = True,
) -> None:
    """???????????????????????? a_replay_record??"""
    if not is_chan_record_enabled(enabled):
        return

    def _worker() -> None:
        try:
            push_record_trace("\u7f20\u8bbarecord\uff1a\u4fdd\u5b58\u4e2d\u2026")
            with _save_lock:
                st = stepper
                if warmup and str(getattr(st, "data_feed_mode", "step")) != "unified":
                    warmup_stepper_to_end(st)
                _save_record_sync(
                    st,
                    fingerprint=fingerprint,
                    code=code,
                    k_type_key=k_type_key,
                    autype_key=autype_key,
                    begin_date=begin_date,
                    end_date=end_date,
                )
            push_record_trace("\u7f20\u8bbarecord\uff1a\u4fdd\u5b58\u5b8c\u6210")
        except Exception as exc:
            print(f"[ChanRecord] save worker failed: {exc}")
            push_record_trace(f"\u7f20\u8bbarecord\uff1a\u4fdd\u5b58\u5931\u8d25\uff08{exc}\uff09")

    threading.Thread(target=_worker, name="chan-record-save", daemon=True).start()
