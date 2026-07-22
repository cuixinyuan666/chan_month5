//! 包含合并 + 三元素分型统一内核（K0合并 / K1合并 / Kn合并共用；旧称「K线合并/n段K线合并」）。
//! 自洽性质：新组诞生瞬间即可判定中组分型且后续吸收不破坏（Down 组只降、Up 组只升），
//! 因此"确认即冻结"与末态等价，天然满足逐K当下、禁止未来函数。

/// 合并方向（对齐旧 KLINE_DIR 语义）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MergeDir {
    Up,
    Down,
    Combine,
}

/// 分型类型
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FxKind {
    Top,
    Bottom,
    Unknown,
}

impl FxKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Top => "TOP",
            Self::Bottom => "BOTTOM",
            Self::Unknown => "UNKNOWN",
        }
    }

    /// 分型确认柱值：顶=-1（向下新单元起），底=1，未知=0
    pub fn confirm_value(self) -> i32 {
        match self {
            Self::Top => -1,
            Self::Bottom => 1,
            Self::Unknown => 0,
        }
    }
}

/// 可合并单元（层级无关；x 统一锚定 1 分钟 K 索引；uid 为本层单元序号，要求连续递增）
#[derive(Debug, Clone)]
pub struct MergeUnit {
    pub uid: i64,
    pub x1: i32,
    pub x2: i32,
    pub high: f64,
    pub low: f64,
}

/// 合并组（若干单元包含合并后的高低框）
#[derive(Debug, Clone)]
pub struct MergedGroup {
    pub high: f64,
    pub low: f64,
    pub dir: MergeDir,
    pub fx: FxKind,
    pub x1: i32,
    pub x2: i32,
    pub first_uid: i64,
    pub last_uid: i64,
    pub unit_count: i32,
}

/// 分型确认事件（中组三元素成立；feed / probe 共用）
#[derive(Debug, Clone)]
pub struct FxEvent {
    pub fx: FxKind,
    pub x1: i32,
    pub x2: i32,
    pub high: f64,
    pub low: f64,
    pub first_uid: i64,
    pub last_uid: i64,
    /// 截断确认：暴力反转单元触发（非常规三元素路径）
    pub truncated: bool,
}

/// 截断监察参数（上升/下降截断；由调用方按当前锚点方向提供，全层同构）
#[derive(Debug, Clone, Copy)]
pub struct TruncGuard {
    /// true=上行阶段监察上升截断（左框发 TOP）；false=下行阶段监察下降截断（左框发 BOTTOM）
    pub up_leg: bool,
    /// 破坏参照价：上行=上个底分型中组最低价；下行=上个顶分型中组最高价
    pub ref_price: f64,
}

/// 截断命中判定：上升截断=新单元最高价>=左框最高价 且 最低价<上个底分型低；下降截断镜像
fn trunc_hit(last: &MergedGroup, u: &MergeUnit, g: &TruncGuard) -> bool {
    if g.up_leg {
        u.high >= last.high && u.low < g.ref_price
    } else {
        u.low <= last.low && u.high > g.ref_price
    }
}

/// 价格微调步长（保证严格大于/小于左框极值，便于后续三元素双高/双低）
fn trunc_price_step(last: &MergedGroup) -> f64 {
    let span = (last.high - last.low).abs();
    let scale = last.low.abs().max(last.high.abs()).max(1.0);
    (span * 1e-4).max(scale * 1e-8).max(1e-8)
}

/// 截断触发单元改写为「可作第三元素」形态（全层同构）：
/// - 下降截断（左框 BOTTOM）：保留触发高点，抬低点至左框低之上（仿正常底分型右元素）
/// - 上升截断（左框 TOP）：保留破位低点，压高点至左框高之下（镜像）
fn trunc_rewrite_trigger_unit(last: &MergedGroup, u: &MergeUnit, up_leg: bool) -> MergeUnit {
    let step = trunc_price_step(last);
    let mut out = u.clone();
    if up_leg {
        // 上升截断 → 左框 TOP：第三元素应 high<mid.high 且 low<mid.low
        if out.high >= last.high {
            out.high = last.high - step;
        }
        if out.low >= last.low {
            out.low = last.low - step;
        }
    } else {
        // 下降截断 → 左框 BOTTOM：第三元素应 high>mid.high 且 low>mid.low
        if out.low <= last.low {
            out.low = last.low + step;
        }
        if out.high <= last.high {
            out.high = last.high + step;
        }
    }
    // 保序：高 >= 低
    if out.high < out.low {
        if up_leg {
            out.high = out.low;
        } else {
            out.low = out.high;
        }
    }
    out
}

/// 末态/离线重放用截断状态机（与 LevelState 锚点+参照价口径同构）。
/// 供 K1合并副图等「只喂单元、不跑完整段配对」场景复用。
#[derive(Debug, Clone)]
pub struct TruncReplayState {
    truncation_check: bool,
    validity_check: bool,
    anchor_fx: Option<FxKind>,
    anchor_high: f64,
    anchor_low: f64,
    last_bottom_low: Option<f64>,
    last_top_high: Option<f64>,
}

impl TruncReplayState {
    pub fn new(truncation_check: bool, validity_check: bool) -> Self {
        Self {
            truncation_check,
            validity_check,
            anchor_fx: None,
            anchor_high: 0.0,
            anchor_low: 0.0,
            last_bottom_low: None,
            last_top_high: None,
        }
    }

    /// 当步截断监察参数（首确认前=None；同向丢弃/校验失败不翻锚点）
    pub fn guard(&self) -> Option<TruncGuard> {
        if !self.truncation_check {
            return None;
        }
        match self.anchor_fx? {
            FxKind::Bottom => self
                .last_bottom_low
                .map(|p| TruncGuard {
                    up_leg: true,
                    ref_price: p,
                }),
            FxKind::Top => self
                .last_top_high
                .map(|p| TruncGuard {
                    up_leg: false,
                    ref_price: p,
                }),
            FxKind::Unknown => None,
        }
    }

    /// 消化一次分型事件：更新破坏参照价；仅首确认/异向配对翻锚点
    pub fn on_event(&mut self, ev: &FxEvent) {
        if ev.fx == FxKind::Unknown {
            return;
        }
        match ev.fx {
            FxKind::Bottom => self.last_bottom_low = Some(ev.low),
            FxKind::Top => self.last_top_high = Some(ev.high),
            FxKind::Unknown => {}
        }
        match self.anchor_fx {
            None => {
                self.anchor_fx = Some(ev.fx);
                self.anchor_high = ev.high;
                self.anchor_low = ev.low;
            }
            Some(a) if a == ev.fx => {
                // 同向丢弃：锚点不回写
            }
            Some(a) => {
                let ok = if !self.validity_check {
                    true
                } else {
                    match (a, ev.fx) {
                        (FxKind::Bottom, FxKind::Top) => ev.high > self.anchor_low,
                        (FxKind::Top, FxKind::Bottom) => ev.low < self.anchor_high,
                        _ => false,
                    }
                };
                if ok {
                    self.anchor_fx = Some(ev.fx);
                    self.anchor_high = ev.high;
                    self.anchor_low = ev.low;
                }
            }
        }
    }
}

/// 进行中单元只读探测结果（十字线快照 + 可能的分型事件）
#[derive(Debug, Clone)]
pub struct ProbeState {
    pub fx_event: Option<FxEvent>,
    pub group_high: f64,
    pub group_low: f64,
    pub group_fx: FxKind,
    pub inner_seq: i32,
    pub group_count: i32,
    /// 当步所在合并组首单元 uid（as-of 查表重建用）
    pub group_first_uid: i64,
    /// 当步所在合并组 x 起点（1 分钟 K）
    pub group_x1: i32,
    /// 当步所在合并框序号（0 起；-1=未成框）
    pub group_seq: i32,
}

/// 包含关系判定（与旧 test_combine 默认口径一致）
pub fn test_combine_range(high_a: f64, low_a: f64, high_b: f64, low_b: f64) -> MergeDir {
    if high_a >= high_b && low_a <= low_b {
        return MergeDir::Combine;
    }
    if high_a <= high_b && low_a >= low_b {
        return MergeDir::Combine;
    }
    if high_a > high_b && low_a > low_b {
        return MergeDir::Down;
    }
    if high_a < high_b && low_a < low_b {
        return MergeDir::Up;
    }
    MergeDir::Combine
}

/// 种子开口虚线方向（全层同构）：仅 sit1/sit2 非零。
/// 对照框为当前末组 hn,ln（n>0；fill_seed_snap 取 groups.last()），与种子 h1,l1 比较。
/// sit1: hn>h1 && ln>l1 → +1；sit2: hn<h1 && ln<l1 → -1；
/// 种子含末组（hn<=h1 && ln>=l1，含全等）及其它重叠 → 0（不画第一条虚线）。
pub fn seed_leave_dir(h1: f64, l1: f64, h2: f64, l2: f64) -> i32 {
    if h2 > h1 && l2 > l1 {
        1
    } else if h2 < h1 && l2 < l1 {
        -1
    } else {
        0
    }
}

/// 第二框严格包含第一框（全等除外）。历史兼容；截断门控改见 `seed_nonleave_may_trunc`。
pub fn seed_second_contains_first(h1: f64, l1: f64, h2: f64, l2: f64) -> bool {
    h2 >= h1 && l2 <= l1 && !(h2 == h1 && l2 == l1)
}

/// 相对种子是否 sit1/sit2 离开（第一条虚线方向成立）。
pub fn seed_is_leave(h1: f64, l1: f64, hn: f64, ln: f64) -> bool {
    seed_leave_dir(h1, l1, hn, ln) != 0
}

/// 非 leave 截断方向（全层同构）：比较 abs(hn-h1) 与 abs(ln-l1)。
/// dh>dl 或 dh==dl → 向下截断（返回 false=up_leg 下降截断，左框 BOTTOM）；
/// dh<dl → 向上截断（返回 true，左框 TOP）。
pub fn seed_contain_trunc_up_leg(h1: f64, l1: f64, h2: f64, l2: f64) -> bool {
    let dh = (h2 - h1).abs();
    let dl = (l2 - l1).abs();
    dl > dh
}

/// 第一条虚线期截断门控（全层同构）：
/// sit1/sit2（leave）→ 不截；非 leave → 整层引擎内至多一次。
pub fn seed_nonleave_may_trunc(
    leave_seen: bool,
    trunc_used: bool,
    h1: f64,
    l1: f64,
    hn: f64,
    ln: f64,
) -> bool {
    if leave_seen || trunc_used {
        return false;
    }
    !seed_is_leave(h1, l1, hn, ln)
}

/// 三元素分型判定（pre/mid 已定组，next 允许用虚拟高低）
fn fx_of(pre: &MergedGroup, mid: &MergedGroup, next_high: f64, next_low: f64) -> FxKind {
    if pre.high < mid.high && next_high < mid.high && pre.low < mid.low && next_low < mid.low {
        FxKind::Top
    } else if pre.high > mid.high && next_high > mid.high && pre.low > mid.low && next_low > mid.low
    {
        FxKind::Bottom
    } else {
        FxKind::Unknown
    }
}

impl MergedGroup {
    fn new_first(u: &MergeUnit, dir: MergeDir) -> Self {
        Self {
            high: u.high,
            low: u.low,
            dir,
            fx: FxKind::Unknown,
            x1: u.x1,
            x2: u.x2,
            first_uid: u.uid,
            last_uid: u.uid,
            unit_count: 1,
        }
    }

    /// 包含吸收：Up 取高高/高低，Down 取低高/低低（一字线不再特殊跳过）
    fn absorb(&mut self, u: &MergeUnit) {
        if self.dir == MergeDir::Up {
            self.high = self.high.max(u.high);
            self.low = self.low.max(u.low);
        } else if self.dir == MergeDir::Down {
            self.high = self.high.min(u.high);
            self.low = self.low.min(u.low);
        }
        self.x2 = u.x2;
        self.last_uid = u.uid;
        self.unit_count += 1;
    }

    fn to_event(&self) -> FxEvent {
        FxEvent {
            fx: self.fx,
            x1: self.x1,
            x2: self.x2,
            high: self.high,
            low: self.low,
            first_uid: self.first_uid,
            last_uid: self.last_uid,
            truncated: false,
        }
    }

    /// 组内快照（uid 连续递增 → 组内序号 = uid - first_uid）
    fn snapshot(&self, uid: i64, seq: i32) -> ProbeState {
        let inner = (uid - self.first_uid).clamp(0, (self.unit_count - 1) as i64) as i32;
        ProbeState {
            fx_event: None,
            group_high: self.high,
            group_low: self.low,
            group_fx: self.fx,
            inner_seq: inner,
            group_count: self.unit_count,
            group_first_uid: self.first_uid,
            group_x1: self.x1,
            group_seq: seq,
        }
    }
}

/// 包含合并引擎：增量喂入单元，产出合并组与三元素分型事件
#[derive(Debug, Clone)]
pub struct CombineEngine {
    groups: Vec<MergedGroup>,
    /// 种子框模式（口径 A）：首两单元不做包含合并（group0=种子框单元素，永不吸收第二根；
    /// group1 强制自成新组）。确认前种子框高低可由下层进行中单元 probe 刷新（见 pipeline 快照）。
    /// 全层同构启用；仅首两单元例外，其余包含合并与三元素分型全层一致。
    pub seed_skip_first: bool,
    /// 相对种子已出现 sit1/sit2 → 之后不再触发截断（第一条虚线口径）
    seed_leave_seen: bool,
    /// 非 leave 截断已用过一次（种子非 leave / TruncGuard 共用额度）
    nonleave_trunc_used: bool,
}

impl Default for CombineEngine {
    fn default() -> Self {
        Self {
            groups: Vec::new(),
            seed_skip_first: true,
            seed_leave_seen: false,
            nonleave_trunc_used: false,
        }
    }
}

impl CombineEngine {
    pub fn new() -> Self {
        Self {
            groups: Vec::new(),
            seed_skip_first: true,
            seed_leave_seen: false,
            nonleave_trunc_used: false,
        }
    }

    pub fn groups(&self) -> &[MergedGroup] {
        &self.groups
    }

    pub fn is_empty(&self) -> bool {
        self.groups.is_empty()
    }

    /// 对照种子更新 leave 锁；返回当前是否允许再做一次非 leave 截断。
    /// `seed_skip_first=false` 时不做第一条虚线门控（TruncGuard 单测等）。
    fn allow_nonleave_trunc(&mut self, hn: f64, ln: f64) -> bool {
        if !self.seed_skip_first {
            return true;
        }
        let (h1, l1) = match self.groups.first() {
            Some(g) => (g.high, g.low),
            None => return false,
        };
        if seed_is_leave(h1, l1, hn, ln) {
            self.seed_leave_seen = true;
            return false;
        }
        seed_nonleave_may_trunc(
            self.seed_leave_seen,
            self.nonleave_trunc_used,
            h1,
            l1,
            hn,
            ln,
        )
    }

    fn mark_nonleave_trunc_used(&mut self) {
        self.nonleave_trunc_used = true;
    }

    /// 永久喂入单元；三组成立时返回中组分型事件（当步冻结，后续吸收不破坏）
    pub fn feed(&mut self, u: &MergeUnit) -> Option<FxEvent> {
        self.feed_guarded(u, None)
    }

    /// 永久喂入 + 截断监察：本应被包含吸收的暴力反转单元命中截断时，
    /// 左框保持原高低并当场冻结分型（上行=TOP/下行=BOTTOM），该单元强制断开成新组
    /// （上升截断开下行组 / 下降截断开上行组），并参与后续三元素监控（监控范围>=第四根）。
    /// 触发单元高低改写为「可作第三元素」形态（下降截断抬低点/上升截断压高点），便于后续双高双低。
    /// 非包含关系不拦截：常规三元素路径本身能正确判定，截断只救"信号被吸收吃掉"的场景。
    pub fn feed_guarded(&mut self, u: &MergeUnit, guard: Option<&TruncGuard>) -> Option<FxEvent> {
        if self.groups.is_empty() {
            self.groups.push(MergedGroup::new_first(u, MergeDir::Up));
            return None;
        }
        // 种子框模式：首两单元不做包含合并（group0=种子框单元素）；
        // leave(sit1/sit2)→不截；非 leave 且第二框严格包含种子 → 第一条虚线窗口内至多截一次
        // （首个分型确认/判断之后的 TruncGuard 不受本门控）
        if self.groups.len() == 1 && self.seed_skip_first {
            let (h1, l1) = (self.groups[0].high, self.groups[0].low);
            let leave = seed_leave_dir(h1, l1, u.high, u.low);
            let is_leave = leave != 0;
            let contains = seed_second_contains_first(h1, l1, u.high, u.low);
            let may = self.allow_nonleave_trunc(u.high, u.low);
            if may && contains {
                let up_leg = seed_contain_trunc_up_leg(h1, l1, u.high, u.low);
                self.groups[0].fx = if up_leg {
                    FxKind::Top
                } else {
                    FxKind::Bottom
                };
                let mut ev = self.groups[0].to_event();
                ev.truncated = true;
                let forced = if up_leg { MergeDir::Down } else { MergeDir::Up };
                let rewritten = trunc_rewrite_trigger_unit(&self.groups[0], u, up_leg);
                self.groups.push(MergedGroup::new_first(&rewritten, forced));
                self.mark_nonleave_trunc_used();
                return Some(ev);
            }
            let dir = match test_combine_range(h1, l1, u.high, u.low) {
                MergeDir::Combine => MergeDir::Up, // 第一框含第二/互含：组方向占位，leave_dir 另行判定
                other => other,
            };
            self.groups.push(MergedGroup::new_first(u, dir));
            // 仅种子第二单元成组时锁 leave（首分型前第一条虚线口径）
            if is_leave {
                self.seed_leave_seen = true;
            }
            return None; // 仅两组，尚不足中组，无分型
        }
        let last = self.groups.len() - 1;
        let dir =
            test_combine_range(self.groups[last].high, self.groups[last].low, u.high, u.low);
        if dir == MergeDir::Combine {
            if let Some(g) = guard {
                if trunc_hit(&self.groups[last], u, g) {
                    // 首个 Kn 分型确认/判断之后：TruncGuard 保持原实现（不受第一条虚线 leave/一次额度约束）
                    self.groups[last].fx = if g.up_leg { FxKind::Top } else { FxKind::Bottom };
                    let mut ev = self.groups[last].to_event();
                    ev.truncated = true;
                    let forced = if g.up_leg { MergeDir::Down } else { MergeDir::Up };
                    let rewritten = trunc_rewrite_trigger_unit(&self.groups[last], u, g.up_leg);
                    self.groups.push(MergedGroup::new_first(&rewritten, forced));
                    return Some(ev);
                }
            }
            self.groups[last].absorb(u);
            return None;
        }
        self.groups.push(MergedGroup::new_first(u, dir));
        let n = self.groups.len();
        if n < 3 {
            return None;
        }
        let fx = fx_of(
            &self.groups[n - 3],
            &self.groups[n - 2],
            self.groups[n - 1].high,
            self.groups[n - 1].low,
        );
        self.groups[n - 2].fx = fx;
        if fx == FxKind::Unknown {
            None
        } else {
            Some(self.groups[n - 2].to_event())
        }
    }

    /// 进行中单元只读探测：语义与 feed 完全一致（包含并入 → 无分型判定；成新组 → 判原末组），
    /// 但不写入引擎状态；分型事件的冻结去重由调用方管理。
    pub fn probe(&self, u: &MergeUnit) -> ProbeState {
        self.probe_guarded(u, None)
    }

    /// 只读探测 + 截断监察（与 feed_guarded 语义一致，不写状态）：
    /// 命中截断时返回左框分型事件（truncated），组快照按"断开成新组"视角。
    pub fn probe_guarded(&self, u: &MergeUnit, guard: Option<&TruncGuard>) -> ProbeState {
        if self.groups.is_empty() {
            return ProbeState {
                fx_event: None,
                group_high: u.high,
                group_low: u.low,
                group_fx: FxKind::Unknown,
                inner_seq: 0,
                group_count: 1,
                group_first_uid: u.uid,
                group_x1: u.x1,
                group_seq: 0,
            };
        }
        // 种子框模式（只读探测）：非 leave → 至多一次截断视角；leave → 不截（与 feed 同构）
        if self.groups.len() == 1 && self.seed_skip_first {
            let g0 = &self.groups[0];
            let may = seed_nonleave_may_trunc(
                self.seed_leave_seen,
                self.nonleave_trunc_used,
                g0.high,
                g0.low,
                u.high,
                u.low,
            );
            let contains = seed_second_contains_first(g0.high, g0.low, u.high, u.low);
            if may && contains {
                let up_leg = seed_contain_trunc_up_leg(g0.high, g0.low, u.high, u.low);
                let mut ev = g0.to_event();
                ev.fx = if up_leg {
                    FxKind::Top
                } else {
                    FxKind::Bottom
                };
                ev.truncated = true;
                let rewritten = trunc_rewrite_trigger_unit(g0, u, up_leg);
                return ProbeState {
                    fx_event: Some(ev),
                    group_high: rewritten.high,
                    group_low: rewritten.low,
                    group_fx: FxKind::Unknown,
                    inner_seq: 0,
                    group_count: 1,
                    group_first_uid: u.uid,
                    group_x1: u.x1,
                    group_seq: 1,
                };
            }
            return ProbeState {
                fx_event: None,
                group_high: u.high,
                group_low: u.low,
                group_fx: FxKind::Unknown,
                inner_seq: 0,
                group_count: 1,
                group_first_uid: u.uid,
                group_x1: u.x1,
                group_seq: 1,
            };
        }
        let n = self.groups.len();
        let last = &self.groups[n - 1];
        let dir = test_combine_range(last.high, last.low, u.high, u.low);
        if dir == MergeDir::Combine {
            if let Some(g) = guard {
                // 首个 Kn 分型确认/判断之后：TruncGuard 原实现（不受第一条虚线门控）
                if trunc_hit(last, u, g) {
                    let mut ev = last.to_event();
                    ev.fx = if g.up_leg { FxKind::Top } else { FxKind::Bottom };
                    ev.truncated = true;
                    let rewritten = trunc_rewrite_trigger_unit(last, u, g.up_leg);
                    return ProbeState {
                        fx_event: Some(ev),
                        group_high: rewritten.high,
                        group_low: rewritten.low,
                        group_fx: FxKind::Unknown,
                        inner_seq: 0,
                        group_count: 1,
                        group_first_uid: u.uid,
                        group_x1: u.x1,
                        group_seq: n as i32,
                    };
                }
            }
            let mut g = last.clone();
            g.absorb(u);
            return ProbeState {
                fx_event: None,
                group_high: g.high,
                group_low: g.low,
                group_fx: g.fx,
                inner_seq: g.unit_count - 1,
                group_count: g.unit_count,
                group_first_uid: g.first_uid,
                group_x1: g.x1,
                group_seq: n as i32 - 1,
            };
        }
        // u 成新组 → 原末组成为中组，可判分型
        let fx_event = if n >= 2 {
            let fx = fx_of(&self.groups[n - 2], &self.groups[n - 1], u.high, u.low);
            if fx == FxKind::Unknown {
                None
            } else {
                let mut ev = self.groups[n - 1].to_event();
                ev.fx = fx;
                Some(ev)
            }
        } else {
            None
        };
        ProbeState {
            fx_event,
            group_high: u.high,
            group_low: u.low,
            group_fx: FxKind::Unknown,
            inner_seq: 0,
            group_count: 1,
            group_first_uid: u.uid,
            group_x1: u.x1,
            group_seq: n as i32,
        }
    }

    /// 已冻结单元的十字线快照：按 first_uid 二分定位 uid 所在组
    pub fn snapshot_for(&self, uid: i64) -> Option<ProbeState> {
        if self.groups.is_empty() {
            return None;
        }
        let pos = self
            .groups
            .partition_point(|g| g.first_uid <= uid)
            .checked_sub(1)?;
        let g = &self.groups[pos];
        if uid > g.last_uid {
            return None;
        }
        Some(g.snapshot(uid, pos as i32))
    }

    /// 末组快照（无锚定 uid 时的当前状态）
    pub fn last_group(&self) -> Option<&MergedGroup> {
        self.groups.last()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unit(uid: i64, h: f64, l: f64) -> MergeUnit {
        MergeUnit {
            uid,
            x1: uid as i32,
            x2: uid as i32,
            high: h,
            low: l,
        }
    }

    #[test]
    fn feed_detects_bottom_fractal() {
        let mut eng = CombineEngine::new();
        assert!(eng.feed(&unit(0, 10.0, 9.0)).is_none());
        assert!(eng.feed(&unit(1, 9.0, 8.0)).is_none());
        let ev = eng.feed(&unit(2, 10.5, 9.5));
        assert!(ev.is_some());
        assert_eq!(ev.unwrap().fx, FxKind::Bottom);
    }

    #[test]
    fn combine_absorbs_and_counts() {
        let mut eng = CombineEngine::new();
        eng.feed(&unit(0, 10.0, 9.0));
        // 种子模式：首两单元不合并（group0=种子框单元素；group1 强制自成新组）
        eng.feed(&unit(1, 9.5, 9.2)); // 与首组互含，但不再吸收
        assert_eq!(eng.groups().len(), 2);
        assert_eq!(eng.groups()[0].unit_count, 1);
        assert_eq!(eng.groups()[1].unit_count, 1);
        let snap = eng.snapshot_for(1).unwrap();
        assert_eq!(snap.inner_seq, 0);
        assert_eq!(snap.group_count, 1);
    }

    /// Up 组合并同高一字线：应按高低=max 抬低点（不再跳过一字线）
    #[test]
    fn up_absorb_same_high_doji_lifts_low() {
        let mut eng = CombineEngine::new();
        eng.feed(&unit(0, 11.93, 11.92)); // Down 前缀
        eng.feed(&unit(1, 11.96, 11.95)); // Up 新组
        eng.feed(&unit(2, 11.96, 11.96)); // 同高一字线
        let g = &eng.groups()[1];
        assert_eq!((g.x1, g.x2), (1, 2));
        assert!((g.high - 11.96).abs() < 1e-12);
        assert!((g.low - 11.96).abs() < 1e-12, "应抬成一字价 low={}", g.low);
    }

    /// Down 组合并同低一字线：应按高低=min 压高点
    #[test]
    fn down_absorb_same_low_doji_lowers_high() {
        let mut eng = CombineEngine::new();
        eng.feed(&unit(0, 12.0, 11.9));
        eng.feed(&unit(1, 11.8, 11.7)); // Down 新组
        eng.feed(&unit(2, 11.7, 11.7)); // 同低一字线
        let g = &eng.groups()[1];
        assert_eq!((g.x1, g.x2), (1, 2));
        assert!((g.high - 11.7).abs() < 1e-12, "应压成一字价 high={}", g.high);
        assert!((g.low - 11.7).abs() < 1e-12);
    }

    #[test]
    fn probe_matches_feed_semantics() {
        let mut eng = CombineEngine::new();
        eng.feed(&unit(0, 10.0, 9.0));
        eng.feed(&unit(1, 9.0, 8.0));
        // 探测：u 成新组 → 判中组 BOTTOM
        let ps = eng.probe(&unit(2, 10.5, 9.5));
        assert!(ps.fx_event.is_some());
        assert_eq!(ps.fx_event.unwrap().fx, FxKind::Bottom);
        // 引擎本体未被修改
        assert_eq!(eng.groups().len(), 2);
        // 探测：包含并入 → 无分型判定
        let ps2 = eng.probe(&unit(2, 9.5, 7.5));
        assert!(ps2.fx_event.is_none());
        assert_eq!(ps2.group_count, 2);
    }

    /// 底分型确认后（监控范围>=第四根），第4根暴力反转命中上升截断：
    /// 左框=顶分型中组高低保持原样，截断K强制断开成新下行组
    #[test]
    fn feed_guarded_up_truncation_splits_and_confirms_top() {
        let mut eng = CombineEngine::new();
        eng.seed_skip_first = false; // 本测专测 TruncGuard，关闭种子额度以免 leave/一次锁干扰
        eng.feed(&unit(0, 10.0, 9.0));
        eng.feed(&unit(1, 9.0, 8.0));
        let ev = eng.feed(&unit(2, 10.5, 9.5)).unwrap();
        assert_eq!(ev.fx, FxKind::Bottom); // 上个底分型最低点=8
        let guard = TruncGuard { up_leg: true, ref_price: 8.0 };
        // 第4根：高11>=左框高10.5 且 低7.5<8 → 上升截断
        let ev = eng.feed_guarded(&unit(3, 11.0, 7.5), Some(&guard)).unwrap();
        assert_eq!(ev.fx, FxKind::Top);
        assert!(ev.truncated);
        assert!((ev.high - 10.5).abs() < 1e-9); // 左框高低不被截断K改写
        assert!((ev.low - 9.5).abs() < 1e-9);
        assert_eq!(eng.groups().len(), 4); // 截断K独立成新组
        assert_eq!(eng.groups()[2].fx, FxKind::Top);
        assert_eq!(eng.groups()[3].dir, MergeDir::Down);
        assert_eq!(eng.groups()[3].unit_count, 1);
    }

    /// 对照：无截断监察时暴力反转K被包含吸收，左框高被改写、信号丢失（旧行为）
    #[test]
    fn feed_without_guard_absorbs_violent_bar() {
        let mut eng = CombineEngine::new();
        eng.seed_skip_first = false;
        eng.feed(&unit(0, 10.0, 9.0));
        eng.feed(&unit(1, 9.0, 8.0));
        eng.feed(&unit(2, 10.5, 9.5));
        assert!(eng.feed(&unit(3, 11.0, 7.5)).is_none());
        assert_eq!(eng.groups().len(), 3);
        assert!((eng.groups()[2].high - 11.0).abs() < 1e-9);
    }

    /// probe 与 feed 截断语义一致：返回同一事件但不写引擎状态
    #[test]
    fn probe_guarded_matches_feed_truncation() {
        let mut eng = CombineEngine::new();
        eng.seed_skip_first = false;
        eng.feed(&unit(0, 10.0, 9.0));
        eng.feed(&unit(1, 9.0, 8.0));
        eng.feed(&unit(2, 10.5, 9.5));
        let guard = TruncGuard { up_leg: true, ref_price: 8.0 };
        let ps = eng.probe_guarded(&unit(3, 11.0, 7.5), Some(&guard));
        let ev = ps.fx_event.expect("探测应命中截断");
        assert_eq!(ev.fx, FxKind::Top);
        assert!(ev.truncated);
        // 只读：引擎未被修改
        assert_eq!(eng.groups().len(), 3);
        assert_eq!(eng.groups()[2].fx, FxKind::Unknown);
        // 断开成新组视角
        assert_eq!(ps.group_count, 1);
        assert_eq!(ps.inner_seq, 0);
    }

    /// 下降截断镜像：低<=左框低 且 高>上个顶分型最高点 → 左框底分型确认，新组向上
    #[test]
    fn feed_guarded_down_truncation_mirror() {
        let mut eng = CombineEngine::new();
        eng.seed_skip_first = false;
        eng.feed(&unit(0, 10.0, 9.0));
        eng.feed(&unit(1, 11.0, 10.5));
        let ev = eng.feed(&unit(2, 9.5, 8.5)).unwrap();
        assert_eq!(ev.fx, FxKind::Top); // 上个顶分型最高点=11
        let guard = TruncGuard { up_leg: false, ref_price: 11.0 };
        let ev = eng.feed_guarded(&unit(3, 11.5, 8.0), Some(&guard)).unwrap();
        assert_eq!(ev.fx, FxKind::Bottom);
        assert!(ev.truncated);
        assert!((ev.high - 9.5).abs() < 1e-9);
        assert!((ev.low - 8.5).abs() < 1e-9);
        assert_eq!(eng.groups().len(), 4);
        assert_eq!(eng.groups()[3].dir, MergeDir::Up);
    }

    /// 截断后触发单元改写为「可作第三元素」形态：下降截断抬低点，便于后续双高顶
    #[test]
    fn trunc_rewrite_allows_following_dual_high_top() {
        // 模拟 10:02 底框 / 10:03 外破触发下降截断 / 10:04 回落
        let mut eng = CombineEngine::new();
        eng.seed_skip_first = false;
        eng.feed(&unit(0, 33.55, 33.51)); // 前
        eng.feed(&unit(1, 33.53, 33.50)); // 10:02 左框（将成截断底）
        // 先不成三元素；用下降截断确认左框底
        let guard = TruncGuard {
            up_leg: false,
            ref_price: 33.55,
        };
        // 10:03 外破：更高高+更低低，本应被吸收
        let ev = eng
            .feed_guarded(&unit(2, 33.57, 33.48), Some(&guard))
            .expect("应命中下降截断");
        assert_eq!(ev.fx, FxKind::Bottom);
        assert!(ev.truncated);
        let trig = &eng.groups()[2];
        assert!(
            trig.low > eng.groups()[1].low,
            "触发单元改写后低点应高于左框低: trig.L={} left.L={}",
            trig.low,
            eng.groups()[1].low
        );
        assert!((trig.high - 33.57).abs() < 1e-9, "高点保留触发值");
        // 10:04 回落 → 应对改写后的 10:03 确认顶分型（双高）
        let ev = eng.feed(&unit(3, 33.44, 33.28)).expect("应确认顶分型");
        assert_eq!(ev.fx, FxKind::Top);
        assert!(!ev.truncated);
        assert!((ev.high - 33.57).abs() < 1e-9);
        assert!(ev.low > 33.50, "顶中组低点应高于前底框低");
    }

    /// 上升截断镜像改写：压高点，保留破位低点
    #[test]
    fn trunc_rewrite_up_leg_clamps_high() {
        let mut eng = CombineEngine::new();
        eng.seed_skip_first = false;
        eng.feed(&unit(0, 10.0, 9.0));
        eng.feed(&unit(1, 9.0, 8.0));
        eng.feed(&unit(2, 10.5, 9.5));
        let guard = TruncGuard { up_leg: true, ref_price: 8.0 };
        eng.feed_guarded(&unit(3, 11.0, 7.5), Some(&guard)).unwrap();
        let trig = &eng.groups()[3];
        let left = &eng.groups()[2];
        assert!(
            trig.high < left.high,
            "上升截断触发单元高点应压到左框高之下: trig.H={} left.H={}",
            trig.high,
            left.high
        );
        assert!((trig.low - 7.5).abs() < 1e-9, "破位低点保留");
    }

    #[test]
    fn seed_leave_dir_only_sit1_sit2() {
        assert_eq!(seed_leave_dir(10.0, 9.0, 11.0, 9.5), 1); // sit1
        assert_eq!(seed_leave_dir(10.0, 9.0, 9.0, 8.0), -1); // sit2
        assert_eq!(seed_leave_dir(10.0, 9.0, 9.5, 9.2), 0); // 第一含第二
        assert_eq!(seed_leave_dir(10.0, 9.0, 10.0, 9.0), 0); // 全等
        assert_eq!(seed_leave_dir(10.0, 9.0, 11.0, 8.0), 0); // 第二严格包含→不画虚线
    }

    /// 第一条虚线期：sit1 leave 不触发种子截断（与严格包含互斥，且锁 leave_seen）
    #[test]
    fn seed_leave_does_not_trunc() {
        let mut eng = CombineEngine::new();
        eng.feed(&unit(0, 10.0, 9.0));
        assert!(eng.feed(&unit(1, 11.0, 10.0)).is_none());
        assert_eq!(eng.groups().len(), 2);
        assert_eq!(eng.groups()[0].fx, FxKind::Unknown);
    }

    /// 第一条虚线期：严格包含截断一次后，种子路径不再二次截（groups 已>=2）
    #[test]
    fn seed_contain_trunc_only_once_in_seed_window() {
        let mut eng = CombineEngine::new();
        eng.feed(&unit(0, 10.0, 9.0));
        let ev = eng.feed(&unit(1, 12.0, 8.5)).unwrap();
        assert!(ev.truncated);
        assert_eq!(ev.fx, FxKind::Bottom);
        // 再喂不走种子路径；首分型后 TruncGuard 另论（本测不盖）
        assert!(eng.groups().len() >= 2);
    }

    /// 第二框严格包含种子：dh>dl → 向下截断（左框 BOTTOM）
    #[test]
    fn seed_contain_trunc_down_when_dh_ge_dl() {
        let mut eng = CombineEngine::new();
        eng.feed(&unit(0, 10.0, 9.0));
        // h2=12(+2), l2=8.5(-0.5) → dh>dl → 向下
        let ev = eng.feed(&unit(1, 12.0, 8.5)).unwrap();
        assert!(ev.truncated);
        assert_eq!(ev.fx, FxKind::Bottom);
        assert_eq!(eng.groups().len(), 2);
        assert_eq!(eng.groups()[0].fx, FxKind::Bottom);
        assert_eq!(eng.groups()[1].dir, MergeDir::Up);
    }

    /// 第二框严格包含种子：dh<dl → 向上截断（左框 TOP）
    #[test]
    fn seed_contain_trunc_up_when_dl_gt_dh() {
        let mut eng = CombineEngine::new();
        eng.feed(&unit(0, 10.0, 9.0));
        // h2=10.5(+0.5), l2=7.0(-2) → dl>dh → 向上
        let ev = eng.feed(&unit(1, 10.5, 7.0)).unwrap();
        assert!(ev.truncated);
        assert_eq!(ev.fx, FxKind::Top);
        assert_eq!(eng.groups()[0].fx, FxKind::Top);
        assert_eq!(eng.groups()[1].dir, MergeDir::Down);
    }

    /// dh==dl 默认向下截断
    #[test]
    fn seed_contain_trunc_tie_defaults_down() {
        assert!(!seed_contain_trunc_up_leg(10.0, 9.0, 11.0, 8.0)); // dh=1,dl=1
        assert!(seed_second_contains_first(10.0, 9.0, 11.0, 8.0));
    }

    /// probe 与 feed 同构：包含截断只读返回 truncated 事件
    #[test]
    fn seed_contain_trunc_probe_isomorphic() {
        let mut eng = CombineEngine::new();
        eng.feed(&unit(0, 10.0, 9.0));
        let ps = eng.probe(&unit(1, 12.0, 8.5));
        let ev = ps.fx_event.expect("应有截断探测");
        assert!(ev.truncated);
        assert_eq!(ev.fx, FxKind::Bottom);
        assert_eq!(eng.groups().len(), 1, "probe 不写引擎");
    }
}
