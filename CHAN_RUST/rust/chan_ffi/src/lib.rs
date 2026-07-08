//! Flutter `dart:ffi` 桥：返回 JSON 字符串指针，调用方负责 `chan_free_string`。

use std::ffi::{c_char, CStr, CString};
use std::ptr;

use chan_data::{
    build_kline_combine_bundle, default_data_root, list_stock_codes, load_klines, resolve_data_root,
    KlineBar, KlinePeriod,
};
use serde::Serialize;

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

/// 加载 K 线。period 示例：day / 5m / 1m。
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

/// 对已加载 K 线 JSON 数组做包含合并，返回 {frames, bi_confirms}。
#[no_mangle]
pub extern "C" fn chan_kline_combine_frames(bars_json: *const c_char) -> *mut c_char {
    let Some(raw) = cstr_to_str(bars_json) else {
        return to_json_err("bars_json 不能为空");
    };
    let bars: Vec<KlineBar> = match serde_json::from_str(raw) {
        Ok(v) => v,
        Err(e) => return to_json_err(&format!("bars_json 解析失败: {e}")),
    };
    to_json_ok(build_kline_combine_bundle(&bars))
}
