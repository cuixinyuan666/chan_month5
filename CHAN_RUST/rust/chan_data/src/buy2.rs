//! Kn class-2 buy/sell (isomorphic all Kn): same ZS frames as class-1
//! (below/above prev). V2.1: after box extreme is established, only strict
//! higher lows (buy) or strict lower highs (sell) get 2Ba…/2Sa…; equal
//! extremes stay class-1 only (1Bb…/1Sb…). Running ref same as class-1.
//! When class-1 establishes or resets (new extreme), class-2 letter also resets to 2Ba/2Sa.
//! Active-unit mark x: if prior class-2 label exists in ZS, pin to begin_pole+1.
use crate::buy1::{zs_above_prev, zs_below_prev};
use crate::pipeline::LevelSegment;
use crate::zs::ZS;
use serde::{Deserialize, Serialize};

/// Buy2 marker for subchart / ML features.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Buy2Frame {
    pub seq: i32,
    pub zs_seq: i32,
    pub x: i32,
    pub price: f64,
    /// "2Ba" / "2Bb" / ...
    pub label: String,
    pub seg_idx: i64,
    pub level: i32,
}

/// Sell2 marker (same fields as Buy2Frame).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Sell2Frame {
    pub seq: i32,
    pub zs_seq: i32,
    pub x: i32,
    pub price: f64,
    /// "2Sa" / "2Sb" / ...
    pub label: String,
    pub seg_idx: i64,
    pub level: i32,
}

#[inline]
fn approx_eq(a: f64, b: f64) -> bool {
    (a - b).abs() <= 1e-12
}

fn suffix_of(ord: usize) -> String {
    if ord < 26 {
        return ((b'a' + ord as u8) as char).to_string();
    }
    let mut n = ord;
    let mut out = String::new();
    loop {
        out.insert(0, (b'a' + (n % 26) as u8) as char);
        if n < 26 {
            break;
        }
        n = n / 26 - 1;
    }
    out
}

fn low_pole_x(s: &LevelSegment) -> i32 {
    if s.begin_fractal_low <= s.end_fractal_low + 1e-12 {
        s.begin_pole_x
    } else {
        s.end_pole_x
    }
}

fn high_pole_x(s: &LevelSegment) -> i32 {
    if s.begin_fractal_high >= s.end_fractal_high - 1e-12 {
        s.begin_pole_x
    } else {
        s.end_pole_x
    }
}

fn mark_x(pole: i32, s: &LevelSegment, pin_active_body: bool) -> i32 {
    if pin_active_body && s.end_pole_x > s.begin_pole_x {
        return pole.max(s.begin_pole_x + 1);
    }
    pole.max(s.end_pole_x)
}

pub fn find_buy2(zs_list: &[ZS], segs: &[LevelSegment], level: i32) -> Vec<Buy2Frame> {
    find_buy2_with_active(zs_list, segs, level, None)
}

/// Same ZS as class-1; only strict higher lows as 2Ba… (equal/new low skip).
pub fn find_buy2_with_active(
    zs_list: &[ZS],
    segs: &[LevelSegment],
    level: i32,
    active_idx: Option<i64>,
) -> Vec<Buy2Frame> {
    let mut out = Vec::new();
    if zs_list.len() < 2 || segs.is_empty() {
        return out;
    }
    let mut seq = 0i32;
    for zi in 1..zs_list.len() {
        let prev = &zs_list[zi - 1];
        let curr = &zs_list[zi];
        if !zs_below_prev(curr, prev) {
            continue;
        }
        // 与一类同框同序维护已见最低；建框/新低/等高归一类，仅更高低点标二类。
        let mut letter_ord: Option<usize> = None;
        let mut box_min_low: Option<f64> = None;
        for &mi in &curr.member_segs {
            if mi == 0 {
                continue;
            }
            if mi >= segs.len() {
                continue;
            }
            let s = &segs[mi];
            let low = s.low;
            match box_min_low {
                None => {
                    // 建框：一类占用，刷新参照；重置二类字母序（后续从 2Ba 起）
                    box_min_low = Some(low);
                    letter_ord = None;
                }
                Some(bmin) if low < bmin && !approx_eq(low, bmin) => {
                    // 新低：一类占用，刷新参照；重置二类字母序
                    box_min_low = Some(low);
                    letter_ord = None;
                }
                Some(bmin) if approx_eq(low, bmin) => {
                    // 等高：一类 1Bb…，不产生二类
                    let _ = bmin;
                    continue;
                }
                Some(bmin) => {
                    // 严格更高低点 → 二类（参照不抬）
                    debug_assert!(low > bmin);
                    let _ = bmin;
                    let prior_labeled_in_zs = letter_ord.is_some();
                    let ord = letter_ord.map(|o| o + 1).unwrap_or(0);
                    letter_ord = Some(ord);
                    let pin = active_idx == Some(s.idx) && prior_labeled_in_zs;
                    out.push(Buy2Frame {
                        seq,
                        zs_seq: zi as i32,
                        x: mark_x(low_pole_x(s), s, pin),
                        price: low,
                        label: format!("2B{}", suffix_of(ord)),
                        seg_idx: s.idx,
                        level,
                    });
                    seq += 1;
                }
            }
        }
    }
    out
}

pub fn find_sell2(zs_list: &[ZS], segs: &[LevelSegment], level: i32) -> Vec<Sell2Frame> {
    find_sell2_with_active(zs_list, segs, level, None)
}

/// Sell2 mirror: only strict lower highs → 2Sa…; equal/new high stay class-1.
pub fn find_sell2_with_active(
    zs_list: &[ZS],
    segs: &[LevelSegment],
    level: i32,
    active_idx: Option<i64>,
) -> Vec<Sell2Frame> {
    let mut out = Vec::new();
    if zs_list.len() < 2 || segs.is_empty() {
        return out;
    }
    let mut seq = 0i32;
    for zi in 1..zs_list.len() {
        let prev = &zs_list[zi - 1];
        let curr = &zs_list[zi];
        if !zs_above_prev(curr, prev) {
            continue;
        }
        let mut letter_ord: Option<usize> = None;
        let mut box_max_high: Option<f64> = None;
        for &mi in &curr.member_segs {
            if mi == 0 {
                continue;
            }
            if mi >= segs.len() {
                continue;
            }
            let s = &segs[mi];
            let high = s.high;
            match box_max_high {
                None => {
                    // 建框：一类占用；重置二类字母序
                    box_max_high = Some(high);
                    letter_ord = None;
                }
                Some(bmax) if high > bmax && !approx_eq(high, bmax) => {
                    // 新高：一类占用；重置二类字母序
                    box_max_high = Some(high);
                    letter_ord = None;
                }
                Some(bmax) if approx_eq(high, bmax) => {
                    // 等高：一类 1Sb…，不产生二类
                    let _ = bmax;
                    continue;
                }
                Some(bmax) => {
                    debug_assert!(high < bmax);
                    let _ = bmax;
                    let prior_labeled_in_zs = letter_ord.is_some();
                    let ord = letter_ord.map(|o| o + 1).unwrap_or(0);
                    letter_ord = Some(ord);
                    let pin = active_idx == Some(s.idx) && prior_labeled_in_zs;
                    out.push(Sell2Frame {
                        seq,
                        zs_seq: zi as i32,
                        x: mark_x(high_pole_x(s), s, pin),
                        price: high,
                        label: format!("2S{}", suffix_of(ord)),
                        seg_idx: s.idx,
                        level,
                    });
                    seq += 1;
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::buy1::{find_buy1, find_sell1};
    use crate::pipeline::LevelSegment;

    fn mk_seg(idx: i64, dir: i32, high: f64, low: f64) -> LevelSegment {
        LevelSegment {
            idx,
            dir,
            begin_confirm_x: idx as i32,
            end_confirm_x: idx as i32,
            begin_pole_x: idx as i32,
            end_pole_x: idx as i32,
            open: low,
            high,
            low,
            close: high,
            volume: 0.0,
            begin_fractal_x1: idx as i32,
            begin_fractal_x2: idx as i32,
            end_fractal_x1: idx as i32,
            end_fractal_x2: idx as i32,
            begin_fractal_high: high,
            begin_fractal_low: low,
            end_fractal_high: high,
            end_fractal_low: low,
            is_bootstrap: false,
            is_promoted_default: false,
        }
    }

    fn below_pair(members: Vec<usize>) -> (ZS, ZS) {
        let prev = ZS {
            level: 1,
            start_idx: 0,
            end_idx: 0,
            start_seg: 0,
            end_seg: 0,
            zg: 20.0,
            zd: 12.0,
            gg: 20.0,
            dd: 10.0,
            mid: 16.0,
            dir: 1,
            in_seg_idx: None,
            out_seg_idx: Some(1),
            is_sure: true,
            member_segs: vec![0],
        };
        let curr = ZS {
            level: 1,
            start_idx: *members.first().unwrap_or(&1) as i64,
            end_idx: *members.last().unwrap_or(&1) as i64,
            start_seg: *members.first().unwrap_or(&1),
            end_seg: *members.last().unwrap_or(&1),
            zg: 8.0,
            zd: 2.0,
            gg: 16.0,
            dd: 3.0,
            mid: 5.0,
            dir: 1,
            in_seg_idx: Some(0),
            out_seg_idx: None,
            is_sure: false,
            member_segs: members,
        };
        (prev, curr)
    }

    fn above_pair(members: Vec<usize>) -> (ZS, ZS) {
        let prev = ZS {
            level: 1,
            start_idx: 0,
            end_idx: 0,
            start_seg: 0,
            end_seg: 0,
            zg: 8.0,
            zd: 2.0,
            gg: 10.0,
            dd: 2.0,
            mid: 5.0,
            dir: 1,
            in_seg_idx: None,
            out_seg_idx: Some(1),
            is_sure: true,
            member_segs: vec![0],
        };
        let curr = ZS {
            level: 1,
            start_idx: *members.first().unwrap_or(&1) as i64,
            end_idx: *members.last().unwrap_or(&1) as i64,
            start_seg: *members.first().unwrap_or(&1),
            end_seg: *members.last().unwrap_or(&1),
            zg: 30.0,
            zd: 15.0,
            gg: 25.0,
            dd: 10.0,
            mid: 22.5,
            dir: 1,
            in_seg_idx: Some(0),
            out_seg_idx: None,
            is_sure: false,
            member_segs: members,
        };
        (prev, curr)
    }

    #[test]
    fn v21_acceptance_buy_side_no_dual_label_at_equal() {
        // 100→1Ba/1Bb/1Bc；101→2Ba；102→2Bb；99→1Ba/1Bb；100→2Ba；同价禁止 1B*+2B* 双标
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 15.0, 100.0),
            mk_seg(2, 1, 14.0, 100.0),
            mk_seg(3, 1, 13.0, 100.0),
            mk_seg(4, 1, 16.0, 101.0),
            mk_seg(5, 1, 17.0, 102.0),
            mk_seg(6, 1, 12.0, 99.0),
            mk_seg(7, 1, 11.0, 99.0),
            mk_seg(8, 1, 14.0, 100.0),
        ];
        let (prev, curr) = below_pair(vec![1, 2, 3, 4, 5, 6, 7, 8]);
        let zs = [prev, curr];
        let b1 = find_buy1(&zs, &segs, 1);
        let b2 = find_buy2(&zs, &segs, 1);
        assert_eq!(
            b1.iter().map(|p| p.label.as_str()).collect::<Vec<_>>(),
            vec!["1Ba", "1Bb", "1Bc", "1Ba", "1Bb"]
        );
        assert_eq!(
            b2.iter().map(|p| p.label.as_str()).collect::<Vec<_>>(),
            vec!["2Ba", "2Bb", "2Ba"]
        );
        for mi in 1..=8 {
            let has_c1 = b1.iter().any(|p| p.seg_idx == mi as i64);
            let has_c2 = b2.iter().any(|p| p.seg_idx == mi as i64);
            assert!(
                !(has_c1 && has_c2),
                "seg {mi} must not have both class-1 and class-2"
            );
        }
    }

    #[test]
    fn v21_acceptance_sell_side_no_dual_label_at_equal() {
        // 卖侧镜像：100→1Sa/b/c；99→2Sa；98→2Sb；103→1Sa/b；102→2Sa
        let segs = vec![
            mk_seg(0, 1, 10.0, 2.0),
            mk_seg(1, 1, 100.0, 10.0),
            mk_seg(2, 1, 100.0, 11.0),
            mk_seg(3, 1, 100.0, 12.0),
            mk_seg(4, 1, 99.0, 13.0),
            mk_seg(5, 1, 98.0, 14.0),
            mk_seg(6, 1, 103.0, 15.0),
            mk_seg(7, 1, 103.0, 16.0),
            mk_seg(8, 1, 102.0, 17.0),
        ];
        let (prev, curr) = above_pair(vec![1, 2, 3, 4, 5, 6, 7, 8]);
        let zs = [prev, curr];
        let s1 = find_sell1(&zs, &segs, 1);
        let s2 = find_sell2(&zs, &segs, 1);
        assert_eq!(
            s1.iter().map(|p| p.label.as_str()).collect::<Vec<_>>(),
            vec!["1Sa", "1Sb", "1Sc", "1Sa", "1Sb"]
        );
        assert_eq!(
            s2.iter().map(|p| p.label.as_str()).collect::<Vec<_>>(),
            vec!["2Sa", "2Sb", "2Sa"]
        );
        for mi in 1..=8 {
            let has_c1 = s1.iter().any(|p| p.seg_idx == mi as i64);
            let has_c2 = s2.iter().any(|p| p.seg_idx == mi as i64);
            assert!(
                !(has_c1 && has_c2),
                "seg {mi} must not have both class-1 and class-2"
            );
        }
    }

    #[test]
    fn higher_low_only_gets_buy2_equal_low_class1_only() {
        // V2.1：等高归一类 1Bb；更高低点才标二类
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 15.0, 5.0),  // 1Ba 建框
            mk_seg(2, 1, 14.0, 5.0),  // 等高 → 1Bb（非二类）
            mk_seg(3, 1, 16.0, 6.0),  // 更高 → 2Ba
            mk_seg(4, 1, 13.0, 3.0),  // 新低 → 一类 1Ba（复位）
            mk_seg(5, 1, 12.0, 4.0),  // 高于新低 → 二类从 2Ba 重起
        ];
        let (prev, curr) = below_pair(vec![1, 2, 3, 4, 5]);
        let zs = [prev, curr];
        let b1 = find_buy1(&zs, &segs, 1);
        let b2 = find_buy2(&zs, &segs, 1);
        assert_eq!(b1.len(), 3);
        assert_eq!(b1[0].seg_idx, 1);
        assert_eq!(b1[1].seg_idx, 2);
        assert_eq!(b1[1].label, "1Bb");
        assert_eq!(b1[2].seg_idx, 4);
        assert_eq!(b1[2].label, "1Ba");
        assert_eq!(b2.len(), 2);
        assert_eq!(b2[0].label, "2Ba");
        assert_eq!(b2[0].seg_idx, 3);
        assert_eq!(b2[1].label, "2Ba");
        assert_eq!(b2[1].seg_idx, 5);
    }

    #[test]
    fn higher_low_only_gets_buy2() {
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 15.0, 5.0),
            mk_seg(2, 1, 16.0, 6.0),
            mk_seg(3, 1, 14.0, 4.0),
        ];
        let (prev, curr) = below_pair(vec![1, 2, 3]);
        let zs = [prev, curr];
        let b1 = find_buy1(&zs, &segs, 1);
        let b2 = find_buy2(&zs, &segs, 1);
        assert_eq!(b1.len(), 2);
        assert_eq!(b2.len(), 1);
        assert_eq!(b2[0].seg_idx, 2);
        assert_eq!(b2[0].label, "2Ba");
        assert_eq!(b2[0].price, 6.0);
    }

    #[test]
    fn skip_higher_does_not_raise_ref_for_buy2() {
        // 框最低=5；跳过 6 后 5.5 仍高于参照 → 仍标二类（参照不抬到 6）
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 15.0, 5.0),
            mk_seg(2, 1, 16.0, 6.0),
            mk_seg(3, 1, 14.0, 5.5),
        ];
        let (prev, curr) = below_pair(vec![1, 2, 3]);
        let b2 = find_buy2(&[prev, curr], &segs, 1);
        assert_eq!(b2.len(), 2);
        assert_eq!(b2[0].price, 6.0);
        assert_eq!(b2[1].price, 5.5);
        assert_eq!(b2[0].label, "2Ba");
        assert_eq!(b2[1].label, "2Bb");
    }

    #[test]
    fn sell2_lower_high_only_equal_goes_class1() {
        let segs = vec![
            mk_seg(0, 1, 10.0, 2.0),
            mk_seg(1, 1, 20.0, 10.0), // 1Sa 建框
            mk_seg(2, 1, 20.0, 11.0), // 等高 → 1Sb
            mk_seg(3, 1, 18.0, 9.0),  // 更低 → 2Sa
            mk_seg(4, 1, 25.0, 12.0), // 新高 → 一类 1Sa（复位）
            mk_seg(5, 1, 22.0, 10.0), // 低于新高 → 二类从 2Sa 重起
        ];
        let (prev, curr) = above_pair(vec![1, 2, 3, 4, 5]);
        let zs = [prev, curr];
        let s1 = find_sell1(&zs, &segs, 1);
        let s2 = find_sell2(&zs, &segs, 1);
        assert_eq!(s1.len(), 3);
        assert_eq!(s1[0].seg_idx, 1);
        assert_eq!(s1[0].label, "1Sa");
        assert_eq!(s1[1].seg_idx, 2);
        assert_eq!(s1[1].label, "1Sb");
        assert_eq!(s1[2].seg_idx, 4);
        assert_eq!(s1[2].label, "1Sa");
        assert_eq!(s2.len(), 2);
        assert_eq!(s2[0].label, "2Sa");
        assert_eq!(s2[0].seg_idx, 3);
        assert_eq!(s2[1].label, "2Sa");
        assert_eq!(s2[1].seg_idx, 5);
    }

    #[test]
    fn layer_first_kn_never_labeled_buy2() {
        let segs = vec![mk_seg(0, 1, 8.0, 2.0), mk_seg(1, 1, 9.0, 4.0)];
        let prev = ZS {
            level: 0,
            start_idx: 99,
            end_idx: 99,
            start_seg: 0,
            end_seg: 0,
            zg: 20.0,
            zd: 12.0,
            gg: 20.0,
            dd: 12.0,
            mid: 16.0,
            dir: 1,
            in_seg_idx: None,
            out_seg_idx: None,
            is_sure: true,
            member_segs: vec![],
        };
        let curr = ZS {
            level: 0,
            start_idx: 0,
            end_idx: 1,
            start_seg: 0,
            end_seg: 1,
            zg: 8.0,
            zd: 2.0,
            gg: 9.0,
            dd: 2.0,
            mid: 5.0,
            dir: 1,
            in_seg_idx: None,
            out_seg_idx: None,
            is_sure: false,
            member_segs: vec![0, 1],
        };
        // mi0 跳过；mi1 建立框最低 → 一类；无二类
        let b2 = find_buy2(&[prev.clone(), curr.clone()], &segs, 0);
        assert!(b2.is_empty());
        let b1 = find_buy1(&[prev, curr], &segs, 0);
        assert_eq!(b1.len(), 1);
        assert_eq!(b1[0].seg_idx, 1);
    }

    #[test]
    fn active_pin_begin_plus_one_buy2() {
        let mut segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 15.0, 5.0),
            mk_seg(2, 1, 16.0, 6.0),
        ];
        // active 段身延伸：begin=2 end=10，low 极点在 begin
        segs[2].begin_pole_x = 2;
        segs[2].end_pole_x = 10;
        segs[2].begin_fractal_low = 6.0;
        segs[2].end_fractal_low = 7.0;
        let (prev, curr) = below_pair(vec![1, 2]);
        // 先有一颗 2Ba 再 active 同框第二颗时才钉；这里仅一颗 2Ba 无 prior → 不钉
        let b2 = find_buy2_with_active(&[prev.clone(), curr.clone()], &segs, 1, Some(2));
        assert_eq!(b2.len(), 1);
        assert_eq!(b2[0].x, 10); // max(pole=2, end=10)

        // 两颗二类且第二颗 active：钉 begin+1
        let mut segs2 = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 15.0, 5.0),
            mk_seg(2, 1, 16.0, 6.0),
            mk_seg(3, 1, 14.0, 5.5),
        ];
        segs2[3].begin_pole_x = 3;
        segs2[3].end_pole_x = 12;
        segs2[3].begin_fractal_low = 5.5;
        segs2[3].end_fractal_low = 6.0;
        let (prev2, curr2) = below_pair(vec![1, 2, 3]);
        let b2b = find_buy2_with_active(&[prev2, curr2], &segs2, 1, Some(3));
        assert_eq!(b2b.len(), 2);
        assert_eq!(b2b[1].seg_idx, 3);
        assert_eq!(b2b[1].x, 4); // pin begin+1
    }
}
