//! 全层通用首段策略：pending 占位 + 反向极值 trial（放宽）+ retained/purged。
//! L1 输入=1 分钟 K 单元，L2+ 输入=N-1 段 K 线单元；规则全层同构。

use crate::engine::FxKind;
use crate::kline::KlineBar;
use crate::pipeline::{LevelConfirm, LevelUnitBar};

pub const POLICY_PENDING: &str = "pending";
pub const POLICY_RETAINED: &str = "retained";
pub const POLICY_PURGED: &str = "purged";

/// 首段构造面对的输入单元（L1=1 分钟 K，L2+=下层段 K 线）
#[allow(dead_code)]
pub trait FirstSegmentInput {
    fn x1(&self) -> i32;
    fn x2(&self) -> i32;
    fn open(&self) -> f64;
    fn high(&self) -> f64;
    fn low(&self) -> f64;
    fn close(&self) -> f64;
    fn volume(&self) -> f64;
}

impl FirstSegmentInput for LevelUnitBar {
    fn x1(&self) -> i32 {
        self.x1
    }
    fn x2(&self) -> i32 {
        self.x2
    }
    fn open(&self) -> f64 {
        self.open
    }
    fn high(&self) -> f64 {
        self.high
    }
    fn low(&self) -> f64 {
        self.low
    }
    fn close(&self) -> f64 {
        self.close
    }
    fn volume(&self) -> f64 {
        self.volume
    }
}

/// pole_x（1 分钟 K）落在哪个输入单元
pub fn pole_unit_idx(inputs: &[LevelUnitBar], pole_x: i32) -> Option<usize> {
    for (i, u) in inputs.iter().enumerate() {
        let a = u.x1.min(u.x2);
        let b = u.x1.max(u.x2);
        if pole_x >= a && pole_x <= b {
            return Some(i);
        }
    }
    None
}

/// [0..=pole_unit_idx] 内反向极值单元：TOP→low 最小首单元，BOTTOM→high 最大首单元
pub fn bootstrap_reverse_extreme_unit_idx(
    inputs: &[LevelUnitBar],
    pole_unit_idx: usize,
    fx: FxKind,
) -> Option<usize> {
    if inputs.is_empty() || pole_unit_idx >= inputs.len() {
        return None;
    }
    match fx {
        FxKind::Top => {
            let mut trough = f64::INFINITY;
            for j in 0..=pole_unit_idx {
                trough = trough.min(inputs[j].low);
            }
            for j in 0..=pole_unit_idx {
                if (inputs[j].low - trough).abs() < 1e-12 {
                    return Some(j);
                }
            }
        }
        FxKind::Bottom => {
            let mut peak = f64::NEG_INFINITY;
            for j in 0..=pole_unit_idx {
                peak = peak.max(inputs[j].high);
            }
            for j in 0..=pole_unit_idx {
                if (inputs[j].high - peak).abs() < 1e-12 {
                    return Some(j);
                }
            }
        }
        FxKind::Unknown => {}
    }
    None
}

/// 放宽审判：反向极值单元→极点单元合法即 PASS，返回 (virtual_idx, pole_unit_idx)
pub fn trial_first_segment(
    inputs: &[LevelUnitBar],
    pole_x: i32,
    fx: FxKind,
) -> Option<(usize, usize)> {
    if fx == FxKind::Unknown {
        return None;
    }
    let pole_i = pole_unit_idx(inputs, pole_x)?;
    let virtual_i = bootstrap_reverse_extreme_unit_idx(inputs, pole_i, fx)?;
    if virtual_i <= pole_i {
        Some((virtual_i, pole_i))
    } else {
        None
    }
}

/// 区间 OHLCV 聚合（输入单元序列）
pub fn aggregate_unit_range(
    inputs: &[LevelUnitBar],
    i: usize,
    j: usize,
) -> (f64, f64, f64, f64, f64) {
    if inputs.is_empty() {
        return (0.0, 0.0, 0.0, 0.0, 0.0);
    }
    let a = i.min(j).min(inputs.len() - 1);
    let b = i.max(j).min(inputs.len() - 1);
    let mut hi = f64::NEG_INFINITY;
    let mut lo = f64::INFINITY;
    let mut vol = 0.0;
    for u in &inputs[a..=b] {
        hi = hi.max(u.high);
        lo = lo.min(u.low);
        vol += u.volume;
    }
    (inputs[a].open, hi, lo, inputs[b].close, vol)
}

/// 首确认前 pending 占位：首输入单元 → 末输入单元
pub fn build_pending_default_unit(inputs: &[LevelUnitBar]) -> Option<LevelUnitBar> {
    if inputs.is_empty() {
        return None;
    }
    let first = &inputs[0];
    let last = &inputs[inputs.len() - 1];
    let dir = if last.close() >= first.open() {
        1
    } else {
        -1
    };
    let (open, high, low, close, vol) = aggregate_unit_range(inputs, 0, inputs.len() - 1);
    Some(LevelUnitBar {
        idx: 0,
        dir,
        x1: first.x1(),
        x2: last.x2(),
        open,
        high,
        low,
        close,
        volume: vol,
        confirm_x: last.x2(),
    })
}

/// 反向极值单元 → 1 分钟 K 极点（TOP 首确认取单元内 min low 首 K，BOTTOM 取 max high 首 K）
pub fn reverse_pole_x(bars: &[KlineBar], u: &LevelUnitBar, fx: FxKind) -> i32 {
    pole_x_in_range(
        bars,
        u.x1,
        u.x2,
        match fx {
            FxKind::Top => FxKind::Bottom,
            FxKind::Bottom => FxKind::Top,
            FxKind::Unknown => FxKind::Unknown,
        },
    )
}

/// 分型极点 1 分钟 K（与 pipeline::fx_pole_x 同语义，供首段模块自用）
pub fn pole_x_in_range(bars: &[KlineBar], x1: i32, x2: i32, fx: FxKind) -> i32 {
    let a = x1.max(0) as usize;
    let b = (x2.max(0) as usize).min(bars.len().saturating_sub(1));
    if bars.is_empty() || a > b {
        return x1.max(0);
    }
    match fx {
        FxKind::Top => {
            let mut peak = f64::NEG_INFINITY;
            for j in a..=b {
                peak = peak.max(bars[j].high);
            }
            for j in a..=b {
                if (bars[j].high - peak).abs() < 1e-12 {
                    return j as i32;
                }
            }
            a as i32
        }
        FxKind::Bottom => {
            let mut trough = f64::INFINITY;
            for j in a..=b {
                trough = trough.min(bars[j].low);
            }
            for j in a..=b {
                if (bars[j].low - trough).abs() < 1e-12 {
                    return j as i32;
                }
            }
            a as i32
        }
        FxKind::Unknown => a as i32,
    }
}

/// 由确认列推断层策略（末态导出用）
pub fn resolve_segment_policy(confirms: &[LevelConfirm], has_promoted: bool) -> String {
    let has_fx = confirms.iter().any(|c| c.fx == "TOP" || c.fx == "BOTTOM");
    if !has_fx {
        return POLICY_PENDING.to_string();
    }
    if has_promoted {
        POLICY_RETAINED.to_string()
    } else {
        POLICY_PURGED.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unit(idx: i64, x: i32, h: f64, l: f64) -> LevelUnitBar {
        LevelUnitBar {
            idx,
            dir: 0,
            x1: x,
            x2: x,
            open: l,
            high: h,
            low: l,
            close: h,
            volume: 1.0,
            confirm_x: x,
        }
    }

    #[test]
    fn trial_pass_on_valid_interval() {
        let inputs = vec![
            unit(0, 0, 10.0, 8.0),
            unit(1, 1, 9.0, 7.0),
            unit(2, 2, 11.0, 9.0),
        ];
        // TOP 极点在 K2(high=11)，反向极值单元 idx=1(low=7)
        assert!(trial_first_segment(&inputs, 2, FxKind::Top).is_some());
    }

    #[test]
    fn pending_default_unit_dir() {
        let inputs = vec![unit(0, 0, 10.0, 9.0), unit(1, 1, 11.0, 10.0)];
        let p = build_pending_default_unit(&inputs).unwrap();
        assert_eq!(p.dir, 1);
        assert_eq!(p.x1, 0);
        assert_eq!(p.x2, 1);
    }
}
