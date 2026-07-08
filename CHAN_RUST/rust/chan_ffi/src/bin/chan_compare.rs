//! CLI：供 Python 比对脚本子进程调用（避免 Windows 上 ctypes 调 cdylib 崩溃）。

use std::env;
use std::io::{self, Read};

use chan_data::{
    build_kline_combine_bundle, load_klines, resolve_data_root, KlineBar, KlinePeriod,
};

fn usage() -> ! {
    eprintln!(
        "用法:\n  \
         chan_compare load <code> <begin> <end> <period> [data_root]\n  \
         chan_compare combine   # stdin: KlineBar[] JSON → stdout: frames JSON"
    );
    std::process::exit(2);
}

fn cmd_load(args: &[String]) {
    if args.len() < 6 {
        usage();
    }
    let code = &args[2];
    let begin = &args[3];
    let end = &args[4];
    let period_s = &args[5];
    let root = if args.len() > 6 {
        resolve_data_root(Some(&args[6]))
    } else {
        resolve_data_root(None)
    };
    let Some(period) = KlinePeriod::parse(period_s) else {
        eprintln!("不支持的周期: {period_s}");
        std::process::exit(1);
    };
    match load_klines(&root, code, begin, end, period) {
        Ok(bars) => {
            println!("{}", serde_json::to_string(&bars).unwrap());
        }
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}

fn cmd_combine() {
    let mut raw = String::new();
    io::stdin().read_to_string(&mut raw).expect("读取 stdin 失败");
    let bars: Vec<KlineBar> = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("bars JSON 解析失败: {e}");
            std::process::exit(1);
        }
    };
    let bundle = build_kline_combine_bundle(&bars);
    println!("{}", serde_json::to_string(&bundle).unwrap());
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        usage();
    }
    match args[1].as_str() {
        "load" => cmd_load(&args),
        "combine" => cmd_combine(),
        _ => usage(),
    }
}
