//! Phase 2B-2：Delta vs Full Snapshot 的 bytes / serialization profiling。
//!
//! 不改算法。证明点在单测；本例只量体积与序列化耗时。
//!
//! 运行：
//!   cargo run --release --example profile_phase2b2 -p chan_data -- 2000

use std::time::Instant;

use chan_data::{
    apply_pipeline_delta, KlineCombineBundle, PipelineOptions, PipelineState, KlineBar,
};
use serde::Serialize;

#[derive(Serialize)]
struct ApiOk<'a, T: Serialize> {
    ok: bool,
    data: &'a T,
}

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

fn main() {
    let n: usize = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(2000);

    let opt = PipelineOptions::default();
    let bars = gen_bars(n);
    let mut st_full = PipelineState::new(opt.clone());
    let mut st_delta = PipelineState::new(opt);
    let mut acc = KlineCombineBundle::empty();

    let mut t_ser_full = 0u128;
    let mut t_ser_delta = 0u128;
    let mut bytes_full_sum = 0u64;
    let mut bytes_delta_sum = 0u64;
    let mut last_full_len = 0usize;
    let mut last_delta_len = 0usize;
    let mut last_feat_len = 0usize;
    let mut last_struct_len = 0usize;

    for bar in bars {
        st_full.append(bar.clone());
        let full = chan_data::build_kline_combine_bundle_from_state(&mut st_full);

        let s0 = Instant::now();
        let full_json = serde_json::to_string(&ApiOk {
            ok: true,
            data: &full,
        })
        .unwrap();
        t_ser_full += s0.elapsed().as_nanos();
        last_full_len = full_json.len();
        bytes_full_sum += last_full_len as u64;

        let d = st_delta.append_delta(bar);
        last_feat_len = serde_json::to_vec(&d.bar_feature).map(|b| b.len()).unwrap_or(0);
        last_struct_len = serde_json::to_vec(&d.structure).map(|b| b.len()).unwrap_or(0);

        let s1 = Instant::now();
        let delta_json = serde_json::to_string(&ApiOk {
            ok: true,
            data: &d,
        })
        .unwrap();
        t_ser_delta += s1.elapsed().as_nanos();
        last_delta_len = delta_json.len();
        bytes_delta_sum += last_delta_len as u64;

        apply_pipeline_delta(&mut acc, d);
    }

    let ja = serde_json::to_value(&acc).unwrap();
    let jb = serde_json::to_value(&chan_data::build_kline_combine_bundle_from_state(&mut st_full))
        .unwrap();
    let ok = ja == jb;

    let ms = |x: u128| (x as f64) / 1_000_000.0;
    println!("=== Phase 2B-2 Delta vs Full (N={n}) ===");
    println!("reconstruct JSON eq Full : {ok}");
    println!();
    println!("--- 末步单包 ---");
    println!("Full Snapshot JSON     : {last_full_len} bytes");
    println!("Delta JSON             : {last_delta_len} bytes");
    println!(
        "Delta / Full           : {:5.1}%",
        (last_delta_len as f64) / (last_full_len as f64) * 100.0
    );
    println!("  bar_feature 一行     : {last_feat_len} bytes");
    println!("  structure 当步全量   : {last_struct_len} bytes");
    println!();
    println!("--- 累计 N 步 ---");
    println!("Full JSON 累计         : {bytes_full_sum} bytes");
    println!("Delta JSON 累计        : {bytes_delta_sum} bytes");
    println!(
        "累计 Delta / Full      : {:5.1}%",
        (bytes_delta_sum as f64) / (bytes_full_sum as f64) * 100.0
    );
    println!();
    println!("--- 序列化耗时（ApiOk 包装，对齐 FFI）---");
    println!("Full serialize 累计    : {:10.2} ms", ms(t_ser_full));
    println!("Delta serialize 累计   : {:10.2} ms", ms(t_ser_delta));
    println!(
        "Delta / Full 耗时      : {:5.1}%",
        (t_ser_delta as f64) / (t_ser_full as f64) * 100.0
    );
}
