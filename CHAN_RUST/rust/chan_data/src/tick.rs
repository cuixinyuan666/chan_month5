use chrono::{NaiveDate, NaiveDateTime, NaiveTime};

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

/// 无 B/S 分笔默认按 B 处理（native 模式）。
pub fn normalize_native(mut rows: Vec<TickRow>) -> Vec<TickRow> {
    for r in rows.iter_mut() {
        if !r.has_bs {
            r.side = "B".into();
        }
    }
    rows
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
}
