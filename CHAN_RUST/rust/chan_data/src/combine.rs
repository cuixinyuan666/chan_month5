//! K线合并 bundle：由 N 段流水线（pipeline）驱动，本文件只做旧字段兼容映射。
//! 合并/分型内核唯一实现见 engine.rs；递归 N 段见 pipeline.rs。

use serde::{Deserialize, Serialize};

use crate::engine::{CombineEngine, MergeUnit};
use crate::feature::{
    build_bi_virtual_bar_views, enrich_fractal_peak_dist, weekday_from_bar, BarCrosshairFeature,
    BiSegment, BiVirtualBar,
};
use crate::kline::KlineBar;
use crate::pipeline::{
    run_pipeline, LevelBundleOut, LevelSegment, LevelUnitBar, PipelineOptions, PipelineResult,
};
use crate::seg_eigen::{
    BarSubSnapshot, FirstSegDirSignal, SegAnalysisBundle, SegConfirmSignal, SegLine,
};

/// 合并 K 线线框（对齐 serialize_kline_combine）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KlineCombineFrame {
    pub x1: i32,
    pub x2: i32,
    pub t1: String,
    pub t2: String,
    pub high: f64,
    pub low: f64,
    pub fx: String,
    pub count: i32,
    /// 末端落在 x2 分钟 K 左半侧（右边界=该 K 中轴；笔合并框与笔 K 半侧衔接一致）
    #[serde(default)]
    pub end_at_left_half: bool,
    /// 起始落在 x1 分钟 K 右半侧（左边界=该 K 中轴）
    #[serde(default)]
    pub start_at_right_half: bool,
}

/// K线合并分型确认柱：合并 K 线顶/底分型确认当步 K（分型连接即笔，逐K当下冻结）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BiConfirmSignal {
    /// 分型确认当步 K 线索引（第三元素进入当步）
    pub x: i32,
    pub fx: String,
    /// 向上笔=1，向下笔=-1
    pub value: i32,
    pub fractal_x1: i32,
    pub fractal_x2: i32,
}

/// 合并线框 + 笔确认 + 十字线特征 + 笔段链 + N段流水线（一次遍历产出，逐K当下）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KlineCombineBundle {
    pub frames: Vec<KlineCombineFrame>,
    pub bi_confirms: Vec<BiConfirmSignal>,
    /// 每根 K 十字线特征（星期 w1..w7、K线合并K线序、各层 N 段快照）
    #[serde(default)]
    pub bar_features: Vec<BarCrosshairFeature>,
    /// 1段（笔）链：锚定配对，链条无缝
    #[serde(default)]
    pub bi_segments: Vec<BiSegment>,
    /// 2段（线段）兼容包（由流水线 Level2 映射）
    #[serde(default)]
    pub seg_analysis: SegAnalysisBundle,
    /// 笔确认后包装笔 K 线（主图展示，含末步进行中笔）
    #[serde(default)]
    pub bi_virtual_bars: Vec<BiVirtualBar>,
    /// 笔 K 线笔K线合并线框（副图「笔K线合并」）
    #[serde(default)]
    pub bi_combine_frames: Vec<KlineCombineFrame>,
    /// 默认笔策略：pending / retained / purged（= default_segment_policies[0] 兼容别名）
    #[serde(default = "default_bi_policy_pending")]
    pub default_bi_policy: String,
    /// 全层首段策略（levels[0]=1段，levels[1]=2段，…）
    #[serde(default)]
    pub default_segment_policies: Vec<String>,
    /// 全层冻结段链（按层）
    #[serde(default)]
    pub level_segments: Vec<Vec<BiSegment>>,
    /// 全层展示用虚拟段 K（pending + 冻结 + 进行中）
    #[serde(default)]
    pub level_virtual_units: Vec<Vec<BiVirtualBar>>,
    /// N 段流水线全量输出（1=笔，2=线段，…穷尽）
    #[serde(default)]
    pub levels: Vec<LevelBundleOut>,
}

fn default_bi_policy_pending() -> String {
    "pending".to_string()
}

impl KlineCombineBundle {
    fn empty() -> Self {
        Self {
            frames: Vec::new(),
            bi_confirms: Vec::new(),
            bar_features: Vec::new(),
            bi_segments: Vec::new(),
            seg_analysis: SegAnalysisBundle::default(),
            bi_virtual_bars: Vec::new(),
            bi_combine_frames: Vec::new(),
            default_bi_policy: default_bi_policy_pending(),
            default_segment_policies: Vec::new(),
            level_segments: Vec::new(),
            level_virtual_units: Vec::new(),
            levels: Vec::new(),
        }
    }
}

/// LevelSegment → BiSegment（导出映射）
fn level_seg_to_bi_segment(s: &LevelSegment) -> BiSegment {
    BiSegment {
        idx: s.idx as i32,
        dir: s.dir,
        begin_confirm_x: s.begin_confirm_x,
        end_confirm_x: s.end_confirm_x,
        begin_fractal_x1: s.begin_fractal_x1,
        begin_fractal_x2: s.begin_fractal_x2,
        end_fractal_x1: s.end_fractal_x1,
        end_fractal_x2: s.end_fractal_x2,
        prev_idx: None,
        next_idx: None,
        is_bootstrap: false,
        is_promoted_default: s.is_promoted_default,
    }
}

fn link_bi_segments(chain: &mut [BiSegment]) {
    for i in 0..chain.len().saturating_sub(1) {
        chain[i].next_idx = Some(chain[i + 1].idx);
        chain[i + 1].prev_idx = Some(chain[i].idx);
    }
}

fn unit_to_virtual_bar(u: &LevelUnitBar) -> BiVirtualBar {
    BiVirtualBar {
        idx: u.idx as i32,
        dir: u.dir,
        x1: u.x1.min(u.x2),
        x2: u.x1.max(u.x2),
        open: u.open,
        high: u.high,
        low: u.low,
        close: u.close,
        confirm_x: u.confirm_x,
    }
}

/// 单层虚拟段 K：冻结段 + 进行中 + pending 占位
fn build_level_virtual_units(level: &LevelBundleOut) -> Vec<BiVirtualBar> {
    let mut v: Vec<BiVirtualBar> = level
        .segments
        .iter()
        .map(|s| seg_to_virtual_bar(s))
        .collect();
    if let Some(active) = &level.active_unit {
        v.push(unit_to_virtual_bar(active));
    } else if level.segment_policy == "pending" {
        if let Some(p) = &level.pending_unit {
            v.push(unit_to_virtual_bar(p));
        }
    }
    v
}

/// 每层段链映射
fn map_level_segments(level: &LevelBundleOut) -> Vec<BiSegment> {
    let mut segs: Vec<BiSegment> = level
        .segments
        .iter()
        .map(level_seg_to_bi_segment)
        .collect();
    link_bi_segments(&mut segs);
    segs
}

/// N 段 → 虚拟段 K 线（OHLC 冻结时已算好）
fn seg_to_virtual_bar(seg: &LevelSegment) -> BiVirtualBar {
    BiVirtualBar {
        idx: seg.idx as i32,
        dir: seg.dir,
        x1: seg.begin_pole_x.min(seg.end_pole_x),
        x2: seg.begin_pole_x.max(seg.end_pole_x),
        open: seg.open,
        high: seg.high,
        low: seg.low,
        close: seg.close,
        confirm_x: seg.end_confirm_x,
    }
}

/// 笔 K 线序列 → 笔K线合并线框（副图「笔K线合并」，末态展示口径）。
/// 多根包含合并：外侧框按分钟 K 中轴；仅一根笔 K（count=1）保留半侧锚定。
pub fn build_bi_combine_frames(bars: &[KlineBar], bi_bars: &[BiVirtualBar]) -> Vec<KlineCombineFrame> {
    if bi_bars.is_empty() {
        return Vec::new();
    }
    let views = build_bi_virtual_bar_views(bi_bars);
    let mut engine = CombineEngine::new();
    for (i, v) in views.iter().enumerate() {
        engine.feed(&MergeUnit {
            uid: i as i64,
            x1: v.view_x1,
            x2: v.view_x2,
            high: v.bar.high,
            low: v.bar.low,
        });
    }
    engine
        .groups()
        .iter()
        .map(|g| {
            let single = g.unit_count == 1;
            let vu = &views[g.first_uid.max(0) as usize];
            KlineCombineFrame {
                x1: g.x1,
                x2: g.x2,
                t1: bars
                    .get(g.x1.max(0) as usize)
                    .map(|b| b.time_text.clone())
                    .unwrap_or_default(),
                t2: bars
                    .get(g.x2.max(0) as usize)
                    .map(|b| b.time_text.clone())
                    .unwrap_or_default(),
                high: g.high,
                low: g.low,
                fx: g.fx.as_str().to_string(),
                count: g.unit_count,
                // 半侧标志仅 count=1 单根笔 K 框保留；多根合并框走中轴口径
                end_at_left_half: single && vu.end_at_left_half,
                start_at_right_half: single && vu.start_at_right_half,
            }
        })
        .collect()
}

/// 2段（线段）兼容映射：Level2 → SegAnalysisBundle
fn map_seg_analysis(pr: &PipelineResult) -> SegAnalysisBundle {
    let Some(l2) = pr.levels.get(1) else {
        return SegAnalysisBundle {
            bar_sub_snapshots: pr
                .bar_seg_rows
                .iter()
                .enumerate()
                .map(|(i, r)| BarSubSnapshot {
                    idx: i as i32,
                    building_seg_dir: r.building_dir,
                    first_seg_dir: r.first_dir,
                    seg_confirm: r.confirm,
                    eigen_slot: -1,
                    eigen_frames: Vec::new(),
                })
                .collect(),
            ..SegAnalysisBundle::default()
        };
    };
    let seg_confirms = l2
        .confirms
        .iter()
        .map(|c| SegConfirmSignal {
            x: c.x,
            fx: c.fx.clone(),
            value: c.value,
            ended_seg_dir: -c.value,
            peak_bi_idx: c.trigger_uid as i32,
            fractal_x1: c.fractal_x1,
            fractal_x2: c.fractal_x2,
            fractal_high: c.fractal_high,
            fractal_low: c.fractal_low,
        })
        .collect();
    let first_seg_dir_signals = if l2.first_dir != 0 {
        vec![FirstSegDirSignal {
            x: l2.first_dir_x,
            dir: l2.first_dir,
        }]
    } else {
        Vec::new()
    };
    let seg_lines = l2
        .segments
        .iter()
        .map(|s| SegLine {
            idx: s.idx as i32,
            dir: s.dir,
            begin_x: s.begin_pole_x,
            end_x: s.end_pole_x,
            begin_fractal_x1: s.begin_fractal_x1,
            begin_fractal_x2: s.begin_fractal_x2,
            end_fractal_x1: s.end_fractal_x1,
            end_fractal_x2: s.end_fractal_x2,
            begin_price: if s.dir > 0 {
                s.begin_fractal_low
            } else {
                s.begin_fractal_high
            },
            end_price: if s.dir > 0 {
                s.end_fractal_high
            } else {
                s.end_fractal_low
            },
        })
        .collect();
    let bar_sub_snapshots = pr
        .bar_seg_rows
        .iter()
        .enumerate()
        .map(|(i, r)| BarSubSnapshot {
            idx: i as i32,
            building_seg_dir: r.building_dir,
            first_seg_dir: r.first_dir,
            seg_confirm: r.confirm,
            eigen_slot: -1,
            eigen_frames: Vec::new(),
        })
        .collect();
    SegAnalysisBundle {
        eigen_frames: Vec::new(),
        seg_confirms,
        first_seg_dir_signals,
        seg_lines,
        bar_sub_snapshots,
        building_seg_dir: pr.bar_seg_rows.last().map(|r| r.building_dir).unwrap_or(0),
        first_seg_dir: l2.first_dir,
    }
}

/// 对已喂入 K 线跑穷尽 N 段流水线，输出兼容 bundle（默认开启有效性校验）。
pub fn build_kline_combine_bundle(bars: &[KlineBar]) -> KlineCombineBundle {
    build_kline_combine_bundle_with(bars, &PipelineOptions::default())
}

/// 带选项版本（validity_check 可配置）。
pub fn build_kline_combine_bundle_with(
    bars: &[KlineBar],
    opt: &PipelineOptions,
) -> KlineCombineBundle {
    if bars.is_empty() {
        return KlineCombineBundle::empty();
    }
    let pr = run_pipeline(bars, opt);
    let l1 = &pr.levels[0];

    // 1段（笔）分型确认（全量：含被丢弃的同向/校验失败分型，与旧口径一致）
    let bi_confirms: Vec<BiConfirmSignal> = l1
        .confirms
        .iter()
        .map(|c| BiConfirmSignal {
            x: c.x,
            fx: c.fx.clone(),
            value: c.value,
            fractal_x1: c.fractal_x1,
            fractal_x2: c.fractal_x2,
        })
        .collect();

    // 全层段链 / 策略 / 虚拟段 K
    let default_segment_policies: Vec<String> = pr
        .levels
        .iter()
        .map(|lv| lv.segment_policy.clone())
        .collect();
    let level_segments: Vec<Vec<BiSegment>> =
        pr.levels.iter().map(map_level_segments).collect();
    let level_virtual_units: Vec<Vec<BiVirtualBar>> = pr
        .levels
        .iter()
        .map(build_level_virtual_units)
        .collect();

    let bi_segments = level_segments
        .first()
        .cloned()
        .unwrap_or_default();
    let default_bi_policy = default_segment_policies
        .first()
        .cloned()
        .unwrap_or_else(|| "pending".to_string());
    let bi_virtual_bars = level_virtual_units
        .first()
        .cloned()
        .unwrap_or_default();

    let bi_combine_frames = build_bi_combine_frames(bars, &bi_virtual_bars);

    // 十字线/ML 特征：K线合并快照 + 各层 N 段快照（固定 purged：首笔确认前不填 bi_*）
    let mut bar_features: Vec<BarCrosshairFeature> = bars
        .iter()
        .enumerate()
        .map(|(i, b)| {
            let k = &pr.bar_k_snaps[i];
            let snaps = &pr.bar_level_snaps[i];
            let l1s = snaps.first();
            BarCrosshairFeature {
                idx: b.idx,
                weekday: weekday_from_bar(b),
                merge_inner_seq: k.inner_seq,
                merge_count: k.count,
                combine_fx: k.fx.clone(),
                combine_high: k.high,
                combine_low: k.low,
                fractal_peak_dist: 0,
                bi_idx: l1s.and_then(|s| s.unit_idx.map(|v| v as i32)),
                bi_merge_inner_seq: l1s.map(|s| s.merge_inner_seq).unwrap_or(0),
                bi_merge_count: l1s.map(|s| s.merge_count).unwrap_or(1),
                bi_open: l1s.map(|s| s.unit_open).unwrap_or(0.0),
                bi_high: l1s.map(|s| s.unit_high).unwrap_or(0.0),
                bi_low: l1s.map(|s| s.unit_low).unwrap_or(0.0),
                bi_close: l1s.map(|s| s.unit_close).unwrap_or(0.0),
                bi_volume: l1s.map(|s| s.unit_volume).unwrap_or(0.0),
                bi_combine_high: l1s.map(|s| s.combine_high).unwrap_or(0.0),
                bi_combine_low: l1s.map(|s| s.combine_low).unwrap_or(0.0),
                bi_combine_fx: l1s
                    .map(|s| s.combine_fx.clone())
                    .unwrap_or_else(|| "UNKNOWN".to_string()),
                levels: snaps.clone(),
            }
        })
        .collect();
    enrich_fractal_peak_dist(bars, &mut bar_features, &bi_confirms);

    let seg_analysis = map_seg_analysis(&pr);

    KlineCombineBundle {
        frames: l1.combine_frames.clone(),
        bi_confirms,
        bar_features,
        bi_segments,
        seg_analysis,
        bi_virtual_bars,
        bi_combine_frames,
        default_bi_policy,
        default_segment_policies,
        level_segments,
        level_virtual_units,
        levels: pr.levels,
    }
}

/// 兼容旧调用：仅返回合并线框。
pub fn build_kline_combine_frames(bars: &[KlineBar]) -> Vec<KlineCombineFrame> {
    build_kline_combine_bundle(bars).frames
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bar(i: usize, h: f64, l: f64) -> KlineBar {
        KlineBar {
            idx: i as i32,
            time_ms: i as i64,
            time_text: format!("2024/01/01 09:{i:02}"),
            open: l,
            high: h,
            low: l,
            close: h,
            volume: 1.0,
            amount: 1.0,
            metrics: serde_json::Map::new(),
        }
    }

    #[test]
    fn stepwise_combine_hl_frozen_per_bar() {
        // 向上合并：#0 当步只看自身，#1/#2 逐步扩展
        let bars = vec![bar(0, 10.0, 9.0), bar(1, 10.5, 9.6), bar(2, 11.0, 10.0)];
        let feats = build_kline_combine_bundle(&bars).bar_features;
        assert_eq!(feats.len(), 3);
        assert!((feats[0].combine_high - 10.0).abs() < 1e-9);
        assert!((feats[0].combine_low - 9.0).abs() < 1e-9);
        assert!((feats[1].combine_high - 10.5).abs() < 1e-9);
        assert!((feats[1].combine_low - 9.6).abs() < 1e-9);
        assert!((feats[2].combine_high - 11.0).abs() < 1e-9);
        assert!((feats[2].combine_low - 10.0).abs() < 1e-9);
    }

    #[test]
    fn merge_included_bars() {
        let bars = vec![bar(0, 10.0, 9.0), bar(1, 9.5, 9.2), bar(2, 11.0, 10.0)];
        let bundle = build_kline_combine_bundle(&bars);
        assert!(!bundle.frames.is_empty());
        assert!(bundle.frames.iter().any(|f| f.count >= 2));
    }

    #[test]
    fn bi_confirm_on_fractal() {
        // 底-顶-底 结构触发分型确认
        let bars = vec![
            bar(0, 10.0, 9.0),
            bar(1, 9.0, 8.0),
            bar(2, 10.5, 9.5),
            bar(3, 9.5, 8.5),
            bar(4, 8.0, 7.0),
        ];
        let bundle = build_kline_combine_bundle(&bars);
        assert!(
            !bundle.bi_confirms.is_empty(),
            "应有笔确认柱: {:?}",
            bundle.frames
        );
        // 十字线特征应含 levels 快照
        assert!(bundle.bar_features.iter().all(|f| !f.levels.is_empty()));
    }

    #[test]
    fn bundle_levels_present() {
        let bars: Vec<KlineBar> = (0..40)
            .map(|i| {
                let up = (i / 4) % 2 == 0;
                let base = 10.0 + (i % 4) as f64 * 0.5;
                let h = if up { base + 1.0 } else { 16.0 - base };
                bar(i, h, h - 0.8)
            })
            .collect();
        let bundle = build_kline_combine_bundle(&bars);
        assert!(!bundle.levels.is_empty());
        assert_eq!(bundle.levels[0].level, 1);
        assert_eq!(bundle.frames.len(), bundle.levels[0].combine_frames.len());
    }

    #[test]
    fn bundle_per_level_export() {
        let bars: Vec<KlineBar> = (0..40)
            .map(|i| {
                let up = (i / 4) % 2 == 0;
                let base = 10.0 + (i % 4) as f64 * 0.5;
                let h = if up { base + 1.0 } else { 16.0 - base };
                bar(i, h, h - 0.8)
            })
            .collect();
        let bundle = build_kline_combine_bundle(&bars);
        assert_eq!(
            bundle.default_segment_policies.len(),
            bundle.levels.len()
        );
        assert_eq!(bundle.level_segments.len(), bundle.levels.len());
        assert_eq!(bundle.level_virtual_units.len(), bundle.levels.len());
        assert_eq!(
            bundle.default_bi_policy,
            bundle
                .default_segment_policies
                .first()
                .cloned()
                .unwrap_or_default()
        );
    }
}
