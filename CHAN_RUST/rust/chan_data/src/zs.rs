//! 原生缠论中枢（ZS）：全层同构 `find_zs`，输入为各层原生段序列。
//! K0=分钟K每根一段；K1+=该层连线段。单段成枢、重叠延伸、离开闭合实线、末开放虚线。

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::pipeline::{LevelBundleOut, LevelSegment, LevelUnitBar};

/// 相邻中枢合并模式（peak 按 DD/GG）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ZSCombineMode {
    Zs,
    Peak,
}

/// 中枢配置
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct ZSConfig {
    pub need_combine: bool,
    pub zs_combine_mode: ZSCombineMode,
}

impl Default for ZSConfig {
    fn default() -> Self {
        Self {
            need_combine: true,
            zs_combine_mode: ZSCombineMode::Zs,
        }
    }
}

/// 运行时中枢（member_segs 为 segs 下标）
#[derive(Debug, Clone)]
pub struct ZS {
    pub level: i32,
    pub start_idx: i64,
    pub end_idx: i64,
    pub start_seg: usize,
    pub end_seg: usize,
    /// 中枢高（重叠区间上沿，常见命名 ZG）
    pub zg: f64,
    /// 中枢低（重叠区间下沿，常见命名 ZD）
    pub zd: f64,
    pub gg: f64,
    pub dd: f64,
    pub mid: f64,
    pub dir: i32,
    pub in_seg_idx: Option<i64>,
    pub out_seg_idx: Option<i64>,
    pub is_sure: bool,
    pub(crate) member_segs: Vec<usize>,
}

/// 中枢框（high=ZG 上沿, low=ZD 下沿, gg=GG, dd=DD）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ZSFrame {
    pub seq: i32,
    pub x1: i32,
    pub x2: i32,
    pub high: f64,
    pub low: f64,
    pub gg: f64,
    pub dd: f64,
    pub level: i32,
    pub count: usize,
    pub dir: i32,
    pub is_sure: bool,
    /// 本中枢最后一个成员段 idx（member_segs.last → segs[].idx）
    pub end_idx: i64,
    pub in_seg_idx: Option<i64>,
    pub out_seg_idx: Option<i64>,
}

/// 段与中枢重叠带 [ZD, ZG] 是否相交（ZG=上沿，ZD=下沿）。
#[inline]
fn seg_overlaps(zg: f64, zd: f64, u: &LevelSegment) -> bool {
    u.high >= zd && u.low <= zg
}

fn price_tick(segs: &[LevelSegment]) -> f64 {
    let mut tick = 0.01;
    for s in segs {
        let d = (s.high - s.low).abs();
        if d > 1e-12 && d < tick {
            tick = d;
        }
    }
    tick
}

fn is_flat_zs(zg: f64, zd: f64, tick: f64) -> bool {
    (zg - zd).abs() <= tick + 1e-12
}

/// 一字线：仅 open==close（勿用 high-low/tick 近一字误判）。
fn one_line_price(s: &LevelSegment) -> Option<f64> {
    if (s.open - s.close).abs() <= 1e-12 {
        return Some(s.open);
    }
    None
}

/// 返回 (ZG上沿, ZD下沿, GG, DD)。
fn range_of(segs: &[LevelSegment], members: &[usize]) -> (f64, f64, f64, f64) {
    let mut zg = f64::INFINITY;
    let mut zd = f64::NEG_INFINITY;
    let mut gg = f64::NEG_INFINITY;
    let mut dd = f64::INFINITY;
    for &m in members {
        let s = &segs[m];
        zg = zg.min(s.high);
        zd = zd.max(s.low);
        gg = gg.max(s.high);
        dd = dd.min(s.low);
    }
    (zg, zd, gg, dd)
}

fn zs_overlap_range(z: &ZS, segs: &[LevelSegment], tick: f64) -> (f64, f64) {
    if is_flat_zs(z.zg, z.zd, tick) {
        return (z.zg, z.zd);
    }
    if z.member_segs.is_empty() {
        return (z.zg, z.zd);
    }
    let (zg, zd, _, _) = range_of(segs, &z.member_segs);
    (zg, zd)
}

fn make_zs(
    level: i32,
    members: &[usize],
    segs: &[LevelSegment],
    is_sure: bool,
) -> ZS {
    let (mut zg, mut zd, gg, dd) = range_of(segs, members);
    let start_seg = members[0];
    let end_seg = *members.last().unwrap();
    let first = &segs[start_seg];
    // 仅真·一字线(open=close)锚定 ZG=ZD；近一字/小振幅不塌缩
    if let Some(anchor) = one_line_price(first) {
        zg = anchor;
        zd = anchor;
    }
    let n = segs.len();
    ZS {
        level,
        start_idx: first.idx,
        end_idx: segs[end_seg].idx,
        start_seg,
        end_seg,
        zg,
        zd,
        gg,
        dd,
        mid: (zg + zd) / 2.0,
        dir: first.dir,
        in_seg_idx: if start_seg > 0 {
            Some(segs[start_seg - 1].idx)
        } else {
            None
        },
        out_seg_idx: if end_seg + 1 < n {
            Some(segs[end_seg + 1].idx)
        } else {
            None
        },
        is_sure,
        member_segs: members.to_vec(),
    }
}

fn extend_zs(z: &mut ZS, segs: &[LevelSegment], pos: usize, tick: f64) {
    z.member_segs.push(pos);
    let s = &segs[pos];
    if !is_flat_zs(z.zg, z.zd, tick) {
        // ZD 下沿上抬；ZG 上沿下压
        if s.low > z.zd {
            z.zd = s.low;
        }
        if s.high < z.zg {
            z.zg = s.high;
        }
    }
    z.gg = z.gg.max(s.high);
    z.dd = z.dd.min(s.low);
    z.mid = (z.zg + z.zd) / 2.0;
    z.end_seg = pos;
    z.end_idx = s.idx;
}

/// 单段成枢（雏形 is_sure=false）
fn try_construct_from(segs: &[LevelSegment], start: usize, level: i32) -> Option<ZS> {
    if start >= segs.len() {
        return None;
    }
    Some(make_zs(level, &[start], segs, false))
}

/// 全层同构：重叠延伸；确认态离开→实线定型；动态离开→仍虚线（禁未来函数）。
pub fn find_zs(segs: &[LevelSegment], level: i32, cfg: &ZSConfig) -> Vec<ZS> {
    find_zs_with_confirmed(segs, level, cfg, segs.len())
}

/// `n_confirmed`=已冻结段数；其后为进行中 active 伪段。
/// 离开段下标 `i < n_confirmed` 才把上一枢定型为实线；动态离开保持虚线。
pub fn find_zs_with_confirmed(
    segs: &[LevelSegment],
    level: i32,
    cfg: &ZSConfig,
    n_confirmed: usize,
) -> Vec<ZS> {
    let n = segs.len();
    if n == 0 {
        return Vec::new();
    }
    let tick = price_tick(segs);
    let mut zs_list: Vec<ZS> = Vec::new();
    let mut cur: Option<ZS> = None;
    let mut i = 0usize;
    while i < n {
        if let Some(ref mut z) = cur {
            let (ozg, ozd) = zs_overlap_range(z, segs, tick);
            if seg_overlaps(ozg, ozd, &segs[i]) {
                extend_zs(z, segs, i, tick);
                i += 1;
                continue;
            }
            // 离开：仅确认Kn不重叠→定型实线；动态Kn离开→仍虚线（不用未来）
            z.is_sure = i < n_confirmed;
            zs_list.push(cur.take().unwrap());
            continue;
        }
        if let Some(z) = try_construct_from(segs, i, level) {
            cur = Some(z);
            i += 1;
        } else {
            i += 1;
        }
    }
    if let Some(mut z) = cur.take() {
        z.is_sure = false;
        zs_list.push(z);
    }
    finalize(zs_list, segs, cfg)
}

fn finalize(mut zs_list: Vec<ZS>, segs: &[LevelSegment], cfg: &ZSConfig) -> Vec<ZS> {
    let n = segs.len();
    for z in zs_list.iter_mut() {
        z.in_seg_idx = if z.start_seg > 0 {
            Some(segs[z.start_seg - 1].idx)
        } else {
            None
        };
        z.out_seg_idx = if z.end_seg + 1 < n {
            Some(segs[z.end_seg + 1].idx)
        } else {
            None
        };
    }
    if cfg.need_combine {
        try_combine(&mut zs_list, segs);
    }
    zs_list
}

#[inline]
fn ranges_overlap(lo1: f64, hi1: f64, lo2: f64, hi2: f64) -> bool {
    lo1 <= hi2 && lo2 <= hi1
}

fn try_combine(zs_list: &mut Vec<ZS>, segs: &[LevelSegment]) {
    let mut changed = true;
    while changed {
        changed = false;
        let mut k = 0;
        while k + 1 < zs_list.len() {
            let a = &zs_list[k];
            let b = &zs_list[k + 1];
            // ranges_overlap(lo, hi, …)：ZD=下沿、ZG=上沿
            let overlap = ranges_overlap(a.zd, a.zg, b.zd, b.zg);
            let block = a.is_sure && b.member_segs.len() == 1;
            if overlap && !block {
                let merged = merge_two(a, b, segs);
                zs_list[k] = merged;
                zs_list.remove(k + 1);
                changed = true;
            } else {
                k += 1;
            }
        }
    }
}

fn merge_two(a: &ZS, b: &ZS, segs: &[LevelSegment]) -> ZS {
    let mut members: Vec<usize> = a
        .member_segs
        .iter()
        .chain(b.member_segs.iter())
        .copied()
        .collect();
    members.sort_unstable();
    members.dedup();
    let z = make_zs(a.level, &members, segs, a.is_sure && b.is_sure);
    ZS {
        dir: a.dir,
        is_sure: a.is_sure && b.is_sure,
        ..z
    }
}

pub fn zs_to_frames(zs_list: &[ZS], segment_by_idx: &HashMap<i64, &LevelSegment>) -> Vec<ZSFrame> {
    zs_list
        .iter()
        .enumerate()
        .filter_map(|(i, z)| {
            let s = segment_by_idx.get(&z.start_idx)?;
            let e = segment_by_idx.get(&z.end_idx)?;
            Some(ZSFrame {
                seq: i as i32,
                x1: s.begin_pole_x.min(e.begin_pole_x),
                x2: s.end_pole_x.max(e.end_pole_x),
                high: z.zg,
                low: z.zd,
                gg: z.gg,
                dd: z.dd,
                level: z.level,
                count: z.member_segs.len(),
                dir: z.dir,
                is_sure: z.is_sure,
                end_idx: z.end_idx,
                in_seg_idx: z.in_seg_idx,
                out_seg_idx: z.out_seg_idx,
            })
        })
        .collect()
}

/// 进行中 Kn 单元 → 伪段（展示轨喂中枢/一类BS；不回写冻结段链）。
/// dir 锚定极点：上涨段低在 begin、高在 end；下跌段高在 begin、低在 end（供 buy1/sell1 打点）。
pub fn unit_to_segment(u: &LevelUnitBar) -> LevelSegment {
    let (px1, px2) = if u.x1 <= u.x2 {
        (u.x1, u.x2)
    } else {
        (u.x2, u.x1)
    };
    // 上涨：起点底、终点顶；下跌：起点顶、终点底
    let (bh, bl, eh, el) = if u.dir >= 0 {
        (u.low, u.low, u.high, u.high)
    } else {
        (u.high, u.high, u.low, u.low)
    };
    LevelSegment {
        idx: u.idx,
        dir: u.dir,
        begin_confirm_x: u.confirm_x,
        end_confirm_x: u.confirm_x,
        begin_pole_x: px1,
        end_pole_x: px2,
        open: u.open,
        high: u.high,
        low: u.low,
        close: u.close,
        volume: u.volume,
        begin_fractal_x1: u.x1,
        begin_fractal_x2: u.x2,
        end_fractal_x1: u.x1,
        end_fractal_x2: u.x2,
        begin_fractal_high: bh,
        begin_fractal_low: bl,
        end_fractal_high: eh,
        end_fractal_low: el,
        is_bootstrap: false,
        is_promoted_default: false,
    }
}

/// 冻结段 + 可选进行中（idx 未在冻结列表中则追加）。
pub fn segments_with_optional_active(
    frozen: &[LevelSegment],
    active: Option<&LevelUnitBar>,
) -> Vec<LevelSegment> {
    let mut out = frozen.to_vec();
    if let Some(u) = active {
        if !out.iter().any(|s| s.idx == u.idx) {
            out.push(unit_to_segment(u));
        }
    }
    out
}

pub fn level_zs_frames(segs: &[LevelSegment], level: i32, cfg: &ZSConfig) -> Vec<ZSFrame> {
    let zs_list = find_zs(segs, level, cfg);
    zs_frames_from_list(&zs_list, segs, level)
}

pub fn zs_frames_from_list(zs_list: &[ZS], segs: &[LevelSegment], _level: i32) -> Vec<ZSFrame> {
    let segment_by_idx: HashMap<i64, &LevelSegment> = segs.iter().map(|s| (s.idx, s)).collect();
    zs_to_frames(zs_list, &segment_by_idx)
}

pub fn build_zs_for_levels(levels: &[LevelBundleOut], cfg: &ZSConfig) -> Vec<Vec<ZSFrame>> {
    levels
        .iter()
        .map(|lv| {
            let n_confirmed = lv.segments.len();
            let segs = segments_with_optional_active(&lv.segments, lv.active_unit.as_ref());
            let zs_list = find_zs_with_confirmed(&segs, lv.level, cfg, n_confirmed);
            zs_frames_from_list(&zs_list, &segs, lv.level)
        })
        .collect()
}

/// 增量引擎占位：batch `find_zs` 与 export 对齐
pub struct ZSIncEngine {
    level: i32,
    cfg: ZSConfig,
}

impl ZSIncEngine {
    pub fn new(level: i32, cfg: ZSConfig) -> Self {
        Self { level, cfg }
    }

    pub fn on_new_seg(&mut self, _segs: &[LevelSegment], _seg_idx: usize) {}

    pub fn into_completed(self, segs: &[LevelSegment]) -> Vec<ZS> {
        find_zs(segs, self.level, &self.cfg)
    }
}

#[cfg(test)]
pub fn make_zs_for_test(
    level: i32,
    members: &[usize],
    segs: &[LevelSegment],
    is_sure: bool,
) -> ZS {
    make_zs(level, members, segs, is_sure)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_seg(idx: i64, dir: i32, high: f64, low: f64) -> LevelSegment {
        mk_seg_ohlc(idx, dir, high, low, low, high)
    }

    fn mk_seg_ohlc(
        idx: i64,
        dir: i32,
        high: f64,
        low: f64,
        open: f64,
        close: f64,
    ) -> LevelSegment {
        LevelSegment {
            idx,
            dir,
            begin_confirm_x: idx as i32,
            end_confirm_x: idx as i32,
            begin_pole_x: idx as i32,
            end_pole_x: idx as i32,
            open,
            high,
            low,
            close,
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

    fn empty_level(level: i32, segments: Vec<LevelSegment>) -> LevelBundleOut {
        LevelBundleOut {
            level,
            confirms: vec![],
            segments,
            unit_bars: vec![],
            combine_frames: vec![],
            zs_frames: vec![],
            buy1_frames: vec![],
            sell1_frames: vec![],
            buy2_frames: vec![],
            sell2_frames: vec![],
            buy_n_frames: vec![],
            sell_n_frames: vec![],
            first_dir: 0,
            first_dir_x: 0,
            active_unit: None,
            segment_policy: "pending".to_string(),
            pending_unit: None,
        }
    }

    #[test]
    fn single_seg_seed_prototype() {
        let segs = vec![mk_seg(0, 1, 20.0, 10.0)];
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        assert_eq!(zs.len(), 1);
        assert!(!zs[0].is_sure);
        assert_eq!(zs[0].member_segs, vec![0]);
    }

    /// open==close → 一字线锚定 ZG=ZD；仅小振幅但 open!=close 不塌缩。
    #[test]
    fn one_line_only_when_open_equals_close() {
        // 真一字：open=close=11.71，即便有影线也不另判
        let true_one = vec![mk_seg_ohlc(17, 1, 11.72, 11.70, 11.71, 11.71)];
        let zs1 = find_zs(&true_one, 0, &ZSConfig::default());
        assert_eq!(zs1.len(), 1);
        assert!((zs1[0].zg - 11.71).abs() < 1e-12);
        assert!((zs1[0].zd - 11.71).abs() < 1e-12);

        // 假近一字：high-low 很小但 open!=close → 不塌成 ZG=ZD
        let fake = vec![mk_seg_ohlc(18, 1, 11.73, 11.72, 11.72, 11.73)];
        let zs2 = find_zs(&fake, 0, &ZSConfig::default());
        assert_eq!(zs2.len(), 1);
        assert!(
            (zs2[0].zg - zs2[0].zd).abs() > 1e-12,
            "open!=close 不得 ZG=ZD: zg={} zd={}",
            zs2[0].zg,
            zs2[0].zd
        );
        assert!((zs2[0].zg - 11.73).abs() < 1e-12);
        assert!((zs2[0].zd - 11.72).abs() < 1e-12);
    }

    #[test]
    fn leave_closes_sure_no_bridge() {
        let segs = vec![
            mk_seg(0, 1, 11.7, 11.7),
            mk_seg(1, 1, 11.7, 11.7),
            mk_seg(2, 1, 11.73, 11.72),
            mk_seg(3, 1, 11.7, 11.7),
        ];
        let zs = find_zs(&segs, 0, &ZSConfig::default());
        assert!(zs.len() >= 2, "离开不桥接，应拆成多枢");
        assert!(zs[0].is_sure);
        let last = zs.last().unwrap();
        assert!(!last.is_sure);
    }

    #[test]
    fn overlap_extends() {
        let segs = vec![
            mk_seg(0, 1, 22.0, 12.0),
            mk_seg(1, 1, 21.0, 11.0),
            mk_seg(2, 1, 20.0, 10.0),
        ];
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        assert_eq!(zs.len(), 1);
        assert_eq!(zs[0].member_segs.len(), 3);
    }

    #[test]
    fn two_disjoint_groups() {
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 22.0, 12.0),
            mk_seg(2, 1, 21.0, 11.0),
            mk_seg(3, 1, 35.0, 25.0),
            mk_seg(4, 1, 40.0, 30.0),
            mk_seg(5, 1, 42.0, 32.0),
            mk_seg(6, 1, 41.0, 31.0),
        ];
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        assert_eq!(zs.len(), 2);
        // 常见命名：ZG=上沿、ZD=下沿
        assert_eq!(zs[0].zg, 20.0);
        assert_eq!(zs[0].zd, 12.0);
    }

    #[test]
    fn active_unit_included_for_open_zs() {
        use crate::pipeline::LevelUnitBar;

        let frozen = vec![
            mk_seg(0, 1, 22.0, 12.0),
            mk_seg(1, 1, 21.0, 11.0),
        ];
        let active = LevelUnitBar {
            idx: 2,
            dir: 1,
            x1: 2,
            x2: 3,
            open: 11.0,
            high: 20.5,
            low: 11.0,
            close: 20.0,
            volume: 0.0,
            confirm_x: 3,
        };
        let segs = segments_with_optional_active(&frozen, Some(&active));
        assert_eq!(segs.len(), 3);
        let zs = find_zs_with_confirmed(&segs, 1, &ZSConfig::default(), frozen.len());
        assert_eq!(zs.len(), 1);
        assert_eq!(zs[0].member_segs.len(), 3);
        assert!(!zs[0].is_sure);
    }

    /// 动态Kn离开不重叠：上一枢仍虚线（禁未来）；确认离开才定型
    #[test]
    fn active_leave_keeps_previous_unsure_until_confirm() {
        use crate::pipeline::LevelUnitBar;

        let frozen = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 22.0, 12.0),
            mk_seg(2, 1, 21.0, 11.0),
        ];
        let active = LevelUnitBar {
            idx: 3,
            dir: 1,
            x1: 3,
            x2: 4,
            open: 30.0,
            high: 40.0,
            low: 30.0,
            close: 35.0,
            volume: 0.0,
            confirm_x: 4,
        };
        let segs = segments_with_optional_active(&frozen, Some(&active));
        let zs_dyn = find_zs_with_confirmed(&segs, 1, &ZSConfig::default(), frozen.len());
        assert_eq!(zs_dyn.len(), 2);
        assert!(!zs_dyn[0].is_sure, "动态离开不得定型上一枢");
        assert!(!zs_dyn[1].is_sure);

        let mut confirmed = frozen.clone();
        confirmed.push(mk_seg(3, 1, 40.0, 30.0));
        let zs_cfm = find_zs(&confirmed, 1, &ZSConfig::default());
        assert_eq!(zs_cfm.len(), 2);
        assert!(zs_cfm[0].is_sure, "确认离开才定型");
        assert!(!zs_cfm[1].is_sure);
    }

    #[test]
    fn build_zs_for_levels_maps_each_level() {
        let lv1 = empty_level(
            1,
            vec![
                mk_seg(10, 1, 20.0, 10.0),
                mk_seg(11, 1, 22.0, 12.0),
                mk_seg(12, 1, 21.0, 11.0),
            ],
        );
        let zs_by_level = build_zs_for_levels(&[lv1], &ZSConfig::default());
        assert_eq!(zs_by_level.len(), 1);
        assert_eq!(zs_by_level[0].len(), 1);
    }

    #[test]
    fn pipeline_end_to_end_builds_zs() {
        let bars = synthetic_zigzag_legs(16, 8, 2.0, 0.1);
        let opt = crate::pipeline::PipelineOptions::default();
        let res = crate::pipeline::run_pipeline(&bars, &opt);
        assert!(!res.levels[0].zs_frames.is_empty());
    }

    fn synthetic_zigzag_legs(
        _legs: usize,
        leg_len: usize,
        _step: f64,
        wick: f64,
    ) -> Vec<crate::kline::KlineBar> {
        let legs: Vec<(f64, f64)> = vec![
            (100.0, 220.0),
            (214.0, 150.0),
            (144.0, 300.0),
            (294.0, 200.0),
            (194.0, 380.0),
            (374.0, 260.0),
            (254.0, 460.0),
            (454.0, 320.0),
            (314.0, 540.0),
            (534.0, 380.0),
            (374.0, 620.0),
        ];
        let mut bars = Vec::new();
        let mut i = 0i32;
        for (a, b) in legs {
            let dir = if b > a { 1.0 } else { -1.0 };
            let step = (b - a) / leg_len as f64;
            let mut price = a;
            for k in 0..leg_len {
                let open = price;
                let close = price + dir * step;
                let hi = if k == 0 {
                    open.max(close)
                } else {
                    open.max(close) + wick
                };
                let lo = if k == 0 {
                    open.min(close)
                } else {
                    open.min(close) - wick
                };
                bars.push(crate::kline::KlineBar {
                    idx: i,
                    time_ms: (i as i64) * 60_000,
                    time_text: format!("2024/01/01 09:30"),
                    open,
                    high: hi,
                    low: lo,
                    close,
                    volume: 1000.0,
                    amount: 0.0,
                    metrics: serde_json::Map::new(),
                });
                price = close;
                i += 1;
            }
        }
        bars
    }
}
