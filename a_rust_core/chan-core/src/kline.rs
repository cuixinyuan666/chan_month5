use crate::enums::{BiDir, FxType, KlineDir};

#[derive(Debug, Clone)]
pub struct Klu {
    pub idx: i32,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub macd: f64,
}

#[derive(Debug, Clone)]
pub struct MergedKlc {
    pub idx: i32,
    pub high: f64,
    pub low: f64,
    pub dir: KlineDir,
    pub fx: FxType,
    pub units: Vec<Klu>,
}

impl MergedKlc {
    pub fn new_first(klu: Klu) -> Self {
        Self {
            idx: 0,
            high: klu.high,
            low: klu.low,
            dir: KlineDir::Up,
            fx: FxType::Unknown,
            units: vec![klu],
        }
    }

    pub fn test_combine(&self, h: f64, l: f64, exclude_included: bool, allow_top_equal: Option<i32>) -> KlineDir {
        if self.high >= h && self.low <= l {
            return KlineDir::Combine;
        }
        if self.high <= h && self.low >= l {
            if allow_top_equal == Some(1) && (self.high - h).abs() < 1e-12 && self.low > l {
                return KlineDir::Down;
            }
            if allow_top_equal == Some(-1) && (self.low - l).abs() < 1e-12 && self.high < h {
                return KlineDir::Up;
            }
            if exclude_included {
                return KlineDir::Included;
            }
            return KlineDir::Combine;
        }
        if self.high > h && self.low > l {
            return KlineDir::Down;
        }
        if self.high < h && self.low < l {
            return KlineDir::Up;
        }
        KlineDir::Combine
    }

    pub fn try_add(&mut self, klu: Klu) -> KlineDir {
        let dir = self.test_combine(klu.high, klu.low, false, None);
        if dir == KlineDir::Combine {
            let low = klu.low;
            let high = klu.high;
            self.units.push(klu);
            if self.dir == KlineDir::Up {
                if (high - low).abs() > 1e-12 || (high - self.high).abs() > 1e-12 {
                    self.high = self.high.max(high);
                    self.low = self.low.max(low);
                }
            } else if self.dir == KlineDir::Down {
                if (high - low).abs() > 1e-12 || (low - self.low).abs() > 1e-12 {
                    self.high = self.high.min(high);
                    self.low = self.low.min(low);
                }
            }
        }
        dir
    }

    pub fn update_fx(&mut self, pre: &MergedKlc, next: &MergedKlc) {
        if pre.high < self.high && next.high < self.high && pre.low < self.low && next.low < self.low {
            self.fx = FxType::Top;
        } else if pre.high > self.high && next.high > self.high && pre.low > self.low && next.low > self.low {
            self.fx = FxType::Bottom;
        }
    }

    pub fn has_gap_with_next(&self, next: &MergedKlc) -> bool {
        let a_lo = self.units.iter().map(|u| u.low).fold(f64::INFINITY, f64::min);
        let a_hi = self.units.iter().map(|u| u.high).fold(f64::NEG_INFINITY, f64::max);
        let b_lo = next.units.iter().map(|u| u.low).fold(f64::INFINITY, f64::min);
        let b_hi = next.units.iter().map(|u| u.high).fold(f64::NEG_INFINITY, f64::max);
        !(a_lo <= b_hi && b_lo <= a_hi)
    }

    pub fn check_fx_valid(&self, item2: &MergedKlc, strict: bool, for_virtual: bool) -> bool {
        if self.fx == FxType::Top {
            if !for_virtual && item2.fx != FxType::Bottom {
                return false;
            }
            if for_virtual && item2.dir != KlineDir::Down {
                return false;
            }
            let (item2_high, self_low) = if strict {
                (item2.high.max(item2.high), self.low.min(self.low))
            } else {
                (item2.high, self.low)
            };
            let _ = item2_high;
            return self.high > item2.high && item2.low < self_low;
        }
        if self.fx == FxType::Bottom {
            if !for_virtual && item2.fx != FxType::Top {
                return false;
            }
            if for_virtual && item2.dir != KlineDir::Up {
                return false;
            }
            let (item2_low, cur_high) = if strict {
                (item2.low.min(item2.low), self.high.max(self.high))
            } else {
                (item2.low, self.high)
            };
            let _ = item2_low;
            return self.low < item2.low && item2.high > cur_high;
        }
        false
    }
}

pub struct KlineList {
    pub klcs: Vec<MergedKlc>,
    ema_fast: f64,
    ema_slow: f64,
    ema_signal: f64,
    macd_initialized: bool,
}

impl KlineList {
    pub fn new() -> Self {
        Self {
            klcs: Vec::new(),
            ema_fast: 0.0,
            ema_slow: 0.0,
            ema_signal: 0.0,
            macd_initialized: false,
        }
    }

    fn update_macd(&mut self, close: f64) -> f64 {
        let alpha_fast = 2.0 / (12.0 + 1.0);
        let alpha_slow = 2.0 / (26.0 + 1.0);
        let alpha_sig = 2.0 / (9.0 + 1.0);
        if !self.macd_initialized {
            self.ema_fast = close;
            self.ema_slow = close;
            self.ema_signal = 0.0;
            self.macd_initialized = true;
            return 0.0;
        }
        self.ema_fast = alpha_fast * close + (1.0 - alpha_fast) * self.ema_fast;
        self.ema_slow = alpha_slow * close + (1.0 - alpha_slow) * self.ema_slow;
        let dif = self.ema_fast - self.ema_slow;
        self.ema_signal = alpha_sig * dif + (1.0 - alpha_sig) * self.ema_signal;
        dif - self.ema_signal
    }

    pub fn add_single_klu(&mut self, idx: i32, high: f64, low: f64, close: f64) -> bool {
        let macd = self.update_macd(close);
        let klu = Klu {
            idx,
            high,
            low,
            close,
            macd,
        };
        if self.klcs.is_empty() {
            self.klcs.push(MergedKlc::new_first(klu));
            return false;
        }
        let last_idx = self.klcs.len() - 1;
        let dir = self.klcs[last_idx].try_add(klu);
        if dir != KlineDir::Combine {
            let new_idx = self.klcs.len() as i32;
            let mut nk = MergedKlc::new_first(Klu {
                idx,
                high,
                low,
                close,
                macd,
            });
            nk.idx = new_idx;
            nk.dir = dir;
            self.klcs.push(nk);
            if self.klcs.len() >= 3 {
                let n = self.klcs.len();
                let pre_h = self.klcs[n - 3].high;
                let pre_l = self.klcs[n - 3].low;
                let cur_h = self.klcs[n - 2].high;
                let cur_l = self.klcs[n - 2].low;
                let nxt_h = self.klcs[n - 1].high;
                let nxt_l = self.klcs[n - 1].low;
                if pre_h < cur_h && nxt_h < cur_h && pre_l < cur_l && nxt_l < cur_l {
                    self.klcs[n - 2].fx = FxType::Top;
                } else if pre_h > cur_h && nxt_h > cur_h && pre_l > cur_l && nxt_l > cur_l {
                    self.klcs[n - 2].fx = FxType::Bottom;
                }
            }
            return true;
        }
        false
    }

    pub fn fx_tail(&self, tail: usize) -> Vec<(i32, String, f64, f64)> {
        let t = tail.max(1);
        let start = self.klcs.len().saturating_sub(t);
        self.klcs[start..]
            .iter()
            .map(|k| {
                (
                    k.idx,
                    match k.fx {
                        FxType::Top => "TOP".to_string(),
                        FxType::Bottom => "BOTTOM".to_string(),
                        FxType::Unknown => "UNKNOWN".to_string(),
                    },
                    k.high,
                    k.low,
                )
            })
            .collect()
    }
}

pub fn end_is_peak(last_end: &MergedKlc, cur_end: &MergedKlc, klcs: &[MergedKlc]) -> bool {
    if last_end.fx == FxType::Bottom {
        let cmp = cur_end.high;
        let mut i = last_end.idx as usize + 1;
        while i < klcs.len() {
            let klc = &klcs[i];
            if klc.idx >= cur_end.idx {
                return true;
            }
            if klc.high > cmp {
                return false;
            }
            i += 1;
        }
        return true;
    }
    if last_end.fx == FxType::Top {
        let cmp = cur_end.low;
        let mut i = last_end.idx as usize + 1;
        while i < klcs.len() {
            let klc = &klcs[i];
            if klc.idx >= cur_end.idx {
                return true;
            }
            if klc.low < cmp {
                return false;
            }
            i += 1;
        }
        return true;
    }
    true
}

pub fn bi_dir_from_fx(fx: FxType) -> BiDir {
    match fx {
        FxType::Bottom => BiDir::Up,
        FxType::Top => BiDir::Down,
        FxType::Unknown => BiDir::Up,
    }
}
