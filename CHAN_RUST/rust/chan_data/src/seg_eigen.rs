//! K2（K1连线）序列化兼容类型：计算已统一到 pipeline（Kn 流水线），
//! 本模块仅保留旧 JSON 字段名以便 Flutter 兼容读取。
//! 本文件仅保留 JSON 字段结构，由 combine::map_k1_analysis 从 Level2 映射。

use serde::{Deserialize, Serialize};

/// 特征序列线框（已弃用，保留序列化兼容）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EigenFrame {
    pub slot: i32,
    pub x1: i32,
    pub x2: i32,
    pub high: f64,
    pub low: f64,
    pub fx: String,
    pub k1_count: i32,
}

/// K1连线确认（合并 K1 bar 顶/底分型，副图「K1连线确认」）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct K1ConfirmSignal {
    /// 分型确认当步 1 分钟 K 索引
    pub x: i32,
    pub fx: String,
    /// 上涨K1连线结束=-1，下跌K1连线结束=1
    pub value: i32,
    pub ended_seg_dir: i32,
    pub peak_k1_idx: i32,
    /// 合并 K1 bar 分型区间
    #[serde(default)]
    pub fractal_x1: i32,
    #[serde(default)]
    pub fractal_x2: i32,
    #[serde(default)]
    pub fractal_high: f64,
    #[serde(default)]
    pub fractal_low: f64,
    /// 截断确认（上升/下降截断触发，非常规三元素路径）
    #[serde(default)]
    pub truncated: bool,
}

/// 首段方向锁定信号。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FirstSegDirSignal {
    pub x: i32,
    /// 首段为上涨=1，下跌=-1
    pub dir: i32,
}

/// 已确认 K1连线（主图展示用）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct K1Line {
    pub idx: i32,
    pub dir: i32,
    /// 起点/终点 K 索引（分型极点，兼容旧字段）
    pub begin_x: i32,
    pub end_x: i32,
    #[serde(default)]
    pub begin_fractal_x1: i32,
    #[serde(default)]
    pub begin_fractal_x2: i32,
    #[serde(default)]
    pub end_fractal_x1: i32,
    #[serde(default)]
    pub end_fractal_x2: i32,
    pub begin_price: f64,
    pub end_price: f64,
}

/// 逐 K 副图/十字线快照（当下冻结）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BarSubSnapshot {
    pub idx: i32,
    /// 0=未定，1=构建上涨段，-1=构建下跌段
    pub building_seg_dir: i32,
    /// 0=未定，1=首段涨，-1=首段跌
    pub first_seg_dir: i32,
    /// K1连线确认柱值（该 K 有则填，否则 0）
    pub k1_confirm: i32,
    /// 已弃用
    #[serde(default)]
    pub eigen_slot: i32,
    /// 已弃用
    #[serde(default)]
    pub eigen_frames: Vec<EigenFrame>,
}

/// K1连线分析整包（K2 兼容；旧称2段/线段）。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct K1AnalysisBundle {
    /// 已弃用（特征序列），恒为空
    #[serde(default)]
    pub eigen_frames: Vec<EigenFrame>,
    pub k1_confirms: Vec<K1ConfirmSignal>,
    pub first_seg_dir_signals: Vec<FirstSegDirSignal>,
    pub k1_lines: Vec<K1Line>,
    pub bar_sub_snapshots: Vec<BarSubSnapshot>,
    /// 当前构建段方向：0/1/-1
    pub building_seg_dir: i32,
    /// 已锁定首段方向：0/1/-1
    pub first_seg_dir: i32,
}
