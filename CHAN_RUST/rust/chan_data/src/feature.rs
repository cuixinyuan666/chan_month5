//! 十字辅助线 / ML 训练特征（逐K当下，禁止未来函数）。

use chrono::{Datelike, TimeZone, Utc};
use serde::{Deserialize, Serialize};

use crate::combine::{BiConfirmSignal, HlCombineStepState, HlMergeUnit, KlineCombineFrame};
use crate::kline::KlineBar;

const WEEKDAY_CN: [&str; 7] = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

/// 单根 K 十字线基础特征（星期 + 合并内序号 + 逐K合并态）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BarCrosshairFeature {
    pub idx: i32,
    /// 当前 K 所属星期（周一…周日）
    pub weekday: String,
    /// 合并 K 线内部排序：单根=1，同区间后续依次 2、3…
    pub merge_inner_seq: i32,
    /// 截至当步所在合并区间已合并根数（逐K当下，非末态）
    #[serde(default)]
    pub merge_count: i32,
    /// 截至当步分型：未确认=UNKNOWN（逐K当下）
    #[serde(default = "default_unknown")]
    pub combine_fx: String,
    /// 截至当步所在合并区间最高价（逐K当下，非末态回写）
    #[serde(default)]
    pub combine_high: f64,
    /// 截至当步所在合并区间最低价（逐K当下，非末态回写）
    #[serde(default)]
    pub combine_low: f64,
    /// 距最近冻结笔确认分型极点间隔根数（不含极点 K）；首笔确认前=0
    #[serde(default)]
    pub fractal_peak_dist: i32,
    /// 当步所属笔 K 序号；首笔确认前=None
    #[serde(default)]
    pub bi_idx: Option<i32>,
    /// 当步笔 K 在合并笔 K 线框内序号（1 起）
    #[serde(default = "default_one")]
    pub bi_merge_inner_seq: i32,
    /// 当步所在合并笔 K 线框已含笔 K 根数（逐K当下）
    #[serde(default = "default_one")]
    pub bi_merge_count: i32,
    #[serde(default)]
    pub bi_open: f64,
    #[serde(default)]
    pub bi_high: f64,
    #[serde(default)]
    pub bi_low: f64,
    #[serde(default)]
    pub bi_close: f64,
    #[serde(default)]
    pub bi_volume: f64,
    /// 当步合并笔 K 线区间最高价（逐K当下）
    #[serde(default)]
    pub bi_combine_high: f64,
    /// 当步合并笔 K 线区间最低价（逐K当下）
    #[serde(default)]
    pub bi_combine_low: f64,
    /// 当步合并笔 K 分型：未确认=UNKNOWN
    #[serde(default = "default_unknown")]
    pub bi_combine_fx: String,
}

fn default_one() -> i32 {
    1
}

fn default_unknown() -> String {
    "UNKNOWN".to_string()
}

/// 笔确认后包装成的笔 K 线（区间内最高/最低 + 起止开收，主图展示）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BiVirtualBar {
    pub idx: i32,
    /// 向上笔=1，向下笔=-1
    pub dir: i32,
    pub x1: i32,
    pub x2: i32,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    /// 笔结束确认 K 索引
    pub confirm_x: i32,
}

/// 笔 K 线展示视图：计算层区间的 x 裁剪，仅用于绘制。
/// 相邻笔在共享分钟 K 上：上一笔末端占左半侧，下一笔起始占右半侧，于中轴无缝衔接。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BiVirtualBarView {
    #[serde(flatten)]
    pub bar: BiVirtualBar,
    pub view_x1: i32,
    pub view_x2: i32,
    /// 末端落在 view_x2 对应分钟 K 左半侧（右边界=该 K 中轴）
    #[serde(default)]
    pub end_at_left_half: bool,
    /// 起始落在 view_x1 对应分钟 K 右半侧（左边界=该 K 中轴）
    #[serde(default)]
    pub start_at_right_half: bool,
}

/// 笔段：相邻异向分型确认配对相连，带前后关联索引。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BiSegment {
    pub idx: i32,
    /// 向上笔=1，向下笔=-1
    pub dir: i32,
    pub begin_confirm_x: i32,
    pub end_confirm_x: i32,
    pub begin_fractal_x1: i32,
    pub begin_fractal_x2: i32,
    pub end_fractal_x1: i32,
    pub end_fractal_x2: i32,
    pub prev_idx: Option<i32>,
    pub next_idx: Option<i32>,
}

/// 由 time_ms 推导中文星期（无未来函数，仅用当前 K 时间）。
pub fn weekday_from_bar(bar: &KlineBar) -> String {
    if bar.time_ms > 0 {
        if let Some(dt) = Utc.timestamp_millis_opt(bar.time_ms).single() {
            let w = dt.weekday().num_days_from_sunday() as usize;
            if w < WEEKDAY_CN.len() {
                return WEEKDAY_CN[w].to_string();
            }
        }
    }
    weekday_from_time_text(&bar.time_text)
}

fn weekday_from_time_text(text: &str) -> String {
    let date_part = text.trim().get(..10).unwrap_or("");
    if date_part.len() < 10 {
        return "-".to_string();
    }
    let parts: Vec<&str> = date_part.split('/').collect();
    if parts.len() != 3 {
        return "-".to_string();
    }
    let y: i32 = parts[0].parse().unwrap_or(0);
    let m: u32 = parts[1].parse().unwrap_or(0);
    let d: u32 = parts[2].parse().unwrap_or(0);
    if y == 0 || m == 0 || d == 0 {
        return "-".to_string();
    }
    if let Some(dt) = chrono::NaiveDate::from_ymd_opt(y, m, d) {
        let w = dt.weekday().num_days_from_sunday() as usize;
        if w < WEEKDAY_CN.len() {
            return WEEKDAY_CN[w].to_string();
        }
    }
    "-".to_string()
}

/// 合并线框 → 每根原始 K 的合并内序号（1 起）。
pub fn merge_inner_seq_map(frames: &[KlineCombineFrame]) -> Vec<i32> {
    let mut max_idx = 0usize;
    for f in frames {
        max_idx = max_idx.max(f.x2 as usize);
    }
    let mut seq = vec![1i32; max_idx + 1];
    for f in frames {
        let mut inner = 1i32;
        for x in f.x1..=f.x2 {
            let ui = x as usize;
            if ui < seq.len() {
                seq[ui] = inner;
                inner += 1;
            }
        }
    }
    seq
}

// 逐步十字线特征见 combine::build_bar_crosshair_features_stepwise

/// 分型合并框内极点 K 索引：TOP 取首个 high 极值，BOTTOM 取首个 low 极值。
pub fn fractal_extreme_bar_idx(bars: &[KlineBar], conf: &BiConfirmSignal) -> Option<i32> {
    let x1 = conf.fractal_x1.max(0) as usize;
    let x2 = conf.fractal_x2.max(0) as usize;
    if bars.is_empty() || x1 > x2 || x2 >= bars.len() {
        return None;
    }
    match conf.fx.as_str() {
        "TOP" => {
            let mut peak = f64::NEG_INFINITY;
            for j in x1..=x2 {
                peak = peak.max(bars[j].high);
            }
            for j in x1..=x2 {
                if (bars[j].high - peak).abs() < 1e-12 {
                    return Some(j as i32);
                }
            }
        }
        "BOTTOM" => {
            let mut trough = f64::INFINITY;
            for j in x1..=x2 {
                trough = trough.min(bars[j].low);
            }
            for j in x1..=x2 {
                if (bars[j].low - trough).abs() < 1e-12 {
                    return Some(j as i32);
                }
            }
        }
        _ => {}
    }
    None
}

/// 逐 K 填充 K线分型极点距：基准=最近冻结笔确认分型框；确认当步起算；不含极点 K。
pub fn enrich_fractal_peak_dist(
    bars: &[KlineBar],
    features: &mut [BarCrosshairFeature],
    bi_confirms: &[BiConfirmSignal],
) {
    if features.is_empty() {
        return;
    }
    let mut confirm_ptr = 0usize;
    let mut extreme_idx: Option<i32> = None;

    for i in 0..features.len() {
        while confirm_ptr < bi_confirms.len() && bi_confirms[confirm_ptr].x as usize <= i {
            extreme_idx = fractal_extreme_bar_idx(bars, &bi_confirms[confirm_ptr]);
            confirm_ptr += 1;
        }
        features[i].fractal_peak_dist = match extreme_idx {
            Some(ext) => (i as i32) - ext,
            None => 0,
        };
    }
}

fn hl_unit_from_vb(bars: &[KlineBar], vb: &BiVirtualBar) -> HlMergeUnit {
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

fn bi_volume(bars: &[KlineBar], x1: usize, x2: usize) -> f64 {
    if bars.is_empty() {
        return 0.0;
    }
    let a = x1.min(x2).min(bars.len() - 1);
    let b = x1.max(x2).min(bars.len() - 1);
    bars[a..=b].iter().map(|b| b.volume).sum()
}

/// 当步进行中笔 K（方案 A，与段分析同源）。
fn provisional_bi_at(
    bars: &[KlineBar],
    bi_segments: &[BiSegment],
    bi_confirms: &[BiConfirmSignal],
    bar_x: usize,
    next_bi: usize,
) -> Option<BiVirtualBar> {
    if next_bi < bi_segments.len() {
        let seg = &bi_segments[next_bi];
        let bx = bar_x as i32;
        if seg.begin_confirm_x <= bx && bx < seg.end_confirm_x {
            return bi_virtual_bar_provisional(
                bars,
                seg.begin_fractal_x1,
                seg.begin_fractal_x2,
                bar_x,
                seg.dir,
                seg.idx,
            );
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
    bi_virtual_bar_provisional(
        bars,
        last.fractal_x1,
        last.fractal_x2,
        bar_x,
        dir,
        0,
    )
}

/// 当步已确认笔 K：仅 end_confirm_x 已到达的笔段，且分钟 K 落在笔区间内。
fn confirmed_bi_at(bars: &[KlineBar], bi_segments: &[BiSegment], bar_x: usize) -> Option<BiVirtualBar> {
    let bx = bar_x as i32;
    for seg in bi_segments.iter().rev() {
        if seg.end_confirm_x > bx {
            continue;
        }
        let vb = bi_virtual_bar_from_segment(bars, seg);
        if vb.x1 <= bx && bx <= vb.x2 {
            return Some(vb);
        }
    }
    None
}

fn active_bi_at(
    bars: &[KlineBar],
    bi_segments: &[BiSegment],
    bi_confirms: &[BiConfirmSignal],
    bar_x: usize,
    next_bi: usize,
) -> Option<BiVirtualBar> {
    provisional_bi_at(bars, bi_segments, bi_confirms, bar_x, next_bi)
        .or_else(|| confirmed_bi_at(bars, bi_segments, bar_x))
}

/// 逐 K 填充笔 K 十字线字段（与 1 分钟 K 特征同向量，逐K当下冻结）。
pub fn enrich_bi_crosshair_fields(
    bars: &[KlineBar],
    features: &mut [BarCrosshairFeature],
    bi_segments: &[BiSegment],
    bi_confirms: &[BiConfirmSignal],
) {
    if features.is_empty() || bars.is_empty() {
        return;
    }
    let mut merge_state = HlCombineStepState::default();
    let mut next_bi = 0usize;
    let limit = bars.len().min(features.len());

    for bar_x in 0..limit {
        while next_bi < bi_segments.len() && bi_segments[next_bi].end_confirm_x == bar_x as i32 {
            let seg = &bi_segments[next_bi];
            let vb = bi_virtual_bar_from_segment(bars, seg);
            let unit = hl_unit_from_vb(bars, &vb);
            merge_state.feed_permanent(&unit, seg.idx);
            next_bi += 1;
        }

        let active = active_bi_at(bars, bi_segments, bi_confirms, bar_x, next_bi);
        let mut snap_state = merge_state.clone();
        if let Some(vb) = provisional_bi_at(bars, bi_segments, bi_confirms, bar_x, next_bi) {
            let unit = hl_unit_from_vb(bars, &vb);
            snap_state.update_provisional(&unit, vb.idx);
        }

        let feat = &mut features[bar_x];
        if let Some(vb) = active {
            let snap = snap_state.crosshair_snapshot(vb.idx);
            feat.bi_idx = Some(vb.idx);
            feat.bi_merge_inner_seq = snap.bi_merge_inner_seq;
            feat.bi_merge_count = snap.bi_merge_count;
            feat.bi_open = vb.open;
            feat.bi_high = vb.high;
            feat.bi_low = vb.low;
            feat.bi_close = vb.close;
            feat.bi_volume = bi_volume(bars, vb.x1.max(0) as usize, vb.x2.max(0) as usize);
            feat.bi_combine_high = snap.bi_combine_high;
            feat.bi_combine_low = snap.bi_combine_low;
            feat.bi_combine_fx = snap.bi_combine_fx;
        } else {
            feat.bi_idx = None;
            feat.bi_merge_inner_seq = 1;
            feat.bi_merge_count = 1;
            feat.bi_open = 0.0;
            feat.bi_high = 0.0;
            feat.bi_low = 0.0;
            feat.bi_close = 0.0;
            feat.bi_volume = 0.0;
            feat.bi_combine_high = 0.0;
            feat.bi_combine_low = 0.0;
            feat.bi_combine_fx = default_unknown();
        }
    }
}

/// 分型确认信号 → 笔段链（异向分型配对，prev/next 连续关联）。
pub fn build_bi_segments(confirms: &[BiConfirmSignal]) -> Vec<BiSegment> {
    let valid: Vec<&BiConfirmSignal> = confirms
        .iter()
        .filter(|c| c.fx == "TOP" || c.fx == "BOTTOM")
        .collect();
    if valid.len() < 2 {
        return Vec::new();
    }

    let mut segments = Vec::new();
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
        let idx = segments.len() as i32;
        segments.push(BiSegment {
            idx,
            dir,
            begin_confirm_x: prev.x,
            end_confirm_x: curr.x,
            begin_fractal_x1: prev.fractal_x1,
            begin_fractal_x2: prev.fractal_x2,
            end_fractal_x1: curr.fractal_x1,
            end_fractal_x2: curr.fractal_x2,
            prev_idx: if idx > 0 { Some(idx - 1) } else { None },
            next_idx: None,
        });
    }
    for i in 0..segments.len().saturating_sub(1) {
        segments[i].next_idx = Some(segments[i + 1].idx);
    }
    segments
}

fn bar_hl_range(bars: &[KlineBar], x1: usize, x2: usize) -> (f64, f64, f64, f64) {
    if bars.is_empty() {
        return (0.0, 0.0, 0.0, 0.0);
    }
    let a = x1.min(x2).min(bars.len() - 1);
    let b = x1.max(x2).min(bars.len() - 1);
    let mut hi = f64::NEG_INFINITY;
    let mut lo = f64::INFINITY;
    for i in a..=b {
        hi = hi.max(bars[i].high);
        lo = lo.min(bars[i].low);
    }
    let open = bars[a].open;
    let close = bars[b].close;
    (open, hi, lo, close)
}

/// 进行中笔 K 线：起点分型至当步 K（方案 A，仅段分析喂入用）。
pub fn bi_virtual_bar_provisional(
    bars: &[KlineBar],
    begin_fractal_x1: i32,
    begin_fractal_x2: i32,
    end_bar_x: usize,
    dir: i32,
    seg_idx: i32,
) -> Option<BiVirtualBar> {
    if bars.is_empty() {
        return None;
    }
    let x1 = begin_fractal_x1
        .min(begin_fractal_x2)
        .max(0) as usize;
    let x2 = end_bar_x.min(bars.len() - 1);
    if x2 < x1 {
        return None;
    }
    let (open, high, low, close) = bar_hl_range(bars, x1, x2);
    Some(BiVirtualBar {
        idx: seg_idx,
        dir,
        x1: x1 as i32,
        x2: x2 as i32,
        open,
        high,
        low,
        close,
        confirm_x: x2 as i32,
    })
}

/// 每笔确认后：用该笔覆盖区间的最高/最低价与起止开收包装成一根 K 线。
pub fn bi_virtual_bar_from_segment(bars: &[KlineBar], seg: &BiSegment) -> BiVirtualBar {
    let x1 = seg
        .begin_fractal_x1
        .min(seg.begin_fractal_x2)
        .max(0) as usize;
    let x2 = seg
        .end_fractal_x1
        .max(seg.end_fractal_x2)
        .max(0) as usize;
    let (open, high, low, close) = bar_hl_range(bars, x1, x2);
    BiVirtualBar {
        idx: seg.idx,
        dir: seg.dir,
        x1: x1 as i32,
        x2: x2 as i32,
        open,
        high,
        low,
        close,
        confirm_x: seg.end_confirm_x,
    }
}

/// 每笔确认后：用该笔覆盖区间的最高/最低价与起止开收包装成一根 K 线。
pub fn build_bi_virtual_bars(bars: &[KlineBar], segments: &[BiSegment]) -> Vec<BiVirtualBar> {
    if bars.is_empty() || segments.is_empty() {
        return Vec::new();
    }
    segments
        .iter()
        .map(|seg| bi_virtual_bar_from_segment(bars, seg))
        .collect()
}

/// 由计算层笔 K 生成展示视图：相邻笔在共享分钟 K 上左/右半侧衔接，view 横向无缝。
pub fn build_bi_virtual_bar_views(bars: &[BiVirtualBar]) -> Vec<BiVirtualBarView> {
    if bars.is_empty() {
        return Vec::new();
    }
    let n = bars.len();
    let mut view_x1: Vec<i32> = bars.iter().map(|b| b.x1).collect();
    let mut view_x2: Vec<i32> = bars.iter().map(|b| b.x2).collect();
    let mut end_at_left_half = vec![false; n];
    let mut start_at_right_half = vec![false; n];

    for i in 0..n - 1 {
        let cur = &bars[i];
        let next = &bars[i + 1];
        // 相邻笔 x 区间交叠：衔接 K = 上一笔末端分钟 K，两端同索引、半侧锚定
        if next.x1 <= cur.x2 {
            let junction = cur.x2.clamp(cur.x1, next.x2);
            view_x2[i] = junction;
            view_x1[i + 1] = junction;
            end_at_left_half[i] = true;
            start_at_right_half[i + 1] = true;
        }
    }

    for i in 0..n {
        if view_x2[i] < view_x1[i] {
            view_x2[i] = view_x1[i];
        }
    }

    bars.iter()
        .enumerate()
        .map(|(i, bar)| BiVirtualBarView {
            bar: bar.clone(),
            view_x1: view_x1[i],
            view_x2: view_x2[i],
            end_at_left_half: end_at_left_half[i],
            start_at_right_half: start_at_right_half[i],
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::combine::BiConfirmSignal;
    use crate::kline::KlineBar;
    use crate::combine::KlineCombineFrame;

    fn bar(idx: i32, time_text: &str, time_ms: i64) -> KlineBar {
        KlineBar {
            idx,
            time_ms,
            time_text: time_text.to_string(),
            open: 1.0,
            high: 2.0,
            low: 0.5,
            close: 1.5,
            volume: 1.0,
            amount: 1.0,
            metrics: serde_json::Map::new(),
        }
    }

    #[test]
    fn weekday_from_time_text_monday() {
        let b = bar(0, "2024/01/01 09:30", 0);
        assert_eq!(weekday_from_bar(&b), "周一");
    }

    #[test]
    fn fractal_peak_dist_after_bi_confirm() {
        // 分型框 K1-K3（3根），极点在 K1（high 最大），笔确认在 K4 当步
        let bars = vec![
            KlineBar {
                idx: 0,
                time_ms: 0,
                time_text: "t0".into(),
                open: 9.0,
                high: 12.0,
                low: 8.0,
                close: 10.0,
                volume: 1.0,
                amount: 1.0,
                metrics: serde_json::Map::new(),
            },
            KlineBar {
                idx: 1,
                time_ms: 1,
                time_text: "t1".into(),
                open: 9.5,
                high: 10.0,
                low: 9.0,
                close: 9.5,
                volume: 1.0,
                amount: 1.0,
                metrics: serde_json::Map::new(),
            },
            KlineBar {
                idx: 2,
                time_ms: 2,
                time_text: "t2".into(),
                open: 9.0,
                high: 9.5,
                low: 8.5,
                close: 9.0,
                volume: 1.0,
                amount: 1.0,
                metrics: serde_json::Map::new(),
            },
            KlineBar {
                idx: 3,
                time_ms: 3,
                time_text: "t3".into(),
                open: 8.0,
                high: 8.5,
                low: 7.0,
                close: 7.5,
                volume: 1.0,
                amount: 1.0,
                metrics: serde_json::Map::new(),
            },
            KlineBar {
                idx: 4,
                time_ms: 4,
                time_text: "t4".into(),
                open: 7.5,
                high: 8.0,
                low: 7.0,
                close: 7.8,
                volume: 1.0,
                amount: 1.0,
                metrics: serde_json::Map::new(),
            },
        ];
        let conf = BiConfirmSignal {
            x: 3,
            fx: "TOP".to_string(),
            value: -1,
            fractal_x1: 0,
            fractal_x2: 2,
        };
        assert_eq!(fractal_extreme_bar_idx(&bars, &conf), Some(0));
        let mut feats = (0..bars.len())
            .map(|i| BarCrosshairFeature {
                idx: i as i32,
                weekday: "-".into(),
                merge_inner_seq: 1,
                merge_count: 1,
                combine_fx: "UNKNOWN".into(),
                combine_high: 0.0,
                combine_low: 0.0,
                fractal_peak_dist: 0,
                bi_idx: None,
                bi_merge_inner_seq: 1,
                bi_merge_count: 1,
                bi_open: 0.0,
                bi_high: 0.0,
                bi_low: 0.0,
                bi_close: 0.0,
                bi_volume: 0.0,
                bi_combine_high: 0.0,
                bi_combine_low: 0.0,
                bi_combine_fx: "UNKNOWN".into(),
            })
            .collect::<Vec<_>>();
        enrich_fractal_peak_dist(&bars, &mut feats, &[conf]);
        assert_eq!(feats[0].fractal_peak_dist, 0);
        assert_eq!(feats[2].fractal_peak_dist, 0);
        // 确认当步 K3：距极点 K0 不含首根 = 3
        assert_eq!(feats[3].fractal_peak_dist, 3);
        assert_eq!(feats[4].fractal_peak_dist, 4);
    }

    #[test]
    fn bi_crosshair_fields_provisional_idx_zero() {
        use crate::combine::build_bar_crosshair_features_stepwise;
        let bars: Vec<KlineBar> = (0..8)
            .map(|i| KlineBar {
                idx: i,
                time_ms: i as i64,
                time_text: format!("2024/01/01 09:{i:02}"),
                open: 10.0 + i as f64 * 0.1,
                high: 10.5 + i as f64 * 0.1,
                low: 9.5 + i as f64 * 0.1,
                close: 10.2 + i as f64 * 0.1,
                volume: 100.0 + i as f64,
                amount: 1.0,
                metrics: serde_json::Map::new(),
            })
            .collect();
        let confirms = vec![BiConfirmSignal {
            x: 1,
            fx: "BOTTOM".to_string(),
            value: 1,
            fractal_x1: 0,
            fractal_x2: 1,
        }];
        let mut feats = build_bar_crosshair_features_stepwise(&bars);
        enrich_bi_crosshair_fields(&bars, &mut feats, &[], &confirms);
        assert_eq!(feats[2].bi_idx, Some(0));
        assert!(feats[2].bi_high > 0.0);
        assert!(feats[2].bi_volume > 0.0);
        assert_eq!(feats[0].bi_idx, None);
    }

    #[test]
    fn merge_inner_seq_in_frame() {
        let frames = vec![KlineCombineFrame {
            x1: 0,
            x2: 2,
            t1: String::new(),
            t2: String::new(),
            high: 10.0,
            low: 9.0,
            fx: "UNKNOWN".to_string(),
            count: 3,
            end_at_left_half: false,
            start_at_right_half: false,
        }];
        let map = merge_inner_seq_map(&frames);
        assert_eq!(map[0], 1);
        assert_eq!(map[1], 2);
        assert_eq!(map[2], 3);
    }

    #[test]
    fn bi_segments_link_opposite_fractals() {
        let confirms = vec![
            BiConfirmSignal {
                x: 2,
                fx: "BOTTOM".to_string(),
                value: 1,
                fractal_x1: 1,
                fractal_x2: 1,
            },
            BiConfirmSignal {
                x: 5,
                fx: "TOP".to_string(),
                value: -1,
                fractal_x1: 4,
                fractal_x2: 4,
            },
            BiConfirmSignal {
                x: 8,
                fx: "BOTTOM".to_string(),
                value: 1,
                fractal_x1: 7,
                fractal_x2: 7,
            },
        ];
        let segs = build_bi_segments(&confirms);
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[0].dir, 1);
        assert_eq!(segs[1].dir, -1);
        assert_eq!(segs[0].next_idx, Some(1));
        assert_eq!(segs[1].prev_idx, Some(0));
    }

    #[test]
    fn bi_virtual_bar_uses_range_hl() {
        let mut bars = vec![
            bar(0, "2024/01/01 09:00", 0),
            bar(1, "2024/01/01 09:01", 0),
            bar(2, "2024/01/01 09:02", 0),
        ];
        bars[0].open = 10.0;
        bars[0].high = 11.0;
        bars[0].low = 9.5;
        bars[0].close = 10.5;
        bars[1].open = 10.5;
        bars[1].high = 12.0;
        bars[1].low = 10.0;
        bars[1].close = 11.5;
        bars[2].open = 11.5;
        bars[2].high = 11.8;
        bars[2].low = 10.5;
        bars[2].close = 11.0;
        let segs = vec![BiSegment {
            idx: 0,
            dir: 1,
            begin_confirm_x: 0,
            end_confirm_x: 2,
            begin_fractal_x1: 0,
            begin_fractal_x2: 0,
            end_fractal_x1: 2,
            end_fractal_x2: 2,
            prev_idx: None,
            next_idx: None,
        }];
        let vb = build_bi_virtual_bars(&bars, &segs);
        assert_eq!(vb.len(), 1);
        assert_eq!(vb[0].high, 12.0);
        assert_eq!(vb[0].low, 9.5);
        assert_eq!(vb[0].open, 10.0);
        assert_eq!(vb[0].close, 11.0);
    }

    #[test]
    fn bi_virtual_bar_view_half_bar_junction() {
        let bars = vec![
            BiVirtualBar {
                idx: 0,
                dir: 1,
                x1: 1,
                x2: 8,
                open: 1.0,
                high: 2.0,
                low: 0.5,
                close: 1.5,
                confirm_x: 8,
            },
            BiVirtualBar {
                idx: 1,
                dir: -1,
                x1: 6,
                x2: 12,
                open: 1.5,
                high: 2.0,
                low: 0.5,
                close: 1.0,
                confirm_x: 12,
            },
        ];
        let views = build_bi_virtual_bar_views(&bars);
        assert_eq!(views.len(), 2);
        assert_eq!(views[0].view_x2, 8);
        assert_eq!(views[1].view_x1, 8);
        assert!(views[0].end_at_left_half);
        assert!(views[1].start_at_right_half);
    }

    #[test]
    fn bi_combine_frames_use_view_x_and_half_flags() {
        use crate::combine::build_bi_combine_frames;

        let bars = vec![
            bar(0, "2024/01/01 09:30", 0),
            bar(1, "2024/01/01 09:31", 60_000),
            bar(2, "2024/01/01 09:32", 120_000),
            bar(3, "2024/01/01 09:33", 180_000),
            bar(4, "2024/01/01 09:34", 240_000),
            bar(5, "2024/01/01 09:35", 300_000),
            bar(6, "2024/01/01 09:36", 360_000),
            bar(7, "2024/01/01 09:37", 420_000),
            bar(8, "2024/01/01 09:38", 480_000),
            bar(9, "2024/01/01 09:39", 540_000),
            bar(10, "2024/01/01 09:40", 600_000),
            bar(11, "2024/01/01 09:41", 660_000),
            bar(12, "2024/01/01 09:42", 720_000),
        ];
        let bi_bars = vec![
            BiVirtualBar {
                idx: 0,
                dir: 1,
                x1: 1,
                x2: 8,
                open: 1.0,
                high: 3.0,
                low: 1.0,
                close: 2.5,
                confirm_x: 8,
            },
            BiVirtualBar {
                idx: 1,
                dir: -1,
                x1: 6,
                x2: 12,
                open: 2.5,
                high: 2.5,
                low: 0.5,
                close: 1.0,
                confirm_x: 12,
            },
        ];
        let frames = build_bi_combine_frames(&bars, &bi_bars);
        assert_eq!(frames.len(), 2);
        // count=1 单根笔 K 框：保留半侧锚定
        assert_eq!(frames[0].count, 1);
        assert_eq!(frames[0].x1, 1);
        assert_eq!(frames[0].x2, 8);
        assert!(frames[0].end_at_left_half);
        assert!(!frames[0].start_at_right_half);
        assert_eq!(frames[1].count, 1);
        assert_eq!(frames[1].x1, 8);
        assert_eq!(frames[1].x2, 12);
        assert!(!frames[1].end_at_left_half);
        assert!(frames[1].start_at_right_half);
    }

    #[test]
    fn bi_combine_frames_merge_units() {
        use crate::combine::build_bi_combine_frames;

        let bars = vec![
            bar(0, "2024/01/01 09:30", 0),
            bar(1, "2024/01/01 09:31", 60_000),
            bar(2, "2024/01/01 09:32", 120_000),
        ];
        let bi_bars = vec![
            BiVirtualBar {
                idx: 0,
                dir: 1,
                x1: 0,
                x2: 0,
                open: 9.0,
                high: 10.0,
                low: 9.0,
                close: 10.0,
                confirm_x: 0,
            },
            BiVirtualBar {
                idx: 1,
                dir: -1,
                x1: 1,
                x2: 1,
                open: 10.0,
                high: 10.0,
                low: 9.5,
                close: 9.5,
                confirm_x: 1,
            },
            BiVirtualBar {
                idx: 2,
                dir: 1,
                x1: 2,
                x2: 2,
                open: 9.5,
                high: 11.0,
                low: 9.5,
                close: 11.0,
                confirm_x: 2,
            },
        ];
        let frames = build_bi_combine_frames(&bars, &bi_bars);
        assert!(!frames.is_empty());
        assert!(frames.iter().any(|f| f.count >= 2) || frames.len() < bi_bars.len());
        // count>=2 合并框：半侧标志应清除，走中轴口径
        for f in frames.iter().filter(|f| f.count >= 2) {
            assert!(!f.end_at_left_half);
            assert!(!f.start_at_right_half);
        }
    }
}
