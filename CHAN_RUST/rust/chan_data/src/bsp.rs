//! 三类买卖点（BSP）模块：复用流水线 `LevelSegment`（段/连线，已是当前 Rust 版
//! 缠论「形态学元素」）与本模块同层的 `ZS`（原生中枢），在每层（K0=level1 / K1=level2 … 全层同构）上计算三类买卖点。
//!
//! 设计红线（最高优先级约束，来自用户）：
//! - 只读已冻结段 `segs` 与已冻结 `zs_list`（均来自 `LevelState`，排除 `active_unit`），天然无未来函数；
//! - 不修改任何已实现元素逻辑（合并引擎 / 分型 / 段构造 / 层级递归 / v1 算法 / 中枢 ZS），只新增、不改动；
//! - 不引入 Python 式「笔(bi)」；三类买卖点建立在 `LevelSegment`（=K(n-1)连线）与 `ZS` 上。
//!
//! 背驰策略（用户 2026-07-16 决策）：纯结构趋势末端，不做 MACD/力度背驰。
//! - 一类买卖点 = ≥ min_zs_cnt 个中枢构成的下跌/上涨「趋势」末段端点；
//! - 二类买卖点 = 一类之后向中枢返回但不破一类的回踩确认点；
//! - 三类买卖点 = 一类之后离开中枢并返回但不回中枢带（[ZG,ZD] 区间）的确认点。

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::pipeline::{LevelBundleOut, LevelSegment};
use crate::zs::{ZS, ZSConfig};

/// 三类买卖点配置（纯结构，无背驰；可调项贴合原版缠论口径）
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct BSPConfig {
    /// 构成「趋势」所需的最少中枢数（≥2 才是真趋势；默认 2）
    pub min_zs_cnt: usize,
    /// 二类回踩幅度上限：返回段幅度 / 离开段幅度 ≤ 该值（默认 1.0，即不限制幅度，只看是否破一类）
    pub max_bs2_rate: f64,
    /// 二类是否必须依附一类（默认 true：无一类不出二类）
    pub bsp2_follow_1: bool,
    /// 三类是否必须依附一类（默认 true：无一类不出三类）
    pub bsp3_follow_1: bool,
    /// 三类是否要求离开段突破中枢极值（peak）：离开段需越过 ZS 的 GG/DD（默认 false）
    pub bsp3_peak: bool,
}

impl Default for BSPConfig {
    fn default() -> Self {
        Self {
            min_zs_cnt: 2,
            max_bs2_rate: 1.0,
            bsp2_follow_1: true,
            bsp3_follow_1: true,
            bsp3_peak: false,
        }
    }
}

/// 单类买卖点（内部计算态，不序列化；序列化镜像见 `BSPFrame`）
#[derive(Debug, Clone)]
pub struct BSP {
    /// 类：1/2/3
    pub cls: i32,
    /// 是否买点（false=卖点）
    pub is_buy: bool,
    /// 点位价格（买点=段低点；卖点=段高点）
    pub price: f64,
    /// 主图 x（已锚定 1 分钟 K：取端点段 end_pole_x）
    pub x: i32,
    /// 端点所在 LevelSegment.idx
    pub seg_idx: i64,
    /// 关联的一类端点 LevelSegment.idx（二类/三类用；一类为 None）
    pub relate_seg_idx: Option<i64>,
}

/// 三类买卖点镜像框（序列化；Flutter 主图点标记直接消费）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BSPFrame {
    /// 类：1/2/3
    pub cls: i32,
    /// 是否买点（true=买，false=卖）
    pub is_buy: bool,
    /// 点位价格
    pub price: f64,
    /// 主图 x（端点段 end_pole_x）
    pub x: i32,
    /// 所属层号（与 combine/line/ZS 同号）
    pub level: i32,
    /// 端点 LevelSegment.idx
    pub seg_idx: i64,
    /// 关联一类端点 LevelSegment.idx（二类/三类；一类为 null）
    pub relate_seg_idx: Option<i64>,
}

/// 段幅度（用于二类回踩比例）
#[inline]
fn seg_range(s: &LevelSegment) -> f64 {
    (s.high - s.low).abs()
}

/// 在单层段序列 + 同层原生中枢上计算三类买卖点（全层同构：每层调用同一函数）。
/// 只读已冻结 `segs` 与已冻结 `zs_list`，无未来函数。
pub fn find_bsp(
    segs: &[LevelSegment],
    zs_list: &[ZS],
    _level: i32,
    cfg: &BSPConfig,
) -> Vec<BSP> {
    let n = segs.len();
    if n == 0 || zs_list.is_empty() {
        return Vec::new();
    }
    // idx → 在 segs 中的下标，便于按端点段定位相邻段
    let pos_of: HashMap<i64, usize> = segs.iter().enumerate().map(|(i, s)| (s.idx, i)).collect();

    // —— 1) 趋势分组：把同方向、连续单调（按中枢带 [ZG,ZD] 严格高低）的中枢串成「趋势段（run）」——
    // 相邻对 (a,b) 方向：b 中枢带整体高于 a（zg↑ 且 zd↑）→ 上涨；整体低于 a（zg↓ 且 zd↓）→ 下跌；
    // 带重叠/嵌套（无法判定单调）→ 0（不计入趋势，视为盘整）。单段中枢不参与趋势判定。
    // run 只在方向一致时延展；方向反转或含糊即切分为新 run（保证 run 内是单一方向趋势）。
    // 注：早期实现用「a 后首段方向 + dd/gg 极值」判定，但首段多为回踩腿（方向与净移动相反），
    // 且极值在窄幅震荡股中互相重叠，导致趋势几乎永不达标 → 全部 0 点。改用中枢带比较修复。
    let dir_of = |a: &ZS, b: &ZS| -> i32 {
        let up = b.zg > a.zg + 1e-9 && b.zd > a.zd + 1e-9;
        let down = b.zg < a.zg - 1e-9 && b.zd < a.zd - 1e-9;
        if up {
            1
        } else if down {
            -1
        } else {
            0
        }
    };

    let mut runs: Vec<Vec<usize>> = Vec::new();
    let mut cur: Vec<usize> = vec![0];
    let mut cur_dir: i32 = 0;
    for k in 1..zs_list.len() {
        let a = &zs_list[k - 1];
        let b = &zs_list[k];
        if a.is_one_bi_zs || b.is_one_bi_zs {
            runs.push(std::mem::take(&mut cur));
            cur = vec![k];
            cur_dir = 0;
            continue;
        }
        let d = dir_of(a, b);
        if d == 0 {
            // 含糊（带重叠/嵌套）→ 趋势断裂
            runs.push(std::mem::take(&mut cur));
            cur = vec![k];
            cur_dir = 0;
        } else if cur_dir == 0 {
            cur_dir = d;
            cur.push(k);
        } else if d == cur_dir {
            cur.push(k);
        } else {
            // 方向反转 → 新趋势从 b 起
            runs.push(std::mem::take(&mut cur));
            cur = vec![k];
            cur_dir = 0;
        }
    }
    runs.push(cur);

    // —— 2) 一类买卖点：趋势末段端点 ——
    // 每条一类记录其所属「达标趋势」的最后一个中枢下标（三类买卖点判定用）
    let mut class1: Vec<(BSP, usize)> = Vec::new();
    for run in &runs {
        if run.len() < cfg.min_zs_cnt {
            continue;
        }
        let first_z = &zs_list[run[0]];
        let last_z = &zs_list[*run.last().unwrap()];
        let declining_run = last_z.dd < first_z.dd; // 下跌趋势（末端出买点）
        let need_dir = if declining_run { -1 } else { 1 };
        // 末端段：last_z 之后的那一段（离开/末段）
        let (price, x, seg_idx) = if last_z.end_seg + 1 < n {
            let o = &segs[last_z.end_seg + 1];
            if o.dir == need_dir {
                // 末端段方向与趋势一致（下跌末段为向下段）→ 取其极点
                if declining_run {
                    (o.low, o.end_pole_x, o.idx)
                } else {
                    (o.high, o.end_pole_x, o.idx)
                }
            } else {
                // 末端段已反向（趋势已转折）→ 取最后中枢的极值作为末端点
                let m = &segs[last_z.end_seg];
                if declining_run {
                    (last_z.dd, m.end_pole_x, m.idx)
                } else {
                    (last_z.gg, m.end_pole_x, m.idx)
                }
            }
        } else {
            // 无末端段（数据止于最后中枢）→ 取最后中枢极值
            let m = &segs[last_z.end_seg];
            if declining_run {
                (last_z.dd, m.end_pole_x, m.idx)
            } else {
                (last_z.gg, m.end_pole_x, m.idx)
            }
        };
        let is_buy = declining_run; // 下跌趋势末端=买点；上涨趋势末端=卖点
        class1.push((
            BSP {
                cls: 1,
                is_buy,
                price,
                x,
                seg_idx,
                relate_seg_idx: None,
            },
            *run.last().unwrap(),
        ));
    }

    // —— 3) 二类 / 三类买卖点：均在一类之后的「离开段(p+1) + 返回段(p+2)」上判定 ——
    // 二类：返回段不破一类极值（回踩浅）；三类：返回段不回中枢带（[zg,zd]）。
    let mut class2: Vec<BSP> = Vec::new();
    let mut class3: Vec<BSP> = Vec::new();
    for (c1, zsi) in &class1 {
        let p = match pos_of.get(&c1.seg_idx) {
            Some(&p) => p,
            None => continue,
        };
        if p + 2 >= n {
            continue; // 需要 离开段(p+1) + 返回段(p+2)
        }
        let break_seg = &segs[p + 1];
        let retrace_seg = &segs[p + 2];
        if c1.is_buy {
            // 一类买点（向下末端）→ 离开=向上段、返回=向下段
            if break_seg.dir != 1 || retrace_seg.dir != -1 {
                continue;
            }
            let break_r = seg_range(break_seg);
            if break_r <= 0.0 {
                continue;
            }
            let rate = seg_range(retrace_seg) / break_r;
            // 二类买点：回踩低点不破一类低
            if retrace_seg.low >= c1.price - 1e-9 && rate <= cfg.max_bs2_rate {
                class2.push(BSP {
                    cls: 2,
                    is_buy: true,
                    price: retrace_seg.low,
                    x: retrace_seg.end_pole_x,
                    seg_idx: retrace_seg.idx,
                    relate_seg_idx: Some(c1.seg_idx),
                });
            }
            // 三类买点：离开段突破中枢上沿(zd)、返回段低点不回带（r.low >= zd）
            let z = &zs_list[*zsi];
            if break_seg.high > z.zd + 1e-9
                && retrace_seg.low >= z.zd - 1e-9
                && !(cfg.bsp3_peak && break_seg.high < z.gg - 1e-9)
            {
                class3.push(BSP {
                    cls: 3,
                    is_buy: true,
                    price: retrace_seg.low,
                    x: retrace_seg.end_pole_x,
                    seg_idx: retrace_seg.idx,
                    relate_seg_idx: Some(z.end_idx),
                });
            }
        } else {
            // 一类卖点（向上末端）→ 离开=向下段、返回=向上段
            if break_seg.dir != -1 || retrace_seg.dir != 1 {
                continue;
            }
            let break_r = seg_range(break_seg);
            if break_r <= 0.0 {
                continue;
            }
            let rate = seg_range(retrace_seg) / break_r;
            // 二类卖点：回踩高点不破一类高
            if retrace_seg.high <= c1.price + 1e-9 && rate <= cfg.max_bs2_rate {
                class2.push(BSP {
                    cls: 2,
                    is_buy: false,
                    price: retrace_seg.high,
                    x: retrace_seg.end_pole_x,
                    seg_idx: retrace_seg.idx,
                    relate_seg_idx: Some(c1.seg_idx),
                });
            }
            // 三类卖点：离开段跌破中枢下沿(zg)、返回段高点不回带（r.high <= zg）
            let z = &zs_list[*zsi];
            if break_seg.low < z.zg - 1e-9
                && retrace_seg.high <= z.zg + 1e-9
                && !(cfg.bsp3_peak && break_seg.low > z.dd + 1e-9)
            {
                class3.push(BSP {
                    cls: 3,
                    is_buy: false,
                    price: retrace_seg.high,
                    x: retrace_seg.end_pole_x,
                    seg_idx: retrace_seg.idx,
                    relate_seg_idx: Some(z.end_idx),
                });
            }
        }
    }

    let mut out = Vec::new();
    // class1 是 (BSP, usize) 元组，展平后接入
    for (b, _) in class1 {
        out.push(b);
    }
    out.extend(class2);
    out.extend(class3);
    out
}

/// 三类买卖点 → 镜像框（Flutter 主图点标记直接消费）
pub fn bsp_to_frames(list: &[BSP], level: i32) -> Vec<BSPFrame> {
    list
        .iter()
        .map(|b| BSPFrame {
            cls: b.cls,
            is_buy: b.is_buy,
            price: b.price,
            x: b.x,
            level,
            seg_idx: b.seg_idx,
            relate_seg_idx: b.relate_seg_idx,
        })
        .collect()
}

/// 由单层段序列 + 同层已算原生中枢直接产出该层三类买卖点框（只读冻结段，无未来函数）
pub fn level_bsp_frames(
    segs: &[LevelSegment],
    zs_list: &[ZS],
    level: i32,
    cfg: &BSPConfig,
) -> Vec<BSPFrame> {
    let bsps = find_bsp(segs, zs_list, level, cfg);
    bsp_to_frames(&bsps, level)
}

/// 每层段序列 → 该层三类买卖点框（全层同构，复用 find_zs + find_bsp）。
/// 注意：本函数会按传入 `zs_cfg` 重新计算中枢；`export()` 内部为复用同一份 zs_list 已直接调用
/// `level_bsp_frames`，此处提供独立便捷入口（如离线测试/批量回测）。
pub fn build_bsp_for_levels(
    levels: &[LevelBundleOut],
    zs_cfg: &ZSConfig,
    bsp_cfg: &BSPConfig,
) -> Vec<Vec<BSPFrame>> {
    levels
        .iter()
        .map(|lv| {
            let zs_list = crate::zs::find_zs(&lv.segments, lv.level, zs_cfg);
            level_bsp_frames(&lv.segments, &zs_list, lv.level, bsp_cfg)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pipeline::LevelBundleOut;
    use crate::zs::{find_zs, ZSConfig};

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

    /// 构造一个「下跌趋势」段序列：两个递降且互不重叠的中枢 + 末端向下段（一类买点）
    /// + 向上离开段 + 向下返回段（二类/三类共用）。中枢带刻意拉开，避免被 find_zs 吸收。
    /// 中枢1 区间≈[16,22]，中枢2 区间≈[6,9]（更低），末段低点到 1.0。
    fn declining_trend_segs() -> Vec<LevelSegment> {
        vec![
            // —— 中枢1：段 low 高=16，段 high 低=22 ——
            mk_seg(0, 1, 22.0, 14.0),
            mk_seg(1, 1, 24.0, 16.0),
            mk_seg(2, 1, 23.0, 15.0),
            // 离开段（向下，落在两中枢带之间的空档 [9,16]，不与任一重叠）
            mk_seg(3, -1, 14.0, 10.0),
            // —— 中枢2（更低）：段 low 高=6，段 high 低=9 ——
            mk_seg(4, 1, 9.0, 4.0),
            mk_seg(5, 1, 8.0, 5.0),
            mk_seg(6, 1, 7.0, 6.0),
            // 末端向下段（趋势末段，低点 1.0）→ 一类买点
            mk_seg(7, -1, 5.0, 1.0),
            // 向上离开段（完全在中枢2上沿 9 之上：low=10>9）
            mk_seg(8, 1, 15.0, 10.0),
            // 向下返回段（low=9.5，守住中枢2上沿 9 之上）→ 二类/三类买点
            mk_seg(9, -1, 13.0, 9.5),
        ]
    }

    #[test]
    fn find_bsp_class1_declining_trend() {
        let segs = declining_trend_segs();
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        assert_eq!(zs.len(), 2, "应检出 2 个递降中枢");
        let cfg = BSPConfig::default();
        let bsps = find_bsp(&segs, &zs, 1, &cfg);
        let c1: Vec<&BSP> = bsps.iter().filter(|b| b.cls == 1 && b.is_buy).collect();
        assert_eq!(c1.len(), 1, "下跌趋势应检出 1 个一类买点");
        assert!((c1[0].price - 1.0).abs() < 1e-9, "一类买点应在末端向下段低点 1.0");
        assert_eq!(c1[0].seg_idx, 7);
    }

    #[test]
    fn find_bsp_class2_no_break_low() {
        let segs = declining_trend_segs();
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        let cfg = BSPConfig::default();
        let bsps = find_bsp(&segs, &zs, 1, &cfg);
        let c2: Vec<&BSP> = bsps.iter().filter(|b| b.cls == 2 && b.is_buy).collect();
        assert_eq!(c2.len(), 1, "回踩不破一类低 → 1 个二类买点");
        // 二类买点在返回段(9)低点 9.5，且不破一类低 1.0
        assert!((c2[0].price - 9.5).abs() < 1e-9);
        assert!(c2[0].relate_seg_idx == Some(7), "二类应关联一类端点 seg 7");
    }

    #[test]
    fn find_bsp_class3_present_when_return_stays_above() {
        let segs = declining_trend_segs();
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        let cfg = BSPConfig::default();
        let bsps = find_bsp(&segs, &zs, 1, &cfg);
        let c3: Vec<&BSP> = bsps.iter().filter(|b| b.cls == 3 && b.is_buy).collect();
        // 离开段(8)向上突破中枢2上沿 zd=9，返回段(9)低点 9.5 守住上沿之上 → 三类买点
        assert_eq!(c3.len(), 1, "返回段守住上沿之上 → 三类买点");
        assert!((c3[0].price - 9.5).abs() < 1e-9);
    }

    #[test]
    fn find_bsp_no_class23_without_down_return() {
        // 下跌趋势 + 一类买点后，离开段向上但「下一段仍是向上」（无向下返回段）
        // → 二类/三类均不出现（二者都需要 离开段+向下返回段 的结构）
        let segs = vec![
            mk_seg(0, 1, 22.0, 14.0),
            mk_seg(1, 1, 24.0, 16.0),
            mk_seg(2, 1, 23.0, 15.0),
            mk_seg(3, -1, 14.0, 10.0),
            mk_seg(4, 1, 9.0, 4.0),
            mk_seg(5, 1, 8.0, 5.0),
            mk_seg(6, 1, 7.0, 6.0),
            mk_seg(7, -1, 5.0, 1.0), // 一类买点 low=1.0
            mk_seg(8, 1, 15.0, 10.0), // 向上离开段
            mk_seg(9, 1, 18.0, 11.0), // 仍向上（无向下返回）→ 二三类均无
        ];
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        let cfg = BSPConfig::default();
        let bsps = find_bsp(&segs, &zs, 1, &cfg);
        let c1: Vec<&BSP> = bsps.iter().filter(|b| b.cls == 1).collect();
        assert_eq!(c1.len(), 1, "仍应有 1 个一类买点");
        let c23: Vec<&BSP> = bsps.iter().filter(|b| b.cls == 2 || b.cls == 3).collect();
        assert_eq!(c23.len(), 0, "无向下返回段 → 二三类均不出现");
    }

    #[test]
    fn find_bsp_single_zs_no_class1() {
        // 仅 1 个中枢、无趋势 → 不出一类（min_zs_cnt 默认 2）
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 22.0, 12.0),
            mk_seg(2, 1, 21.0, 11.0),
            mk_seg(3, -1, 19.0, 9.0),
            mk_seg(4, 1, 25.0, 8.0),
            mk_seg(5, -1, 24.0, 7.0),
        ];
        let zs = find_zs(&segs, 1, &ZSConfig::default());
        assert_eq!(zs.len(), 1, "应只检出 1 个中枢");
        let cfg = BSPConfig::default();
        let bsps = find_bsp(&segs, &zs, 1, &cfg);
        assert!(
            bsps.iter().all(|b| b.cls != 1),
            "单中枢不构成趋势 → 无一类买卖点"
        );
    }

    #[test]
    fn find_bsp_empty_when_no_segs() {
        let cfg = BSPConfig::default();
        assert!(find_bsp(&[], &[], 1, &cfg).is_empty());
    }

    #[test]
    fn build_bsp_end_to_end_from_bundle() {
        // 离线接 run_pipeline：构造清晰交替涨跌腿的合成 K 线，验证 export 会挂 bsp_frames
        let bars = synthetic_zigzag_legs(16, 8, 2.0, 0.1);
        let opt = crate::pipeline::PipelineOptions::default();
        let res = crate::pipeline::run_pipeline(&bars, &opt);
        // 合成锯齿含多个中枢，至少有一层能检出买卖点（或至少不报错、字段存在）
        // 这里只断言结构存在：每个 level 的 bsp_frames 字段可访问
        for lv in &res.levels {
            let _ = &lv.bsp_frames; // 编译期字段存在即可
        }
        // 直接对 K0 段序列 + 其 ZS 跑一次，确认函数可产出（合成数据未必有完整趋势，允许为空）
        let zs = find_zs(&res.levels[0].segments, 1, &ZSConfig::default());
        let _bsps = find_bsp(&res.levels[0].segments, &zs, 1, &BSPConfig::default());
    }

    /// 确定性「幅度递增锯齿 + 转折点 gap」合成 K 线（与 zs.rs 测试同款）
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

    // 占位：避免未使用导入告警（LevelBundleOut 在更完整测试里会用到）
    #[allow(dead_code)]
    fn _uses(_: LevelBundleOut) {}

    /// 真实数据复现：加载 002003 2004/07/19~07/20 的 TICK-1MIN，跑全流水线，
    /// 逐层打印 ZS 带 / 连接段方向 / find_bsp 结果，用于排查「bsp_frames=0」问题。
    #[test]
    fn repro_002003_bsp_zero() {
        let root = crate::offline::default_data_root();
        if !root.is_dir() {
            eprintln!("[repro] 无 a_Data，跳过");
            return;
        }
        let bars = match crate::offline::load_klines(
            &root,
            "002003",
            "2004/07/19 10:47:00",
            "2004/07/20 13:09:00",
            crate::kline::KlinePeriod::M1,
        ) {
            Ok(b) => b,
            Err(e) => {
                eprintln!("[repro] 加载失败: {e}");
                return;
            }
        };
        eprintln!("[repro] 加载 K0 根数 = {}", bars.len());
        let opt = crate::pipeline::PipelineOptions::default();
        let res = crate::pipeline::run_pipeline(&bars, &opt);
        for lv in &res.levels {
            let segs = &lv.segments;
            let n = segs.len();
            let zs = crate::zs::find_zs(segs, lv.level, &crate::zs::ZSConfig::default());
            eprintln!(
                "\n=== K{}: segments={} zs={} ===",
                lv.level - 1,
                n,
                zs.len()
            );
            for (i, z) in zs.iter().enumerate() {
                let conn = if z.end_seg + 1 < n {
                    segs[z.end_seg + 1].dir
                } else {
                    0
                };
                eprintln!(
                    "  ZS#{} seg=[{},{}] dd={:.3} gg={:.3} zg={:.3} zd={:.3} one_bi={} conn_dir_after={}",
                    i, z.start_seg, z.end_seg, z.dd, z.gg, z.zg, z.zd, z.is_one_bi_zs, conn
                );
            }
            // 复现 run 分组逻辑，便于看是否达标
            let mut runs: Vec<Vec<usize>> = Vec::new();
            let mut cur: Vec<usize> = vec![0];
            for k in 1..zs.len() {
                let a = &zs[k - 1];
                let b = &zs[k];
                if a.is_one_bi_zs || b.is_one_bi_zs {
                    runs.push(std::mem::take(&mut cur));
                    cur = vec![k];
                    continue;
                }
                let conn_dir = if a.end_seg + 1 < n {
                    Some(segs[a.end_seg + 1].dir)
                } else {
                    None
                };
                let declining = b.dd < a.dd && conn_dir == Some(-1);
                let rising = b.gg > a.gg && conn_dir == Some(1);
                if declining || rising {
                    cur.push(k);
                } else {
                    runs.push(std::mem::take(&mut cur));
                    cur = vec![k];
                }
            }
            runs.push(cur);
            eprintln!("  runs (>=2 才出一类):");
            for r in &runs {
                eprintln!(
                    "    len={} idxs={:?}",
                    r.len(),
                    r.iter().map(|x| x + 1).collect::<Vec<_>>()
                );
            }
            let bsps = find_bsp(segs, &zs, lv.level, &BSPConfig::default());
            eprintln!(
                "  → find_bsp 结果: {} 个 (cls1={} cls2={} cls3={})",
                bsps.len(),
                bsps.iter().filter(|b| b.cls == 1).count(),
                bsps.iter().filter(|b| b.cls == 2).count(),
                bsps.iter().filter(|b| b.cls == 3).count(),
            );
            for b in &bsps {
                eprintln!(
                    "    cls={} {} price={:.3} x={} seg_idx={}",
                    b.cls,
                    if b.is_buy { "买" } else { "卖" },
                    b.price,
                    b.x,
                    b.seg_idx
                );
            }
        }
    }
}
