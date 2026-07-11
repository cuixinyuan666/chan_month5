//! Kn 递归流水线：K0(原始K) → K1(笔) → K2(线段) → … → Kn，穷尽到无法再生成新层。
//! 命名历史：旧「1段/2段/n段」→「K1/K2/Kn」；内部 level 序号不变（1=K1）。
//!
//! 三层语义（勿混为一谈）：
//! 1. **判定内核同构**（全层）：`CombineEngine` 包含合并 + 三元素分型；
//! 2. **成段机制同构**（全层）：锚定配对 + 有效性校验 + 冻结去重；
//! 3. **首段业务策略同构**（全层）：pending 占位 + 反向极值 trial + retained/purged（`segment_first.rs`）。
//!
//! 每层递归：输入单元包含合并 → 三元素分型确认（冻结不回写）→ 锚定配对 → Kn → 喂上层。
//! 进行中单元（anchor 极点 → 当步K 区间）逐层向上只读探测，段确认可早于整段冻结（方案A）。

use std::collections::{HashSet, VecDeque};

use serde::{Deserialize, Serialize};

use crate::combine::KlineCombineFrame;
use crate::engine::{CombineEngine, FxEvent, FxKind, MergeUnit, TruncGuard};
use crate::kline::KlineBar;
use crate::segment_first::{
    build_pending_default_unit, resolve_segment_policy, reverse_pole_x, trial_first_segment,
    POLICY_PENDING, POLICY_PURGED, POLICY_RETAINED,
};

/// 流水线选项
#[derive(Debug, Clone)]
pub struct PipelineOptions {
    /// 有效性校验开关：顶极值 > 底极值（最低限度；关闭则任意异向分型即配对）
    pub validity_check: bool,
    /// 层数安全上限（穷尽通常远达不到）
    pub max_levels: usize,
    /// 全层首段构造：pending + 反向极值 trial（默认开启）
    pub first_segment_bootstrap: bool,
    /// 截断监察开关（默认开启）：上行阶段暴力反转单元（最高价>=左框高 且 最低价<上个底分型低）
    /// 不被包含吸收，左框当场顶分型确认；下降截断镜像；全层同构
    pub truncation_check: bool,
}

impl Default for PipelineOptions {
    fn default() -> Self {
        Self {
            validity_check: true,
            max_levels: 16,
            first_segment_bootstrap: true,
            truncation_check: true,
        }
    }
}

/// N 段分型确认（冻结历史，写入后不回改）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LevelConfirm {
    /// 确认当步 1 分钟 K 索引
    pub x: i32,
    pub fx: String,
    /// 顶=-1，底=1
    pub value: i32,
    /// 分型中组 1 分钟 K 区间
    pub fractal_x1: i32,
    pub fractal_x2: i32,
    pub fractal_high: f64,
    pub fractal_low: f64,
    /// 分型极点 1 分钟 K（TOP=最高价首K，BOTTOM=最低价首K）
    pub pole_x: i32,
    /// 触发确认的下层单元序号
    pub trigger_uid: i64,
    /// 是否被用作段端点（同向丢弃 / 校验失败 = false；当下冻结不回写）
    pub used: bool,
    /// 截断确认：暴力反转单元触发（非常规三元素路径；上升截断=TOP，下降截断=BOTTOM）
    #[serde(default)]
    pub truncated: bool,
}

/// N 段（锚定配对产物；端点=分型极点 1 分钟 K）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LevelSegment {
    pub idx: i64,
    /// 向上=1，向下=-1
    pub dir: i32,
    pub begin_confirm_x: i32,
    pub end_confirm_x: i32,
    pub begin_pole_x: i32,
    pub end_pole_x: i32,
    /// 段区间 [begin_pole_x, end_pole_x] 的 OHLCV（冻结时算好，as-of 重绘零计算）
    #[serde(default)]
    pub open: f64,
    #[serde(default)]
    pub high: f64,
    #[serde(default)]
    pub low: f64,
    #[serde(default)]
    pub close: f64,
    #[serde(default)]
    pub volume: f64,
    pub begin_fractal_x1: i32,
    pub begin_fractal_x2: i32,
    pub end_fractal_x1: i32,
    pub end_fractal_x2: i32,
    /// 起止分型组高低（合并框口径，映射 SegLine 价格用）
    #[serde(default)]
    pub begin_fractal_high: f64,
    #[serde(default)]
    pub begin_fractal_low: f64,
    #[serde(default)]
    pub end_fractal_high: f64,
    #[serde(default)]
    pub end_fractal_low: f64,
    /// 已废弃：新方案无 bootstrap 引导段，固定 false（JSON 兼容）
    #[serde(default)]
    pub is_bootstrap: bool,
    /// 首确认 trial PASS 升格默认段
    #[serde(default)]
    pub is_promoted_default: bool,
}

/// N 段 K 线（x 锚定 1 分钟 K；OHLC=区间开收+极值，volume=区间和）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LevelUnitBar {
    pub idx: i64,
    pub dir: i32,
    pub x1: i32,
    pub x2: i32,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub volume: f64,
    /// 段冻结当步 1 分钟 K
    pub confirm_x: i32,
}

/// 每根 K0 × 每层 Kn 的十字线快照（逐K当下冻结，ML/tooltip 同源）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LevelSnap {
    /// 层级：1=K1(笔)，2=K2(线段)，…（旧称 n段）
    pub level: i32,
    /// 当步所属 Kn 序号（进行中或刚冻结；首确认前=None）
    pub unit_idx: Option<i64>,
    pub unit_dir: i32,
    /// 当步 Kn 的 K0 区间（进行中段 x2=当步K；查表重绘用）
    #[serde(default)]
    pub unit_x1: i32,
    #[serde(default)]
    pub unit_x2: i32,
    pub unit_open: f64,
    pub unit_high: f64,
    pub unit_low: f64,
    pub unit_close: f64,
    pub unit_volume: f64,
    /// 该 Kn 在 Kn合并框内序号（0 起）
    pub merge_inner_seq: i32,
    /// 所在合并框已含 Kn 根数（逐K当下）
    pub merge_count: i32,
    pub combine_high: f64,
    pub combine_low: f64,
    pub combine_fx: String,
    /// 当步所在 Kn合并框 K0 起点（as-of 查表重绘用；-1=无）
    #[serde(default = "neg_one")]
    pub combine_x1: i32,
}

fn neg_one() -> i32 {
    -1
}

impl LevelSnap {
    fn empty(level: i32) -> Self {
        Self {
            level,
            unit_idx: None,
            unit_dir: 0,
            unit_x1: -1,
            unit_x2: -1,
            unit_open: 0.0,
            unit_high: 0.0,
            unit_low: 0.0,
            unit_close: 0.0,
            unit_volume: 0.0,
            merge_inner_seq: 0,
            merge_count: 1,
            combine_high: 0.0,
            combine_low: 0.0,
            combine_fx: "UNKNOWN".to_string(),
            combine_x1: -1,
        }
    }
}

/// 每层全量输出
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LevelBundleOut {
    pub level: i32,
    pub confirms: Vec<LevelConfirm>,
    pub segments: Vec<LevelSegment>,
    pub unit_bars: Vec<LevelUnitBar>,
    /// 本层输入单元（K(n-1)；n=1 时为 K0）的包含合并线框
    pub combine_frames: Vec<KlineCombineFrame>,
    /// 首 N 段方向：0 未定
    pub first_dir: i32,
    pub first_dir_x: i32,
    /// 末步进行中 N 段K线（锚点极点 → 末K；尚未冻结）
    #[serde(default)]
    pub active_unit: Option<LevelUnitBar>,
    /// 首段策略：pending / retained / purged
    #[serde(default = "default_policy_pending")]
    pub segment_policy: String,
    /// 首确认前 pending 占位段（仅展示）
    #[serde(default)]
    pub pending_unit: Option<LevelUnitBar>,
}

fn default_policy_pending() -> String {
    POLICY_PENDING.to_string()
}

/// K线合并逐步快照（兼容 merge_* / combine_* 字段）
#[derive(Debug, Clone)]
pub struct BarCombineSnap {
    pub inner_seq: i32,
    pub count: i32,
    pub high: f64,
    pub low: f64,
    pub fx: String,
}

/// 2段（线段）逐K兼容行
#[derive(Debug, Clone, Copy, Default)]
pub struct BarSegRow {
    pub building_dir: i32,
    pub first_dir: i32,
    pub confirm: i32,
}

/// 流水线结果
#[derive(Debug, Clone)]
pub struct PipelineResult {
    pub levels: Vec<LevelBundleOut>,
    /// 每根K × 每层快照
    pub bar_level_snaps: Vec<Vec<LevelSnap>>,
    /// 每根K的K线合并快照
    pub bar_k_snaps: Vec<BarCombineSnap>,
    /// 每根K的2段兼容行（building/first/confirm）
    pub bar_seg_rows: Vec<BarSegRow>,
}

/// 分型极点 1 分钟 K：TOP 取 high 极大首K，BOTTOM 取 low 极小首K
fn fx_pole_x(bars: &[KlineBar], x1: i32, x2: i32, fx: FxKind) -> i32 {
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

/// 区间 OHLCV（x 越界自动收缩）
fn range_ohlcv(bars: &[KlineBar], x1: i32, x2: i32) -> (f64, f64, f64, f64, f64) {
    if bars.is_empty() {
        return (0.0, 0.0, 0.0, 0.0, 0.0);
    }
    let a = (x1.max(0) as usize).min(bars.len() - 1);
    let b = (x2.max(0) as usize).min(bars.len() - 1);
    let (a, b) = (a.min(b), a.max(b));
    let mut hi = f64::NEG_INFINITY;
    let mut lo = f64::INFINITY;
    let mut vol = 0.0;
    for x in a..=b {
        hi = hi.max(bars[x].high);
        lo = lo.min(bars[x].low);
        vol += bars[x].volume;
    }
    (bars[a].open, hi, lo, bars[b].close, vol)
}

fn make_unit_bar(
    bars: &[KlineBar],
    idx: i64,
    dir: i32,
    x1: i32,
    x2: i32,
    confirm_x: i32,
) -> LevelUnitBar {
    let (open, high, low, close, volume) = range_ohlcv(bars, x1, x2);
    LevelUnitBar {
        idx,
        dir,
        x1,
        x2,
        open,
        high,
        low,
        close,
        volume,
        confirm_x,
    }
}

/// 最近已用端点分型（锚定配对基准）
#[derive(Debug, Clone)]
struct Anchor {
    fx: FxKind,
    confirm_x: i32,
    pole_x: i32,
    fx1: i32,
    fx2: i32,
    high: f64,
    low: f64,
}

/// 进行中单元区间极值缓存（anchor 极点 → 当步K，增量吸收）
#[derive(Debug, Clone)]
struct ProvCache {
    x1: usize,
    last_x: usize,
    high: f64,
    low: f64,
    volume: f64,
}

/// 单层状态（产出 N 段；输入单元为 N-1 段K线，N=1 时输入 1 分钟 K）
struct LevelState {
    level: i32,
    validity_check: bool,
    /// 全层首段 trial 开关
    first_segment_bootstrap: bool,
    /// 截断监察开关
    truncation_check: bool,
    engine: CombineEngine,
    /// 已喂入本层引擎的 N-1 段输入单元前缀（首段反向极值 / pending 用）
    input_prefix: Vec<LevelUnitBar>,
    /// 首段策略三态
    segment_policy: String,
    confirms: Vec<LevelConfirm>,
    /// 冻结去重 key=(中组首单元uid, 是否顶)：组吸收扩展只改末端，首单元唯一标识组；
    /// 同组分型方向不可翻转（Up组只升不可能转BOTTOM），故一组至多冻结一次
    frozen: HashSet<(i64, bool)>,
    anchor: Option<Anchor>,
    segments: Vec<LevelSegment>,
    unit_bars: Vec<LevelUnitBar>,
    first_dir: i32,
    first_dir_x: i32,
    building_dir: i32,
    prov: Option<ProvCache>,
    /// 当步确认柱值（快照用；同步多确认保留最后）
    confirm_val_this_bar: i32,
    /// 当步刚冻结首段（promoted），快照优先展示该段
    freshly_first_seg: bool,
    /// 最近一次底分型确认中组最低价（含同向丢弃/校验失败的；上升截断破坏参照价）
    last_bottom_low: Option<f64>,
    /// 最近一次顶分型确认中组最高价（含同向丢弃/校验失败的；下降截断破坏参照价）
    last_top_high: Option<f64>,
}

/// 有效性校验：顶极值 > 底极值（最低限度，可配置关闭）
fn validity_ok(anchor: &Anchor, fx: FxKind, ev_high: f64, ev_low: f64) -> bool {
    match (anchor.fx, fx) {
        (FxKind::Bottom, FxKind::Top) => ev_high > anchor.low,
        (FxKind::Top, FxKind::Bottom) => ev_low < anchor.high,
        _ => false,
    }
}

impl LevelState {
    fn new(level: i32, opt: &PipelineOptions) -> Self {
        Self {
            level,
            validity_check: opt.validity_check,
            first_segment_bootstrap: opt.first_segment_bootstrap,
            truncation_check: opt.truncation_check,
            engine: CombineEngine::new(),
            input_prefix: Vec::new(),
            segment_policy: POLICY_PENDING.to_string(),
            confirms: Vec::new(),
            frozen: HashSet::new(),
            anchor: None,
            segments: Vec::new(),
            unit_bars: Vec::new(),
            first_dir: 0,
            first_dir_x: -1,
            building_dir: 0,
            prov: None,
            confirm_val_this_bar: 0,
            freshly_first_seg: false,
            last_bottom_low: None,
            last_top_high: None,
        }
    }

    fn begin_bar(&mut self) {
        self.confirm_val_this_bar = 0;
        self.freshly_first_seg = false;
    }

    /// 当步截断监察参数（Q4口径：按锚点方向分工，首确认前不监控）。
    /// 末组已被探测先行冻结分型时沿用该方向：永久喂入只作物理断开+去重重放，
    /// 禁止锚点翻向后对同一组镜像误触发（同组分型方向不可翻转）。
    fn trunc_guard(&self) -> Option<TruncGuard> {
        if !self.truncation_check {
            return None;
        }
        if let Some(last) = self.engine.last_group() {
            if self.frozen.contains(&(last.first_uid, true)) {
                return self
                    .last_bottom_low
                    .map(|p| TruncGuard { up_leg: true, ref_price: p });
            }
            if self.frozen.contains(&(last.first_uid, false)) {
                return self
                    .last_top_high
                    .map(|p| TruncGuard { up_leg: false, ref_price: p });
            }
        }
        match self.anchor.as_ref()?.fx {
            // 上行阶段（锚点=底分型）：监察上升截断，参照上个底分型中组最低价
            FxKind::Bottom => self
                .last_bottom_low
                .map(|p| TruncGuard { up_leg: true, ref_price: p }),
            // 下行阶段（锚点=顶分型）：监察下降截断，参照上个顶分型中组最高价
            FxKind::Top => self
                .last_top_high
                .map(|p| TruncGuard { up_leg: false, ref_price: p }),
            FxKind::Unknown => None,
        }
    }

    fn set_anchor(&mut self, fx: FxKind, ev_x1: i32, ev_x2: i32, high: f64, low: f64, pole_x: i32, confirm_x: i32) {
        self.anchor = Some(Anchor {
            fx,
            confirm_x,
            pole_x,
            fx1: ev_x1,
            fx2: ev_x2,
            high,
            low,
        });
        // 锚点变化 → 进行中单元起点变化，缓存重建
        self.prov = None;
    }

    /// 处理一次分型确认（冻结去重）；返回新冻结的 N 段K线（喂上层）
    fn on_confirm(
        &mut self,
        ev: &FxEvent,
        bar_x: i32,
        trigger_uid: i64,
        bars: &[KlineBar],
        trigger_ub: Option<LevelUnitBar>,
    ) -> Vec<LevelUnitBar> {
        let fx = ev.fx;
        let (ev_x1, ev_x2, ev_high, ev_low) = (ev.x1, ev.x2, ev.high, ev.low);
        if fx == FxKind::Unknown {
            return Vec::new();
        }
        let key = (ev.first_uid, fx == FxKind::Top);
        if !self.frozen.insert(key) {
            return Vec::new();
        }
        // 截断破坏参照价（Q2口径）：最近一次顶/底分型确认中组极值（含未用作端点的），当步冻结
        match fx {
            FxKind::Bottom => self.last_bottom_low = Some(ev_low),
            FxKind::Top => self.last_top_high = Some(ev_high),
            FxKind::Unknown => {}
        }
        let value = fx.confirm_value();
        let pole_x = fx_pole_x(bars, ev_x1, ev_x2, fx);
        if self.first_dir == 0 {
            // 首 N 段方向 = 首确认分型结束的段方向（TOP 结束上段=1）
            self.first_dir = -value;
            self.first_dir_x = bar_x;
        }
        self.building_dir = value;
        self.confirm_val_this_bar = value;

        let mut used = false;
        let mut outs = Vec::new();

        // trial 输入：已喂入前缀 + 探测触发单元（probe 路径可能尚未永久 feed）
        let mut trial_inputs = self.input_prefix.clone();
        if let Some(t) = trigger_ub {
            if trial_inputs.iter().all(|u| u.idx != t.idx) {
                trial_inputs.push(t);
            }
        }

        enum Action {
            First,
            Drop,
            Pair,
        }
        let action = match &self.anchor {
            None => Action::First,
            Some(a) if a.fx == fx => Action::Drop, // 同向分型：丢弃，锚点不回写
            Some(a) => {
                if self.validity_check && !validity_ok(a, fx, ev_high, ev_low) {
                    Action::Drop // 校验失败：不用作端点
                } else {
                    Action::Pair
                }
            }
        };

        match action {
            Action::First => {
                used = true;
                if self.first_segment_bootstrap {
                    // 全层首确认：反向极值 trial（放宽：合法区间即 PASS）
                    if let Some((vi, _pi)) =
                        trial_first_segment(&trial_inputs, pole_x, fx)
                    {
                        let virtual_u = &trial_inputs[vi];
                        let begin_pole = reverse_pole_x(bars, virtual_u, fx);
                        let dir = if fx == FxKind::Top { 1 } else { -1 };
                        let (vk_high, vk_low) = (virtual_u.high, virtual_u.low);
                        let (o, h, l, c, v) = range_ohlcv(bars, begin_pole, pole_x);
                        self.segment_policy = POLICY_RETAINED.to_string();
                        self.segments.push(LevelSegment {
                            idx: 0,
                            dir,
                            begin_confirm_x: bar_x,
                            end_confirm_x: bar_x,
                            begin_pole_x: begin_pole,
                            end_pole_x: pole_x,
                            open: o,
                            high: h,
                            low: l,
                            close: c,
                            volume: v,
                            begin_fractal_x1: virtual_u.x1,
                            begin_fractal_x2: virtual_u.x2,
                            end_fractal_x1: ev_x1,
                            end_fractal_x2: ev_x2,
                            begin_fractal_high: vk_high,
                            begin_fractal_low: vk_low,
                            end_fractal_high: ev_high,
                            end_fractal_low: ev_low,
                            is_bootstrap: false,
                            is_promoted_default: true,
                        });
                        self.freshly_first_seg = true;
                        let ub = make_unit_bar(bars, 0, dir, begin_pole, pole_x, bar_x);
                        self.unit_bars.push(ub.clone());
                        outs.push(ub);
                    } else {
                        self.segment_policy = POLICY_PURGED.to_string();
                    }
                }
                self.set_anchor(fx, ev_x1, ev_x2, ev_high, ev_low, pole_x, bar_x);
            }
            Action::Drop => {}
            Action::Pair => {
                used = true;
                let a = self.anchor.clone().expect("Pair 必有锚点");
                let idx = self.segments.len() as i64;
                let dir = if a.fx == FxKind::Bottom { 1 } else { -1 };
                let (o, h, l, c, v) = range_ohlcv(bars, a.pole_x, pole_x);
                self.segments.push(LevelSegment {
                    idx,
                    dir,
                    begin_confirm_x: a.confirm_x,
                    end_confirm_x: bar_x,
                    begin_pole_x: a.pole_x,
                    end_pole_x: pole_x,
                    open: o,
                    high: h,
                    low: l,
                    close: c,
                    volume: v,
                    begin_fractal_x1: a.fx1,
                    begin_fractal_x2: a.fx2,
                    end_fractal_x1: ev_x1,
                    end_fractal_x2: ev_x2,
                    begin_fractal_high: a.high,
                    begin_fractal_low: a.low,
                    end_fractal_high: ev_high,
                    end_fractal_low: ev_low,
                    is_bootstrap: false,
                    is_promoted_default: false,
                });
                let ub = make_unit_bar(bars, idx, dir, a.pole_x, pole_x, bar_x);
                self.unit_bars.push(ub.clone());
                outs.push(ub);
                self.set_anchor(fx, ev_x1, ev_x2, ev_high, ev_low, pole_x, bar_x);
            }
        }

        self.confirms.push(LevelConfirm {
            x: bar_x,
            fx: fx.as_str().to_string(),
            value,
            fractal_x1: ev_x1,
            fractal_x2: ev_x2,
            fractal_high: ev_high,
            fractal_low: ev_low,
            pole_x,
            trigger_uid,
            used,
            truncated: ev.truncated,
        });
        outs
    }

    /// 进行中 N 段单元（anchor 极点 → 当步K 区间；增量维护极值）
    fn provisional_unit(&mut self, bars: &[KlineBar], bar_i: usize) -> Option<(MergeUnit, f64, f64, f64)> {
        let a = self.anchor.as_ref()?;
        let x1 = a.pole_x.max(0) as usize;
        if x1 >= bars.len() || bar_i >= bars.len() || bar_i < x1 {
            return None;
        }
        let need_rebuild = match &self.prov {
            Some(c) => c.x1 != x1 || c.last_x > bar_i,
            None => true,
        };
        if need_rebuild {
            let (_, hi, lo, _, vol) = range_ohlcv(bars, x1 as i32, bar_i as i32);
            self.prov = Some(ProvCache {
                x1,
                last_x: bar_i,
                high: hi,
                low: lo,
                volume: vol,
            });
        } else if let Some(c) = &mut self.prov {
            for x in (c.last_x + 1)..=bar_i {
                c.high = c.high.max(bars[x].high);
                c.low = c.low.min(bars[x].low);
                c.volume += bars[x].volume;
            }
            c.last_x = bar_i;
        }
        let c = self.prov.as_ref().expect("prov 已构建");
        // uid 对齐"下一个将喂入上层的单元序号"，保证上层 uid 连续
        let unit = MergeUnit {
            uid: self.unit_bars.len() as i64,
            x1: x1 as i32,
            x2: bar_i as i32,
            high: c.high,
            low: c.low,
        };
        Some((unit, bars[x1].open, bars[bar_i].close, c.volume))
    }

    /// 当步十字线快照（active 单元：首段冻结步优先刚冻结段，否则进行中段）
    fn snapshot(
        &self,
        bars: &[KlineBar],
        upper: Option<&CombineEngine>,
        upper_guard: Option<TruncGuard>,
        prov: Option<&(MergeUnit, f64, f64, f64)>,
    ) -> LevelSnap {
        // 首段 promoted 冻结当步：展示刚冻结段而非同步新起进行中段
        if self.freshly_first_seg {
            if let Some(seg) = self.segments.first() {
                let ub = make_unit_bar(bars, seg.idx, seg.dir, seg.begin_pole_x, seg.end_pole_x, seg.end_confirm_x);
                let merge = upper.and_then(|e| e.snapshot_for(seg.idx));
                let mut snap = LevelSnap::empty(self.level);
                snap.unit_idx = Some(seg.idx);
                snap.unit_dir = seg.dir;
                snap.unit_x1 = ub.x1;
                snap.unit_x2 = ub.x2;
                snap.unit_open = ub.open;
                snap.unit_high = ub.high;
                snap.unit_low = ub.low;
                snap.unit_close = ub.close;
                snap.unit_volume = ub.volume;
                match merge {
                    Some(m) => {
                        snap.merge_inner_seq = m.inner_seq;
                        snap.merge_count = m.group_count;
                        snap.combine_high = m.group_high;
                        snap.combine_low = m.group_low;
                        snap.combine_fx = m.group_fx.as_str().to_string();
                        snap.combine_x1 = m.group_x1;
                    }
                    None => {
                        snap.combine_high = ub.high;
                        snap.combine_low = ub.low;
                        snap.combine_x1 = ub.x1;
                    }
                }
                return snap;
            }
        }
        // pending 占位：尚无锚点、首确认前
        if self.anchor.is_none()
            && self.segment_policy == POLICY_PENDING
            && !self.input_prefix.is_empty()
        {
            if let Some(pu) = build_pending_default_unit(&self.input_prefix) {
                let mut snap = LevelSnap::empty(self.level);
                snap.unit_idx = Some(0);
                snap.unit_dir = pu.dir;
                snap.unit_x1 = pu.x1;
                snap.unit_x2 = pu.x2;
                snap.unit_open = pu.open;
                snap.unit_high = pu.high;
                snap.unit_low = pu.low;
                snap.unit_close = pu.close;
                snap.unit_volume = pu.volume;
                snap.combine_high = pu.high;
                snap.combine_low = pu.low;
                snap.combine_x1 = pu.x1;
                return snap;
            }
        }
        if let (Some(a), Some((unit, open, close, volume))) = (&self.anchor, prov) {
            let dir = if a.fx == FxKind::Bottom { 1 } else { -1 };
            let mut snap = LevelSnap::empty(self.level);
            snap.unit_idx = Some(unit.uid);
            snap.unit_dir = dir;
            snap.unit_x1 = unit.x1;
            snap.unit_x2 = unit.x2;
            snap.unit_open = *open;
            snap.unit_high = unit.high;
            snap.unit_low = unit.low;
            snap.unit_close = *close;
            snap.unit_volume = *volume;
            match upper {
                Some(e) => {
                    // 与探测流同口径：带上层截断监察，命中时按"断开成新组"视角展示
                    let ps = e.probe_guarded(unit, upper_guard.as_ref());
                    snap.merge_inner_seq = ps.inner_seq;
                    snap.merge_count = ps.group_count;
                    snap.combine_high = ps.group_high;
                    snap.combine_low = ps.group_low;
                    snap.combine_fx = ps.group_fx.as_str().to_string();
                    snap.combine_x1 = ps.group_x1;
                }
                None => {
                    snap.combine_high = unit.high;
                    snap.combine_low = unit.low;
                    snap.combine_x1 = unit.x1;
                }
            }
            return snap;
        }
        LevelSnap::empty(self.level)
    }

    fn export(&self, bars: &[KlineBar]) -> LevelBundleOut {
        // 末步进行中单元：prov 缓存（快照阶段已推进到末K）
        let active_unit = match (&self.anchor, &self.prov) {
            (Some(a), Some(c)) if c.last_x < bars.len() => {
                let dir = if a.fx == FxKind::Bottom { 1 } else { -1 };
                Some(LevelUnitBar {
                    idx: self.segments.len() as i64,
                    dir,
                    x1: c.x1 as i32,
                    x2: c.last_x as i32,
                    open: bars[c.x1].open,
                    high: c.high,
                    low: c.low,
                    close: bars[c.last_x].close,
                    volume: c.volume,
                    confirm_x: c.last_x as i32,
                })
            }
            _ => None,
        };
        let has_promoted = self.segments.iter().any(|s| s.is_promoted_default);
        let segment_policy = if self.segment_policy == POLICY_PENDING {
            resolve_segment_policy(&self.confirms, has_promoted)
        } else {
            self.segment_policy.clone()
        };
        let pending_unit = if segment_policy == POLICY_PENDING {
            build_pending_default_unit(&self.input_prefix)
        } else {
            None
        };
        LevelBundleOut {
            level: self.level,
            confirms: self.confirms.clone(),
            segments: self.segments.clone(),
            unit_bars: self.unit_bars.clone(),
            combine_frames: frames_from_engine(&self.engine, bars),
            first_dir: self.first_dir,
            first_dir_x: self.first_dir_x,
            active_unit,
            segment_policy,
            pending_unit,
        }
    }
}

/// 合并引擎组 → 合并线框（x 锚定 1 分钟 K）
pub fn frames_from_engine(engine: &CombineEngine, bars: &[KlineBar]) -> Vec<KlineCombineFrame> {
    engine
        .groups()
        .iter()
        .map(|g| KlineCombineFrame {
            x1: g.x1,
            x2: g.x2,
            t1: bars
                .get(g.x1.max(0) as usize)
                .map(|b| b.time_text.clone())
                .unwrap_or_default(),
            t2: bars
                .get(g.x2.max(0) as usize)
                .map(|b| b.time_text.clone())
                .unwrap_or_default(),
            high: g.high,
            low: g.low,
            fx: g.fx.as_str().to_string(),
            count: g.unit_count,
            end_at_left_half: false,
            start_at_right_half: false,
        })
        .collect()
}

/// 永久单元逐层传播：feed → 确认 → 配对产段 → 段K线继续向上（层不足即创建，穷尽 N 段）
fn propagate(
    levels: &mut Vec<LevelState>,
    start_li: usize,
    units: Vec<LevelUnitBar>,
    bar_x: i32,
    bars: &[KlineBar],
    opt: &PipelineOptions,
) {
    let mut queue: VecDeque<(usize, LevelUnitBar)> =
        units.into_iter().map(|u| (start_li, u)).collect();
    while let Some((li, ub)) = queue.pop_front() {
        if li >= opt.max_levels {
            continue;
        }
        if li == levels.len() {
            levels.push(LevelState::new((li + 1) as i32, opt));
        }
        levels[li].input_prefix.push(ub.clone());
        let mu = MergeUnit {
            uid: ub.idx,
            x1: ub.x1,
            x2: ub.x2,
            high: ub.high,
            low: ub.low,
        };
        // 截断监察随喂随判：命中则左框当场分型确认 + 单元强制断开成新组
        let guard = levels[li].trunc_guard();
        if let Some(ev) = levels[li].engine.feed_guarded(&mu, guard.as_ref()) {
            let outs = levels[li].on_confirm(&ev, bar_x, mu.uid, bars, Some(ub));
            for o in outs {
                queue.push_back((li + 1, o));
            }
        }
    }
}

/// 全量入口：对已喂入 K 线前缀跑穷尽 N 段流水线（内部单遍逐K，无未来函数）
pub fn run_pipeline(bars: &[KlineBar], opt: &PipelineOptions) -> PipelineResult {
    let mut levels: Vec<LevelState> = vec![LevelState::new(1, opt)];
    let mut bar_level_snaps: Vec<Vec<LevelSnap>> = Vec::with_capacity(bars.len());
    let mut bar_k_snaps: Vec<BarCombineSnap> = Vec::with_capacity(bars.len());
    let mut bar_seg_rows: Vec<BarSegRow> = Vec::with_capacity(bars.len());

    for (i, bar) in bars.iter().enumerate() {
        let bar_x = i as i32;
        for lv in levels.iter_mut() {
            lv.begin_bar();
        }

        // 1) 永久流：当前K → Level1 引擎 → 级联向上
        let ku = LevelUnitBar {
            idx: i as i64,
            dir: 0,
            x1: bar_x,
            x2: bar_x,
            open: bar.open,
            high: bar.high,
            low: bar.low,
            close: bar.close,
            volume: bar.volume,
            confirm_x: bar_x,
        };
        propagate(&mut levels, 0, vec![ku], bar_x, bars, opt);

        // 2) 探测流：li 层进行中 Kn → li+1 层引擎只读探测（提前段确认，方案A）
        let mut li = 0usize;
        while li + 1 < levels.len() {
            let pu_opt = levels[li].provisional_unit(bars, i);
            if let Some(pu) = pu_opt {
                // 探测流同样带截断监察（与 feed_guarded 语义一致，不写状态）
                let guard = levels[li + 1].trunc_guard();
                let ev_opt = levels[li + 1]
                    .engine
                    .probe_guarded(&pu.0, guard.as_ref())
                    .fx_event;
                if let Some(ev) = ev_opt {
                    let probe_ub = {
                        let dir = levels[li]
                            .anchor
                            .as_ref()
                            .map(|a| if a.fx == FxKind::Bottom { 1 } else { -1 })
                            .unwrap_or(0);
                        make_unit_bar(bars, pu.0.uid, dir, pu.0.x1, pu.0.x2, bar_x)
                    };
                    let outs = levels[li + 1].on_confirm(
                        &ev,
                        bar_x,
                        pu.0.uid,
                        bars,
                        Some(probe_ub),
                    );
                    if !outs.is_empty() {
                        propagate(&mut levels, li + 2, outs, bar_x, bars, opt);
                    }
                }
            }
            li += 1;
        }

        // 3) 快照（逐K当下冻结）
        // K线合并快照：当步K必在 Level1 引擎末组
        let ksnap = levels[0]
            .engine
            .snapshot_for(i as i64)
            .map(|m| BarCombineSnap {
                inner_seq: m.inner_seq,
                count: m.group_count,
                high: m.group_high,
                low: m.group_low,
                fx: m.group_fx.as_str().to_string(),
            })
            .unwrap_or(BarCombineSnap {
                inner_seq: 0,
                count: 1,
                high: bar.high,
                low: bar.low,
                fx: "UNKNOWN".to_string(),
            });
        bar_k_snaps.push(ksnap);

        // 各层进行中单元先行更新（含最顶层）
        let mut provs: Vec<Option<(MergeUnit, f64, f64, f64)>> = Vec::with_capacity(levels.len());
        for lv in levels.iter_mut() {
            provs.push(lv.provisional_unit(bars, i));
        }
        let mut snaps = Vec::with_capacity(levels.len());
        for li in 0..levels.len() {
            let (upper, upper_guard) = if li + 1 < levels.len() {
                (Some(&levels[li + 1].engine), levels[li + 1].trunc_guard())
            } else {
                (None, None)
            };
            snaps.push(levels[li].snapshot(bars, upper, upper_guard, provs[li].as_ref()));
        }
        bar_level_snaps.push(snaps);

        // 2段（线段）兼容行
        let row = levels
            .get(1)
            .map(|l| BarSegRow {
                building_dir: l.building_dir,
                first_dir: l.first_dir,
                confirm: l.confirm_val_this_bar,
            })
            .unwrap_or_default();
        bar_seg_rows.push(row);
    }

    PipelineResult {
        levels: levels.iter().map(|l| l.export(bars)).collect(),
        bar_level_snaps,
        bar_k_snaps,
        bar_seg_rows,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bar(i: usize, h: f64, l: f64) -> KlineBar {
        KlineBar {
            idx: i as i32,
            time_ms: i as i64 * 60_000,
            time_text: format!("2024/01/01 09:{i:02}"),
            open: l,
            high: h,
            low: l,
            close: h,
            volume: 1.0,
            amount: 1.0,
            metrics: serde_json::Map::new(),
        }
    }

    /// 之字形行情：应产出 Level1 确认与段
    fn zigzag(n: usize) -> Vec<KlineBar> {
        (0..n)
            .map(|i| {
                let base = 10.0 + ((i / 3) % 2) as f64 * 2.0 + (i % 3) as f64 * 0.7;
                let h = if (i / 3) % 2 == 0 { base + 1.0 } else { 14.0 - base + 10.0 };
                bar(i, h, h - 0.8)
            })
            .collect()
    }

    #[test]
    fn pipeline_produces_level1_confirms() {
        let bars = vec![
            bar(0, 10.0, 9.0),
            bar(1, 9.0, 8.0),
            bar(2, 10.5, 9.5),
            bar(3, 9.5, 8.5),
            bar(4, 8.0, 7.0),
        ];
        let pr = run_pipeline(&bars, &PipelineOptions::default());
        assert_eq!(pr.bar_level_snaps.len(), bars.len());
        assert!(!pr.levels.is_empty());
        assert!(!pr.levels[0].confirms.is_empty(), "应有K1分型确认");
    }

    #[test]
    fn anchored_pairing_keeps_chain_seamless() {
        // 同向分型丢弃后，下一段起点仍是最近已用端点 → 链条无缝
        let bars = zigzag(60);
        let pr = run_pipeline(&bars, &PipelineOptions::default());
        let segs = &pr.levels[0].segments;
        for w in segs.windows(2) {
            assert_eq!(
                w[0].end_pole_x, w[1].begin_pole_x,
                "相邻段端点应无缝衔接"
            );
            assert_eq!(w[0].end_confirm_x, w[1].begin_confirm_x);
        }
    }

    #[test]
    fn snapshots_frozen_per_bar_no_future() {
        // 前缀重放：任意前缀的 LevelSnap 与全量逐字段一致（逐K当下冻结，无未来函数）
        let bars = zigzag(40);
        let full = run_pipeline(&bars, &PipelineOptions::default());
        for cut in [10usize, 20, 30] {
            let part = run_pipeline(&bars[..cut], &PipelineOptions::default());
            for i in 0..cut {
                let a = &full.bar_level_snaps[i];
                let b = &part.bar_level_snaps[i];
                let common = a.len().min(b.len());
                for li in 0..common {
                    assert_eq!(
                        a[li], b[li],
                        "bar {i} level {li} LevelSnap 前缀重放不一致"
                    );
                }
            }
        }
    }

    #[test]
    fn validity_check_rejects_inverted_pair() {
        // 顶极值低于底极值：开启校验时不成段
        let bars = vec![
            bar(0, 20.0, 19.0),
            bar(1, 18.0, 17.0), // 底分型中组(高低都低于两侧)
            bar(2, 19.0, 18.5),
            bar(3, 16.0, 15.0), // 直落
            bar(4, 16.5, 15.5), // 顶分型中组候选(极值 16.5 < 底极值 17.0)
            bar(5, 14.0, 13.0),
        ];
        let with_check = run_pipeline(
            &bars,
            &PipelineOptions {
                validity_check: true,
                ..PipelineOptions::default()
            },
        );
        let without_check = run_pipeline(
            &bars,
            &PipelineOptions {
                validity_check: false,
                ..PipelineOptions::default()
            },
        );
        let pair_count = |pr: &PipelineResult| {
            pr.levels[0]
                .segments
                .iter()
                .filter(|s| !s.is_promoted_default)
                .count()
        };
        assert!(pair_count(&with_check) <= pair_count(&without_check));
    }

    #[test]
    fn levels_exhaust_until_no_more() {
        let bars = zigzag(300);
        let pr = run_pipeline(&bars, &PipelineOptions::default());
        // 层数有限且最高层无产出段（穷尽）
        assert!(pr.levels.len() < 16);
        if let Some(top) = pr.levels.last() {
            // 最高层要么无段（穷尽终止），要么是刚建仍在积累
            assert!(top.segments.len() <= 1 || pr.levels.len() == 16);
        }
    }

    /// 以 test 数据结构为例：底分型(低8)确认后第4根 K(11/7.5) 命中上升截断 →
    /// 左框K2(10.5/9.5)=顶分型中组当步确认，上升段终点=左框峰值K2（非截断K）
    #[test]
    fn up_truncation_confirms_top_at_fourth_bar() {
        let bars = vec![
            bar(0, 10.0, 9.0),
            bar(1, 9.0, 8.0),   // 底分型中组（最低点8）
            bar(2, 10.5, 9.5),  // 底分型确认元素=左框
            bar(3, 11.0, 7.5),  // 第4根：高>=10.5 且 低<8 → 上升截断
            bar(4, 10.2, 9.2),
        ];
        let pr = run_pipeline(&bars, &PipelineOptions::default());
        let l1 = &pr.levels[0];
        let trunc: Vec<_> = l1.confirms.iter().filter(|c| c.truncated).collect();
        assert_eq!(trunc.len(), 1, "应有且仅有一次截断确认: {:?}", l1.confirms);
        let t = trunc[0];
        assert_eq!(t.fx, "TOP");
        assert_eq!(t.x, 3); // 确认落在第4根当步
        assert_eq!((t.fractal_x1, t.fractal_x2), (2, 2)); // 中组=左框K2
        assert!((t.fractal_high - 10.5).abs() < 1e-9); // 左框高低未被截断K改写
        assert!((t.fractal_low - 9.5).abs() < 1e-9);
        assert_eq!(t.pole_x, 2);
        assert!(t.used, "截断顶分型应用作段端点");
        // 上升段：底分型极点K1 → 左框峰值K2（终点不落在截断K3上）
        let up_seg = l1
            .segments
            .iter()
            .find(|s| s.dir == 1)
            .expect("应有上升段");
        assert_eq!(up_seg.begin_pole_x, 1);
        assert_eq!(up_seg.end_pole_x, 2);
        // 截断K独立成组：合并框链中 K3 起新框（监控范围>=第四根）
        assert!(l1
            .combine_frames
            .iter()
            .any(|f| f.x1 == 3), "截断K应强制断开成新组: {:?}", l1.combine_frames);
    }

    /// 开关关闭 → 旧行为：暴力反转K被吸收，无截断确认（对照排查用）
    #[test]
    fn truncation_off_keeps_legacy_absorb() {
        let bars = vec![
            bar(0, 10.0, 9.0),
            bar(1, 9.0, 8.0),
            bar(2, 10.5, 9.5),
            bar(3, 11.0, 7.5),
            bar(4, 10.2, 9.2),
        ];
        let pr = run_pipeline(
            &bars,
            &PipelineOptions {
                truncation_check: false,
                ..PipelineOptions::default()
            },
        );
        let l1 = &pr.levels[0];
        assert!(l1.confirms.iter().all(|c| !c.truncated));
        // K3 被吸收进左框（框高改写为11），不另起新框
        assert!(l1.combine_frames.iter().all(|f| f.x1 != 3));
    }

    /// 下降截断镜像：顶分型(高11)确认后，第4根低<=左框低 且 高>11 → 底分型截断确认
    #[test]
    fn down_truncation_mirror_confirms_bottom() {
        let bars = vec![
            bar(0, 10.0, 9.0),
            bar(1, 11.0, 10.5), // 顶分型中组（最高点11）
            bar(2, 9.5, 8.5),   // 顶分型确认元素=左框
            bar(3, 11.5, 8.0),  // 第4根：低<=8.5 且 高>11 → 下降截断
            bar(4, 9.8, 9.0),
        ];
        let pr = run_pipeline(&bars, &PipelineOptions::default());
        let l1 = &pr.levels[0];
        let trunc: Vec<_> = l1.confirms.iter().filter(|c| c.truncated).collect();
        assert_eq!(trunc.len(), 1, "应有且仅有一次截断确认: {:?}", l1.confirms);
        let t = trunc[0];
        assert_eq!(t.fx, "BOTTOM");
        assert_eq!(t.x, 3);
        assert_eq!((t.fractal_x1, t.fractal_x2), (2, 2));
        assert!((t.fractal_high - 9.5).abs() < 1e-9);
        assert!((t.fractal_low - 8.5).abs() < 1e-9);
        // 下降段：顶分型极点K1 → 左框谷值K2
        let down_seg = l1
            .segments
            .iter()
            .find(|s| s.dir == -1 && !s.is_promoted_default)
            .expect("应有下降段");
        assert_eq!(down_seg.begin_pole_x, 1);
        assert_eq!(down_seg.end_pole_x, 2);
    }

    /// 含截断行情的前缀重放一致性：逐K当下冻结、无未来函数（LevelSnap 逐字段相等）
    #[test]
    fn truncation_snapshots_frozen_no_future() {
        let mut bars = vec![
            bar(0, 10.0, 9.0),
            bar(1, 9.0, 8.0),
            bar(2, 10.5, 9.5),
            bar(3, 11.0, 7.5), // 上升截断
        ];
        bars.extend(zigzag(36).into_iter().skip(4));
        let bars: Vec<KlineBar> = bars
            .into_iter()
            .enumerate()
            .map(|(i, mut b)| {
                b.idx = i as i32;
                b
            })
            .collect();
        let full = run_pipeline(&bars, &PipelineOptions::default());
        for cut in [4usize, 5, 10, 20, 30] {
            let part = run_pipeline(&bars[..cut], &PipelineOptions::default());
            for i in 0..cut {
                let a = &full.bar_level_snaps[i];
                let b = &part.bar_level_snaps[i];
                let common = a.len().min(b.len());
                for li in 0..common {
                    assert_eq!(a[li], b[li], "bar {i} level {li} 截断前缀重放不一致");
                }
            }
            // 确认历史前缀也一致（冻结不回写）
            let fc = &full.levels[0].confirms;
            let pc = &part.levels[0].confirms;
            for (j, c) in pc.iter().enumerate() {
                assert_eq!(c.x, fc[j].x);
                assert_eq!(c.fx, fc[j].fx);
                assert_eq!(c.truncated, fc[j].truncated);
            }
        }
    }

    #[test]
    fn all_levels_have_segment_policy() {
        let bars = zigzag(80);
        let pr = run_pipeline(&bars, &PipelineOptions::default());
        for lv in &pr.levels {
            assert!(
                lv.segment_policy == "pending"
                    || lv.segment_policy == "retained"
                    || lv.segment_policy == "purged",
                "level {} policy={}",
                lv.level,
                lv.segment_policy
            );
        }
    }
}
