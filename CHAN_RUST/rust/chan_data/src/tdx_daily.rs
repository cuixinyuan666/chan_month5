//! 通达信 2026-09 新版行情协议：证券列表 + 历史日线（全市场导出用）。
//!
//! 背景：2026-09-10 起服务端拒绝旧 pytdx 版本标识 `0x01016408`，
//! 历史 K 线请求需改用抓包版本标识 `0x01007b18`（字节 `18 7b 00 01`），
//! 且 vol/amount 由旧的 u32 改为 f32。本模块只做「取数」，不改任何缠论计算口径。
//!
//! 与 `tdx.rs`（分笔 0x0fc6）并存：分笔链路仍走原实现，互不影响。

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

use flate2::read::ZlibDecoder;
use chrono::NaiveDate;

use crate::error::{ChanDataError, Result};
use crate::tick::TickRow;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(6);
const IO_TIMEOUT: Duration = Duration::from_secs(12);

/// 单次 K 线请求上限（协议限制 800）。
pub const BARS_PAGE: u16 = 800;
/// 证券列表单页条数。
pub const LIST_PAGE: u16 = 1000;

const INIT_PKG: &str = "0c0218940001030003000d0001";
const AUTH_PKG: &str = "0c031899000120002000db0f7464786c6576656c000000295cf740110000000000000000000000000005";
const VERSION_FLAG: u32 = 0x0100_7B18;

/// 一条日线（不复权，与通达信日线口径一致）。
#[derive(Clone, Debug)]
pub struct DailyBar {
    /// 交易日 YYYYMMDD。
    pub date: i32,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    /// 成交量（手，股票口径）。
    pub volume: f64,
    /// 成交额（元）。
    pub amount: f64,
}

/// 证券列表条目。
#[derive(Clone, Debug)]
pub struct SecurityInfo {
    pub code: String,
    pub name: String,
    pub market: u16,
}

/// 代码 → 通达信市场号（0 深、1 沪、2 北）。
pub fn market_of_code(code: &str) -> u16 {
    match code.as_bytes().first().copied().unwrap_or(b'0') {
        b'5' | b'6' | b'9' => 1,
        b'8' | b'4' => 2,
        _ => 0,
    }
}

/// 是否 A 股正股（按市场 + 代码前缀过滤，排除基金/债券/指数/B 股）。
pub fn is_a_share(market: u16, code: &str) -> bool {
    let c = code.as_bytes();
    if c.len() != 6 {
        return false;
    }
    match market {
        // 深市：主板 000/001/002/003，创业板 300/301
        0 => code.starts_with("00") || code.starts_with("30"),
        // 沪市：主板 600/601/603/605，科创板 688/689
        1 => code.starts_with("60") || code.starts_with("68"),
        // 北交所：43/83/87/88/92
        2 => code.starts_with('4') || code.starts_with('8') || code.starts_with("92"),
        _ => false,
    }
}

/// 一个已认证的通达信会话。
pub struct TdxSession {
    stream: TcpStream,
}

impl TdxSession {
    /// 连接并完成 0c02 初始化 + 0c03 tdxlevel 认证。
    pub fn connect(host: &str) -> Result<Self> {
        let addr: SocketAddr = format!("{host}:7709")
            .parse()
            .map_err(|e| ChanDataError::msg(format!("行情地址无效 {host}: {e}")))?;
        let stream = TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT)
            .map_err(|e| ChanDataError::msg(format!("连接通达信行情失败 {host}: {e}")))?;
        stream.set_read_timeout(Some(IO_TIMEOUT))?;
        stream.set_write_timeout(Some(IO_TIMEOUT))?;
        stream.set_nodelay(true)?;
        let mut s = Self { stream };
        s.send_recv(&hex_bytes(INIT_PKG)?)?;
        s.send_recv(&hex_bytes(AUTH_PKG)?)?;
        Ok(s)
    }

    /// 发送一个请求包，返回解压后的响应体（不含 16 字节帧头）。
    fn send_recv(&mut self, pkg: &[u8]) -> Result<Vec<u8>> {
        self.stream.write_all(pkg)?;
        self.stream.flush()?;
        let mut head = [0u8; 16];
        self.stream
            .read_exact(&mut head)
            .map_err(|e| ChanDataError::msg(format!("行情应答头读取失败: {e}")))?;
        let zipsize = u16::from_le_bytes([head[12], head[13]]) as usize;
        let unzipsize = u16::from_le_bytes([head[14], head[15]]) as usize;
        if zipsize == 0 {
            return Ok(Vec::new());
        }
        let mut body = vec![0u8; zipsize];
        self.stream
            .read_exact(&mut body)
            .map_err(|e| ChanDataError::msg(format!("行情应答体读取失败: {e}")))?;
        if zipsize == unzipsize {
            return Ok(body);
        }
        let mut dec = ZlibDecoder::new(&body[..]);
        let mut out = Vec::with_capacity(unzipsize.max(1024));
        dec.read_to_end(&mut out)
            .map_err(|e| ChanDataError::msg(format!("行情解压失败: {e}")))?;
        Ok(out)
    }

    /// 拉取某市场某交易日的分笔（0x0fc6，带笔数与买卖方向）。
    pub fn day_ticks(&mut self, market: u16, code: &str, date8: i32) -> Result<Vec<TickRow>> {
        let date = NaiveDate::from_ymd_opt(
            date8 / 10000,
            (date8 / 100 % 100) as u32,
            (date8 % 100) as u32,
        )
        .ok_or_else(|| ChanDataError::msg(format!("非法日期 {date8}")))?;
        let mut all: Vec<TickRow> = Vec::new();
        let mut start: u16 = 0;
        loop {
            let pkg = crate::tdx::history_pkg(market, code, date8 as u32, start, 800);
            let body = self.send_recv(&pkg)?;
            let page = crate::tdx::parse_history_c6(&body, date)?;
            if page.is_empty() {
                break;
            }
            let n = page.len() as u16;
            all.extend(page);
            if n < 800 || start > 40000 {
                break;
            }
            start = start.saturating_add(n);
        }
        all.sort_by_key(|r| r.dt);
        Ok(all)
    }

    /// 拉取某市场全部证券（分页）。
    pub fn security_list(&mut self, market: u16) -> Result<Vec<SecurityInfo>> {
        let mut out = Vec::new();
        let mut start: u16 = 0;
        loop {
            let pkg = list_pkg(market, start);
            let body = self.send_recv(&pkg)?;
            if body.len() < 2 {
                break;
            }
            let num = u16::from_le_bytes([body[0], body[1]]) as usize;
            if num == 0 {
                break;
            }
            let mut pos = 2usize;
            for _ in 0..num {
                if pos + 29 > body.len() {
                    break;
                }
                let rec = &body[pos..pos + 29];
                pos += 29;
                let code = String::from_utf8_lossy(&rec[0..6]).trim().to_string();
                let name_bytes = &rec[8..16];
                let (name, _, _) = encoding_rs::GBK.decode(name_bytes);
                let name = name.trim_end_matches('\0').trim().to_string();
                if !code.is_empty() {
                    out.push(SecurityInfo {
                        code,
                        name,
                        market,
                    });
                }
            }
            if num < LIST_PAGE as usize {
                break;
            }
            start = match start.checked_add(LIST_PAGE) {
                Some(v) => v,
                None => break,
            };
        }
        Ok(out)
    }

    /// 拉取单只证券的日线全历史（按时间升序）。
    ///
    /// `start` 从最新一根往回计数，因此逐页加大直到返回不足一页为止。
    pub fn daily_bars(&mut self, market: u16, code: &str, max_bars: usize) -> Result<Vec<DailyBar>> {
        let mut pages: Vec<Vec<DailyBar>> = Vec::new();
        let mut start: u16 = 0;
        let mut total = 0usize;
        loop {
            let pkg = bars_pkg(market, code, 9, start, BARS_PAGE)?;
            let body = self.send_recv(&pkg)?;
            if body.len() < 2 {
                break;
            }
            let page = parse_bars(&body, 9)?;
            if page.is_empty() {
                break;
            }
            let n = page.len();
            total += n;
            pages.push(page);
            if n < BARS_PAGE as usize || total >= max_bars {
                break;
            }
            start = match start.checked_add(BARS_PAGE) {
                Some(v) => v,
                None => break,
            };
        }
        let mut bars: Vec<DailyBar> = pages.into_iter().rev().flatten().collect();
        if bars.len() > max_bars {
            let keep = bars.len() - max_bars;
            bars.drain(0..keep);
        }
        bars.sort_by_key(|b| b.date);
        bars.dedup_by_key(|b| b.date);
        Ok(bars)
    }
}

fn list_pkg(market: u16, start: u16) -> Vec<u8> {
    let mut pkg = hex_bytes("0c0118640101060006005004").unwrap_or_default();
    pkg.extend_from_slice(&market.to_le_bytes());
    pkg.extend_from_slice(&start.to_le_bytes());
    pkg
}

fn bars_pkg(market: u16, code: &str, category: u16, start: u16, count: u16) -> Result<Vec<u8>> {
    if code.len() != 6 || !code.chars().all(|c| c.is_ascii_digit()) {
        return Err(ChanDataError::msg(format!("证券代码需为 6 位数字: {code}")));
    }
    let mut pkg = Vec::with_capacity(38);
    pkg.extend_from_slice(&0x010cu16.to_le_bytes());
    pkg.extend_from_slice(&VERSION_FLAG.to_le_bytes());
    pkg.extend_from_slice(&0x1cu16.to_le_bytes());
    pkg.extend_from_slice(&0x1cu16.to_le_bytes());
    pkg.extend_from_slice(&0x052du16.to_le_bytes());
    pkg.extend_from_slice(&market.to_le_bytes());
    pkg.extend_from_slice(code.as_bytes());
    pkg.extend_from_slice(&category.to_le_bytes());
    pkg.extend_from_slice(&1u16.to_le_bytes());
    pkg.extend_from_slice(&start.to_le_bytes());
    pkg.extend_from_slice(&count.to_le_bytes());
    pkg.extend_from_slice(&0u32.to_le_bytes());
    pkg.extend_from_slice(&0u32.to_le_bytes());
    pkg.extend_from_slice(&0u16.to_le_bytes());
    Ok(pkg)
}

fn parse_bars(body: &[u8], category: u16) -> Result<Vec<DailyBar>> {
    if body.len() < 2 {
        return Ok(Vec::new());
    }
    let ret_count = u16::from_le_bytes([body[0], body[1]]) as usize;
    let mut pos = 2usize;
    let mut out = Vec::with_capacity(ret_count);
    let mut pre: i64 = 0;
    for _ in 0..ret_count {
        if pos + 4 > body.len() {
            break;
        }
        let raw_date = u32::from_le_bytes([body[pos], body[pos + 1], body[pos + 2], body[pos + 3]]);
        pos += 4;
        let date = if category < 4 || category == 7 || category == 8 {
            // 分钟线：压缩日期，本模块暂不使用
            let y = (raw_date >> 16 >> 11) + 2004;
            let md = (raw_date >> 16) % 2048;
            (y * 10000 + (md / 100) * 100 + md % 100) as i32
        } else {
            raw_date as i32
        };
        let (od, p) = get_price(body, pos)?;
        pos = p;
        let (cd, p) = get_price(body, pos)?;
        pos = p;
        let (hd, p) = get_price(body, pos)?;
        pos = p;
        let (ld, p) = get_price(body, pos)?;
        pos = p;
        if pos + 8 > body.len() {
            break;
        }
        let vol = f32::from_le_bytes([body[pos], body[pos + 1], body[pos + 2], body[pos + 3]]) as f64;
        pos += 4;
        let amt = f32::from_le_bytes([body[pos], body[pos + 1], body[pos + 2], body[pos + 3]]) as f64;
        pos += 4;
        let o = od + pre;
        let c = o + cd;
        let h = o + hd;
        let l = o + ld;
        pre = c;
        out.push(DailyBar {
            date,
            open: o as f64 / 1000.0,
            high: h as f64 / 1000.0,
            low: l as f64 / 1000.0,
            close: c as f64 / 1000.0,
            volume: vol,
            amount: amt,
        });
    }
    Ok(out)
}

fn get_price(data: &[u8], mut pos: usize) -> Result<(i64, usize)> {
    if pos >= data.len() {
        return Err(ChanDataError::msg("K 线价量字段不足"));
    }
    let mut b = data[pos] as i64;
    let mut intdata = b & 0x3f;
    let sign = (b & 0x40) != 0;
    if (b & 0x80) != 0 {
        let mut shift = 6;
        loop {
            pos += 1;
            if pos >= data.len() {
                return Err(ChanDataError::msg("K 线变长价格中断"));
            }
            b = data[pos] as i64;
            intdata += (b & 0x7f) << shift;
            shift += 7;
            if (b & 0x80) == 0 {
                break;
            }
        }
    }
    pos += 1;
    if sign {
        intdata = -intdata;
    }
    Ok((intdata, pos))
}

fn hex_bytes(s: &str) -> Result<Vec<u8>> {
    let clean: String = s.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    if clean.len() % 2 != 0 {
        return Err(ChanDataError::msg("请求包长度错误"));
    }
    let mut out = Vec::with_capacity(clean.len() / 2);
    let bytes = clean.as_bytes();
    for i in (0..bytes.len()).step_by(2) {
        let hi = from_hex(bytes[i])?;
        let lo = from_hex(bytes[i + 1])?;
        out.push((hi << 4) | lo);
    }
    Ok(out)
}

fn from_hex(b: u8) -> Result<u8> {
    match b {
        b'0'..=b'9' => Ok(b - b'0'),
        b'a'..=b'f' => Ok(b - b'a' + 10),
        b'A'..=b'F' => Ok(b - b'A' + 10),
        _ => Err(ChanDataError::msg("请求包不是十六进制")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_share_filter() {
        assert!(is_a_share(0, "000001"));
        assert!(is_a_share(0, "002003"));
        assert!(is_a_share(0, "300750"));
        assert!(!is_a_share(0, "159915")); // 深市 ETF
        assert!(is_a_share(1, "600519"));
        assert!(is_a_share(1, "688687"));
        assert!(!is_a_share(1, "510300")); // 沪市 ETF
        assert!(!is_a_share(1, "900901")); // B 股
        assert!(is_a_share(2, "920992"));
    }

    #[test]
    fn bars_pkg_layout() {
        let p = bars_pkg(0, "000001", 9, 0, 800).unwrap();
        assert_eq!(p.len(), 38);
        assert_eq!(&p[0..2], &[0x0c, 0x01]);
        assert_eq!(&p[2..6], &[0x18, 0x7b, 0x00, 0x01]);
        assert_eq!(&p[10..12], &[0x2d, 0x05]);
    }

    #[test]
    fn price_varint_roundtrip() {
        // 单字节：正 5
        let (v, pos) = get_price(&[5], 0).unwrap();
        assert_eq!((v, pos), (5, 1));
        // 单字节：负 5（0x45）
        let (v, _) = get_price(&[0x45], 0).unwrap();
        assert_eq!(v, -5);
    }
}
