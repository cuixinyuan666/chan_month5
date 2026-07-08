//! 包含合并 + 三元素分型统一内核（K线合并 / 1段K线合并 / N段K线合并共用，全工程唯一实现）。
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

    /// 包含吸收（一字线特殊口径与旧实现一致）
    fn absorb(&mut self, u: &MergeUnit) {
        if self.dir == MergeDir::Up {
            if (u.high - u.low).abs() > 1e-12 || (u.high - self.high).abs() > 1e-12 {
                self.high = self.high.max(u.high);
                self.low = self.low.max(u.low);
            }
        } else if self.dir == MergeDir::Down {
            if (u.high - u.low).abs() > 1e-12 || (u.low - self.low).abs() > 1e-12 {
                self.high = self.high.min(u.high);
                self.low = self.low.min(u.low);
            }
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
        }
    }

    /// 组内快照（uid 连续递增 → 组内序号 = uid - first_uid）
    fn snapshot(&self, uid: i64) -> ProbeState {
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
        }
    }
}

/// 包含合并引擎：增量喂入单元，产出合并组与三元素分型事件
#[derive(Debug, Clone, Default)]
pub struct CombineEngine {
    groups: Vec<MergedGroup>,
}

impl CombineEngine {
    pub fn new() -> Self {
        Self { groups: Vec::new() }
    }

    pub fn groups(&self) -> &[MergedGroup] {
        &self.groups
    }

    pub fn is_empty(&self) -> bool {
        self.groups.is_empty()
    }

    /// 永久喂入单元；三组成立时返回中组分型事件（当步冻结，后续吸收不破坏）
    pub fn feed(&mut self, u: &MergeUnit) -> Option<FxEvent> {
        if self.groups.is_empty() {
            self.groups.push(MergedGroup::new_first(u, MergeDir::Up));
            return None;
        }
        let last = self.groups.len() - 1;
        let dir =
            test_combine_range(self.groups[last].high, self.groups[last].low, u.high, u.low);
        if dir == MergeDir::Combine {
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
            };
        }
        let n = self.groups.len();
        let last = &self.groups[n - 1];
        let dir = test_combine_range(last.high, last.low, u.high, u.low);
        if dir == MergeDir::Combine {
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
        Some(g.snapshot(uid))
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
        eng.feed(&unit(1, 9.5, 9.2)); // 被包含
        assert_eq!(eng.groups().len(), 1);
        assert_eq!(eng.groups()[0].unit_count, 2);
        let snap = eng.snapshot_for(1).unwrap();
        assert_eq!(snap.inner_seq, 1);
        assert_eq!(snap.group_count, 2);
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
}
