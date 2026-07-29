//! Kn buy1: isomorphic across levels. Trigger when current ZS box is entirely below previous.
//! Labels 1a/1b/... by low; lower low marks new 1a without rewriting; layer-first Kn skipped.

use serde::{Deserialize, Serialize};

use crate::pipeline::LevelSegment;
use crate::zs::ZS;

/// Buy1 marker for subchart / ML features.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Buy1Frame {
    pub seq: i32,
    /// Belonging ZS seq (aligned with zs_frames.seq).
    pub zs_seq: i32,
    /// Marker x (pole at Kn low).
    pub x: i32,
    pub price: f64,
    /// "1a" / "1b" / ...
    pub label: String,
    pub seg_idx: i64,
    pub level: i32,
}

#[inline]
fn approx_eq(a: f64, b: f64) -> bool {
    (a - b).abs() <= 1e-12
}

/// Suffix: 0->a, 1->b, ... (beyond z uses aa...).
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

/// Pole x at Kn low.
fn low_pole_x(s: &LevelSegment) -> i32 {
    if s.begin_fractal_low <= s.end_fractal_low + 1e-12 {
        s.begin_pole_x
    } else {
        s.end_pole_x
    }
}

/// Current ZS entirely below previous: curr.ZG < prev.ZD (ZG=high, ZD=low).
#[inline]
pub fn zs_below_prev(curr: &ZS, prev: &ZS) -> bool {
    curr.zg < prev.zd
}

/// Find buy1 on computed ZS list (no future; append-only labels).
pub fn find_buy1(zs_list: &[ZS], segs: &[LevelSegment], level: i32) -> Vec<Buy1Frame> {
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
        // Members in order; layer-first Kn (segs index 0) skipped.
        let mut letter_ord: Option<usize> = None;
        let mut prev_member_low: Option<f64> = None;
        for &mi in &curr.member_segs {
            if mi == 0 {
                continue;
            }
            if mi >= segs.len() {
                continue;
            }
            let s = &segs[mi];
            let low = s.low;
            let ord = match prev_member_low {
                None => 0usize,
                Some(pl) if approx_eq(low, pl) => letter_ord.unwrap_or(0) + 1,
                Some(pl) if low < pl => 0,
                Some(_) => letter_ord.unwrap_or(0) + 1,
            };
            letter_ord = Some(ord);
            prev_member_low = Some(low);
            out.push(Buy1Frame {
                seq,
                zs_seq: zi as i32,
                x: low_pole_x(s),
                price: low,
                label: format!("1{}", suffix_of(ord)),
                seg_idx: s.idx,
                level,
            });
            seq += 1;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::zs::{find_zs, ZSConfig};

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

    #[test]
    fn no_buy1_when_second_zs_not_below() {
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 22.0, 12.0),
            mk_seg(2, 1, 21.0, 11.0),
            mk_seg(3, 1, 40.0, 30.0),
            mk_seg(4, 1, 42.0, 32.0),
            mk_seg(5, 1, 41.0, 31.0),
        ];
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        assert!(zs.len() >= 2);
        assert!(zs[1].zg >= zs[0].zd);
        let b1 = find_buy1(&zs, &segs, 1);
        assert!(b1.is_empty());
    }

    #[test]
    fn buy1_when_current_zs_below_prev() {
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 22.0, 12.0),
            mk_seg(2, 1, 21.0, 11.0),
            mk_seg(3, 1, 8.0, 2.0),
            mk_seg(4, 1, 9.0, 3.0),
            mk_seg(5, 1, 7.0, 1.0),
        ];
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        assert!(zs.len() >= 2);
        assert!(zs_below_prev(&zs[1], &zs[0]));
        let b1 = find_buy1(&zs, &segs, 1);
        assert!(!b1.is_empty());
        assert!(b1.iter().all(|p| p.seg_idx != 0));
        assert_eq!(b1[0].label, "1a");
    }

    #[test]
    fn equal_lows_get_1a_1b_and_lower_new_1a_no_rewrite() {
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 15.0, 5.0),
            mk_seg(2, 1, 14.0, 5.0),
            mk_seg(3, 1, 13.0, 3.0),
        ];
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
            start_idx: 1,
            end_idx: 3,
            start_seg: 1,
            end_seg: 3,
            zg: 8.0,
            zd: 2.0,
            gg: 15.0,
            dd: 3.0,
            mid: 5.0,
            dir: 1,
            in_seg_idx: Some(0),
            out_seg_idx: None,
            is_sure: false,
            member_segs: vec![1, 2, 3],
        };
        let b1 = find_buy1(&[prev, curr], &segs, 1);
        assert_eq!(b1.len(), 3);
        assert_eq!(b1[0].label, "1a");
        assert_eq!(b1[0].price, 5.0);
        assert_eq!(b1[1].label, "1b");
        assert_eq!(b1[1].price, 5.0);
        assert_eq!(b1[2].label, "1a");
        assert_eq!(b1[2].price, 3.0);
        assert_eq!(b1[0].label, "1a");
        assert_eq!(b1[1].label, "1b");
    }

    #[test]
    fn layer_first_kn_never_labeled() {
        let segs = vec![
            mk_seg(0, 1, 8.0, 2.0),
            mk_seg(1, 1, 9.0, 3.0),
        ];
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
        let b1 = find_buy1(&[prev, curr], &segs, 0);
        assert_eq!(b1.len(), 1);
        assert_eq!(b1[0].seg_idx, 1);
        assert_eq!(b1[0].label, "1a");
    }
}