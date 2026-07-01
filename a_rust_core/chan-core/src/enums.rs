#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KlineDir {
    Up,
    Down,
    Combine,
    Included,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FxType {
    Bottom,
    Top,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BiDir {
    Up,
    Down,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BspType {
    T1,
    T1P,
    T2,
    T2S,
    T3A,
    T3B,
}

impl BspType {
    pub fn as_str(self) -> &'static str {
        match self {
            BspType::T1 => "1",
            BspType::T1P => "1p",
            BspType::T2 => "2",
            BspType::T2S => "2s",
            BspType::T3A => "3a",
            BspType::T3B => "3b",
        }
    }
}
