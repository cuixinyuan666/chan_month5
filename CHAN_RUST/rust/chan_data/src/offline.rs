use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use chrono::{Datelike, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Timelike, Utc};

use crate::error::{ChanDataError, Result};
use crate::kline::{KlineBar, KlinePeriod};
use crate::tick::{normalize_native, read_tick_file, TickRow};

/// 默认 a_Data：优先 `chan.py/a_Data`（CHAN_RUST 的上一级），其次 `CHAN_RUST/a_Data`。
pub fn default_data_root() -> PathBuf {
    let chan_rust = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..");
    let candidates = [
        chan_rust.join("..").join("a_Data"),
        chan_rust.join("a_Data"),
    ];
    for c in &candidates {
        if c.is_dir() {
            return c.canonicalize().unwrap_or_else(|_| c.clone());
        }
    }
    candidates[0].clone()
}

/// 解析数据根目录：优先入参，否则默认相对路径。
pub fn resolve_data_root(raw: Option<&str>) -> PathBuf {
    raw.map(PathBuf::from).unwrap_or_else(default_data_root)
}

/// 证券代码 → 六位目录名。
pub fn folder_from_code(code: &str) -> String {
    let digits: String = code.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.len() >= 6 {
        digits[digits.len() - 6..].to_string()
    } else {
        format!("{:0>6}", digits)
    }
}

fn parse_date8(raw: &str) -> Result<i32> {
    let s = raw.trim().replace(['-', '/'], "");
    if s.len() != 8 || !s.chars().all(|c| c.is_ascii_digit()) {
        return Err(ChanDataError::msg(format!("日期格式应为 YYYYMMDD: {raw}")));
    }
    Ok(s.parse()?)
}

fn list_tick_paths(folder: &Path, code6: &str, begin8: i32, end8: i32) -> Result<Vec<PathBuf>> {
    if code6.len() != 6 {
        return Err(ChanDataError::msg("证券代码需为 6 位数字"));
    }
    if !folder.is_dir() {
        return Ok(Vec::new());
    }
    let suffix = format!("_{code6}.txt");
    let mut out = Vec::new();
    for entry in std::fs::read_dir(folder)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.ends_with(&suffix) {
            continue;
        }
        let d8 = name
            .split('_')
            .next()
            .and_then(|s| s.parse::<i32>().ok())
            .unwrap_or(0);
        if (begin8..=end8).contains(&d8) {
            out.push((d8, entry.path()));
        }
    }
    out.sort_by_key(|(d, _)| *d);
    Ok(out.into_iter().map(|(_, p)| p).collect())
}

/// 枚举 a_Data 下已有股票目录（六位代码）。
pub fn list_stock_codes(data_root: &Path) -> Result<Vec<String>> {
    if !data_root.is_dir() {
        return Ok(Vec::new());
    }
    let mut codes = Vec::new();
    for entry in std::fs::read_dir(data_root)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if name.len() == 6 && name.chars().all(|c| c.is_ascii_digit()) {
            codes.push(name);
        }
    }
    codes.sort();
    Ok(codes)
}

pub fn load_klines(
    data_root: &Path,
    code: &str,
    begin_date: &str,
    end_date: &str,
    period: KlinePeriod,
) -> Result<Vec<KlineBar>> {
    let code6 = folder_from_code(code);
    let folder = data_root.join(&code6);
    let b8 = parse_date8(begin_date)?;
    let e8 = parse_date8(end_date)?;
    let paths = list_tick_paths(&folder, &code6, b8, e8)?;
    if paths.is_empty() {
        return Err(ChanDataError::msg(format!(
            "未找到离线分笔：{folder:?} 区间 {begin_date}~{end_date}"
        )));
    }
    let mut rows = Vec::new();
    for p in paths {
        rows.extend(read_tick_file(&p)?);
    }
    rows.sort_by_key(|r| r.dt);
    let rows = normalize_native(rows);
    if rows.is_empty() {
        return Err(ChanDataError::msg("分笔文件在日期区间内无有效成交行"));
    }
    let bars_1m = ticks_to_1m(&rows);
    rows_to_period(bars_1m, period)
}

#[derive(Clone)]
struct Bar1m {
    dt: NaiveDateTime,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    volume: f64,
    amount: f64,
}

fn ticks_to_1m(rows: &[TickRow]) -> Vec<Bar1m> {
    // 分钟桶：首价开、末价收、高低扩、量额累加
    let mut buck: BTreeMap<(i32, u32, u32, u32, u32), [f64; 6]> = BTreeMap::new();
    for row in rows {
        let key = (
            row.dt.year(),
            row.dt.month(),
            row.dt.day(),
            row.dt.hour(),
            row.dt.minute(),
        );
        let price = row.price;
        let hi = row.hi();
        let lo = row.lo();
        let vol = row.vol;
        let amt = price * vol;
        buck.entry(key)
            .and_modify(|cur| {
                cur[1] = price;
                cur[2] = cur[2].max(hi);
                cur[3] = cur[3].min(lo);
                cur[4] += vol;
                cur[5] += amt;
            })
            .or_insert([price, price, hi, lo, vol, amt]);
    }
    let mut out = Vec::with_capacity(buck.len());
    for ((y, mo, d, hh, mm), v) in buck {
        let dt = NaiveDate::from_ymd_opt(y, mo, d)
            .and_then(|date| NaiveTime::from_hms_opt(hh, mm, 0).map(|t| NaiveDateTime::new(date, t)))
            .unwrap();
        out.push(Bar1m {
            dt,
            open: v[0],
            high: v[2],
            low: v[3],
            close: v[1],
            volume: v[4],
            amount: v[5],
        });
    }
    out
}

fn merge_bars(bars: &[Bar1m]) -> Bar1m {
    let first = &bars[0];
    let last = &bars[bars.len() - 1];
    Bar1m {
        dt: last.dt,
        open: first.open,
        high: bars.iter().map(|b| b.high).fold(f64::NEG_INFINITY, f64::max),
        low: bars.iter().map(|b| b.low).fold(f64::INFINITY, f64::min),
        close: last.close,
        volume: bars.iter().map(|b| b.volume).sum(),
        amount: bars.iter().map(|b| b.amount).sum(),
    }
}

fn resample_minutes(bars: &[Bar1m], period_m: u32) -> Vec<Bar1m> {
    if period_m <= 1 {
        return bars.to_vec();
    }
    let mut buck: BTreeMap<(i32, u32, u32, u32), Vec<Bar1m>> = BTreeMap::new();
    for b in bars {
        let slot = (b.dt.hour() * 60 + b.dt.minute()) / period_m;
        let key = (b.dt.year(), b.dt.month(), b.dt.day(), slot);
        buck.entry(key).or_default().push(b.clone());
    }
    buck.values()
        .map(|lst| {
            let mut sorted = lst.clone();
            sorted.sort_by_key(|b| b.dt);
            merge_bars(&sorted)
        })
        .collect()
}

fn daily_from_1m(bars: &[Bar1m]) -> Vec<Bar1m> {
    let mut buck: BTreeMap<(i32, u32, u32), Vec<Bar1m>> = BTreeMap::new();
    for b in bars {
        let key = (b.dt.year(), b.dt.month(), b.dt.day());
        buck.entry(key).or_default().push(b.clone());
    }
    let mut out = Vec::new();
    for ((y, mo, d), lst) in buck {
        let mut sorted = lst;
        sorted.sort_by_key(|b| b.dt);
        let mut m = merge_bars(&sorted);
        m.dt = NaiveDate::from_ymd_opt(y, mo, d)
            .and_then(|date| NaiveTime::from_hms_opt(15, 0, 0).map(|t| NaiveDateTime::new(date, t)))
            .unwrap();
        out.push(m);
    }
    out.sort_by_key(|b| b.dt);
    out
}

fn weekly_from_daily(bars: &[Bar1m]) -> Vec<Bar1m> {
    let mut buck: BTreeMap<(i32, u32), Vec<Bar1m>> = BTreeMap::new();
    for b in bars {
        let date = b.dt.date();
        let iso = date.iso_week();
        buck.entry((iso.year(), iso.week())).or_default().push(b.clone());
    }
    buck.values()
        .map(|lst| {
            let mut sorted = lst.clone();
            sorted.sort_by_key(|b| b.dt);
            merge_bars(&sorted)
        })
        .collect()
}

fn monthly_from_daily(bars: &[Bar1m]) -> Vec<Bar1m> {
    let mut buck: BTreeMap<(i32, u32), Vec<Bar1m>> = BTreeMap::new();
    for b in bars {
        buck.entry((b.dt.year(), b.dt.month()))
            .or_default()
            .push(b.clone());
    }
    buck.values()
        .map(|lst| {
            let mut sorted = lst.clone();
            sorted.sort_by_key(|b| b.dt);
            merge_bars(&sorted)
        })
        .collect()
}

fn yearly_from_daily(bars: &[Bar1m]) -> Vec<Bar1m> {
    let mut buck: BTreeMap<i32, Vec<Bar1m>> = BTreeMap::new();
    for b in bars {
        buck.entry(b.dt.year()).or_default().push(b.clone());
    }
    buck.values()
        .map(|lst| {
            let mut sorted = lst.clone();
            sorted.sort_by_key(|b| b.dt);
            merge_bars(&sorted)
        })
        .collect()
}

fn quarterly_from_daily(bars: &[Bar1m]) -> Vec<Bar1m> {
    let mut buck: BTreeMap<(i32, u32), Vec<Bar1m>> = BTreeMap::new();
    for b in bars {
        let q = (b.dt.month() - 1) / 3 + 1;
        buck.entry((b.dt.year(), q)).or_default().push(b.clone());
    }
    buck.values()
        .map(|lst| {
            let mut sorted = lst.clone();
            sorted.sort_by_key(|b| b.dt);
            merge_bars(&sorted)
        })
        .collect()
}

fn rows_to_period(bars_1m: Vec<Bar1m>, period: KlinePeriod) -> Result<Vec<KlineBar>> {
    let bars = if let Some(pm) = period.minute_slot() {
        resample_minutes(&bars_1m, pm)
    } else {
        let daily = daily_from_1m(&bars_1m);
        match period {
            KlinePeriod::Day => daily,
            KlinePeriod::Week => weekly_from_daily(&daily),
            KlinePeriod::Month => monthly_from_daily(&daily),
            KlinePeriod::Year => yearly_from_daily(&daily),
            KlinePeriod::Quarter => quarterly_from_daily(&daily),
            _ => daily,
        }
    };
    Ok(bars
        .into_iter()
        .enumerate()
        .map(|(i, b)| {
            let mut k = bar_to_kline(b);
            k.idx = i as i32;
            k
        })
        .collect())
}

fn bar_to_kline(b: Bar1m) -> KlineBar {
    let time_ms = Utc.from_utc_datetime(&b.dt).timestamp_millis();
    let time_text = format!(
        "{:04}/{:02}/{:02} {:02}:{:02}",
        b.dt.year(),
        b.dt.month(),
        b.dt.day(),
        b.dt.hour(),
        b.dt.minute()
    );
    KlineBar {
        idx: 0,
        time_ms,
        time_text,
        open: b.open,
        high: b.high,
        low: b.low,
        close: b.close,
        volume: b.volume,
        amount: b.amount,
        metrics: serde_json::Map::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_codes_non_empty_when_data_exists() {
        let root = default_data_root();
        if root.is_dir() {
            let codes = list_stock_codes(&root).unwrap();
            assert!(!codes.is_empty());
        }
    }
}
