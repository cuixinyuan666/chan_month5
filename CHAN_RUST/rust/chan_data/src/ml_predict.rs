//! 外部模型预测（对齐 Vespa demo6：meta 对齐稠密向量 → 打分）。
//! 支持：
//! 1) `chan_ml_v1`：logistic / linear（weights + bias）
//! 2) 简化 XGBoost JSON trees（常见 save_model json 的 tree 数组）

use serde::Deserialize;
use serde_json::Value;
use std::fs;
use std::path::Path;

pub const MISSING: f64 = -9999999.0;

#[derive(Debug, Deserialize)]
struct ChanMlV1 {
    #[allow(dead_code)]
    format: String,
    #[serde(default)]
    bias: f64,
    weights: Vec<f64>,
    /// logistic（默认）或 linear
    #[serde(default = "default_objective")]
    objective: String,
}

fn default_objective() -> String {
    "logistic".to_string()
}

fn sigmoid(x: f64) -> f64 {
    1.0 / (1.0 + (-x).exp())
}

/// 用模型文件 + 稠密特征打分。
pub fn predict_dense(model_path: &str, dense: &[f64]) -> Result<f64, String> {
    let path = Path::new(model_path);
    if !path.exists() {
        return Err(format!("模型文件不存在: {model_path}"));
    }
    let raw = fs::read_to_string(path).map_err(|e| format!("读模型失败: {e}"))?;
    let v: Value = serde_json::from_str(&raw).map_err(|e| format!("模型 JSON 解析失败: {e}"))?;

    if let Some(fmt) = v.get("format").and_then(|x| x.as_str()) {
        if fmt == "chan_ml_v1" {
            let m: ChanMlV1 =
                serde_json::from_value(v).map_err(|e| format!("chan_ml_v1 解析失败: {e}"))?;
            return Ok(predict_chan_ml_v1(&m, dense));
        }
    }

    // XGBoost JSON：尝试 learner.gradient_booster.model
    if let Some(score) = try_predict_xgboost_json(&v, dense) {
        return Ok(score);
    }

    Err(
        "无法识别模型格式：请使用 chan_ml_v1（weights+bias）或兼容的 XGBoost model.json"
            .to_string(),
    )
}

fn predict_chan_ml_v1(m: &ChanMlV1, dense: &[f64]) -> f64 {
    let n = m.weights.len().min(dense.len());
    let mut s = m.bias;
    for i in 0..n {
        let x = dense[i];
        if (x - MISSING).abs() < 1e-12 {
            continue;
        }
        s += m.weights[i] * x;
    }
    if m.objective == "linear" {
        s
    } else {
        sigmoid(s)
    }
}

fn try_predict_xgboost_json(root: &Value, dense: &[f64]) -> Option<f64> {
    let model = root
        .pointer("/learner/gradient_booster/model")
        .or_else(|| root.pointer("/gradient_booster/model"))
        .or_else(|| root.get("model"))?;

    let trees = model.get("trees")?.as_array()?;
    let mut base = model
        .get("base_score")
        .and_then(|x| parse_f64(x))
        .unwrap_or(0.5);
    // xgb 常把 base_score 存成字符串
    if let Some(arr) = model.get("base_score").and_then(|x| x.as_array()) {
        if let Some(v) = arr.first().and_then(parse_f64) {
            base = v;
        }
    }

    let mut sum = 0.0;
    for t in trees {
        sum += eval_xgb_tree(t, dense)?;
    }
    // binary:logistic：sigmoid(margin)；若 base_score 已在 (0,1) 作先验则用 logit 近似
    let margin = if base > 0.0 && base < 1.0 {
        (base / (1.0 - base)).ln() + sum
    } else {
        base + sum
    };
    Some(sigmoid(margin))
}

fn parse_f64(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

/// 简化树：split_* / children / base_weights；缺省读 default_left（与 XGB JSON 对齐）。
fn eval_xgb_tree(tree: &Value, dense: &[f64]) -> Option<f64> {
    let split_idx = tree.get("split_indices")?.as_array()?;
    let split_cond = tree.get("split_conditions")?.as_array()?;
    let left = tree.get("left_children")?.as_array()?;
    let right = tree.get("right_children")?.as_array()?;
    let base_weights = tree.get("base_weights")?.as_array()?;
    // XGB：true/1 → missing 走左；缺字段时保持旧行为（走左）
    let default_left = tree.get("default_left").and_then(|x| x.as_array());

    let mut node: i64 = 0;
    for _ in 0..512 {
        if node < 0 {
            break;
        }
        let ni = node as usize;
        if ni >= left.len() {
            break;
        }
        let l = left[ni].as_i64()?;
        let r = right[ni].as_i64()?;
        // 叶节点：左右为 -1
        if l < 0 && r < 0 {
            return base_weights.get(ni).and_then(parse_f64);
        }
        let fidx = split_idx.get(ni)?.as_u64()? as usize;
        let thr = split_cond.get(ni).and_then(parse_f64).unwrap_or(0.0);
        let x = dense.get(fidx).copied().unwrap_or(MISSING);
        if (x - MISSING).abs() < 1e-12 {
            let go_left = match default_left.and_then(|a| a.get(ni)) {
                Some(Value::Bool(b)) => *b,
                Some(Value::Number(n)) => n.as_i64().unwrap_or(1) != 0,
                _ => true,
            };
            node = if go_left { l } else { r };
            continue;
        }
        node = if x < thr { l } else { r };
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn chan_ml_v1_logistic() {
        let mut f = NamedTempFile::new().unwrap();
        write!(
            f,
            r#"{{"format":"chan_ml_v1","bias":0.0,"weights":[1.0, -1.0],"objective":"logistic"}}"#
        )
        .unwrap();
        let s = predict_dense(f.path().to_str().unwrap(), &[2.0, 0.0]).unwrap();
        assert!(s > 0.5);
    }

    #[test]
    fn xgb_missing_follows_default_left() {
        // 单树：根 split f0；default_left=false → missing 走右叶 weight=2
        let raw = r#"{
          "learner":{"gradient_booster":{"model":{
            "base_score":[0.5],
            "trees":[{
              "split_indices":[0, 0, 0],
              "split_conditions":[0.0, 0.0, 0.0],
              "left_children":[1, -1, -1],
              "right_children":[2, -1, -1],
              "base_weights":[0.0, -1.0, 2.0],
              "default_left":[0, 1, 1]
            }]
          }}}
        }"#;
        let mut f = NamedTempFile::new().unwrap();
        write!(f, "{raw}").unwrap();
        let s = predict_dense(f.path().to_str().unwrap(), &[MISSING]).unwrap();
        // margin ≈ logit(0.5)+2 → sigmoid 接近 1
        assert!(s > 0.8, "score={s}");
    }
}
