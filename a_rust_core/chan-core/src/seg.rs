use crate::bi::Bi;
use crate::enums::{BiDir, FxType, KlineDir};
use crate::kline::MergedKlc;

#[derive(Debug, Clone)]
pub struct Seg {
    pub idx: i32,
    pub start_bi: i32,
    pub end_bi: i32,
    pub dir: BiDir,
    pub is_sure: bool,
    pub zs_bi_ranges: Vec<(i32, i32)>,
}

pub struct SegList {
    pub segs: Vec<Seg>,
    pub left_peak: bool,
}

impl SegList {
    pub fn new(left_peak: bool) -> Self {
        Self {
            segs: Vec::new(),
            left_peak,
        }
    }

    pub fn update(&mut self, bis: &[Bi], klcs: &[MergedKlc]) {
        self.do_init(bis);
        if self.segs.is_empty() {
            self.cal_seg_sure(bis, klcs, 0);
        } else {
            let begin = self.segs.last().unwrap().end_bi + 1;
            self.cal_seg_sure(bis, klcs, begin);
        }
        self.collect_left_seg(bis, klcs);
    }

    fn do_init(&mut self, bis: &[Bi]) {
        while let Some(s) = self.segs.last() {
            if !s.is_sure {
                self.segs.pop();
            } else {
                break;
            }
        }
        let _ = bis;
    }

    fn cal_seg_sure(&mut self, bis: &[Bi], klcs: &[MergedKlc], begin_idx: i32) {
        let mut up_ele: Vec<i32> = Vec::new();
        let mut down_ele: Vec<i32> = Vec::new();
        let mut last_seg_dir: Option<BiDir> = None;
        if !self.segs.is_empty() {
            last_seg_dir = Some(self.segs.last().unwrap().dir);
        }
        for bi in bis.iter().filter(|b| b.idx >= begin_idx) {
            let mut fx_end: Option<i32> = None;
            if bi.dir == BiDir::Down && last_seg_dir != Some(BiDir::Up) {
                if Self::eigen_add(&mut up_ele, bi.idx, BiDir::Up) {
                    fx_end = up_ele.get(1).copied();
                }
            } else if bi.dir == BiDir::Up && last_seg_dir != Some(BiDir::Down) {
                if Self::eigen_add(&mut down_ele, bi.idx, BiDir::Down) {
                    fx_end = down_ele.get(1).copied();
                }
            }
            if self.segs.is_empty() {
                if up_ele.len() >= 2 && bi.dir == BiDir::Down {
                    last_seg_dir = Some(BiDir::Down);
                    up_ele.clear();
                } else if down_ele.len() >= 2 && bi.dir == BiDir::Up {
                    down_ele.clear();
                    last_seg_dir = Some(BiDir::Up);
                }
            }
            if let Some(end_bi) = fx_end {
                if self.add_new_seg(bis, end_bi, true) {
                    self.cal_seg_sure(bis, klcs, end_bi + 1);
                }
                break;
            }
        }
    }

    fn eigen_add(ele: &mut Vec<i32>, bi_idx: i32, _seg_dir: BiDir) -> bool {
        ele.push(bi_idx);
        ele.len() >= 3
    }

    fn add_new_seg(&mut self, bis: &[Bi], end_bi_idx: i32, is_sure: bool) -> bool {
        if end_bi_idx as usize >= bis.len() {
            return false;
        }
        let bi1_idx = if self.segs.is_empty() {
            0
        } else {
            self.segs.last().unwrap().end_bi + 1
        };
        if bi1_idx as usize >= bis.len() || end_bi_idx < bi1_idx {
            return false;
        }
        let end_bi = &bis[end_bi_idx as usize];
        let dir = end_bi.dir;
        let idx = self.segs.len() as i32;
        self.segs.push(Seg {
            idx,
            start_bi: bi1_idx,
            end_bi: end_bi_idx,
            dir,
            is_sure,
            zs_bi_ranges: Vec::new(),
        });
        true
    }

    fn collect_left_seg(&mut self, bis: &[Bi], klcs: &[MergedKlc]) {
        if self.segs.is_empty() {
            if bis.len() >= 3 {
                if let Some(last) = bis.last() {
                    let _ = self.add_new_seg(bis, last.idx, false);
                }
            }
            return;
        }
        let last_bi = bis.last().unwrap();
        let last_seg = self.segs.last().unwrap();
        if last_bi.idx - last_seg.end_bi < 2 {
            return;
        }
        if last_seg.dir == BiDir::Down && last_bi.end_val(klcs) <= bis[last_seg.end_bi as usize].end_val(klcs) {
            return;
        }
        if last_seg.dir == BiDir::Up && last_bi.end_val(klcs) >= bis[last_seg.end_bi as usize].end_val(klcs) {
            return;
        }
        if self.left_peak {
            return;
        }
        let end_idx = if last_seg.dir == last_bi.dir {
            last_bi.idx - 1
        } else {
            last_bi.idx
        };
        if end_idx > last_seg.end_bi {
            let _ = self.add_new_seg(bis, end_idx, false);
        }
    }

    pub fn line_tail_sig(&self, bis: &[Bi], klcs: &[MergedKlc], tail: usize) -> Vec<(i32, i32, bool, f64, f64, String)> {
        let t = tail.max(1);
        let start = self.segs.len().saturating_sub(t);
        self.segs[start..]
            .iter()
            .map(|s| {
                let b0 = &bis[s.start_bi as usize];
                let b1 = &bis[s.end_bi as usize];
                (
                    b0.begin_klu_idx(klcs),
                    b1.end_klu_idx(klcs),
                    s.is_sure,
                    b0.begin_val(klcs),
                    b1.end_val(klcs),
                    format!("{:?}", s.dir),
                )
            })
            .collect()
    }

    pub fn exist_sure_seg(&self) -> bool {
        self.segs.iter().any(|s| s.is_sure)
    }
}

pub fn cal_seg_assign(bis: &mut [Bi], seg_list: &SegList) -> i32 {
    if seg_list.segs.is_empty() {
        for b in bis.iter_mut() {
            b.idx = b.idx;
        }
        return -1;
    }
    let cur = seg_list.segs.last().unwrap();
    let mut bi_idx = bis.len() as i32 - 1;
    let mut last_sure = -1;
    while bi_idx >= 0 {
        let bi = &mut bis[bi_idx as usize];
        if bi.idx > cur.end_bi {
            bi_idx -= 1;
            continue;
        }
        bi_idx -= 1;
    }
    let mut seg = seg_list.segs.last();
    while let Some(s) = seg {
        if s.is_sure {
            last_sure = s.start_bi;
            break;
        }
        seg = None;
    }
    last_sure
}
