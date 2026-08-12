//! Flutter `dart:ffi` 桥：返回 JSON 字符串指针，调用方负责 `chan_free_string`。

use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::sync::{Mutex, OnceLock};

use chan_data::{
    build_kline_combine_bundle_from_state, build_kline_combine_bundle_with, chip_profile,
    default_data_root, list_stock_codes, load_klines, ml_predict_dense, resolve_data_root,
    save_test_ohlc, KlineBar, KlinePeriod, PipelineOptions, PipelineState, ZSConfig,
};
use serde::{Deserialize, Serialize};

#[derive(Serialize)]
struct ApiOk<T> {
    ok: bool,
    data: T,
}

#[derive(Serialize)]
struct ApiErr {
    ok: bool,
    error: String,
}

fn to_json_ok<T: Serialize>(data: T) -> *mut c_char {
    match serde_json::to_string(&ApiOk { ok: true, data }) {
        Ok(s) => CString::new(s).map(|c| c.into_raw()).unwrap_or(ptr::null_mut()),
        Err(e) => to_json_err(&e.to_string()),
    }
}

fn to_json_err(msg: &str) -> *mut c_char {
    match serde_json::to_string(&ApiErr {
        ok: false,
        error: msg.to_string(),
    }) {
        Ok(s) => CString::new(s).map(|c| c.into_raw()).unwrap_or(ptr::null_mut()),
        Err(_) => ptr::null_mut(),
    }
}

fn cstr_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        None
    } else {
        unsafe { CStr::from_ptr(ptr).to_str().ok() }
    }
}

/// 释放 `chan_*` 返回的字符串。
#[no_mangle]
pub extern "C" fn chan_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(s));
    }
}

/// 默认 a_Data 绝对路径（JSON `{ok,data}`）。
#[no_mangle]
pub extern "C" fn chan_default_data_root() -> *mut c_char {
    let p = default_data_root();
    to_json_ok(p.to_string_lossy().to_string())
}

/// 枚举股票代码列表。`data_root` 可空。
#[no_mangle]
pub extern "C" fn chan_list_stock_codes(data_root: *const c_char) -> *mut c_char {
    let root_s = cstr_to_str(data_root).map(|s| s.to_string());
    let root = resolve_data_root(root_s.as_deref());
    match list_stock_codes(&root) {
        Ok(codes) => to_json_ok(codes),
        Err(e) => to_json_err(&e.to_string()),
    }
}

/// 加载 K 线。period 示例：tick / 1m / 5m / 2h / 3d / 1mon / 3y。
#[no_mangle]
pub extern "C" fn chan_load_klines(
    data_root: *const c_char,
    code: *const c_char,
    begin_date: *const c_char,
    end_date: *const c_char,
    period: *const c_char,
) -> *mut c_char {
    let Some(code) = cstr_to_str(code) else {
        return to_json_err("code 不能为空");
    };
    let Some(begin_date) = cstr_to_str(begin_date) else {
        return to_json_err("begin_date 不能为空");
    };
    let Some(end_date) = cstr_to_str(end_date) else {
        return to_json_err("end_date 不能为空");
    };
    let period_s = cstr_to_str(period)
        .map(|s| s.to_string())
        .unwrap_or_else(|| "day".to_string());
    let Some(period_enum) = KlinePeriod::parse(&period_s) else {
        return to_json_err(&format!("不支持的周期: {period_s}"));
    };

    let root_s = cstr_to_str(data_root).map(|s| s.to_string());
    let root = resolve_data_root(root_s.as_deref());

    match load_klines(
        &root,
        &code,
        &begin_date,
        &end_date,
        period_enum,
    ) {
        Ok(bars) => to_json_ok(bars),
        Err(e) => to_json_err(&e.to_string()),
    }
}

/// 保存 test 自定义 OHLC 到 `a_Data/test/custom.ohlc.csv`。
/// 入参 JSON：`{ "data_root": "...?", "bars": [KlineBar...] }`
#[no_mangle]
pub extern "C" fn chan_save_test_ohlc(req_json: *const c_char) -> *mut c_char {
    let Some(raw) = cstr_to_str(req_json) else {
        return to_json_err("req_json 不能为空");
    };
    #[derive(Deserialize)]
    struct SaveReq {
        #[serde(default)]
        data_root: Option<String>,
        bars: Vec<KlineBar>,
    }
    #[derive(Serialize)]
    struct SaveOut {
        path: String,
        count: usize,
    }
    let req: SaveReq = match serde_json::from_str(raw) {
        Ok(v) => v,
        Err(e) => return to_json_err(&format!("save_test_ohlc 解析失败: {e}")),
    };
    let root = resolve_data_root(req.data_root.as_deref());
    match save_test_ohlc(&root, &req.bars) {
        Ok(()) => {
            let path = root.join("test").join("custom.ohlc.csv");
            to_json_ok(SaveOut {
                path: path.to_string_lossy().to_string(),
                count: req.bars.len(),
            })
        }
        Err(e) => to_json_err(&e.to_string()),
    }
}

/// 对已加载 K 线做 Kn 流水线。
/// 入参两种：
/// 1) 纯 bars 数组（兼容旧调用，截断默认开）
/// 2) `{ "bars": [...], "truncation_check": true/false }`
#[no_mangle]
pub extern "C" fn chan_kline_combine_frames(bars_json: *const c_char) -> *mut c_char {
    let Some(raw) = cstr_to_str(bars_json) else {
        return to_json_err("bars_json 不能为空");
    };
    match parse_combine_request(raw) {
        Ok((bars, opt)) => to_json_ok(build_kline_combine_bundle_with(&bars, &opt)),
        Err(e) => to_json_err(&e),
    }
}

#[derive(Debug, Deserialize)]
struct CombineRequest {
    bars: Vec<KlineBar>,
    /// 缺省=开启截断（与 PipelineOptions::default 一致）
    #[serde(default)]
    truncation_check: Option<bool>,
    /// 缺省=中枢共用配置（need_combine/combine_mode）
    #[serde(default)]
    zs_config: Option<ZSConfig>,
}

fn parse_combine_request(raw: &str) -> Result<(Vec<KlineBar>, PipelineOptions), String> {
    let trimmed = raw.trim_start();
    if trimmed.starts_with('[') {
        let bars: Vec<KlineBar> =
            serde_json::from_str(raw).map_err(|e| format!("bars_json 解析失败: {e}"))?;
        return Ok((bars, PipelineOptions::default()));
    }
    let req: CombineRequest =
        serde_json::from_str(raw).map_err(|e| format!("combine 请求解析失败: {e}"))?;
    let mut opt = PipelineOptions::default();
    if let Some(v) = req.truncation_check {
        opt.truncation_check = v;
    }
    if let Some(z) = req.zs_config {
        opt.zs_config = z;
    }
    Ok((req.bars, opt))
}

// ========== Phase 1.5：PipelineHandle 会话（Rust 持 PipelineState，Flutter 只持 handle）==========

struct PipelineRegistry {
    next_id: u64,
    map: HashMap<u64, PipelineState>,
}

fn pipeline_registry() -> &'static Mutex<PipelineRegistry> {
    static REG: OnceLock<Mutex<PipelineRegistry>> = OnceLock::new();
    REG.get_or_init(|| {
        Mutex::new(PipelineRegistry {
            next_id: 1,
            map: HashMap::new(),
        })
    })
}

fn parse_pipeline_opt(raw: &str) -> Result<PipelineOptions, String> {
    if raw.trim().is_empty() || raw.trim() == "{}" {
        return Ok(PipelineOptions::default());
    }
    #[derive(Deserialize)]
    struct OptReq {
        #[serde(default)]
        truncation_check: Option<bool>,
        #[serde(default)]
        zs_config: Option<ZSConfig>,
    }
    let req: OptReq =
        serde_json::from_str(raw).map_err(|e| format!("pipeline opt 解析失败: {e}"))?;
    let mut opt = PipelineOptions::default();
    if let Some(v) = req.truncation_check {
        opt.truncation_check = v;
    }
    if let Some(z) = req.zs_config {
        opt.zs_config = z;
    }
    Ok(opt)
}

/// 创建流水线会话。入参 JSON：`{ truncation_check?, zs_config? }`（可空/`{}`）。
/// 返回 `{ ok, data: { handle: u64 } }`
#[no_mangle]
pub extern "C" fn chan_pipeline_create(opt_json: *const c_char) -> *mut c_char {
    let raw = cstr_to_str(opt_json).unwrap_or("{}");
    let opt = match parse_pipeline_opt(raw) {
        Ok(o) => o,
        Err(e) => return to_json_err(&e),
    };
    let mut reg = match pipeline_registry().lock() {
        Ok(g) => g,
        Err(_) => return to_json_err("pipeline registry lock poisoned"),
    };
    let handle = reg.next_id;
    reg.next_id = reg.next_id.wrapping_add(1).max(1);
    reg.map.insert(handle, PipelineState::new(opt));
    #[derive(Serialize)]
    struct Out {
        handle: u64,
    }
    to_json_ok(Out { handle })
}

/// 逐根 append。入参 JSON：单根 KlineBar 或 `{ "bar": {...} }`。
/// 返回完整 `KlineCombineBundle`（与 `chan_kline_combine_frames` 同构）。
#[no_mangle]
pub extern "C" fn chan_pipeline_append(handle: u64, bar_json: *const c_char) -> *mut c_char {
    let Some(raw) = cstr_to_str(bar_json) else {
        return to_json_err("bar_json 不能为空");
    };
    let bar = match parse_one_bar(raw) {
        Ok(b) => b,
        Err(e) => return to_json_err(&e),
    };
    let mut reg = match pipeline_registry().lock() {
        Ok(g) => g,
        Err(_) => return to_json_err("pipeline registry lock poisoned"),
    };
    let Some(state) = reg.map.get_mut(&handle) else {
        return to_json_err(&format!("invalid pipeline handle: {handle}"));
    };
    state.append(bar);
    to_json_ok(build_kline_combine_bundle_from_state(state))
}

fn parse_one_bar(raw: &str) -> Result<KlineBar, String> {
    let trimmed = raw.trim_start();
    if trimmed.starts_with('{') {
        // 允许 { "bar": {...} } 或直接 KlineBar
        #[derive(Deserialize)]
        struct Wrap {
            bar: Option<KlineBar>,
        }
        if let Ok(w) = serde_json::from_str::<Wrap>(raw) {
            if let Some(b) = w.bar {
                return Ok(b);
            }
        }
        return serde_json::from_str(raw).map_err(|e| format!("bar_json 解析失败: {e}"));
    }
    Err("bar_json 须为对象".into())
}

/// 非消费快照：当前已喂入前缀的 bundle。
#[no_mangle]
pub extern "C" fn chan_pipeline_snapshot(handle: u64) -> *mut c_char {
    let mut reg = match pipeline_registry().lock() {
        Ok(g) => g,
        Err(_) => return to_json_err("pipeline registry lock poisoned"),
    };
    let Some(state) = reg.map.get_mut(&handle) else {
        return to_json_err(&format!("invalid pipeline handle: {handle}"));
    };
    to_json_ok(build_kline_combine_bundle_from_state(state))
}

/// reset：清空已喂入 K，保留选项（随后 replay）。
#[no_mangle]
pub extern "C" fn chan_pipeline_reset(handle: u64) -> *mut c_char {
    let mut reg = match pipeline_registry().lock() {
        Ok(g) => g,
        Err(_) => return to_json_err("pipeline registry lock poisoned"),
    };
    let Some(state) = reg.map.get_mut(&handle) else {
        return to_json_err(&format!("invalid pipeline handle: {handle}"));
    };
    state.reset();
    #[derive(Serialize)]
    struct Out {
        handle: u64,
        len: usize,
    }
    to_json_ok(Out {
        handle,
        len: state.len(),
    })
}

/// 当前会话已喂入根数。
#[no_mangle]
pub extern "C" fn chan_pipeline_len(handle: u64) -> *mut c_char {
    let reg = match pipeline_registry().lock() {
        Ok(g) => g,
        Err(_) => return to_json_err("pipeline registry lock poisoned"),
    };
    let Some(state) = reg.map.get(&handle) else {
        return to_json_err(&format!("invalid pipeline handle: {handle}"));
    };
    #[derive(Serialize)]
    struct Out {
        handle: u64,
        len: usize,
    }
    to_json_ok(Out {
        handle,
        len: state.len(),
    })
}

/// 销毁会话，释放 Rust 侧 PipelineState。
#[no_mangle]
pub extern "C" fn chan_pipeline_free(handle: u64) -> *mut c_char {
    let mut reg = match pipeline_registry().lock() {
        Ok(g) => g,
        Err(_) => return to_json_err("pipeline registry lock poisoned"),
    };
    if reg.map.remove(&handle).is_none() {
        return to_json_err(&format!("invalid pipeline handle: {handle}"));
    }
    #[derive(Serialize)]
    struct Out {
        handle: u64,
        freed: bool,
    }
    to_json_ok(Out {
        handle,
        freed: true,
    })
}

/// 筹码分桶 profile。
/// 入参 JSON：`{ "bars": [...], "cutoff_x": N?, "bucket_step": 0.1? }`
#[no_mangle]
pub extern "C" fn chan_chip_profile(req_json: *const c_char) -> *mut c_char {
    let Some(raw) = cstr_to_str(req_json) else {
        return to_json_err("req_json 不能为空");
    };
    #[derive(Deserialize)]
    struct ChipReq {
        bars: Vec<KlineBar>,
        #[serde(default)]
        cutoff_x: Option<i64>,
        #[serde(default)]
        bucket_step: Option<f64>,
    }
    let req: ChipReq = match serde_json::from_str(raw) {
        Ok(v) => v,
        Err(e) => return to_json_err(&format!("chip_profile 解析失败: {e}")),
    };
    to_json_ok(chip_profile(&req.bars, req.cutoff_x, req.bucket_step))
}

/// ML 预测：`{ "model_path": "...", "dense": [f64...] }` → `{ score }`
/// 对齐 demo6：meta 填稠密向量后打分；支持 chan_ml_v1 / 简化 XGBoost JSON。
#[no_mangle]
pub extern "C" fn chan_ml_predict(req_json: *const c_char) -> *mut c_char {
    let Some(raw) = cstr_to_str(req_json) else {
        return to_json_err("req_json 不能为空");
    };
    #[derive(Deserialize)]
    struct PredReq {
        model_path: String,
        dense: Vec<f64>,
    }
    #[derive(Serialize)]
    struct PredOut {
        score: f64,
    }
    let req: PredReq = match serde_json::from_str(raw) {
        Ok(v) => v,
        Err(e) => return to_json_err(&format!("ml_predict 解析失败: {e}")),
    };
    match ml_predict_dense(&req.model_path, &req.dense) {
        Ok(score) => to_json_ok(PredOut { score }),
        Err(e) => to_json_err(&e),
    }
}
