use chrono::{Duration, NaiveDate, NaiveDateTime, NaiveTime, Timelike};

use crate::error::{ChanDataError, Result};

/// 单条分笔（对齐 Python OfflineTickRow 简化版）。
#[derive(Debug, Clone)]
pub struct TickRow {
    pub dt: NaiveDateTime,
    pub price: f64,
    pub vol: f64,
    pub side: String,
    pub has_bs: bool,
    pub price_lo: Option<f64>,
    pub price_hi: Option<f64>,
    /// 第 4 列成交笔数（`HH:MM 价格 量 笔数 [B/S]`；无列或非法时按 1 笔）
    pub ticks: f64,
}

impl TickRow {
    pub fn lo(&self) -> f64 {
        self.price_lo.unwrap_or(self.price)
    }

    pub fn hi(&self) -> f64 {
        self.price_hi.unwrap_or(self.price)
    }
}

/// 解析 a_Data 分笔行：`HH:MM 价格 成交量 [笔数] [B/S]`
pub fn parse_tick_line(line: &str, y: i32, mo: u32, d: u32) -> Option<TickRow> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    let parts: Vec<&str> = line.split_whitespace().collect();
    if parts.len() < 3 {
        return None;
    }
    if parts[0].contains("时间") || parts[0].starts_with("---") {
        return None;
    }
    let time_parts: Vec<&str> = parts[0].split(':').collect();
    if time_parts.len() != 2 {
        return None;
    }
    let hh: u32 = time_parts[0].parse().ok()?;
    let mm: u32 = time_parts[1].parse().ok()?;
    if hh > 23 || mm > 59 {
        return None;
    }

    let price = parse_float(parts[1])?;
    let vol = parse_float(parts[2])?;
    let mut side = String::new();
    let mut has_bs = false;
    for tok in parts.iter().skip(3) {
        let s = tok.trim().to_ascii_uppercase();
        if s == "B" || s == "S" {
            side = s;
            has_bs = true;
            break;
        }
    }
    // 第 4 列为笔数（B/S 前的那一列）；解析失败（如老文件无列）按 1 笔
    let mut ticks = 1.0;
    if let Some(tok) = parts.get(3) {
        if let Some(v) = parse_float(tok) {
            if v > 0.0 {
                ticks = v;
            }
        }
    }

    let date = NaiveDate::from_ymd_opt(y, mo, d)?;
    let time = NaiveTime::from_hms_opt(hh, mm, 0)?;
    let dt = NaiveDateTime::new(date, time);

    Some(TickRow {
        dt,
        price,
        vol,
        side,
        has_bs,
        price_lo: None,
        price_hi: None,
        ticks,
    })
}

fn parse_float(raw: &str) -> Option<f64> {
  raw.trim().parse::<f64>().ok().filter(|v| v.is_finite())
}

/// 从分笔文件路径解析 YYYYMMDD。
pub fn date_from_filename(path: &std::path::Path) -> Result<(i32, u32, u32)> {
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or_else(|| ChanDataError::msg("无效分笔文件名"))?;
    let d8 = name
        .split('_')
        .next()
        .ok_or_else(|| ChanDataError::msg("无效分笔文件名"))?;
    if d8.len() != 8 || !d8.chars().all(|c| c.is_ascii_digit()) {
        return Err(ChanDataError::msg(format!("无效日期前缀: {d8}")));
    }
    let y: i32 = d8[0..4].parse()?;
    let mo: u32 = d8[4..6].parse()?;
    let d: u32 = d8[6..8].parse()?;
    Ok((y, mo, d))
}

pub fn read_tick_file(path: &std::path::Path) -> Result<Vec<TickRow>> {
    let (y, mo, d) = date_from_filename(path)?;
    let bytes = std::fs::read(path)?;
    let text = decode_tick_bytes(&bytes);
    let mut rows = Vec::new();
    for line in text.lines() {
        if let Some(row) = parse_tick_line(line, y, mo, d) {
            rows.push(row);
        }
    }
    rows.sort_by_key(|r| r.dt);
    Ok(rows)
}

/// 分笔 txt 编码：优先 UTF-8；否则按 GBK（对齐 Python `utf-8, errors=ignore` 可读 GBK 文件）。
fn decode_tick_bytes(bytes: &[u8]) -> String {
    let bytes = strip_utf8_bom(bytes);
    if std::str::from_utf8(bytes).is_ok() {
        // 合法 UTF-8 直接返回
        return String::from_utf8_lossy(bytes).into_owned();
    }
    let (cow, _, _) = encoding_rs::GBK.decode(bytes);
    cow.into_owned()
}

fn strip_utf8_bom(bytes: &[u8]) -> &[u8] {
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        &bytes[3..]
    } else {
        bytes
    }
}

/// 保留无 B/S 分笔（不强行改为 B），让筹码与成交量能区分灰度。
/// 原行为会丢灰度语义。
pub fn normalize_native(mut rows: Vec<TickRow>) -> Vec<TickRow> {
    for r in rows.iter_mut() {
        if !r.has_bs {
            r.side.clear();
        }
    }
    rows
}

fn minute_key(dt: NaiveDateTime) -> (i32, u32, u32, u32, u32) {
    use chrono::Datelike;
    (dt.year(), dt.month(), dt.day(), dt.hour(), dt.minute())
}

/// 同分钟多笔：均分到 60 秒内，保证 time 严格递增、`time_text` 秒位有变化。
/// 旧版用 `+i ms` 会让秒位永远 0，X 轴看起来一整屏 `…:00`，分不出笔序。
/// `n` 笔时序：`base + floor(k * 60000 / n) ms`，n=1 即 0。
pub fn assign_intramute_times(rows: &mut [TickRow]) {
    if rows.is_empty() {
        return;
    }
    let mut i = 0;
    while i < rows.len() {
        let key = minute_key(rows[i].dt);
        let mut j = i + 1;
        while j < rows.len() && minute_key(rows[j].dt) == key {
            j += 1;
        }
        let n = j - i;
        let base = {
            let dt = rows[i].dt;
            NaiveDateTime::new(
                dt.date(),
                NaiveTime::from_hms_opt(dt.hour(), dt.minute(), 0).unwrap_or(dt.time()),
            )
        };
        if n <= 1 {
            rows[i].dt = base;
        } else {
            for k in 0..n {
                let off_ms = (k as i64 * 60_000 / n as i64) as i32;
                rows[i + k].dt = base + Duration::milliseconds(off_ms as i64);
            }
        }
        i = j;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_sample_line() {
        let row = parse_tick_line("09:30\t25.24\t10\t2\tS", 2021, 4, 13).unwrap();
        assert!((row.price - 25.24).abs() < 1e-9);
        assert_eq!(row.side, "S");
        assert!(row.has_bs);
    }

    #[test]
    fn parse_tick_column_ticks() {
        // 带笔数列：第 4 列 10
        let row = parse_tick_line("09:30\t35.10\t60\t10\tB", 2024, 1, 2).unwrap();
        assert!((row.ticks - 10.0).abs() < 1e-9);
        // 集合竞价行：无 B/S 也有笔数
        let row = parse_tick_line("09:25\t35.07\t144\t25", 2024, 1, 2).unwrap();
        assert!((row.ticks - 25.0).abs() < 1e-9);
        assert!(!row.has_bs);
        // 老文件无笔数列：按 1 笔
        let row = parse_tick_line("09:30\t35.10\t60\tB", 2024, 1, 2).unwrap();
        assert!((row.ticks - 1.0).abs() < 1e-9);
    }

    #[test]
    fn decode_gbk_tick_bytes() {
        // GBK 样本：表头含中文，分笔行仍为 ASCII
        let gbk = b"                  20260421 \xb8\xa3\xb6\xf7 (001312)\r\n \xca\xb1\xbc\xe4\t    \xbc\xdb\xb8\xf1\t    \xb3\xc9\xbd\xbb\t\xb1\xca\xca\xfd\t\r\n09:30\t10.50\t100\t1\tB\r\n";
        let text = decode_tick_bytes(gbk);
        let row = parse_tick_line(
            text.lines().find(|l| l.contains("09:30")).unwrap(),
            2026,
            4,
            21,
        )
        .unwrap();
        assert!((row.price - 10.5).abs() < 1e-9);
        assert_eq!(row.side, "B");
    }

    #[test]
    fn assign_intramute_spreads_same_minute() {
        let mk = |price| {
            let mut r = parse_tick_line("09:30\t10.00\t1\t1\tB", 2026, 4, 21).unwrap();
            r.price = price;
            r
        };
        let mut rows = vec![mk(1.0), mk(2.0), mk(3.0)];
        assign_intramute_times(&mut rows);
        // 均分到 60s：0s / 20s / 40s，严格递增且秒位可区分
        assert!(rows[0].dt < rows[1].dt && rows[1].dt < rows[2].dt);
        assert_eq!((rows[1].dt - rows[0].dt).num_milliseconds(), 20_000);
        assert_eq!((rows[2].dt - rows[0].dt).num_milliseconds(), 40_000);
        assert_eq!(rows[0].dt.second(), 0);
        assert_eq!(rows[1].dt.second(), 20);
        assert_eq!(rows[2].dt.second(), 40);
    }

    #[test]
    fn parse_row_without_bs_keeps_empty_side() {
        // 集合竞价行：仅 HH:MM 价格 量 笔数，无 B/S
        let row = parse_tick_line("09:25\t36.51\t10184\t4755", 2026, 4, 21).unwrap();
        assert!(!row.has_bs);
        assert!(row.side.is_empty());
        // normalize_native 不得把无 BS 改成 B（灰度语义来源）
        let rows = normalize_native(vec![row]);
        assert!(rows[0].side.is_empty());
    }
}
