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
    # 深拷贝缠论状态 + 指标状态，回退时可直接恢复到上一根
    return StepperRollbackSnapshot(
        step_idx=int(stepper.step_idx),
        chan=copy.deepcopy(stepper.chan),
        indicators=copy.deepcopy(stepper.indicators),
        indicator_history=copy.deepcopy(stepper.indicator_history),
        trend_lines=copy.deepcopy(stepper.trend_lines),
        structure_bundle=copy.deepcopy(stepper.structure_bundle),
        bundle_cache_step_idx=copy.deepcopy(stepper._bundle_cache_step_idx),
        serialized_klu_cache=copy.deepcopy(stepper._serialized_klu_cache),
        chart_payload_cache=copy.deepcopy(stepper._chart_payload_cache),
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
    if stepper.chan is None:
        stepper._iter = None
    else:
        # 不走 step_load（会 do_init 清空），直接从当前内部游标继续。
        stepper._iter = stepper.chan.load_iterator(lv_idx=0, parent_klu=None, step=True)

