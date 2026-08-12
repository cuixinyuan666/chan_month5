//! Phase 2B-1 快照/输出 profiling —— 对齐真实 FFI 热路径（不改算法）。
//!
//! 真实 FFI 路径（`chan_pipeline_append`）：
//!   append → snapshot（含 BarFeature 增量）→ from_snapshot（复用 feature/K0 帧）
//!   → serde_json(ApiOk) → CString
//!
//! 运行：
//!   cargo run --release --example profile_phase2a -p chan_data -- 2000
//!   DUMP_JSON=1  写出 phase2a_sample_bundle.json / phase2a_sample_bars.json

use std::ffi::CString;
use std::hint::black_box;
use std::time::Instant;

use chan_data::{
    build_k1_combine_frames_with, build_kline_combine_bundle_from_snapshot,
    enrich_fractal_peak_dist, find_buy1_with_active, find_buy2_with_active,
    find_buy_n_with_active, find_sell1_with_active, find_sell2_with_active,
    find_sell_n_with_active, find_zs, find_zs_with_confirmed, weekday_from_bar,
    zs_frames_from_list, BarCrosshairFeature, K0ConfirmSignal, LevelBundleOut, LevelSegment,
    PipelineOptions, PipelineResult, PipelineState, KlineBar,
};
use serde::Serialize;

#[derive(Serialize)]
struct ApiOk<'a, T: Serialize> {
    ok: bool,
    data: &'a T,
}

/// 确定性 LCG 随机游走，产出多层级段。
fn gen_bars(n: usize) -> Vec<KlineBar> {
    let mut rng: u128 = 0x1234_5678_9abc_def0;
    let mut price = 100.0f64;
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        rng = rng
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let r1 = ((rng >> 33) as f64) / ((1u64 << 31) as f64) - 1.0;
        rng = rng
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let r2 = ((rng >> 33) as f64) / ((1u64 << 31) as f64);
        let open = price;
        let close = (price + r1 * 2.0).max(1.0);
        let hi = open.max(close) + r2 * 0.9;
        let lo = (open.min(close) - r2 * 0.9).max(0.01);
        out.push(KlineBar {
            idx: i as i32,
            time_ms: (i as i64) * 60_000,
            time_text: format!("2024/01/01 09:{:02}", i % 60),
            open,
            high: hi,
            low: lo,
            close,
            volume: 1000.0 + r2 * 500.0,
            amount: 0.0,
            metrics: serde_json::Map::new(),
        });
        price = close;
    }
    out
}

/// 与 pipeline::k0_bars_to_segments 同构（只用于测量 K0 ZS/BS 重算，不改算法）。
fn k0_bars_to_segments(bars: &[KlineBar]) -> Vec<LevelSegment> {
    let mut out = Vec::with_capacity(bars.len());
    for (i, b) in bars.iter().enumerate() {
        let dir = if i == 0 {
            1
        } else {
            let p = &bars[i - 1];
            let mid = (b.high + b.low) / 2.0;
            let p_mid = (p.high + p.low) / 2.0;
            if mid >= p_mid {
                1
            } else {
                -1
            }
        };
        let x = b.idx;
        out.push(LevelSegment {
            idx: i as i64,
            dir,
            begin_confirm_x: x,
            end_confirm_x: x,
            begin_pole_x: x,
            end_pole_x: x,
            open: b.open,
            high: b.high,
            low: b.low,
            close: b.close,
            volume: b.volume,
            begin_fractal_x1: x,
            begin_fractal_x2: x,
            end_fractal_x1: x,
            end_fractal_x2: x,
            begin_fractal_high: b.high,
            begin_fractal_low: b.low,
            end_fractal_high: b.high,
            end_fractal_low: b.low,
            is_bootstrap: false,
            is_promoted_default: false,
        });
    }
    out
}

/// 与 zs::segments_with_optional_active 同构（测量用）。
fn segs_with_active(lv: &LevelBundleOut) -> Vec<LevelSegment> {
    let mut out = lv.segments.clone();
    if let Some(u) = &lv.active_unit {
        if !out.iter().any(|s| s.idx == u.idx) {
            let (px1, px2) = if u.x1 <= u.x2 {
                (u.x1, u.x2)
            } else {
                (u.x2, u.x1)
            };
            let (bh, bl, eh, el) = if u.dir >= 0 {
                (u.low, u.low, u.high, u.high)
            } else {
                (u.high, u.high, u.low, u.low)
            };
            out.push(LevelSegment {
                idx: u.idx,
                dir: u.dir,
                begin_confirm_x: u.confirm_x,
                end_confirm_x: u.confirm_x,
                begin_pole_x: px1,
                end_pole_x: px2,
                open: u.open,
                high: u.high,
                low: u.low,
                close: u.close,
                volume: u.volume,
                begin_fractal_x1: u.x1,
                begin_fractal_x2: u.x2,
                end_fractal_x1: u.x1,
                end_fractal_x2: u.x2,
                begin_fractal_high: bh,
                begin_fractal_low: bl,
                end_fractal_high: eh,
                end_fractal_low: el,
                is_bootstrap: false,
                is_promoted_default: false,
            });
        }
    }
    out
}

fn build_features(bars: &[KlineBar], pr: &PipelineResult) -> Vec<BarCrosshairFeature> {
    let l1 = &pr.levels[0];
    let k0_confirms: Vec<K0ConfirmSignal> = l1
        .confirms
        .iter()
        .map(|c| K0ConfirmSignal {
            x: c.x,
            fx: c.fx.clone(),
            value: c.value,
            fractal_x1: c.fractal_x1,
            fractal_x2: c.fractal_x2,
            truncated: c.truncated,
        })
        .collect();
    let mut features: Vec<BarCrosshairFeature> = bars
        .iter()
        .enumerate()
        .map(|(i, b)| {
            let k = &pr.bar_k_snaps[i];
            let snaps = &pr.bar_level_snaps[i];
            let l1s = snaps.first();
            BarCrosshairFeature {
                idx: b.idx,
                weekday: weekday_from_bar(b),
                merge_inner_seq: k.inner_seq,
                merge_count: k.count,
                merge_box_seq: k.group_seq,
                combine_fx: k.fx.clone(),
                combine_high: k.high,
                combine_low: k.low,
                fractal_peak_dist: 0,
                k1_idx: l1s.and_then(|s| s.unit_idx.map(|v| v as i32)),
                k1_merge_inner_seq: l1s.map(|s| s.merge_inner_seq).unwrap_or(0),
                k1_merge_count: l1s.map(|s| s.merge_count).unwrap_or(1),
                k1_open: l1s.map(|s| s.unit_open).unwrap_or(0.0),
                k1_high: l1s.map(|s| s.unit_high).unwrap_or(0.0),
                k1_low: l1s.map(|s| s.unit_low).unwrap_or(0.0),
                k1_close: l1s.map(|s| s.unit_close).unwrap_or(0.0),
                k1_volume: l1s.map(|s| s.unit_volume).unwrap_or(0.0),
                k1_combine_high: l1s.map(|s| s.combine_high).unwrap_or(0.0),
                k1_combine_low: l1s.map(|s| s.combine_low).unwrap_or(0.0),
                k1_combine_fx: l1s
                    .map(|s| s.combine_fx.clone())
                    .unwrap_or_else(|| "UNKNOWN".to_string()),
                levels: snaps.clone(),
                zs_hits: pr
                    .bar_struct_hits
                    .get(i)
                    .map(|(z, _)| z.clone())
                    .unwrap_or_default(),
                bs1_hits: pr
                    .bar_struct_hits
                    .get(i)
                    .map(|(_, b)| b.clone())
                    .unwrap_or_default(),
            }
        })
        .collect();
    enrich_fractal_peak_dist(bars, &mut features, &k0_confirms);
    features
}

fn json_len<T: Serialize>(v: &T) -> usize {
    serde_json::to_vec(v).map(|b| b.len()).unwrap_or(0)
}

fn main() {
    let n: usize = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(2000);

    let opt = PipelineOptions::default();
    let bars = gen_bars(n);
    let mut state = PipelineState::new(opt.clone());

    // —— 真实 FFI 热路径（计入总计，不双计）——
    let mut t_append = 0u128;
    let mut t_snap = 0u128;
    let mut t_bundle = 0u128;
    let mut t_ser = 0u128;
    let mut t_cstr = 0u128;

    // —— 拆分测量（额外跑一遍，不计入总计）——
    let mut t_clone_snaps = 0u128;
    let mut t_export_zs = 0u128;
    let mut t_export_bs = 0u128;
    let mut t_export_clone_hist = 0u128;
    let mut t_feat = 0u128;
    let mut t_k1_combine = 0u128;
    let mut t_k0_zs_bs = 0u128;

    let mut per_step: Vec<u128> = Vec::with_capacity(n);
    let mut last_json_len = 0usize;
    let mut last_bundle = None;
    let mut last_levels = 0usize;

    for (i, bar) in bars.iter().cloned().enumerate() {
        let s0 = Instant::now();
        state.append(bar);
        let a = s0.elapsed().as_nanos();

        let s2 = Instant::now();
        let pr: PipelineResult = state.snapshot();
        let snap = s2.elapsed().as_nanos();

        // 拆分：snapshot 内 bar_* Arc clone（2B-1 应为 O(1)）
        let s_c = Instant::now();
        black_box(pr.bar_level_snaps.clone());
        black_box(pr.bar_k_snaps.clone());
        black_box(pr.bar_seg_rows.clone());
        black_box(pr.bar_struct_hits.clone());
        t_clone_snaps += s_c.elapsed().as_nanos();

        // 拆分：export 内冻结历史 clone
        let s_h = Instant::now();
        for lv in &pr.levels {
            black_box(lv.confirms.clone());
            black_box(lv.segments.clone());
            black_box(lv.unit_bars.clone());
            black_box(lv.combine_frames.clone());
        }
        t_export_clone_hist += s_h.elapsed().as_nanos();

        // 拆分：export 内 find_zs_with_confirmed（全层）+ 随后 6 路 BS
        let mut zs_pack = Vec::with_capacity(pr.levels.len());
        let s_z = Instant::now();
        for lv in &pr.levels {
            let n_confirmed = lv.segments.len();
            let segs = segs_with_active(lv);
            let display = lv.level + 1;
            let zs_list = find_zs_with_confirmed(&segs, display, &opt.zs_config, n_confirmed);
            black_box(zs_frames_from_list(&zs_list, &segs, display));
            zs_pack.push((zs_list, segs, display, lv.active_unit.as_ref().map(|u| u.idx)));
        }
        t_export_zs += s_z.elapsed().as_nanos();

        let s_b = Instant::now();
        for (zs_list, segs, display, active_idx) in &zs_pack {
            black_box(find_buy1_with_active(zs_list, segs, *display, *active_idx));
            black_box(find_sell1_with_active(zs_list, segs, *display, *active_idx));
            black_box(find_buy2_with_active(zs_list, segs, *display, *active_idx));
            black_box(find_sell2_with_active(zs_list, segs, *display, *active_idx));
            black_box(find_buy_n_with_active(zs_list, segs, *display, *active_idx));
            black_box(find_sell_n_with_active(zs_list, segs, *display, *active_idx));
        }
        t_export_bs += s_b.elapsed().as_nanos();

        // 对照：旧全量 BarFeature（热路径已改为 snapshot 内增量，不计入总计）
        let s_f = Instant::now();
        let feats = build_features(state.bars(), &pr);
        black_box(feats.len());
        t_feat += s_f.elapsed().as_nanos();

        let s_k1 = Instant::now();
        if let Some(l0) = pr.levels.first() {
            let mut k1_bars: Vec<_> = l0
                .segments
                .iter()
                .map(|s| chan_data::K1Bar {
                    idx: s.idx as i32,
                    dir: s.dir,
                    x1: s.begin_pole_x.min(s.end_pole_x),
                    x2: s.begin_pole_x.max(s.end_pole_x),
                    open: s.open,
                    high: s.high,
                    low: s.low,
                    close: s.close,
                    confirm_x: s.end_confirm_x,
                })
                .collect();
            if let Some(u) = &l0.active_unit {
                k1_bars.push(chan_data::K1Bar {
                    idx: u.idx as i32,
                    dir: u.dir,
                    x1: u.x1.min(u.x2),
                    x2: u.x1.max(u.x2),
                    open: u.open,
                    high: u.high,
                    low: u.low,
                    close: u.close,
                    confirm_x: u.confirm_x,
                });
            }
            black_box(build_k1_combine_frames_with(
                state.bars(),
                &k1_bars,
                opt.truncation_check,
                opt.validity_check,
            ));
        }
        t_k1_combine += s_k1.elapsed().as_nanos();

        // 对照：旧 bundle 内 K0 ZS/BS 重算（热路径已复用 collect_k0 帧）
        let s_k0 = Instant::now();
        {
            let segs = k0_bars_to_segments(state.bars());
            let zs_list = find_zs(&segs, 0, &opt.zs_config);
            black_box(find_buy1_with_active(&zs_list, &segs, 0, None));
            black_box(find_sell1_with_active(&zs_list, &segs, 0, None));
            black_box(find_buy2_with_active(&zs_list, &segs, 0, None));
            black_box(find_sell2_with_active(&zs_list, &segs, 0, None));
            black_box(find_buy_n_with_active(&zs_list, &segs, 0, None));
            black_box(find_sell_n_with_active(&zs_list, &segs, 0, None));
        }
        t_k0_zs_bs += s_k0.elapsed().as_nanos();

        last_levels = pr.levels.len();

        let s3 = Instant::now();
        let bundle = build_kline_combine_bundle_from_snapshot(&state, pr);
        let bund = s3.elapsed().as_nanos();

        let s4 = Instant::now();
        let json = serde_json::to_string(&ApiOk {
            ok: true,
            data: &bundle,
        })
        .unwrap();
        let ser = s4.elapsed().as_nanos();
        last_json_len = json.len();

        let s5 = Instant::now();
        let cstr = CString::new(json.as_bytes()).ok();
        t_cstr += s5.elapsed().as_nanos();
        black_box(cstr.as_ref().map(|c| c.as_bytes().len()));

        if i + 1 == n && std::env::var_os("DUMP_JSON").is_some() {
            let _ = std::fs::write("phase2a_sample_bundle.json", &json);
            let bars_json = serde_json::to_string(state.bars()).unwrap();
            let _ = std::fs::write("phase2a_sample_bars.json", bars_json);
            eprintln!(
                "[dump] phase2a_sample_bundle.json ({} bytes) + phase2a_sample_bars.json",
                json.len()
            );
        }

        t_append += a;
        t_snap += snap;
        t_bundle += bund;
        t_ser += ser;
        per_step.push(a + snap + bund + ser);

        if i + 1 == n {
            last_bundle = Some(bundle);
        }
    }

    let total_step = per_step.iter().sum::<u128>();
    let ms = |x: u128| (x as f64) / 1_000_000.0;
    let pct = |x: u128| (x as f64) / (total_step as f64) * 100.0;

    println!("=== Phase 2B-1 profiling (N={n}) ===");
    println!("levels produced : {last_levels}");
    println!("final FFI json  : {last_json_len} bytes (ApiOk 包装，对齐 chan_pipeline_append)");
    println!();
    println!("--- 真实 FFI 热路径累计（release，无双计）---");
    println!(
        "append (增量)          : {:10.2} ms  ({:5.1}%)",
        ms(t_append),
        pct(t_append)
    );
    println!("bars().to_vec()        :      0.00 ms  (已删除，from_state 引用)");
    println!(
        "snapshot(export+增量特征): {:10.2} ms  ({:5.1}%)",
        ms(t_snap),
        pct(t_snap)
    );
    println!(
        "from_snapshot(bundle)  : {:10.2} ms  ({:5.1}%)",
        ms(t_bundle),
        pct(t_bundle)
    );
    println!(
        "serialize(JSON ApiOk)  : {:10.2} ms  ({:5.1}%)",
        ms(t_ser),
        pct(t_ser)
    );
    println!(
        "CString::new (FFI拷贝) : {:10.2} ms  (额外，未计入 step 总计)",
        ms(t_cstr)
    );
    println!("------------------------------------------");
    println!("step 总成本            : {:10.2} ms", ms(total_step));
    println!("append / step 占比     : {:5.2}%", pct(t_append));
    println!(
        "step / append 倍数     : {:8.1}x",
        total_step as f64 / t_append as f64
    );
    println!();

    println!("--- snapshot / export 逐函数（额外重跑，不计入总计）---");
    println!(
        "clone bar_*_snaps      : {:10.2} ms  (2B-1 应为 Arc O(1))",
        ms(t_clone_snaps)
    );
    println!(
        "clone confirms/segs    : {:10.2} ms  (export 冻结历史 clone)",
        ms(t_export_clone_hist)
    );
    println!(
        "find_zs_with_confirmed : {:10.2} ms  (export 全层中枢)",
        ms(t_export_zs)
    );
    println!(
        "find_buy/sell 1/2/n    : {:10.2} ms  (export 全层 BS，含内部再跑 zs)",
        ms(t_export_bs)
    );
    println!();

    println!("--- 对照：旧 from_pipeline 成本（不计入总计；热路径已消除）---");
    println!(
        "BarFeature 全量重建    : {:10.2} ms",
        ms(t_feat)
    );
    println!(
        "build_k1_combine       : {:10.2} ms",
        ms(t_k1_combine)
    );
    println!(
        "build_k0_zs_and_bs1    : {:10.2} ms  (热路径复用 collect_k0)",
        ms(t_k0_zs_bs)
    );
    println!();

    println!("--- 逐根 step 成本随 n 增长（窗口=最近50根均值 µs/step）---");
    for c in [100usize, 250, 500, 1000, 1500, 2000] {
        if c > n {
            continue;
        }
        let lo = c.saturating_sub(50);
        let w = &per_step[lo..c];
        let avg = w.iter().sum::<u128>() as f64 / w.len() as f64 / 1000.0;
        let base = {
            let b = &per_step[50.min(n.saturating_sub(1))..100.min(n)];
            if b.is_empty() {
                avg
            } else {
                b.iter().sum::<u128>() as f64 / b.len() as f64 / 1000.0
            }
        };
        println!(
            "n={:5}  avg={:9.1} µs/step   ≈ {:.1}x (vs n≈75)",
            c,
            avg,
            avg / base.max(1.0)
        );
    }

    if let Some(bundle) = last_bundle.as_ref() {
        println!();
        println!("--- 末态 JSON 体积分解（serde_json::to_vec）---");
        let rows = [
            ("bar_features", json_len(&bundle.bar_features)),
            ("levels", json_len(&bundle.levels)),
            ("frames", json_len(&bundle.frames)),
            ("k0_confirms", json_len(&bundle.k0_confirms)),
            ("k0_lines", json_len(&bundle.k0_lines)),
            ("k1_analysis", json_len(&bundle.k1_analysis)),
            ("k1_bars", json_len(&bundle.k1_bars)),
            ("k1_combine_frames", json_len(&bundle.k1_combine_frames)),
            ("level_segments", json_len(&bundle.level_segments)),
            ("level_virtual_units", json_len(&bundle.level_virtual_units)),
            ("zs_k0_frames", json_len(&bundle.zs_k0_frames)),
            ("buy1_k0_frames", json_len(&bundle.buy1_k0_frames)),
            ("sell1_k0_frames", json_len(&bundle.sell1_k0_frames)),
            ("buy2_k0_frames", json_len(&bundle.buy2_k0_frames)),
            ("sell2_k0_frames", json_len(&bundle.sell2_k0_frames)),
            ("buy_n_k0_frames", json_len(&bundle.buy_n_k0_frames)),
            ("sell_n_k0_frames", json_len(&bundle.sell_n_k0_frames)),
        ];
        let mut pairs = rows.to_vec();
        pairs.sort_by_key(|(_, l)| std::cmp::Reverse(*l));
        let sum: usize = pairs.iter().map(|(_, l)| *l).sum();
        for (name, len) in &pairs {
            println!(
                "{:22} {:>10} bytes  ({:5.1}%)",
                name,
                len,
                (*len as f64) / (sum as f64) * 100.0
            );
        }
        println!(
            "{:22} {:>10} bytes  (字段合计，未含 ApiOk 外壳)",
            "fields_sum", sum
        );
        if let Some(f0) = bundle.bar_features.first() {
            println!(
                "bar_features[0].levels.len = {}  (每根 × 全层 LevelSnap)",
                f0.levels.len()
            );
        }
        println!("bundle.levels.len         = {}", bundle.levels.len());
        println!(
            "bundle.bar_features.len   = {}",
            bundle.bar_features.len()
        );
    }
}
