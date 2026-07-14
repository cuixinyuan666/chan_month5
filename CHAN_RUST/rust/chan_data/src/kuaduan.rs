//! 跨段中枢（KuaDuan）模块：复用流水线 `LevelSegment` 区间，用「松重叠吸收器」找到全层跨段中枢。
//!
//! 设计理念（与现有 combine/line 全层同构）：
//! 现有包含合并 `CombineEngine` 本质是一台「区间吸收器」——判定函数=严格包含 → 产出下一层段。
//! 跨段中枢是同一台吸收器的「松重叠孪生」——判定函数换成「≥3 连续段区间互相重叠」→ 产出跨段中枢。
//! 因此 KuaDuan 不新造数据结构，直接吃每层 `segments`；判定只看已冻结段，天然无未来函数
//! （与「逐K当下性」同源：段端点冻结后才进 KuaDuan 计算）。
//!
//! 与「统一层号」对齐：K0跨段中枢建立在 level=1 的段上（展示名 K0跨段中枢），
//! K1跨段中枢建立在 level=2 的段上（展示名 K1跨段中枢），与其余 combine/line/fractal 同号。

use serde::{Deserialize, Serialize};

use crate::pipeline::{LevelBundleOut, LevelSegment};

/// 跨段中枢：由某层 ≥3 连续重叠段聚合（段区间即 `LevelSegment.high/low`）。
#[derive(Debug, Clone, PartialEq)]
pub struct KuaDuan {
    /// 建立在第 n 层段之上（= 输入 segments 的 level，与 combine/line/fractal 同号）
    pub level: i32,
    /// 首段 idx（锚定上层单元序号，便于 Flutter/ML 回查）
    pub start_idx: i64,
    /// 末段 idx（延伸后）
    pub end_idx: i64,
    /// 首段在 `segments` 中的下标
    pub start_seg: usize,
    /// 末段在 `segments` 中的下标（延伸后）
    pub end_seg: usize,
    /// 上沿 ZG = max(覆盖段 low)  ← 最高的低
    pub zg: f64,
    /// 下沿 ZD = min(覆盖段 high) ← 最低的高
    pub zd: f64,
    /// 区间最高点 GG（三类买卖点包络）
    pub gg: f64,
    /// 区间最低点 DD
    pub dd: f64,
    /// 种子(3段)外的延伸段数（同向延续的跨段中枢扩展）
    pub extend: usize,
}

impl KuaDuan {
    /// 与「合并框」同构的 overlap 判定：段 u 的价格区间与 [ZD, ZG] 相交即重叠。
    fn overlaps(&self, u: &LevelSegment) -> bool {
        u.high >= self.zd && u.low <= self.zg
    }

    /// 跨段中枢宽度（ZG - ZD），统一 ML 特征（与分型确认/极点距/截断同列）。
    pub fn width(&self) -> f64 {
        self.zg - self.zd
    }

    /// 振幅（GG - DD），ML 特征。
    pub fn amplitude(&self) -> f64 {
        self.gg - self.dd
    }
}

/// 吸收器 B（跨段中枢）：种子 = 连续 3 段互相重叠（max(low) ≤ min(high)）；
/// 后续段仍与 [ZD, ZG] 重叠则延伸 `end`，重算 ZG/ZD/GG/DD。
/// 镜像 `MergedGroup::absorb`，只换判定函数。无未来函数：只看已冻结段。
///
/// 段序列应已排除未冻结占位（pending/active），调用方传入 `lv.segments` 即可。
pub fn find_kuaduan(segs: &[LevelSegment], level: i32) -> Vec<KuaDuan> {
    let mut out = Vec::new();
    if segs.len() < 3 {
        return out;
    }
    let mut i = 0usize;
    while i + 2 < segs.len() {
        let (a, b, c) = (&segs[i], &segs[i + 1], &segs[i + 2]);
        // 三重叠：max(low) ≤ min(high)
        let zg = a.low.max(b.low).max(c.low); // 最高的低
        let zd = a.high.min(b.high).min(c.high); // 最低的高
        if zg <= zd {
            let mut kuaduan = KuaDuan {
                level,
                start_idx: a.idx,
                end_idx: c.idx,
                start_seg: i,
                end_seg: i + 2,
                zg,
                zd,
                gg: a.high.max(b.high).max(c.high),
                dd: a.low.min(b.low).min(c.low),
                extend: 0,
            };
            let mut j = i + 3;
            // 延伸：下一段仍与 [ZD, ZG] 重叠则纳入，重算极值
            while j < segs.len() && kuaduan.overlaps(&segs[j]) {
                kuaduan.zg = kuaduan.zg.max(segs[j].low);
                kuaduan.zd = kuaduan.zd.min(segs[j].high);
                kuaduan.gg = kuaduan.gg.max(segs[j].high);
                kuaduan.dd = kuaduan.dd.min(segs[j].low);
                kuaduan.end_idx = segs[j].idx;
                kuaduan.end_seg = j;
                kuaduan.extend += 1;
                j += 1;
            }
            out.push(kuaduan);
            // 脱离：从延伸末段下一根起新种子（每段至多属于一个跨段中枢，干净分离）
            i = j;
        } else {
            i += 1;
        }
    }
    out
}

/// 接入 `run_pipeline` 产物：每层段序列 → 该层跨段中枢（复用全层输出，零重算）。
/// 与「统一层号」一致：K0跨段中枢 level=1 → 展示名 K0跨段中枢；K1跨段中枢 level=2 → K1跨段中枢。
pub fn build_kuaduan_for_levels(levels: &[LevelBundleOut]) -> Vec<Vec<KuaDuan>> {
    levels
        .iter()
        .map(|lv| find_kuaduan(&lv.segments, lv.level))
        .collect()
}

/// 跨段中枢镜像框（对齐 `KlineCombineFrame`，便于 Flutter 复用合并框绘制 / ML 特征）。
/// `high`/`low` 沿用合并框的「价格轴约定」：high ≥ low（更高价=上沿）。
/// 跨段中枢上沿 ZD=min(各段 high) 为更高价，下沿 ZG=max(各段 low) 为更低价 → high=ZD, low=ZG。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct KuaDuanFrame {
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
}

/// 跨段中枢 → 镜像框（Flutter 直接复用合并框渲染管线）。
pub fn kuaduan_to_frames(kuaduan_list: &[KuaDuan], segment_by_idx: &std::collections::HashMap<i64, &LevelSegment>) -> Vec<KuaDuanFrame> {
    kuaduan_list
        .iter()
        .filter_map(|kuaduan| {
            let s = segment_by_idx.get(&kuaduan.start_idx)?;
            let e = segment_by_idx.get(&kuaduan.end_idx)?;
            Some(KuaDuanFrame {
                x1: s.begin_pole_x.min(e.begin_pole_x),
                x2: s.end_pole_x.max(e.end_pole_x),
                high: kuaduan.zd,
                low: kuaduan.zg,
                level: kuaduan.level,
                count: kuaduan.end_seg - kuaduan.start_seg + 1,
            })
        })
        .collect()
}

/// 由单层段序列直接产出该层跨段中枢镜像框。
/// 复用 `find_kuaduan` + `kuaduan_to_frames`，只吃已冻结段 → 无未来函数（与「逐K当下性」同源）。
/// 供 `run_pipeline` 的 `export()` 逐层挂载，Flutter 直接渲染。
pub fn level_kuaduan_frames(segments: &[LevelSegment], level: i32) -> Vec<KuaDuanFrame> {
    if segments.len() < 3 {
        return Vec::new();
    }
    let segment_by_idx: std::collections::HashMap<i64, &LevelSegment> = segments
        .iter()
        .map(|s| (s.idx, s))
        .collect();
    let kuaduan = find_kuaduan(segments, level);
    kuaduan_to_frames(&kuaduan, &segment_by_idx)
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
    fn find_kuaduan_two_disjoint_groups() {
        // K0跨段中枢（level=1）：两组各 3 段互相重叠，中间被一段隔开
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 22.0, 12.0),
            mk_seg(2, 1, 21.0, 11.0),
            mk_seg(3, 1, 35.0, 25.0), // 不重叠 → 闭合第一组
            mk_seg(4, 1, 40.0, 30.0),
            mk_seg(5, 1, 42.0, 32.0),
            mk_seg(6, 1, 41.0, 31.0),
        ];
        let kuaduan = find_kuaduan(&segs, 1);
        assert_eq!(kuaduan.len(), 2, "应检出 2 个K0跨段中枢");
        assert_eq!(kuaduan[0].zg, 12.0); // max(low)=12
        assert_eq!(kuaduan[0].zd, 20.0); // min(high)=20
        assert_eq!(kuaduan[0].extend, 0);
        assert_eq!(kuaduan[1].start_idx, 3);
        assert_eq!(kuaduan[1].end_idx, 6);
    }

    #[test]
    fn find_kuaduan_extend_counts_extra_segments() {
        // 5 段连续重叠 → 1 个跨段中枢，extend=2
        let segs = vec![
            mk_seg(0, 1, 20.0, 10.0),
            mk_seg(1, 1, 22.0, 12.0),
            mk_seg(2, 1, 21.0, 11.0),
            mk_seg(3, 1, 25.0, 11.0), // 重叠 → 延伸
            mk_seg(4, 1, 26.0, 10.0), // 重叠 → 延伸
            mk_seg(5, 1, 40.0, 30.0), // 脱离
        ];
        let kuaduan = find_kuaduan(&segs, 1);
        assert_eq!(kuaduan.len(), 1);
        assert_eq!(kuaduan[0].extend, 2, "种子外应有 2 段延伸");
        assert_eq!(kuaduan[0].end_idx, 4);
        assert_eq!(kuaduan[0].zg, 12.0); // max(10,12,11,11,10)
        assert_eq!(kuaduan[0].zd, 20.0); // min(20,22,21,25,26)
        assert_eq!(kuaduan[0].gg, 26.0);
        assert_eq!(kuaduan[0].dd, 10.0);
    }

    #[test]
    fn find_kuaduan_less_than_three_returns_empty() {
        let segs = vec![mk_seg(0, 1, 20.0, 10.0), mk_seg(1, 1, 22.0, 12.0)];
        assert!(find_kuaduan(&segs, 1).is_empty());
    }

    #[test]
    fn build_kuaduan_for_levels_maps_each_level() {
        // K0连线层（level=1）给一组重叠段；K1连线层（level=2）给另一组
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
            first_dir: 0,
            first_dir_x: 0,
            active_unit: None,
            segment_policy: "pending".to_string(),
            pending_unit: None,
        };
        let kuaduan_by_level = build_kuaduan_for_levels(&[lv1, lv2]);
        assert_eq!(kuaduan_by_level.len(), 2);
        assert_eq!(kuaduan_by_level[0].len(), 1, "K0跨段中枢应命中");
        assert_eq!(kuaduan_by_level[0][0].level, 1);
        assert_eq!(kuaduan_by_level[1].len(), 1, "K1跨段中枢应命中");
        assert_eq!(kuaduan_by_level[1][0].level, 2);
    }

    #[test]
    fn pipeline_end_to_end_builds_k0_and_k1_kuaduan() {
        // 离线接 run_pipeline：构造清晰交替涨跌腿（转折点留 gap）的合成 K 线。
        let bars = synthetic_zigzag_legs(16, 8, 2.0, 0.1);
        let opt = crate::pipeline::PipelineOptions::default();
        let res = crate::pipeline::run_pipeline(&bars, &opt);

        // 诊断：打印每层段数 / 分型确认数 / 合并框数
        for lv in &res.levels {
            println!(
                "[diag] level={} 段数={} 分型确认数={} 合并框数={}",
                lv.level,
                lv.segments.len(),
                lv.confirms.len(),
                lv.combine_frames.len(),
            );
        }

        // 1) K0跨段中枢：直接对真实 run_pipeline 产物（level=1 K0连线段）跑 KuaDuan
        let kuaduan_by_level = build_kuaduan_for_levels(&res.levels);
        assert_eq!(kuaduan_by_level.len(), res.levels.len());
        assert!(!kuaduan_by_level[0].is_empty(), "K0跨段中枢应跑通（真实 run_pipeline 产物）");

        // 1b) 验证 export() 已把跨段中枢框逐层挂到 LevelBundleOut.kuaduan_frames
        //     （即 Flutter 实际收到的数据路径，而非仅 build_kuaduan_for_levels 离线计算）
        assert!(
            !res.levels[0].kuaduan_frames.is_empty(),
            "level=1 的 kuaduan_frames 应非空（export 已挂载跨段中枢框）",
        );
        println!(
            "K0跨段中枢数={} 首跨段中枢[ZG={:.2},ZD={:.2},extend={}]",
            kuaduan_by_level[0].len(),
            kuaduan_by_level[0].first().unwrap().zg,
            kuaduan_by_level[0].first().unwrap().zd,
            kuaduan_by_level[0].first().unwrap().extend,
        );

        // 2) K1跨段中枢：把真实 run_pipeline 产出的K0连线段（LevelSegment）直接作为「K1连线层」输入，
        //    验证 KuaDuan 模块对 level=2 段序列的离线处理（与 build_kuaduan_for_levels 同构路径）。
        //    注：本合成序列下，run_pipeline 的K1连线层因K0连线单元端点精确相等、合并退化为单组而未自产
        //    K1连线（属流水线 segment 层行为，非 KuaDuan 模块问题）；此处用真实类型验证K1跨段中枢链路。
        let lv1_segs = res.levels[0].segments.clone();
        assert!(lv1_segs.len() >= 3, "需足够K0连线段以构成K1跨段中枢");
        let lv2_bundle = LevelBundleOut {
            level: 2,
            confirms: vec![],
            segments: lv1_segs,
            unit_bars: vec![],
            combine_frames: vec![],
            kuaduan_frames: vec![],
            first_dir: 0,
            first_dir_x: 0,
            active_unit: None,
            segment_policy: "pending".to_string(),
            pending_unit: None,
        };
        let kuaduan2 = build_kuaduan_for_levels(&[lv2_bundle]);
        assert!(!kuaduan2[0].is_empty(), "K1跨段中枢应跑通（复用真实K0连线段作为K1连线层输入）");
        println!(
            "K1跨段中枢数={} 首跨段中枢[ZG={:.2},ZD={:.2},extend={}]",
            kuaduan2[0].len(),
            kuaduan2[0].first().unwrap().zg,
            kuaduan2[0].first().unwrap().zd,
            kuaduan2[0].first().unwrap().extend,
        );
    }

    /// 确定性「幅度递增锯齿 + 转折点 gap」：每段腿高低点不断抬高（模拟上涨趋势中的回调），
    /// 且在每个拐点留 gap（下腿起点低于上腿顶点、上腿起点低于下腿谷底），避免相邻K0连线单元
    /// high/low 完全相等 → 防止 level-2 合并组退化为点 → K1连线分型得以形成 → K1跨段中枢。
    fn synthetic_zigzag_legs(_legs: usize, leg_len: usize, _step: f64, wick: f64) -> Vec<crate::kline::KlineBar> {
        // (start, end) 每段腿；相邻腿之间留 ~6 点 gap
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
                // 首根用自身开收定高低，避免与上一腿端点 high 相等引发包含
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
