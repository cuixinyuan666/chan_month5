//! K 线包含/合并（对齐 Combiner/KLine_Combiner + KLine_List.add_single_klu）。

use serde::{Deserialize, Serialize};

use crate::feature::{
    build_bi_segments, build_bi_virtual_bar_views, build_bi_virtual_bars, enrich_fractal_peak_dist,
    BarCrosshairFeature, BiSegment, BiVirtualBar,
};
use crate::kline::KlineBar;
use crate::seg_eigen::{build_seg_analysis, SegAnalysisBundle};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum KlineDir {
    Up,
    Down,
    Combine,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FxType {
    Top,
    Bottom,
    Unknown,
}

impl FxType {
    fn as_str(self) -> &'static str {
        match self {
            Self::Top => "TOP",
            Self::Bottom => "BOTTOM",
            Self::Unknown => "UNKNOWN",
        }
    }
}

#[derive(Debug, Clone)]
struct MergedKlc {
    high: f64,
    low: f64,
    dir: KlineDir,
    fx: FxType,
    begin_idx: usize,
    end_idx: usize,
}

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

/// 可合并高低单元（1 分钟 K 或笔 K 线共用包含逻辑）。
#[derive(Debug, Clone)]
pub struct HlMergeUnit {
    pub x1: i32,
    pub x2: i32,
    pub high: f64,
    pub low: f64,
    pub t1: String,
    pub t2: String,
    /// 末端落在 x2 分钟 K 左半侧（笔 K view 半侧锚定）
    pub end_at_left_half: bool,
    /// 起始落在 x1 分钟 K 右半侧
    pub start_at_right_half: bool,
}

#[derive(Debug, Clone)]
struct HlMergedKlc {
    high: f64,
    low: f64,
    dir: KlineDir,
    fx: FxType,
    x1: i32,
    x2: i32,
    t1: String,
    t2: String,
    end_at_left_half: bool,
    start_at_right_half: bool,
}

impl HlMergedKlc {
    fn new_first(u: &HlMergeUnit) -> Self {
        Self {
            high: u.high,
            low: u.low,
            dir: KlineDir::Up,
            fx: FxType::Unknown,
            x1: u.x1,
            x2: u.x2,
            t1: u.t1.clone(),
            t2: u.t2.clone(),
            end_at_left_half: u.end_at_left_half,
            start_at_right_half: u.start_at_right_half,
        }
    }

    fn try_add(&mut self, u: &HlMergeUnit) -> KlineDir {
        let dir = test_combine_range(self.high, self.low, u.high, u.low);
        if dir == KlineDir::Combine {
            if self.dir == KlineDir::Up {
                if (u.high - u.low).abs() > 1e-12 || (u.high - self.high).abs() > 1e-12 {
                    self.high = self.high.max(u.high);
                    self.low = self.low.max(u.low);
                }
            } else if self.dir == KlineDir::Down {
                if (u.high - u.low).abs() > 1e-12 || (u.low - self.low).abs() > 1e-12 {
                    self.high = self.high.min(u.high);
                    self.low = self.low.min(u.low);
                }
            }
            self.x2 = u.x2;
            self.t2 = u.t2.clone();
            self.end_at_left_half = u.end_at_left_half;
        }
        dir
    }

    fn update_fx(&mut self, pre: &HlMergedKlc, next: &HlMergedKlc) {
        self.fx = FxType::Unknown;
        if pre.high < self.high
            && next.high < self.high
            && pre.low < self.low
            && next.low < self.low
        {
            self.fx = FxType::Top;
        } else if pre.high > self.high
            && next.high > self.high
            && pre.low > self.low
            && next.low > self.low
        {
            self.fx = FxType::Bottom;
        }
    }
}

/// 对高低单元序列做 K 线包含合并（与 1 分钟 K 合并同逻辑）。
pub fn build_combine_frames_from_hl_units(units: &[HlMergeUnit]) -> Vec<KlineCombineFrame> {
    if units.is_empty() {
        return Vec::new();
    }
    let mut klcs: Vec<HlMergedKlc> = Vec::new();
    let mut unit_counts: Vec<usize> = Vec::new();

    for u in units {
        if klcs.is_empty() {
            klcs.push(HlMergedKlc::new_first(u));
            unit_counts.push(1);
            continue;
        }
        let last = klcs.len() - 1;
        let dir = klcs[last].try_add(u);
        if dir == KlineDir::Combine {
            unit_counts[last] += 1;
        } else {
            let mut nk = HlMergedKlc::new_first(u);
            nk.dir = dir;
            klcs.push(nk);
            unit_counts.push(1);
            if klcs.len() >= 3 {
                let n = klcs.len();
                let pre = klcs[n - 3].clone();
                let next = klcs[n - 1].clone();
                klcs[n - 2].update_fx(&pre, &next);
            }
        }
    }

    klcs.iter()
        .zip(unit_counts.iter())
        .map(|(klc, cnt)| KlineCombineFrame {
            x1: klc.x1,
            x2: klc.x2,
            t1: klc.t1.clone(),
            t2: klc.t2.clone(),
            high: klc.high,
            low: klc.low,
            fx: klc.fx.as_str().to_string(),
            count: *cnt as i32,
            end_at_left_half: klc.end_at_left_half,
            start_at_right_half: klc.start_at_right_half,
        })
        .collect()
}

/// 笔 K 线序列 → 合并笔 K 线线框（副图「合并笔K线」）。
/// 多根包含合并：x1/x2 为首尾 view 索引，外侧框按分钟 K 中轴（同合并 K 线）。
/// 仅一根笔 K（count=1）：保留半侧锚定，与笔 K 蜡烛衔接一致。
pub fn build_bi_combine_frames(bars: &[KlineBar], bi_bars: &[BiVirtualBar]) -> Vec<KlineCombineFrame> {
    if bi_bars.is_empty() {
        return Vec::new();
    }
    let views = build_bi_virtual_bar_views(bi_bars);
    let units: Vec<HlMergeUnit> = views
        .iter()
        .map(|v| {
            let b = &v.bar;
            let t1 = bars
                .get(v.view_x1.max(0) as usize)
                .map(|x| x.time_text.clone())
                .unwrap_or_default();
            let t2 = bars
                .get(v.view_x2.max(0) as usize)
                .map(|x| x.time_text.clone())
                .unwrap_or_default();
            HlMergeUnit {
                x1: v.view_x1,
                x2: v.view_x2,
                high: b.high,
                low: b.low,
                t1,
                t2,
                end_at_left_half: v.end_at_left_half,
                start_at_right_half: v.start_at_right_half,
            }
        })
        .collect();
    let mut frames = build_combine_frames_from_hl_units(&units);
    // 半侧标志仅用于 count=1 单根笔 K 框；多根合并框走中轴口径，与合并 K 线一致
    if !frames.is_empty() && !units.is_empty() {
        let mut unit_cursor = 0usize;
        for frame in frames.iter_mut() {
            let cnt = frame.count.max(1) as usize;
            if cnt > 1 {
                frame.start_at_right_half = false;
                frame.end_at_left_half = false;
            } else if unit_cursor < units.len() {
                frame.start_at_right_half = units[unit_cursor].start_at_right_half;
                frame.end_at_left_half = units[unit_cursor].end_at_left_half;
            }
            unit_cursor += cnt;
        }
    }
    frames
}

/// 逐步喂入高低单元时的分型确认（合并笔 K 线段确认同源）。
#[derive(Debug, Clone)]
pub struct HlFxConfirm {
    pub fx: String,
    pub fractal_x1: i32,
    pub fractal_x2: i32,
    pub fractal_high: f64,
    pub fractal_low: f64,
}

/// 逐笔喂入合并笔 K 线时的包含合并状态（与 `build_combine_frames_from_hl_units` 同口径）。
#[derive(Debug, Default, Clone)]
pub struct HlCombineStepState {
    klcs: Vec<HlMergedKlc>,
    unit_counts: Vec<usize>,
    /// 每笔已喂入单元的 bi idx（扁平，与合并计数同步）
    unit_bi_idxs: Vec<i32>,
    /// 末单元是否为进行中笔 K（方案 A：笔内可更新，确认后转永久）
    provisional: bool,
}

/// 合并笔 K 线当步十字线快照。
#[derive(Debug, Clone)]
pub struct BiCombineCrosshairSnap {
    pub bi_merge_inner_seq: i32,
    pub bi_merge_count: i32,
    pub bi_combine_high: f64,
    pub bi_combine_low: f64,
    pub bi_combine_fx: String,
}

impl HlCombineStepState {
    /// 十字线：末合并笔 K 线框当步 H/L 与笔 K 合并内序。
    pub fn crosshair_snapshot(&self, active_bi_idx: i32) -> BiCombineCrosshairSnap {
        if self.klcs.is_empty() {
            return BiCombineCrosshairSnap {
                bi_merge_inner_seq: 1,
                bi_merge_count: 1,
                bi_combine_high: 0.0,
                bi_combine_low: 0.0,
                bi_combine_fx: FxType::Unknown.as_str().to_string(),
            };
        }
        let last_klc = self.klcs.len() - 1;
        let cnt = self.unit_counts.get(last_klc).copied().unwrap_or(1).max(1);
        let unit_start: usize = self.unit_counts.iter().take(last_klc).sum();
        let mut inner_seq = cnt as i32;
        for j in 0..cnt {
            let ui = unit_start + j;
            if ui < self.unit_bi_idxs.len() && self.unit_bi_idxs[ui] == active_bi_idx {
                inner_seq = (j + 1) as i32;
                break;
            }
        }
        let klc = &self.klcs[last_klc];
        BiCombineCrosshairSnap {
            bi_merge_inner_seq: inner_seq,
            bi_merge_count: cnt as i32,
            bi_combine_high: klc.high,
            bi_combine_low: klc.low,
            bi_combine_fx: klc.fx.as_str().to_string(),
        }
    }

    /// 喂入已确认笔 K 线；若末位为进行中单元则先移除再喂入。
    pub fn feed_permanent(&mut self, u: &HlMergeUnit, bi_idx: i32) -> Option<HlFxConfirm> {
        if self.provisional {
            self.klcs.pop();
            self.unit_counts.pop();
            if !self.unit_bi_idxs.is_empty() {
                self.unit_bi_idxs.pop();
            }
            self.provisional = false;
        }
        self.feed(u, bi_idx)
    }

    /// 更新进行中笔 K 线（每笔内逐 K 刷新高低与 x2）；可触发合并笔 K 分型确认。
    pub fn update_provisional(&mut self, u: &HlMergeUnit, bi_idx: i32) -> Option<HlFxConfirm> {
        if self.provisional && !self.klcs.is_empty() {
            self.replace_last_with_new_unit(u, bi_idx);
        } else {
            self.provisional = true;
            return self.feed(u, bi_idx);
        }
        self.reeval_mid_fx()
    }

    /// 移除末位进行中单元（当前步无进行中笔时调用）。
    pub fn clear_provisional(&mut self) {
        if self.provisional {
            self.klcs.pop();
            self.unit_counts.pop();
            if !self.unit_bi_idxs.is_empty() {
                self.unit_bi_idxs.pop();
            }
            self.provisional = false;
        }
    }

    fn replace_last_with_new_unit(&mut self, u: &HlMergeUnit, bi_idx: i32) {
        let last = self.klcs.len() - 1;
        if last == 0 {
            self.klcs[0] = HlMergedKlc::new_first(u);
            self.unit_counts[0] = 1;
            if let Some(tag) = self.unit_bi_idxs.last_mut() {
                *tag = bi_idx;
            } else {
                self.unit_bi_idxs.push(bi_idx);
            }
            return;
        }
        let prev_idx = last - 1;
        let prev_h = self.klcs[prev_idx].high;
        let prev_l = self.klcs[prev_idx].low;
        let dir = test_combine_range(prev_h, prev_l, u.high, u.low);
        if dir == KlineDir::Combine {
            self.klcs[prev_idx].try_add(u);
            self.klcs.pop();
            self.unit_counts.pop();
            if !self.unit_bi_idxs.is_empty() {
                self.unit_bi_idxs.pop();
            }
            self.provisional = false;
            if prev_idx < self.unit_counts.len() {
                self.unit_counts[prev_idx] += 1;
            }
            self.unit_bi_idxs.push(bi_idx);
        } else {
            let mut nk = HlMergedKlc::new_first(u);
            nk.dir = dir;
            self.klcs[last] = nk;
            if last < self.unit_counts.len() {
                self.unit_counts[last] = 1;
            }
            if let Some(tag) = self.unit_bi_idxs.last_mut() {
                *tag = bi_idx;
            }
        }
    }

    fn reeval_mid_fx(&mut self) -> Option<HlFxConfirm> {
        if self.klcs.len() < 3 {
            return None;
        }
        let n = self.klcs.len();
        let pre = self.klcs[n - 3].clone();
        let next = self.klcs[n - 1].clone();
        self.klcs[n - 2].update_fx(&pre, &next);
        let mid = &self.klcs[n - 2];
        match mid.fx {
            FxType::Top => Some(HlFxConfirm {
                fx: FxType::Top.as_str().to_string(),
                fractal_x1: mid.x1,
                fractal_x2: mid.x2,
                fractal_high: mid.high,
                fractal_low: mid.low,
            }),
            FxType::Bottom => Some(HlFxConfirm {
                fx: FxType::Bottom.as_str().to_string(),
                fractal_x1: mid.x1,
                fractal_x2: mid.x2,
                fractal_high: mid.high,
                fractal_low: mid.low,
            }),
            FxType::Unknown => None,
        }
    }

    /// 喂入一笔笔 K 线单元；第三元素进入触发分型时返回确认信息。
    pub fn feed(&mut self, u: &HlMergeUnit, bi_idx: i32) -> Option<HlFxConfirm> {
        if self.klcs.is_empty() {
            self.klcs.push(HlMergedKlc::new_first(u));
            self.unit_counts.push(1);
            self.unit_bi_idxs.push(bi_idx);
            return None;
        }
        let last = self.klcs.len() - 1;
        let dir = self.klcs[last].try_add(u);
        if dir == KlineDir::Combine {
            self.unit_counts[last] += 1;
            self.unit_bi_idxs.push(bi_idx);
            return None;
        }
        let mut nk = HlMergedKlc::new_first(u);
        nk.dir = dir;
        self.klcs.push(nk);
        self.unit_counts.push(1);
        self.unit_bi_idxs.push(bi_idx);
        if self.klcs.len() < 3 {
            return None;
        }
        let n = self.klcs.len();
        let pre = self.klcs[n - 3].clone();
        let next = self.klcs[n - 1].clone();
        self.klcs[n - 2].update_fx(&pre, &next);
        let mid = &self.klcs[n - 2];
        match mid.fx {
            FxType::Top => Some(HlFxConfirm {
                fx: FxType::Top.as_str().to_string(),
                fractal_x1: mid.x1,
                fractal_x2: mid.x2,
                fractal_high: mid.high,
                fractal_low: mid.low,
            }),
            FxType::Bottom => Some(HlFxConfirm {
                fx: FxType::Bottom.as_str().to_string(),
                fractal_x1: mid.x1,
                fractal_x2: mid.x2,
                fractal_high: mid.high,
                fractal_low: mid.low,
            }),
            FxType::Unknown => None,
        }
    }
}

/// 笔确认柱：合并 K 线顶/底分型确认当步 K（分型连接即笔，逐K当下冻结）。
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

/// 合并线框 + 笔确认 + 十字线特征 + 笔段链（一次遍历产出，逐K当下）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KlineCombineBundle {
    pub frames: Vec<KlineCombineFrame>,
    pub bi_confirms: Vec<BiConfirmSignal>,
    /// 每根 K 十字线特征（星期、合并内序号）
    #[serde(default)]
    pub bar_features: Vec<BarCrosshairFeature>,
    /// 相邻异向分型配对笔段，含 prev/next 连续关联
    #[serde(default)]
    pub bi_segments: Vec<BiSegment>,
    /// 合并笔 K 线段确认 / 首段方向（逐K当下）
    #[serde(default)]
    pub seg_analysis: SegAnalysisBundle,
    /// 笔确认后包装笔 K 线（主图展示）
    #[serde(default)]
    pub bi_virtual_bars: Vec<BiVirtualBar>,
    /// 笔 K 线包含合并线框（副图「合并笔K线」）
    #[serde(default)]
    pub bi_combine_frames: Vec<KlineCombineFrame>,
}

/// 单步合并 K 线状态（逐K当下，供 ML / 十字线）。
#[derive(Debug, Clone)]
pub struct BarCombineStepState {
    pub merge_inner_seq: i32,
    pub merge_count: i32,
    pub combine_fx: String,
    pub combine_high: f64,
    pub combine_low: f64,
}

/// 与 `build_kline_combine_bundle` 同口径的逐步合并状态。
pub fn build_bar_combine_step_states(bars: &[KlineBar]) -> Vec<BarCombineStepState> {
    if bars.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(bars.len());
    let mut klcs: Vec<MergedKlc> = Vec::new();
    let mut unit_counts: Vec<usize> = Vec::new();
    // 每根合并 K 线：分型确认当步（None=尚未确认）
    let mut fx_confirm_at: Vec<Option<usize>> = Vec::new();

    for (i, bar) in bars.iter().enumerate() {
        if klcs.is_empty() {
            klcs.push(MergedKlc::new_first(i, bar.high, bar.low));
            unit_counts.push(1);
            fx_confirm_at.push(None);
        } else {
            let last = klcs.len() - 1;
            let dir = klcs[last].try_add(i, bar.high, bar.low);
            if dir == KlineDir::Combine {
                unit_counts[last] += 1;
            } else {
                let mut nk = MergedKlc::new_first(i, bar.high, bar.low);
                nk.dir = dir;
                klcs.push(nk);
                unit_counts.push(1);
                fx_confirm_at.push(None);
                if klcs.len() >= 3 {
                    let n = klcs.len();
                    let pre = klcs[n - 3].clone();
                    let next = klcs[n - 1].clone();
                    klcs[n - 2].update_fx(&pre, &next);
                    if klcs[n - 2].fx != FxType::Unknown {
                        fx_confirm_at[n - 2] = Some(i);
                    }
                }
            }
        }

        let klc_idx = klcs.len() - 1;
        let merge_count = unit_counts[klc_idx] as i32;
        let merge_inner_seq = merge_count;
        let combine_fx = match fx_confirm_at[klc_idx] {
            Some(confirm_i) if confirm_i <= i => klcs[klc_idx].fx.as_str().to_string(),
            _ => FxType::Unknown.as_str().to_string(),
        };
        out.push(BarCombineStepState {
            merge_inner_seq,
            merge_count,
            combine_fx,
            combine_high: klcs[klc_idx].high,
            combine_low: klcs[klc_idx].low,
        });
    }
    out
}

/// 逐步十字线特征（逐K当下 merge_count / combine_fx）。
pub fn build_bar_crosshair_features_stepwise(bars: &[KlineBar]) -> Vec<BarCrosshairFeature> {
    use crate::feature::{weekday_from_bar, BarCrosshairFeature};
    build_bar_combine_step_states(bars)
        .into_iter()
        .enumerate()
        .map(|(i, st)| {
            let b = &bars[i];
            BarCrosshairFeature {
                idx: b.idx,
                weekday: weekday_from_bar(b),
                merge_inner_seq: st.merge_inner_seq,
                merge_count: st.merge_count,
                combine_fx: st.combine_fx,
                combine_high: st.combine_high,
                combine_low: st.combine_low,
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
                bi_combine_fx: "UNKNOWN".to_string(),
            }
        })
        .collect()
}

fn test_combine_range(high_a: f64, low_a: f64, high_b: f64, low_b: f64) -> KlineDir {
    if high_a >= high_b && low_a <= low_b {
        return KlineDir::Combine;
    }
    if high_a <= high_b && low_a >= low_b {
        return KlineDir::Combine;
    }
    if high_a > high_b && low_a > low_b {
        return KlineDir::Down;
    }
    if high_a < high_b && low_a < low_b {
        return KlineDir::Up;
    }
    KlineDir::Combine
}

impl MergedKlc {
    fn new_first(idx: usize, high: f64, low: f64) -> Self {
        Self {
            high,
            low,
            dir: KlineDir::Up,
            fx: FxType::Unknown,
            begin_idx: idx,
            end_idx: idx,
        }
    }

    fn try_add(&mut self, idx: usize, high: f64, low: f64) -> KlineDir {
        let dir = test_combine_range(self.high, self.low, high, low);
        if dir == KlineDir::Combine {
            if self.dir == KlineDir::Up {
                if (high - low).abs() > 1e-12 || (high - self.high).abs() > 1e-12 {
                    self.high = self.high.max(high);
                    self.low = self.low.max(low);
                }
            } else if self.dir == KlineDir::Down {
                if (high - low).abs() > 1e-12 || (low - self.low).abs() > 1e-12 {
                    self.high = self.high.min(high);
                    self.low = self.low.min(low);
                }
            }
            self.end_idx = idx;
        }
        dir
    }

    fn update_fx(&mut self, pre: &MergedKlc, next: &MergedKlc) {
        self.fx = FxType::Unknown;
        if pre.high < self.high
            && next.high < self.high
            && pre.low < self.low
            && next.low < self.low
        {
            self.fx = FxType::Top;
        } else if pre.high > self.high
            && next.high > self.high
            && pre.low > self.low
            && next.low > self.low
        {
            self.fx = FxType::Bottom;
        }
    }
}

fn push_bi_confirm_if_fx(
    klc: &MergedKlc,
    confirm_bar_idx: usize,
    signals: &mut Vec<BiConfirmSignal>,
) {
    match klc.fx {
        FxType::Top => signals.push(BiConfirmSignal {
            x: confirm_bar_idx as i32,
            fx: FxType::Top.as_str().to_string(),
            value: -1,
            fractal_x1: klc.begin_idx as i32,
            fractal_x2: klc.end_idx as i32,
        }),
        FxType::Bottom => signals.push(BiConfirmSignal {
            x: confirm_bar_idx as i32,
            fx: FxType::Bottom.as_str().to_string(),
            value: 1,
            fractal_x1: klc.begin_idx as i32,
            fractal_x2: klc.end_idx as i32,
        }),
        FxType::Unknown => {}
    }
}

/// 对已喂入 K 线做增量合并，输出线框 + 笔确认柱。
pub fn build_kline_combine_bundle(bars: &[KlineBar]) -> KlineCombineBundle {
    if bars.is_empty() {
        return KlineCombineBundle {
            frames: Vec::new(),
            bi_confirms: Vec::new(),
            bar_features: Vec::new(),
            bi_segments: Vec::new(),
            seg_analysis: SegAnalysisBundle::default(),
            bi_virtual_bars: Vec::new(),
            bi_combine_frames: Vec::new(),
        };
    }

    let mut klcs: Vec<MergedKlc> = Vec::new();
    let mut unit_counts: Vec<usize> = Vec::new();
    let mut bi_confirms: Vec<BiConfirmSignal> = Vec::new();

    for (i, bar) in bars.iter().enumerate() {
        if klcs.is_empty() {
            klcs.push(MergedKlc::new_first(i, bar.high, bar.low));
            unit_counts.push(1);
            continue;
        }
        let last = klcs.len() - 1;
        let dir = klcs[last].try_add(i, bar.high, bar.low);
        if dir == KlineDir::Combine {
            unit_counts[last] += 1;
        } else {
            let mut nk = MergedKlc::new_first(i, bar.high, bar.low);
            nk.dir = dir;
            klcs.push(nk);
            unit_counts.push(1);
            if klcs.len() >= 3 {
                let n = klcs.len();
                let pre = klcs[n - 3].clone();
                let next = klcs[n - 1].clone();
                klcs[n - 2].update_fx(&pre, &next);
                push_bi_confirm_if_fx(&klcs[n - 2], i, &mut bi_confirms);
            }
        }
    }

    let frames = klcs
        .iter()
        .zip(unit_counts.iter())
        .map(|(klc, cnt)| {
            let t1 = bars
                .get(klc.begin_idx)
                .map(|b| b.time_text.clone())
                .unwrap_or_default();
            let t2 = bars
                .get(klc.end_idx)
                .map(|b| b.time_text.clone())
                .unwrap_or_default();
            KlineCombineFrame {
                x1: klc.begin_idx as i32,
                x2: klc.end_idx as i32,
                t1,
                t2,
                high: klc.high,
                low: klc.low,
                fx: klc.fx.as_str().to_string(),
                count: *cnt as i32,
                end_at_left_half: false,
                start_at_right_half: false,
            }
        })
        .collect::<Vec<KlineCombineFrame>>();

    let bi_segments = build_bi_segments(bars, &bi_confirms);
    let bi_virtual_bars = build_bi_virtual_bars(bars, &bi_segments);
    let bi_combine_frames = build_bi_combine_frames(bars, &bi_virtual_bars);
    let mut bar_features = build_bar_crosshair_features_stepwise(bars);
    enrich_fractal_peak_dist(bars, &mut bar_features, &bi_confirms);
    use crate::feature::enrich_bi_crosshair_fields;
    enrich_bi_crosshair_fields(bars, &mut bar_features, &bi_segments, &bi_confirms);
    let seg_analysis = build_seg_analysis(bars, &bi_segments, &bi_confirms);

    KlineCombineBundle {
        frames,
        bi_confirms,
        bar_features,
        bi_segments,
        seg_analysis,
        bi_virtual_bars,
        bi_combine_frames,
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
        let feats = build_bar_crosshair_features_stepwise(&bars);
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
    }
}
