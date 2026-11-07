//! 全 A 股分笔（逐笔成交）批量导出：直接写 App 现有的 `.tdx_protocol_cache` 格式。
//!
//! 用法（在 CHAN_RUST/rust 下）：
//!   cargo run --release -p chan_data --example export_all_ticks -- \
//!     --begin 20261027 --end 20261030 --out ../../exports/a_shares_ticks
//!
//! 参数：
//!   --begin YYYYMMDD   起始交易日（含）
//!   --end   YYYYMMDD   结束交易日（含，默认今天）
//!   --codes a,b,c      只拉指定代码（3 只测试用）
//!   --codes-from FILE  股票清单 CSV（默认取 exports/a_shares_daily/summary.csv）
//!   --limit N          只处理前 N 只（调试用）
//!   --threads N        并发连接数（默认 12，建议 ≤ 20）
//!   --cache-root DIR   分笔缓存根目录（默认 a_Data，与 App 同目录）
//!   --out DIR          清单/汇总输出目录（默认 ../../exports/a_shares_ticks）
//!
//! 断点续传：缓存文件已存在且非空则跳过，重复执行只补缺口。

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::Instant;

use chan_data::{is_a_share, TickFetcher, TdxSession, TickRow};

const HOSTS: &[&str] = &[
    "101.33.225.16",
    "101.35.121.35",
    "101.42.164.241",
    "101.42.240.54",
    "101.43.159.194",
    "110.41.147.114",
    "110.41.2.72",
    "111.229.247.189",
    "111.230.186.52",
    "111.231.113.208",
    "116.205.163.254",
    "116.205.171.132",
    "116.205.183.150",
    "118.25.98.114",
    "119.97.185.59",
    "120.53.8.251",
    "121.36.225.169",
    "122.51.120.217",
    "122.51.232.182",
    "123.60.164.122",
    "123.60.70.228",
    "123.60.73.44",
    "123.60.84.66",
    "124.223.163.242",
    "124.70.133.119",
    "124.70.199.56",
    "124.71.187.122",
    "124.71.187.72",
    "124.71.9.153",
    "129.204.230.128",
    "150.158.160.2",
    "152.136.191.169",
    "159.75.29.111",
    "175.178.112.197",
    "175.178.128.227",
    "43.139.18.171",
    "43.139.95.83",
    "49.232.15.141",
    "62.234.50.143",
    "81.70.151.186",
    "81.71.32.47",
    "82.156.174.84",
    "82.156.214.79",
];

#[derive(Clone)]
struct Target {
    code: String,
    name: String,
    market: u16,
}

struct StockResult {
    code: String,
    name: String,
    market: u16,
    days: usize,
    rows: usize,
    bytes: u64,
    fail_days: usize,
}

fn arg_value(args: &[String], key: &str) -> Option<String> {
    args.iter()
        .position(|a| a == key)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn today8() -> i32 {
    // 不引入新依赖：用系统时间戳按 UTC+8 粗略折算（仅用于默认 end）。
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let days = (secs + 8 * 3600) / 86400;
    // 1970-01-01 起的天数 → 公历日期
    let mut y = 1970i64;
    let mut d = days;
    loop {
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let ylen = if leap { 366 } else { 365 };
        if d < ylen {
            break;
        }
        d -= ylen;
        y += 1;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let mdays = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut m = 0usize;
    while m < 12 && d >= mdays[m] {
        d -= mdays[m];
        m += 1;
    }
    (y * 10000 + (m as i64 + 1) * 100 + d + 1) as i32
}

/// 8 位日期 → (年,月,日)
fn split_date(d: i32) -> (i32, i32, i32) {
    (d / 10000, d / 100 % 100, d % 100)
}

/// 星期（0=周日 … 6=周六），Sakamoto 算法，避免引入 chrono 依赖。
fn weekday(y: i32, m: i32, d: i32) -> u32 {
    const T: [i32; 12] = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
    let y = if m < 3 { y - 1 } else { y };
    let w = (y + y / 4 - y / 100 + y / 400 + T[(m - 1) as usize] + d) % 7;
    w as u32
}

fn is_trading_day(d: i32) -> bool {
    let (y, m, day) = split_date(d);
    let w = weekday(y, m, day);
    w != 0 && w != 6
}

fn next_day(d: i32) -> i32 {
    let (y, m, day) = split_date(d);
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let mdays = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    if day < mdays[(m - 1) as usize] {
        y * 10000 + m * 100 + day + 1
    } else if m < 12 {
        y * 10000 + (m + 1) * 100 + 1
    } else {
        (y + 1) * 10000 + 101
    }
}

fn trading_days(begin: i32, end: i32) -> Vec<i32> {
    let mut out = Vec::new();
    let mut d = begin;
    while d <= end {
        if is_trading_day(d) {
            out.push(d);
        }
        d = next_day(d);
    }
    out
}

fn parse_codes_csv(path: &Path) -> Option<Vec<Target>> {
    let text = fs::read_to_string(path).ok()?;
    let mut out = Vec::new();
    for (i, line) in text.lines().enumerate() {
        if i == 0 || line.trim().is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.split(',').collect();
        if parts.len() < 3 {
            continue;
        }
        let code = parts[0].trim().to_string();
        let name = parts[1].trim().to_string();
        let market: u16 = parts[2].trim().parse().unwrap_or(0);
        if code.len() != 6 || !code.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        out.push(Target { code, name, market });
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

fn fetch_universe() -> Result<Vec<Target>, String> {
    let mut errors = Vec::new();
    for host in HOSTS {
        let Ok(mut s) = TdxSession::connect(host) else {
            continue;
        };
        let mut all = Vec::new();
        let mut ok = true;
        for market in 0u16..=1 {
            match s.security_list(market) {
                Ok(list) => all.extend(list),
                Err(e) => {
                    errors.push(format!("{host} market{market}: {e}"));
                    ok = false;
                    break;
                }
            }
        }
        if !ok {
            continue;
        }
        let mut out: Vec<Target> = all
            .into_iter()
            .filter(|x| is_a_share(x.market, &x.code))
            .map(|x| Target {
                code: x.code,
                name: x.name,
                market: x.market,
            })
            .collect();
        out.sort_by(|a, b| a.code.cmp(&b.code));
        out.dedup_by(|a, b| a.code == b.code);
        if !out.is_empty() {
            return Ok(out);
        }
    }
    Err(format!("无法取得证券列表：{}", errors.join(" | ")))
}

/// 统计已存在缓存文件的行数（跳表头 2 行与末尾来源行）。
fn scan_cache(path: &Path) -> Option<(usize, u64)> {
    let text = fs::read_to_string(path).ok()?;
    let bytes = text.len() as u64;
    let rows = text
        .lines()
        .filter(|l| !l.trim().is_empty() && !l.starts_with('#') && l.as_bytes()[0].is_ascii_digit())
        .count();
    if rows == 0 {
        None
    } else {
        Some((rows, bytes))
    }
}

/// 单只股票「股内按交易日并行」拉取；返回 (有数据天数, 失败天数, 行数, 字节数)。
fn fetch_single_stock_by_day(
    target: &Target,
    days: &[i32],
    cache_root: &Path,
    day_threads: usize,
    failures: &Mutex<Vec<String>>,
) -> (usize, usize, usize, u64) {
    let next_day = AtomicUsize::new(0);
    let day_ok = AtomicUsize::new(0);
    let day_fail = AtomicUsize::new(0);
    std::thread::scope(|scope| {
        for _ in 0..day_threads {
            let next_day = &next_day;
            let day_ok = &day_ok;
            let day_fail = &day_fail;
            let failures = failures;
            let cache_root = cache_root.to_path_buf();
            scope.spawn(move || {
                let mut fetcher = TickFetcher::new();
                loop {
                    let i = next_day.fetch_add(1, Ordering::SeqCst);
                    if i >= days.len() {
                        break;
                    }
                    let date8 = days[i];
                    let path = chan_data::tick_cache_path(&cache_root, &target.code, date8);
                    if scan_cache(&path).is_some() {
                        day_ok.fetch_add(1, Ordering::SeqCst);
                        continue;
                    }
                    let mut attempt = 0;
                    loop {
                        match fetcher.fetch_day(target.market, &target.code, date8) {
                            Ok(v) => {
                                if !v.is_empty() {
                                    let _ = chan_data::write_tick_cache(
                                        &cache_root, &target.code, date8, &v,
                                    );
                                }
                                day_ok.fetch_add(1, Ordering::SeqCst);
                                break;
                            }
                            Err(e) => {
                                fetcher.reconnect();
                                attempt += 1;
                                if attempt >= 3 {
                                    day_fail.fetch_add(1, Ordering::SeqCst);
                                    failures
                                        .lock()
                                        .unwrap()
                                        .push(format!("{}\t{date8}\t{e}", target.code));
                                    break;
                                }
                            }
                        }
                    }
                }
            });
        }
    });
    let mut rows = 0usize;
    let mut bytes = 0u64;
    for &date8 in days {
        let path = chan_data::tick_cache_path(cache_root, &target.code, date8);
        if let Some((r, b)) = scan_cache(&path) {
            rows += r;
            bytes += b;
        }
    }
    (
        day_ok.load(Ordering::SeqCst),
        day_fail.load(Ordering::SeqCst),
        rows,
        bytes,
    )
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let end = arg_value(&args, "--end")
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(today8);
    let begin = arg_value(&args, "--begin")
        .and_then(|v| v.parse().ok())
        .unwrap_or(19900101);
    let threads: usize = arg_value(&args, "--threads")
        .and_then(|v| v.parse().ok())
        .unwrap_or(12)
        .clamp(1, 24);
    let limit: Option<usize> = arg_value(&args, "--limit").and_then(|v| v.parse().ok());
    let out_dir = PathBuf::from(
        arg_value(&args, "--out").unwrap_or_else(|| "../../exports/a_shares_ticks".to_string()),
    );
    let cache_root = PathBuf::from(
        arg_value(&args, "--cache-root").unwrap_or_else(|| {
            chan_data::default_data_root().to_string_lossy().to_string()
        }),
    );
    let codes_filter: Option<BTreeSet<String>> = arg_value(&args, "--codes").map(|v| {
        v.split(',')
            .map(|x| x.trim().to_string())
            .filter(|x| !x.is_empty())
            .collect()
    });
    let codes_from = arg_value(&args, "--codes-from")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("../../exports/a_shares_daily/summary.csv"));

    if begin > end {
        eprintln!("起始日期 {begin} 晚于结束日期 {end}");
        std::process::exit(2);
    }
    if let Err(e) = fs::create_dir_all(&out_dir) {
        eprintln!("创建输出目录失败: {e}");
        std::process::exit(1);
    }

    let days = trading_days(begin, end);
    if days.is_empty() {
        eprintln!("区间内没有交易日：{begin}~{end}");
        std::process::exit(2);
    }

    println!("[1/3] 读取股票清单…");
    let mut targets = match parse_codes_csv(&codes_from) {
        Some(v) => {
            println!("      来自 {}（{} 只）", codes_from.display(), v.len());
            v
        }
        None => {
            println!("      清单文件不可用，改从行情服务器拉列表…");
            match fetch_universe() {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("{e}");
                    std::process::exit(2);
                }
            }
        }
    };
    if let Some(set) = &codes_filter {
        targets.retain(|t| set.contains(&t.code));
    }
    if let Some(n) = limit {
        targets.truncate(n);
    }
    if targets.is_empty() {
        eprintln!("标的列表为空");
        std::process::exit(2);
    }
    println!(
        "      股票 {} 只 × 交易日 {} 天 = {} 个股票日",
        targets.len(),
        days.len(),
        targets.len() * days.len()
    );
    println!("      缓存根目录：{}", cache_root.display());

    println!("[2/3] 拉取分笔（{} 线程）…", threads);
    let start = Instant::now();
    let next = AtomicUsize::new(0);
    let done = AtomicUsize::new(0);
    let ok_days = AtomicUsize::new(0);
    let cached_days = AtomicUsize::new(0);
    let nodata_days = AtomicUsize::new(0);
    let fail_days = AtomicUsize::new(0);
    let total_rows = AtomicUsize::new(0);
    let total_bytes = AtomicUsize::new(0);
    let results: Mutex<Vec<StockResult>> = Mutex::new(Vec::new());
    let failures: Mutex<Vec<String>> = Mutex::new(Vec::new());
    let total = targets.len();
    let day_threads: usize = arg_value(&args, "--day-threads")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
        .clamp(0, 64);

    if day_threads > 1 && targets.len() == 1 {
        let t = &targets[0];
        println!("      单股股内并行：{day_threads} 线程按交易日拉取");
        let (okd, faild, rows, bytes) =
            fetch_single_stock_by_day(t, &days, &cache_root, day_threads, &failures);
        ok_days.store(okd, Ordering::SeqCst);
        fail_days.store(faild, Ordering::SeqCst);
        total_rows.store(rows, Ordering::SeqCst);
        total_bytes.store(bytes as usize, Ordering::SeqCst);
        done.store(1, Ordering::SeqCst);
        results.lock().unwrap().push(StockResult {
            code: t.code.clone(),
            name: t.name.clone(),
            market: t.market,
            days: okd,
            rows,
            bytes,
            fail_days: faild,
        });
        println!(
            "      单股完成：{okd} 天有数据，{faild} 天失败（{}s）",
            start.elapsed().as_secs()
        );
    } else {

    std::thread::scope(|scope| {
        for _ in 0..threads {
            let targets = &targets;
            let days = &days;
            let next = &next;
            let done = &done;
            let ok_days = &ok_days;
            let cached_days = &cached_days;
            let nodata_days = &nodata_days;
            let fail_days = &fail_days;
            let total_rows = &total_rows;
            let total_bytes = &total_bytes;
            let results = &results;
            let failures = &failures;
            let cache_root = cache_root.clone();
            scope.spawn(move || {
                let mut fetcher = TickFetcher::new();
                loop {
                    let i = next.fetch_add(1, Ordering::SeqCst);
                    if i >= targets.len() {
                        break;
                    }
                    let t = &targets[i];
                    let mut res = StockResult {
                        code: t.code.clone(),
                        name: t.name.clone(),
                        market: t.market,
                        days: 0,
                        rows: 0,
                        bytes: 0,
                        fail_days: 0,
                    };
                    for &date8 in days.iter() {
                        let path = chan_data::tick_cache_path(&cache_root, &t.code, date8);
                        if let Some((rows, bytes)) = scan_cache(&path) {
                            res.days += 1;
                            res.rows += rows;
                            res.bytes += bytes;
                            cached_days.fetch_add(1, Ordering::SeqCst);
                            total_rows.fetch_add(rows, Ordering::SeqCst);
                            total_bytes.fetch_add(bytes as usize, Ordering::SeqCst);
                            continue;
                        }
                        let mut attempt = 0;
                        let mut ticks: Option<Vec<TickRow>> = None;
                        let mut last_err = String::new();
                        while attempt < 3 {
                            match fetcher.fetch_day(t.market, &t.code, date8) {
                                Ok(v) => {
                                    ticks = Some(v);
                                    break;
                                }
                                Err(e) => {
                                    last_err = e.to_string();
                                    fetcher.reconnect();
                                    attempt += 1;
                                }
                            }
                        }
                        match ticks {
                            None => {
                                res.fail_days += 1;
                                fail_days.fetch_add(1, Ordering::SeqCst);
                                failures
                                    .lock()
                                    .unwrap()
                                    .push(format!("{}\t{date8}\t{last_err}", t.code));
                            }
                            Some(v) if v.is_empty() => {
                                // 停牌/非交易日/未上市：不写空缓存，下次重跑仍会尝试。
                                nodata_days.fetch_add(1, Ordering::SeqCst);
                            }
                            Some(v) => {
                                match chan_data::write_tick_cache(&cache_root, &t.code, date8, &v) {
                                    Ok(p) => {
                                        let bytes = fs::metadata(&p).map(|m| m.len()).unwrap_or(0);
                                        res.days += 1;
                                        res.rows += v.len();
                                        res.bytes += bytes;
                                        ok_days.fetch_add(1, Ordering::SeqCst);
                                        total_rows.fetch_add(v.len(), Ordering::SeqCst);
                                        total_bytes.fetch_add(bytes as usize, Ordering::SeqCst);
                                    }
                                    Err(e) => {
                                        res.fail_days += 1;
                                        fail_days.fetch_add(1, Ordering::SeqCst);
                                        failures
                                            .lock()
                                            .unwrap()
                                            .push(format!("{}\t{date8}\t写缓存失败: {e}", t.code));
                                    }
                                }
                            }
                        }
                    }
                    let n = done.fetch_add(1, Ordering::SeqCst) + 1;
                    if n % 20 == 0 || n == total {
                        println!(
                            "      进度 {n}/{total}（{}s，已写 {} 股票日，缓存命中 {}）",
                            start.elapsed().as_secs(),
                            ok_days.load(Ordering::SeqCst),
                            cached_days.load(Ordering::SeqCst)
                        );
                    }
                    results.lock().unwrap().push(res);
                }
            });
        }
    });
    }

    println!("[3/3] 汇总…");
    let elapsed = start.elapsed().as_secs();
    let mut results = results.into_inner().unwrap();
    results.sort_by(|a, b| a.code.cmp(&b.code));
    let ok_stocks = results.iter().filter(|r| r.fail_days == 0 && r.days > 0).count();
    let mut summary = String::from("code,name,market,days,rows,bytes,fail_days\n");
    for r in &results {
        summary.push_str(&format!(
            "{},{},{},{},{},{},{}\n",
            r.code,
            r.name.replace(',', " "),
            r.market,
            r.days,
            r.rows,
            r.bytes,
            r.fail_days
        ));
    }
    let _ = fs::write(out_dir.join("summary.csv"), summary);
    let fails = failures.into_inner().unwrap();
    let _ = fs::write(out_dir.join("failures.txt"), fails.join("\n"));

    let manifest = format!(
        "{{\n  \"generated_at\": \"{}\",\n  \"source\": \"TDX 7709 0x0fc6 (带笔数分笔)\",\n  \"begin\": {begin},\n  \"end\": {end},\n  \"trading_days\": {},\n  \"threads\": {threads},\n  \"stocks_total\": {},\n  \"stocks_ok\": {ok_stocks},\n  \"stock_days_ok\": {},\n  \"stock_days_cached\": {},\n  \"stock_days_nodata\": {},\n  \"stock_days_failed\": {},\n  \"rows_total\": {},\n  \"bytes_total\": {},\n  \"elapsed_sec\": {elapsed},\n  \"cache_root\": \"{}\"\n}}\n",
        chrono::Local::now().format("%Y-%m-%d %H:%M:%S"),
        days.len(),
        targets.len(),
        ok_days.load(Ordering::SeqCst),
        cached_days.load(Ordering::SeqCst),
        nodata_days.load(Ordering::SeqCst),
        fail_days.load(Ordering::SeqCst),
        total_rows.load(Ordering::SeqCst),
        total_bytes.load(Ordering::SeqCst),
        cache_root.display().to_string().replace('\\', "\\\\")
    );
    let _ = fs::write(out_dir.join("manifest.json"), &manifest);
    println!("{manifest}");
    println!(
        "完成：{} 只股票、{} 个股票日（新写 {} / 缓存 {} / 无数据 {} / 失败 {}），{} 行分笔，用时 {elapsed}s",
        targets.len(),
        ok_days.load(Ordering::SeqCst) + cached_days.load(Ordering::SeqCst),
        ok_days.load(Ordering::SeqCst),
        cached_days.load(Ordering::SeqCst),
        nodata_days.load(Ordering::SeqCst),
        fail_days.load(Ordering::SeqCst),
        total_rows.load(Ordering::SeqCst),
    );
    println!("输出：{}", out_dir.display());
}
