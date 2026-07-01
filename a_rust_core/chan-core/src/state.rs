use std::collections::HashSet;

use crate::bi::{Bi, BiList};
use crate::config::ChanConfig;
use crate::enums::{BiDir, BspType};
use crate::kline::{KlineList, MergedKlc};
use crate::seg::{Seg, SegList};
use crate::zs::ZsList;

#[derive(Debug, Clone)]
pub struct BspPoint {
    pub level: String,
    pub x: i32,
    pub is_buy: bool,
    pub label: String,
}

pub struct BspList {
    pub points: Vec<BspPoint>,
    seen: HashSet<String>,
    config: ChanConfig,
}

impl BspList {
    pub fn new(config: ChanConfig) -> Self {
        Self {
            points: Vec::new(),
            seen: HashSet::new(),
            config,
        }
    }

    pub fn cal_bi_level(&mut self, bis: &[Bi], klcs: &[MergedKlc], segs: &[Seg]) {
        self.points.retain(|p| p.level != "bi");
        self.seen.retain(|k| !k.starts_with("bi|"));
        for seg in segs {
            if !self.config.bsp_types.contains(&BspType::T1) && !self.config.bsp_types.contains(&BspType::T1P) {
                continue;
            }
            let end_bi = &bis[seg.end_bi as usize];
            let is_buy = end_bi.dir == BiDir::Down;
            let x = end_bi.end_klu_idx(klcs);
            let label = if self.config.bsp_types.contains(&BspType::T1) {
                "1"
            } else {
                "1p"
            };
            self.add("bi", x, is_buy, label);
        }
    }

    pub fn cal_seg_level(&mut self, bis: &[Bi], klcs: &[MergedKlc], segs: &[Seg]) {
        self.points.retain(|p| p.level != "seg");
        self.seen.retain(|k| !k.starts_with("seg|"));
        for seg in segs {
            if seg.end_bi + 2 >= bis.len() as i32 {
                continue;
            }
            let bsp2 = &bis[(seg.end_bi + 2) as usize];
            let is_buy = bsp2.dir == BiDir::Down;
            let x = bsp2.end_klu_idx(klcs);
            if self.config.bsp_types.contains(&BspType::T2) {
                let retrace = bsp2.amp(klcs) / bis[(seg.end_bi + 1) as usize].amp(klcs).max(1e-7);
                if retrace <= self.config.max_bs2_rate {
                    self.add("seg", x, is_buy, "2");
                }
            }
        }
    }

    fn add(&mut self, level: &str, x: i32, is_buy: bool, label: &str) {
        let key = format!("{}|{}|{}", level, x, if is_buy { 1 } else { 0 });
        if self.seen.contains(&key) {
            return;
        }
        self.seen.insert(key);
        self.points.push(BspPoint {
            level: level.to_string(),
            x,
            is_buy,
            label: label.to_string(),
        });
    }

    pub fn bsp_keys(&self) -> Vec<String> {
        let mut keys: Vec<String> = self
            .points
            .iter()
            .map(|p| format!("{}|{}|{}", p.level, p.x, if p.is_buy { 1 } else { 0 }))
            .collect();
        keys.sort();
        keys.dedup();
        keys
    }
}

pub struct ChanState {
    pub config: ChanConfig,
    pub kline: KlineList,
    pub bi_list: BiList,
    pub seg_list: SegList,
    pub segseg_list: SegList,
    pub zs_list: ZsList,
    pub segzs_list: ZsList,
    pub bs_point_lst: BspList,
    pub seg_bs_point_lst: BspList,
    pub last_sure_seg_start_bi_idx: i32,
    pub last_sure_segseg_start_bi_idx: i32,
    pub step_count: i32,
}

impl ChanState {
    pub fn new(config: ChanConfig) -> Self {
        let left_peak = config.seg_left_peak;
        Self {
            bi_list: BiList::new(config.clone()),
            seg_list: SegList::new(left_peak),
            segseg_list: SegList::new(left_peak),
            zs_list: ZsList::new(config.one_bi_zs),
            segzs_list: ZsList::new(config.one_bi_zs),
            bs_point_lst: BspList::new(config.clone()),
            seg_bs_point_lst: BspList::new(config.clone()),
            config,
            kline: KlineList::new(),
            last_sure_seg_start_bi_idx: -1,
            last_sure_segseg_start_bi_idx: -1,
            step_count: 0,
        }
    }

    pub fn feed_bar(&mut self, idx: i32, high: f64, low: f64, close: f64) {
        let n = self.kline.klcs.len();
        let new_klc = self.kline.add_single_klu(idx, high, low, close);
        let step_calc = true;
        let mut changed = false;
        if n == 0 {
            self.step_count += 1;
            return;
        }
        if new_klc && self.kline.klcs.len() >= 2 {
            let klc_idx = (self.kline.klcs.len() - 2) as i32;
            let last_idx = (self.kline.klcs.len() - 1) as i32;
            changed = self.bi_list.update_bi(
                &self.kline.klcs,
                klc_idx,
                last_idx,
                step_calc,
            );
            if changed && step_calc {
                self.cal_seg_and_zs();
            }
        } else if step_calc && self.kline.klcs.len() >= 1 {
            let last_idx = (self.kline.klcs.len() - 1) as i32;
            if self
                .bi_list
                .try_add_virtual_bi(&self.kline.klcs, last_idx, true)
            {
                self.cal_seg_and_zs();
            }
        }
        self.step_count += 1;
    }

    fn cal_seg_and_zs(&mut self) {
        let klcs = self.kline.klcs.clone();
        {
            let bis = &self.bi_list.bi_list;
            self.seg_list.update(bis, &klcs);
            self.zs_list.cal_bi_zs(bis, &klcs, &self.seg_list.segs);
        }
        self.last_sure_seg_start_bi_idx =
            crate::seg::cal_seg_assign(&mut self.bi_list.bi_list, &self.seg_list);
        let seg_as_bi = self.wrap_seg_as_bi();
        self.segseg_list.update(&seg_as_bi, &klcs);
        self.segzs_list
            .cal_bi_zs(&seg_as_bi, &klcs, &self.segseg_list.segs);
        self.last_sure_segseg_start_bi_idx = -1;
        let bis = self.bi_list.bi_list.clone();
        let segs = self.seg_list.segs.clone();
        self.bs_point_lst.cal_bi_level(&bis, &klcs, &segs);
        self.seg_bs_point_lst.cal_seg_level(&bis, &klcs, &segs);
    }

    fn wrap_seg_as_bi(&self) -> Vec<Bi> {
        self.seg_list
            .segs
            .iter()
            .enumerate()
            .map(|(i, s)| Bi {
                idx: i as i32,
                begin_klc: s.start_bi,
                end_klc: s.end_bi,
                dir: s.dir,
                is_sure: s.is_sure,
                sure_ends: Vec::new(),
            })
            .collect()
    }

    pub fn structure_signature(&self) -> serde_json::Value {
        let klcs = &self.kline.klcs;
        let bi_tail = self.bi_list.line_tail_sig(klcs, 5);
        let seg_tail = self.seg_list.line_tail_sig(&self.bi_list.bi_list, klcs, 3);
        let segseg_tail = self.segseg_list.line_tail_sig(&self.wrap_seg_as_bi(), klcs, 3);
        let mut keys = self.bs_point_lst.bsp_keys();
        keys.extend(self.seg_bs_point_lst.bsp_keys());
        keys.sort();
        keys.dedup();
        serde_json::json!({
            "klc_count": self.kline.klcs.len(),
            "fx_tail": self.kline.fx_tail(3),
            "bi_tail": bi_tail,
            "seg_tail": seg_tail,
            "segseg_tail": segseg_tail,
            "last_sure_seg_start_bi_idx": self.last_sure_seg_start_bi_idx,
            "last_sure_segseg_start_bi_idx": self.last_sure_segseg_start_bi_idx,
            "bsp_keys": keys,
        })
    }

    pub fn reset(&mut self) {
        *self = Self::new(self.config.clone());
    }
}
