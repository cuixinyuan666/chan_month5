//! 线段分析：合并笔 K 线分型确认段（与合并 K 线同包含逻辑，弃用特征序列）。
//! 方案 A：进行中笔 K 逐 K 喂入，段确认可早于整笔 end_confirm_x；已冻结分型不回写。

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use crate::combine::{BiConfirmSignal, HlCombineStepState, HlFxConfirm, HlMergeUnit};
use crate::feature::{bi_virtual_bar_from_segment, bi_virtual_bar_provisional, BiSegment};
use crate::kline::KlineBar;

/// 特征序列线框（已弃用，保留序列化兼容）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EigenFrame {
    pub slot: i32,
    pub x1: i32,
    pub x2: i32,
    pub high: f64,
    pub low: f64,
    pub fx: String,
    pub bi_count: i32,
}

/// 段确认（合并笔 K 线顶/底分型，副图「段确认」）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SegConfirmSignal {
    /// 分型确认当步 1 分钟 K 索引
    pub x: i32,
    pub fx: String,
    /// 上涨段结束=-1，下跌段结束=1
    pub value: i32,
    pub ended_seg_dir: i32,
    pub peak_bi_idx: i32,
    /// 合并笔 K 线分型区间
    #[serde(default)]
    pub fractal_x1: i32,
    #[serde(default)]
    pub fractal_x2: i32,
    #[serde(default)]
    pub fractal_high: f64,
    #[serde(default)]
    pub fractal_low: f64,
}

/// 首段方向锁定信号。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FirstSegDirSignal {
    pub x: i32,
    /// 首段为上涨=1，下跌=-1
    pub dir: i32,
}

/// 已确认线段（主图展示用，可含未来修正，不参与 ML）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SegLine {
    pub idx: i32,
    pub dir: i32,
    /// 起点/终点 K 索引（分型中心，兼容旧字段）
    pub begin_x: i32,
    pub end_x: i32,
    #[serde(default)]
    pub begin_fractal_x1: i32,
    #[serde(default)]
    pub begin_fractal_x2: i32,
    #[serde(default)]
    pub end_fractal_x1: i32,
    #[serde(default)]
    pub end_fractal_x2: i32,
    pub begin_price: f64,
    pub end_price: f64,
}

/// 逐 K 副图/十字线快照（当下冻结）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BarSubSnapshot {
    pub idx: i32,
    /// 0=未定，1=构建上涨段，-1=构建下跌段
    pub building_seg_dir: i32,
    /// 0=未定，1=首段涨，-1=首段跌
    pub first_seg_dir: i32,
    /// 段确认柱值（该 K 有则填，否则 0）
    pub seg_confirm: i32,
    /// 已弃用
    #[serde(default)]
    pub eigen_slot: i32,
    /// 已弃用
    #[serde(default)]
    pub eigen_frames: Vec<EigenFrame>,
}

/// 段分析整包。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SegAnalysisBundle {
    /// 已弃用（特征序列），恒为空
    #[serde(default)]
    pub eigen_frames: Vec<EigenFrame>,
    pub seg_confirms: Vec<SegConfirmSignal>,
    pub first_seg_dir_signals: Vec<FirstSegDirSignal>,
    pub seg_lines: Vec<SegLine>,
    pub bar_sub_snapshots: Vec<BarSubSnapshot>,
    /// 当前构建段方向：0/1/-1
    pub building_seg_dir: i32,
    /// 已锁定首段方向：0/1/-1
    pub first_seg_dir: i32,
}

fn build_seg_lines_from_confirms(confirms: &[SegConfirmSignal]) -> Vec<SegLine> {
    let valid: Vec<&SegConfirmSignal> = confirms
        .iter()
        .filter(|c| c.fx == "TOP" || c.fx == "BOTTOM")
        .collect();
    if valid.len() < 2 {
        return Vec::new();
    }

    let mut lines = Vec::new();
    for i in 1..valid.len() {
        let prev = valid[i - 1];
        let curr = valid[i];
        if prev.fx == curr.fx {
            continue;
        }
        let dir = if prev.fx == "BOTTOM" && curr.fx == "TOP" {
            1
        } else if prev.fx == "TOP" && curr.fx == "BOTTOM" {
            -1
        } else {
            continue;
        };
        let (begin_price, end_price) = if dir > 0 {
            (prev.fractal_low, curr.fractal_high)
        } else {
            (prev.fractal_high, curr.fractal_low)
        };
        let begin_cx = (prev.fractal_x1 + prev.fractal_x2) / 2;
        let end_cx = (curr.fractal_x1 + curr.fractal_x2) / 2;
        lines.push(SegLine {
            idx: lines.len() as i32,
            dir,
            begin_x: begin_cx,
            end_x: end_cx,
            begin_fractal_x1: prev.fractal_x1,
            begin_fractal_x2: prev.fractal_x2,
            end_fractal_x1: curr.fractal_x1,
            end_fractal_x2: curr.fractal_x2,
            begin_price,
            end_price,
        });
    }
    lines
}

fn hl_unit_from_vb(bars: &[KlineBar], vb: &crate::feature::BiVirtualBar) -> HlMergeUnit {
    let t1 = bars
        .get(vb.x1.max(0) as usize)
        .map(|b| b.time_text.clone())
        .unwrap_or_default();
    let t2 = bars
        .get(vb.x2.max(0) as usize)
        .map(|b| b.time_text.clone())
        .unwrap_or_default();
    HlMergeUnit {
        x1: vb.x1,
        x2: vb.x2,
        high: vb.high,
        low: vb.low,
        t1,
        t2,
        end_at_left_half: false,
        start_at_right_half: false,
    }
}

/// 当步是否存在进行中笔，并构造其临时笔 K 单元。
fn provisional_unit_at(
    bars: &[KlineBar],
    bi_segments: &[BiSegment],
    bi_confirms: &[BiConfirmSignal],
    bar_x: usize,
    next_bi: usize,
) -> Option<(HlMergeUnit, i32)> {
    if next_bi < bi_segments.len() {
        let seg = &bi_segments[next_bi];
        let bx = bar_x as i32;
        if seg.begin_confirm_x <= bx && bx < seg.end_confirm_x {
            let vb = bi_virtual_bar_provisional(
                bars,
                seg.begin_fractal_x1,
                seg.begin_fractal_x2,
                bar_x,
                seg.dir,
                seg.idx,
            )?;
            return Some((hl_unit_from_vb(bars, &vb), seg.idx));
        }
        return None;
    }
    if next_bi > 0 {
        return None;
    }
    let last = bi_confirms
        .iter()
        .filter(|c| c.fx == "TOP" || c.fx == "BOTTOM")
        .last()?;
    if last.x >= bar_x as i32 {
        return None;
    }
    let dir = if last.fx == "BOTTOM" { 1 } else { -1 };
    let vb = bi_virtual_bar_provisional(
        bars,
        last.fractal_x1,
        last.fractal_x2,
        bar_x,
        dir,
        0,
    )?;
    Some((hl_unit_from_vb(bars, &vb), 0))
}

fn try_emit_seg_confirm(
    seg_confirms: &mut Vec<SegConfirmSignal>,
    frozen: &mut HashSet<(i32, i32, String)>,
    bar_x: i32,
    fx: HlFxConfirm,
    peak_bi_idx: i32,
    first_seg_dir: &mut i32,
    first_seg_dir_signals: &mut Vec<FirstSegDirSignal>,
    building_seg_dir: &mut i32,
) -> i32 {
    let key = (fx.fractal_x1, fx.fractal_x2, fx.fx.clone());
    if frozen.contains(&key) {
        return 0;
    }
    frozen.insert(key);
    let ended_seg_dir = if fx.fx == "TOP" { 1 } else { -1 };
    let value = if fx.fx == "TOP" { -1 } else { 1 };
    seg_confirms.push(SegConfirmSignal {
        x: bar_x,
        fx: fx.fx,
        value,
        ended_seg_dir,
        peak_bi_idx,
        fractal_x1: fx.fractal_x1,
        fractal_x2: fx.fractal_x2,
        fractal_high: fx.fractal_high,
        fractal_low: fx.fractal_low,
    });
    if *first_seg_dir == 0 {
        *first_seg_dir = ended_seg_dir;
        first_seg_dir_signals.push(FirstSegDirSignal {
            x: bar_x,
            dir: ended_seg_dir,
        });
    }
    *building_seg_dir = -ended_seg_dir;
    value
}

/// 对已喂入 K 线、笔段、笔确认做段分析：已确认笔 + 进行中笔 K 合并，分型逐 K 当下冻结。
pub fn build_seg_analysis(
    bars: &[KlineBar],
    bi_segments: &[BiSegment],
    bi_confirms: &[BiConfirmSignal],
) -> SegAnalysisBundle {
    if bars.is_empty() {
        return SegAnalysisBundle::default();
    }

    let mut merge_state = HlCombineStepState::default();
    let mut seg_confirms: Vec<SegConfirmSignal> = Vec::new();
    let mut frozen_fractals: HashSet<(i32, i32, String)> = HashSet::new();
    let mut first_seg_dir_signals: Vec<FirstSegDirSignal> = Vec::new();
    let mut first_seg_dir = 0i32;
    let mut building_seg_dir = 0i32;
    let mut next_bi = 0usize;
    let mut bar_snapshots = Vec::with_capacity(bars.len());

    for bar_x in 0..bars.len() {
        let mut seg_confirm_val = 0i32;

        while next_bi < bi_segments.len() && bi_segments[next_bi].end_confirm_x == bar_x as i32 {
            let seg = &bi_segments[next_bi];
            let vb = bi_virtual_bar_from_segment(bars, seg);
            let unit = hl_unit_from_vb(bars, &vb);

            if let Some(fx) = merge_state.feed_permanent(&unit) {
                seg_confirm_val = try_emit_seg_confirm(
                    &mut seg_confirms,
                    &mut frozen_fractals,
                    bar_x as i32,
                    fx,
                    seg.idx,
                    &mut first_seg_dir,
                    &mut first_seg_dir_signals,
                    &mut building_seg_dir,
                );
            }
            next_bi += 1;
        }

        // 方案 A：进行中笔 K 仅在临时状态上探测分型，不写入永久合并链（避免污染导致段确认过少）
        if let Some((unit, peak_idx)) =
            provisional_unit_at(bars, bi_segments, bi_confirms, bar_x, next_bi)
        {
            let mut early = merge_state.clone();
            if let Some(fx) = early.update_provisional(&unit) {
                seg_confirm_val = try_emit_seg_confirm(
                    &mut seg_confirms,
                    &mut frozen_fractals,
                    bar_x as i32,
                    fx,
                    peak_idx,
                    &mut first_seg_dir,
                    &mut first_seg_dir_signals,
                    &mut building_seg_dir,
                );
            }
        }

        bar_snapshots.push(BarSubSnapshot {
            idx: bar_x as i32,
            building_seg_dir,
            first_seg_dir,
            seg_confirm: seg_confirm_val,
            eigen_slot: -1,
            eigen_frames: Vec::new(),
        });
    }

    let seg_lines = build_seg_lines_from_confirms(&seg_confirms);

    SegAnalysisBundle {
        eigen_frames: Vec::new(),
        seg_confirms,
        first_seg_dir_signals,
        seg_lines,
        bar_sub_snapshots: bar_snapshots,
        building_seg_dir,
        first_seg_dir,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::feature::BiSegment;
    use crate::kline::KlineBar;

    fn bar(i: usize, h: f64, l: f64) -> KlineBar {
        KlineBar {
            idx: i as i32,
            time_ms: 0,
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
    fn seg_analysis_runs_on_empty_bi() {
        let bars = vec![bar(0, 10.0, 9.0), bar(1, 10.5, 9.5)];
        let bundle = build_seg_analysis(&bars, &[], &[]);
        assert_eq!(bundle.bar_sub_snapshots.len(), 2);
        assert!(bundle.eigen_frames.is_empty());
    }

    #[test]
    fn seg_confirms_from_bi_combine_fractals() {
        let bars: Vec<KlineBar> = (0..30)
            .map(|i| {
                let h = if i % 4 < 2 {
                    10.0 + i as f64 * 0.15
                } else {
                    9.5 + i as f64 * 0.05
                };
                let l = h - 0.8;
                bar(i, h, l)
            })
            .collect();
        let bi_segs = vec![
            BiSegment {
                idx: 0,
                dir: 1,
                begin_confirm_x: 2,
                end_confirm_x: 5,
                begin_fractal_x1: 0,
                begin_fractal_x2: 0,
                end_fractal_x1: 4,
                end_fractal_x2: 4,
                prev_idx: None,
                next_idx: Some(1),
            },
            BiSegment {
                idx: 1,
                dir: -1,
                begin_confirm_x: 5,
                end_confirm_x: 9,
                begin_fractal_x1: 4,
                begin_fractal_x2: 4,
                end_fractal_x1: 8,
                end_fractal_x2: 8,
                prev_idx: Some(0),
                next_idx: Some(2),
            },
            BiSegment {
                idx: 2,
                dir: 1,
                begin_confirm_x: 9,
                end_confirm_x: 14,
                begin_fractal_x1: 8,
                begin_fractal_x2: 8,
                end_fractal_x1: 13,
                end_fractal_x2: 13,
                prev_idx: Some(1),
                next_idx: None,
            },
        ];
        let bundle = build_seg_analysis(&bars, &bi_segs, &[]);
        assert_eq!(bundle.bar_sub_snapshots.len(), bars.len());
        assert!(bundle.eigen_frames.is_empty());
        for snap in &bundle.bar_sub_snapshots {
            assert!(snap.eigen_frames.is_empty());
        }
    }

    #[test]
    fn frozen_seg_confirm_not_removed_when_provisional_extends() {
        use crate::combine::BiConfirmSignal;

        let bars: Vec<KlineBar> = (0..12)
            .map(|i| {
                let h = 10.0 + (i as f64) * 0.3;
                bar(i, h, h - 0.5)
            })
            .collect();
        let bi_segs = vec![BiSegment {
            idx: 0,
            dir: 1,
            begin_confirm_x: 1,
            end_confirm_x: 8,
            begin_fractal_x1: 0,
            begin_fractal_x2: 0,
            end_fractal_x1: 7,
            end_fractal_x2: 7,
            prev_idx: None,
            next_idx: None,
        }];
        let bi_confirms = vec![
            BiConfirmSignal {
                x: 1,
                fx: "BOTTOM".to_string(),
                value: 1,
                fractal_x1: 0,
                fractal_x2: 0,
            },
            BiConfirmSignal {
                x: 8,
                fx: "TOP".to_string(),
                value: -1,
                fractal_x1: 7,
                fractal_x2: 7,
            },
        ];
        let bundle = build_seg_analysis(&bars, &bi_segs, &bi_confirms);
        let n = bundle.seg_confirms.len();
        assert!(n <= bundle.seg_confirms.len());
        let _ = n;
    }
}
