//! Kn class-1 buy/sell (isomorphic all Kn): ZS below prev -> buy; above -> sell.
//!
//! == 方案A 一类/二类分工 ==
//! 同一资格中枢框内，一类仅负责「建框」与「严格新极值」：
//!   - 建框（box_min_low / box_max_high 首次赋值）→ 1Ba / 1Sa
//!   - 严格新低（买）/ 严格新高（卖）→ 重置字母为 1Ba / 1Sa
//!   - 等高或更弱 → 不标（交由 buy2.rs 标 2Ba…/2Sa…）
//! 运行参照（box_min_low / box_max_high）由一类更新，二类只读共享。
//! 两类均遵守「跳过时不抬高/压低参照」。
//! == 打点规则（与二类同构）==
//! Active-unit mark x: if prior label exists in ZS, pin to begin_pole+1 (no walk).
//! Flutter display (pitfall): Rust may still emit on active extend; UI must append
//! K0-granular history (key includes x), not dedupe only by level|seg|label.
use crate::pipeline::LevelSegment;
use crate::zs::ZS;
use serde::{Deserialize, Serialize};
/// Buy1 marker for subchart / ML features.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Buy1Frame {
    pub seq: i32,
    /// Belonging ZS seq (aligned with zs_frames.seq).
    pub zs_seq: i32,
    /// Marker x (pole at Kn low).
    pub x: i32,
    pub price: f64,
    /// "1Ba" / "1Bb" / ...
    pub label: String,
    pub seg_idx: i64,
    pub level: i32,
}
/// Sell1 marker (same fields as Buy1Frame).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Sell1Frame {
    pub seq: i32,
    pub zs_seq: i32,
    /// Marker x (pole at Kn high).
    pub x: i32,
    pub price: f64,
    /// "1Sa" / "1Sb" / ...
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
/// Pole x at Kn high.
fn high_pole_x(s: &LevelSegment) -> i32 {
    if s.begin_fractal_high >= s.end_fractal_high - 1e-12 {
        s.begin_pole_x
    } else {
        s.end_pole_x
    }
}
/// mark x = max(pole, end_pole): no back-write to begin pole before judgment is knowable.
/// When active + prior label already in this ZS: pin to begin_pole+1 (first body), do not walk with end.
fn mark_x(pole: i32, s: &LevelSegment, pin_active_body: bool) -> i32 {
    if pin_active_body && s.end_pole_x > s.begin_pole_x {
        return pole.max(s.begin_pole_x + 1);
    }
    pole.max(s.end_pole_x)
}
/// Current ZS entirely below previous: curr.ZG < prev.ZD.
#[inline]
pub fn zs_below_prev(curr: &ZS, prev: &ZS) -> bool {
    curr.zg < prev.zd
}
/// Current ZS entirely above previous: curr.ZD > prev.ZG (buy1 mirror).
#[inline]
pub fn zs_above_prev(curr: &ZS, prev: &ZS) -> bool {
    curr.zd > prev.zg
}
/// Find buy1 on computed ZS list (no future; append-only labels).
pub fn find_buy1(zs_list: &[ZS], segs: &[LevelSegment], level: i32) -> Vec<Buy1Frame> {
    find_buy1_with_active(zs_list, segs, level, None)
}
/// Same as find_buy1; `active_idx` pins mark x on growing active unit.
pub fn find_buy1_with_active(
    zs_list: &[ZS],
    segs: &[LevelSegment],
    level: i32,
    active_idx: Option<i64>,
) -> Vec<Buy1Frame> {
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
        // box_min_low = 本中枢框已见最低；仅建框/新低标一类；等高/更高交给二类。
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
            // 已有参照且非严格新低 → 不标一类（参照不抬）
            if let Some(bmin) = box_min_low {
                if low > bmin || approx_eq(low, bmin) {
                    continue;
                }
            }
            let prior_labeled_in_zs = letter_ord.is_some();
            // 建框或新低：重置字母为 1Ba
            let ord = 0usize;
            letter_ord = Some(ord);
            box_min_low = Some(low);
            let pin = active_idx == Some(s.idx) && prior_labeled_in_zs;
            out.push(Buy1Frame {
                seq,
                zs_seq: zi as i32,
                x: mark_x(low_pole_x(s), s, pin),
                price: low,
                label: format!("1B{}", suffix_of(ord)),
                seg_idx: s.idx,
                level,
            });
            seq += 1;
        }
    }
    out
}
/// Find sell1 (buy1 mirror: highs, ZS above prev).
pub fn find_sell1(zs_list: &[ZS], segs: &[LevelSegment], level: i32) -> Vec<Sell1Frame> {
    find_sell1_with_active(zs_list, segs, level, None)
}
/// Same as find_sell1; `active_idx` pins mark x on growing active unit.
pub fn find_sell1_with_active(
    zs_list: &[ZS],
    segs: &[LevelSegment],
    level: i32,
    active_idx: Option<i64>,
) -> Vec<Sell1Frame> {
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
        // box_max_high = 本中枢框已见最高；仅建框/新高标一类；等高/更低交给二类。
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
            // 已有参照且非严格新高 → 不标一类（参照不压）
            if let Some(bmax) = box_max_high {
                if high < bmax || approx_eq(high, bmax) {
                    continue;
                }
            }
            let prior_labeled_in_zs = letter_ord.is_some();
            let ord = 0usize;
            letter_ord = Some(ord);
            box_max_high = Some(high);
            let pin = active_idx == Some(s.idx) && prior_labeled_in_zs;
            out.push(Sell1Frame {
                seq,
                zs_seq: zi as i32,
                x: mark_x(high_pole_x(s), s, pin),
                price: high,
                label: format!("1S{}", suffix_of(ord)),
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
        assert_eq!(b1[0].label, "1Ba");
    }
    #[test]
    fn equal_low_not_class1_new_low_resets_1ba() {
        // 方案A：等高不再标一类（交给二类）；新低仍 1Ba
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
        assert_eq!(b1.len(), 2);
        assert_eq!(b1[0].label, "1Ba");
        assert_eq!(b1[0].price, 5.0);
        assert_eq!(b1[0].seg_idx, 1);
        assert_eq!(b1[1].label, "1Ba");
        assert_eq!(b1[1].price, 3.0);
        assert_eq!(b1[1].seg_idx, 3);
        assert!(b1.iter().all(|p| p.seg_idx != 2));
    }
    #[test]
    fn higher_low_in_same_zs_not_labeled() {
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 15.0, 5.0),
            mk_seg(2, 1, 16.0, 6.0),
            mk_seg(3, 1, 14.0, 4.0),
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
            gg: 16.0,
            dd: 4.0,
            mid: 5.0,
            dir: 1,
            in_seg_idx: Some(0),
            out_seg_idx: None,
            is_sure: false,
            member_segs: vec![1, 2, 3],
        };
        let b1 = find_buy1(&[prev, curr], &segs, 1);
        assert_eq!(b1.len(), 2);
        assert_eq!(b1[0].seg_idx, 1);
        assert_eq!(b1[0].label, "1Ba");
        assert_eq!(b1[1].seg_idx, 3);
        assert_eq!(b1[1].label, "1Ba");
        assert!(b1.iter().all(|p| p.seg_idx != 2));
    }
    #[test]
    fn layer_first_kn_never_labeled() {
        let segs = vec![mk_seg(0, 1, 8.0, 2.0), mk_seg(1, 1, 9.0, 3.0)];
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
        assert_eq!(b1[0].label, "1Ba");
    }
    #[test]
    fn sell1_when_current_zs_above_prev() {
        let segs = vec![
            mk_seg(0, 1, 10.0, 2.0),
            mk_seg(1, 1, 12.0, 3.0),
            mk_seg(2, 1, 11.0, 2.5),
            mk_seg(3, 1, 40.0, 30.0),
            mk_seg(4, 1, 42.0, 31.0),
            mk_seg(5, 1, 41.0, 30.5),
        ];
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        assert!(zs.len() >= 2);
        if zs_above_prev(&zs[1], &zs[0]) {
            let s1 = find_sell1(&zs, &segs, 1);
            assert!(!s1.is_empty());
            assert!(s1.iter().all(|p| p.seg_idx != 0));
            assert!(s1[0].label.starts_with("1S"));
        }
    }
    #[test]
    fn equal_high_not_class1_new_high_resets_1sa() {
        // 方案A：等高不再标一类（交给二类）；新高仍 1Sa
        let segs = vec![
            mk_seg(0, 1, 10.0, 2.0),
            mk_seg(1, 1, 20.0, 10.0),
            mk_seg(2, 1, 20.0, 11.0),
            mk_seg(3, 1, 25.0, 12.0),
        ];
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
            start_idx: 1,
            end_idx: 3,
            start_seg: 1,
            end_seg: 3,
            zg: 30.0,
            zd: 15.0,
            gg: 25.0,
            dd: 10.0,
            mid: 22.5,
            dir: 1,
            in_seg_idx: Some(0),
            out_seg_idx: None,
            is_sure: false,
            member_segs: vec![1, 2, 3],
        };
        assert!(zs_above_prev(&curr, &prev));
        let s1 = find_sell1(&[prev, curr], &segs, 1);
        assert_eq!(s1.len(), 2);
        assert_eq!(s1[0].label, "1Sa");
        assert_eq!(s1[0].price, 20.0);
        assert_eq!(s1[0].seg_idx, 1);
        assert_eq!(s1[1].label, "1Sa");
        assert_eq!(s1[1].price, 25.0);
        assert_eq!(s1[1].seg_idx, 3);
        assert!(s1.iter().all(|p| p.seg_idx != 2));
    }
    #[test]
    fn lower_high_in_same_zs_not_labeled_sell() {
        let segs = vec![
            mk_seg(0, 1, 10.0, 2.0),
            mk_seg(1, 1, 20.0, 10.0),
            mk_seg(2, 1, 18.0, 11.0),
            mk_seg(3, 1, 22.0, 12.0),
        ];
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
            start_idx: 1,
            end_idx: 3,
            start_seg: 1,
            end_seg: 3,
            zg: 30.0,
            zd: 15.0,
            gg: 22.0,
            dd: 10.0,
            mid: 22.5,
            dir: 1,
            in_seg_idx: Some(0),
            out_seg_idx: None,
            is_sure: false,
            member_segs: vec![1, 2, 3],
        };
        let s1 = find_sell1(&[prev, curr], &segs, 1);
        assert_eq!(s1.len(), 2);
        assert_eq!(s1[0].seg_idx, 1);
        assert_eq!(s1[0].label, "1Sa");
        assert_eq!(s1[1].seg_idx, 3);
        assert_eq!(s1[1].label, "1Sa");
        assert!(s1.iter().all(|p| p.seg_idx != 2));
    }
    #[test]
    fn layer_first_kn_never_labeled_sell() {
        let segs = vec![mk_seg(0, 1, 20.0, 10.0), mk_seg(1, 1, 22.0, 11.0)];
        let prev = ZS {
            level: 0,
            start_idx: 99,
            end_idx: 99,
            start_seg: 0,
            end_seg: 0,
            zg: 8.0,
            zd: 2.0,
            gg: 8.0,
            dd: 2.0,
            mid: 5.0,
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
            zg: 30.0,
            zd: 15.0,
            gg: 22.0,
            dd: 10.0,
            mid: 22.5,
            dir: 1,
            in_seg_idx: None,
            out_seg_idx: None,
            is_sure: false,
            member_segs: vec![0, 1],
        };
        let s1 = find_sell1(&[prev, curr], &segs, 0);
        assert_eq!(s1.len(), 1);
        assert_eq!(s1[0].seg_idx, 1);
        assert_eq!(s1[0].label, "1Sa");
    }
    /// 002003: at idx=24, sell1 x must be discovery step 24 (not begin pole 21)
    #[test]
    fn sell1_x_is_discovery_step_not_begin_pole_002003() {
        use crate::combine::build_kline_combine_bundle;
        let data_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../a_Data");
        if !data_root.join("002003").exists() {
            eprintln!("skip: a_Data/002003 missing");
            return;
        }
        let root = crate::resolve_data_root(Some(data_root.to_str().unwrap()));
        let bars = crate::load_klines(
            &root,
            "002003",
            "2004/07/19 10:47:00",
            "2004/07/20 13:09:00",
            crate::KlinePeriod::M1,
        )
        .expect("load 002003");
        assert!(bars.len() > 24);
        let at21 = build_kline_combine_bundle(&bars[..=21]);
        // 方案B：K0连线层 structure.level==0；帧上 level 仍为显示中枢号 1
        let k1_21 = at21.levels.iter().find(|l| l.level == 0).unwrap();
        assert!(
            k1_21.zs_frames.len() < 2 || k1_21.sell1_frames.is_empty(),
            "idx=21 must not yet emit K1 sell1"
        );
        let at24 = build_kline_combine_bundle(&bars[..=24]);
        let k1_24 = at24.levels.iter().find(|l| l.level == 0).unwrap();
        assert_eq!(k1_24.zs_frames.len(), 2);
        assert_eq!(k1_24.sell1_frames.len(), 1);
        assert_eq!(k1_24.sell1_frames[0].label, "1Sa");
        assert_eq!(
            k1_24.sell1_frames[0].x, 24,
            "sell x must be discovery step, not begin pole 21"
        );
    }
    /// 同枢：跳过低于框最高后，再遇仅等于跳过价（仍低于框最高）→ 仍不标。
    #[test]
    fn after_lower_high_equal_to_skip_still_below_box_max_not_labeled() {
        let segs = vec![
            mk_seg(0, 1, 10.0, 2.0),
            mk_seg(1, -1, 20.0, 10.0), // 1Sa，框最高=20
            mk_seg(2, 1, 18.0, 11.0),  // 低于框最高：跳过
            mk_seg(3, -1, 18.0, 9.0),  // 仍低于框最高：不标
        ];
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
            start_idx: 1,
            end_idx: 3,
            start_seg: 1,
            end_seg: 3,
            zg: 30.0,
            zd: 15.0,
            gg: 20.0,
            dd: 9.0,
            mid: 22.5,
            dir: 1,
            in_seg_idx: Some(0),
            out_seg_idx: None,
            is_sure: false,
            member_segs: vec![1, 2, 3],
        };
        let s1 = find_sell1(&[prev, curr], &segs, 1);
        assert_eq!(s1.len(), 1);
        assert_eq!(s1[0].seg_idx, 1);
        assert_eq!(s1[0].label, "1Sa");
    }
    /// 同枢：跳过低于框最高后回到框最高 → 等高不再标一类（交给二类）。
    #[test]
    fn after_lower_high_return_to_box_max_not_class1() {
        let segs = vec![
            mk_seg(0, 1, 10.0, 2.0),
            mk_seg(1, -1, 20.0, 10.0), // 1Sa
            mk_seg(2, 1, 18.0, 11.0),  // skip / class2
            mk_seg(3, -1, 20.0, 9.0),  // 等高 → 非一类
        ];
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
            start_idx: 1,
            end_idx: 3,
            start_seg: 1,
            end_seg: 3,
            zg: 30.0,
            zd: 15.0,
            gg: 20.0,
            dd: 9.0,
            mid: 22.5,
            dir: 1,
            in_seg_idx: Some(0),
            out_seg_idx: None,
            is_sure: false,
            member_segs: vec![1, 2, 3],
        };
        let s1 = find_sell1(&[prev, curr], &segs, 1);
        assert_eq!(s1.len(), 1);
        assert_eq!(s1[0].seg_idx, 1);
        assert_eq!(s1[0].label, "1Sa");
    }
    /// 同枢买：跳过更高低后，中间价仍高于框最低 → 不标（禁止旧逻辑把参照抬到跳过价）。
    #[test]
    fn mid_low_above_box_min_not_labeled_after_higher_skip() {
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 15.0, 5.0), // 1Ba，框最低=5
            mk_seg(2, 1, 16.0, 6.0), // 更高低：跳过
            mk_seg(3, 1, 14.0, 5.5), // 仍高于框最低：不标
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
            gg: 16.0,
            dd: 5.0,
            mid: 5.0,
            dir: 1,
            in_seg_idx: Some(0),
            out_seg_idx: None,
            is_sure: false,
            member_segs: vec![1, 2, 3],
        };
        let b1 = find_buy1(&[prev, curr], &segs, 1);
        assert_eq!(b1.len(), 1);
        assert_eq!(b1[0].seg_idx, 1);
        assert_eq!(b1[0].label, "1Ba");
        assert_eq!(b1[0].price, 5.0);
    }
    /// 002003: step25 no new sell; step26/27 以框最高口径验收（见运行结果）。
    #[test]
    fn sell1_002003_step25_no_new_step26_1sa_step27_keeps() {
        use crate::combine::build_kline_combine_bundle;
        let data_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../a_Data");
        if !data_root.join("002003").exists() {
            eprintln!("skip: a_Data/002003 missing");
            return;
        }
        let root = crate::resolve_data_root(Some(data_root.to_str().unwrap()));
        let bars = crate::load_klines(
            &root,
            "002003",
            "2004/07/19 10:47:00",
            "2004/07/20 13:09:00",
            crate::KlinePeriod::M1,
        )
        .expect("load 002003");
        assert!(bars.len() > 27);
        let at25 = build_kline_combine_bundle(&bars[..=25]);
        let k1_25 = at25.levels.iter().find(|l| l.level == 0).unwrap();
        let act25 = k1_25.active_unit.as_ref().expect("step25 active");
        assert_eq!(act25.dir, 1, "idx=25 active is up: no new sell");
        assert!(
            k1_25
                .sell1_frames
                .iter()
                .all(|p| p.seg_idx != act25.idx),
            "idx=25 active up seg must not emit new sell"
        );

        let at26 = build_kline_combine_bundle(&bars[..=26]);
        let k1_26 = at26.levels.iter().find(|l| l.level == 0).unwrap();
        let act26 = k1_26.active_unit.as_ref().expect("step26 active");
        assert_eq!(act26.dir, -1);
        assert_eq!(act26.idx, 5);
        // 框最高口径：本枢已有 1Sa@11.89，active high=11.88 低于框最高 → 不标新卖
        assert!(
            k1_26.sell1_frames.iter().all(|p| p.seg_idx != act26.idx),
            "idx=26 high below ZS box max must not emit new sell"
        );
        assert!(
            k1_26
                .sell1_frames
                .iter()
                .any(|p| p.seg_idx == 3 && p.label == "1Sa"),
            "earlier box-max sell remains"
        );

        let at27 = build_kline_combine_bundle(&bars[..=27]);
        let k1_27 = at27.levels.iter().find(|l| l.level == 0).unwrap();
        let act27 = k1_27.active_unit.as_ref().expect("step27 active");
        assert_eq!(act27.idx, act26.idx, "27 same active K1 as 26");
        assert_eq!(act27.x1, act26.x1);
        assert!(act27.x2 > act26.x2);
        assert!(
            k1_27.sell1_frames.iter().all(|p| p.seg_idx != act27.idx),
            "idx=27 still below box max: no sell on active"
        );
    }
}
