use crate::bi::Bi;
use crate::kline::MergedKlc;
use crate::seg::Seg;

#[derive(Debug, Clone)]
pub struct Zs {
    pub begin_bi: i32,
    pub end_bi: i32,
    pub is_sure: bool,
    pub low: f64,
    pub high: f64,
}

pub struct ZsList {
    pub zs_lst: Vec<Zs>,
    pub one_bi_zs: bool,
    pub last_sure_pos: i32,
    pub last_seg_idx: i32,
    free_item: Vec<i32>,
}

impl ZsList {
    pub fn new(one_bi_zs: bool) -> Self {
        Self {
            zs_lst: Vec::new(),
            one_bi_zs,
            last_sure_pos: -1,
            last_seg_idx: 0,
            free_item: Vec::new(),
        }
    }

    pub fn cal_bi_zs(&mut self, bis: &[Bi], klcs: &[MergedKlc], segs: &[Seg]) {
        while self
            .zs_lst
            .last()
            .map(|z| z.begin_bi >= self.last_sure_pos)
            .unwrap_or(false)
        {
            self.zs_lst.pop();
        }
        for seg in segs.iter().skip(self.last_seg_idx as usize) {
            if seg.start_bi < self.last_sure_pos {
                continue;
            }
            self.free_item.clear();
            let mut deal = 0;
            for bi in bis.iter().filter(|b| b.idx >= seg.start_bi && b.idx <= seg.end_bi) {
                if bi.dir == seg.dir {
                    continue;
                }
                if deal < 1 {
                    self.add_to_free(bi.idx, seg.is_sure, bis, klcs);
                    deal += 1;
                } else {
                    self.push_bi(bi.idx, seg.is_sure, bis, klcs);
                }
            }
        }
        if let Some(last_seg) = segs.last() {
            self.free_item.clear();
            let opp = match last_seg.dir {
                crate::enums::BiDir::Up => crate::enums::BiDir::Down,
                crate::enums::BiDir::Down => crate::enums::BiDir::Up,
            };
            for bi in bis.iter().filter(|b| b.idx > last_seg.end_bi) {
                if bi.dir == opp {
                    continue;
                }
                self.push_bi(bi.idx, false, bis, klcs);
            }
        }
        self.update_last_pos(segs);
    }

    fn add_to_free(&mut self, bi_idx: i32, is_sure: bool, bis: &[Bi], klcs: &[MergedKlc]) {
        if self.free_item.last() == Some(&bi_idx) {
            self.free_item.pop();
        }
        self.free_item.push(bi_idx);
        if let Some(zs) = self.try_construct(&self.free_item, is_sure, bis, klcs) {
            if zs.begin_bi > 0 {
                self.zs_lst.push(zs);
                self.free_item.clear();
            }
        }
    }

    fn push_bi(&mut self, bi_idx: i32, is_sure: bool, bis: &[Bi], klcs: &[MergedKlc]) {
        self.add_to_free(bi_idx, is_sure, bis, klcs);
    }

    fn try_construct(&self, lst: &[i32], is_sure: bool, bis: &[Bi], klcs: &[MergedKlc]) -> Option<Zs> {
        if !self.one_bi_zs && lst.len() < 2 {
            return None;
        }
        let use_lst = if lst.len() >= 2 {
            &lst[lst.len() - 2..]
        } else {
            lst
        };
        let min_high = use_lst
            .iter()
            .map(|&i| bis[i as usize]._high(klcs))
            .fold(f64::INFINITY, f64::min);
        let max_low = use_lst
            .iter()
            .map(|&i| bis[i as usize]._low(klcs))
            .fold(f64::NEG_INFINITY, f64::max);
        if min_high > max_low {
            Some(Zs {
                begin_bi: use_lst[0],
                end_bi: *use_lst.last().unwrap(),
                is_sure,
                low: max_low,
                high: min_high,
            })
        } else {
            None
        }
    }

    fn update_last_pos(&mut self, segs: &[Seg]) {
        self.last_sure_pos = -1;
        self.last_seg_idx = 0;
        for seg in segs.iter().rev() {
            if seg.is_sure {
                self.last_sure_pos = seg.start_bi;
                self.last_seg_idx = seg.idx;
                return;
            }
        }
    }
}
