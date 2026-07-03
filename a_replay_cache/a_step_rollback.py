import copy
from dataclasses import dataclass
from typing import Any, Optional


@dataclass
class StepperRollbackSnapshot:
    step_idx: int
    chan: Any
    indicators: dict[str, Any]
    indicator_history: list[dict[str, Any]]
    trend_lines: list[dict[str, Any]]
    structure_bundle: Any
    bundle_cache_step_idx: Optional[int]
    serialized_klu_cache: list[dict[str, Any]]
    chart_payload_cache: dict[bool, tuple[int, dict[str, Any]]]
    bi_sure_signal_history: list[dict[str, Any]] | None = None
    bi_sure_signal_seen_keys: set[str] | None = None
    seg_sure_signal_history: list[dict[str, Any]] | None = None
    seg_sure_signal_seen_keys: set[str] | None = None


@dataclass
class AppRollbackSnapshot:
    active_chart_id: str
    chart_mode: str
    stepper1: StepperRollbackSnapshot
    stepper2: Optional[StepperRollbackSnapshot]
    trade_events: list[dict[str, Any]]
    account: Any
    bsp_history: list[dict[str, Any]]
    rhythm_hit_history: list[dict[str, Any]]
    rhythm_hit_keys: set[str]
    bsp_judge_logs: list[dict[str, Any]]
    last_level_dirs: dict[str, Optional[str]]
    judge_notice: bool
    last_judge_stats: Optional[dict[str, Any]]
    last_judge_x: Optional[int]
    last_judge_time: Optional[str]
    # multi：除 driver 外的各周期步进器快照，顺序与 AppState.multi_steppers 一致
    multi_steppers: Optional[list[StepperRollbackSnapshot]] = None


@dataclass
class AppLightSnapshot:
    step_idx: int
    active_chart_id: str
    chart_mode: str
    trade_events: list[dict[str, Any]]
    account: Any
    bsp_history: list[dict[str, Any]]
    rhythm_hit_history: list[dict[str, Any]]
    rhythm_hit_keys: set[str]
    bsp_judge_logs: list[dict[str, Any]]
    last_level_dirs: dict[str, Optional[str]]
    judge_notice: bool
    last_judge_stats: Optional[dict[str, Any]]
    last_judge_x: Optional[int]
    last_judge_time: Optional[str]


def capture_stepper_snapshot(stepper: Any) -> StepperRollbackSnapshot:
    # 深拷贝缠论状态 + 指标状态，回退时可直接恢复到上一根。
    # 性能优化要点：
    # 1) 列表 / dict 元素是 immutable（int/float/str/None）的容器，
    #    直接 list(...)/dict(...) 浅拷贝即可，无需 deepcopy 递归走每个元素；
    # 2) chart_payload_cache 中的值是已定型的 dict，浅拷贝足够；
    # 3) bundle_cache_step_idx 是 Optional[int]，直接赋值；
    # 4) chan/indicators/structure_bundle 含复杂引用图，仍需 deepcopy。
    sk_cache = stepper._serialized_klu_cache
    chart_cache = stepper._chart_payload_cache
    return StepperRollbackSnapshot(
        step_idx=int(stepper.step_idx),
        chan=copy.deepcopy(stepper.chan),
        indicators=copy.deepcopy(stepper.indicators),
        indicator_history=list(stepper.indicator_history),
        trend_lines=list(stepper.trend_lines),
        structure_bundle=copy.deepcopy(stepper.structure_bundle),
        bundle_cache_step_idx=stepper._bundle_cache_step_idx,
        serialized_klu_cache=list(sk_cache) if isinstance(sk_cache, list) else [],
        chart_payload_cache=dict(chart_cache) if isinstance(chart_cache, dict) else {},
        bi_sure_signal_history=[dict(it) for it in getattr(stepper, "bi_sure_signal_history", [])],
        bi_sure_signal_seen_keys=set(getattr(stepper, "_bi_sure_signal_seen_keys", set())),
        seg_sure_signal_history=[dict(it) for it in getattr(stepper, "seg_sure_signal_history", [])],
        seg_sure_signal_seen_keys=set(getattr(stepper, "_seg_sure_signal_seen_keys", set())),
    )


def restore_stepper_snapshot(stepper: Any, snap: StepperRollbackSnapshot) -> None:
    stepper.chan = snap.chan
    stepper.step_idx = int(snap.step_idx)
    stepper.indicators = snap.indicators
    stepper.indicator_history = snap.indicator_history
    stepper.trend_lines = snap.trend_lines
    stepper.structure_bundle = snap.structure_bundle
    stepper._bundle_cache_step_idx = snap.bundle_cache_step_idx
    stepper._serialized_klu_cache = snap.serialized_klu_cache
    stepper._chart_payload_cache = snap.chart_payload_cache
    signal_hist = getattr(snap, "bi_sure_signal_history", None) or []
    stepper.bi_sure_signal_history = [dict(it) for it in signal_hist]
    seen_keys = getattr(snap, "bi_sure_signal_seen_keys", None)
    if seen_keys is None:
        seen_keys = {str(it.get("key")) for it in stepper.bi_sure_signal_history if isinstance(it, dict) and it.get("key")}
    seen_keys = set(seen_keys)
    # Bi确认柱去重：兼容旧快照里的旧key，同时补上当前key算法。
    key_fn = getattr(stepper, "_bi_sure_signal_key", None)
    if callable(key_fn):
        for it in stepper.bi_sure_signal_history:
            try:
                seen_keys.add(key_fn(it))
            except Exception:
                pass
    stepper._bi_sure_signal_seen_keys = seen_keys
    stepper._bi_sure_signal_seen_list_id = id(stepper.bi_sure_signal_history)
    stepper._bi_sure_signal_seen_count = len(stepper.bi_sure_signal_history)
    seg_signal_hist = getattr(snap, "seg_sure_signal_history", None) or []
    stepper.seg_sure_signal_history = [dict(it) for it in seg_signal_hist]
    seg_seen_keys = getattr(snap, "seg_sure_signal_seen_keys", None)
    if seg_seen_keys is None:
        seg_seen_keys = {str(it.get("key")) for it in stepper.seg_sure_signal_history if isinstance(it, dict) and it.get("key")}
    seg_seen_keys = set(seg_seen_keys)
    # 段确认柱去重：兼容旧快照，同时补上当前key算法。
    seg_key_fn = getattr(stepper, "_seg_sure_signal_key", None)
    if callable(seg_key_fn):
        for it in stepper.seg_sure_signal_history:
            try:
                seg_seen_keys.add(seg_key_fn(it))
            except Exception:
                pass
    stepper._seg_sure_signal_seen_keys = seg_seen_keys
    stepper._seg_sure_signal_seen_list_id = id(stepper.seg_sure_signal_history)
    stepper._seg_sure_signal_seen_count = len(stepper.seg_sure_signal_history)
    if stepper.chan is None:
        stepper._iter = None
    else:
        # 不走 step_load（会 do_init 清空），直接从当前内部游标继续。
        stepper._iter = stepper.chan.load_iterator(lv_idx=0, parent_klu=None, step=True)

