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
mod zs;
mod bsp;

pub use combine::{
    build_k1_combine_frames, build_k1_combine_frames_with, build_kline_combine_bundle,
    build_kline_combine_bundle_with, build_kline_combine_frames, K0ConfirmSignal,
    KlineCombineBundle, KlineCombineFrame,
};
pub use engine::{
    seed_contain_trunc_up_leg, seed_is_leave, seed_leave_dir, seed_nonleave_may_trunc,
    seed_second_contains_first, CombineEngine, FxEvent, FxKind, MergeDir, MergeUnit, MergedGroup,
    ProbeState, TruncGuard, TruncReplayState,
};
pub use error::{ChanDataError, Result};
pub use feature::{
    build_k1_bar_views, enrich_fractal_peak_dist, fractal_extreme_bar_idx,
    weekday_from_bar, BarCrosshairFeature, K0Line, K1Bar, K1BarView,
};
pub use kline::{KlineBar, KlinePeriod};
pub use offline::{
    default_data_root, list_stock_codes, load_klines, load_test_ohlc_csv, resolve_data_root,
    save_test_ohlc, save_test_ohlc_csv, test_ohlc_csv_path,
};
pub use pipeline::{
    run_pipeline, LevelBundleOut, LevelConfirm, LevelSegment, LevelSnap, LevelUnitBar,
    PipelineOptions, PipelineResult,
};
pub use segment_first::{aggregate_unit_range, pole_x_in_range};
pub use seg_eigen::{
    BarSubSnapshot, EigenFrame, FirstSegDirSignal, K1AnalysisBundle, K1ConfirmSignal, K1Line,
};
pub use kuaduan::{
    build_kuaduan_v1_for_levels, find_kuaduan_v1, kuaduan_v1_to_frames, KuaDuanV1, KuaDuanV1Frame,
};
pub use zs::{
    build_zs_for_levels, find_zs, level_zs_frames, zs_frames_from_list, zs_to_frames, ZS, ZSConfig,
    ZSFrame, ZSAlgo, ZSCombineMode,
};
pub use bsp::{
    build_bsp_for_levels, find_bsp, level_bsp_frames, bsp_to_frames, BSP, BSPConfig, BSPFrame,
};
