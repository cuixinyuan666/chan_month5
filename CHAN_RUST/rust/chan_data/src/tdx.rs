//! 通达信行情协议（7709）拉历史分笔。
//! 走带笔数的增强指令；结果按日缓存，不读旧的导出 txt 当权威。

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use chrono::{Datelike, NaiveDate, NaiveDateTime, NaiveTime, Timelike, Weekday};
use flate2::read::ZlibDecoder;

use crate::error::{ChanDataError, Result};
use crate::tick::{read_tick_file, TickRow};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(6);
const IO_TIMEOUT: Duration = Duration::from_secs(12);
const PAGE: u16 = 800;

const HOSTS: &[(&str, u16)] = &[
    ("180.153.18.170", 7709),
    ("115.238.56.198", 7709),
    ("180.153.18.171", 7709),
    ("218.108.98.244", 7709),
    ("124.160.88.183", 7709),
];

static LAST_OK: Mutex<Option<(String, u16)>> = Mutex::new(None);

fn cache_dir(data_root: &Path, code: &str) -> PathBuf {
    data_root.join(".tdx_protocol_cache").join(code)
}

fn cache_path(data_root: &Path, code: &str, date8: i32) -> PathBuf {
    cache_dir(data_root, code).join(format!("{date8}_{code}.txt"))
}

/// 六位代码 → 通达信市场号：0 深、1 沪、2 北。
pub fn market_of_code(code: &str) -> u16 {
    match code.as_bytes().first().copied().unwrap_or(b'0') {
        b'5' | b'6' | b'9' => 1,
        b'8' | b'4' => 2,
        _ => 0,
    }
}

/// 拉 [begin,end] 闭区间内交易日分笔（跳过周末；无数据的日子跳过）。
/// 全日已在缓存里时不连行情服务器。
pub fn load_protocol_ticks(
    data_root: &Path,
    code: &str,
    begin_dt: NaiveDateTime,
    end_dt: NaiveDateTime,
) -> Result<Vec<TickRow>> {
    let code = folder_code(code)?;
    let mut client: Option<TdxClient> = None;
    let mut rows = Vec::new();
    let mut d = begin_dt.date();
    let last = end_dt.date();
    while d <= last {
        if d.weekday() != Weekday::Sat && d.weekday() != Weekday::Sun {
            let date8 = d.year() * 10000 + d.month() as i32 * 100 + d.day() as i32;
            let day_rows = load_one_day(&mut client, data_root, &code, date8)?;
            rows.extend(day_rows);
        }
        d = d
            .succ_opt()
            .ok_or_else(|| ChanDataError::msg("日期溢出"))?;
    }
    Ok(rows)
}

fn folder_code(code: &str) -> Result<String> {
    let digits: String = code.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.len() >= 6 {
        Ok(digits[digits.len() - 6..].to_string())
    } else if digits.is_empty() {
        Err(ChanDataError::msg("证券代码需为 6 位数字"))
    } else {
        Ok(format!("{:0>6}", digits))
    }
}

fn ensure_client(client: &mut Option<TdxClient>) -> Result<&mut TdxClient> {
    if client.is_none() {
        *client = Some(TdxClient::connect()?);
    }
    Ok(client.as_mut().expect("刚连上"))
}

fn fetch_history_day(client: &mut TdxClient, code: &str, date8: i32) -> Result<Vec<TickRow>> {
    let mkt = market_of_code(code);
    let mut ticks = client.history_day(mkt, code, date8)?;
    if ticks.is_empty() && mkt != 0 {
        // 北交所偶发市场号不对：再试深/沪
        ticks = client.history_day(0, code, date8)?;
        if ticks.is_empty() {
            ticks = client.history_day(1, code, date8)?;
        }
    }
    Ok(ticks)
}

fn load_one_day(
    client: &mut Option<TdxClient>,
    data_root: &Path,
    code: &str,
    date8: i32,
) -> Result<Vec<TickRow>> {
    let path = cache_path(data_root, code, date8);
    if path.is_file() {
        return read_tick_file(&path);
    }
    let ticks = match fetch_history_day(ensure_client(client)?, code, date8) {
        Ok(t) => t,
        Err(_) => {
            *client = Some(TdxClient::connect()?);
            fetch_history_day(ensure_client(client)?, code, date8)?
        }
    };
    if ticks.is_empty() {
        return Ok(Vec::new());
    }
    write_cache(&path, date8, code, &ticks)?;
    Ok(ticks)
}

fn write_cache(path: &Path, date8: i32, code: &str, ticks: &[TickRow]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut out = String::new();
    out.push_str(&format!("                  {date8} ({code})\n"));
    out.push_str(" 时间\t    价格\t    成交\t笔数\t\n");
    for t in ticks {
        let hhmm = t.dt.format("%H:%M");
        if t.has_bs && (t.side.eq_ignore_ascii_case("B") || t.side.eq_ignore_ascii_case("S")) {
            out.push_str(&format!(
                "{hhmm}\t{:.4}\t{}\t{}\t{}\n",
                t.price,
                t.vol,
                t.ticks,
                t.side.to_ascii_uppercase()
            ));
        } else {
            out.push_str(&format!(
                "{hhmm}\t{:.4}\t{}\t{}\t\n",
                t.price, t.vol, t.ticks
            ));
        }
    }
    out.push_str("#数据来源:通达信协议\n");
    std::fs::write(path, out)?;
    Ok(())
}

struct TdxClient {
    stream: TcpStream,
}

impl TdxClient {
    fn connect() -> Result<Self> {
        let mut order: Vec<(String, u16)> = HOSTS
            .iter()
            .map(|(h, p)| ((*h).to_string(), *p))
            .collect();
        if let Ok(g) = LAST_OK.lock() {
            if let Some((h, p)) = g.clone() {
                order.retain(|x| x.0 != h || x.1 != p);
                order.insert(0, (h, p));
            }
        }
        let mut last_err = ChanDataError::msg("通达信行情服务器均无法连接");
        for (host, port) in order {
            match Self::connect_one(&host, port) {
                Ok(c) => {
                    if let Ok(mut g) = LAST_OK.lock() {
                        *g = Some((host, port));
                    }
                    return Ok(c);
                }
                Err(e) => last_err = e,
            }
        }
        Err(last_err)
    }

    fn connect_one(host: &str, port: u16) -> Result<Self> {
        let addr = format!("{host}:{port}");
        let sock: std::net::SocketAddr = addr.parse().map_err(|e| {
            ChanDataError::msg(format!("行情地址无效 {addr}: {e}"))
        })?;
        let stream = TcpStream::connect_timeout(&sock, CONNECT_TIMEOUT)
        .map_err(|e| ChanDataError::msg(format!("连接通达信行情失败 {addr}: {e}")))?;
        stream.set_read_timeout(Some(IO_TIMEOUT))?;
        stream.set_write_timeout(Some(IO_TIMEOUT))?;
        stream.set_nodelay(true)?;
        let mut c = Self { stream };
        c.setup()?;
        Ok(c)
    }

    fn setup(&mut self) -> Result<()> {
        // 与 pytdx SetupCmd1/2/3 相同的握手包
        let cmd1 = hex_bytes("0c0218930001030003000d0001")?;
        let cmd2 = hex_bytes("0c0218940001030003000d0002")?;
        let cmd3 = hex_bytes(
            "0c031899000120002000db0fd5d0c9ccd6a4a8af0000008fc22540130000d500c9ccbdf0d7ea00000002",
        )?;
        let _ = self.send_recv(&cmd1)?;
        let _ = self.send_recv(&cmd2)?;
        let _ = self.send_recv(&cmd3)?;
        Ok(())
    }

    fn send_recv(&mut self, pkg: &[u8]) -> Result<Vec<u8>> {
        self.stream.write_all(pkg)?;
        self.stream.flush()?;
        let mut head = [0u8; 16];
        self.stream.read_exact(&mut head).map_err(|e| {
            ChanDataError::msg(format!("行情应答头读取失败: {e}"))
        })?;
        let zipsize = u16::from_le_bytes([head[12], head[13]]) as usize;
        let unzipsize = u16::from_le_bytes([head[14], head[15]]) as usize;
        if zipsize == 0 {
            return Ok(Vec::new());
        }
        let mut body = vec![0u8; zipsize];
        self.stream.read_exact(&mut body).map_err(|e| {
            ChanDataError::msg(format!("行情应答体读取失败: {e}"))
        })?;
        if zipsize == unzipsize {
            return Ok(body);
        }
        let mut dec = ZlibDecoder::new(&body[..]);
        let mut out = Vec::with_capacity(unzipsize);
        dec.read_to_end(&mut out)
            .map_err(|e| ChanDataError::msg(format!("行情解压失败: {e}")))?;
        Ok(out)
    }

    fn history_day(&mut self, market: u16, code: &str, date8: i32) -> Result<Vec<TickRow>> {
        let mut all: Vec<(u32, TickRow)> = Vec::new();
        let mut start: u16 = 0;
        let date = NaiveDate::from_ymd_opt(date8 / 10000, (date8 / 100 % 100) as u32, (date8 % 100) as u32)
            .ok_or_else(|| ChanDataError::msg(format!("非法日期 {date8}")))?;
        loop {
            let pkg = history_pkg(market, code, date8 as u32, start, PAGE);
            let body = self.send_recv(&pkg)?;
            let page = parse_history_c6(&body, date)?;
            if page.is_empty() {
                break;
            }
            let n = page.len() as u16;
            for row in page {
                let key = row.dt.hour() * 60 + row.dt.minute();
                all.push((key, row));
            }
            if n < PAGE {
                break;
            }
            start = start.saturating_add(n);
            if start > 40000 {
                break;
            }
        }
        all.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(all.into_iter().map(|(_, r)| r).collect())
    }
}

/// 带笔数的历史分笔（命令 0x0fc6）。
fn history_pkg(market: u16, code: &str, date: u32, start: u16, count: u16) -> Vec<u8> {
    let mut pkg = hex_bytes("0c013002020112001200c60f").unwrap_or_default();
    pkg.extend_from_slice(&date.to_le_bytes());
    pkg.extend_from_slice(&market.to_le_bytes());
    let mut code6 = [0u8; 6];
    let raw = code.as_bytes();
    let n = raw.len().min(6);
    code6[..n].copy_from_slice(&raw[..n]);
    pkg.extend_from_slice(&code6);
    pkg.extend_from_slice(&start.to_le_bytes());
    pkg.extend_from_slice(&count.to_le_bytes());
    pkg
}

fn parse_history_c6(body: &[u8], date: NaiveDate) -> Result<Vec<TickRow>> {
    if body.len() < 6 {
        return Ok(Vec::new());
    }
    let num = u16::from_le_bytes([body[0], body[1]]) as usize;
    let mut pos = 6;
    let mut last_price: i64 = 0;
    let mut out = Vec::with_capacity(num);
    for _ in 0..num {
        let (hour, minute, p) = match get_time(body, pos) {
            Ok(v) => v,
            Err(_) => break,
        };
        pos = p;
        let (price_raw, p) = match get_price(body, pos) {
            Ok(v) => v,
            Err(_) => break,
        };
        pos = p;
        let (vol, p) = match get_price(body, pos) {
            Ok(v) => v,
            Err(_) => break,
        };
        pos = p;
        let (num_ticks, p) = match get_price(body, pos) {
            Ok(v) => v,
            Err(_) => break,
        };
        pos = p;
        let (buyorsell, p) = match get_price(body, pos) {
            Ok(v) => v,
            Err(_) => break,
        };
        pos = p;
        let (_, p) = match get_price(body, pos) {
            Ok(v) => v,
            Err(_) => break,
        };
        pos = p;
        last_price += price_raw;
        if hour > 23 || minute > 59 {
            continue;
        }
        let Some(time) = NaiveTime::from_hms_opt(hour, minute, 0) else {
            continue;
        };
        let (side, has_bs) = match buyorsell {
            0 => ("B".to_string(), true),
            1 => ("S".to_string(), true),
            _ => (String::new(), false),
        };
        out.push(TickRow {
            dt: NaiveDateTime::new(date, time),
            price: last_price as f64 / 100.0,
            vol: vol as f64,
            side,
            has_bs,
            price_lo: None,
            price_hi: None,
            ticks: num_ticks.max(0) as f64,
        });
    }
    Ok(out)
}

fn get_time(data: &[u8], pos: usize) -> Result<(u32, u32, usize)> {
    if pos + 2 > data.len() {
        return Err(ChanDataError::msg("分笔时间字段不足"));
    }
    let tminutes = u16::from_le_bytes([data[pos], data[pos + 1]]) as u32;
    Ok((tminutes / 60, tminutes % 60, pos + 2))
}

/// 通达信变长有符号整数（与 pytdx get_price 同口径）。
fn get_price(data: &[u8], mut pos: usize) -> Result<(i64, usize)> {
    if pos >= data.len() {
        return Err(ChanDataError::msg("分笔价量字段不足"));
    }
    let mut bdata = data[pos] as i64;
    let mut intdata = bdata & 0x3f;
    let sign = (bdata & 0x40) != 0;
    if (bdata & 0x80) != 0 {
        let mut shift = 6;
        loop {
            pos += 1;
            if pos >= data.len() {
                return Err(ChanDataError::msg("分笔价量变长中断"));
            }
            bdata = data[pos] as i64;
            intdata += (bdata & 0x7f) << shift;
            shift += 7;
            if (bdata & 0x80) == 0 {
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
        return Err(ChanDataError::msg("握手包长度错误"));
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
        _ => Err(ChanDataError::msg("握手包不是十六进制")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn market_sh_sz() {
        assert_eq!(market_of_code("000001"), 0);
        assert_eq!(market_of_code("002003"), 0);
        assert_eq!(market_of_code("600519"), 1);
        assert_eq!(market_of_code("688687"), 1);
    }

    #[test]
    fn history_pkg_len() {
        let p = history_pkg(0, "002003", 20180110, 0, 800);
        // 12 头 + 4 date + 2 market + 6 code + 2 start + 2 count
        assert_eq!(p.len(), 28);
    }

    #[test]
    fn protocol_cache_hits_without_network() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let dt = NaiveDate::from_ymd_opt(2018, 1, 10)
            .unwrap()
            .and_hms_opt(9, 30, 0)
            .unwrap();
        let ticks = vec![TickRow {
            dt,
            price: 11.5,
            vol: 100.0,
            side: "B".into(),
            has_bs: true,
            price_lo: None,
            price_hi: None,
            ticks: 3.0,
        }];
        let path = cache_path(root, "002003", 20180110);
        write_cache(&path, 20180110, "002003", &ticks).unwrap();
        let got = load_protocol_ticks(root, "002003", dt, dt).unwrap();
        assert_eq!(got.len(), 1);
        assert!((got[0].ticks - 3.0).abs() < 1e-9);
        assert_eq!(got[0].side, "B");
    }
}
