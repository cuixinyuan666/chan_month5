use crate::config::ChanConfig;
use crate::enums::{BiDir, FxType, KlineDir};
use crate::kline::{end_is_peak, bi_dir_from_fx, KlineList, MergedKlc};

#[derive(Debug, Clone)]
pub struct Bi {
    pub idx: i32,
    pub begin_klc: i32,
    pub end_klc: i32,
    pub dir: BiDir,
    pub is_sure: bool,
    pub sure_ends: Vec<i32>,
}

impl Bi {
    pub fn begin_val(&self, klcs: &[MergedKlc]) -> f64 {
        let k = &klcs[self.begin_klc as usize];
        if self.dir == BiDir::Up {
            k.low
        } else {
            k.high
        }
    }

    pub fn end_val(&self, klcs: &[MergedKlc]) -> f64 {
        let k = &klcs[self.end_klc as usize];
        if self.dir == BiDir::Up {
            k.high
        } else {
            k.low
        }
    }

    pub fn end_klu_idx(&self, klcs: &[MergedKlc]) -> i32 {
        klcs[self.end_klc as usize].units.last().map(|u| u.idx).unwrap_or(0)
    }

    pub fn begin_klu_idx(&self, klcs: &[MergedKlc]) -> i32 {
        klcs[self.begin_klc as usize]
            .units
            .first()
            .map(|u| u.idx)
            .unwrap_or(0)
    }

    pub fn _high(&self, klcs: &[MergedKlc]) -> f64 {
        let mut h = f64::NEG_INFINITY;
        for i in self.begin_klc..=self.end_klc {
            h = h.max(klcs[i as usize].high);
        }
        h
    }

    pub fn _low(&self, klcs: &[MergedKlc]) -> f64 {
        let mut l = f64::INFINITY;
        for i in self.begin_klc..=self.end_klc {
            l = l.min(klcs[i as usize].low);
        }
        l
    }

    pub fn amp(&self, klcs: &[MergedKlc]) -> f64 {
        (self.end_val(klcs) - self.begin_val(klcs)).abs()
    }

    pub fn cal_macd_peak(&self, klcs: &[MergedKlc]) -> f64 {
        let mut peak = 1e-7;
        for i in self.begin_klc..=self.end_klc {
            for u in &klcs[i as usize].units {
                let m = u.macd.abs();
                if m > peak {
                    if self.dir == BiDir::Down && u.macd < 0.0 {
                        peak = m;
                    } else if self.dir == BiDir::Up && u.macd > 0.0 {
                        peak = m;
                    }
                }
            }
        }
        peak
    }
}

pub struct BiList {
    pub bi_list: Vec<Bi>,
    pub last_end: Option<i32>,
    pub free_klc: Vec<i32>,
    pub config: ChanConfig,
}

impl BiList {
    pub fn new(config: ChanConfig) -> Self {
        Self {
            bi_list: Vec::new(),
            last_end: None,
            free_klc: Vec::new(),
            config,
        }
    }

    pub fn update_bi(&mut self, klcs: &[MergedKlc], klc_idx: i32, last_klc_idx: i32, step: bool) -> bool {
        let f1 = self.update_bi_sure(klcs, klc_idx);
        if step {
            let f2 = self.try_add_virtual_bi(klcs, last_klc_idx, false);
            f1 || f2
        } else {
            f1
        }
    }

    fn get_last_klu_of_last_bi(&self, klcs: &[MergedKlc]) -> Option<i32> {
        self.bi_list.last().map(|b| b.end_klu_idx(klcs))
    }

    fn delete_virtual_bi(&mut self, klcs: &[MergedKlc]) {
        if let Some(last) = self.bi_list.last() {
            if !last.is_sure {
                let sure_ends = last.sure_ends.clone();
                if !sure_ends.is_empty() {
                    let mut bi = self.bi_list.pop().unwrap();
                    bi.end_klc = sure_ends[0];
                    bi.is_sure = true;
                    self.bi_list.push(bi);
                    self.last_end = Some(self.bi_list.last().unwrap().end_klc);
                    for se in sure_ends.into_iter().skip(1) {
                        let le = self.last_end.unwrap();
                        self.add_new_bi(klcs, le, se, true);
                        self.last_end = Some(se);
                    }
                } else {
                    self.bi_list.pop();
                }
            }
        }
        self.last_end = self.bi_list.last().map(|b| b.end_klc);
    }

    fn try_create_first_bi(&mut self, klcs: &[MergedKlc], klc_idx: i32) -> bool {
        for &exist in &self.free_klc.clone() {
            let e = &klcs[exist as usize];
            let c = &klcs[klc_idx as usize];
            if e.fx == c.fx {
                continue;
            }
            if self.can_make_bi(klcs, klc_idx, exist, false) {
                self.add_new_bi(klcs, exist, klc_idx, true);
                self.last_end = Some(klc_idx);
                return true;
            }
        }
        self.free_klc.push(klc_idx);
        self.last_end = Some(klc_idx);
        false
    }

    fn update_bi_sure(&mut self, klcs: &[MergedKlc], klc_idx: i32) -> bool {
        let tmp_end = self.get_last_klu_of_last_bi(klcs);
        self.delete_virtual_bi(klcs);
        let klc = &klcs[klc_idx as usize];
        if klc.fx == FxType::Unknown {
            return tmp_end != self.get_last_klu_of_last_bi(klcs);
        }
        if self.last_end.is_none() || self.bi_list.is_empty() {
            return self.try_create_first_bi(klcs, klc_idx);
        }
        let last_end = self.last_end.unwrap();
        let last_fx = klcs[last_end as usize].fx;
        if klc.fx == last_fx {
            return self.try_update_end(klcs, klc_idx, false);
        }
        if self.can_make_bi(klcs, klc_idx, last_end, false) {
            self.add_new_bi(klcs, last_end, klc_idx, true);
            self.last_end = Some(klc_idx);
            return true;
        }
        if self.update_peak(klcs, klc_idx, false) {
            return true;
        }
        tmp_end != self.get_last_klu_of_last_bi(klcs)
    }

    pub fn try_add_virtual_bi(&mut self, klcs: &[MergedKlc], last_klc_idx: i32, need_del_end: bool) -> bool {
        if need_del_end {
            self.delete_virtual_bi(klcs);
        }
        if self.bi_list.is_empty() {
            return false;
        }
        let last_idx = self.bi_list.len() - 1;
        let last = &self.bi_list[last_idx];
        if last_klc_idx == last.end_klc {
            return false;
        }
        let last_klc = &klcs[last.end_klc as usize];
        let klc = &klcs[last_klc_idx as usize];
        if (last.dir == BiDir::Up && klc.high >= last_klc.high)
            || (last.dir == BiDir::Down && klc.low <= last_klc.low)
        {
            self.bi_list[last_idx].end_klc = last_klc_idx;
            return true;
        }
        let last_end_klc = last.end_klc;
        let mut tmp = last_klc_idx;
        while tmp > last_end_klc {
            if self.can_make_bi(klcs, tmp, last_end_klc, true) {
                let le = self.last_end.unwrap();
                self.add_new_bi(klcs, le, tmp, false);
                return true;
            }
            if self.update_peak(klcs, tmp, true) {
                return true;
            }
            tmp -= 1;
        }
        false
    }

    fn add_new_bi(&mut self, klcs: &[MergedKlc], pre: i32, cur: i32, is_sure: bool) {
        let pre_fx = klcs[pre as usize].fx;
        let dir = bi_dir_from_fx(pre_fx);
        let idx = self.bi_list.len() as i32;
        self.bi_list.push(Bi {
            idx,
            begin_klc: pre,
            end_klc: cur,
            dir,
            is_sure,
            sure_ends: Vec::new(),
        });
        self.last_end = Some(cur);
        let _ = klcs;
    }

    fn satisfy_bi_span(&self, klcs: &[MergedKlc], cur: i32, last_end: i32) -> bool {
        let mut span = cur - last_end;
        if !self.config.gap_as_kl {
            if self.config.bi_strict {
                return span >= 4;
            }
            return span >= 3;
        }
        if span >= 4 {
            return true;
        }
        let mut tmp = last_end;
        while tmp < cur {
            if klcs[tmp as usize].has_gap_with_next(&klcs[(tmp + 1) as usize]) {
                span += 1;
            }
            tmp += 1;
        }
        if self.config.bi_strict {
            span >= 4
        } else {
            span >= 3
        }
    }

    fn can_make_bi(&self, klcs: &[MergedKlc], cur: i32, last_end: i32, for_virtual: bool) -> bool {
        if !self.satisfy_bi_span(klcs, cur, last_end) {
            return false;
        }
        let le = &klcs[last_end as usize];
        let cu = &klcs[cur as usize];
        if !le.check_fx_valid(cu, self.config.bi_fx_check_strict, for_virtual) {
            return false;
        }
        if self.config.bi_end_is_peak && !end_is_peak(le, cu, klcs) {
            return false;
        }
        true
    }

    fn try_update_end(&mut self, klcs: &[MergedKlc], klc_idx: i32, for_virtual: bool) -> bool {
        if self.bi_list.is_empty() {
            return false;
        }
        let idx = self.bi_list.len() - 1;
        let last = &self.bi_list[idx];
        let klc = &klcs[klc_idx as usize];
        let up_ok = last.dir == BiDir::Up
            && ((for_virtual && klc.dir == KlineDir::Up) || (!for_virtual && klc.fx == FxType::Top))
            && klc.high >= last.end_val(klcs);
        let down_ok = last.dir == BiDir::Down
            && ((for_virtual && klc.dir == KlineDir::Down) || (!for_virtual && klc.fx == FxType::Bottom))
            && klc.low <= last.end_val(klcs);
        if up_ok || down_ok {
            if for_virtual {
                let prev_end = self.bi_list[idx].end_klc;
                self.bi_list[idx].sure_ends.push(prev_end);
            }
            self.bi_list[idx].end_klc = klc_idx;
            self.last_end = Some(klc_idx);
            return true;
        }
        false
    }

    fn can_update_peak(&self, klcs: &[MergedKlc], klc_idx: i32) -> bool {
        if self.config.bi_allow_sub_peak || self.bi_list.len() < 2 {
            return false;
        }
        let last = &self.bi_list[self.bi_list.len() - 1];
        let prev = &self.bi_list[self.bi_list.len() - 2];
        let klc = &klcs[klc_idx as usize];
        if last.dir == BiDir::Down && klc.high < last.begin_val(klcs) {
            return false;
        }
        if last.dir == BiDir::Up && klc.low > last.begin_val(klcs) {
            return false;
        }
        if !end_is_peak(&klcs[prev.begin_klc as usize], klc, klcs) {
            return false;
        }
        if last.dir == BiDir::Down && last.end_val(klcs) < prev.begin_val(klcs) {
            return false;
        }
        if last.dir == BiDir::Up && last.end_val(klcs) > prev.begin_val(klcs) {
            return false;
        }
        true
    }

    fn update_peak(&mut self, klcs: &[MergedKlc], klc_idx: i32, for_virtual: bool) -> bool {
        if !self.can_update_peak(klcs, klc_idx) {
            return false;
        }
        let tmp = self.bi_list.pop().unwrap();
        if !self.try_update_end(klcs, klc_idx, for_virtual) {
            self.bi_list.push(tmp);
            return false;
        }
        if for_virtual {
            let idx = self.bi_list.len() - 1;
            self.bi_list[idx].sure_ends.push(tmp.end_klc);
        }
        true
    }

    pub fn line_tail_sig(&self, klcs: &[MergedKlc], tail: usize) -> Vec<(i32, i32, bool, f64, f64, String)> {
        let t = tail.max(1);
        let start = self.bi_list.len().saturating_sub(t);
        self.bi_list[start..]
            .iter()
            .map(|b| {
                (
                    b.begin_klu_idx(klcs),
                    b.end_klu_idx(klcs),
                    b.is_sure,
                    b.begin_val(klcs),
                    b.end_val(klcs),
                    format!("{:?}", b.dir),
                )
            })
            .collect()
    }
}
