use thiserror::Error;

pub type Result<T> = std::result::Result<T, ChanDataError>;

#[derive(Debug, Error)]
pub enum ChanDataError {
    #[error("IO错误: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON错误: {0}")]
    Json(#[from] serde_json::Error),
    #[error("解析错误: {0}")]
    Parse(#[from] std::num::ParseIntError),
    #[error("{0}")]
    Msg(String),
}

impl ChanDataError {
    pub fn msg(s: impl Into<String>) -> Self {
        Self::Msg(s.into())
    }
}
