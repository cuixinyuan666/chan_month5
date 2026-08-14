//! 全类 BSP 在线对错评判（与 buy1/buy2/buy_n 解耦）。
//!
//! BSP 本身是永久事件；本模块只派生 Pending/Correct/Wrong，不改原始 x/price/label。
//! 类号从 BSP 自身 label/cls 解析，不写死 1/2/3。
//! 成功/失败是 BSP 之后第一个明确的顺向/反向结构事件（不要求必须等新中枢定型）：
//!   1) 后续非本框成员段相对本框 ZG/ZD 的离开（全类都有失败路径）
//!   2) 后续已定型中枢 zs_above_prev / zs_below_prev（事件之一，非唯一判据）
//!   3) 一类/二类另继承同框严格新极值复位；三类+仍是全员打点，不套极值失败
//! 无未来：只使用 asof 已可见的 ZS/seg。终态冻结：Pending→Correct|Wrong 后忽略冲突。
//! 同 x 同时命中成功/失败：成功优先（apply_hits）。不同 x：取最早事件。

use std::collections::HashMap;

use crate::buy1::{zs_above_prev, zs_below_prev, Buy1Frame, Sell1Frame};
use crate::buy2::{Buy2Frame, Sell2Frame};
use crate::buy_n::{BuyNFrame, SellNFrame};
use crate::pipeline::LevelSegment;
use crate::zs::ZS;
use serde::{Deserialize, Serialize};

/// 买 / 卖（镜像用 Direction，不复制两套规则）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BsSide {
    Buy,
    Sell,
}

impl BsSide {
    pub fn as_str(self) -> &'static str {
        match self {
            BsSide::Buy => "B",
            BsSide::Sell => "S",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "B" | "b" => Some(BsSide::Buy),
            "S" | "s" => Some(BsSide::Sell),
            _ => None,
        }
    }
}

/// 评判状态。只允许 Pending → Correct / Wrong。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BsVerdictState {
    Pending,
    Correct,
    Wrong,
}

impl BsVerdictState {
    pub fn as_str(self) -> &'static str {
        match self {
            BsVerdictState::Pending => "pending",
            BsVerdictState::Correct => "correct",
            BsVerdictState::Wrong => "wrong",
        }
    }

    pub fn is_terminal(self) -> bool {
        matches!(self, BsVerdictState::Correct | BsVerdictState::Wrong)
    }
}

/// 独立于 BSP 的评判帧（不回写原 BSP）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BsVerdictFrame {
    pub level: i32,
    /// "B" / "S"
    pub side: String,
    /// 类号 1..n，不封顶
    pub cls: i32,
    pub label: String,
    pub seg_idx: i64,
    /// BSP 出现时的 x（≠ 评判 x）
    pub bsp_x: i32,
    pub price: f64,
    pub zs_seq: i32,
    /// pending / correct / wrong
    pub state: String,
    /// 首次进入仓的 step（= bsp_x）
    pub create_x: i32,
    /// 首次 Correct 的结构事件 x
    pub confirm_x: Option<i32>,
    /// 首次 Wrong 的结构事件 x
    pub invalid_x: Option<i32>,
    pub reason: String,
}

impl BsVerdictFrame {
    pub fn state_enum(&self) -> BsVerdictState {
        match self.state.as_str() {
            "correct" => BsVerdictState::Correct,
            "wrong" => BsVerdictState::Wrong,
            _ => BsVerdictState::Pending,
        }
    }

    /// asOf 展示用：终态事件 x；Pending 则无终态。
    pub fn verdict_x(&self) -> Option<i32> {
        match self.state_enum() {
            BsVerdictState::Correct => self.confirm_x,
            BsVerdictState::Wrong => self.invalid_x,
            BsVerdictState::Pending => None,
        }
    }
}

/// 统一 BSP 事件（检测模块产出，judge 只读）。
#[derive(Debug, Clone)]
pub struct BsEvent {
    pub side: BsSide,
    pub cls: i32,
    pub seq: i32,
    pub zs_seq: i32,
    pub x: i32,
    pub price: f64,
    pub label: String,
    pub seg_idx: i64,
    pub level: i32,
}

impl BsEvent {
    /// 稳定键：层|向|类|段|标签。不含颗粒度 x（同 seg/label 多 x 共用一条 verdict）。
    pub fn stable_key(&self) -> String {
        format!(
            "{}|{}|{}|{}|{}",
            self.level,
            self.side.as_str(),
            self.cls,
            self.seg_idx,
            self.label
        )
    }
}

/// 从 label 解析类号与方向。"1Ba"→(1,Buy) "12Sa"→(12,Sell) "3B"→(3,Buy)
/// 不写死 1/2/3。
pub fn parse_bsp_class(label: &str) -> Option<(i32, BsSide)> {
    let bytes = label.as_bytes();
    let mut i = 0;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        i += 1;
    }
    if i == 0 {
        return None;
    }
    let cls: i32 = label[..i].parse().ok()?;
    if cls < 1 {
        return None;
    }
    let side = match bytes.get(i) {
        Some(b'B') | Some(b'b') => BsSide::Buy,
        Some(b'S') | Some(b's') => BsSide::Sell,
        _ => return None,
    };
    Some((cls, side))
}

fn event_from_buy1(f: &Buy1Frame) -> Option<BsEvent> {
    let (cls, side) = parse_bsp_class(&f.label).unwrap_or((1, BsSide::Buy));
    Some(BsEvent {
        side,
        cls,
        seq: f.seq,
        zs_seq: f.zs_seq,
        x: f.x,
        price: f.price,
        label: f.label.clone(),
        seg_idx: f.seg_idx,
        level: f.level,
    })
}

fn event_from_sell1(f: &Sell1Frame) -> Option<BsEvent> {
    let (cls, side) = parse_bsp_class(&f.label).unwrap_or((1, BsSide::Sell));
    Some(BsEvent {
        side,
        cls,
        seq: f.seq,
        zs_seq: f.zs_seq,
        x: f.x,
        price: f.price,
        label: f.label.clone(),
        seg_idx: f.seg_idx,
        level: f.level,
    })
}

fn event_from_buy2(f: &Buy2Frame) -> Option<BsEvent> {
    let (cls, side) = parse_bsp_class(&f.label).unwrap_or((2, BsSide::Buy));
    Some(BsEvent {
        side,
        cls,
        seq: f.seq,
        zs_seq: f.zs_seq,
        x: f.x,
        price: f.price,
        label: f.label.clone(),
        seg_idx: f.seg_idx,
        level: f.level,
    })
}

fn event_from_sell2(f: &Sell2Frame) -> Option<BsEvent> {
    let (cls, side) = parse_bsp_class(&f.label).unwrap_or((2, BsSide::Sell));
    Some(BsEvent {
        side,
        cls,
        seq: f.seq,
        zs_seq: f.zs_seq,
        x: f.x,
        price: f.price,
        label: f.label.clone(),
        seg_idx: f.seg_idx,
        level: f.level,
    })
}

fn event_from_buy_n(f: &BuyNFrame) -> Option<BsEvent> {
    let (parsed, side) = parse_bsp_class(&f.label).unwrap_or((f.cls, BsSide::Buy));
    let cls = if f.cls >= 1 { f.cls } else { parsed };
    Some(BsEvent {
        side,
        cls,
        seq: f.seq,
        zs_seq: f.zs_seq,
        x: f.x,
        price: f.price,
        label: f.label.clone(),
        seg_idx: f.seg_idx,
        level: f.level,
    })
}

fn event_from_sell_n(f: &SellNFrame) -> Option<BsEvent> {
    let (parsed, side) = parse_bsp_class(&f.label).unwrap_or((f.cls, BsSide::Sell));
    let cls = if f.cls >= 1 { f.cls } else { parsed };
    Some(BsEvent {
        side,
        cls,
        seq: f.seq,
        zs_seq: f.zs_seq,
        x: f.x,
        price: f.price,
        label: f.label.clone(),
        seg_idx: f.seg_idx,
        level: f.level,
    })
}

/// 六路 BSP 帧 → 统一事件（不重新检测买卖点）。
pub fn collect_bs_events(
    buy1: &[Buy1Frame],
    sell1: &[Sell1Frame],
    buy2: &[Buy2Frame],
    sell2: &[Sell2Frame],
    buy_n: &[BuyNFrame],
    sell_n: &[SellNFrame],
) -> Vec<BsEvent> {
    let mut out = Vec::new();
    out.extend(buy1.iter().filter_map(event_from_buy1));
    out.extend(sell1.iter().filter_map(event_from_sell1));
    out.extend(buy2.iter().filter_map(event_from_buy2));
    out.extend(sell2.iter().filter_map(event_from_sell2));
    out.extend(buy_n.iter().filter_map(event_from_buy_n));
    out.extend(sell_n.iter().filter_map(event_from_sell_n));
    out
}

fn pending_frame(ev: &BsEvent) -> BsVerdictFrame {
    BsVerdictFrame {
        level: ev.level,
        side: ev.side.as_str().to_string(),
        cls: ev.cls,
        label: ev.label.clone(),
        seg_idx: ev.seg_idx,
        bsp_x: ev.x,
        price: ev.price,
        zs_seq: ev.zs_seq,
        state: BsVerdictState::Pending.as_str().to_string(),
        create_x: ev.x,
        confirm_x: None,
        invalid_x: None,
        reason: "pending".to_string(),
    }
}

#[inline]
fn approx_eq(a: f64, b: f64) -> bool {
    (a - b).abs() <= 1e-12
}

/// 段在 asof 已可见的右端（确认柱 / 极点）。
fn seg_known_x(s: &LevelSegment) -> i32 {
    s.end_confirm_x.max(s.end_pole_x)
}

/// 中枢在 asof 已可见的右端（成员段 max known x）。
fn zs_event_x(zs: &ZS, segs: &[LevelSegment]) -> i32 {
    zs.member_segs
        .iter()
        .filter_map(|&i| segs.get(i))
        .map(seg_known_x)
        .max()
        .unwrap_or(0)
}

fn zs_containing_seg<'a>(zs_list: &'a [ZS], segs: &[LevelSegment], seg_idx: i64) -> Option<(usize, &'a ZS)> {
    zs_list.iter().enumerate().find(|(_, z)| {
        z.member_segs.iter().any(|&mi| {
            segs.get(mi).map(|s| s.idx == seg_idx).unwrap_or(false)
        })
    })
}

/// 一类/二类同框保护极值：买=已见最低，卖=已见最高（只看 bsp_x 当时已可见成员）。
fn box_extreme_at(
    zs: &ZS,
    segs: &[LevelSegment],
    side: BsSide,
    asof_x: i32,
) -> Option<f64> {
    let mut ext: Option<f64> = None;
    for &mi in &zs.member_segs {
        if mi == 0 {
            continue;
        }
        let Some(s) = segs.get(mi) else { continue };
        if seg_known_x(s) > asof_x {
            continue;
        }
        match side {
            BsSide::Buy => {
                ext = Some(match ext {
                    None => s.low,
                    Some(v) => v.min(s.low),
                });
            }
            BsSide::Sell => {
                ext = Some(match ext {
                    None => s.high,
                    Some(v) => v.max(s.high),
                });
            }
        }
    }
    ext
}

struct Hit {
    x: i32,
    reason: String,
}

/// 单一 BSP：只读当前前缀结构，返回最早成功 / 最早失败（event_x <= asof，且 >= bsp_x）。
fn judge_one(
    ev: &BsEvent,
    zs_list: &[ZS],
    segs: &[LevelSegment],
    asof: i32,
    active_idx: Option<i64>,
) -> (Option<Hit>, Option<Hit>) {
    if asof < ev.x {
        return (None, None);
    }
    let Some((zi, this_zs)) = zs_containing_seg(zs_list, segs, ev.seg_idx) else {
        return (None, None);
    };

    let mut success: Option<Hit> = None;
    let mut failure: Option<Hit> = None;
    let bump_ok = |slot: &mut Option<Hit>, hit: Hit| {
        if hit.x < ev.x || hit.x > asof {
            return;
        }
        match slot {
            None => *slot = Some(hit),
            Some(old) if hit.x < old.x => *slot = Some(hit),
            _ => {}
        }
    };

    // 一类/二类同框保护极值（buy1/buy2 生成语义）。三类+是全员打点，不套此失败。
    if ev.cls <= 2 {
        let protective = if ev.cls == 1 {
            Some(ev.price)
        } else {
            box_extreme_at(this_zs, segs, ev.side, ev.x)
        };
        if let Some(prot) = protective {
            for &mi in &this_zs.member_segs {
                if mi == 0 {
                    continue;
                }
                let Some(s) = segs.get(mi) else { continue };
                if active_idx == Some(s.idx) {
                    continue; // 动态段极值不稳，不当失败源
                }
                if s.idx == ev.seg_idx {
                    continue;
                }
                let hx = seg_known_x(s);
                if hx <= ev.x || hx > asof {
                    continue;
                }
                let broken = match ev.side {
                    BsSide::Buy => s.low < prot && !approx_eq(s.low, prot),
                    BsSide::Sell => s.high > prot && !approx_eq(s.high, prot),
                };
                if broken {
                    bump_ok(
                        &mut failure,
                        Hit {
                            x: hx.max(ev.x),
                            reason: if ev.cls == 1 {
                                "same_zs_new_extreme".to_string()
                            } else {
                                "same_zs_box_extreme_break".to_string()
                            },
                        },
                    );
                }
            }
        }
    }

    // 全类：后续非本框成员段相对本框 ZG/ZD 的离开。不要求新 ZS 已形成/定型。
    // 买：升破 ZG=顺向确认，跌破 ZD=反向证伪；卖镜像。本框延伸成员不是离开。
    let member_set: std::collections::HashSet<usize> =
        this_zs.member_segs.iter().copied().collect();
    for (si, s) in segs.iter().enumerate() {
        if member_set.contains(&si) {
            continue;
        }
        let hx = seg_known_x(s);
        if hx <= ev.x || hx > asof {
            continue;
        }
        let above = s.high > this_zs.zg && !approx_eq(s.high, this_zs.zg);
        let below = s.low < this_zs.zd && !approx_eq(s.low, this_zs.zd);
        match ev.side {
            BsSide::Buy => {
                if above {
                    bump_ok(
                        &mut success,
                        Hit {
                            x: hx.max(ev.x),
                            reason: "leave_above_zg".to_string(),
                        },
                    );
                }
                if below {
                    bump_ok(
                        &mut failure,
                        Hit {
                            x: hx.max(ev.x),
                            reason: "leave_below_zd".to_string(),
                        },
                    );
                }
            }
            BsSide::Sell => {
                if below {
                    bump_ok(
                        &mut success,
                        Hit {
                            x: hx.max(ev.x),
                            reason: "leave_below_zd".to_string(),
                        },
                    );
                }
                if above {
                    bump_ok(
                        &mut failure,
                        Hit {
                            x: hx.max(ev.x),
                            reason: "leave_above_zg".to_string(),
                        },
                    );
                }
            }
        }
    }

    // 全类：后续已定型中枢整体上/下移（事件之一；继承 zs_above_prev / zs_below_prev）。
    for later in zs_list.iter().skip(zi + 1) {
        if !later.is_sure {
            continue;
        }
        let hx = zs_event_x(later, segs);
        if hx <= ev.x || hx > asof {
            continue;
        }
        let above = zs_above_prev(later, this_zs);
        let below = zs_below_prev(later, this_zs);
        match ev.side {
            BsSide::Buy => {
                if above {
                    bump_ok(
                        &mut success,
                        Hit {
                            x: hx.max(ev.x),
                            reason: "later_zs_above".to_string(),
                        },
                    );
                }
                if below {
                    bump_ok(
                        &mut failure,
                        Hit {
                            x: hx.max(ev.x),
                            reason: "later_zs_below".to_string(),
                        },
                    );
                }
            }
            BsSide::Sell => {
                // 卖镜像：下移=顺向成功，上移=反向失败
                if below {
                    bump_ok(
                        &mut success,
                        Hit {
                            x: hx.max(ev.x),
                            reason: "later_zs_below".to_string(),
                        },
                    );
                }
                if above {
                    bump_ok(
                        &mut failure,
                        Hit {
                            x: hx.max(ev.x),
                            reason: "later_zs_above".to_string(),
                        },
                    );
                }
            }
        }
    }

    (success, failure)
}

fn apply_hits(frame: &mut BsVerdictFrame, success: Option<Hit>, failure: Option<Hit>) {
    if frame.state_enum().is_terminal() {
        return;
    }
    // 成功优先：同 x 也 Correct（工程单状态机）。
    let pick = match (success, failure) {
        (Some(s), Some(f)) if s.x <= f.x => Some((BsVerdictState::Correct, s)),
        (Some(_), Some(f)) => Some((BsVerdictState::Wrong, f)),
        (Some(s), None) => Some((BsVerdictState::Correct, s)),
        (None, Some(f)) => Some((BsVerdictState::Wrong, f)),
        (None, None) => None,
    };
    let Some((st, hit)) = pick else { return };
    if hit.x < frame.bsp_x {
        return;
    }
    match st {
        BsVerdictState::Correct => {
            frame.state = st.as_str().to_string();
            frame.confirm_x = Some(hit.x);
            frame.invalid_x = None;
            frame.reason = hit.reason;
        }
        BsVerdictState::Wrong => {
            frame.state = st.as_str().to_string();
            frame.invalid_x = Some(hit.x);
            frame.confirm_x = None;
            frame.reason = hit.reason;
        }
        BsVerdictState::Pending => {}
    }
}

/// 单层入口：K0/K1/…/KN 共用。store 跨步冻结终态。
pub fn judge_level(
    asof: i32,
    zs_list: &[ZS],
    segs: &[LevelSegment],
    live_events: &[BsEvent],
    store: &mut HashMap<String, BsVerdictFrame>,
    active_idx: Option<i64>,
) -> Vec<BsVerdictFrame> {
    let mut live_keys = std::collections::HashSet::new();
    for ev in live_events {
        if ev.x > asof || ev.seg_idx < 0 {
            continue;
        }
        let k = ev.stable_key();
        live_keys.insert(k.clone());
        store.entry(k).or_insert_with(|| pending_frame(ev));
    }

    for ev in live_events {
        if ev.x > asof || ev.seg_idx < 0 {
            continue;
        }
        let k = ev.stable_key();
        let Some(frame) = store.get_mut(&k) else { continue };
        if frame.state_enum().is_terminal() {
            continue;
        }
        let (ok, bad) = judge_one(ev, zs_list, segs, asof, active_idx);
        apply_hits(frame, ok, bad);
    }

    // 已入库但本步 live 未再吐出的 BSP：仍用原字段继续判（不回写 BSP）。
    let pending_keys: Vec<String> = store
        .iter()
        .filter(|(k, v)| !v.state_enum().is_terminal() && !live_keys.contains(*k))
        .map(|(k, _)| k.clone())
        .collect();
    for k in pending_keys {
        let ev = {
            let Some(f) = store.get(&k) else { continue };
            let Some(side) = BsSide::from_str(&f.side) else { continue };
            BsEvent {
                side,
                cls: f.cls,
                seq: 0,
                zs_seq: f.zs_seq,
                x: f.bsp_x,
                price: f.price,
                label: f.label.clone(),
                seg_idx: f.seg_idx,
                level: f.level,
            }
        };
        let (ok, bad) = judge_one(&ev, zs_list, segs, asof, active_idx);
        if let Some(frame) = store.get_mut(&k) {
            apply_hits(frame, ok, bad);
        }
    }

    let mut out: Vec<BsVerdictFrame> = store.values().cloned().collect();
    out.sort_by(|a, b| {
        a.bsp_x
            .cmp(&b.bsp_x)
            .then(a.level.cmp(&b.level))
            .then(a.cls.cmp(&b.cls))
            .then(a.side.cmp(&b.side))
            .then(a.seg_idx.cmp(&b.seg_idx))
            .then(a.label.cmp(&b.label))
    });
    out
}

/// 便捷：无跨步仓时的一次性评判（asof 前缀自洽；终态仍按首次事件冻结）。
pub fn judge_bsp(
    asof: i32,
    zs_list: &[ZS],
    segs: &[LevelSegment],
    live_events: &[BsEvent],
    active_idx: Option<i64>,
) -> Vec<BsVerdictFrame> {
    let mut store = HashMap::new();
    judge_level(asof, zs_list, segs, live_events, &mut store, active_idx)
}

/// 从六路帧评判一层（K0 与 K1+ 同一入口）。
pub fn judge_frames(
    asof: i32,
    zs_list: &[ZS],
    segs: &[LevelSegment],
    buy1: &[Buy1Frame],
    sell1: &[Sell1Frame],
    buy2: &[Buy2Frame],
    sell2: &[Sell2Frame],
    buy_n: &[BuyNFrame],
    sell_n: &[SellNFrame],
    store: &mut HashMap<String, BsVerdictFrame>,
    active_idx: Option<i64>,
) -> Vec<BsVerdictFrame> {
    let events = collect_bs_events(buy1, sell1, buy2, sell2, buy_n, sell_n);
    judge_level(asof, zs_list, segs, &events, store, active_idx)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pipeline::LevelSegment;

    fn mk_seg(idx: i64, dir: i32, high: f64, low: f64, x: i32) -> LevelSegment {
        LevelSegment {
            idx,
            dir,
            begin_confirm_x: x,
            end_confirm_x: x,
            begin_pole_x: x,
            end_pole_x: x,
            open: low,
            high,
            low,
            close: high,
            volume: 0.0,
            begin_fractal_x1: x,
            begin_fractal_x2: x,
            end_fractal_x1: x,
            end_fractal_x2: x,
            begin_fractal_high: high,
            begin_fractal_low: low,
            end_fractal_high: high,
            end_fractal_low: low,
            is_bootstrap: false,
            is_promoted_default: false,
        }
    }

    fn mk_zs(zg: f64, zd: f64, members: Vec<usize>, sure: bool) -> ZS {
        ZS {
            level: 0,
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
            is_sure: sure,
            member_segs: members,
        }
    }

    fn ev_buy(cls: i32, letter: char, seg: i64, x: i32, price: f64, zs_seq: i32, level: i32) -> BsEvent {
        BsEvent {
            side: BsSide::Buy,
            cls,
            seq: 0,
            zs_seq,
            x,
            price,
            label: format!("{cls}B{letter}"),
            seg_idx: seg,
            level,
        }
    }

    fn ev_sell(cls: i32, letter: char, seg: i64, x: i32, price: f64, zs_seq: i32, level: i32) -> BsEvent {
        BsEvent {
            side: BsSide::Sell,
            cls,
            seq: 0,
            zs_seq,
            x,
            price,
            label: format!("{cls}S{letter}"),
            seg_idx: seg,
            level,
        }
    }

    /// 一/二类资格：zs1 整体在 zs0 下方；其后 zs2 上移=成功，或 zs2 再下移=失败。
    fn chain_buy_zs(up: bool) -> (Vec<LevelSegment>, Vec<ZS>) {
        let segs = vec![
            mk_seg(0, 1, 30.0, 20.0, 0),
            mk_seg(1, -1, 10.0, 4.0, 10),
            mk_seg(2, 1, 9.0, 5.0, 20),
            if up {
                mk_seg(3, 1, 18.0, 12.0, 30)
            } else {
                mk_seg(3, -1, 1.8, 0.4, 30)
            },
            if up {
                mk_seg(4, -1, 17.0, 13.0, 40)
            } else {
                mk_seg(4, 1, 1.6, 0.6, 40)
            },
        ];
        let zs2 = if up {
            mk_zs(16.0, 11.0, vec![3, 4], true)
        } else {
            mk_zs(1.5, 0.3, vec![3, 4], true)
        };
        let zs = vec![
            mk_zs(25.0, 18.0, vec![0], true),
            mk_zs(8.0, 2.0, vec![1, 2], true),
            zs2,
        ];
        (segs, zs)
    }

    #[test]
    fn parse_class_not_hardcoded_to_3() {
        assert_eq!(parse_bsp_class("1Ba"), Some((1, BsSide::Buy)));
        assert_eq!(parse_bsp_class("2Sa"), Some((2, BsSide::Sell)));
        assert_eq!(parse_bsp_class("3Bb"), Some((3, BsSide::Buy)));
        assert_eq!(parse_bsp_class("9Sa"), Some((9, BsSide::Sell)));
        assert_eq!(parse_bsp_class("12Ba"), Some((12, BsSide::Buy)));
        assert_eq!(parse_bsp_class("B1"), None);
    }

    #[test]
    fn buy1_pending_until_later_zs() {
        let segs = vec![
            mk_seg(0, 1, 30.0, 20.0, 0),
            mk_seg(1, -1, 10.0, 4.0, 10),
            mk_seg(2, 1, 9.0, 5.0, 20),
        ];
        let zs = vec![
            mk_zs(25.0, 18.0, vec![0], true),
            mk_zs(8.0, 2.0, vec![1, 2], true),
        ];
        let e = ev_buy(1, 'a', 1, 10, 4.0, 1, 0);
        let v = judge_bsp(20, &zs, &segs, &[e], None);
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].state, "pending");
        assert!(v[0].confirm_x.is_none());
    }

    #[test]
    fn buy1_correct_when_later_zs_above() {
        let (segs, zs) = chain_buy_zs(true);
        let e = ev_buy(1, 'a', 1, 10, 4.0, 1, 0);
        let v = judge_bsp(40, &zs, &segs, &[e], None);
        assert_eq!(v[0].state, "correct");
        assert_eq!(v[0].confirm_x, Some(30)); // 非本框升破 ZG，早于后续 ZS 定型 x=40
        assert_eq!(v[0].reason, "leave_above_zg");
        assert!(v[0].confirm_x.unwrap() >= v[0].bsp_x);
        assert_eq!(v[0].bsp_x, 10);
        assert_eq!(v[0].price, 4.0);
        assert_eq!(v[0].label, "1Ba");
    }

    #[test]
    fn buy1_wrong_when_later_zs_below() {
        let (segs, zs) = chain_buy_zs(false);
        let e = ev_buy(1, 'a', 1, 10, 4.0, 1, 0);
        let v = judge_bsp(40, &zs, &segs, &[e], None);
        assert_eq!(v[0].state, "wrong");
        assert_eq!(v[0].invalid_x, Some(30)); // 非本框跌破 ZD，早于后续 ZS 定型 x=40
        assert_eq!(v[0].reason, "leave_below_zd");
    }

    #[test]
    fn buy1_wrong_same_zs_new_low() {
        let segs = vec![
            mk_seg(0, 1, 30.0, 20.0, 0),
            mk_seg(1, -1, 10.0, 4.0, 10),
            mk_seg(2, 1, 9.0, 5.0, 20),
            mk_seg(3, -1, 6.0, 2.0, 25), // 同框新低
        ];
        let zs = vec![
            mk_zs(25.0, 18.0, vec![0], true),
            mk_zs(8.0, 2.0, vec![1, 2, 3], true),
        ];
        let e = ev_buy(1, 'a', 1, 10, 4.0, 1, 0);
        let v = judge_bsp(25, &zs, &segs, &[e], None);
        assert_eq!(v[0].state, "wrong");
        assert_eq!(v[0].reason, "same_zs_new_extreme");
        assert_eq!(v[0].invalid_x, Some(25));
    }

    #[test]
    fn freeze_correct_ignores_later_failure() {
        let segs = vec![
            mk_seg(0, 1, 30.0, 20.0, 0),
            mk_seg(1, -1, 10.0, 4.0, 10),
            mk_seg(2, 1, 9.0, 5.0, 20),
            mk_seg(3, 1, 18.0, 12.0, 30),
            mk_seg(4, -1, 17.0, 13.0, 40),
            mk_seg(5, -1, 3.0, 1.0, 50),
            mk_seg(6, 1, 2.8, 1.2, 60),
        ];
        let zs = vec![
            mk_zs(25.0, 18.0, vec![0], true),
            mk_zs(8.0, 2.0, vec![1, 2], true),
            mk_zs(16.0, 11.0, vec![3, 4], true), // 先上移 → Correct
            mk_zs(1.5, 0.3, vec![5, 6], true),  // 再下移，必须忽略
        ];
        let e = ev_buy(1, 'a', 1, 10, 4.0, 1, 0);
        let mut store = HashMap::new();
        let v1 = judge_level(40, &zs[..3], &segs, &[e.clone()], &mut store, None);
        assert_eq!(v1[0].state, "correct");
        let v2 = judge_level(60, &zs, &segs, &[e], &mut store, None);
        assert_eq!(v2[0].state, "correct");
        assert_eq!(v2[0].confirm_x, Some(30));
    }

    #[test]
    fn freeze_wrong_ignores_later_success() {
        let segs = vec![
            mk_seg(0, 1, 30.0, 20.0, 0),
            mk_seg(1, -1, 10.0, 4.0, 10),
            mk_seg(2, 1, 9.0, 5.0, 20),
            mk_seg(3, -1, 1.8, 0.4, 30),
            mk_seg(4, 1, 1.6, 0.6, 40),
            mk_seg(5, 1, 18.0, 12.0, 50),
            mk_seg(6, -1, 17.0, 13.0, 60),
        ];
        let zs = vec![
            mk_zs(25.0, 18.0, vec![0], true),
            mk_zs(8.0, 2.0, vec![1, 2], true),
            mk_zs(1.5, 0.3, vec![3, 4], true),
            mk_zs(16.0, 11.0, vec![5, 6], true),
        ];
        let e = ev_buy(1, 'a', 1, 10, 4.0, 1, 0);
        let mut store = HashMap::new();
        let v1 = judge_level(40, &zs[..3], &segs, &[e.clone()], &mut store, None);
        assert_eq!(v1[0].state, "wrong");
        let v2 = judge_level(60, &zs, &segs, &[e], &mut store, None);
        assert_eq!(v2[0].state, "wrong");
        assert_eq!(v2[0].invalid_x, Some(30));
    }

    #[test]
    fn no_future_asof_hides_later_zs() {
        let (segs, zs) = chain_buy_zs(true);
        let e = ev_buy(1, 'a', 1, 10, 4.0, 1, 0);
        let v_early = judge_bsp(20, &zs, &segs, &[e.clone()], None);
        assert_eq!(v_early[0].state, "pending");
        let v_late = judge_bsp(40, &zs, &segs, &[e], None);
        assert_eq!(v_late[0].state, "correct");
    }

    #[test]
    fn bsp_identity_not_rewritten() {
        let (segs, zs) = chain_buy_zs(true);
        let e = ev_buy(2, 'a', 2, 20, 5.0, 1, 0);
        let snapshot = (
            e.x,
            e.price,
            e.seg_idx,
            e.label.clone(),
            e.level,
        );
        let v = judge_bsp(40, &zs, &segs, &[e], None);
        assert_eq!(v[0].bsp_x, snapshot.0);
        assert_eq!(v[0].price, snapshot.1);
        assert_eq!(v[0].seg_idx, snapshot.2);
        assert_eq!(v[0].label, snapshot.3);
        assert_eq!(v[0].level, snapshot.4);
    }

    #[test]
    fn sell1_mirror_correct_when_later_zs_below() {
        // zs1 在 zs0 上方（一卖资格）；其后 zs2 再下移=卖成功
        let segs = vec![
            mk_seg(0, -1, 10.0, 4.0, 0),
            mk_seg(1, 1, 30.0, 20.0, 10),
            mk_seg(2, -1, 29.0, 21.0, 20),
            mk_seg(3, -1, 8.0, 2.0, 30),
            mk_seg(4, 1, 7.0, 3.0, 40),
        ];
        let zs = vec![
            mk_zs(8.0, 2.0, vec![0], true),
            mk_zs(28.0, 22.0, vec![1, 2], true),
            mk_zs(6.0, 1.5, vec![3, 4], true),
        ];
        let e = ev_sell(1, 'a', 1, 10, 30.0, 1, 0);
        let v = judge_bsp(40, &zs, &segs, &[e], None);
        assert_eq!(v[0].state, "correct");
        assert_eq!(v[0].reason, "leave_below_zd");
        assert_eq!(v[0].confirm_x, Some(30));
    }

    #[test]
    fn sell1_mirror_wrong_same_zs_new_high() {
        let segs = vec![
            mk_seg(0, -1, 10.0, 4.0, 0),
            mk_seg(1, 1, 30.0, 20.0, 10),
            mk_seg(2, -1, 29.0, 21.0, 20),
            mk_seg(3, 1, 35.0, 25.0, 25),
        ];
        let zs = vec![
            mk_zs(8.0, 2.0, vec![0], true),
            mk_zs(28.0, 22.0, vec![1, 2, 3], true),
        ];
        let e = ev_sell(1, 'a', 1, 10, 30.0, 1, 0);
        let v = judge_bsp(25, &zs, &segs, &[e], None);
        assert_eq!(v[0].state, "wrong");
        assert_eq!(v[0].reason, "same_zs_new_extreme");
    }

    #[test]
    fn class2_buy_box_break_not_own_price() {
        // 2B price=6（更高低），保护极值是一类低 4；跌到 5 不失败，跌破 4 才失败
        let segs_ok = vec![
            mk_seg(0, 1, 30.0, 20.0, 0),
            mk_seg(1, -1, 10.0, 4.0, 10),
            mk_seg(2, 1, 9.0, 6.0, 20),
            mk_seg(3, -1, 8.0, 5.0, 25),
        ];
        let zs = vec![
            mk_zs(25.0, 18.0, vec![0], true),
            mk_zs(8.0, 2.0, vec![1, 2, 3], true),
        ];
        let e = ev_buy(2, 'a', 2, 20, 6.0, 1, 0);
        let v = judge_bsp(25, &zs, &segs_ok, &[e.clone()], None);
        assert_eq!(v[0].state, "pending");

        let segs_bad = vec![
            mk_seg(0, 1, 30.0, 20.0, 0),
            mk_seg(1, -1, 10.0, 4.0, 10),
            mk_seg(2, 1, 9.0, 6.0, 20),
            mk_seg(3, -1, 8.0, 3.0, 25),
        ];
        let zs2 = vec![
            mk_zs(25.0, 18.0, vec![0], true),
            mk_zs(8.0, 2.0, vec![1, 2, 3], true),
        ];
        let v2 = judge_bsp(25, &zs2, &segs_bad, &[e], None);
        assert_eq!(v2[0].state, "wrong");
        assert_eq!(v2[0].reason, "same_zs_box_extreme_break");
    }

    #[test]
    fn class_n_no_intra_extreme_failure() {
        // 三类同框新低不构成失败（生成语义是全员打点）
        let segs = vec![
            mk_seg(0, 1, 30.0, 20.0, 0),
            mk_seg(1, -1, 10.0, 4.0, 10),
            mk_seg(2, 1, 9.0, 5.0, 20),
            mk_seg(3, 1, 18.0, 12.0, 30),
            mk_seg(4, -1, 17.0, 11.0, 35),
        ];
        let zs = vec![
            mk_zs(25.0, 18.0, vec![0], true),
            mk_zs(8.0, 2.0, vec![1, 2], true),
            mk_zs(16.0, 11.0, vec![3, 4], true),
        ];
        let e = ev_buy(3, 'a', 3, 30, 12.0, 2, 0);
        let v = judge_bsp(35, &zs, &segs, &[e], None);
        assert_eq!(v[0].state, "pending");
    }

    #[test]
    fn all_classes_buy_sell_matrix() {
        // 自动枚举 1..n：每类 Buy/Sell 各走 Correct 与 Wrong
        for cls in 1..=8 {
            for level in [0, 1, 2] {
                let (segs_up, zs_up) = chain_buy_zs(true);
                let buy = ev_buy(cls, 'a', 1, 10, 4.0, 1, level);
                let v_ok = judge_bsp(40, &zs_up, &segs_up, &[buy], None);
                assert_eq!(v_ok[0].state, "correct", "buy cls={cls} kn={level}");
                assert_eq!(v_ok[0].cls, cls);
                assert_eq!(v_ok[0].level, level);

                let (segs_dn, zs_dn) = chain_buy_zs(false);
                let buy2 = ev_buy(cls, 'a', 1, 10, 4.0, 1, level);
                let v_bad = judge_bsp(40, &zs_dn, &segs_dn, &[buy2], None);
                assert_eq!(v_bad[0].state, "wrong", "buy fail cls={cls} kn={level}");

                // 卖：用一卖资格链（zs1 在上，成功=再下移）
                let segs_s = vec![
                    mk_seg(0, -1, 10.0, 4.0, 0),
                    mk_seg(1, 1, 30.0, 20.0, 10),
                    mk_seg(2, -1, 29.0, 21.0, 20),
                    mk_seg(3, -1, 8.0, 2.0, 30),
                    mk_seg(4, 1, 7.0, 3.0, 40),
                ];
                let zs_s_ok = vec![
                    mk_zs(8.0, 2.0, vec![0], true),
                    mk_zs(28.0, 22.0, vec![1, 2], true),
                    mk_zs(6.0, 1.5, vec![3, 4], true),
                ];
                let sell = ev_sell(cls, 'a', 1, 10, 30.0, 1, level);
                let vs_ok = judge_bsp(40, &zs_s_ok, &segs_s, &[sell], None);
                assert_eq!(vs_ok[0].state, "correct", "sell cls={cls} kn={level}");

                let segs_s_bad = vec![
                    mk_seg(0, -1, 10.0, 4.0, 0),
                    mk_seg(1, 1, 30.0, 20.0, 10),
                    mk_seg(2, -1, 29.0, 21.0, 20),
                    mk_seg(3, 1, 40.0, 32.0, 30),
                    mk_seg(4, -1, 39.0, 33.0, 40),
                ];
                let zs_s_bad = vec![
                    mk_zs(8.0, 2.0, vec![0], true),
                    mk_zs(28.0, 22.0, vec![1, 2], true),
                    mk_zs(38.0, 31.0, vec![3, 4], true),
                ];
                let sell2 = ev_sell(cls, 'a', 1, 10, 30.0, 1, level);
                let vs_bad = judge_bsp(40, &zs_s_bad, &segs_s_bad, &[sell2], None);
                assert_eq!(vs_bad[0].state, "wrong", "sell fail cls={cls} kn={level}");
            }
        }
    }

    #[test]
    fn same_judge_entry_for_k0_and_kn() {
        let (segs, zs) = chain_buy_zs(true);
        let e0 = ev_buy(4, 'b', 1, 10, 4.0, 1, 0);
        let e2 = ev_buy(4, 'b', 1, 10, 4.0, 1, 2);
        let v0 = judge_bsp(40, &zs, &segs, &[e0], None);
        let v2 = judge_bsp(40, &zs, &segs, &[e2], None);
        assert_eq!(v0[0].state, v2[0].state);
        assert_eq!(v0[0].reason, v2[0].reason);
        assert_eq!(v0[0].level, 0);
        assert_eq!(v2[0].level, 2);
    }

    #[test]
    fn collect_events_covers_all_frame_kinds() {
        let b1 = Buy1Frame {
            seq: 0,
            zs_seq: 1,
            x: 10,
            price: 1.0,
            label: "1Ba".into(),
            seg_idx: 1,
            level: 0,
        };
        let s1 = Sell1Frame {
            seq: 0,
            zs_seq: 1,
            x: 11,
            price: 2.0,
            label: "1Sa".into(),
            seg_idx: 2,
            level: 0,
        };
        let b2 = Buy2Frame {
            seq: 0,
            zs_seq: 1,
            x: 12,
            price: 1.1,
            label: "2Ba".into(),
            seg_idx: 3,
            level: 0,
        };
        let s2 = Sell2Frame {
            seq: 0,
            zs_seq: 1,
            x: 13,
            price: 1.9,
            label: "2Sa".into(),
            seg_idx: 4,
            level: 0,
        };
        let bn = BuyNFrame {
            seq: 0,
            zs_seq: 2,
            cls: 7,
            x: 14,
            price: 3.0,
            label: "7Ba".into(),
            seg_idx: 5,
            level: 0,
        };
        let sn = SellNFrame {
            seq: 0,
            zs_seq: 2,
            cls: 7,
            x: 15,
            price: 4.0,
            label: "7Sa".into(),
            seg_idx: 6,
            level: 0,
        };
        let evs = collect_bs_events(&[b1], &[s1], &[b2], &[s2], &[bn], &[sn]);
        assert_eq!(evs.len(), 6);
        assert!(evs.iter().any(|e| e.cls == 7 && e.side == BsSide::Buy));
        assert!(evs.iter().any(|e| e.cls == 7 && e.side == BsSide::Sell));
    }

    fn load_002003_m1() -> Vec<crate::kline::KlineBar> {
        let data_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../a_Data");
        assert!(data_root.join("002003").exists(), "a_Data/002003 missing");
        let root = crate::resolve_data_root(Some(data_root.to_str().unwrap()));
        crate::load_klines(
            &root,
            "002003",
            "2004/07/19 10:47:00",
            "2004/07/20 13:09:00",
            crate::KlinePeriod::M1,
        )
        .expect("load 002003")
    }

    fn k0_verdict_at(
        bars: &[crate::kline::KlineBar],
        asof: usize,
        label: &str,
        bsp_x: i32,
    ) -> BsVerdictFrame {
        use crate::combine::build_kline_combine_bundle;
        let bundle = build_kline_combine_bundle(&bars[..=asof]);
        bundle
            .bs_verdict_k0_frames
            .into_iter()
            .find(|v| v.label == label && v.bsp_x == bsp_x)
            .unwrap_or_else(|| panic!("missing {label} bsp_x={bsp_x} at asof={asof}"))
    }

    #[test]
    fn stepwise_matches_truncated_prefix() {
        let (segs, zs) = chain_buy_zs(true);
        let e = ev_buy(1, 'a', 1, 10, 4.0, 1, 0);
        let mut store = HashMap::new();
        let mut last = Vec::new();
        for asof in [10, 20, 30, 40] {
            last = judge_level(asof, &zs, &segs, std::slice::from_ref(&e), &mut store, None);
            let fresh = judge_bsp(asof, &zs, &segs, std::slice::from_ref(&e), None);
            assert_eq!(last[0].state, fresh[0].state, "asof={asof}");
        }
        assert_eq!(last[0].state, "correct");
    }

    /// 强制验收：002003 1min K0 idx=12 的 4Sa，首次证伪在升破本框 ZG 的 step=17。
    #[test]
    fn k0_1min_idx12_4sa_wrong_at_17() {
        let bars = load_002003_m1();
        assert!(bars.len() > 17);
        for asof in 12..17 {
            let v = k0_verdict_at(&bars, asof, "4Sa", 12);
            assert_eq!(v.state, "pending", "asof={asof} must not be Wrong yet");
            assert!(v.invalid_x.is_none());
        }
        let at17 = k0_verdict_at(&bars, 17, "4Sa", 12);
        assert_eq!(at17.state, "wrong");
        assert_eq!(at17.invalid_x, Some(17));
        assert_eq!(at17.reason, "leave_above_zg");
        assert!(at17.invalid_x.unwrap() >= at17.bsp_x);
        for asof in [18usize, 20, 40, bars.len() - 1] {
            let v = k0_verdict_at(&bars, asof, "4Sa", 12);
            assert_eq!(v.state, "wrong", "asof={asof} must stay Wrong");
            assert_eq!(v.invalid_x, Some(17));
        }
    }

    /// 强制验收：同窗 1Ba@12，同框新低 11.68 在 step=14 首次证伪。
    #[test]
    fn k0_1min_idx12_1ba_wrong_at_14() {
        let bars = load_002003_m1();
        assert!(bars.len() > 14);
        for asof in 12..14 {
            let v = k0_verdict_at(&bars, asof, "1Ba", 12);
            assert_eq!(v.state, "pending", "asof={asof} must not be Wrong yet");
        }
        let at14 = k0_verdict_at(&bars, 14, "1Ba", 12);
        assert_eq!(at14.state, "wrong");
        assert_eq!(at14.invalid_x, Some(14));
        assert_eq!(at14.reason, "same_zs_new_extreme");
        let at_end = k0_verdict_at(&bars, bars.len() - 1, "1Ba", 12);
        assert_eq!(at_end.state, "wrong");
        assert_eq!(at_end.invalid_x, Some(14));
    }

    /// 三类+：尚未形成后续 ZS，但非本框成员已反向离开 ZG/ZD → 立即 Wrong。
    #[test]
    fn class_n_reverse_leave_is_failure() {
        let segs = vec![
            mk_seg(0, 1, 30.0, 20.0, 0),
            mk_seg(1, -1, 10.0, 4.0, 10),
            mk_seg(2, 1, 9.0, 5.0, 20),
            mk_seg(3, 1, 18.0, 12.0, 30), // 3Ba 所在框
            mk_seg(4, -1, 10.0, 8.0, 35), // 非本框：跌破 zd=11
        ];
        let zs = vec![
            mk_zs(25.0, 18.0, vec![0], true),
            mk_zs(8.0, 2.0, vec![1, 2], true),
            mk_zs(16.0, 11.0, vec![3], true),
        ];
        let e = ev_buy(3, 'a', 3, 30, 12.0, 2, 0);
        let v_early = judge_bsp(30, &zs, &segs, &[e.clone()], None);
        assert_eq!(v_early[0].state, "pending");
        let v = judge_bsp(35, &zs, &segs, &[e], None);
        assert_eq!(v[0].state, "wrong");
        assert_eq!(v[0].invalid_x, Some(35));
        assert_eq!(v[0].reason, "leave_below_zd");
    }

    #[test]
    fn class_n_sell_reverse_leave_is_failure() {
        let segs = vec![
            mk_seg(0, -1, 10.0, 4.0, 0),
            mk_seg(1, 1, 30.0, 20.0, 10),
            mk_seg(2, -1, 12.0, 6.0, 20),
            mk_seg(3, 1, 11.0, 7.0, 25),
            mk_seg(4, 1, 18.0, 13.0, 30), // 非本框：升破 zg=12
        ];
        let zs = vec![
            mk_zs(8.0, 2.0, vec![0], true),
            mk_zs(28.0, 18.0, vec![1], true),
            mk_zs(12.0, 5.0, vec![2, 3], true),
        ];
        let e = ev_sell(3, 'a', 2, 20, 12.0, 2, 0);
        let v = judge_bsp(30, &zs, &segs, &[e], None);
        assert_eq!(v[0].state, "wrong");
        assert_eq!(v[0].invalid_x, Some(30));
        assert_eq!(v[0].reason, "leave_above_zg");
    }

    /// 成功事件更晚、失败事件更早 → 取最早失败。
    #[test]
    fn earliest_failure_beats_later_success() {
        let segs = vec![
            mk_seg(0, 1, 30.0, 20.0, 0),
            mk_seg(1, -1, 10.0, 4.0, 10),
            mk_seg(2, 1, 9.0, 5.0, 20),
            mk_seg(3, -1, 6.0, 2.0, 25), // 同框新低 → 失败
            mk_seg(4, 1, 18.0, 12.0, 30),
            mk_seg(5, -1, 17.0, 13.0, 40), // 后续上移 ZS → 成功更晚
        ];
        let zs = vec![
            mk_zs(25.0, 18.0, vec![0], true),
            mk_zs(8.0, 2.0, vec![1, 2, 3], true),
            mk_zs(16.0, 11.0, vec![4, 5], true),
        ];
        let e = ev_buy(1, 'a', 1, 10, 4.0, 1, 0);
        let v = judge_bsp(40, &zs, &segs, &[e], None);
        assert_eq!(v[0].state, "wrong");
        assert_eq!(v[0].invalid_x, Some(25));
        assert!(v[0].confirm_x.is_none());
    }

    /// 同一 x 同时命中成功/失败：成功优先（与 apply_hits 单调状态机一致）。
    #[test]
    fn same_x_success_and_failure_picks_correct() {
        let segs = vec![
            mk_seg(0, 1, 30.0, 20.0, 0),
            mk_seg(1, -1, 10.0, 4.0, 10),
            mk_seg(2, 1, 9.0, 5.0, 20),
            mk_seg(3, 1, 18.0, 1.0, 30), // 同时升破 zg=8 且跌破 zd=2
        ];
        let zs = vec![
            mk_zs(25.0, 18.0, vec![0], true),
            mk_zs(8.0, 2.0, vec![1, 2], true),
        ];
        let e = ev_buy(1, 'a', 1, 10, 4.0, 1, 0);
        let v = judge_bsp(30, &zs, &segs, &[e], None);
        assert_eq!(v[0].state, "correct");
        assert_eq!(v[0].confirm_x, Some(30));
        assert_eq!(v[0].reason, "leave_above_zg");
    }
}
