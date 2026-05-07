"""高性能步进快照模块（无业务逻辑变更，纯性能优化）。

设计目标
- 步进多根 K 线后继续步进时不再卡顿，性能不随历史步数累积而劣化。
- 单步轻量快照避免不必要的递归 deepcopy；仅对会被原地改写的字段做必要拷贝。
- chan / indicators 仍由全量 snapshot 负责（稀疏间隔触发）。

为何能加速
原 `_capture_light_snapshot()` 每步对 `bsp_history`、`bsp_judge_logs`、`rhythm_hit_history`、
`trade_events`、`_last_judge_stats` 等做整体 deepcopy；这些列表 / 字典中
**绝大多数元素都是 frozen dict**（创建后不再修改），只需 list/dict 浅拷贝
（共享同一批不变元素）即可获得正确的快照副本，省下成倍的递归走访开销。

例外项及对应策略
- `bsp_history`：item 的 `status` 字段会被 `_judge_bsp_against_all` 原地改写，
  故抓取时记录每个已设值 status 的 (idx, status)；回退时先按长度截断，
  再把 prefix 中所有 status 重置为 None，最后写回 (idx, status) 即可。
- `_last_level_dirs`：是小字典且会被原地改写，dict() 浅拷贝即可。
- `PaperAccount`：字段会被原地改写，转 tuple 快照后回退时逐字段写回。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Optional


def _account_to_tuple(account: Any) -> tuple:
    """PaperAccount → 不可变 tuple 快照（无需 deepcopy）。"""
    if account is None:
        return ()
    return (
        float(getattr(account, "initial_cash", 0.0)),
        float(getattr(account, "cash", 0.0)),
        int(getattr(account, "position", 0)),
        float(getattr(account, "avg_cost", 0.0)),
        getattr(account, "last_open_step", None),
        getattr(account, "last_trade_step", None),
        getattr(account, "same_step_flip_side", None),
        getattr(account, "same_step_flip_at_idx", None),
    )


def _restore_account_from_tuple(account: Any, snap: tuple) -> None:
    if account is None or not snap:
        return
    (
        account.initial_cash,
        account.cash,
        account.position,
        account.avg_cost,
        account.last_open_step,
        account.last_trade_step,
        account.same_step_flip_side,
        account.same_step_flip_at_idx,
    ) = snap


@dataclass
class AppStepDelta:
    """整个 AppState 的单步增量快照（步进前抓取，回退到步进前状态用）。

    关键差异于旧 AppLightSnapshot：
    - 列表用「list(...) 浅拷贝 + 长度」记录；
      列表元素若不可变，则共享底层 dict 引用，不递归走访；
    - bsp_history 的可变 status 字段以稀疏 map 记录；
    - 字典 / dataclass 类小对象用 dict()/tuple 浅快照。
    """
    # 兼容旧轻量快照命名（back_n 中以 step_idx 匹配目标）。
    step_idx: int
    active_chart_id: str
    chart_mode: str

    # —— 「以浅拷贝+长度」记录（元素均为创建后不可变的 frozen dict） ——
    trade_events_shallow: list  # 共享 dict 引用，不递归
    bsp_judge_logs_shallow: list
    rhythm_hit_history_shallow: list
    rhythm_hit_keys_snapshot: set

    # —— bsp_history：item.status 会被改写，需特殊处理 ——
    bsp_history_shallow: list
    bsp_history_status_map: dict[int, Any]

    # —— 小字典/标量（值会被替换 / 原地改写） ——
    last_level_dirs: dict[str, Any]
    judge_notice: bool
    last_judge_stats_ref: Any  # 字典引用本身被替换，不在内部修改 → 直接保留引用
    last_judge_x: Any
    last_judge_time: Any

    # PaperAccount 的字段值（不可变 tuple）
    account_tuple: tuple


def _bsp_history_freeze(bsp_history: list) -> list[dict[str, Any]]:
    """将 bsp_history 冻结为新 dict 列表，隔离后续 status 改写。"""
    out: list[dict[str, Any]] = []
    for it in bsp_history or []:
        if isinstance(it, dict):
            out.append(dict(it))
        else:
            out.append(it)
    return out


def capture_app_step_delta(
    *,
    pre_step_idx: int,
    active_chart_id: str,
    chart_mode: str,
    trade_events: list,
    bsp_history: list,
    bsp_judge_logs: list,
    rhythm_hit_history: list,
    rhythm_hit_keys: set,
    last_level_dirs: dict,
    judge_notice: bool,
    last_judge_stats: Any,
    last_judge_x: Any,
    last_judge_time: Any,
    account: Any,
) -> AppStepDelta:
    """步进前抓取单步增量快照（绝大多数字段是浅拷贝，复杂度 O(列表长度)）。"""
    return AppStepDelta(
        step_idx=int(pre_step_idx),
        active_chart_id=str(active_chart_id),
        chart_mode=str(chart_mode),
        trade_events_shallow=list(trade_events or []),
        bsp_judge_logs_shallow=list(bsp_judge_logs or []),
        rhythm_hit_history_shallow=list(rhythm_hit_history or []),
        rhythm_hit_keys_snapshot=set(rhythm_hit_keys or set()),
        # bsp_history.item.status 会被 _judge_bsp_against_all 原地改写；
        # 必须 dict 浅拷贝隔离，否则快照会"穿透"成最新 status。
        bsp_history_shallow=_bsp_history_freeze(bsp_history),
        bsp_history_status_map={},  # 已在每个 item dict 中冻结，不再需要补丁
        last_level_dirs=dict(last_level_dirs or {}),
        judge_notice=bool(judge_notice),
        last_judge_stats_ref=last_judge_stats,
        last_judge_x=last_judge_x,
        last_judge_time=last_judge_time,
        account_tuple=_account_to_tuple(account),
    )


def overlay_app_step_delta(
    delta: AppStepDelta,
    *,
    set_active_chart_id,
    set_chart_mode,
    set_trade_events,
    set_bsp_history,
    set_bsp_judge_logs,
    set_rhythm_hit_history,
    set_rhythm_hit_keys,
    set_last_level_dirs,
    set_judge_notice,
    set_last_judge_stats,
    set_last_judge_x,
    set_last_judge_time,
    account: Any,
) -> None:
    """以 delta 覆盖当前 AppState 的非 chan 状态（chan/indicators 由调用方先复原）。

    注意：列表用「浅拷贝快照」整体替换 self 的引用，与旧 _restore_light_snapshot 一致。
    bsp_history 中已被原地改写的 status 字段会被先全部重置为 None，再按 delta 写回。
    """
    set_active_chart_id(delta.active_chart_id)
    set_chart_mode(delta.chart_mode)
    set_trade_events(list(delta.trade_events_shallow))
    set_bsp_judge_logs(list(delta.bsp_judge_logs_shallow))
    set_rhythm_hit_history(list(delta.rhythm_hit_history_shallow))
    set_rhythm_hit_keys(set(delta.rhythm_hit_keys_snapshot))
    # bsp_history：delta 中 item 已被 dict() 冻结，直接 list() 浅拷贝即可恢复。
    set_bsp_history(list(delta.bsp_history_shallow))
    set_last_level_dirs(dict(delta.last_level_dirs))
    set_judge_notice(bool(delta.judge_notice))
    set_last_judge_stats(delta.last_judge_stats_ref)
    set_last_judge_x(delta.last_judge_x)
    set_last_judge_time(delta.last_judge_time)
    _restore_account_from_tuple(account, delta.account_tuple)
