//! 全层通用首段策略：种子合并框（首元素=种子框，不与次元素包含合并）+ A→B 首段 + B→C 第二段。
//! 全层同构：K0合并 / K1合并 / Kn合并 共用同一引擎与首段逻辑。
//!
//! 关键例外（登记于 CHAN_RUST/README.md 历史记录）：本层产出 Kn 的前两个单元之间不做包含合并
//! （K1 层首两笔、K2 层首两段…各自独立）。此为该“种子框”设计的字面偏离“合并内核同构”，
//! 因用户明确“第二个 Kn 不再与第一个 Kn 做包含关系”；除首两单元外，其余包含合并与三元素分型
//! 判定全层一致。

use crate::engine::FxKind;
use crate::kline::KlineBar;
use crate::pipeline::LevelUnitBar;

/// 区间 OHLCV 聚合（输入单元序列）：开=首单元开，高/低=区间极值，收=末单元收，量=区间和
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

/// 分型极点 1 分钟 K（与 pipeline::fx_pole_x 同语义，供首段模块自用）：
/// TOP 取区间首个 high 极值 K，BOTTOM 取首个 low 极值 K
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

#[cfg(test)]
mod tests {
    use super::*;

    fn ubar(idx: i64, x: i32, h: f64, l: f64) -> LevelUnitBar {
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
    fn aggregate_unit_range_basic() {
        let inputs = vec![ubar(0, 0, 10.0, 8.0), ubar(1, 1, 11.0, 9.0)];
        let (o, hi, lo, c, v) = aggregate_unit_range(&inputs, 0, 1);
        assert!((o - 8.0).abs() < 1e-12);
        assert!((hi - 11.0).abs() < 1e-12);
        assert!((lo - 8.0).abs() < 1e-12);
        assert!((c - 11.0).abs() < 1e-12);
        assert!((v - 2.0).abs() < 1e-12);
    }
}
