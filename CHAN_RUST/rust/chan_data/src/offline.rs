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

/// 测试股白名单目录（非六位数字代码）。
const TEST_STOCK_FOLDER: &str = "test";

/// 是否允许作为 a_Data 子目录的证券标识。
fn is_allowed_stock_key(key: &str) -> bool {
    (key.len() == 6 && key.chars().all(|c| c.is_ascii_digit())) || key == TEST_STOCK_FOLDER
}

/// 证券代码 → 目录名（六位数字或测试白名单 `test`）。
pub fn folder_from_code(code: &str) -> String {
    let trimmed = code.trim();
    if trimmed.eq_ignore_ascii_case(TEST_STOCK_FOLDER) {
        return TEST_STOCK_FOLDER.to_string();
    }
    let digits: String = trimmed.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.len() >= 6 {
        digits[digits.len() - 6..].to_string()
    } else {
        format!("{:0>6}", digits)
    }
}

#[derive(Clone, Copy)]
enum BoundKind {
    Begin,
    End,
}

/// 解析区间端点：支持 YYYY/MM/DD、YYYY/MM/DD HH:MM、YYYY/MM/DD HH:MM:SS。
fn parse_datetime_bound(raw: &str, kind: BoundKind) -> Result<NaiveDateTime> {
    let s = raw.trim().replace('/', "-");
    if s.is_empty() {
        return Err(ChanDataError::msg("日期不能为空"));
    }
    for fmt in ["%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"] {
        if let Ok(dt) = NaiveDateTime::parse_from_str(&s, fmt) {
            return Ok(dt);
        }
    }
    let date_part = if s.len() >= 10 { &s[..10] } else { s.as_str() };
    if let Ok(d) = NaiveDate::parse_from_str(date_part, "%Y-%m-%d") {
        let time = match kind {
            BoundKind::Begin => NaiveTime::from_hms_opt(0, 0, 0).unwrap(),
            BoundKind::End => NaiveTime::from_hms_opt(23, 59, 59).unwrap(),
        };
        return Ok(NaiveDateTime::new(d, time));
    }
    let compact = s.replace('-', "");
    if compact.len() == 8 && compact.chars().all(|c| c.is_ascii_digit()) {
        let y: i32 = compact[0..4].parse()?;
        let mo: u32 = compact[4..6].parse()?;
        let d: u32 = compact[6..8].parse()?;
        let date = NaiveDate::from_ymd_opt(y, mo, d)
            .ok_or_else(|| ChanDataError::msg(format!("非法日期: {raw}")))?;
        let time = match kind {
            BoundKind::Begin => NaiveTime::from_hms_opt(0, 0, 0).unwrap(),
            BoundKind::End => NaiveTime::from_hms_opt(23, 59, 59).unwrap(),
        };
        return Ok(NaiveDateTime::new(date, time));
    }
    Err(ChanDataError::msg(format!(
        "日期格式应为 YYYY/MM/DD 或 YYYY/MM/DD HH:MM:SS: {raw}"
    )))
}

fn date8_from_datetime(dt: NaiveDateTime) -> i32 {
    dt.year() * 10000 + (dt.month() as i32) * 100 + dt.day() as i32
}

fn list_tick_paths(folder: &Path, code_key: &str, begin8: i32, end8: i32) -> Result<Vec<PathBuf>> {
    if !is_allowed_stock_key(code_key) {
        return Err(ChanDataError::msg("证券代码需为 6 位数字或 test"));
    }
    if !folder.is_dir() {
        return Ok(Vec::new());
    }
    let suffix = format!("_{code_key}.txt");
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

/// 枚举 a_Data 下已有股票目录（六位代码 + 测试目录 `test`）。
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
        if is_allowed_stock_key(&name) {
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
    let code_key = folder_from_code(code);
    let folder = data_root.join(&code_key);
    let begin_dt = parse_datetime_bound(begin_date, BoundKind::Begin)?;
    let end_dt = parse_datetime_bound(end_date, BoundKind::End)?;
    if end_dt < begin_dt {
        return Err(ChanDataError::msg(format!(
            "结束时间不能早于开始时间：{begin_date}~{end_date}"
        )));
    }
    let b8 = date8_from_datetime(begin_dt);
    let e8 = date8_from_datetime(end_dt);
    let paths = list_tick_paths(&folder, &code_key, b8, e8)?;
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
    let mut rows = normalize_native(rows);
    rows.retain(|r| r.dt >= begin_dt && r.dt <= end_dt);
    if rows.is_empty() {
        return Err(ChanDataError::msg("分笔文件在日期区间内无有效成交行"));
    }
    let bars_1m = ticks_to_1m(&rows);
    let bars = rows_to_period(bars_1m, period)?;
    let bars = filter_bars_by_datetime(bars, begin_dt, end_dt);
    if bars.is_empty() {
        return Err(ChanDataError::msg(format!(
            "区间内无 K 线：{begin_date}~{end_date}"
        )));
    }
    Ok(bars)
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

fn filter_bars_by_datetime(
    bars: Vec<KlineBar>,
    begin_dt: NaiveDateTime,
    end_dt: NaiveDateTime,
) -> Vec<KlineBar> {
    let begin_ms = Utc.from_utc_datetime(&begin_dt).timestamp_millis();
    let end_ms = Utc.from_utc_datetime(&end_dt).timestamp_millis();
    bars.into_iter()
        .filter(|b| b.time_ms >= begin_ms && b.time_ms <= end_ms)
        .enumerate()
        .map(|(i, mut b)| {
            b.idx = i as i32;
            b
        })
        .collect()
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
    fn parse_datetime_bound_supports_seconds() {
        let begin = parse_datetime_bound("2004/06/25 09:30:15", BoundKind::Begin).unwrap();
        assert_eq!(begin.hour(), 9);
        assert_eq!(begin.minute(), 30);
        assert_eq!(begin.second(), 15);

        let end = parse_datetime_bound("2004/07/29", BoundKind::End).unwrap();
        assert_eq!(end.hour(), 23);
        assert_eq!(end.minute(), 59);
        assert_eq!(end.second(), 59);
    }

    #[test]
    fn filter_bars_by_datetime_trims_edges() {
        let mk = |h, m| {
            let dt = NaiveDate::from_ymd_opt(2004, 6, 25)
                .and_then(|d| NaiveTime::from_hms_opt(h, m, 0).map(|t| NaiveDateTime::new(d, t)))
                .unwrap();
            bar_to_kline(Bar1m {
                dt,
                open: 1.0,
                high: 1.0,
                low: 1.0,
                close: 1.0,
                volume: 1.0,
                amount: 1.0,
            })
        };
        let bars = vec![mk(9, 30), mk(10, 0), mk(10, 30)];
        let begin = parse_datetime_bound("2004/06/25 09:45:00", BoundKind::Begin).unwrap();
        let end = parse_datetime_bound("2004/06/25 10:15:00", BoundKind::End).unwrap();
        let out = filter_bars_by_datetime(bars, begin, end);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].time_text, "2004/06/25 10:00");
    }

    #[test]
    fn list_codes_non_empty_when_data_exists() {
        let root = default_data_root();
        if root.is_dir() {
            let codes = list_stock_codes(&root).unwrap();
            assert!(!codes.is_empty());
        }
    }

    #[test]
    fn load_test_stock_four_1m_bars() {
        let root = default_data_root();
        let test_dir = root.join(TEST_STOCK_FOLDER);
        if !test_dir.is_dir() {
            return;
        }
        let codes = list_stock_codes(&root).unwrap();
        assert!(codes.iter().any(|c| c == TEST_STOCK_FOLDER));

        let bars = load_klines(
            &root,
            TEST_STOCK_FOLDER,
            "2026/07/10 09:30:00",
            "2026/07/10 09:33:59",
            KlinePeriod::M1,
        )
        .unwrap();
        assert_eq!(bars.len(), 4);
        let ohlc: Vec<(f64, f64, f64, f64)> = bars
            .iter()
            .map(|b| (b.open, b.high, b.low, b.close))
            .collect();
        assert_eq!(
            ohlc,
            vec![(3.0, 4.0, 3.0, 4.0), (2.0, 3.0, 2.0, 3.0), (3.0, 4.0, 3.0, 4.0), (1.0, 4.0, 1.0, 4.0)]
        );
    }
}
