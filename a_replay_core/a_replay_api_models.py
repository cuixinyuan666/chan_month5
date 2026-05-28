from typing import Any, Optional

from pydantic import BaseModel, Field


class InitReq(BaseModel):
    code: str
    begin_date: str
    end_date: Optional[str] = None
    initial_cash: float = 10_000
    autype: str = "qfq"
    chan_config: Optional[dict[str, Any]] = None
    k_type: str = "daily"  # 周期类型
    chart_mode: str = "single"  # single | dual | multi
    k_type_2: Optional[str] = None  # 双周期下第二周期
    # 单品种多周期单图：至少 2 个周期 API 键（与 k_type 独立，服务端按粒度选最细为步进驱动）
    k_types_multi: Optional[list[str]] = None
    active_chart_id: str = "chart1"  # chart1 | chart2
    # 用户确认使用离线源后二次 init 传 True；单次 init 可传 data_source_priority 覆盖链（不改服务端全局）
    confirm_offline: bool = False
    data_source_priority: Optional[list[str]] = None
    data_form_mode: str = "traditional"
    data_form_quantity: Optional[int] = None
    data_form_quantity_alloc: str = "front"  # front=靠前分配 | back=靠后分配
    offline_data_custom: str = "native"  # native | merge_no_bs
    # 喂数据方式：step=逐K喂数据；unified=一次性喂给缠论计算（仅看画线/筹码）
    data_feed_mode: str = "step"
    kline_presentation_mode: str = "step"  # step=步进呈现 | instant=一次性呈现末根
    # 回退缓存参数（前端可调）
    rollback_cache_depth: Optional[int] = None
    rollback_full_snapshot_interval: Optional[int] = None
    rollback_capture_max_bars: Optional[int] = None


class ReconfigReq(BaseModel):
    chan_config: dict[str, Any]
    data_form_mode: Optional[str] = None
    data_form_quantity: Optional[int] = None
    data_form_quantity_alloc: Optional[str] = None
    offline_data_custom: Optional[str] = None
    data_feed_mode: Optional[str] = None
    kline_presentation_mode: Optional[str] = None
    rollback_cache_depth: Optional[int] = None
    rollback_full_snapshot_interval: Optional[int] = None
    rollback_capture_max_bars: Optional[int] = None


class BackNReq(BaseModel):
    n: int = 1


class StepReq(BaseModel):
    judge_mode: Optional[str] = None  # "auto" | "manual"
    active_chart_id: Optional[str] = None
    n: int = 1


class JudgeBspReq(BaseModel):
    reason: str = "manual_check"


class GotoStepReq(BaseModel):
    """跳转到指定步进索引（与 rebuild_to_step 一致，0 为第一根可见 K）。"""

    step_idx: int = 0
    # 与 /api/step 一致：指定当前激活图窗，跳转作用于该图的步进器
    active_chart_id: Optional[str] = None


class SessionKlineViewReq(BaseModel):
    """弹窗查看全量 K 线缓存：OHLC / 成交量+筹码分桶 / 原始字段。"""

    chart_id: str = "active"  # chart1 | chart2 | active
    view: str = "kline"  # kline | volume_chip | all
    # 单品种多周期单图：指定 API 周期键（如 3min、5min），从对应步进器取 kline_all；空则默认驱动层（最细周期）
    layer_k_type: Optional[str] = None


class IndicatorBacktestReq(BaseModel):
    """指标+买卖点回测（独立会话）。步进顺序与复盘 api_step 一致：驱动 step → 被动 sync → bt_dual 防未来。"""

    code: str
    begin_date: str
    end_date: Optional[str] = None
    initial_cash: float = 10_000.0
    autype: str = "qfq"
    chan_config: Optional[dict[str, Any]] = None
    k_type: str = "daily"  # 周期1
    chart_mode: str = "single"
    k_type_2: Optional[str] = None  # 周期2
    step_driver: str = "auto"  # auto | k1 | k2：步进时钟；auto=较细周期
    entry_conditions: list[dict[str, Any]] = Field(default_factory=list)
    entry_combine: str = "and"
    exit_conditions: list[dict[str, Any]] = Field(default_factory=list)
    exit_combine: str = "and"
    exit_hold_bars: Optional[int] = None  # 与出场公式为或；均未设时内部默认 5
    # 兼容旧前端
    conditions: Optional[list[dict[str, Any]]] = None
    combine_mode: Optional[str] = None
    sell_hold_bars: Optional[int] = None
    confirm_offline: bool = False
    data_source_priority: Optional[list[str]] = None
    data_form_mode: str = "traditional"
    data_form_quantity: Optional[int] = None

