use pyo3::prelude::*;
use pyo3::types::{PyDict, PyList};

fn as_f64(item: &PyAny, key: &str) -> f64 {
    item.get_item(key)
        .ok()
        .and_then(|v| v.extract::<f64>().ok())
        .filter(|v| v.is_finite())
        .unwrap_or(0.0)
}

fn as_i64(item: &PyAny, key: &str, default: i64) -> i64 {
    item.get_item(key)
        .ok()
        .and_then(|v| v.extract::<i64>().ok())
        .unwrap_or(default)
}

fn as_string(item: &PyAny, key: &str) -> String {
    item.get_item(key)
        .ok()
        .and_then(|v| v.extract::<String>().ok())
        .unwrap_or_default()
}

#[pyfunction]
fn cache_status(py: Python<'_>) -> PyResult<PyObject> {
    let d = PyDict::new(py);
    d.set_item("rust_available", true)?;
    d.set_item("engine_mode", "rust")?;
    d.set_item("payload_version", 2)?;
    Ok(d.into())
}

#[pyfunction]
fn normalize_bars(py: Python<'_>, bars: &PyList) -> PyResult<PyObject> {
    let out = PyDict::new(py);
    let xs = PyList::empty(py);
    let ts = PyList::empty(py);
    let opens = PyList::empty(py);
    let highs = PyList::empty(py);
    let lows = PyList::empty(py);
    let closes = PyList::empty(py);
    let volumes = PyList::empty(py);

    for (idx, bar) in bars.iter().enumerate() {
        let default_x = idx as i64;
        xs.append(as_i64(bar, "x", default_x))?;
        ts.append(as_string(bar, "t"))?;
        opens.append(as_f64(bar, "o"))?;
        highs.append(as_f64(bar, "h"))?;
        lows.append(as_f64(bar, "l"))?;
        closes.append(as_f64(bar, "c"))?;
        volumes.append(as_f64(bar, "v"))?;
    }

    out.set_item("x", xs)?;
    out.set_item("t", ts)?;
    out.set_item("open", opens)?;
    out.set_item("high", highs)?;
    out.set_item("low", lows)?;
    out.set_item("close", closes)?;
    out.set_item("volume", volumes)?;
    Ok(out.into())
}

#[pyfunction(signature = (code, k_type, begin_date, bars, end_date=None, chip_bars=None))]
fn load_session(
    py: Python<'_>,
    code: String,
    k_type: String,
    begin_date: String,
    bars: &PyList,
    end_date: Option<String>,
    chip_bars: Option<&PyList>,
) -> PyResult<PyObject> {
    let mut hasher = blake3::Hasher::new();
    hasher.update(code.as_bytes());
    hasher.update(k_type.as_bytes());
    hasher.update(begin_date.as_bytes());
    hasher.update(end_date.clone().unwrap_or_default().as_bytes());
    hasher.update(bars.len().to_string().as_bytes());
    let chip_len = chip_bars.map(|x| x.len()).unwrap_or_else(|| bars.len());
    hasher.update(chip_len.to_string().as_bytes());
    let session_id = hasher.finalize().to_hex().to_string();
    let d = PyDict::new(py);
    d.set_item("session_id", session_id)?;
    d.set_item("payload_version", 2)?;
    d.set_item("engine_mode", "rust")?;
    d.set_item("bar_count", bars.len())?;
    d.set_item("chip_bar_count", chip_len)?;
    Ok(d.into())
}

#[pyfunction]
fn step_to(py: Python<'_>, session_id: String, target_step: i64) -> PyResult<PyObject> {
    next_step_delta(py, session_id, target_step - 1, target_step)
}

#[pyfunction]
fn next_step_delta(py: Python<'_>, _session_id: String, from_step: i64, to_step: i64) -> PyResult<PyObject> {
    let d = PyDict::new(py);
    d.set_item("from_step", from_step)?;
    d.set_item("to_step", to_step)?;
    d.set_item("append_kline", PyList::empty(py))?;
    d.set_item("tail_patch", py.None())?;
    d.set_item("structure_dirty", true)?;
    Ok(d.into())
}

#[pyfunction]
fn chip_profile(py: Python<'_>, session_id: String, cutoff_x: Option<i64>, bucket_step: Option<f64>) -> PyResult<PyObject> {
    let d = PyDict::new(py);
    let prices = PyList::empty(py);
    let empty = PyList::empty(py);
    d.set_item(
        "profile_id",
        format!("{}:{}:{}", session_id, cutoff_x.unwrap_or(-1), bucket_step.unwrap_or(0.1)),
    )?;
    d.set_item("cutoff_x", cutoff_x)?;
    d.set_item("bucket_step", bucket_step.unwrap_or(0.1))?;
    d.set_item("prices", prices)?;
    d.set_item("s", empty)?;
    d.set_item("b", PyList::empty(py))?;
    d.set_item("total", PyList::empty(py))?;
    d.set_item("max_total", 0.0)?;
    d.set_item("source", "rust")?;
    Ok(d.into())
}

#[pyfunction]
fn clear_cache(py: Python<'_>) -> PyResult<PyObject> {
    let d = PyDict::new(py);
    d.set_item("removed", 0)?;
    d.set_item("rust_available", true)?;
    Ok(d.into())
}

#[pymodule]
fn a_rust_core_ext(_py: Python<'_>, m: &PyModule) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(cache_status, m)?)?;
    m.add_function(wrap_pyfunction!(normalize_bars, m)?)?;
    m.add_function(wrap_pyfunction!(load_session, m)?)?;
    m.add_function(wrap_pyfunction!(step_to, m)?)?;
    m.add_function(wrap_pyfunction!(next_step_delta, m)?)?;
    m.add_function(wrap_pyfunction!(chip_profile, m)?)?;
    m.add_function(wrap_pyfunction!(clear_cache, m)?)?;
    Ok(())
}
