//! a_Data 离线分笔 → K 线聚合 → Kn 递归流水线（K0=原始K，K1=K0连线(笔)，K2=K1连线(线段)，…穷尽；旧称「n段」）。
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
mod kuaduan;

pub use combine::{
    build_k1_combine_frames, build_k1_combine_frames_with, build_kline_combine_bundle,
    build_kline_combine_bundle_with, build_kline_combine_frames, K0ConfirmSignal,
    KlineCombineBundle, KlineCombineFrame,
};
pub use engine::{
    CombineEngine, FxEvent, FxKind, MergeDir, MergeUnit, MergedGroup, ProbeState, TruncGuard,
    TruncReplayState,
};
pub use error::{ChanDataError, Result};
pub use feature::{
    build_k1_bar_views, enrich_fractal_peak_dist, fractal_extreme_bar_idx,
    weekday_from_bar, BarCrosshairFeature, K0Line, K1Bar, K1BarView,
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
    BarSubSnapshot, EigenFrame, FirstSegDirSignal, K1AnalysisBundle, K1ConfirmSignal, K1Line,
};
pub use kuaduan::{build_kuaduan_for_levels, find_kuaduan, kuaduan_to_frames, KuaDuan, KuaDuanFrame};
