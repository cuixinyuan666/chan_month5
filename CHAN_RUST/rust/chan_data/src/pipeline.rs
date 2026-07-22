//! Kn 递归流水线：K0(原始K) → K1(K0连线) → K2(K1连线) → … → Kn，穷尽到无法再生成新层。
//! 命名历史：旧「1段/2段/n段」→「K1/K2/Kn」；内部 level 序号不变（1=K1）。
//!
//! 三层语义（勿混为一谈）：
//! 1. **判定内核同构**（全层）：`CombineEngine` 包含合并 + 三元素分型（首两单元不做包含，见种子框例外）；
//! 2. **成段机制同构**（全层）：锚定配对 + 有效性校验 + 冻结去重；
//! 3. **首段业务策略同构**（全层）：种子合并框（group0）+ UNKNOWN 开口虚线（D2·S-b）+ A→B 首段 + B→C 第二段（虚实见 `first_fx_state`）。
//!
//! 每层递归：输入单元包含合并 → 三元素分型确认（冻结不回写）→ 锚定配对 → Kn → 喂上层。
//! 全层同构约束：**必须等 K(n-1) 单元永久冻结后才能参与 Kn**（禁止行进中下层提前确认上层）。
//! 进行中单元仍可只读探测上层合并态，但仅用于十字线/展示快照，不触发 `on_confirm`。

use std::collections::{HashSet, VecDeque};

use serde::{Deserialize, Serialize};

use crate::combine::KlineCombineFrame;
use crate::engine::{
    seed_leave_dir, CombineEngine, FxEvent, FxKind, MergeUnit, TruncGuard,
};
use crate::kuaduan::KuaDuanV1Frame;
use crate::kline::KlineBar;
use crate::bsp::{BSPConfig, BSPFrame};
use crate::zs::{ZSConfig, ZSFrame};


/// 流水线选项
#[derive(Debug, Clone)]
pub struct PipelineOptions {
    /// 有效性校验开关：顶极值 > 底极值（最低限度；关闭则任意异向分型即配对）
    pub validity_check: bool,
    /// 层数安全上限（穷尽通常远达不到）
    pub max_levels: usize,
    /// 截断监察开关（默认开启）：上行阶段暴力反转单元（最高价>=左框高 且 最低价<上个底分型低）
    /// 不被包含吸收，左框当场顶分型确认；下降截断镜像；全层同构
    pub truncation_check: bool,
    /// 原生缠论中枢（ZS）配置：控制是否合并、合并模式、单段中枢、成中枢算法
    pub zs_config: ZSConfig,
    /// 三类买卖点（BSP）配置：趋势最少中枢数、二类回踩幅度、三类是否依附一类等
    pub bsp_config: BSPConfig,
}

impl Default for PipelineOptions {
    fn default() -> Self {
        Self {
            validity_check: true,
            max_levels: 16,
            truncation_check: true,
            zs_config: ZSConfig::default(),
            bsp_config: BSPConfig::default(),
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
    /// 起止分型组高低（合并框口径，映射 K1Line 价格用）
    #[serde(default)]
    pub begin_fractal_high: f64,
    #[serde(default)]
    pub begin_fractal_low: f64,
    #[serde(default)]
    pub end_fractal_high: f64,
    #[serde(default)]
    pub end_fractal_low: f64,
    /// 已废弃：无 bootstrap 引导段，固定 false（JSON 兼容）
    #[serde(default)]
    pub is_bootstrap: bool,
    /// 已废弃：首段改为种子框 A→B，固定 false（JSON 兼容）
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
    /// 层级：1=K1(K0连线)，2=K2(K1连线)，…（旧称 n段）
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
    /// 当步所在 Kn 合并框序号（0 起；-1=未成框）
    pub merge_box_seq: i32,
    // ---- 种子框（首 Kn 合并框）快照：逐K当下冻结，供 Flutter 渲染与 ML/tooltip 同源 ----
    /// 种子框是否确定态（首个真实分型确认后冻结）
    pub seed_confirmed: bool,
    /// 种子框序号（=0；-1=无种子框）
    pub seed_box_seq: i32,
    /// 种子框区间 [x1,x2]
    pub seed_box_x1: i32,
    pub seed_box_x2: i32,
    /// 种子框极值（high/low）
    pub seed_box_high: f64,
    pub seed_box_low: f64,
    /// 种子框分型方向（首个真实分型反向推断；UNKNOWN=未定）
    pub seed_fx: String,
    /// 画线端点：A=种子极值, B=首个分型, C=次分型；-1=未就绪
    pub draw_a_x: i32,
    pub draw_b_x: i32,
    pub draw_c_x: i32,
    /// 首个 Kn 分型状态：JUDGE=判断(线虚) / CONFIRM=确认(A→B实,B→C虚) / UNKNOWN=未就绪
    pub first_fx_state: String,
    /// 离开种子方向（全层同构）：0=不画开口虚线；
    /// +1/-1=首分型前末组 hn,ln 相对种子 sit1/sit2；含/重叠为 0
    #[serde(default)]
    pub seed_leave_dir: i32,
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
            merge_box_seq: -1,
            seed_confirmed: false,
            seed_box_seq: -1,
            seed_box_x1: -1,
            seed_box_x2: -1,
            seed_box_high: f64::NAN,
            seed_box_low: f64::NAN,
            seed_fx: "UNKNOWN".to_string(),
            draw_a_x: -1,
            draw_b_x: -1,
            draw_c_x: -1,
            first_fx_state: "UNKNOWN".to_string(),
            seed_leave_dir: 0,
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
    /// 本层跨段中枢镜像框（K0跨段中枢 level=1 / K1跨段中枢 level=2 …；由 `kuaduan` 模块松重叠吸收器产出）
    #[serde(default)]
    pub kuaduan_frames: Vec<KuaDuanV1Frame>,
    /// 本层原生缠论中枢镜像框（全层同构，建立在 `LevelSegment` 上；由 `zs` 模块产出）
    #[serde(default)]
    pub zs_frames: Vec<ZSFrame>,
    /// 本层三类买卖点镜像框（全层同构，建立在 `LevelSegment`+`ZS` 上；由 `bsp` 模块产出）
    #[serde(default)]
    pub bsp_frames: Vec<BSPFrame>,
    /// 首 N 段方向：0 未定
    pub first_dir: i32,
    pub first_dir_x: i32,
    /// 末步进行中 N 段K线（锚点极点 → 末K；尚未冻结）
    #[serde(default)]
    pub active_unit: Option<LevelUnitBar>,
    /// 首段策略：seed=种子框未确认 / retained=已有锚点成段（JSON 兼容，不再有 trial 三态）
    #[serde(default = "default_policy_seed")]
    pub segment_policy: String,
    /// 已废弃：种子框由 snapshot.seed_box 展示，恒为 None（JSON 兼容）
    #[serde(default)]
    pub pending_unit: Option<LevelUnitBar>,
}

/// 兼容默认：种子框未确认
fn default_policy_seed() -> String {
    "seed".to_string()
}

/// K线合并逐步快照（兼容 merge_* / combine_* 字段）
#[derive(Debug, Clone)]
pub struct BarCombineSnap {
    pub inner_seq: i32,
    pub count: i32,
    pub high: f64,
    pub low: f64,
    pub fx: String,
    /// 当步所在 K0 合并框序号（0 起；-1=未成框）
    pub group_seq: i32,
}

/// K1连线逐K兼容行
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

/// 区间高低收量（调试/兼容；Kn 单元请用 kn_unit_ohlcv）
#[allow(dead_code)]
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

/// Kn 段开盘价（全层同构）：上升取起点底分型最低价，下降取起点顶分型最高价
/// （与连线 begin_price 同口径；禁止用极点 K 的 open/low 冒充）
fn kn_segment_open(dir: i32, begin_fx_high: f64, begin_fx_low: f64) -> f64 {
    if dir > 0 {
        begin_fx_low
    } else {
        begin_fx_high
    }
}

/// 段身 H/L/C/V：从起点极点**下一根**到终点（不含极点 K，避免顶分型那根的低价污染下降段等）
fn range_body_hlcv(bars: &[KlineBar], begin_pole: i32, end_x: i32) -> (f64, f64, f64, f64) {
    if bars.is_empty() {
        return (f64::NEG_INFINITY, f64::INFINITY, 0.0, 0.0);
    }
    let start = (begin_pole.max(0) as usize).saturating_add(1);
    let end = (end_x.max(0) as usize).min(bars.len() - 1);
    if start > end || start >= bars.len() {
        return (f64::NEG_INFINITY, f64::INFINITY, 0.0, 0.0);
    }
    let mut hi = f64::NEG_INFINITY;
    let mut lo = f64::INFINITY;
    let mut vol = 0.0;
    for x in start..=end {
        hi = hi.max(bars[x].high);
        lo = lo.min(bars[x].low);
        vol += bars[x].volume;
    }
    (hi, lo, bars[end].close, vol)
}

/// Kn 单元 OHLCV（全层同构）：开盘=起点分型极值；高低收只取极点后段身，再与开盘合成合法蜡烛
fn kn_unit_ohlcv(
    bars: &[KlineBar],
    dir: i32,
    begin_pole: i32,
    end_x: i32,
    begin_fx_high: f64,
    begin_fx_low: f64,
) -> (f64, f64, f64, f64, f64) {
    let open = kn_segment_open(dir, begin_fx_high, begin_fx_low);
    let begin_i = (begin_pole.max(0) as usize).min(bars.len().saturating_sub(1));
    let (bh, bl, body_close, body_vol) = range_body_hlcv(bars, begin_pole, end_x);
    let begin_vol = bars.get(begin_i).map(|b| b.volume).unwrap_or(0.0);
    if !bh.is_finite() {
        // 尚无段身（仍停在极点当根）：OHLC 退化为开盘价
        return (open, open, open, open, begin_vol);
    }
    (
        open,
        bh.max(open),
        bl.min(open),
        body_close,
        begin_vol + body_vol,
    )
}

fn make_unit_bar(
    bars: &[KlineBar],
    idx: i64,
    dir: i32,
    x1: i32,
    x2: i32,
    confirm_x: i32,
    begin_fx_high: f64,
    begin_fx_low: f64,
) -> LevelUnitBar {
    let (open, high, low, close, volume) =
        kn_unit_ohlcv(bars, dir, x1, x2, begin_fx_high, begin_fx_low);
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
    /// 截断监察开关
    truncation_check: bool,
    engine: CombineEngine,
    /// 种子框首段状态：0=未, 1=A→B已发射, 2=B→C已发射
    seed_phase: u8,
    /// 种子框方向（首个真实分型反向推断）
    seed_fx: FxKind,
    /// 画线端点 A/B/C 的 1 分钟 K 索引（-1=未就绪）
    seed_a_x: i32,
    seed_b_x: i32,
    seed_c_x: i32,
    seed_confirmed: bool,
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
    /// 当步刚冻结种子框首段 A→B，快照优先展示该段
    freshly_first_seg: bool,
    /// 最近一次底分型确认中组最低价（含同向丢弃/校验失败的；上升截断破坏参照价）
    last_bottom_low: Option<f64>,
    /// 最近一次顶分型确认中组最高价（含同向丢弃/校验失败的；下降截断破坏参照价）
    last_top_high: Option<f64>,
    /// 原生缠论中枢（ZS）配置（从 opt 拷贝，只读冻结段计算，不改动其它元素逻辑）
    zs_config: ZSConfig,
    /// 三类买卖点（BSP）配置（从 opt 拷贝，只读冻结段计算，不改动其它元素逻辑）
    bsp_config: BSPConfig,
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
            truncation_check: opt.truncation_check,
            zs_config: opt.zs_config,
            bsp_config: opt.bsp_config,
            engine: CombineEngine::new(),
            seed_phase: 0,
            seed_fx: FxKind::Unknown,
            seed_a_x: -1,
            seed_b_x: -1,
            seed_c_x: -1,
            seed_confirmed: false,
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
        _trigger_ub: Option<LevelUnitBar>,

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
                // 种子框首段 A→B：A=首合并组(种子框)极值首K，B=首个真实分型极点
                // 口径 A：种子方向=首分型反向；group0 永不吸收第二根
                let g0 = &self.engine.groups()[0];
                let seed_fx = if fx == FxKind::Top {
                    FxKind::Bottom
                } else {
                    FxKind::Top
                };
                let begin_pole = fx_pole_x(bars, g0.x1, g0.x2, seed_fx);
                let dir = if fx == FxKind::Top { 1 } else { -1 };
                let (o, h, l, c, v) =
                    kn_unit_ohlcv(bars, dir, begin_pole, pole_x, g0.high, g0.low);
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
                    begin_fractal_x1: g0.x1,
                    begin_fractal_x2: g0.x2,
                    end_fractal_x1: ev_x1,
                    end_fractal_x2: ev_x2,
                    begin_fractal_high: g0.high,
                    begin_fractal_low: g0.low,
                    end_fractal_high: ev_high,
                    end_fractal_low: ev_low,
                    is_bootstrap: false,
                    is_promoted_default: false,
                });
                self.seed_phase = 1;
                self.seed_fx = seed_fx;
                self.seed_a_x = begin_pole;
                self.seed_b_x = pole_x;
                self.seed_confirmed = true;
                self.freshly_first_seg = true;
                let ub = make_unit_bar(bars, 0, dir, begin_pole, pole_x, bar_x, g0.high, g0.low);
                self.unit_bars.push(ub.clone());
                outs.push(ub);
                self.set_anchor(fx, ev_x1, ev_x2, ev_high, ev_low, pole_x, bar_x);
            }
            Action::Drop => {}
            Action::Pair => {
                used = true;
                let a = self.anchor.clone().expect("Pair 必有锚点");
                let idx = self.segments.len() as i64;
                let dir = if a.fx == FxKind::Bottom { 1 } else { -1 };
                // 开盘=锚点分型极值；高低收取极点后段身
                let (o, h, l, c, v) =
                    kn_unit_ohlcv(bars, dir, a.pole_x, pole_x, a.high, a.low);
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
                let ub = make_unit_bar(bars, idx, dir, a.pole_x, pole_x, bar_x, a.high, a.low);
                self.unit_bars.push(ub.clone());
                outs.push(ub);
                // 种子框次分型：首个配对即 B→C 的 C 点
                if self.seed_phase == 1 {
                    self.seed_c_x = pole_x;
                    self.seed_phase = 2;
                }
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

    /// 进行中 N 段单元（anchor 极点 → 当步K；段身极值不含起点极点 K）
    fn provisional_unit(&mut self, bars: &[KlineBar], bar_i: usize) -> Option<(MergeUnit, f64, f64, f64)> {
        let (pole_x, fx, fx_high, fx_low) = {
            let a = self.anchor.as_ref()?;
            (a.pole_x, a.fx, a.high, a.low)
        };
        let x1 = pole_x.max(0) as usize;
        if x1 >= bars.len() || bar_i >= bars.len() || bar_i < x1 {
            return None;
        }
        let dir = if fx == FxKind::Bottom { 1 } else { -1 };
        let open = kn_segment_open(dir, fx_high, fx_low);
        let need_rebuild = match &self.prov {
            Some(c) => c.x1 != x1 || c.last_x > bar_i,
            None => true,
        };
        if need_rebuild {
            // 段身从极点下一根起算；尚无段身时高低退化为开盘价
            let (bh, bl, _, body_vol) = range_body_hlcv(bars, x1 as i32, bar_i as i32);
            let begin_vol = bars[x1].volume;
            let (high, low, vol) = if bh.is_finite() {
                (bh.max(open), bl.min(open), begin_vol + body_vol)
            } else {
                (open, open, begin_vol)
            };
            self.prov = Some(ProvCache {
                x1,
                last_x: bar_i,
                high,
                low,
                volume: vol,
            });
        } else if let Some(c) = &mut self.prov {
            for x in (c.last_x + 1)..=bar_i {
                c.high = c.high.max(bars[x].high).max(open);
                c.low = c.low.min(bars[x].low).min(open);
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
        Some((unit, open, bars[bar_i].close, c.volume))
    }

    /// 当步十字线快照（active 单元：首段冻结步优先刚冻结段，否则进行中段）
    /// `pending_input`：下层尚未永久喂入的进行中单元（只读探测 JUDGE / 动态种子框；不触发 on_confirm）
    fn snapshot(
        &self,
        bars: &[KlineBar],
        upper: Option<&CombineEngine>,
        prov: Option<&(MergeUnit, f64, f64, f64)>,
        pending_input: Option<&MergeUnit>,
    ) -> LevelSnap {
        // 种子框首段 A→B 冻结当步：展示刚冻结段而非同步新起进行中段
        if self.freshly_first_seg {
            if let Some(seg) = self.segments.first() {
                let ub = make_unit_bar(
                    bars,
                    seg.idx,
                    seg.dir,
                    seg.begin_pole_x,
                    seg.end_pole_x,
                    seg.end_confirm_x,
                    seg.begin_fractal_high,
                    seg.begin_fractal_low,
                );
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
                self.fill_seed_snap(&mut snap, bars, pending_input);
                return snap;
            }
        }
        // 种子框动态展示：尚无锚点、首段未确认前
        if self.anchor.is_none() {
            let mut snap = LevelSnap::empty(self.level);
            self.fill_seed_snap(&mut snap, bars, pending_input);
            return snap;
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
                    // 进行中单元只读探测合并态；截断只对已确认下层永久 feed 生效（all_confirm）
                    let ps = e.probe_guarded(unit, None);
                    snap.merge_inner_seq = ps.inner_seq;
                    snap.merge_count = ps.group_count;
                    snap.combine_high = ps.group_high;
                    snap.combine_low = ps.group_low;
                    snap.combine_fx = ps.group_fx.as_str().to_string();
                    snap.combine_x1 = ps.group_x1;
                    snap.merge_box_seq = ps.group_seq;
                }
                None => {
                    snap.combine_high = unit.high;
                    snap.combine_low = unit.low;
                    snap.combine_x1 = unit.x1;
                }
            }
            self.fill_seed_snap(&mut snap, bars, pending_input);
            return snap;
        }
        let mut snap = LevelSnap::empty(self.level);
        self.fill_seed_snap(&mut snap, bars, pending_input);
        snap
    }

    /// 填充种子框快照（口径 A，全层同构）：确认前可随 pending 动态刷新；JUDGE/CONFIRM 填 A/B/C；
    /// UNKNOWN 且已有 group1 时写 `seed_leave_dir`（开口虚线方向，各层同一套）。
    fn fill_seed_snap(
        &self,
        snap: &mut LevelSnap,
        bars: &[KlineBar],
        pending_input: Option<&MergeUnit>,
    ) {
        // ---- 已确认：几何冻结，端点取缓存；次分型未入库时可 probe 填 C ----
        if self.seed_confirmed {
            if let Some(g0) = self.engine.groups().first() {
                snap.seed_box_seq = 0;
                snap.seed_box_x1 = g0.x1;
                snap.seed_box_x2 = g0.x2;
                snap.seed_box_high = g0.high;
                snap.seed_box_low = g0.low;
            } else {
                snap.seed_box_seq = -1;
            }
            snap.seed_confirmed = true;
            snap.seed_fx = match self.seed_fx {
                FxKind::Top => "TOP".to_string(),
                FxKind::Bottom => "BOTTOM".to_string(),
                FxKind::Unknown => "UNKNOWN".to_string(),
            };
            snap.draw_a_x = self.seed_a_x;
            snap.draw_b_x = self.seed_b_x;
            snap.draw_c_x = self.seed_c_x;
            snap.first_fx_state = "CONFIRM".to_string();
            // 确认后不再画 UNKNOWN 开口；leave_dir 清零（全层同构）
            snap.seed_leave_dir = 0;
            // 次分型尚在判断：probe 下层进行中单元，补 C（不改冻结 A/B）
            if snap.draw_c_x < 0 {
                if let Some(c_x) = self.probe_draw_c(bars, pending_input) {
                    snap.draw_c_x = c_x;
                }
            }
            return;
        }

        snap.seed_confirmed = false;
        snap.first_fx_state = "UNKNOWN".to_string();
        snap.draw_a_x = -1;
        snap.draw_b_x = -1;
        snap.draw_c_x = -1;
        snap.seed_fx = "UNKNOWN".to_string();
        snap.seed_leave_dir = 0;

        if let Some(g0) = self.engine.groups().first() {
            snap.seed_box_seq = 0;
            snap.seed_box_x1 = g0.x1;
            snap.seed_box_x2 = g0.x2;
            snap.seed_box_high = g0.high;
            snap.seed_box_low = g0.low;

            // D2 收紧：有非种子组后，对照末组 hn,ln 写 leave_dir（全层同构；含/重叠=0 不画）
            let gs = self.engine.groups();
            if gs.len() >= 2 {
                let gn = gs.last().expect("len>=2");
                snap.seed_leave_dir =
                    seed_leave_dir(g0.high, g0.low, gn.high, gn.low);
            }

            // JUDGE：只读探测第三单元，中组(group1)分型≠0 且尚未 on_confirm
            if let Some(ev) = self.probe_first_fx(pending_input) {
                let seed_fx = if ev.fx == FxKind::Top {
                    FxKind::Bottom
                } else {
                    FxKind::Top
                };
                snap.seed_fx = match seed_fx {
                    FxKind::Top => "TOP".to_string(),
                    FxKind::Bottom => "BOTTOM".to_string(),
                    FxKind::Unknown => "UNKNOWN".to_string(),
                };
                snap.draw_a_x = fx_pole_x(bars, g0.x1, g0.x2, seed_fx);
                snap.draw_b_x = fx_pole_x(bars, ev.x1, ev.x2, ev.fx);
                snap.first_fx_state = "JUDGE".to_string();
                // JUDGE 让位 ABC 虚线；开口 leave_dir 保留供排查，绘制侧看 first_fx_state
                return;
            }

            // 引擎已有三组且中组已标分型（同 bar 确认前的兜底；通常 on_confirm 已跑）
            if gs.len() >= 3 && gs[1].fx != FxKind::Unknown && self.seed_phase == 0 {
                let mid = &gs[1];
                let seed_fx = if mid.fx == FxKind::Top {
                    FxKind::Bottom
                } else {
                    FxKind::Top
                };
                snap.seed_fx = match seed_fx {
                    FxKind::Top => "TOP".to_string(),
                    FxKind::Bottom => "BOTTOM".to_string(),
                    FxKind::Unknown => "UNKNOWN".to_string(),
                };
                snap.draw_a_x = fx_pole_x(bars, g0.x1, g0.x2, seed_fx);
                snap.draw_b_x = fx_pole_x(bars, mid.x1, mid.x2, mid.fx);
                snap.first_fx_state = "JUDGE".to_string();
            }
            return;
        }

        // 引擎空：下层进行中首单元 → 动态种子框预览（口径 A）；尚无 group1 → leave_dir=0
        if let Some(u) = pending_input {
            snap.seed_box_seq = 0;
            snap.seed_box_x1 = u.x1;
            snap.seed_box_x2 = u.x2;
            snap.seed_box_high = u.high;
            snap.seed_box_low = u.low;
        } else {
            snap.seed_box_seq = -1;
            snap.seed_box_x1 = -1;
            snap.seed_box_x2 = -1;
            snap.seed_box_high = f64::NAN;
            snap.seed_box_low = f64::NAN;
        }
    }

    /// 只读探测首个真实分型（种子未确认时；不写引擎）。
    /// 含：groups==1 时动态 Kn 非 leave 截断 → JUDGE（确认仍只走 feed/on_confirm）。
    fn probe_first_fx(&self, pending_input: Option<&MergeUnit>) -> Option<FxEvent> {
        let u = pending_input?;
        if self.engine.groups().is_empty() {
            return None;
        }
        let ps = self.engine.probe_guarded(u, None);
        let ev = ps.fx_event?;
        if ev.fx == FxKind::Unknown {
            None
        } else {
            Some(ev)
        }
    }

    /// 首段已确认、次分型未入库：probe 下层进行中单元取 C 极点
    fn probe_draw_c(&self, bars: &[KlineBar], pending_input: Option<&MergeUnit>) -> Option<i32> {
        let u = pending_input?;
        if self.seed_phase != 1 {
            return None;
        }
        let a = self.anchor.as_ref()?;
        let ps = self.engine.probe_guarded(u, None);
        let ev = ps.fx_event?;
        if ev.fx == FxKind::Unknown || ev.fx == a.fx {
            return None;
        }
        if self.validity_check && !validity_ok(a, ev.fx, ev.high, ev.low) {
            return None;
        }
        Some(fx_pole_x(bars, ev.x1, ev.x2, ev.fx))
    }

    fn export(&self, bars: &[KlineBar]) -> LevelBundleOut {
        // 末步进行中单元：prov 缓存（快照阶段已推进到末K）
        let active_unit = match (&self.anchor, &self.prov) {
            (Some(a), Some(c)) if c.last_x < bars.len() => {
                let dir = if a.fx == FxKind::Bottom { 1 } else { -1 };
                let (open, high, low, close, volume) =
                    kn_unit_ohlcv(bars, dir, a.pole_x, c.last_x as i32, a.high, a.low);
                Some(LevelUnitBar {
                    idx: self.segments.len() as i64,
                    dir,
                    x1: c.x1 as i32,
                    x2: c.last_x as i32,
                    open,
                    high,
                    low,
                    close,
                    volume,
                    confirm_x: c.last_x as i32,
                })
            }
            _ => None,
        };
        // 原生中枢列表只算一次，zs_frames 与 bsp_frames 共用（均只读冻结段，无未来函数）
        let zs_list = crate::zs::find_zs(&self.segments, self.level, &self.zs_config);
        LevelBundleOut {
            level: self.level,
            confirms: self.confirms.clone(),
            segments: self.segments.clone(),
            unit_bars: self.unit_bars.clone(),
            combine_frames: frames_from_engine(&self.engine, bars),
            kuaduan_frames: crate::kuaduan::level_kuaduan_v1_frames(&self.segments, self.level),
            zs_frames: crate::zs::zs_frames_from_list(&zs_list, &self.segments, self.level),
            bsp_frames: crate::bsp::level_bsp_frames(
                &self.segments,
                &zs_list,
                self.level,
                &self.bsp_config,
            ),
            first_dir: self.first_dir,
            first_dir_x: self.first_dir_x,
            active_unit,
            segment_policy: if self.seed_confirmed {
                "retained".to_string()
            } else {
                "seed".to_string()
            },
            pending_unit: None,
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

        // 2) 快照（逐K当下冻结）
        // 进行中单元只读探测仅发生在 snapshot 内（展示用），不在此提前 on_confirm。
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
                group_seq: m.group_seq,
            })
            .unwrap_or(BarCombineSnap {
                inner_seq: 0,
                count: 1,
                high: bar.high,
                low: bar.low,
                fx: "UNKNOWN".to_string(),
                group_seq: -1,
            });
        bar_k_snaps.push(ksnap);

        // 各层进行中单元先行更新（含最顶层）
        let mut provs: Vec<Option<(MergeUnit, f64, f64, f64)>> = Vec::with_capacity(levels.len());
        for lv in levels.iter_mut() {
            provs.push(lv.provisional_unit(bars, i));
        }
        let mut snaps = Vec::with_capacity(levels.len());
        for li in 0..levels.len() {
            let upper = if li + 1 < levels.len() {
                Some(&levels[li + 1].engine)
            } else {
                None
            };
            // 下层进行中单元 → 本层只读探测（JUDGE / 动态种子框）；L1 输入为逐K永久喂入，无 pending
            let pending_input = if li == 0 {
                None
            } else {
                provs[li - 1].as_ref().map(|(u, _, _, _)| u)
            };
            snaps.push(levels[li].snapshot(bars, upper, provs[li].as_ref(), pending_input));
        }
        bar_level_snaps.push(snaps);

        // K1连线兼容行
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
    use crate::engine::{CombineEngine, MergeUnit};

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
        let pair_count = |pr: &PipelineResult| pr.levels[0].segments.len();
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
            .find(|s| s.dir == -1)
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
                lv.segment_policy == "seed"
                    || lv.segment_policy == "retained"
                    || lv.segment_policy == "pending", // 旧 JSON 兼容值
                "level {} policy={}",
                lv.level,
                lv.segment_policy
            );
        }
    }

    /// 种子包含截断：有 truncated 确认并产出首段（端点走常规 First，不另定 A/B）
    #[test]
    fn seed_contain_trunc_first_seg_poles_debug() {
        let bars = vec![bar(0, 10.0, 9.0), bar(1, 12.0, 8.5)];
        let pr = run_pipeline(&bars, &PipelineOptions::default());
        let l1 = &pr.levels[0];
        assert!(
            l1.confirms.iter().any(|c| c.truncated),
            "应有种子包含截断确认"
        );
        assert!(!l1.segments.is_empty(), "截断应产出首段");
        let bars_up = vec![bar(0, 10.0, 9.0), bar(1, 10.5, 7.0)];
        let pr_up = run_pipeline(&bars_up, &PipelineOptions::default());
        assert!(pr_up.levels[0].confirms.iter().any(|c| c.truncated));
        assert!(!pr_up.levels[0].segments.is_empty());
    }

    /// 全层同构：UNKNOWN 时 leave_dir 对照末组 hn,ln（非仅 group1）
    #[test]
    fn seed_leave_dir_d2_before_first_fx_isomorphic() {
        // group0 后下行离开 → leave_dir=-1；尚未第三组 → 仍 UNKNOWN
        let bars = vec![
            bar(0, 10.0, 9.0), // 种子
            bar(1, 8.5, 7.5), // group1 Down sit2
        ];
        let pr = run_pipeline(&bars, &PipelineOptions::default());
        assert!(!pr.bar_level_snaps.is_empty());
        let s0 = &pr.bar_level_snaps[0][0];
        assert_eq!(s0.first_fx_state, "UNKNOWN");
        assert_eq!(s0.seed_leave_dir, 0, "仅 group0 不画开口");
        assert_eq!(s0.seed_box_seq, 0);

        let s1 = &pr.bar_level_snaps[1][0];
        assert_eq!(s1.first_fx_state, "UNKNOWN");
        assert_eq!(s1.seed_leave_dir, -1, "离开种子 Down sit2");
        assert_eq!(s1.seed_box_x1, 0);
        assert_eq!(s1.seed_box_x2, 0);

        // 第一框含第二框 → leave_dir=0
        let bars_in = vec![bar(0, 10.0, 8.0), bar(1, 9.5, 8.5)];
        let pr_in = run_pipeline(&bars_in, &PipelineOptions::default());
        let s_in = &pr_in.bar_level_snaps[1][0];
        assert_eq!(s_in.seed_leave_dir, 0, "第一含第二不画第一条虚线");

        // 语义：对照末组 hn（与仅对照 g1 区分）：末组 sit2 而「假想 g1 sit1」时取末组
        assert_eq!(
            crate::engine::seed_leave_dir(10.0, 9.0, 11.0, 10.0),
            1,
            "假想 g1 sit1"
        );
        assert_eq!(
            crate::engine::seed_leave_dir(10.0, 9.0, 8.5, 7.5),
            -1,
            "末组 sit2 → leave_dir 应以末组为准"
        );

        // 长序列：凡 UNKNOWN 且 leave_dir≠0 的层，口径一致（|dir|==1）
        let long = zigzag(100);
        let pr2 = run_pipeline(&long, &PipelineOptions::default());
        for (bi, snaps) in pr2.bar_level_snaps.iter().enumerate() {
            for (li, s) in snaps.iter().enumerate() {
                if s.first_fx_state == "UNKNOWN" && s.seed_leave_dir != 0 {
                    assert!(
                        s.seed_leave_dir == 1 || s.seed_leave_dir == -1,
                        "bar{bi} L{li} leave_dir={}",
                        s.seed_leave_dir
                    );
                    assert_eq!(s.seed_box_seq, 0);
                    assert!(!s.seed_confirmed);
                }
                if s.seed_confirmed {
                    assert_eq!(s.seed_leave_dir, 0, "确认后 leave_dir 清零 bar{bi} L{li}");
                }
            }
        }
    }

    /// 口径 A：首两单元不做包含 → 两组各 1；首分型确认后种子框冻结 + A→B 入库
    #[test]
    fn seed_box_first_seg_confirm_and_endpoints() {
        // 构造：K0 三根形成 group0/1/2，中组出分型 → Action::First
        let bars = vec![
            bar(0, 10.0, 9.0),  // group0 种子
            bar(1, 8.5, 7.5),  // group1（不与种子合并）
            bar(2, 11.0, 10.0), // group2 → mid(group1) 底分型（低点更低）
            bar(3, 12.0, 11.0),
            bar(4, 9.0, 8.0),
            bar(5, 13.0, 12.0),
            bar(6, 8.0, 7.0),
            bar(7, 14.0, 13.0),
            bar(8, 7.5, 6.5),
            bar(9, 15.0, 14.0),
        ];
        let pr = run_pipeline(&bars, &PipelineOptions::default());
        let l1 = &pr.levels[0];
        assert!(
            !l1.segments.is_empty(),
            "首分型确认应产出 A→B 首段"
        );
        let seg0 = &l1.segments[0];
        assert!(!seg0.is_promoted_default);
        assert!(!seg0.is_bootstrap);
        // 末态快照：种子已确认，A/B 就绪
        let last = pr.bar_level_snaps.last().expect("有快照");
        let s0 = &last[0];
        assert!(s0.seed_confirmed, "确认后种子框确定态");
        assert_eq!(s0.first_fx_state, "CONFIRM");
        assert!(s0.draw_a_x >= 0, "A=种子极值");
        assert!(s0.draw_b_x >= 0, "B=首分型极值");
        assert_eq!(s0.seed_box_seq, 0);
        // 引擎首两单元独立
        assert!(
            l1.combine_frames.len() >= 2,
            "至少两组（种子+次元素）"
        );
        if l1.combine_frames.len() >= 2 {
            assert_eq!(l1.combine_frames[0].count, 1, "种子框单元素");
        }
    }

    /// seed_skip_first：两单元强制两组
    #[test]
    fn seed_skip_first_two_units_two_groups() {
        let mut eng = CombineEngine::new();
        assert!(eng.seed_skip_first);
        let u0 = MergeUnit {
            uid: 0,
            x1: 0,
            x2: 0,
            high: 10.0,
            low: 9.0,
        };
        let u1 = MergeUnit {
            uid: 1,
            x1: 1,
            x2: 1,
            high: 9.5,
            low: 8.5, // 本可被包含，但种子模式跳过
        };
        assert!(eng.feed(&u0).is_none());
        assert!(eng.feed(&u1).is_none());
        assert_eq!(eng.groups().len(), 2);
        assert_eq!(eng.groups()[0].unit_count, 1);
        assert_eq!(eng.groups()[1].unit_count, 1);
    }

    /// 全层同构：Kn 确认的 trigger 必须是已永久冻结的 K(n-1) 单元
    /// （禁止用行进中下层探测提前确认）。
    fn assert_upper_confirms_use_frozen_lower(pr: &PipelineResult) {
        for li in 1..pr.levels.len() {
            let lower = &pr.levels[li - 1];
            let upper = &pr.levels[li];
            for c in &upper.confirms {
                let u = lower
                    .unit_bars
                    .iter()
                    .find(|u| u.idx == c.trigger_uid)
                    .unwrap_or_else(|| {
                        panic!(
                            "K{} 确认 x={} trigger_uid={} 在 K{} 冻结单元中不存在（疑似行进中探测）",
                            upper.level, c.x, c.trigger_uid, lower.level
                        )
                    });
                assert!(
                    u.confirm_x <= c.x,
                    "K{} 确认 x={} 早于触发单元 K{}#{} 的冻结步 confirm_x={}（禁止未确认下层参与上层）",
                    upper.level,
                    c.x,
                    lower.level,
                    u.idx,
                    u.confirm_x
                );
            }
        }
    }

    #[test]
    fn upper_confirm_requires_frozen_lower_unit_zigzag() {
        let bars = zigzag(120);
        let pr = run_pipeline(
            &bars,
            &PipelineOptions {
                truncation_check: false,
                ..PipelineOptions::default()
            },
        );
        if pr.levels.len() >= 2 {
            assert_upper_confirms_use_frozen_lower(&pr);
        }
    }

    /// 实盘样本：旧方案A 会在 K1 未冻结时提前确认 K2（如 10:37 用进行中 K1#93）。
    #[test]
    fn upper_confirm_requires_frozen_lower_unit_688687() {
        let data_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../a_Data");
        if !data_root.join("688687").exists() {
            eprintln!("skip: a_Data/688687 不存在");
            return;
        }
        let root = crate::resolve_data_root(Some(data_root.to_str().unwrap()));
        let bars = crate::load_klines(
            &root,
            "688687",
            "2024/01/01 09:30:00",
            "2024/01/30 15:00:00",
            crate::KlinePeriod::M1,
        )
        .expect("load 688687");
        let pr = run_pipeline(
            &bars,
            &PipelineOptions {
                truncation_check: false,
                ..PipelineOptions::default()
            },
        );
        assert!(pr.levels.len() >= 2);
        // 旧行为对照锚点：K2 顶曾在 x=307、trigger=未冻结的 K1#93
        if let Some(c) = pr.levels[1].confirms.iter().find(|c| c.pole_x == 303) {
            if let Some(u) = pr.levels[0].unit_bars.iter().find(|u| u.idx == c.trigger_uid) {
                assert!(
                    u.confirm_x <= c.x,
                    "回归锚点：K2 顶 pole=303 确认 x={} 不得早于触发 K1#{} 冻结 confirm_x={}",
                    c.x,
                    u.idx,
                    u.confirm_x
                );
            }
        }
        assert_upper_confirms_use_frozen_lower(&pr);
    }

    /// Kn 开盘价：上升取起点底分型最低价，下降取起点顶分型最高价；
    /// 故意污染 bars[].open，防止回归到「用极点 K 的 open/low」。
    #[test]
    fn kn_open_uses_begin_fractal_extreme_not_bar_open() {
        let mut bars = zigzag(80);
        for b in &mut bars {
            b.open = 1.23; // 与分型高低无关
        }
        let pr = run_pipeline(&bars, &PipelineOptions::default());
        for lv in &pr.levels {
            for s in &lv.segments {
                let expect = if s.dir > 0 {
                    s.begin_fractal_low
                } else {
                    s.begin_fractal_high
                };
                assert!(
                    (s.open - expect).abs() < 1e-9,
                    "K{} seg#{} open={} 应为起点分型极值 {}（dir={}）",
                    lv.level,
                    s.idx,
                    s.open,
                    expect,
                    s.dir
                );
            }
            for u in &lv.unit_bars {
                let seg = lv
                    .segments
                    .iter()
                    .find(|s| s.idx == u.idx)
                    .expect("unit_bar 应对齐已冻结段");
                let expect = if seg.dir > 0 {
                    seg.begin_fractal_low
                } else {
                    seg.begin_fractal_high
                };
                assert!(
                    (u.open - expect).abs() < 1e-9,
                    "K{} unit#{} open={} 应为起点分型极值 {}",
                    lv.level,
                    u.idx,
                    u.open,
                    expect
                );
            }
            if let Some(u) = &lv.active_unit {
                let expect = if u.dir > 0 {
                    lv.confirms
                        .iter()
                        .rev()
                        .find(|c| c.used && c.fx == "BOTTOM")
                        .map(|c| c.fractal_low)
                } else {
                    lv.confirms
                        .iter()
                        .rev()
                        .find(|c| c.used && c.fx == "TOP")
                        .map(|c| c.fractal_high)
                };
                if let Some(e) = expect {
                    assert!(
                        (u.open - e).abs() < 1e-9,
                        "K{} active#{} open={} 应为锚点分型极值 {}",
                        lv.level,
                        u.idx,
                        u.open,
                        e
                    );
                }
            }
        }
    }

    /// 回归：002003 顶分型极点 11:08 后，进行中 K1 的 L/H/C 不得吃进极点 K 的低价 11.84
    #[test]
    fn kn_body_excludes_begin_pole_bar_002003() {
        let data_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../a_Data");
        if !data_root.join("002003").exists() {
            eprintln!("skip: a_Data/002003 不存在");
            return;
        }
        let root = crate::resolve_data_root(Some(data_root.to_str().unwrap()));
        let bars = crate::load_klines(
            &root,
            "002003",
            "2004/07/19 10:47:00",
            "2004/07/19 11:11:00",
            crate::KlinePeriod::M1,
        )
        .expect("load 002003");
        let pr = run_pipeline(&bars, &PipelineOptions::default());
        let l1 = &pr.levels[0];
        let u = l1.active_unit.as_ref().expect("应有进行中 K1");
        assert_eq!(u.idx, 3);
        assert_eq!(u.dir, -1);
        assert_eq!(u.x1, 21); // 11:08 极点
        assert_eq!(u.x2, 24); // 11:11
        assert!((u.open - 11.89).abs() < 1e-9, "开盘=顶分型高 open={}", u.open);
        assert!((u.high - 11.89).abs() < 1e-9, "高=段身高 high={}", u.high);
        assert!((u.low - 11.86).abs() < 1e-9, "低=11:09~11:11 最低 low={}", u.low);
        assert!((u.close - 11.86).abs() < 1e-9, "收=11:11 close={}", u.close);
        // 极点 K 低价 11.84 不得污染
        assert!(u.low > 11.84 + 1e-9);
        let snap = &pr.bar_level_snaps.last().unwrap()[0];
        assert!((snap.unit_open - 11.89).abs() < 1e-9);
        assert!((snap.unit_low - 11.86).abs() < 1e-9);
        assert!((snap.unit_close - 11.86).abs() < 1e-9);
    }
}
