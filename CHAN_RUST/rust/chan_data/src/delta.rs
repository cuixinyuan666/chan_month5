//! PipelineDelta：步进增量出口（2B-2）。
//!
//! 唯一目标：证明 Full Snapshot 可被 Delta 无损重建。
//! Hybrid：历史 `bar_features` 只追加当步一行；其余字段当步全量替换
//! （中枢/BS/active/合并框会改旧框，不能只 append）。
//!
//! 不改 append 判定、不删 Full Snapshot、不接 Flutter / 二进制协议。

use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::buy1::{Buy1Frame, Sell1Frame};
use crate::buy2::{Buy2Frame, Sell2Frame};
use crate::buy_n::{BuyNFrame, SellNFrame};
use crate::combine::{
    build_kline_combine_bundle_from_state, K0ConfirmSignal, KlineCombineBundle, KlineCombineFrame,
};
use crate::feature::{BarCrosshairFeature, K0Line, K1Bar};
use crate::kline::KlineBar;
use crate::pipeline::{LevelBundleOut, PipelineState};
use crate::seg_eigen::K1AnalysisBundle;
use crate::zs::ZSFrame;

/// 除 `bar_features` 外的 Full Snapshot 字段（当步全量）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PipelineDeltaStructure {
    pub frames: Vec<KlineCombineFrame>,
    pub k0_confirms: Vec<K0ConfirmSignal>,
    pub k0_lines: Vec<K0Line>,
    pub k1_analysis: K1AnalysisBundle,
    pub k1_bars: Vec<K1Bar>,
    pub k1_combine_frames: Vec<KlineCombineFrame>,
    pub default_k0_policy: String,
    pub default_segment_policies: Vec<String>,
    pub level_segments: Vec<Vec<K0Line>>,
    pub level_virtual_units: Vec<Vec<K1Bar>>,
    pub levels: Vec<LevelBundleOut>,
    pub zs_k0_frames: Vec<ZSFrame>,
    pub buy1_k0_frames: Vec<Buy1Frame>,
    pub sell1_k0_frames: Vec<Sell1Frame>,
    pub buy2_k0_frames: Vec<Buy2Frame>,
    pub sell2_k0_frames: Vec<Sell2Frame>,
    pub buy_n_k0_frames: Vec<BuyNFrame>,
    pub sell_n_k0_frames: Vec<SellNFrame>,
    #[serde(default)]
    pub bs_verdict_k0_frames: Vec<crate::bs_eval::BsVerdictFrame>,
}

/// 当步增量。JSON 扁平：`idx` + `bar_feature` + 结构字段（无历史 bar_features）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PipelineDelta {
    /// 当步 K0 索引（= 已喂入根数-1；重建时必须等于当前 `bar_features.len()`）
    pub idx: i32,
    /// 当步十字特征（历史行不重复发送）
    pub bar_feature: BarCrosshairFeature,
    #[serde(flatten)]
    pub structure: PipelineDeltaStructure,
}

impl PipelineDelta {
    /// 从当步 Full Snapshot 抽出 Delta（只带走末根 feature）。
    pub fn from_full(full: &KlineCombineBundle) -> Self {
        let feat = full
            .bar_features
            .last()
            .cloned()
            .expect("from_full: Full Snapshot 不能为空");
        Self {
            idx: feat.idx,
            bar_feature: feat,
            structure: structure_from_full(full),
        }
    }
}

fn structure_from_full(full: &KlineCombineBundle) -> PipelineDeltaStructure {
    PipelineDeltaStructure {
        frames: full.frames.clone(),
        k0_confirms: full.k0_confirms.clone(),
        k0_lines: full.k0_lines.clone(),
        k1_analysis: full.k1_analysis.clone(),
        k1_bars: full.k1_bars.clone(),
        k1_combine_frames: full.k1_combine_frames.clone(),
        default_k0_policy: full.default_k0_policy.clone(),
        default_segment_policies: full.default_segment_policies.clone(),
        level_segments: full.level_segments.clone(),
        level_virtual_units: full.level_virtual_units.clone(),
        levels: full.levels.clone(),
        zs_k0_frames: full.zs_k0_frames.clone(),
        buy1_k0_frames: full.buy1_k0_frames.clone(),
        sell1_k0_frames: full.sell1_k0_frames.clone(),
        buy2_k0_frames: full.buy2_k0_frames.clone(),
        sell2_k0_frames: full.sell2_k0_frames.clone(),
        buy_n_k0_frames: full.buy_n_k0_frames.clone(),
        sell_n_k0_frames: full.sell_n_k0_frames.clone(),
        bs_verdict_k0_frames: full.bs_verdict_k0_frames.clone(),
    }
}

fn apply_structure(acc: &mut KlineCombineBundle, s: PipelineDeltaStructure) {
    acc.frames = s.frames;
    acc.k0_confirms = s.k0_confirms;
    acc.k0_lines = s.k0_lines;
    acc.k1_analysis = s.k1_analysis;
    acc.k1_bars = s.k1_bars;
    acc.k1_combine_frames = s.k1_combine_frames;
    acc.default_k0_policy = s.default_k0_policy;
    acc.default_segment_policies = s.default_segment_policies;
    acc.level_segments = s.level_segments;
    acc.level_virtual_units = s.level_virtual_units;
    acc.levels = s.levels;
    acc.zs_k0_frames = s.zs_k0_frames;
    acc.buy1_k0_frames = s.buy1_k0_frames;
    acc.sell1_k0_frames = s.sell1_k0_frames;
    acc.buy2_k0_frames = s.buy2_k0_frames;
    acc.sell2_k0_frames = s.sell2_k0_frames;
    acc.buy_n_k0_frames = s.buy_n_k0_frames;
    acc.sell_n_k0_frames = s.sell_n_k0_frames;
    acc.bs_verdict_k0_frames = s.bs_verdict_k0_frames;
}

/// 把一步 Delta 打进累加仓。历史 `bar_features` 只追加，禁止回写旧行。
pub fn apply_pipeline_delta(acc: &mut KlineCombineBundle, d: PipelineDelta) {
    let expected = acc.bar_features.len() as i32;
    assert_eq!(
        d.idx, expected,
        "delta.idx 必须等于当前 bar_features.len()（下一根），got {} want {}",
        d.idx, expected
    );
    assert_eq!(d.bar_feature.idx, d.idx, "bar_feature.idx 必须等于 delta.idx");
    Arc::make_mut(&mut acc.bar_features).push(d.bar_feature);
    apply_structure(acc, d.structure);
}

/// 从空仓按序应用 Delta，重建 Full Snapshot。
pub fn reconstruct_bundle_from_deltas<I>(deltas: I) -> KlineCombineBundle
where
    I: IntoIterator<Item = PipelineDelta>,
{
    let mut acc = KlineCombineBundle::empty();
    for d in deltas {
        apply_pipeline_delta(&mut acc, d);
    }
    acc
}

impl PipelineState {
    /// 先 `append`（判定不改），再导出当步 Delta。Full Snapshot 仍走 `from_state`。
    pub fn append_delta(&mut self, bar: KlineBar) -> PipelineDelta {
        self.append(bar);
        let full = build_kline_combine_bundle_from_state(self);
        PipelineDelta::from_full(&full)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::combine::build_kline_combine_bundle_with;
    use crate::pipeline::PipelineOptions;

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

    fn zigzag(n: usize) -> Vec<KlineBar> {
        (0..n)
            .map(|i| {
                let up = (i / 4) % 2 == 0;
                let base = 10.0 + (i % 4) as f64 * 0.5;
                let h = if up { base + 1.0 } else { 16.0 - base };
                bar(i, h, h - 0.8)
            })
            .collect()
    }

    fn json_eq(a: &KlineCombineBundle, b: &KlineCombineBundle, tag: &str) {
        let ja = serde_json::to_value(a).expect("ser a");
        let jb = serde_json::to_value(b).expect("ser b");
        assert_eq!(ja, jb, "{tag}: Delta 重建 != Full Snapshot");
    }

    fn load_002003() -> Option<Vec<KlineBar>> {
        let data_root =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../a_Data");
        if !data_root.join("002003").exists() {
            eprintln!("skip: a_Data/002003 不存在");
            return None;
        }
        let root = crate::resolve_data_root(Some(data_root.to_str().unwrap()));
        Some(
            crate::load_klines(
                &root,
                "002003",
                "2004/07/19 10:47:00",
                "2004/07/20 13:09:00",
                crate::KlinePeriod::M1,
            )
            .expect("load 002003"),
        )
    }

    /// 每步：累加 Delta == 当步 Full Snapshot（含黄金 run_pipeline）
    #[test]
    fn delta_reconstructs_full_each_step_zigzag() {
        let bars = zigzag(80);
        let opt = PipelineOptions::default();
        let mut st = PipelineState::new(opt.clone());
        let mut acc = KlineCombineBundle::empty();
        for (i, b) in bars.iter().enumerate() {
            let d = st.append_delta(b.clone());
            apply_pipeline_delta(&mut acc, d);
            let full = build_kline_combine_bundle_from_state(&mut st);
            json_eq(&acc, &full, &format!("step{i} vs from_state"));
            let golden = build_kline_combine_bundle_with(&bars[..=i], &opt);
            json_eq(&acc, &golden, &format!("step{i} vs golden"));
        }
    }

    /// 空仓一次吃完全部 Delta == 末态 Full
    #[test]
    fn delta_batch_reconstruct_equals_final_full() {
        let bars = zigzag(50);
        let opt = PipelineOptions::default();
        let mut st = PipelineState::new(opt.clone());
        let mut deltas = Vec::new();
        for b in &bars {
            deltas.push(st.append_delta(b.clone()));
        }
        let rebuilt = reconstruct_bundle_from_deltas(deltas);
        let full = build_kline_combine_bundle_from_state(&mut st);
        json_eq(&rebuilt, &full, "batch reconstruct");
        let golden = build_kline_combine_bundle_with(&bars, &opt);
        json_eq(&rebuilt, &golden, "batch vs golden");
    }

    /// 历史 bar_features 冻结：下一步不得改旧行
    #[test]
    fn delta_does_not_rewrite_old_bar_features() {
        let bars = zigzag(30);
        let mut st = PipelineState::new(PipelineOptions::default());
        let mut acc = KlineCombineBundle::empty();
        let mut prev_feats: Vec<BarCrosshairFeature> = Vec::new();
        for b in &bars {
            let d = st.append_delta(b.clone());
            apply_pipeline_delta(&mut acc, d);
            for (i, old) in prev_feats.iter().enumerate() {
                let now = &acc.bar_features[i];
                let jo = serde_json::to_value(old).unwrap();
                let jn = serde_json::to_value(now).unwrap();
                assert_eq!(jo, jn, "旧 bar_features[{i}] 被回写");
            }
            prev_feats = acc.bar_features.as_ref().clone();
        }
    }

    /// 002003 step24–28：逐步重建 + reset 后重放 Delta
    #[test]
    fn delta_002003_steps_24_28_and_reset_replay() {
        let Some(bars) = load_002003() else {
            return;
        };
        assert!(bars.len() > 28);
        let opt = PipelineOptions::default();
        let mut st = PipelineState::new(opt.clone());
        let mut acc = KlineCombineBundle::empty();
        let mut deltas = Vec::new();
        for step in 0..=28 {
            let d = st.append_delta(bars[step].clone());
            deltas.push(d.clone());
            apply_pipeline_delta(&mut acc, d);
            if (24..=28).contains(&step) {
                let full = build_kline_combine_bundle_from_state(&mut st);
                json_eq(&acc, &full, &format!("002003 step{step}"));
                let golden = build_kline_combine_bundle_with(&bars[..=step], &opt);
                json_eq(&acc, &golden, &format!("002003 step{step} golden"));
            }
        }
        // reset 会话后，用已记录的 Delta 从空仓重建到 27
        st.reset();
        let rebuilt27 = reconstruct_bundle_from_deltas(deltas.into_iter().take(28));
        for step in 0..=27 {
            st.append(bars[step].clone());
        }
        let full27 = build_kline_combine_bundle_from_state(&mut st);
        json_eq(&rebuilt27, &full27, "reset+replay step27 via deltas");
    }

    /// Delta JSON 不含历史 bar_features 数组（只有当步一行）
    #[test]
    fn delta_json_has_single_bar_feature() {
        let bars = zigzag(10);
        let mut st = PipelineState::new(PipelineOptions::default());
        let mut last = None;
        for b in &bars {
            last = Some(st.append_delta(b.clone()));
        }
        let d = last.unwrap();
        let v = serde_json::to_value(&d).unwrap();
        assert!(v.get("bar_features").is_none(), "Delta 不应再发 bar_features 数组");
        assert!(v.get("bar_feature").is_some());
        assert_eq!(d.idx, 9);
        assert_eq!(d.bar_feature.idx, 9);
        let full = build_kline_combine_bundle_from_state(&mut st);
        assert_eq!(full.bar_features.len(), 10);
        let db = serde_json::to_vec(&d).unwrap().len();
        let fb = serde_json::to_vec(&full).unwrap().len();
        assert!(db < fb, "末步 Delta 字节应小于 Full Snapshot ({db} vs {fb})");
    }
}
