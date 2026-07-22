//! 十字辅助线 / ML 训练特征 + K1 bar 展示视图（逐K当下，禁止未来函数）。
//! 全层首段策略见 segment_first.rs；合并/分型内核见 engine.rs。

use chrono::{Datelike, TimeZone, Utc};
use serde::{Deserialize, Serialize};

use crate::combine::K0ConfirmSignal;
use crate::kline::KlineBar;
use crate::pipeline::LevelSnap;

const WEEKDAY_CN: [&str; 7] = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

/// 单根 K 十字线基础特征（星期 w1..w7 + K0合并序 + 各层 Kn 快照）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BarCrosshairFeature {
    pub idx: i32,
    /// 当前 K 所属星期（周一…周日；tooltip 显示 w1..w7）
    pub weekday: String,
    /// K0合并K0序：合并框内排序，单根=0，同区间后续依次 1、2…
    pub merge_inner_seq: i32,
    /// 截至当步所在合并区间已合并根数（逐K当下，非末态）
    #[serde(default)]
    pub merge_count: i32,
    /// 截至当步 K0合并框序号（0 起；-1=未成框）
    #[serde(default = "neg_one")]
    pub merge_box_seq: i32,
    /// 截至当步分型：未确认=UNKNOWN（逐K当下）
    #[serde(default = "default_unknown")]
    pub combine_fx: String,
    /// 截至当步 K0合并区间最高价（逐K当下，非末态回写）
    #[serde(default)]
    pub combine_high: f64,
    /// 截至当步 K0合并区间最低价（逐K当下，非末态回写）
    #[serde(default)]
    pub combine_low: f64,
    /// 距最近冻结K0连线确认分型极点间隔根数（不含极点 K）；首K0连线确认前=0
    #[serde(default)]
    pub fractal_peak_dist: i32,
    /// 当步所属 K1 序号；首 K1 确认前=None（levels[0] 冗余镜像，ML 兼容）
    #[serde(default)]
    pub k1_idx: Option<i32>,
    /// K1合并K1序：当步 K1 在 K1合并框内序号（0 起）
    #[serde(default = "default_zero")]
    pub k1_merge_inner_seq: i32,
    /// 当步所在 K1合并框已含 K1 根数（逐K当下）
    #[serde(default = "default_one")]
    pub k1_merge_count: i32,
    #[serde(default)]
    pub k1_open: f64,
    #[serde(default)]
    pub k1_high: f64,
    #[serde(default)]
    pub k1_low: f64,
    #[serde(default)]
    pub k1_close: f64,
    #[serde(default)]
    pub k1_volume: f64,
    /// 当步 K1合并区间最高价（逐K当下）
    #[serde(default)]
    pub k1_combine_high: f64,
    /// 当步 K1合并区间最低价（逐K当下）
    #[serde(default)]
    pub k1_combine_low: f64,
    /// 当步 K1合并分型：未确认=UNKNOWN
    #[serde(default = "default_unknown")]
    pub k1_combine_fx: String,
    /// 各层 Kn 快照（levels[0]=K1/K0连线，levels[1]=K2/K1连线，…穷尽）
    #[serde(default)]
    pub levels: Vec<LevelSnap>,
}

fn default_one() -> i32 {
    1
}

fn default_zero() -> i32 {
    0
}

fn neg_one() -> i32 {
    -1
}

fn default_unknown() -> String {
    "UNKNOWN".to_string()
}

/// K0连线确认后包装成的 K1 bar（区间内最高/最低 + 起止开收，主图展示）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct K1Bar {
    pub idx: i32,
    /// 向上K0连线=1，向下K0连线=-1
    pub dir: i32,
    pub x1: i32,
    pub x2: i32,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    /// K0连线结束确认 K 索引
    pub confirm_x: i32,
}

/// K1 bar 展示视图：计算层区间的 x 裁剪，仅用于绘制。
/// 相邻 K0连线在共享分钟 K 上：上一根末端占左半侧，下一根起始占右半侧，于中轴无缝衔接。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct K1BarView {
    #[serde(flatten)]
    pub bar: K1Bar,
    pub view_x1: i32,
    pub view_x2: i32,
    /// 末端落在 view_x2 对应分钟 K 左半侧（右边界=该 K 中轴）
    #[serde(default)]
    pub end_at_left_half: bool,
    /// 起始落在 view_x1 对应分钟 K 右半侧（左边界=该 K 中轴）
    #[serde(default)]
    pub start_at_right_half: bool,
}

/// K0连线：锚定配对（最近已用端点分型）产物，链条无缝，带前后关联索引。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct K0Line {
    pub idx: i32,
    /// 向上K0连线=1，向下K0连线=-1
    pub dir: i32,
    pub begin_confirm_x: i32,
    pub end_confirm_x: i32,
    pub begin_fractal_x1: i32,
    pub begin_fractal_x2: i32,
    pub end_fractal_x1: i32,
    pub end_fractal_x2: i32,
    pub prev_idx: Option<i32>,
    pub next_idx: Option<i32>,
    /// 已废弃：新方案无 bootstrap 引导段，固定 false
    #[serde(default)]
    pub is_bootstrap: bool,
    /// 已废弃：首段改为种子框 A→B，固定 false
    #[serde(default)]
    pub is_promoted_default: bool,
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

/// 分型合并框内极点 K 索引：TOP 取首个 high 极值，BOTTOM 取首个 low 极值。
pub fn fractal_extreme_bar_idx(bars: &[KlineBar], conf: &K0ConfirmSignal) -> Option<i32> {
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

/// 逐 K 填充 K线分型极点距：基准=最近冻结K0连线确认分型框；确认当步起算；不含极点 K。
pub fn enrich_fractal_peak_dist(
    bars: &[KlineBar],
    features: &mut [BarCrosshairFeature],
    k0_confirms: &[K0ConfirmSignal],
) {
    if features.is_empty() {
        return;
    }
    let mut confirm_ptr = 0usize;
    let mut extreme_idx: Option<i32> = None;

    for i in 0..features.len() {
        while confirm_ptr < k0_confirms.len() && k0_confirms[confirm_ptr].x as usize <= i {
            extreme_idx = fractal_extreme_bar_idx(bars, &k0_confirms[confirm_ptr]);
            confirm_ptr += 1;
        }
        features[i].fractal_peak_dist = match extreme_idx {
            Some(ext) => (i as i32) - ext,
            None => 0,
        };
    }
}

/// 由计算层 K1 bar 生成展示视图：相邻 K0连线在共享分钟 K 上左/右半侧衔接，view 横向无缝。
pub fn build_k1_bar_views(bars: &[K1Bar]) -> Vec<K1BarView> {
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
        // 相邻 K0连线 x 区间交叠：衔接 K = 上一根末端分钟 K，两端同索引、半侧锚定
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
        .map(|(i, bar)| K1BarView {
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
    fn fractal_extreme_bar_idx_top() {
        // 分型框 K0-K2（3根），极点在 K0（high 最大），K0连线确认在 K3 当步
        let mk = |i: i32, o: f64, h: f64, l: f64, c: f64| KlineBar {
            idx: i,
            time_ms: i as i64,
            time_text: format!("t{i}"),
            open: o,
            high: h,
            low: l,
            close: c,
            volume: 1.0,
            amount: 1.0,
            metrics: serde_json::Map::new(),
        };
        let bars = vec![
            mk(0, 9.0, 10.0, 8.0, 9.5),
            mk(1, 9.5, 10.0, 9.0, 9.5),
            mk(2, 9.0, 9.5, 8.5, 9.0),
            mk(3, 8.0, 8.5, 7.0, 7.5),
        ];
        let conf = K0ConfirmSignal {
            x: 3,
            fx: "TOP".to_string(),
            value: -1,
            fractal_x1: 0,
            fractal_x2: 2,
            truncated: false,
        };
        assert_eq!(fractal_extreme_bar_idx(&bars, &conf), Some(0));
    }

    #[test]
    fn k1_bar_view_half_bar_junction() {
        let bars = vec![
            K1Bar {
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
            K1Bar {
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
        let views = build_k1_bar_views(&bars);
        assert_eq!(views.len(), 2);
        assert_eq!(views[0].view_x2, 8);
        assert_eq!(views[1].view_x1, 8);
        assert!(views[0].end_at_left_half);
        assert!(views[1].start_at_right_half);
    }
}
