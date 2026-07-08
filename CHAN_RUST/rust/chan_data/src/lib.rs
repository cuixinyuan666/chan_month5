//! a_Data 离线分笔 → K 线聚合（语义对齐 Python COfflineInline）。

mod combine;
mod error;
mod feature;
mod kline;
mod offline;
mod seg_eigen;
mod tick;

pub use combine::{
    build_bi_combine_frames, build_combine_frames_from_hl_units, build_kline_combine_bundle,
    build_kline_combine_frames, BiConfirmSignal, HlMergeUnit, KlineCombineBundle,
    KlineCombineFrame,
};
pub use feature::{
    build_bi_virtual_bar_views, enrich_bi_crosshair_fields, enrich_fractal_peak_dist,
    fractal_extreme_bar_idx, BarCrosshairFeature, BiSegment, BiVirtualBar, BiVirtualBarView,
};
pub use seg_eigen::{
    build_seg_analysis, BarSubSnapshot, EigenFrame, FirstSegDirSignal, SegAnalysisBundle,
    SegConfirmSignal, SegLine,
};
pub use error::{ChanDataError, Result};
pub use kline::{KlineBar, KlinePeriod};
pub use offline::{default_data_root, list_stock_codes, load_klines, resolve_data_root};
