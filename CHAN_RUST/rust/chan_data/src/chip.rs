//! 筹码分布：分笔价量直加 → chip_tick_bins；按 cutoff 分桶 profile。
//! 对齐旧工程 a_rust_core::chip_profile / a_replay_trainer 离线注入口径。

use std::collections::BTreeMap;

use chrono::{Datelike, NaiveDateTime, Timelike};
use serde::{Deserialize, Serialize};

use crate::kline::{KlineBar, KlinePeriod};
use crate::tick::TickRow;

/// 单根 K 的分笔价量桶（左侧 S 绿 / 右侧 B 红）。
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ChipTickBins {
    /// 价格（升序，4 位精度）
    pub p: Vec<f64>,
    /// 左侧 S（卖）累计量
    pub s: Vec<f64>,
    /// 右侧 B（买）累计量
    pub b: Vec<f64>,
    /// 兼容字段 s+b
    pub w: Vec<f64>,
}

impl ChipTickBins {
    pub fn is_empty(&self) -> bool {
        self.p.is_empty()
    }

    pub fn from_side_rows(rows: &[(f64, f64, &str)]) -> Option<Self> {
        let mut acc_s: BTreeMap<i64, f64> = BTreeMap::new();
        let mut acc_b: BTreeMap<i64, f64> = BTreeMap::new();
        for &(price, vol, side) in rows {
            if !(price > 0.0) || !(vol > 0.0) || !price.is_finite() || !vol.is_finite() {
                continue;
            }
            // 价位四位小数：乘 10000 取整作键
            let key = (price * 10000.0).round() as i64;
            let s = side.trim().to_ascii_uppercase();
            if s == "S" {
                *acc_s.entry(key).or_insert(0.0) += vol;
            } else {
                // 方向缺失/异常 → 当作 B（右红）
                *acc_b.entry(key).or_insert(0.0) += vol;
            }
        }
        let keys: Vec<i64> = acc_s
            .keys()
            .chain(acc_b.keys())
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
            p.push(k as f64 / 10000.0);
            s.push(sv);
            b.push(bv);
            w.push(sv + bv);
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
    Quarter {
        y: i32,
        q: u32,
    },
    Year {
        y: i32,
    },
}

fn chip_bar_bucket_key(dt: NaiveDateTime, period: KlinePeriod) -> Option<ChipBucketKey> {
    match period {
        KlinePeriod::M1
        | KlinePeriod::M3
        | KlinePeriod::M5
        | KlinePeriod::M15
        | KlinePeriod::M30
        | KlinePeriod::M60 => {
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
        KlinePeriod::Quarter => {
            let q = (dt.month() - 1) / 3 + 1;
            Some(ChipBucketKey::Quarter {
                y: dt.year(),
                q,
            })
        }
        KlinePeriod::Year => Some(ChipBucketKey::Year { y: dt.year() }),
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
pub fn enrich_bars_with_chip_tick_bins(
    bars: &mut [KlineBar],
    ticks: &[TickRow],
    period: KlinePeriod,
) {
    if bars.is_empty() || ticks.is_empty() {
        return;
    }
    let mut key_to_rows: BTreeMap<ChipBucketKey, Vec<(f64, f64, String)>> = BTreeMap::new();
    for t in ticks {
        let Some(bk) = chip_bar_bucket_key(t.dt, period) else {
            continue;
        };
        key_to_rows
            .entry(bk)
            .or_default()
            .push((t.price, t.vol, t.side.clone()));
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
    for bar in bars.iter_mut() {
        let Some(bk) = bar_bucket_key_from_ms(bar.time_ms, period) else {
            continue;
        };
        if let Some(bins) = key_to_bins.get(&bk) {
            bar.metrics
                .insert("chip_tick_bins".to_string(), bins.to_json_value());
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

/// 按 cutoff_x（含）累加筹码：优先 chip_tick_bins 直加，否则 OHLC 三角分摊兜底。
pub fn chip_profile(bars: &[KlineBar], cutoff_x: Option<i64>, bucket_step: Option<f64>) -> ChipProfile {
    let step = bucket_step.unwrap_or(0.1).max(0.001);
    let cut = cutoff_x.unwrap_or_else(|| bars.last().map(|b| b.idx as i64).unwrap_or(-1));
    let mut buckets_s: BTreeMap<i64, f64> = BTreeMap::new();
    let mut buckets_b: BTreeMap<i64, f64> = BTreeMap::new();
    for bar in bars.iter().filter(|b| (b.idx as i64) <= cut) {
        if let Some(v) = bar.metrics.get("chip_tick_bins") {
            if let Some(bins) = ChipTickBins::from_json_value(v) {
                for (idx, price) in bins.p.iter().enumerate() {
                    if !price.is_finite() {
                        continue;
                    }
                    let key = (*price / step).floor() as i64;
                    let sv = bins.s.get(idx).copied().unwrap_or(0.0);
                    let mut bv = bins.b.get(idx).copied().unwrap_or(0.0);
                    if bins.b.is_empty() {
                        bv = bins.w.get(idx).copied().unwrap_or(0.0);
                    }
                    if sv > 0.0 {
                        *buckets_s.entry(key).or_insert(0.0) += sv;
                    }
                    if bv > 0.0 {
                        *buckets_b.entry(key).or_insert(0.0) += bv;
                    }
                }
                continue;
            }
        }
        accumulate_ohlc_triangle(bar, step, &mut buckets_b);
    }
    let keys: Vec<i64> = buckets_s
        .keys()
        .chain(buckets_b.keys())
        .copied()
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect();
    let mut prices = Vec::with_capacity(keys.len());
    let mut s_vals = Vec::with_capacity(keys.len());
    let mut b_vals = Vec::with_capacity(keys.len());
    let mut totals = Vec::with_capacity(keys.len());
    let mut max_total = 0.0;
    for key in keys {
        let sv = *buckets_s.get(&key).unwrap_or(&0.0);
        let bv = *buckets_b.get(&key).unwrap_or(&0.0);
        let total = sv + bv;
        if total > max_total {
            max_total = total;
        }
        prices.push(key as f64 * step);
        s_vals.push(sv);
        b_vals.push(bv);
        totals.push(total);
    }
    ChipProfile {
        profile_id: format!("chip:{cut}:{step}"),
        cutoff_x: cut,
        bucket_step: step,
        prices,
        s: s_vals,
        b: b_vals,
        total: totals,
        max_total,
        source: "rust".to_string(),
    }
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
    fn fold_side_rows_splits_s_and_b() {
        let bins = ChipTickBins::from_side_rows(&[
            (10.0, 100.0, "S"),
            (10.0, 50.0, "B"),
            (10.1, 200.0, "B"),
        ])
        .unwrap();
        assert_eq!(bins.p, vec![10.0, 10.1]);
        assert_eq!(bins.s, vec![100.0, 0.0]);
        assert_eq!(bins.b, vec![50.0, 200.0]);
        assert_eq!(bins.w, vec![150.0, 200.0]);
    }

    #[test]
    fn chip_profile_prefers_tick_bins() {
        let mut b0 = bar(0, 10.0, 10.2, 9.8, 10.0, 1000.0);
        let bins = ChipTickBins {
            p: vec![10.0, 10.1],
            s: vec![30.0, 0.0],
            b: vec![70.0, 40.0],
            w: vec![100.0, 40.0],
        };
        b0.metrics
            .insert("chip_tick_bins".to_string(), bins.to_json_value());
        let b1 = bar(1, 10.0, 10.3, 9.9, 10.2, 500.0);
        let profile = chip_profile(&[b0, b1], Some(0), Some(0.1));
        assert_eq!(profile.cutoff_x, 0);
        assert!(profile.max_total > 0.0);
        // cutoff=0 不应吃进 idx=1
        let sum: f64 = profile.total.iter().sum();
        assert!((sum - 140.0).abs() < 1e-6);
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
                w: vec![10.0],
            }
            .to_json_value(),
        );
        b1.metrics.insert(
            "chip_tick_bins".to_string(),
            ChipTickBins {
                p: vec![10.0],
                s: vec![0.0],
                b: vec![90.0],
                w: vec![90.0],
            }
            .to_json_value(),
        );
        let p0 = chip_profile(&[b0.clone(), b1.clone()], Some(0), Some(0.1));
        let p1 = chip_profile(&[b0, b1], Some(1), Some(0.1));
        assert!((p0.total.iter().sum::<f64>() - 10.0).abs() < 1e-6);
        assert!((p1.total.iter().sum::<f64>() - 100.0).abs() < 1e-6);
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
    }
}
