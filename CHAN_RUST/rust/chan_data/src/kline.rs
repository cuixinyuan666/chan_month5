use serde::{Deserialize, Serialize};

/// K 线周期（与 Python KL_TYPE 常用项对应）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum KlinePeriod {
    M1,
    M3,
    M5,
    M15,
    M30,
    M60,
    Day,
    Week,
    Month,
    Quarter,
    Year,
}

impl KlinePeriod {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "1m" | "m1" | "k_1m" | "tick-1min" | "tick_1min" => Some(Self::M1),
            "3m" | "m3" | "k_3m" => Some(Self::M3),
            "5m" | "m5" | "k_5m" => Some(Self::M5),
            "15m" | "m15" | "k_15m" => Some(Self::M15),
            "30m" | "m30" | "k_30m" => Some(Self::M30),
            "60m" | "m60" | "k_60m" => Some(Self::M60),
            "day" | "d" | "k_day" | "日" | "日线" => Some(Self::Day),
            "week" | "w" | "k_week" | "周" | "周线" => Some(Self::Week),
            "month" | "mon" | "k_mon" | "月" | "月线" => Some(Self::Month),
            "quarter" | "q" | "k_quarter" | "季" => Some(Self::Quarter),
            "year" | "y" | "k_year" | "年" => Some(Self::Year),
            _ => None,
        }
    }

    /// 分钟周期槽宽；非分钟类返回 None。
    pub fn minute_slot(self) -> Option<u32> {
        match self {
            Self::M1 => Some(1),
            Self::M3 => Some(3),
            Self::M5 => Some(5),
            Self::M15 => Some(15),
            Self::M30 => Some(30),
            Self::M60 => Some(60),
            _ => None,
        }
    }
}

/// 单根 K 线（字典式主 K 单元，对齐 CKLine_Unit 核心字段 + 可扩展指标槽）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KlineBar {
    /// K 线序号（0 起，与主图 x 对齐）
    #[serde(default)]
    pub idx: i32,
    /// 毫秒时间戳（UTC 本地日历语义，与 Python CTime 一致）
    pub time_ms: i64,
    /// 展示用时间文本 YYYY/MM/DD HH:MM
    pub time_text: String,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub volume: f64,
    pub amount: f64,
    /// 配套指标数值（macd/boll/rsi 等，随模块逐步填充）
    #[serde(default)]
    pub metrics: serde_json::Map<String, serde_json::Value>,
}
