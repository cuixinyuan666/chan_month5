use pyo3::prelude::*;
use pyo3::types::{PyDict, PyList};
use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, OnceLock};

#[derive(Clone, Default)]
struct ChipBins {
    p: Vec<f64>,
    s: Vec<f64>,
    b: Vec<f64>,
    w: Vec<f64>,
}

#[derive(Clone, Default)]
struct Bar {
    x: i64,
    t: String,
    o: f64,
    h: f64,
    l: f64,
    c: f64,
    v: f64,
    chip_tick_bins: Option<ChipBins>,
}

#[derive(Clone, Default)]
struct SessionData {
    bars: Vec<Bar>,
    chip_bars: Vec<Bar>,
}

static SESSIONS: OnceLock<Mutex<HashMap<String, SessionData>>> = OnceLock::new();

fn sessions() -> &'static Mutex<HashMap<String, SessionData>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

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

fn list_f64(item: &PyAny, key: &str) -> Vec<f64> {
    item.get_item(key)
        .ok()
        .and_then(|v| v.extract::<Vec<f64>>().ok())
        .unwrap_or_default()
}

fn parse_bar(item: &PyAny, default_x: i64) -> Bar {
    let chip_tick_bins = item
        .get_item("chip_tick_bins")
        .ok()
        .and_then(|bins| {
            let p = list_f64(bins, "p");
            if p.is_empty() {
                return None;
            }
            Some(ChipBins {
                p,
                s: list_f64(bins, "s"),
                b: list_f64(bins, "b"),
                w: list_f64(bins, "w"),
            })
        });
    Bar {
        x: as_i64(item, "x", default_x),
        t: as_string(item, "t"),
        o: as_f64(item, "o"),
        h: as_f64(item, "h"),
        l: as_f64(item, "l"),
        c: as_f64(item, "c"),
        v: as_f64(item, "v"),
        chip_tick_bins,
    }
}

fn hash_bar(hasher: &mut blake3::Hasher, bar: &PyAny, default_x: i64) {
    hasher.update(&as_i64(bar, "x", default_x).to_le_bytes());
    hasher.update(as_string(bar, "t").as_bytes());
    for key in ["o", "h", "l", "c", "v"] {
        hasher.update(&as_f64(bar, key).to_le_bytes());
    }
}

fn accumulate_ohlc_triangle(bar: &Bar, step: f64, buckets_b: &mut BTreeMap<i64, f64>) {
    let low = bar.l.min(bar.h);
    let high = bar.l.max(bar.h);
    let mode = bar.c.max(low).min(high);
    let vol = bar.v.max(0.0);
    if high < low || vol <= 0.0 {
        return;
    }
    let i0 = (low / step).floor() as i64;
    let i1 = (high / step).ceil() as i64;
    if i1 < i0 {
        return;
    }
    if (high - low).abs() < 1e-12 {
        *buckets_b.entry(i0).or_insert(0.0) += vol;
        return;
    }
    let mut weights: Vec<(i64, f64)> = Vec::new();
    let mut total_w = 0.0;
    for key in i0..=i1 {
        let price = key as f64 * step;
        let weight = if (mode - low).abs() < 1e-12 {
            (high - price) / (high - low).max(1e-12)
        } else if (high - mode).abs() < 1e-12 {
            (price - low) / (high - low).max(1e-12)
        } else if price <= mode {
            (price - low) / (mode - low).max(1e-12)
        } else {
            (high - price) / (high - mode).max(1e-12)
        }
        .max(0.0);
        weights.push((key, weight));
        total_w += weight;
    }
    if total_w <= 1e-12 {
        return;
    }
    for (key, weight) in weights {
        if weight > 0.0 {
            *buckets_b.entry(key).or_insert(0.0) += weight / total_w * vol;
        }
    }
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
    for (idx, bar) in bars.iter().enumerate() {
        hash_bar(&mut hasher, bar, idx as i64);
    }
    if let Some(chips) = chip_bars {
        for (idx, bar) in chips.iter().enumerate() {
            hash_bar(&mut hasher, bar, idx as i64);
        }
    }
    let session_id = hasher.finalize().to_hex().to_string();
    let chip_iter = chip_bars.unwrap_or(bars);
    let mut stored_bars = Vec::with_capacity(bars.len());
    for (idx, bar) in bars.iter().enumerate() {
        stored_bars.push(parse_bar(bar, idx as i64));
    }
    let mut stored_chip_bars = Vec::with_capacity(chip_iter.len());
    for (idx, bar) in chip_iter.iter().enumerate() {
        stored_chip_bars.push(parse_bar(bar, idx as i64));
    }
    if let Ok(mut guard) = sessions().lock() {
        guard.insert(
            session_id.clone(),
            SessionData {
                bars: stored_bars,
                chip_bars: stored_chip_bars,
            },
        );
    }
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
fn next_step_delta(py: Python<'_>, session_id: String, from_step: i64, to_step: i64) -> PyResult<PyObject> {
    let d = PyDict::new(py);
    let bars = sessions()
        .lock()
        .ok()
        .and_then(|guard| guard.get(&session_id).map(|s| s.bars.clone()))
        .unwrap_or_default();
    if bars.is_empty() {
        d.set_item("from_step", from_step)?;
        d.set_item("to_step", -1)?;
        d.set_item("append_kline", PyList::empty(py))?;
        d.set_item("tail_patch", py.None())?;
        d.set_item("structure_dirty", false)?;
        return Ok(d.into());
    }
    let total = bars.len() as i64;
    let target = to_step.max(0).min(total - 1);
    let start = (from_step + 1).max(0).min(target);
    let append = PyList::empty(py);
    let mut tail_patch: Option<Py<PyAny>> = None;
    for i in start..=target {
        let bar = &bars[i as usize];
        let row = PyDict::new(py);
        row.set_item("x", bar.x)?;
        row.set_item("t", bar.t.clone())?;
        row.set_item("o", bar.o)?;
        row.set_item("h", bar.h)?;
        row.set_item("l", bar.l)?;
        row.set_item("c", bar.c)?;
        row.set_item("v", bar.v)?;
        append.append(row)?;
        tail_patch = Some(row.into());
    }
    d.set_item("from_step", from_step)?;
    d.set_item("to_step", target)?;
    d.set_item("append_kline", append)?;
    d.set_item("tail_patch", tail_patch.unwrap_or_else(|| py.None()))?;
    d.set_item("structure_dirty", true)?;
    Ok(d.into())
}

#[pyfunction]
fn chip_profile(py: Python<'_>, session_id: String, cutoff_x: Option<i64>, bucket_step: Option<f64>) -> PyResult<PyObject> {
    let step = bucket_step.unwrap_or(0.1).max(0.001);
    let bars = sessions()
        .lock()
        .ok()
        .and_then(|guard| guard.get(&session_id).map(|s| s.chip_bars.clone()))
        .unwrap_or_default();
    if !bars.is_empty() {
        let cut = cutoff_x.unwrap_or_else(|| bars.last().map(|b| b.x).unwrap_or(-1));
        let mut buckets_s: BTreeMap<i64, f64> = BTreeMap::new();
        let mut buckets_b: BTreeMap<i64, f64> = BTreeMap::new();
        for bar in bars.iter().filter(|b| b.x <= cut) {
            if let Some(bins) = &bar.chip_tick_bins {
                for (idx, price) in bins.p.iter().enumerate() {
                    if !price.is_finite() {
                        continue;
                    }
                    let key = (*price / step).floor() as i64;
                    let sv = bins.s.get(idx).copied().unwrap_or(0.0);
                    let mut bv = bins.b.get(idx).copied().unwrap_or(0.0);
                    if bins.b.is_empty() {
                        bv = bins.w.get(idx).copied().unwrap_or(0.0);
                    }
                    if sv > 0.0 {
                        *buckets_s.entry(key).or_insert(0.0) += sv;
                    }
                    if bv > 0.0 {
                        *buckets_b.entry(key).or_insert(0.0) += bv;
                    }
                }
            } else {
                accumulate_ohlc_triangle(bar, step, &mut buckets_b);
            }
        }
        let keys: Vec<i64> = buckets_s
            .keys()
            .chain(buckets_b.keys())
            .copied()
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect();
        let prices = PyList::empty(py);
        let s_vals = PyList::empty(py);
        let b_vals = PyList::empty(py);
        let totals = PyList::empty(py);
        let mut max_total = 0.0;
        for key in keys {
            let sv = *buckets_s.get(&key).unwrap_or(&0.0);
            let bv = *buckets_b.get(&key).unwrap_or(&0.0);
            let total = sv + bv;
            if total > max_total {
                max_total = total;
            }
            prices.append(key as f64 * step)?;
            s_vals.append(sv)?;
            b_vals.append(bv)?;
            totals.append(total)?;
        }
        let d = PyDict::new(py);
        d.set_item("profile_id", format!("{}:{}:{}", session_id, cut, step))?;
        d.set_item("cutoff_x", cut)?;
        d.set_item("bucket_step", step)?;
        d.set_item("prices", prices)?;
        d.set_item("s", s_vals)?;
        d.set_item("b", b_vals)?;
        d.set_item("total", totals)?;
        d.set_item("max_total", max_total)?;
        d.set_item("source", "rust")?;
        return Ok(d.into());
    }
    let d = PyDict::new(py);
    let prices = PyList::empty(py);
    let empty = PyList::empty(py);
    d.set_item(
        "profile_id",
            format!("{}:{}:{}", session_id, cutoff_x.unwrap_or(-1), step),
    )?;
    d.set_item("cutoff_x", cutoff_x)?;
    d.set_item("bucket_step", step)?;
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
