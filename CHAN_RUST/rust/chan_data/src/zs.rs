//! 原生缠论中枢（ZS）模块：复用流水线 `LevelSegment`（段/连线，已是当前 Rust 版
//! 缠论「形态学元素」），在每层（K0=level1 / K1=level2 … 全层同构）上计算原生中枢。
//!
//! 设计红线（最高优先级约束，来自用户）：
//! - 只读已冻结段 `segs`（调用方传入 `LevelState.segments`，排除 `active_unit`），天然无未来函数；
//! - 不修改任何已实现元素逻辑（合并引擎 / 分型 / 段构造 / 层级递归），只新增、不改动；
//! - 中枢的进/出段引用相邻 `LevelSegment.idx`（Rust「段」），不引入 Python 式「笔(bi)」。
//!
//! 与原生缠论对齐：
//! - 中枢由 ≥3 连续重叠段构成，区间 [ZG,ZD]（ZG=max(段low), ZD=min(段high)），[DD,GG] 为极值；
//! - 延伸采用原生「离开-返回」：离开段不重叠后，返回段再重叠则延伸同一中枢（替换 v1 的 i=j 直接关闭）；
//! - 含中枢方向 dir、进/出段 in/out_seg_idx、九段重叠升级、combine 合并、one_bi_zs 单段中枢、
//!   normal/over_seg/auto 多算法；三类买卖点仅预留字段，本模块不做判定。

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::pipeline::{LevelBundleOut, LevelSegment};

/// 中枢合并模式
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ZSCombineMode {
    /// 以 [ZG,ZD] 区间重叠判定合并
    Zs,
    /// 以 [DD,GG] 极值区间重叠判定合并
    Peak,
}

/// 中枢算法
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ZSAlgo {
    /// 普通：≥3 连续段互相重叠成中枢（贴合原生「≥3 重叠成中枢」）
    Normal,
    /// 跨段：允许首末段重叠、中段跨越成中枢
    OverSeg,
    /// 自动：等同 Normal
    Auto,
}

/// 原生中枢配置
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct ZSConfig {
    /// 是否对相邻重叠中枢做合并
    pub need_combine: bool,
    /// 合并判定所用的区间
    pub zs_combine_mode: ZSCombineMode,
    /// 单段（单笔）是否可独立成中枢
    pub one_bi_zs: bool,
    /// 成中枢算法
    pub zs_algo: ZSAlgo,
}

impl Default for ZSConfig {
    fn default() -> Self {
        Self {
            need_combine: true,
            zs_combine_mode: ZSCombineMode::Zs,
            one_bi_zs: false,
            zs_algo: ZSAlgo::Normal,
        }
    }
}

impl ZSConfig {
    /// 成中枢所需的最小种子段数（贴合原生「≥3 重叠成中枢」；单段模式为 1）
    fn seed_len(&self) -> usize {
        if self.one_bi_zs {
            1
        } else {
            3
        }
    }
}

/// 原生缠论中枢（内部计算态，不序列化；序列化镜像见 `ZSFrame`）
#[derive(Debug, Clone)]
pub struct ZS {
    /// 所属层号（与 combine/line/fractal 同号：K0=1, K1=2 …）
    pub level: i32,
    /// 首段逻辑 idx（锚定上层单元序号，便于 Flutter/ML 回查）
    pub start_idx: i64,
    /// 末段逻辑 idx（延伸/离开-返回后）
    pub end_idx: i64,
    /// 首段在 `segs` 中的下标
    pub start_seg: usize,
    /// 末段在 `segs` 中的下标（离开-返回后可能为回返段）
    pub end_seg: usize,
    /// 上沿 ZG = max(覆盖段 low)  ← 最高的低
    pub zg: f64,
    /// 下沿 ZD = min(覆盖段 high) ← 最低的高
    pub zd: f64,
    /// 区间最高点 GG（三类买卖点包络）
    pub gg: f64,
    /// 区间最低点 DD
    pub dd: f64,
    /// 中轴 mid = (ZG+ZD)/2
    pub mid: f64,
    /// 中枢方向：取首段 LevelSegment.dir（预留三类买卖点）
    pub dir: i32,
    /// 进段 idx = 首段前一段的 LevelSegment.idx（相邻段，非「笔」；预留）
    pub in_seg_idx: Option<i64>,
    /// 出段 idx = 末段后一段的 LevelSegment.idx（相邻段，预留三类买卖点）
    pub out_seg_idx: Option<i64>,
    /// 是否单段中枢
    pub is_one_bi_zs: bool,
    /// 是否九段重叠升级（覆盖段数 ≥9）
    pub is_nine_seg_upgrade: bool,
    /// 末态确认（step 模式下逐步为 true）
    pub is_sure: bool,
    /// 实际构成中枢的段下标（可能因「离开-返回」跳过离开段，非连续），仅内部用于区间重算
    member_segs: Vec<usize>,
}

/// 原生中枢镜像框（复用 `KuaDuanV1Frame` 渲染：high=ZD, low=ZG；新增 dir/进出段/升级标记）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ZSFrame {
    /// 本层中枢序号（1-based，按时间先后）
    pub seq: i32,
    /// 主图 x 区间（已锚定 1 分钟 K）：取首/末段极点 K
    pub x1: i32,
    pub x2: i32,
    /// 上沿（更高价，=ZD=min(high_i)）
    pub high: f64,
    /// 下沿（更低价，=ZG=max(low_i)）
    pub low: f64,
    /// 所属层号（与 combine/line 同号）
    pub level: i32,
    /// 覆盖段数（种子3 + 延伸）
    pub count: usize,
    /// 中枢方向（首段方向）
    pub dir: i32,
    /// 是否单段中枢
    pub is_one_bi_zs: bool,
    /// 是否九段重叠升级
    pub is_nine_seg_upgrade: bool,
    /// 是否末态确认
    pub is_sure: bool,
    /// 进段 idx（相邻 LevelSegment.idx）
    pub in_seg_idx: Option<i64>,
    /// 出段 idx（相邻 LevelSegment.idx）
    pub out_seg_idx: Option<i64>,
}

/// 段 u 与中枢区间 [ZG,ZD] 相交即重叠（标准区间相交：u.high ≥ ZG 且 u.low ≤ ZD）
#[inline]
fn seg_overlaps(zg: f64, zd: f64, u: &LevelSegment) -> bool {
    u.high >= zg && u.low <= zd
}

/// 由若干段重算中枢区间几何
fn range_of(segs: &[LevelSegment], members: &[usize]) -> (f64, f64, f64, f64) {
    let mut zg = f64::NEG_INFINITY;
    let mut zd = f64::INFINITY;
    let mut gg = f64::NEG_INFINITY;
    let mut dd = f64::INFINITY;
    for &m in members {
        let s = &segs[m];
        zg = zg.max(s.low);
        zd = zd.min(s.high);
        gg = gg.max(s.high);
        dd = dd.min(s.low);
    }
    (zg, zd, gg, dd)
}

/// 由已确定的成员段构造中枢（区间/方向/进出段均由此推导）
fn make_zs(level: i32, members: &[usize], segs: &[LevelSegment], is_one_bi: bool) -> ZS {
    let (zg, zd, gg, dd) = range_of(segs, members);
    let start_seg = members[0];
    let end_seg = *members.last().unwrap();
    let first = &segs[start_seg];
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
        is_one_bi_zs: is_one_bi,
        is_nine_seg_upgrade: members.len() >= 9,
        is_sure: true,
        member_segs: members.to_vec(),
    }
}

/// 将段（下标 pos）延伸进开放中枢，重算区间几何与末态
fn extend_zs(z: &mut ZS, segs: &[LevelSegment], pos: usize) {
    z.member_segs.push(pos);
    let s = &segs[pos];
    z.zg = z.zg.max(s.low);
    z.zd = z.zd.min(s.high);
    z.gg = z.gg.max(s.high);
    z.dd = z.dd.min(s.low);
    z.mid = (z.zg + z.zd) / 2.0;
    z.end_seg = pos;
    z.end_idx = s.idx;
    z.is_nine_seg_upgrade = z.member_segs.len() >= 9;
}

/// 从 `segs[start]` 起尝试构成新中枢；命中返回 Some(ZS)，否则 None。
/// 仅检测种子窗口（普通=3 连续互相重叠；跨段=首末重叠；单段=1）。
fn try_construct_from(segs: &[LevelSegment], start: usize, level: i32, cfg: &ZSConfig) -> Option<ZS> {
    let n = segs.len();
    if cfg.one_bi_zs {
        if start >= n {
            return None;
        }
        let members = vec![start];
        return Some(make_zs(level, &members, segs, true));
    }
    let w = 3usize;
    if start + w > n {
        return None;
    }
    let a = &segs[start];
    let b = &segs[start + 1];
    let c = &segs[start + 2];
    let ok = match cfg.zs_algo {
        ZSAlgo::Normal | ZSAlgo::Auto => {
            // 三者互相重叠：min(high) > max(low)
            let min_high = a.high.min(b.high).min(c.high);
            let max_low = a.low.max(b.low).max(c.low);
            min_high > max_low
        }
        ZSAlgo::OverSeg => {
            // 跨段：首末段重叠即可（中段允许跨越/不重叠）
            let min_high = a.high.min(c.high);
            let max_low = a.low.max(c.low);
            min_high > max_low
        }
    };
    if !ok {
        return None;
    }
    let members = vec![start, start + 1, start + 2];
    Some(make_zs(level, &members, segs, false))
}

/// 在单层段序列上计算原生中枢（全层同构：每层调用同一函数）。
/// 只读已冻结段 `segs`，无未来函数。
pub fn find_zs(segs: &[LevelSegment], level: i32, cfg: &ZSConfig) -> Vec<ZS> {
    let n = segs.len();
    if n < cfg.seed_len() {
        return Vec::new();
    }
    let mut zs_list: Vec<ZS> = Vec::new();
    let mut cur: Option<ZS> = None;
    let mut i = 0usize;
    while i < n {
        // 1) 尝试延伸当前开放中枢
        let mut extended = false;
        if let Some(z) = cur.as_mut() {
            if seg_overlaps(z.zg, z.zd, &segs[i]) {
                // 普通延伸：本段与 [ZG,ZD] 重叠
                extend_zs(z, segs, i);
                extended = true;
            } else if i + 1 < n && seg_overlaps(z.zg, z.zd, &segs[i + 1]) {
                // 离开-返回：离开段(segs[i])不重叠，但返回段(segs[i+1])重叠
                // → 延伸同一中枢，离开段被跳过（不含入 member_segs）
                extend_zs(z, segs, i + 1);
                i += 1; // 消耗返回段（离开段已在流程中跳过）
                extended = true;
            }
        }
        if extended {
            i += 1;
            continue;
        }
        // 2) 当前无开放中枢 或 中枢已因「离开段后无返回段」而闭合
        if cur.is_some() {
            zs_list.push(cur.take().unwrap());
            // segs[i]（离开段）作为新候选起点继续，不前进
        }
        match try_construct_from(segs, i, level, cfg) {
            Some(z) => {
                let len = z.member_segs.len();
                cur = Some(z);
                i += len;
            }
            None => {
                i += 1;
            }
        }
    }
    if let Some(z) = cur.take() {
        zs_list.push(z);
    }
    // 3) 收尾：重算进/出段、九段升级，并按需合并相邻重叠中枢
    finalize(zs_list, segs, cfg)
}

/// 收尾处理：重算进/出段与九段升级，并按需合并相邻重叠中枢
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
        z.is_nine_seg_upgrade = z.member_segs.len() >= 9;
    }
    if cfg.need_combine {
        try_combine(&mut zs_list, segs);
    }
    zs_list
}

/// 两区间 [lo1,hi1] 与 [lo2,hi2] 是否相交（lo ≤ hi）
#[inline]
fn ranges_overlap(lo1: f64, hi1: f64, lo2: f64, hi2: f64) -> bool {
    lo1 <= hi2 && lo2 <= hi1
}

/// 合并相邻重叠中枢（zs 模式比 [ZG,ZD]，peak 模式比 [DD,GG]；单段中枢不参与合并）
fn try_combine(zs_list: &mut Vec<ZS>, segs: &[LevelSegment]) {
    let mut changed = true;
    while changed {
        changed = false;
        let mut k = 0;
        while k + 1 < zs_list.len() {
            let overlap = ranges_overlap(
                zs_list[k].zg,
                zs_list[k].zd,
                zs_list[k + 1].zg,
                zs_list[k + 1].zd,
            );
            // 单段中枢不参与合并
            let one_bi = zs_list[k].is_one_bi_zs || zs_list[k + 1].is_one_bi_zs;
            if overlap && !one_bi {
                let merged = merge_two(&zs_list[k], &zs_list[k + 1], segs);
                zs_list[k] = merged;
                zs_list.remove(k + 1);
                changed = true;
                // 不前进 k，重新检查合并后的与新后继
            } else {
                k += 1;
            }
        }
    }
}

/// 合并两个中枢为成员段并集
fn merge_two(a: &ZS, b: &ZS, segs: &[LevelSegment]) -> ZS {
    let mut members: Vec<usize> = a.member_segs.iter().chain(b.member_segs.iter()).copied().collect();
    members.sort_unstable();
    members.dedup();
    let (zg, zd, gg, dd) = range_of(segs, &members);
    let start_seg = *members.first().unwrap();
    let end_seg = *members.last().unwrap();
    let n = segs.len();
    ZS {
        level: a.level,
        start_idx: segs[start_seg].idx,
        end_idx: segs[end_seg].idx,
        start_seg,
        end_seg,
        zg,
        zd,
        gg,
        dd,
        mid: (zg + zd) / 2.0,
        dir: a.dir, // 取前者方向
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
        is_one_bi_zs: false,
        is_nine_seg_upgrade: members.len() >= 9,
        is_sure: true,
        member_segs: members,
    }
}

/// 原生中枢 → 镜像框（Flutter 直接复用合并框渲染管线）
pub fn zs_to_frames(zs_list: &[ZS], segment_by_idx: &HashMap<i64, &LevelSegment>) -> Vec<ZSFrame> {
    zs_list
        .iter()
        .enumerate()
        .filter_map(|(i, z)| {
            let s = segment_by_idx.get(&z.start_idx)?;
            let e = segment_by_idx.get(&z.end_idx)?;
            Some(ZSFrame {
                seq: (i + 1) as i32,
                x1: s.begin_pole_x.min(e.begin_pole_x),
                x2: s.end_pole_x.max(e.end_pole_x),
                high: z.zd,
                low: z.zg,
                level: z.level,
                count: z.member_segs.len(),
                dir: z.dir,
                is_one_bi_zs: z.is_one_bi_zs,
                is_nine_seg_upgrade: z.is_nine_seg_upgrade,
                is_sure: z.is_sure,
                in_seg_idx: z.in_seg_idx,
                out_seg_idx: z.out_seg_idx,
            })
        })
        .collect()
}

/// 由单层段序列直接产出该层原生中枢镜像框（只读冻结段，无未来函数）
pub fn level_zs_frames(segs: &[LevelSegment], level: i32, cfg: &ZSConfig) -> Vec<ZSFrame> {
    let zs_list = find_zs(segs, level, cfg);
    zs_frames_from_list(&zs_list, segs, level)
}

/// 由「已算好的原生中枢列表」直接产出该层原生中枢镜像框（供 export 复用同一份 zs_list，
/// 同时挂 zs_frames 与 bsp_frames，避免重复计算且不引入未来函数）
pub fn zs_frames_from_list(zs_list: &[ZS], segs: &[LevelSegment], _level: i32) -> Vec<ZSFrame> {
    let segment_by_idx: HashMap<i64, &LevelSegment> = segs.iter().map(|s| (s.idx, s)).collect();
    zs_to_frames(zs_list, &segment_by_idx)
}

/// 每层段序列 → 该层原生中枢框（全层同构，复用 find_zs + zs_to_frames）
pub fn build_zs_for_levels(levels: &[LevelBundleOut], cfg: &ZSConfig) -> Vec<Vec<ZSFrame>> {
    levels
        .iter()
        .map(|lv| level_zs_frames(&lv.segments, lv.level, cfg))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pipeline::LevelBundleOut;

    fn mk_seg(idx: i64, dir: i32, high: f64, low: f64) -> LevelSegment {
        LevelSegment {
            idx,
            dir,
            begin_confirm_x: 0,
            end_confirm_x: 0,
            begin_pole_x: 0,
            end_pole_x: 0,
            open: low,
            high,
            low,
            close: high,
            volume: 0.0,
            begin_fractal_x1: 0,
            begin_fractal_x2: 0,
            end_fractal_x1: 0,
            end_fractal_x2: 0,
            begin_fractal_high: high,
            begin_fractal_low: low,
            end_fractal_high: high,
            end_fractal_low: low,
            is_bootstrap: false,
            is_promoted_default: false,
        }
    }

    #[test]
    fn find_zs_two_disjoint_groups() {
        // level=1：两组各 3 段互相重叠，中间被一段隔开 → 2 个中枢
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 22.0, 12.0),
            mk_seg(2, 1, 21.0, 11.0),
            mk_seg(3, 1, 35.0, 25.0), // 不重叠 → 闭合第一组
            mk_seg(4, 1, 40.0, 30.0),
            mk_seg(5, 1, 42.0, 32.0),
            mk_seg(6, 1, 41.0, 31.0),
        ];
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        assert_eq!(zs.len(), 2, "应检出 2 个原生中枢");
        assert_eq!(zs[0].zg, 12.0); // max(low)=12
        assert_eq!(zs[0].zd, 20.0); // min(high)=20
        assert_eq!(zs[1].start_idx, 3);
        assert_eq!(zs[1].end_idx, 6);
    }

    #[test]
    fn find_zs_extend_on_leave_return() {
        // 离开段不重叠后，返回段再重叠 → 延伸同一中枢（离开段被跳过）
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 22.0, 12.0),
            mk_seg(2, 1, 21.0, 11.0),
            mk_seg(3, 1, 40.0, 30.0), // 离开段：不重叠
            mk_seg(4, 1, 19.0, 9.0),  // 返回段：重叠 [12,20] → 延伸同一中枢
            mk_seg(5, 1, 23.0, 13.0), // 继续重叠 → 延伸
        ];
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        assert_eq!(zs.len(), 1, "离开-返回应并成一个中枢");
        assert_eq!(zs[0].start_idx, 0);
        assert_eq!(zs[0].end_idx, 5);
        // member_segs 应含 [0,1,2,4,5]，跳过离开段 3
        assert_eq!(zs[0].member_segs, vec![0, 1, 2, 4, 5]);
        assert_eq!(zs[0].member_segs.len(), 5);
    }

    #[test]
    fn find_zs_two_leaves_close() {
        // 离开段后紧接不重叠段 → 中枢闭合，离开段成为下一组起点
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 22.0, 12.0),
            mk_seg(2, 1, 21.0, 11.0),
            mk_seg(3, 1, 40.0, 30.0), // 离开段 [30,40]：与ZS1[12,20]、与下组均不重叠
            mk_seg(4, 1, 60.0, 55.0), // 新组（与离开段无重叠）
            mk_seg(5, 1, 59.0, 54.0),
            mk_seg(6, 1, 61.0, 56.0),
        ];
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        assert_eq!(zs.len(), 2, "离开段后无返回 → 应闭合并起新中枢");
        assert_eq!(zs[0].end_idx, 2);
        assert_eq!(zs[1].start_idx, 4);
        assert_eq!(zs[1].end_idx, 6);
    }

    #[test]
    fn find_zs_one_bi_zs() {
        let cfg = ZSConfig {
            one_bi_zs: true,
            ..ZSConfig::default()
        };
        let segs = vec![mk_seg(0, 1, 20.0, 10.0)];
        let zs = find_zs(&segs, 1, &cfg);
        assert_eq!(zs.len(), 1, "单段模式应成 1 个中枢");
        assert!(zs[0].is_one_bi_zs);
        assert_eq!(zs[0].zg, 10.0);
        assert_eq!(zs[0].zd, 20.0);
    }

    #[test]
    fn find_zs_nine_seg_upgrade() {
        // 9 段连续重叠 → 1 个中枢且标记九段升级
        let segs: Vec<LevelSegment> = (0..9)
            .map(|k| mk_seg(k as i64, 1, 20.0 + (k as f64) * 0.1, 10.0))
            .collect();
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        assert_eq!(zs.len(), 1);
        assert!(zs[0].is_nine_seg_upgrade, "9 段重叠应标记九段升级");
        assert_eq!(zs[0].member_segs.len(), 9);
    }

    #[test]
    fn find_zs_less_than_three_returns_empty() {
        let segs = vec![mk_seg(0, 1, 20.0, 10.0), mk_seg(1, 1, 22.0, 12.0)];
        assert!(find_zs(&segs, 1, &ZSConfig::default()).is_empty());
    }

    #[test]
    fn build_zs_for_levels_maps_each_level() {
        let lv1 = LevelBundleOut {
            level: 1,
            confirms: vec![],
            segments: vec![
                mk_seg(10, 1, 20.0, 10.0),
                mk_seg(11, 1, 22.0, 12.0),
                mk_seg(12, 1, 21.0, 11.0),
            ],
            unit_bars: vec![],
            combine_frames: vec![],
            kuaduan_frames: vec![],
            zs_frames: vec![],
            bsp_frames: vec![],
            first_dir: 0,
            first_dir_x: 0,
            active_unit: None,
            segment_policy: "pending".to_string(),
            pending_unit: None,
        };
        let lv2 = LevelBundleOut {
            level: 2,
            confirms: vec![],
            segments: vec![
                mk_seg(20, 1, 50.0, 40.0),
                mk_seg(21, 1, 52.0, 42.0),
                mk_seg(22, 1, 51.0, 41.0),
            ],
            unit_bars: vec![],
            combine_frames: vec![],
            kuaduan_frames: vec![],
            zs_frames: vec![],
            bsp_frames: vec![],
            first_dir: 0,
            first_dir_x: 0,
            active_unit: None,
            segment_policy: "pending".to_string(),
            pending_unit: None,
        };
        let zs_by_level = build_zs_for_levels(&[lv1, lv2], &ZSConfig::default());
        assert_eq!(zs_by_level.len(), 2);
        assert_eq!(zs_by_level[0].len(), 1, "K0 原生中枢应命中");
        assert_eq!(zs_by_level[0][0].level, 1);
        assert_eq!(zs_by_level[1].len(), 1, "K1 原生中枢应命中");
        assert_eq!(zs_by_level[1][0].level, 2);
    }

    #[test]
    fn pipeline_end_to_end_builds_zs() {
        // 离线接 run_pipeline：构造清晰交替涨跌腿的合成 K 线
        let bars = synthetic_zigzag_legs(16, 8, 2.0, 0.1);
        let opt = crate::pipeline::PipelineOptions::default();
        let res = crate::pipeline::run_pipeline(&bars, &opt);

        // 验证 export() 已把原生中枢框逐层挂到 LevelBundleOut.zs_frames
        assert!(
            !res.levels[0].zs_frames.is_empty(),
            "level=1 的 zs_frames 应非空（export 已挂载原生中枢框）",
        );
        println!(
            "K0原生中枢数={} 首中枢[ZG={:.2},ZD={:.2}]",
            res.levels[0].zs_frames.len(),
            res.levels[0].zs_frames.first().unwrap().low,
            res.levels[0].zs_frames.first().unwrap().high,
        );
    }

    /// 确定性「幅度递增锯齿 + 转折点 gap」合成 K 线（与 v1 测试同款）
    fn synthetic_zigzag_legs(_legs: usize, leg_len: usize, _step: f64, wick: f64) -> Vec<crate::kline::KlineBar> {
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
