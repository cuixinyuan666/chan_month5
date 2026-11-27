//! 全 A 股日线全历史导出（通达信 2026-09 新版协议）。
//!
//! 用法（在 CHAN_RUST/rust 下）：
//!   cargo run --release -p chan_data --example export_all_a_shares -- --out ../../exports/a_shares_daily
//!
//! 可选参数：
//!   --threads N     并发连接数（默认 12，建议 ≤ 20）
//!   --max-bars N    单只最多保留多少根日线（默认 20000，即全历史）
//!   --limit N       只导出前 N 只（调试用）
//!   --codes a,b,c   只导出指定代码（调试用）
//!   --out DIR       输出目录
//!
//! 说明：数据源 = 通达信行情服务器（与本软件 App 同一取数通道）；
//! 日线为不复权口径；volume 单位「手」，amount 单位「元」。

use std::collections::BTreeSet;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::Instant;

use chan_data::{is_a_share, DailyBar, SecurityInfo, TdxSession};

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
    bars: usize,
    first: i32,
    last: i32,
    status: String,
}

fn arg_value(args: &[String], key: &str) -> Option<String> {
    args.iter()
        .position(|a| a == key)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn exchange_prefix(market: u16) -> &'static str {
    match market {
        1 => "sh",
        2 => "bj",
        _ => "sz",
    }
}

fn file_name_for(t: &Target) -> String {
    format!("{}{}.csv", exchange_prefix(t.market), t.code)
}

fn date_str(d: i32) -> String {
    format!("{:04}-{:02}-{:02}", d / 10000, d / 100 % 100, d % 100)
}

/// 读已有 CSV 的首末日期与根数（断点续传时补统计）。
fn scan_csv(path: &Path) -> Option<(usize, i32, i32)> {
    let text = fs::read_to_string(path).ok()?;
    let mut bars = 0usize;
    let mut first = 0i32;
    let mut last = 0i32;
    for line in text.lines().skip(1) {
        let date = line.split(',').next()?;
        let digits: String = date.chars().filter(|c| c.is_ascii_digit()).collect();
        if digits.len() != 8 {
            continue;
        }
        let d: i32 = digits.parse().ok()?;
        if bars == 0 {
            first = d;
        }
        last = d;
        bars += 1;
    }
    if bars == 0 {
        None
    } else {
        Some((bars, first, last))
    }
}

fn write_stock_csv(path: &Path, bars: &[DailyBar]) -> std::io::Result<()> {    let mut s = String::with_capacity(bars.len() * 48 + 64);
    s.push_str("date,open,high,low,close,volume,amount\n");
    for b in bars {
        s.push_str(&format!(
            "{},{:.3},{:.3},{:.3},{:.3},{:.0},{:.0}\n",
            date_str(b.date),
            b.open,
            b.high,
            b.low,
            b.close,
            b.volume,
            b.amount
        ));
    }
    let tmp = path.with_extension("csv.tmp");
    fs::write(&tmp, s)?;
    fs::rename(tmp, path)
}

fn fetch_universe(codes_filter: &Option<BTreeSet<String>>) -> Result<Vec<Target>, String> {
    let mut errors = Vec::new();
    for host in HOSTS.iter().take(8) {
        match TdxSession::connect(host) {
            Ok(mut s) => {
                let mut all = Vec::new();
                for market in 0u16..=2 {
                    match s.security_list(market) {
                        Ok(list) => {
                            println!("     market{market} 列表 {} 条", list.len());
                            all.extend(list)
                        }
                        Err(e) => {
                            println!("     market{market} 列表失败: {e}");
                            errors.push(format!("{host} market{market}: {e}"))
                        }
                    }
                }
                if all.is_empty() {
                    continue;
                }
                let raw = all.len();
                let mut out: Vec<Target> = all
                    .into_iter()
                    .filter(|s: &SecurityInfo| is_a_share(s.market, &s.code))
                    .filter(|s| match &codes_filter {
                        Some(set) => set.contains(&s.code),
                        None => true,
                    })
                    .map(|s| Target {
                        code: s.code,
                        name: s.name,
                        market: s.market,
                    })
                    .collect();
                out.sort_by(|a, b| a.code.cmp(&b.code));
                out.dedup_by(|a, b| a.code == b.code && a.market == b.market);
                println!("     证券 {raw} 条 → A 股 {n} 只", n = out.len());
                if !out.is_empty() {
                    return Ok(out);
                }
            }
            Err(e) => errors.push(format!("{host}: {e}")),
        }
    }
    Err(format!("无法取得证券列表：{}", errors.join(" | ")))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let out_dir = PathBuf::from(
        arg_value(&args, "--out").unwrap_or_else(|| "../../exports/a_shares_daily".to_string()),
    );
    let threads: usize = arg_value(&args, "--threads")
        .and_then(|v| v.parse().ok())
        .unwrap_or(12)
        .clamp(1, 24);
    let max_bars: usize = arg_value(&args, "--max-bars")
        .and_then(|v| v.parse().ok())
        .unwrap_or(20000);
    let limit: Option<usize> = arg_value(&args, "--limit").and_then(|v| v.parse().ok());
    let codes_filter: Option<BTreeSet<String>> = arg_value(&args, "--codes").map(|v| {
        v.split(',')
            .map(|x| x.trim().to_string())
            .filter(|x| !x.is_empty())
            .collect()
    });

    if let Err(e) = fs::create_dir_all(out_dir.join("daily")) {
        eprintln!("创建输出目录失败: {e}");
        std::process::exit(1);
    }

    println!("[1/3] 拉取证券列表…");
    let mut targets = match fetch_universe(&codes_filter) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    if let Some(n) = limit {
        targets.truncate(n);
    }
    println!("      A 股标的数：{}", targets.len());
    if targets.is_empty() {
        eprintln!("标的列表为空");
        std::process::exit(2);
    }

    // 股票清单
    let list_path = out_dir.join("stocks.csv");
    let mut list_csv = String::from("code,name,market,exchange,file\n");
    for t in &targets {
        list_csv.push_str(&format!(
            "{},{},{},{},{}\n",
            t.code,
            t.name.replace(',', " "),
            t.market,
            exchange_prefix(t.market),
            file_name_for(t)
        ));
    }
    let _ = fs::write(&list_path, list_csv);

    println!("[2/3] 下载日线（{} 线程）…", threads);
    let start = Instant::now();
    let next = AtomicUsize::new(0);
    let done = AtomicUsize::new(0);
    let results: Mutex<Vec<StockResult>> = Mutex::new(Vec::new());
    let total = targets.len();

    std::thread::scope(|scope| {
        for worker in 0..threads {
            let targets = &targets;
            let next = &next;
            let done = &done;
            let results = &results;
            let out_dir = out_dir.clone();
            scope.spawn(move || {
                let mut host_idx = worker % HOSTS.len();
                let mut session: Option<TdxSession> = None;
                loop {
                    let i = next.fetch_add(1, Ordering::SeqCst);
                    if i >= targets.len() {
                        break;
                    }
                    let t = &targets[i];
                    let path = out_dir.join("daily").join(file_name_for(t));

                    // 断点续传：已有非空文件直接跳过
                    if let Ok(meta) = fs::metadata(&path) {
                        if meta.len() > 40 {
                            let (bars, first, last) = scan_csv(&path).unwrap_or((0, 0, 0));
                            let mut r = results.lock().unwrap();
                            r.push(StockResult {
                                code: t.code.clone(),
                                name: t.name.clone(),
                                market: t.market,
                                bars,
                                first,
                                last,
                                status: "cached".into(),
                            });
                            let n = done.fetch_add(1, Ordering::SeqCst) + 1;
                            if n % 100 == 0 || n == total {
                                println!("     进度 {n}/{total}（{}s）", start.elapsed().as_secs());
                            }
                            continue;
                        }
                    }

                    let mut attempt = 0;
                    let mut bars: Option<Vec<DailyBar>> = None;
                    let mut last_err = String::new();
                    while attempt < 3 {
                        if session.is_none() {
                            let host = HOSTS[host_idx % HOSTS.len()];
                            host_idx += 1;
                            match TdxSession::connect(host) {
                                Ok(s) => session = Some(s),
                                Err(e) => {
                                    last_err = e.to_string();
                                    attempt += 1;
                                    continue;
                                }
                            }
                        }
                        match session
                            .as_mut()
                            .unwrap()
                            .daily_bars(t.market, &t.code, max_bars)
                        {
                            Ok(v) => {
                                bars = Some(v);
                                break;
                            }
                            Err(e) => {
                                last_err = e.to_string();
                                session = None;
                                attempt += 1;
                            }
                        }
                    }

                    let mut res = StockResult {
                        code: t.code.clone(),
                        name: t.name.clone(),
                        market: t.market,
                        bars: 0,
                        first: 0,
                        last: 0,
                        status: "ok".into(),
                    };
                    match bars {
                        Some(b) if !b.is_empty() => {
                            if let Err(e) = write_stock_csv(&path, &b) {
                                res.status = format!("write_err:{e}");
                            } else {
                                res.bars = b.len();
                                res.first = b[0].date;
                                res.last = b[b.len() - 1].date;
                            }
                        }
                        _ => {
                            res.status = format!("fail:{last_err}");
                        }
                    }
                    let n = {
                        let mut r = results.lock().unwrap();
                        r.push(res);
                        done.fetch_add(1, Ordering::SeqCst) + 1
                    };
                    if n % 100 == 0 || n == total {
                        println!("     进度 {n}/{total}（{}s）", start.elapsed().as_secs());
                    }
                }
            });
        }
    });

    println!("[3/3] 汇总…");
    let mut all = results.into_inner().unwrap();
    all.sort_by(|a, b| a.code.cmp(&b.code));
    let ok = all.iter().filter(|r| r.status == "ok" || r.status == "cached").count();
    let failed = all.len() - ok;
    let bars_total: usize = all.iter().map(|r| r.bars).sum();

    let mut summary = String::from("code,name,market,exchange,bars,first,last,status\n");
    for r in &all {
        summary.push_str(&format!(
            "{},{},{},{},{},{},{},{}\n",
            r.code,
            r.name.replace(',', " "),
            r.market,
            exchange_prefix(r.market),
            r.bars,
            if r.first > 0 { date_str(r.first) } else { String::new() },
            if r.last > 0 { date_str(r.last) } else { String::new() },
            r.status.replace(',', " ")
        ));
    }
    let summary_path = out_dir.join("summary.csv");
    let _ = fs::write(&summary_path, summary);

    let manifest = format!(
        "{{\n  \"generated_at\": \"{}\",\n  \"source\": \"TDX 7709 (2026-09 protocol)\",\n  \"period\": \"daily\",\n  \"adjust\": \"none\",\n  \"volume_unit\": \"lot(100 shares)\",\n  \"amount_unit\": \"CNY\",\n  \"stocks_total\": {},\n  \"stocks_ok\": {},\n  \"stocks_failed\": {},\n  \"bars_total\": {},\n  \"elapsed_sec\": {}\n}}\n",
        chrono::Local::now().format("%Y-%m-%d %H:%M:%S"),
        all.len(),
        ok,
        failed,
        bars_total,
        start.elapsed().as_secs()
    );
    let _ = fs::write(out_dir.join("manifest.json"), manifest);
    let mut f = fs::File::create(out_dir.join("failures.txt")).unwrap();
    for r in all.iter().filter(|r| r.status.starts_with("fail")) {
        let _ = writeln!(f, "{}\t{}\t{}", r.code, r.name, r.status);
    }

    println!(
        "完成：{} 只（成功 {} / 失败 {}），共 {} 根日线，用时 {}s\n输出：{}",
        all.len(),
        ok,
        failed,
        bars_total,
        start.elapsed().as_secs(),
        out_dir.display()
    );
}
