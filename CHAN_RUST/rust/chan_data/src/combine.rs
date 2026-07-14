//! K0合并 bundle：由 Kn 流水线（pipeline）驱动，本文件只做旧字段兼容映射。
//! 命名：K0=原始K，K1=K0连线(笔)，K2=K1连线(线段)（旧「1段/2段」）；字段名 k0_*/k1_* 对应各 K 层。
//! 合并/分型内核唯一实现见 engine.rs；递归 N 段见 pipeline.rs。

use serde::{Deserialize, Serialize};

use crate::engine::{CombineEngine, MergeUnit, TruncReplayState};
use crate::feature::{
    build_k1_bar_views, enrich_fractal_peak_dist, weekday_from_bar, BarCrosshairFeature,
    K0Line, K1Bar,
};
use crate::kline::KlineBar;
use crate::pipeline::{
    run_pipeline, LevelBundleOut, LevelSegment, LevelUnitBar, PipelineOptions, PipelineResult,
};
use crate::seg_eigen::{
    BarSubSnapshot, FirstSegDirSignal, K1AnalysisBundle, K1ConfirmSignal, K1Line,
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
    /// 末端落在 x2 分钟 K 左半侧（右边界=该 K 中轴；K0合并框与 K1 bar 半侧衔接一致）
    #[serde(default)]
    pub end_at_left_half: bool,
    /// 起始落在 x1 分钟 K 右半侧（左边界=该 K 中轴）
    #[serde(default)]
    pub start_at_right_half: bool,
}

/// K0合并分型确认柱：合并框顶/底分型确认当步 K（连接即 K0连线，逐K当下冻结）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct K0ConfirmSignal {
    /// 分型确认当步 K 线索引（第三元素进入当步）
    pub x: i32,
    pub fx: String,
    /// 向上K0连线=1，向下K0连线=-1
    pub value: i32,
    pub fractal_x1: i32,
    pub fractal_x2: i32,
    /// 截断确认（上升/下降截断触发，非常规三元素路径）
    #[serde(default)]
    pub truncated: bool,
}

/// 合并线框 + K0连线确认 + 十字线特征 + K0连线链 + Kn 流水线（一次遍历产出，逐K当下）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KlineCombineBundle {
    pub frames: Vec<KlineCombineFrame>,
    pub k0_confirms: Vec<K0ConfirmSignal>,
    /// 每根 K 十字线特征（星期 w1..w7、K0合并序、各层 Kn 快照）
    #[serde(default)]
    pub bar_features: Vec<BarCrosshairFeature>,
    /// K1（K0连线）链：锚定配对，链条无缝
    #[serde(default)]
    pub k0_lines: Vec<K0Line>,
    /// K2（K1连线）兼容包（由流水线 Level2 映射）
    #[serde(default)]
    pub k1_analysis: K1AnalysisBundle,
    /// K0连线确认后包装 K1 bar（主图展示，含末步进行中 K0连线）
    #[serde(default)]
    pub k1_bars: Vec<K1Bar>,
    /// K1合并线框（副图「K1合并」）
    #[serde(default)]
    pub k1_combine_frames: Vec<KlineCombineFrame>,
    /// 默认 K0层策略：pending / retained / purged（= default_segment_policies[0] 兼容别名）
    #[serde(default = "default_k0_policy_pending")]
    pub default_k0_policy: String,
    /// 全层首段策略（levels[0]=K1，levels[1]=K2，…）
    #[serde(default)]
    pub default_segment_policies: Vec<String>,
    /// 全层冻结段链（按层）
    #[serde(default)]
    pub level_segments: Vec<Vec<K0Line>>,
    /// 全层展示用虚拟段 K（pending + 冻结 + 进行中）
    #[serde(default)]
    pub level_virtual_units: Vec<Vec<K1Bar>>,
    /// Kn 流水线全量输出（1=K1/K0连线，2=K2/K1连线，…穷尽）
    #[serde(default)]
    pub levels: Vec<LevelBundleOut>,
}

fn default_k0_policy_pending() -> String {
    "pending".to_string()
}

impl KlineCombineBundle {
    fn empty() -> Self {
        Self {
            frames: Vec::new(),
            k0_confirms: Vec::new(),
            bar_features: Vec::new(),
            k0_lines: Vec::new(),
            k1_analysis: K1AnalysisBundle::default(),
            k1_bars: Vec::new(),
            k1_combine_frames: Vec::new(),
            default_k0_policy: default_k0_policy_pending(),
            default_segment_policies: Vec::new(),
            level_segments: Vec::new(),
            level_virtual_units: Vec::new(),
            levels: Vec::new(),
        }
    }
}

/// LevelSegment → K0Line（导出映射）
fn level_seg_to_k0_line(s: &LevelSegment) -> K0Line {
    K0Line {
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

fn link_k0_lines(chain: &mut [K0Line]) {
    for i in 0..chain.len().saturating_sub(1) {
        chain[i].next_idx = Some(chain[i + 1].idx);
        chain[i + 1].prev_idx = Some(chain[i].idx);
    }
}

fn unit_to_virtual_bar(u: &LevelUnitBar) -> K1Bar {
    K1Bar {
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
fn build_level_virtual_units(level: &LevelBundleOut) -> Vec<K1Bar> {
    let mut v: Vec<K1Bar> = level
        .segments
        .iter()
        .map(|s| segment_to_virtual_bar(s))
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
fn map_level_segments(level: &LevelBundleOut) -> Vec<K0Line> {
    let mut segs: Vec<K0Line> = level
        .segments
        .iter()
        .map(level_seg_to_k0_line)
        .collect();
    link_k0_lines(&mut segs);
    segs
}

/// N 段 → 虚拟段 K 线（OHLC 冻结时已算好）
fn segment_to_virtual_bar(seg: &LevelSegment) -> K1Bar {
    K1Bar {
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

/// K1 bar 序列 → K1合并线框（副图「K1合并」，末态展示口径）。
/// 默认开启截断监察+有效性校验，与流水线 L2 同构。
pub fn build_k1_combine_frames(bars: &[KlineBar], k1_bars: &[K1Bar]) -> Vec<KlineCombineFrame> {
    build_k1_combine_frames_with(bars, k1_bars, true, true)
}

/// K1 bar 序列 → K1合并线框（可关截断/校验，对照排查用）。
/// 调用方应只传入**已确认冻结**的 K1 bar（与 L2 永久 feed 同构）；进行中 K0连线不参与截断合并。
/// 多根包含合并：外侧框按分钟 K 中轴；仅一根 K1 bar（count=1）保留半侧锚定。
pub fn build_k1_combine_frames_with(
    bars: &[KlineBar],
    k1_bars: &[K1Bar],
    truncation_check: bool,
    validity_check: bool,
) -> Vec<KlineCombineFrame> {
    if k1_bars.is_empty() {
        return Vec::new();
    }
    let views = build_k1_bar_views(k1_bars);
    let mut engine = CombineEngine::new();
    // 截断状态机与 LevelState 同构：保证副图框与 L2 合并链一致
    let mut trunc = TruncReplayState::new(truncation_check, validity_check);
    for (i, v) in views.iter().enumerate() {
        let mu = MergeUnit {
            uid: i as i64,
            x1: v.view_x1,
            x2: v.view_x2,
            high: v.bar.high,
            low: v.bar.low,
        };
        let guard = trunc.guard();
        if let Some(ev) = engine.feed_guarded(&mu, guard.as_ref()) {
            trunc.on_event(&ev);
        }
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
                // 半侧标志仅 count=1 单根 K1 bar 框保留；多根合并框走中轴口径
                end_at_left_half: single && vu.end_at_left_half,
                start_at_right_half: single && vu.start_at_right_half,
            }
        })
        .collect()
}

/// K1连线兼容映射：Level2 → K1AnalysisBundle
fn map_k1_analysis(pr: &PipelineResult) -> K1AnalysisBundle {
    let Some(l2) = pr.levels.get(1) else {
        return K1AnalysisBundle {
            bar_sub_snapshots: pr
                .bar_seg_rows
                .iter()
                .enumerate()
                .map(|(i, r)| BarSubSnapshot {
                    idx: i as i32,
                    building_seg_dir: r.building_dir,
                    first_seg_dir: r.first_dir,
                    k1_confirm: r.confirm,
                    eigen_slot: -1,
                    eigen_frames: Vec::new(),
                })
                .collect(),
            ..K1AnalysisBundle::default()
        };
    };
    let k1_confirms = l2
        .confirms
        .iter()
        .map(|c| K1ConfirmSignal {
            x: c.x,
            fx: c.fx.clone(),
            value: c.value,
            ended_seg_dir: -c.value,
            peak_k1_idx: c.trigger_uid as i32,
            fractal_x1: c.fractal_x1,
            fractal_x2: c.fractal_x2,
            fractal_high: c.fractal_high,
            fractal_low: c.fractal_low,
            truncated: c.truncated,
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
    let k1_lines = l2
        .segments
        .iter()
        .map(|s| K1Line {
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
            k1_confirm: r.confirm,
            eigen_slot: -1,
            eigen_frames: Vec::new(),
        })
        .collect();
    K1AnalysisBundle {
        eigen_frames: Vec::new(),
        k1_confirms,
        first_seg_dir_signals,
        k1_lines,
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

    // K0连线分型确认（全量：含被丢弃的同向/校验失败分型，与旧口径一致）
    let k0_confirms: Vec<K0ConfirmSignal> = l1
        .confirms
        .iter()
        .map(|c| K0ConfirmSignal {
            x: c.x,
            fx: c.fx.clone(),
            value: c.value,
            fractal_x1: c.fractal_x1,
            fractal_x2: c.fractal_x2,
            truncated: c.truncated,
        })
        .collect();

    // 全层段链 / 策略 / 虚拟段 K
    let default_segment_policies: Vec<String> = pr
        .levels
        .iter()
        .map(|lv| lv.segment_policy.clone())
        .collect();
    let level_segments: Vec<Vec<K0Line>> =
        pr.levels.iter().map(map_level_segments).collect();
    let level_virtual_units: Vec<Vec<K1Bar>> = pr
        .levels
        .iter()
        .map(build_level_virtual_units)
        .collect();

    let k0_lines = level_segments
        .first()
        .cloned()
        .unwrap_or_default();
    let default_k0_policy = default_segment_policies
        .first()
        .cloned()
        .unwrap_or_else(|| "pending".to_string());
    let k1_bars = level_virtual_units
        .first()
        .cloned()
        .unwrap_or_default();

    // K1合并框：只喂已冻结 K0连线（与 L2 feed 输入同构）；进行中/pending 不参与截断合并
    let k1_bars_for_combine: Vec<K1Bar> = pr
        .levels
        .first()
        .map(|l| l.segments.iter().map(segment_to_virtual_bar).collect())
        .unwrap_or_default();
    let k1_combine_frames = build_k1_combine_frames_with(
        bars,
        &k1_bars_for_combine,
        opt.truncation_check,
        opt.validity_check,
    );

    // 十字线/ML 特征：K线合并快照 + 各层 N 段快照（固定 purged：首 K0连线确认前不填 k1_*）
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
                k1_idx: l1s.and_then(|s| s.unit_idx.map(|v| v as i32)),
                k1_merge_inner_seq: l1s.map(|s| s.merge_inner_seq).unwrap_or(0),
                k1_merge_count: l1s.map(|s| s.merge_count).unwrap_or(1),
                k1_open: l1s.map(|s| s.unit_open).unwrap_or(0.0),
                k1_high: l1s.map(|s| s.unit_high).unwrap_or(0.0),
                k1_low: l1s.map(|s| s.unit_low).unwrap_or(0.0),
                k1_close: l1s.map(|s| s.unit_close).unwrap_or(0.0),
                k1_volume: l1s.map(|s| s.unit_volume).unwrap_or(0.0),
                k1_combine_high: l1s.map(|s| s.combine_high).unwrap_or(0.0),
                k1_combine_low: l1s.map(|s| s.combine_low).unwrap_or(0.0),
                k1_combine_fx: l1s
                    .map(|s| s.combine_fx.clone())
                    .unwrap_or_else(|| "UNKNOWN".to_string()),
                levels: snaps.clone(),
            }
        })
        .collect();
    enrich_fractal_peak_dist(bars, &mut bar_features, &k0_confirms);

    let k1_analysis = map_k1_analysis(&pr);

    KlineCombineBundle {
        frames: l1.combine_frames.clone(),
        k0_confirms,
        bar_features,
        k0_lines,
        k1_analysis,
        k1_bars,
        k1_combine_frames,
        default_k0_policy,
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
    fn k0_confirm_on_fractal() {
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
            !bundle.k0_confirms.is_empty(),
            "应有K0连线确认柱: {:?}",
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
            bundle.default_k0_policy,
            bundle
                .default_segment_policies
                .first()
                .cloned()
                .unwrap_or_default()
        );
    }

    fn k1_bar(i: i32, h: f64, l: f64) -> K1Bar {
        K1Bar {
            idx: i,
            dir: 1,
            x1: i,
            x2: i,
            open: l,
            high: h,
            low: l,
            close: h,
            confirm_x: i,
        }
    }

    /// K1合并副图：底分型后第4根暴力反转应截断断开（与 L2/engine 同构）
    #[test]
    fn k1_combine_frames_up_truncation_splits() {
        let bars: Vec<_> = (0..5).map(|i| bar(i, 12.0, 7.0)).collect();
        let k1_bars = vec![
            k1_bar(0, 10.0, 9.0),
            k1_bar(1, 9.0, 8.0),   // 底分型中组
            k1_bar(2, 10.5, 9.5),  // 底确认=左框
            k1_bar(3, 11.0, 7.5),  // 上升截断
            k1_bar(4, 10.2, 9.2),
        ];
        let frames = build_k1_combine_frames_with(&bars, &k1_bars, true, true);
        assert!(
            frames.iter().any(|f| f.x1 == 3),
            "截断K1 bar应强制断开成新框: {:?}",
            frames
        );
        // 左框高低不被截断K改写：含 x 覆盖到 2 的框高应为 10.5
        let left = frames
            .iter()
            .find(|f| f.x1 == 2 && f.x2 == 2)
            .expect("应有左框=确认元素独立组");
        assert!((left.high - 10.5).abs() < 1e-9);
        assert!((left.low - 9.5).abs() < 1e-9);
        assert_eq!(left.fx, "TOP");
    }

    /// 关闭截断 → 旧行为：暴力反转 K1 bar 被吸收
    #[test]
    fn k1_combine_frames_truncation_off_absorbs() {
        let bars: Vec<_> = (0..5).map(|i| bar(i, 12.0, 7.0)).collect();
        let k1_bars = vec![
            k1_bar(0, 10.0, 9.0),
            k1_bar(1, 9.0, 8.0),
            k1_bar(2, 10.5, 9.5),
            k1_bar(3, 11.0, 7.5),
            k1_bar(4, 10.2, 9.2),
        ];
        let frames = build_k1_combine_frames_with(&bars, &k1_bars, false, true);
        assert!(frames.iter().all(|f| f.x1 != 3));
        let absorbed = frames.iter().find(|f| f.x1 <= 2 && f.x2 >= 3);
        assert!(absorbed.is_some());
        assert!((absorbed.unwrap().high - 11.0).abs() < 1e-9);
    }

    /// all_confirm：K1合并框只认已冻结 K0连线，与带进行中 K0连线的合并结果可分叉时以冻结为准
    #[test]
    fn k1_combine_bundle_matches_frozen_segments_only() {
        let bars: Vec<KlineBar> = (0..80)
            .map(|i| {
                let up = (i / 4) % 2 == 0;
                let base = 10.0 + (i % 4) as f64 * 0.5;
                let h = if up { base + 1.0 } else { 16.0 - base };
                bar(i, h, h - 0.8)
            })
            .collect();
        for trunc in [false, true] {
            let opt = PipelineOptions {
                truncation_check: trunc,
                ..PipelineOptions::default()
            };
            let bundle = build_kline_combine_bundle_with(&bars, &opt);
            let frozen: Vec<K1Bar> = bundle
                .levels
                .first()
                .map(|l| l.segments.iter().map(segment_to_virtual_bar).collect())
                .unwrap_or_default();
            let expect = build_k1_combine_frames_with(
                &bars,
                &frozen,
                trunc,
                true,
            );
            assert_eq!(
                bundle.k1_combine_frames.len(),
                expect.len(),
                "trunc={trunc} 框数量应与仅冻结K0连线一致"
            );
            for (i, (a, b)) in bundle
                .k1_combine_frames
                .iter()
                .zip(expect.iter())
                .enumerate()
            {
                assert_eq!((a.x1, a.x2, &a.fx), (b.x1, b.x2, &b.fx), "trunc={trunc} frame {i}");
                assert!((a.high - b.high).abs() < 1e-9);
                assert!((a.low - b.low).abs() < 1e-9);
            }
            // 进行中 K0连线可仍出现在 k1_bars，但不进合并框输入
            if bundle.levels.first().and_then(|l| l.active_unit.as_ref()).is_some() {
                assert!(
                    bundle.k1_bars.len() > frozen.len(),
                    "trunc={trunc} 展示用虚拟K1 bar应含进行中"
                );
            }
        }
    }
}
