use serde::{Deserialize, Serialize};

/// K 线周期：tick=原生分笔一字线；其余由分笔先聚 1m 再升周期。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum KlinePeriod {
    /// 原生分笔（每笔一根 K0，O=H=L=C）
    Tick,
    M1,
    M3,
    M5,
    M15,
    M30,
    M60,
    /// 2 小时（分钟槽 120）
    H2,
    /// 4 小时（分钟槽 240）
    H4,
    Day,
    /// 3 个连续交易日
    Day3,
    Week,
    Month,
    Month3,
    Month6,
    Month9,
    Month12,
    Quarter,
    Year,
    Year3,
    Year6,
}

impl KlinePeriod {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "tick" | "fenbi" | "分笔" => Some(Self::Tick),
            "1m" | "m1" | "k_1m" | "tick-1min" | "tick_1min" => Some(Self::M1),
            "3m" | "m3" | "k_3m" => Some(Self::M3),
            "5m" | "m5" | "k_5m" => Some(Self::M5),
            "15m" | "m15" | "k_15m" => Some(Self::M15),
            "30m" | "m30" | "k_30m" => Some(Self::M30),
            "60m" | "m60" | "k_60m" | "1h" => Some(Self::M60),
            "2h" | "120m" | "h2" => Some(Self::H2),
            "4h" | "240m" | "h4" => Some(Self::H4),
            "day" | "d" | "1d" | "k_day" | "日" | "日线" => Some(Self::Day),
            "3d" | "day3" => Some(Self::Day3),
            "week" | "w" | "1w" | "k_week" | "周" | "周线" => Some(Self::Week),
            "month" | "mon" | "1mon" | "k_mon" | "月" | "月线" => Some(Self::Month),
            "3mon" | "month3" => Some(Self::Month3),
            "6mon" | "month6" => Some(Self::Month6),
            "9mon" | "month9" => Some(Self::Month9),
            "12mon" | "month12" => Some(Self::Month12),
            "quarter" | "q" | "k_quarter" | "季" => Some(Self::Quarter),
            "year" | "y" | "1y" | "k_year" | "年" => Some(Self::Year),
            "3y" | "year3" => Some(Self::Year3),
            "6y" | "year6" => Some(Self::Year6),
            _ => None,
        }
    }

    /// 分钟/小时周期槽宽（分钟）；非此类返回 None。
    pub fn minute_slot(self) -> Option<u32> {
        match self {
            Self::M1 => Some(1),
            Self::M3 => Some(3),
            Self::M5 => Some(5),
            Self::M15 => Some(15),
            Self::M30 => Some(30),
            Self::M60 => Some(60),
            Self::H2 => Some(120),
            Self::H4 => Some(240),
            _ => None,
        }
    }

    /// 多月桶宽（1=单月）；非月类返回 None。
    pub fn month_span(self) -> Option<u32> {
        match self {
            Self::Month => Some(1),
            Self::Month3 | Self::Quarter => Some(3),
            Self::Month6 => Some(6),
            Self::Month9 => Some(9),
            Self::Month12 => Some(12),
            _ => None,
        }
    }

    /// 多年桶宽；非年类返回 None。
    pub fn year_span(self) -> Option<u32> {
        match self {
            Self::Year => Some(1),
            Self::Year3 => Some(3),
            Self::Year6 => Some(6),
            _ => None,
        }
    }

    pub fn is_tick(self) -> bool {
        matches!(self, Self::Tick)
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
    /// 展示用时间文本（tick 含秒：YYYY/MM/DD HH:MM:SS；其它多为到分）
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
