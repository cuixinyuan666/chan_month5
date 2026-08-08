//! Kn 三类及以上买卖点（全层同构）：以一类/二类资格中枢为链起点，
//! 相邻中枢买侧整体上移（zd_k > zg_{k-1}）→ 升一类；卖侧镜像下移。
//! 中间环不满足则该起点链断开；后续新的一/二类资格框可开新链。
//! 同框每个成员（跳过层首 mi==0）按序命名 3Ba/3Bb…，字母只递增不复位。
//! Active 钉点与一类/二类同构。
use crate::buy1::{zs_above_prev, zs_below_prev};
use crate::pipeline::LevelSegment;
use crate::zs::ZS;
use serde::{Deserialize, Serialize};

/// 三类+买点（cls>=3；label 如 "3Ba"）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BuyNFrame {
    pub seq: i32,
    pub zs_seq: i32,
    /// 类号：3=三类，4=四类…
    pub cls: i32,
    pub x: i32,
    pub price: f64,
    /// "3Ba" / "4Bb" / ...
    pub label: String,
    pub seg_idx: i64,
    pub level: i32,
}

/// 三类+卖点（买镜像）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SellNFrame {
    pub seq: i32,
    pub zs_seq: i32,
    pub cls: i32,
    pub x: i32,
    pub price: f64,
    /// "3Sa" / "4Sb" / ...
    pub label: String,
    pub seg_idx: i64,
    pub level: i32,
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

/// 同资格框内「每成员都打点」（与一类/二类「极值才标」不同；三类+链升类口径，ML 勿当极值语义）
fn label_buy_box(
    out: &mut Vec<BuyNFrame>,
    seq: &mut i32,
    zs: &ZS,
    zs_seq: i32,
    cls: i32,
    segs: &[LevelSegment],
    level: i32,
    active_idx: Option<i64>,
) {
    let mut letter_ord: Option<usize> = None;
    for &mi in &zs.member_segs {
        if mi == 0 {
            continue;
        }
        if mi >= segs.len() {
            continue;
        }
        let s = &segs[mi];
        let prior = letter_ord.is_some();
        let ord = letter_ord.map(|o| o + 1).unwrap_or(0);
        letter_ord = Some(ord);
        let pin = active_idx == Some(s.idx) && prior;
        out.push(BuyNFrame {
            seq: *seq,
            zs_seq,
            cls,
            x: mark_x(low_pole_x(s), s, pin),
            price: s.low,
            label: format!("{cls}B{}", suffix_of(ord)),
            seg_idx: s.idx,
            level,
        });
        *seq += 1;
    }
}

fn label_sell_box(
    out: &mut Vec<SellNFrame>,
    seq: &mut i32,
    zs: &ZS,
    zs_seq: i32,
    cls: i32,
    segs: &[LevelSegment],
    level: i32,
    active_idx: Option<i64>,
) {
    let mut letter_ord: Option<usize> = None;
    for &mi in &zs.member_segs {
        if mi == 0 {
            continue;
        }
        if mi >= segs.len() {
            continue;
        }
        let s = &segs[mi];
        let prior = letter_ord.is_some();
        let ord = letter_ord.map(|o| o + 1).unwrap_or(0);
        letter_ord = Some(ord);
        let pin = active_idx == Some(s.idx) && prior;
        out.push(SellNFrame {
            seq: *seq,
            zs_seq,
            cls,
            x: mark_x(high_pole_x(s), s, pin),
            price: s.high,
            label: format!("{cls}S{}", suffix_of(ord)),
            seg_idx: s.idx,
            level,
        });
        *seq += 1;
    }
}

pub fn find_buy_n(zs_list: &[ZS], segs: &[LevelSegment], level: i32) -> Vec<BuyNFrame> {
    find_buy_n_with_active(zs_list, segs, level, None)
}

/// 买：一类/二类资格框为起点，后续连续 zd_k > zg_{k-1} → 3/4/5…
pub fn find_buy_n_with_active(
    zs_list: &[ZS],
    segs: &[LevelSegment],
    level: i32,
    active_idx: Option<i64>,
) -> Vec<BuyNFrame> {
    let mut out = Vec::new();
    if zs_list.len() < 2 || segs.is_empty() {
        return out;
    }
    let mut seq = 0i32;
    for origin in 1..zs_list.len() {
        // zs1：一类/二类资格（当前整体在上个下方）
        if !zs_below_prev(&zs_list[origin], &zs_list[origin - 1]) {
            continue;
        }
        let mut prev_i = origin;
        let mut cls = 3i32;
        for k in (origin + 1)..zs_list.len() {
            // 买侧升类：当前整体在上一框上方
            if !zs_above_prev(&zs_list[k], &zs_list[prev_i]) {
                break; // 链断开
            }
            label_buy_box(
                &mut out,
                &mut seq,
                &zs_list[k],
                k as i32,
                cls,
                segs,
                level,
                active_idx,
            );
            prev_i = k;
            cls += 1;
        }
    }
    out
}

pub fn find_sell_n(zs_list: &[ZS], segs: &[LevelSegment], level: i32) -> Vec<SellNFrame> {
    find_sell_n_with_active(zs_list, segs, level, None)
}

/// 卖镜像：一类/二类资格（上移）为起点，后续连续 zg_k < zd_{k-1} → 3/4/5…
pub fn find_sell_n_with_active(
    zs_list: &[ZS],
    segs: &[LevelSegment],
    level: i32,
    active_idx: Option<i64>,
) -> Vec<SellNFrame> {
    let mut out = Vec::new();
    if zs_list.len() < 2 || segs.is_empty() {
        return out;
    }
    let mut seq = 0i32;
    for origin in 1..zs_list.len() {
        if !zs_above_prev(&zs_list[origin], &zs_list[origin - 1]) {
            continue;
        }
        let mut prev_i = origin;
        let mut cls = 3i32;
        for k in (origin + 1)..zs_list.len() {
            if !zs_below_prev(&zs_list[k], &zs_list[prev_i]) {
                break;
            }
            label_sell_box(
                &mut out,
                &mut seq,
                &zs_list[k],
                k as i32,
                cls,
                segs,
                level,
                active_idx,
            );
            prev_i = k;
            cls += 1;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
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

    fn mk_zs(zg: f64, zd: f64, members: Vec<usize>) -> ZS {
        ZS {
            level: 1,
            start_idx: *members.first().unwrap_or(&0) as i64,
            end_idx: *members.last().unwrap_or(&0) as i64,
            start_seg: *members.first().unwrap_or(&0),
            end_seg: *members.last().unwrap_or(&0),
            zg,
            zd,
            gg: zg,
            dd: zd,
            mid: (zg + zd) / 2.0,
            dir: 1,
            in_seg_idx: None,
            out_seg_idx: None,
            is_sure: true,
            member_segs: members,
        }
    }

    #[test]
    fn buy_chain_3_then_4_sequential_letters() {
        // zs0 高；zs1 在其下=一/二类起点；zs2 在 zs1 上=三类；zs3 在 zs2 上=四类
        let segs = vec![
            mk_seg(0, 1, 30.0, 20.0),
            mk_seg(1, 1, 10.0, 4.0),
            mk_seg(2, 1, 9.0, 5.0),
            mk_seg(3, 1, 18.0, 12.0), // 三类框成员
            mk_seg(4, 1, 17.0, 13.0),
            mk_seg(5, 1, 28.0, 22.0), // 四类框成员
            mk_seg(6, 1, 27.0, 23.0),
        ];
        let zs = vec![
            mk_zs(25.0, 18.0, vec![0]),       // zs0
            mk_zs(8.0, 2.0, vec![1, 2]),      // zs1 一/二类（below）
            mk_zs(16.0, 11.0, vec![3, 4]),    // zs2 三类（above zs1）
            mk_zs(26.0, 21.0, vec![5, 6]),    // zs3 四类（above zs2）
        ];
        let b = find_buy_n(&zs, &segs, 1);
        assert_eq!(b.len(), 4);
        assert_eq!(b[0].label, "3Ba");
        assert_eq!(b[0].cls, 3);
        assert_eq!(b[0].seg_idx, 3);
        assert_eq!(b[1].label, "3Bb");
        assert_eq!(b[1].seg_idx, 4);
        assert_eq!(b[2].label, "4Ba");
        assert_eq!(b[2].cls, 4);
        assert_eq!(b[2].seg_idx, 5);
        assert_eq!(b[3].label, "4Bb");
        assert_eq!(b[3].seg_idx, 6);
    }

    #[test]
    fn buy_chain_breaks_no_class4() {
        // zs2 不在 zs1 上方 → 断链；zs3 即使更高也不从该起点标四类
        let segs = vec![
            mk_seg(0, 1, 30.0, 20.0),
            mk_seg(1, 1, 10.0, 4.0),
            mk_seg(2, 1, 14.0, 6.0),  // 与 zs1 重叠区，不上移
            mk_seg(3, 1, 28.0, 22.0),
        ];
        let zs = vec![
            mk_zs(25.0, 18.0, vec![0]),
            mk_zs(8.0, 2.0, vec![1]),      // 一/二类
            mk_zs(12.0, 5.0, vec![2]),     // 不满足 zd>zg1（5 不 > 8）
            mk_zs(26.0, 21.0, vec![3]),    // 不应从 zs1 链标四类
        ];
        let b = find_buy_n(&zs, &segs, 1);
        assert!(b.is_empty());
    }

    #[test]
    fn sell_chain_mirror() {
        let segs = vec![
            mk_seg(0, 1, 10.0, 2.0),
            mk_seg(1, 1, 30.0, 20.0),
            mk_seg(2, 1, 12.0, 4.0),
            mk_seg(3, 1, 11.0, 5.0),
            mk_seg(4, 1, 2.5, 0.5),
        ];
        let zs = vec![
            mk_zs(8.0, 2.0, vec![0]),       // zs0 低
            mk_zs(28.0, 18.0, vec![1]),     // zs1 一/二类卖（above）
            mk_zs(10.0, 3.0, vec![2, 3]),   // zs2 三类卖（below zs1: zg=10 < zd=18）
            mk_zs(2.0, 0.5, vec![4]),      // zs3 四类卖（below zs2: zg=2 < zd=3）
        ];
        let s = find_sell_n(&zs, &segs, 1);
        assert_eq!(s.len(), 3);
        assert_eq!(s[0].label, "3Sa");
        assert_eq!(s[0].cls, 3);
        assert_eq!(s[1].label, "3Sb");
        assert_eq!(s[2].label, "4Sa");
        assert_eq!(s[2].cls, 4);
    }

    #[test]
    fn layer_first_mi0_skipped() {
        let segs = vec![mk_seg(0, 1, 18.0, 12.0), mk_seg(1, 1, 17.0, 13.0)];
        // zs1 below zs0 → 一/二类起点；zs2 above zs1 → 三类；mi0 跳过
        let zs = vec![
            mk_zs(25.0, 18.0, vec![]),
            mk_zs(8.0, 2.0, vec![]),
            mk_zs(16.0, 11.0, vec![0, 1]),
        ];
        let b = find_buy_n(&zs, &segs, 0);
        assert_eq!(b.len(), 1);
        assert_eq!(b[0].seg_idx, 1);
        assert_eq!(b[0].label, "3Ba");
    }

    #[test]
    fn active_pin_begin_plus_one() {
        let mut segs = vec![
            mk_seg(0, 1, 30.0, 20.0),
            mk_seg(1, 1, 10.0, 4.0),
            mk_seg(2, 1, 18.0, 12.0),
            mk_seg(3, 1, 17.0, 13.0),
        ];
        segs[3].begin_pole_x = 3;
        segs[3].end_pole_x = 12;
        segs[3].begin_fractal_low = 13.0;
        segs[3].end_fractal_low = 14.0;
        let zs = vec![
            mk_zs(25.0, 18.0, vec![0]),
            mk_zs(8.0, 2.0, vec![1]),
            mk_zs(16.0, 11.0, vec![2, 3]),
        ];
        let b = find_buy_n_with_active(&zs, &segs, 1, Some(3));
        assert_eq!(b.len(), 2);
        assert_eq!(b[1].x, 4); // pin begin+1
    }

    #[test]
    fn letters_never_reset_inside_box() {
        let segs = vec![
            mk_seg(0, 1, 30.0, 20.0),
            mk_seg(1, 1, 10.0, 4.0),
            mk_seg(2, 1, 18.0, 12.0),
            mk_seg(3, 1, 17.0, 10.0), // 更低也不复位
            mk_seg(4, 1, 19.0, 14.0),
        ];
        let zs = vec![
            mk_zs(25.0, 18.0, vec![0]),
            mk_zs(8.0, 2.0, vec![1]),
            mk_zs(16.0, 11.0, vec![2, 3, 4]),
        ];
        let b = find_buy_n(&zs, &segs, 1);
        assert_eq!(b.len(), 3);
        assert_eq!(b[0].label, "3Ba");
        assert_eq!(b[1].label, "3Bb");
        assert_eq!(b[2].label, "3Bc");
    }
}
