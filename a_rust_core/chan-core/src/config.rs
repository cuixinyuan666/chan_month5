use crate::enums::BspType;

#[derive(Debug, Clone)]
pub struct ChanConfig {
    pub bi_strict: bool,
    pub bi_fx_check_strict: bool,
    pub gap_as_kl: bool,
    pub bi_end_is_peak: bool,
    pub bi_allow_sub_peak: bool,
    pub seg_left_peak: bool,
    pub zs_combine: bool,
    pub one_bi_zs: bool,
    pub divergence_rate: f64,
    pub min_zs_cnt: i32,
    pub bsp1_only_multibi_zs: bool,
    pub max_bs2_rate: f64,
    pub bs1_peak: bool,
    pub bsp_types: Vec<BspType>,
    pub bsp2_follow_1: bool,
    pub bsp3_follow_1: bool,
    pub bsp3_peak: bool,
    pub bsp2s_follow_2: bool,
    pub max_bsp2s_lv: Option<i32>,
    pub strict_bsp3: bool,
    pub bsp3a_max_zs_cnt: i32,
}

impl Default for ChanConfig {
    fn default() -> Self {
        Self {
            bi_strict: true,
            bi_fx_check_strict: true,
            gap_as_kl: false,
            bi_end_is_peak: true,
            bi_allow_sub_peak: true,
            seg_left_peak: true,
            zs_combine: true,
            one_bi_zs: false,
            divergence_rate: f64::INFINITY,
            min_zs_cnt: 1,
            bsp1_only_multibi_zs: true,
            max_bs2_rate: 0.9999,
            bs1_peak: true,
            bsp_types: vec![
                BspType::T1,
                BspType::T1P,
                BspType::T2,
                BspType::T2S,
                BspType::T3A,
                BspType::T3B,
            ],
            bsp2_follow_1: true,
            bsp3_follow_1: true,
            bsp3_peak: false,
            bsp2s_follow_2: false,
            max_bsp2s_lv: None,
            strict_bsp3: false,
            bsp3a_max_zs_cnt: 1,
        }
    }
}
