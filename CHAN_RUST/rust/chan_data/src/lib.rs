//! a_Data 离线分笔 → K 线聚合 → N 段递归流水线（1段=笔，2段=线段，…穷尽）。
//! 模块分工：engine=包含合并+分型唯一内核；pipeline=N 段递归；
//! combine/feature/seg_eigen=旧字段兼容映射；segment_first=全层首段策略。

mod combine;
mod engine;
mod error;
mod feature;
mod kline;
mod offline;
mod pipeline;
mod seg_eigen;
mod segment_first;
mod tick;

pub use combine::{
    build_bi_combine_frames, build_kline_combine_bundle, build_kline_combine_bundle_with,
    build_kline_combine_frames, BiConfirmSignal, KlineCombineBundle, KlineCombineFrame,
};
pub use engine::{CombineEngine, FxEvent, FxKind, MergeDir, MergeUnit, MergedGroup, ProbeState};
pub use error::{ChanDataError, Result};
pub use feature::{
    build_bi_virtual_bar_views, enrich_fractal_peak_dist, fractal_extreme_bar_idx,
    weekday_from_bar, BarCrosshairFeature, BiSegment, BiVirtualBar, BiVirtualBarView,
};
pub use kline::{KlineBar, KlinePeriod};
pub use offline::{default_data_root, list_stock_codes, load_klines, resolve_data_root};
pub use pipeline::{
    run_pipeline, LevelBundleOut, LevelConfirm, LevelSegment, LevelSnap, LevelUnitBar,
    PipelineOptions, PipelineResult,
};
pub use segment_first::{
    build_pending_default_unit, resolve_segment_policy, trial_first_segment, POLICY_PENDING,
    POLICY_PURGED, POLICY_RETAINED,
};
pub use seg_eigen::{
    BarSubSnapshot, EigenFrame, FirstSegDirSignal, SegAnalysisBundle, SegConfirmSignal, SegLine,
};
