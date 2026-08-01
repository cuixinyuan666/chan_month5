//! 筹码分布：分笔价量直加 → chip_tick_bins；按 cutoff 分桶 profile。
//! 对齐旧工程 a_rust_core::chip_profile / a_replay_trainer 离线注入口径。

use std::collections::BTreeMap;

use chrono::{Datelike, NaiveDateTime, Timelike};
use serde::{Deserialize, Serialize};

use crate::kline::{KlineBar, KlinePeriod};
use crate::tick::TickRow;

/// 单根 K 的分笔价量桶（三分量：S 绿 / B 红 / 无方向灰）。
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ChipTickBins {
    /// 价格（升序，4 位精度）
    pub p: Vec<f64>,
    /// 左侧 S（卖）累计量
    pub s: Vec<f64>,
    /// 右侧 B（买）累计量
    pub b: Vec<f64>,
    /// 灰度 w（无 B/S 分笔累计量），不再是 s+b 合计
    pub w: Vec<f64>,
}

impl ChipTickBins {
    pub fn is_empty(&self) -> bool {
        self.p.is_empty()
    }

    pub fn from_side_rows(rows: &[(f64, f64, &str)]) -> Option<Self> {
        Self::from_side_qty_rows(rows)
    }

    /// 笔数分布桶：rows=(price, ticks, side)，结构同成交量 bins（s/b/w）。
    pub fn from_side_tick_rows(rows: &[(f64, f64, &str)]) -> Option<Self> {
        Self::from_side_qty_rows(rows)
    }

    fn from_side_qty_rows(rows: &[(f64, f64, &str)]) -> Option<Self> {
        let mut acc_s: BTreeMap<i64, f64> = BTreeMap::new();
        let mut acc_b: BTreeMap<i64, f64> = BTreeMap::new();
        let mut acc_w: BTreeMap<i64, f64> = BTreeMap::new();
        for &(price, qty, side) in rows {
            if !(price > 0.0) || !(qty > 0.0) || !price.is_finite() || !qty.is_finite() {
                continue;
            }
            // 价位四位小数：乘 10000 取整作键
            let key = (price * 10000.0).round() as i64;
            let s = side.trim().to_ascii_uppercase();
            if s == "S" {
                *acc_s.entry(key).or_insert(0.0) += qty;
            } else if s == "B" {
                *acc_b.entry(key).or_insert(0.0) += qty;
            } else {
                // 方向缺失 → 灰度 w（不再默认当 B）
                *acc_w.entry(key).or_insert(0.0) += qty;
            }
        }
        let keys: Vec<i64> = acc_s
            .keys()
            .chain(acc_b.keys())
            .chain(acc_w.keys())
            .copied()
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect();
        if keys.is_empty() {
            return None;
        }
        let mut p = Vec::with_capacity(keys.len());
        let mut s = Vec::with_capacity(keys.len());
        let mut b = Vec::with_capacity(keys.len());
        let mut w = Vec::with_capacity(keys.len());
        for k in keys {
            let sv = *acc_s.get(&k).unwrap_or(&0.0);
            let bv = *acc_b.get(&k).unwrap_or(&0.0);
            let wv = *acc_w.get(&k).unwrap_or(&0.0);
            p.push(k as f64 / 10000.0);
            s.push(sv);
            b.push(bv);
            w.push(wv);
        }
        Some(Self { p, s, b, w })
    }

    pub fn to_json_value(&self) -> serde_json::Value {
        serde_json::json!({
            "p": self.p,
            "s": self.s,
            "b": self.b,
            "w": self.w,
        })
    }

    pub fn from_json_value(v: &serde_json::Value) -> Option<Self> {
        let obj = v.as_object()?;
        let p = json_f64_vec(obj.get("p")?)?;
        if p.is_empty() {
            return None;
        }
        let s = obj.get("s").and_then(json_f64_vec).unwrap_or_default();
        let b = obj.get("b").and_then(json_f64_vec).unwrap_or_default();
        let w = obj.get("w").and_then(json_f64_vec).unwrap_or_default();
        Some(Self { p, s, b, w })
    }
}

fn json_f64_vec(v: &serde_json::Value) -> Option<Vec<f64>> {
    let arr = v.as_array()?;
    let mut out = Vec::with_capacity(arr.len());
    for x in arr {
        out.push(x.as_f64()?);
    }
    Some(out)
}

/// 分笔时刻 → 周期 K 线桶键（与 offline 合成 K 一致）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
enum ChipBucketKey {
    /// 逐笔：合成后的精确毫秒
    Instant {
        time_ms: i64,
    },
    Minute {
        y: i32,
        mo: u32,
        d: u32,
        slot: u32,
    },
    Day {
        y: i32,
        mo: u32,
        d: u32,
    },
    Week {
        y: i32,
        w: u32,
    },
    Month {
        y: i32,
        mo: u32,
    },
    /// 多月槽：年内 floor((m-1)/span)
    MonthSlot {
        y: i32,
        slot: u32,
        span: u32,
    },
    Year {
        y: i32,
    },
    YearSlot {
        y0: i32,
        span: u32,
    },
}

fn chip_bar_bucket_key(dt: NaiveDateTime, period: KlinePeriod) -> Option<ChipBucketKey> {
    use chrono::{TimeZone, Utc};
    match period {
        KlinePeriod::Tick => {
            let time_ms = Utc.from_utc_datetime(&dt).timestamp_millis();
            Some(ChipBucketKey::Instant { time_ms })
        }
        KlinePeriod::M1
        | KlinePeriod::M3
        | KlinePeriod::M5
        | KlinePeriod::M15
        | KlinePeriod::M30
        | KlinePeriod::M60
        | KlinePeriod::H2
        | KlinePeriod::H4 => {
            let pm = period.minute_slot()?;
            let slot = (dt.hour() * 60 + dt.minute()) / pm;
            Some(ChipBucketKey::Minute {
                y: dt.year(),
                mo: dt.month(),
                d: dt.day(),
                slot,
            })
        }
        KlinePeriod::Day => Some(ChipBucketKey::Day {
            y: dt.year(),
            mo: dt.month(),
            d: dt.day(),
        }),
        // 3 日=连续交易日分桶，单靠日历无法对齐 → enrich 里走 BarEnd 窗口
        KlinePeriod::Day3 => None,
        KlinePeriod::Week => {
            let iso = dt.date().iso_week();
            Some(ChipBucketKey::Week {
                y: iso.year(),
                w: iso.week(),
            })
        }
        KlinePeriod::Month => Some(ChipBucketKey::Month {
            y: dt.year(),
            mo: dt.month(),
        }),
        KlinePeriod::Month3
        | KlinePeriod::Month6
        | KlinePeriod::Month9
        | KlinePeriod::Month12
        | KlinePeriod::Quarter => {
            let span = period.month_span()?;
            let slot = (dt.month() - 1) / span;
            Some(ChipBucketKey::MonthSlot {
                y: dt.year(),
                slot,
                span,
            })
        }
        KlinePeriod::Year => Some(ChipBucketKey::Year { y: dt.year() }),
        KlinePeriod::Year3 | KlinePeriod::Year6 => {
            let span = period.year_span()?;
            let y0 = (dt.year().div_euclid(span as i32)) * span as i32;
            Some(ChipBucketKey::YearSlot { y0, span })
        }
    }
}

fn bar_bucket_key_from_ms(time_ms: i64, period: KlinePeriod) -> Option<ChipBucketKey> {
    use chrono::{TimeZone, Utc};
    let secs = time_ms.div_euclid(1000);
    let nsecs = ((time_ms.rem_euclid(1000)) * 1_000_000) as u32;
    let dt = Utc.timestamp_opt(secs, nsecs).single()?.naive_utc();
    chip_bar_bucket_key(dt, period)
}

/// 将分笔按周期桶聚合为 chip_tick_bins，写入对应 K 线 metrics。
/// 同时按第 4 列笔数写 tick_count / buy_tick_count / sell_tick_count（Kn笔数副图真实数据源）。
/// 笔数=0：仍写 metrics=0，但不写 chip_tick_count_bins（分布/副图全无柱）。
pub fn enrich_bars_with_chip_tick_bins(
    bars: &mut [KlineBar],
    ticks: &[TickRow],
    period: KlinePeriod,
) {
    if bars.is_empty() || ticks.is_empty() {
        return;
    }
    // tick：一笔一根 K0，按分笔序/idx 对齐写入（不靠可能碰撞的 time_ms）
    if period.is_tick() {
        enrich_tick_by_bar_idx(bars, ticks);
        return;
    }
    // 3 日连续交易日：用 bar 时间窗对齐（日历键对不齐）
    if period == KlinePeriod::Day3 {
        enrich_by_bar_end_windows(bars, ticks);
        return;
    }
    let mut key_to_rows: BTreeMap<ChipBucketKey, Vec<(f64, f64, String)>> = BTreeMap::new();
    // 笔数分布：按价累加 ticks（与成交量 bins 同价键）
    let mut key_to_tick_rows: BTreeMap<ChipBucketKey, Vec<(f64, f64, String)>> = BTreeMap::new();
    // 每桶笔数累计：(总笔数, 买笔数, 卖笔数)；灰度仅进总笔数
    let mut key_to_ticks: BTreeMap<ChipBucketKey, (f64, f64, f64)> = BTreeMap::new();
    for t in ticks {
        let Some(bk) = chip_bar_bucket_key(t.dt, period) else {
            continue;
        };
        key_to_rows
            .entry(bk)
            .or_default()
            .push((t.price, t.vol, t.side.clone()));
        // 与 from_side_rows 同口径：价格/量非法行不计
        if !(t.price > 0.0) || !(t.vol > 0.0) || !t.price.is_finite() || !t.vol.is_finite() {
            continue;
        }
        // 显式 0 不入 count bins（与 parse：0 保留 0、缺列才默认 1 一致）
        if t.ticks > 0.0 && t.ticks.is_finite() {
            key_to_tick_rows
                .entry(bk)
                .or_default()
                .push((t.price, t.ticks, t.side.clone()));
        }
        let acc = key_to_ticks.entry(bk).or_default();
        acc.0 += t.ticks;
        let s = t.side.trim().to_ascii_uppercase();
        if s == "B" {
            acc.1 += t.ticks;
        } else if s == "S" {
            acc.2 += t.ticks;
        }
    }
    let mut key_to_bins: BTreeMap<ChipBucketKey, ChipTickBins> = BTreeMap::new();
    for (bk, rows) in &key_to_rows {
        let refs: Vec<(f64, f64, &str)> = rows
            .iter()
            .map(|(p, v, s)| (*p, *v, s.as_str()))
            .collect();
        if let Some(bins) = ChipTickBins::from_side_rows(&refs) {
            key_to_bins.insert(*bk, bins);
        }
    }
    let mut key_to_count_bins: BTreeMap<ChipBucketKey, ChipTickBins> = BTreeMap::new();
    for (bk, rows) in &key_to_tick_rows {
        let refs: Vec<(f64, f64, &str)> = rows
            .iter()
            .map(|(p, tk, s)| (*p, *tk, s.as_str()))
            .collect();
        if let Some(bins) = ChipTickBins::from_side_tick_rows(&refs) {
            key_to_count_bins.insert(*bk, bins);
        }
    }
    for bar in bars.iter_mut() {
        let Some(bk) = bar_bucket_key_from_ms(bar.time_ms, period) else {
            continue;
        };
        if let Some(bins) = key_to_bins.get(&bk) {
            bar.metrics
                .insert("chip_tick_bins".to_string(), bins.to_json_value());
        }
        if let Some(bins) = key_to_count_bins.get(&bk) {
            bar.metrics
                .insert("chip_tick_count_bins".to_string(), bins.to_json_value());
        }
        if let Some((total, buy, sell)) = key_to_ticks.get(&bk) {
            bar.metrics
                .insert("tick_count".to_string(), serde_json::json!(total));
            bar.metrics
                .insert("buy_tick_count".to_string(), serde_json::json!(buy));
            bar.metrics
                .insert("sell_tick_count".to_string(), serde_json::json!(sell));
        }
    }
}

/// tick 周期：第 i 笔 → bars[i] 的 chip_tick_bins（含 B/S）+ 笔数 metrics。
fn enrich_tick_by_bar_idx(bars: &mut [KlineBar], ticks: &[TickRow]) {
    let n = bars.len().min(ticks.len());
    for i in 0..n {
        let t = &ticks[i];
        let refs = [(t.price, t.vol, t.side.as_str())];
        if let Some(bins) = ChipTickBins::from_side_rows(&refs) {
            bars[i]
                .metrics
                .insert("chip_tick_bins".to_string(), bins.to_json_value());
        }
        // 单笔笔数分布桶（与成交量 bins 同价）；ticks=0 不写桶
        if t.ticks > 0.0 && t.ticks.is_finite() {
            let trefs = [(t.price, t.ticks, t.side.as_str())];
            if let Some(bins) = ChipTickBins::from_side_tick_rows(&trefs) {
                bars[i]
                    .metrics
                    .insert("chip_tick_count_bins".to_string(), bins.to_json_value());
            }
        }
        // 单笔行笔数（含显式 0）：B→买、S→卖、无方向→仅总笔数
        if t.price > 0.0 && t.vol > 0.0 && t.price.is_finite() && t.vol.is_finite() {
            let s = t.side.trim().to_ascii_uppercase();
            let (buy, sell) = match s.as_str() {
                "B" => (t.ticks, 0.0),
                "S" => (0.0, t.ticks),
                _ => (0.0, 0.0),
            };
            bars[i]
                .metrics
                .insert("tick_count".to_string(), serde_json::json!(t.ticks));
            bars[i]
                .metrics
                .insert("buy_tick_count".to_string(), serde_json::json!(buy));
            bars[i]
                .metrics
                .insert("sell_tick_count".to_string(), serde_json::json!(sell));
        }
    }
}

/// 按 bar 结束时刻划分：tick 落入 (prev_end, bar_end] 写入该 bar。
fn enrich_by_bar_end_windows(bars: &mut [KlineBar], ticks: &[TickRow]) {
    use chrono::{TimeZone, Utc};
    let mut key_to_rows: BTreeMap<i64, Vec<(f64, f64, String)>> = BTreeMap::new();
    let mut key_to_tick_rows: BTreeMap<i64, Vec<(f64, f64, String)>> = BTreeMap::new();
    // 每窗笔数累计：(总笔数, 买笔数, 卖笔数)
    let mut key_to_ticks: BTreeMap<i64, (f64, f64, f64)> = BTreeMap::new();
    for t in ticks {
        let t_ms = Utc.from_utc_datetime(&t.dt).timestamp_millis();
        // 找第一个 bar.time_ms >= t_ms
        let mut chosen = None;
        for b in bars.iter() {
            if b.time_ms >= t_ms {
                chosen = Some(b.time_ms);
                break;
            }
        }
        let Some(end_ms) = chosen.or_else(|| bars.last().map(|b| b.time_ms)) else {
            continue;
        };
        key_to_rows
            .entry(end_ms)
            .or_default()
            .push((t.price, t.vol, t.side.clone()));
        if !(t.price > 0.0) || !(t.vol > 0.0) || !t.price.is_finite() || !t.vol.is_finite() {
            continue;
        }
        if t.ticks > 0.0 && t.ticks.is_finite() {
            key_to_tick_rows
                .entry(end_ms)
                .or_default()
                .push((t.price, t.ticks, t.side.clone()));
        }
        let acc = key_to_ticks.entry(end_ms).or_default();
        acc.0 += t.ticks;
        let s = t.side.trim().to_ascii_uppercase();
        if s == "B" {
            acc.1 += t.ticks;
        } else if s == "S" {
            acc.2 += t.ticks;
        }
    }
    let mut key_to_bins: BTreeMap<i64, ChipTickBins> = BTreeMap::new();
    for (k, rows) in &key_to_rows {
        let refs: Vec<(f64, f64, &str)> = rows
            .iter()
            .map(|(p, v, s)| (*p, *v, s.as_str()))
            .collect();
        if let Some(bins) = ChipTickBins::from_side_rows(&refs) {
            key_to_bins.insert(*k, bins);
        }
    }
    let mut key_to_count_bins: BTreeMap<i64, ChipTickBins> = BTreeMap::new();
    for (k, rows) in &key_to_tick_rows {
        let refs: Vec<(f64, f64, &str)> = rows
            .iter()
            .map(|(p, tk, s)| (*p, *tk, s.as_str()))
            .collect();
        if let Some(bins) = ChipTickBins::from_side_tick_rows(&refs) {
            key_to_count_bins.insert(*k, bins);
        }
    }
    for bar in bars.iter_mut() {
        if let Some(bins) = key_to_bins.get(&bar.time_ms) {
            bar.metrics
                .insert("chip_tick_bins".to_string(), bins.to_json_value());
        }
        if let Some(bins) = key_to_count_bins.get(&bar.time_ms) {
            bar.metrics
                .insert("chip_tick_count_bins".to_string(), bins.to_json_value());
        }
        if let Some((total, buy, sell)) = key_to_ticks.get(&bar.time_ms) {
            bar.metrics
                .insert("tick_count".to_string(), serde_json::json!(total));
            bar.metrics
                .insert("buy_tick_count".to_string(), serde_json::json!(buy));
            bar.metrics
                .insert("sell_tick_count".to_string(), serde_json::json!(sell));
        }
    }
}

/// 筹码分桶 profile 输出。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ChipProfile {
    pub profile_id: String,
    pub cutoff_x: i64,
    pub bucket_step: f64,
    pub prices: Vec<f64>,
    pub s: Vec<f64>,
    pub b: Vec<f64>,
    /// 灰度（无方向分笔）
    pub w: Vec<f64>,
    pub total: Vec<f64>,
    pub max_total: f64,
    pub source: String,
}

fn accumulate_ohlc_triangle(bar: &KlineBar, step: f64, buckets_b: &mut BTreeMap<i64, f64>) {
    let low = bar.low.min(bar.high);
    let high = bar.low.max(bar.high);
    let mode = bar.close.max(low).min(high);
    let vol = bar.volume.max(0.0);
    if high < low || vol <= 0.0 {
        return;
    }
    let i0 = (low / step).floor() as i64;
    let i1 = (high / step).ceil() as i64;
    if i1 < i0 {
        return;
    }
    if (high - low).abs() < 1e-12 {
        *buckets_b.entry(i0).or_insert(0.0) += vol;
        return;
    }
    let mut weights: Vec<(i64, f64)> = Vec::new();
    let mut total_w = 0.0;
    for key in i0..=i1 {
        let price = key as f64 * step;
        let weight = if (mode - low).abs() < 1e-12 {
            (high - price) / (high - low).max(1e-12)
        } else if (high - mode).abs() < 1e-12 {
            (price - low) / (high - low).max(1e-12)
        } else if price <= mode {
            (price - low) / (mode - low).max(1e-12)
        } else {
            (high - price) / (high - mode).max(1e-12)
        }
        .max(0.0);
        weights.push((key, weight));
        total_w += weight;
    }
    if total_w <= 1e-12 {
        return;
    }
    for (key, weight) in weights {
        if weight > 0.0 {
            *buckets_b.entry(key).or_insert(0.0) += weight / total_w * vol;
        }
    }
}

/// 按 cutoff_x（含）累加筹码：优先 chip_tick_bins 直加；
/// 一字线/无 bins：收盘价单点落量（禁三角）；其余 OHLC 才三角兜底。
pub fn chip_profile(bars: &[KlineBar], cutoff_x: Option<i64>, bucket_step: Option<f64>) -> ChipProfile {
    let step = bucket_step.unwrap_or(0.1).max(0.001);
    let cut = cutoff_x.unwrap_or_else(|| bars.last().map(|b| b.idx as i64).unwrap_or(-1));
    let mut buckets_s: BTreeMap<i64, f64> = BTreeMap::new();
    let mut buckets_b: BTreeMap<i64, f64> = BTreeMap::new();
    let mut buckets_w: BTreeMap<i64, f64> = BTreeMap::new();
    for bar in bars.iter().filter(|b| (b.idx as i64) <= cut) {
        if let Some(v) = bar.metrics.get("chip_tick_bins") {
            if let Some(bins) = ChipTickBins::from_json_value(v) {
                for (idx, price) in bins.p.iter().enumerate() {
                    if !price.is_finite() {
                        continue;
                    }
                    let key = (*price / step).floor() as i64;
                    let sv = bins.s.get(idx).copied().unwrap_or(0.0);
                    let bv = bins.b.get(idx).copied().unwrap_or(0.0);
                    let wv = bins.w.get(idx).copied().unwrap_or(0.0);
                    if sv > 0.0 {
                        *buckets_s.entry(key).or_insert(0.0) += sv;
                    }
                    if bv > 0.0 {
                        *buckets_b.entry(key).or_insert(0.0) += bv;
                    }
                    if wv > 0.0 {
                        *buckets_w.entry(key).or_insert(0.0) += wv;
                    }
                }
                continue;
            }
        }
        // 一字线（tick）：单点落量，禁止三角分摊
        if (bar.high - bar.low).abs() < 1e-12 {
            accumulate_point_volume(bar, step, &mut buckets_b);
            continue;
        }
        accumulate_ohlc_triangle(bar, step, &mut buckets_b);
    }
    let keys: Vec<i64> = buckets_s
        .keys()
        .chain(buckets_b.keys())
        .chain(buckets_w.keys())
        .copied()
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect();
    let mut prices = Vec::with_capacity(keys.len());
    let mut s_vals = Vec::with_capacity(keys.len());
    let mut b_vals = Vec::with_capacity(keys.len());
    let mut w_vals = Vec::with_capacity(keys.len());
    let mut totals = Vec::with_capacity(keys.len());
    let mut max_total = 0.0;
    for key in keys {
        let sv = *buckets_s.get(&key).unwrap_or(&0.0);
        let bv = *buckets_b.get(&key).unwrap_or(&0.0);
        let wv = *buckets_w.get(&key).unwrap_or(&0.0);
        let total = sv + bv + wv;
        if total > max_total {
            max_total = total;
        }
        prices.push(key as f64 * step);
        s_vals.push(sv);
        b_vals.push(bv);
        w_vals.push(wv);
        totals.push(total);
    }
    ChipProfile {
        profile_id: format!("chip:{cut}:{step}"),
        cutoff_x: cut,
        bucket_step: step,
        prices,
        s: s_vals,
        b: b_vals,
        w: w_vals,
        total: totals,
        max_total,
        source: "rust".to_string(),
    }
}

/// 一字线无 bins：收盘价单点 + 全量记 B。
fn accumulate_point_volume(bar: &KlineBar, step: f64, buckets_b: &mut BTreeMap<i64, f64>) {
    let vol = bar.volume.max(0.0);
    if vol <= 0.0 || !bar.close.is_finite() {
        return;
    }
    let key = (bar.close / step).floor() as i64;
    *buckets_b.entry(key).or_insert(0.0) += vol;
}

/// 局部筹码峰：v >= 左邻 && v > 右邻（平顶峰取右端，对齐 Dart peakIndices）。
pub fn chip_peaks(profile: &ChipProfile) -> Vec<usize> {
    let n = profile.total.len();
    if n == 0 {
        return Vec::new();
    }
    let mut out = Vec::new();
    for i in 0..n {
        let v = profile.total[i];
        if v <= 0.0 {
            continue;
        }
        let left_ok = i == 0 || v >= profile.total[i - 1];
        let right_ok = i + 1 >= n || v > profile.total[i + 1];
        if left_ok && right_ok {
            out.push(i);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    fn bar(idx: i32, o: f64, h: f64, l: f64, c: f64, v: f64) -> KlineBar {
        KlineBar {
            idx,
            time_ms: 0,
            time_text: String::new(),
            open: o,
            high: h,
            low: l,
            close: c,
            volume: v,
            amount: 0.0,
            metrics: serde_json::Map::new(),
        }
    }

    #[test]
    fn fold_side_rows_splits_s_and_b_and_w() {
        let bins = ChipTickBins::from_side_rows(&[
            (10.0, 100.0, "S"),
            (10.0, 50.0, "B"),
            (10.1, 200.0, "B"),
            // 无方向 → 灰度 w，不再当 B
            (10.0, 30.0, ""),
        ])
        .unwrap();
        assert_eq!(bins.p, vec![10.0, 10.1]);
        assert_eq!(bins.s, vec![100.0, 0.0]);
        assert_eq!(bins.b, vec![50.0, 200.0]);
        assert_eq!(bins.w, vec![30.0, 0.0]);
    }

    #[test]
    fn chip_profile_prefers_tick_bins() {
        let mut b0 = bar(0, 10.0, 10.2, 9.8, 10.0, 1000.0);
        let bins = ChipTickBins {
            p: vec![10.0, 10.1],
            s: vec![30.0, 0.0],
            b: vec![70.0, 40.0],
            // 灰度独立分量：10.0 价位 20
            w: vec![20.0, 0.0],
        };
        b0.metrics
            .insert("chip_tick_bins".to_string(), bins.to_json_value());
        let b1 = bar(1, 10.0, 10.3, 9.9, 10.2, 500.0);
        let profile = chip_profile(&[b0, b1], Some(0), Some(0.1));
        assert_eq!(profile.cutoff_x, 0);
        assert!(profile.max_total > 0.0);
        // cutoff=0 不应吃进 idx=1；total=s+b+w=30+70+20+40=160
        let sum: f64 = profile.total.iter().sum();
        assert!((sum - 160.0).abs() < 1e-6);
        // 灰度进 profile.w
        let w_sum: f64 = profile.w.iter().sum();
        assert!((w_sum - 20.0).abs() < 1e-6);
    }

    #[test]
    fn chip_profile_cutoff_freezes_history() {
        let mut b0 = bar(0, 10.0, 10.0, 10.0, 10.0, 0.0);
        let mut b1 = bar(1, 10.0, 10.0, 10.0, 10.0, 0.0);
        b0.metrics.insert(
            "chip_tick_bins".to_string(),
            ChipTickBins {
                p: vec![10.0],
                s: vec![10.0],
                b: vec![0.0],
                w: vec![0.0],
            }
            .to_json_value(),
        );
        b1.metrics.insert(
            "chip_tick_bins".to_string(),
            ChipTickBins {
                p: vec![10.0],
                s: vec![0.0],
                b: vec![90.0],
                w: vec![10.0],
            }
            .to_json_value(),
        );
        let p0 = chip_profile(&[b0.clone(), b1.clone()], Some(0), Some(0.1));
        let p1 = chip_profile(&[b0, b1], Some(1), Some(0.1));
        assert!((p0.total.iter().sum::<f64>() - 10.0).abs() < 1e-6);
        // 同价位 10.0：b0(10) + b1(s0+b90+w10)=110
        assert!((p1.total.iter().sum::<f64>() - 110.0).abs() < 1e-6);
        // b1 的灰度 10 进 w 分量
        assert!((p1.w.iter().sum::<f64>() - 10.0).abs() < 1e-6);
    }

    #[test]
    fn enrich_injects_bins_by_day_bucket() {
        use chrono::{TimeZone, Utc};
        let dt = NaiveDate::from_ymd_opt(2024, 1, 2)
            .unwrap()
            .and_hms_opt(10, 0, 0)
            .unwrap();
        let ticks = vec![TickRow {
            dt,
            price: 12.34,
            vol: 100.0,
            side: "B".to_string(),
            has_bs: true,
            price_lo: None,
            price_hi: None,
            ticks: 25.0,
        }];
        let mut bars = vec![KlineBar {
            idx: 0,
            time_ms: Utc.from_utc_datetime(&dt).timestamp_millis(),
            time_text: "2024/01/02 15:00".to_string(),
            open: 12.0,
            high: 13.0,
            low: 11.0,
            close: 12.5,
            volume: 100.0,
            amount: 0.0,
            metrics: serde_json::Map::new(),
        }];
        enrich_bars_with_chip_tick_bins(&mut bars, &ticks, KlinePeriod::Day);
        assert!(bars[0].metrics.contains_key("chip_tick_bins"));
        // 真实笔数：总 25、买 25（B）、卖 0
        assert_eq!(bars[0].metrics["tick_count"].as_f64(), Some(25.0));
        assert_eq!(bars[0].metrics["buy_tick_count"].as_f64(), Some(25.0));
        assert_eq!(bars[0].metrics["sell_tick_count"].as_f64(), Some(0.0));
    }

    #[test]
    fn enrich_tick_writes_bins_per_bar_idx() {
        use chrono::NaiveTime;
        let base = NaiveDate::from_ymd_opt(2026, 4, 21)
            .unwrap()
            .and_time(NaiveTime::from_hms_opt(9, 30, 0).unwrap());
        let ticks = vec![
            TickRow {
                dt: base,
                price: 10.0,
                vol: 100.0,
                side: "B".into(),
                has_bs: true,
                price_lo: None,
                price_hi: None,
                ticks: 7.0,
            },
            TickRow {
                dt: base + chrono::Duration::milliseconds(1),
                price: 10.1,
                vol: 50.0,
                side: "S".into(),
                has_bs: true,
                price_lo: None,
                price_hi: None,
                ticks: 3.0,
            },
        ];
        let mut bars: Vec<KlineBar> = ticks
            .iter()
            .enumerate()
            .map(|(i, t)| {
                let p = t.price;
                bar(i as i32, p, p, p, p, t.vol)
            })
            .collect();
        enrich_bars_with_chip_tick_bins(&mut bars, &ticks, KlinePeriod::Tick);
        assert!(bars[0].metrics.contains_key("chip_tick_bins"));
        assert!(bars[1].metrics.contains_key("chip_tick_bins"));
        let b0 = ChipTickBins::from_json_value(bars[0].metrics.get("chip_tick_bins").unwrap())
            .unwrap();
        let b1 = ChipTickBins::from_json_value(bars[1].metrics.get("chip_tick_bins").unwrap())
            .unwrap();
        assert!((b0.b[0] - 100.0).abs() < 1e-9);
        assert!((b1.s[0] - 50.0).abs() < 1e-9);
        // 真实笔数：bar0 B=7 笔、bar1 S=3 笔
        assert_eq!(bars[0].metrics["tick_count"].as_f64(), Some(7.0));
        assert_eq!(bars[0].metrics["buy_tick_count"].as_f64(), Some(7.0));
        assert_eq!(bars[0].metrics["sell_tick_count"].as_f64(), Some(0.0));
        assert_eq!(bars[1].metrics["tick_count"].as_f64(), Some(3.0));
        assert_eq!(bars[1].metrics["buy_tick_count"].as_f64(), Some(0.0));
        assert_eq!(bars[1].metrics["sell_tick_count"].as_f64(), Some(3.0));
        // 一字无 bins：单点而非三角
        let plain = bar(0, 9.0, 9.0, 9.0, 9.0, 80.0);
        let profile = chip_profile(&[plain], Some(0), Some(0.1));
        assert_eq!(profile.total.len(), 1);
        assert!((profile.total[0] - 80.0).abs() < 1e-9);
    }
}
