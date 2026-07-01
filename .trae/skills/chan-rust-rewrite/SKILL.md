---
name: "chan-rust-rewrite"
description: "缠论核心计算逻辑 Rust 改写指南。当修改核心计算模块（Bi/Seg/ZS/KLine/Combiner/BuySellPoint/Math）或新增 Rust 侧代码时，必须调用此 Skill 确保改写一致性、PyO3 绑定规范、跨平台（Android）兼容性。"
---

# 缠论核心计算 Rust 改写指南

## 触发条件

当以下任一情况发生时，**必须**调用此 Skill：

1. **新增 Rust 侧代码**（`chan-core/` 下的任何 `.rs` 文件）
2. **修改核心计算模块**（`Bi/`、`Seg/`、`ZS/`、`KLine/`、`Combiner/`、`BuySellPoint/`、`Math/`）且改动涉及 Rust 已实现的部分
3. **修改 PyO3 绑定代码**（`chan-core/src/lib.rs` 或各模块的 `_pyo3.rs`）
4. **新增/修改配置项**可能影响 Rust 侧计算逻辑
5. **用户问"Rust 改写进度"、"Rust 侧怎么改"、"移植 Android"**

---

## 一、总体架构

### 1.1 分层设计（三层解耦）

```
┌──────────────────────────────────────────────────────────────┐
│  Layer 3: 平台适配层（platform/）                              │
│  ├─ platform::python     → PyO3 绑定（当前桌面端）             │
│  └─ platform::android    → JNI 绑定（未来 Android 端）         │
├──────────────────────────────────────────────────────────────┤
│  Layer 2: 核心计算层（core/）—— 纯 Rust，无 FFI 依赖           │
│  ├─ core::common         → 枚举、配置、数据结构（KLineUnit）    │
│  ├─ core::kline          → K线合并 & 包含处理                  │
│  ├─ core::bi             → 笔的生成 & 修正                     │
│  ├─ core::seg            → 线段划分（特征序列）                 │
│  ├─ core::zs             → 中枢识别 & 合并                     │
│  ├─ core::bsp            → 买卖点判定                          │
│  └─ core::math           → 技术指标（MACD/BOLL/KDJ/RSI）       │
├──────────────────────────────────────────────────────────────┤
│  Layer 1: 序列化层（serde）—— 跨语言数据交换                    │
│  ├─ JSON / MessagePack   → 配置、结果序列化                    │
│  └─ Arrow / FlatBuffers  → 大量 K 线数据零拷贝传输             │
└──────────────────────────────────────────────────────────────┘
```

**核心原则**：`core::` 层是纯 Rust 代码，**不依赖任何 FFI 框架**（PyO3/JNI）。平台适配层负责把 `core::` 的数据结构桥接到 Python/Android。

---

## 二、Rust 项目结构

### 2.1 目录结构（`chan-core/`）

```
chan-core/
├── Cargo.toml                    # 根 crate，多个 feature flag
├── src/
│   ├── lib.rs                    # 仅 re-export，无逻辑
│   ├── core/                     # ★ 核心计算层（纯 Rust，无 FFI 依赖）
│   │   ├── mod.rs
│   │   ├── common/
│   │   │   ├── mod.rs
│   │   │   ├── enums.rs          # KL_TYPE, BI_DIR, FX_TYPE, BSP_TYPE 等
│   │   │   ├── config.rs         # ChanConfig, BiConfig, SegConfig 等
│   │   │   ├── kl_unit.rs        # KLineUnit 数据结构
│   │   │   └── time.rs           # CTime 等价（年月日时分）
│   │   ├── kline/
│   │   │   ├── mod.rs
│   │   │   ├── combiner.rs       # 包含处理（test_combine, add_klu）
│   │   │   ├── merged_kl.rs      # 合并后 K 线（CKLine 等价）
│   │   │   └── kl_list.rs        # 某周期 K 线列表
│   │   ├── bi/
│   │   │   ├── mod.rs
│   │   │   ├── bi.rs             # 单根笔
│   │   │   └── bi_list.rs        # 笔列表（try_create_first_bi, update_bi）
│   │   ├── seg/
│   │   │   ├── mod.rs
│   │   │   ├── seg.rs            # 单根线段
│   │   │   ├── eigen_fx.rs       # 特征序列分型
│   │   │   └── seg_list_chan.rs  # 缠论标准线段算法
│   │   ├── zs/
│   │   │   ├── mod.rs
│   │   │   ├── zs.rs             # 单根中枢
│   │   │   └── zs_list.rs        # 中枢列表
│   │   ├── bsp/
│   │   │   ├── mod.rs
│   │   │   ├── bs_point.rs       # 单个买卖点
│   │   │   └── bsp_list.rs       # 买卖点列表
│   │   └── math/
│   │       ├── mod.rs
│   │       ├── macd.rs           # MACD（EMA 递推）
│   │       ├── boll.rs           # BOLL 布林带
│   │       ├── kdj.rs            # KDJ 随机指标
│   │       ├── rsi.rs            # RSI 相对强弱
│   │       └── demark.rs         # 德马克序列
│   ├── platform/                 # ★ 平台适配层
│   │   ├── mod.rs
│   │   ├── python/               # PyO3 绑定（当前桌面端）
│   │   │   ├── mod.rs
│   │   │   ├── common_py.rs      # CKLineUnit, CTime 的 #[pyclass]
│   │   │   ├── kline_py.rs
│   │   │   ├── bi_py.rs
│   │   │   ├── seg_py.rs
│   │   │   ├── zs_py.rs
│   │   │   ├── bsp_py.rs
│   │   │   └── math_py.rs
│   │   └── android/              # JNI 绑定（未来 Android 端）
│   │       └── mod.rs
│   └── serde_utils.rs            # 序列化工具（JSON/MessagePack/Arrow）
├── tests/                        # 集成测试
│   ├── test_bi.rs
│   ├── test_seg.rs
│   ├── test_zs.rs
│   └── fixtures/                 # 测试用 K 线数据
└── benches/                      # 性能基准测试
    ├── bench_combiner.rs
    ├── bench_bi.rs
    └── bench_macd.rs
```

### 2.2 Cargo.toml Feature Flags

```toml
[package]
name = "chan-core"
version = "0.1.0"
edition = "2021"

[features]
default = ["python"]
python = ["pyo3", "numpy"]       # 桌面端 PyO3 绑定
android = ["jni"]                # 未来 Android JNI 绑定
serde_json = ["dep:serde_json"]  # JSON 序列化
serde_msgpack = ["dep:rmp-serde"] # MessagePack 序列化
arrow = ["dep:arrow"]            # Arrow 列式传输

[dependencies]
serde = { version = "1", features = ["derive"], optional = true }
serde_json = { version = "1", optional = true }
rmp-serde = { version = "1", optional = true }
pyo3 = { version = "0.22", features = ["extension-module"], optional = true }
numpy = { version = "0.22", optional = true }
jni = { version = "0.21", optional = true }
arrow = { version = "53", optional = true }
```

### 2.3 Python 侧文件命名规范（不污染缠论逻辑）

**核心原则**：Rust 改写过程中，Python 侧新增的 Rust 相关文件/文件夹**必须使用 `a_` 前缀**，确保不污染现有缠论 Python 逻辑，一眼可区分哪些是 Rust 桥接代码。

```
chan.py/                          # Python 工程根目录
├── Bi/                            # 纯 Python 缠论逻辑（不改动）
├── Seg/                           # 纯 Python 缠论逻辑（不改动）
├── ZS/                            # 纯 Python 缠论逻辑（不改动）
├── KLine/                         # 纯 Python 缠论逻辑（不改动）
├── Combiner/                      # 纯 Python 缠论逻辑（不改动）
├── BuySellPoint/                  # 纯 Python 缠论逻辑（不改动）
├── Math/                          # 纯 Python 缠论逻辑（不改动）
│
├── a_rust_core/                   # ★ Rust 桥接调度层（a_ 前缀）
│   ├── a_rust_dispatch.py         # 统一调度器，根据配置选择 Python/Rust
│   ├── a_rust_math.py             # Math 模块调度器（MACD/BOLL/KDJ/RSI）
│   ├── a_rust_combiner.py         # K线合并模块调度器
│   ├── a_rust_bi.py               # 笔计算模块调度器
│   ├── a_rust_seg.py              # 线段计算模块调度器
│   ├── a_rust_zs.py               # 中枢计算模块调度器
│   ├── a_rust_bsp.py              # 买卖点模块调度器
│   ├── a_rust_timer.py            # 耗时统计 & 计时工具
│   └── a_rust_config.py           # Rust 开关配置项定义
│
├── a_rust_bench/                  # ★ Rust 性能基准测试（a_ 前缀）
│   ├── a_bench_runner.py          # 性能对比跑分入口
│   └── a_bench_report.py          # 报告生成
│
└── chan-core/                     # ★ Rust 工程（独立 crate，非 Python 包）
    ├── Cargo.toml
    └── src/...
```

**命名规则**：

| 类型 | 命名格式 | 示例 |
|------|---------|------|
| Rust 桥接调度文件夹 | `a_rust_*` | `a_rust_core/`, `a_rust_bench/` |
| Rust 桥接调度 Python 文件 | `a_rust_*.py` | `a_rust_math.py`, `a_rust_dispatch.py` |
| Rust crate 项目 | `chan-core/`（独立 Rust 项目） | 不需要 `a_` 前缀 |

**导入方式**（Python 侧调用 Rust 调度器）：

```python
# Chan.py 或 a_replay_trainer.py 中

# 旧方式（纯 Python，保持不变）
from Math.MACD import CMACD

# 新方式（通过 a_rust 调度器，内部自动选择 Python 或 Rust）
from a_rust_core.a_rust_math import CMACD_Rust  # 调度器类
```

**关键约束**：

| 约束 | 说明 |
|------|------|
| 不改动 `Bi/`、`Seg/`、`ZS/` 等原始目录 | 纯 Python 缠论逻辑保持原样不动 |
| 调度器负责引入原始 Python 类 | `a_rust_math.py` 内部 `from Math.MACD import CMACD`，不修改原始文件 |
| `chan-core/` 是独立 Rust crate | 不放在 `a_` 文件夹内，因为它是 Rust 项目而非 Python 代码 |
| 新增测试文件也用 `a_` 前缀 | 如 `a_test_rust_math.py`，调试结束后删除 |

---

## 三、逐K当下性（Rust 侧实现规范）

### 3.1 核心原则

含 `逐K喂数据` 的模式下，Rust 侧必须严格遵守：

| 原则 | Rust 实现 |
|------|----------|
| BSP 写入后冻结 | `BSPointList` 中已确认的买卖点不可变，新 BSP 只能 `push` |
| 结构签名只用于缓存 | `StructureSignature` 仅用于性能缓存，不参与逻辑判定 |
| 签名重算输入截断 | 重算时 `kl_slice[..step_idx]` 严格截断到当前已喂入 |
| 末态修正不混入历史 | 末态结构快照与历史 BSP 分属不同数据结构 |

### 3.2 Rust 实现模式

```rust
// core::bsp::bsp_list.rs

/// 买卖点列表（支持逐K当下性）
pub struct BSPointList {
    /// 已确认的买卖点（写入后冻结）
    confirmed: Vec<BSPoint>,
    /// 当前步进索引（已喂入的 K 线根数）
    step_idx: usize,
    /// 末态全量 BSP（仅用于展示，不参与逐K判定）
    final_snapshot: Option<Vec<BSPoint>>,
}

impl BSPointList {
    /// 逐K增量：只基于 kl_data[..step_idx] 判定新买卖点
    pub fn step_update(&mut self, kl_data: &[KLineUnit], config: &BSPointConfig) {
        let visible = &kl_data[..self.step_idx];
        // 只判定当前可见数据能确定的买卖点
        if let Some(new_bsp) = self.try_detect(visible, config) {
            self.confirmed.push(new_bsp); // 写入后冻结
        }
        self.step_idx += 1;
    }

    /// 获取历史 BSP（只返回已确认的）
    pub fn history(&self) -> &[BSPoint] {
        &self.confirmed
    }

    /// 构建末态快照（仅用于首屏展示，标记为 final_snapshot）
    pub fn build_final_snapshot(&mut self, kl_data: &[KLineUnit], config: &BSPointConfig) {
        self.final_snapshot = Some(self.compute_all(kl_data, config));
    }
}
```

---

## 四、PyO3 绑定规范（当前桌面端）

### 4.1 数据传递方向

```
Python → Rust:  CKLine_Unit 列表（逐K喂入）
Rust → Python:  计算结果（Bi/Seg/ZS/BSP 列表）
```

### 4.2 零拷贝传输

使用 `numpy` 数组传递 OHLCV 数据，避免 Python 对象序列化开销：

```rust
// platform::python::common_py.rs

use pyo3::prelude::*;
use numpy::PyReadonlyArray2;

/// 从 numpy 数组批量创建 KLineUnit
#[pyfunction]
fn create_kl_units_from_numpy(
    py: Python<'_>,
    ohlcv: PyReadonlyArray2<f64>,  // shape: (N, 5), columns: [open, high, low, close, volume]
    timestamps: Vec<i64>,           // Unix 毫秒时间戳
) -> PyResult<Vec<KLineUnit>> {
    let arr = ohlcv.as_array();
    let mut units = Vec::with_capacity(arr.nrows());
    for (i, row) in arr.rows().into_iter().enumerate() {
        units.push(KLineUnit {
            time: CTime::from_unix_ms(timestamps[i]),
            open: row[0],
            high: row[1],
            low: row[2],
            close: row[3],
            volume: row[4],
            ..Default::default()
        });
    }
    Ok(units)
}
```

### 4.3 计算结果返回

```rust
// platform::python::bi_py.rs

use pyo3::prelude::*;

/// Rust 侧笔列表的 Python 包装
#[pyclass]
pub struct PyBiList {
    inner: core::bi::BiList,
}

#[pymethods]
impl PyBiList {
    #[new]
    fn new(config: &PyBiConfig) -> Self {
        Self { inner: core::bi::BiList::new(config.inner.clone()) }
    }

    /// 喂入一根合并后的 K 线，返回是否产生了新笔
    fn feed_klc(&mut self, klc: &PyMergedKLine) -> bool {
        self.inner.feed_klc(&klc.inner)
    }

    /// 获取已确认的笔列表（Python 可直接遍历）
    fn get_bi_list(&self) -> Vec<PyBi> {
        self.inner.confirmed().iter().map(|bi| PyBi::from(bi.clone())).collect()
    }
}
```

### 4.4 maturin 构建配置

```toml
# chan-core/pyproject.toml
[build-system]
requires = ["maturin>=1.5"]
build-backend = "maturin"

[project]
name = "chan_core"
requires-python = ">=3.10"

[tool.maturin]
features = ["python", "serde_json"]
python-source = "python"
module-name = "chan_core._core"
```

### 4.5 Python 侧调用方式

```python
# chan.py 中逐步切换到 Rust 模块

# 旧方式（纯 Python）
from Math.MACD import CMACD
macd = CMACD(12, 26, 9)

# 新方式（Rust 加速）
import chan_core
macd = chan_core.MACD(12, 26, 9)

# 双轨验证：通过配置开关同时运行两个版本，diff 结果
if config.use_rust_math:
    macd = chan_core.MACD(12, 26, 9)
else:
    from Math.MACD import CMACD
    macd = CMACD(12, 26, 9)
```

---

## 五、Android 移植兼容性规范

### 5.1 核心层无 FFI 依赖（最关键）

`core::` 下的所有代码**只能依赖**：

| 允许依赖 | 禁止依赖 |
|---------|---------|
| `std`（`Vec`, `HashMap`, `f64` 等） | `pyo3` |
| `serde`（`Serialize`/`Deserialize` trait） | `numpy` |
| 自定义纯 Rust crate | `jni`（Android 侧在 `platform::android` 中使用） |
| | 任何 Python 相关 crate |
| | 任何 Android 相关 crate |

### 5.2 数据结构内存布局

Rust 侧数据结构应考虑 Android 端的内存限制（移动端通常 512MB~2GB）：

```rust
// 使用 u32 代替 usize 减少内存占用（Android 32位兼容）
pub struct KLineUnit {
    pub time: CTime,         // 8 bytes
    pub open: f64,           // 8 bytes
    pub high: f64,           // 8 bytes
    pub low: f64,            // 8 bytes
    pub close: f64,          // 8 bytes
    pub volume: f64,         // 8 bytes
    pub turnover: f64,       // 8 bytes
    pub turnrate: f64,       // 8 bytes
    // 总计: 64 bytes/根，10000 根 ≈ 640KB（可接受）
}

// 使用 Box<[T]> 代替 Vec<T> 减少 8 bytes 的 capacity 字段
pub struct BiList {
    confirmed: Box<[Bi]>,  // 冻结后转为 Box<[T]>，无 capacity 开销
    pending: Vec<Bi>,      // 未确认的笔仍然用 Vec
}
```

### 5.3 JNI 绑定预留

```rust
// platform::android::mod.rs（未来实现）

#[cfg(feature = "android")]
pub mod android {
    use jni::JNIEnv;
    use jni::objects::{JClass, JObject};
    use jni::sys::{jlong, jboolean};

    /// Android 端 JNI 入口
    #[no_mangle]
    pub extern "system" fn Java_com_chan_core_ChanCore_nativeInit(
        _env: JNIEnv,
        _class: JClass,
        config_json: JObject,
    ) -> jlong {
        // 从 JSON 解析配置 → 初始化 core::ChanEngine
        // 返回引擎指针（jlong）
        0
    }

    #[no_mangle]
    pub extern "system" fn Java_com_chan_core_ChanCore_nativeFeedKLine(
        mut env: JNIEnv,
        _class: JClass,
        engine_ptr: jlong,
        open: jdouble, high: jdouble, low: jdouble,
        close: jdouble, volume: jdouble,
        timestamp: jlong,
    ) -> jboolean {
        // 逐K喂入 → 调用 core::ChanEngine::feed_kline()
        // 返回是否有新结构产生
        false
    }
}
```

### 5.4 跨平台序列化

使用 `serde` + JSON/MessagePack 作为 Rust → Android 的数据交换格式：

```rust
// core::common::kl_unit.rs

use serde::{Serialize, Deserialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KLineUnit {
    pub time: CTime,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    #[serde(default)]
    pub volume: f64,
    #[serde(default)]
    pub turnover: f64,
    #[serde(default)]
    pub turnrate: f64,
}
```

---

## 六、改写阶段与优先级

### 阶段 0：基础设施（`common`）

| 任务 | 依赖 | 预估工量 | 优先级 |
|------|------|---------|--------|
| `Cargo.toml` + feature flags | 无 | 小 | P0 |
| `core::common::enums` | 无 | 小 | P0 |
| `core::common::config` | `enums` | 小 | P0 |
| `core::common::kl_unit` + `time` | 无 | 小 | P0 |
| `platform::python::common_py` | `kl_unit` | 中 | P0 |
| 双轨验证框架 | `common_py` | 中 | P0 |

### 阶段 1：技术指标（`math`）—— 收益最高、风险最低

| 任务 | 依赖 | 预估工量 | 优先级 |
|------|------|---------|--------|
| `core::math::macd` | `common` | 小 | P1 |
| `core::math::boll` | `common` | 小 | P1 |
| `core::math::kdj` | `common` | 小 | P1 |
| `core::math::rsi` | `common` | 小 | P1 |
| `platform::python::math_py` | `math` | 中 | P1 |
| Math 性能基准测试 | `math_py` | 小 | P1 |

### 阶段 2：K 线合并（`kline`）

| 任务 | 依赖 | 预估工量 | 优先级 |
|------|------|---------|--------|
| `core::kline::combiner` | `common` | 中 | P2 |
| `core::kline::merged_kl` | `combiner` | 中 | P2 |
| `platform::python::kline_py` | `kline` | 中 | P2 |
| 包含处理正确性 diff 验证 | `kline_py` | 中 | P2 |

### 阶段 3：笔（`bi`）

| 任务 | 依赖 | 预估工量 | 优先级 |
|------|------|---------|--------|
| `core::bi::bi` | `kline` | 中 | P3 |
| `core::bi::bi_list` | `bi` | 大 | P3 |
| `platform::python::bi_py` | `bi_list` | 中 | P3 |
| 笔端点修正逻辑验证 | `bi_py` | 大 | P3 |

### 阶段 4：线段（`seg`）

| 任务 | 依赖 | 预估工量 | 优先级 |
|------|------|---------|--------|
| `core::seg::eigen_fx` | `bi` | 大 | P4 |
| `core::seg::seg` | `eigen_fx` | 中 | P4 |
| `core::seg::seg_list_chan` | `seg` | 大 | P4 |
| `platform::python::seg_py` | `seg_list_chan` | 中 | P4 |

### 阶段 5：中枢（`zs`）

| 任务 | 依赖 | 预估工量 | 优先级 |
|------|------|---------|--------|
| `core::zs::zs` | `seg` | 中 | P5 |
| `core::zs::zs_list` | `zs` | 中 | P5 |
| `platform::python::zs_py` | `zs_list` | 中 | P5 |

### 阶段 6：买卖点（`bsp`）

| 任务 | 依赖 | 预估工量 | 优先级 |
|------|------|---------|--------|
| `core::bsp::bs_point` | `zs` | 中 | P6 |
| `core::bsp::bsp_list` | `bs_point` | 大 | P6 |
| `platform::python::bsp_py` | `bsp_list` | 中 | P6 |

### 阶段 7：Android 平台适配

| 任务 | 依赖 | 预估工量 | 优先级 |
|------|------|---------|--------|
| `platform::android` JNI 绑定 | 阶段 0~6 全部完成 | 大 | P7 |
| Android 端集成测试 | `android` | 大 | P7 |

---

## 七、双轨验证框架

### 7.1 设计思路

每个模块完成后，Python 和 Rust 版本同时运行，逐 K 对比中间结果，确保逻辑一致性。

### 7.2 实现模式

```rust
// platform::python::verify.rs

/// 通用双轨验证器
#[pyfunction]
fn verify_bi_calculation(
    py: Python<'_>,
    kl_units: Vec<PyKLineUnit>,
    config: &PyBiConfig,
) -> PyResult<Vec<BiDiff>> {
    // 1. Rust 侧计算
    let rust_result = core::bi::BiList::compute_all(&kl_units, &config.inner);

    // 2. 调用 Python 侧计算（通过 pyo3 回调）
    let py_result: Vec<PyBi> = py
        .import("Bi.BiList")?
        .call_method1("compute_all", (kl_units, config))?
        .extract()?;

    // 3. 逐笔 diff
    let mut diffs = Vec::new();
    for (i, (r, p)) in rust_result.iter().zip(py_result.iter()).enumerate() {
        if r != p {
            diffs.push(BiDiff {
                index: i,
                rust_bi: r.clone(),
                python_bi: p.clone(),
                diff_type: classify_diff(r, p),
            });
        }
    }
    Ok(diffs)
}
```

### 7.3 验证数据

使用 `a_Data/` 下的离线分笔数据作为标准测试集，覆盖：
- 正常趋势（上涨/下跌）
- 盘整（包含处理密集）
- 跳空（gap）
- 极端行情（涨跌停）

---

## 八、Python/Rust 用户可切换机制（调试阶段）

### 8.1 核心原则

**Rust 改写调试阶段，Python 逻辑必须完整保留，不得删除。** 用户通过 UI 勾选框自主选择使用 Python 还是 Rust 计算，直观感受速度差异。

```
┌──────────────────────────────────────────────────┐
│  用户勾选 ──→ dispatch ──→ Python 实现（旧逻辑）  │
│  （checkbox）           ├─→ Rust 实现（新逻辑）   │
│                         └─→ 计时 → 日志输出耗时   │
└──────────────────────────────────────────────────┘
```

### 8.2 配置项设计（ChanConfig.py）

在 `ChanConfig.py` 中新增**模块级** Rust 开关，每个计算模块独立控制：

```python
# ChanConfig.py 新增配置项

# === Rust 加速开关（调试阶段，每个模块可独立切换） ===
"use_rust_math": False,         # 技术指标（MACD/BOLL/KDJ/RSI）是否用 Rust
"use_rust_combiner": False,     # K线合并（包含处理）是否用 Rust
"use_rust_bi": False,           # 笔计算是否用 Rust
"use_rust_seg": False,          # 线段计算是否用 Rust
"use_rust_zs": False,           # 中枢计算是否用 Rust
"use_rust_bsp": False,          # 买卖点判定是否用 Rust
# 全局快捷开关（一键全开/全关）
"use_rust_all": False,          # 勾选后覆盖所有模块级开关
```

**开关优先级**：`use_rust_all=True` 时忽略模块级开关，全部走 Rust；`use_rust_all=False` 时各模块独立控制。

### 8.3 调度器模式（Dispatch Pattern）

每个计算模块提供一个统一的调度入口，根据配置自动选择 Python 或 Rust 实现：

```python
# 示例：a_rust_core/a_rust_math.py

import time
import logging
from ChanConfig import CChanConfig

logger = logging.getLogger("chan.rust_switch")

class CMACD:
    """MACD 调度器 —— 根据配置自动选择 Python 或 Rust 实现"""
    
    def __init__(self, fastperiod=12, slowperiod=26, signalperiod=9, config: CChanConfig = None):
        self._config = config
        self._use_rust = self._should_use_rust()
        
        if self._use_rust:
            import chan_core
            self._inner = chan_core.MACD(fastperiod, slowperiod, signalperiod)
        else:
            from Math.MACD import CMACD as CMACD_py
            self._inner = CMACD_py(fastperiod, slowperiod, signalperiod)
        
        # 计时统计
        self._total_time_ns = 0
        self._call_count = 0
    
    def _should_use_rust(self) -> bool:
        """判断是否使用 Rust 实现"""
        if self._config is None:
            return False
        if getattr(self._config, 'use_rust_all', False):
            return True
        return getattr(self._config, 'use_rust_math', False)
    
    def add(self, value):
        """喂入一个价格，返回 MACD_item"""
        if self._use_rust:
            t0 = time.perf_counter_ns()
            result = self._inner.add(value)
            elapsed = time.perf_counter_ns() - t0
        else:
            t0 = time.perf_counter_ns()
            result = self._inner.add(value)
            elapsed = time.perf_counter_ns() - t0
        
        self._total_time_ns += elapsed
        self._call_count += 1
        return result
    
    def get_stats(self):
        """获取耗时统计（供 UI 展示）"""
        avg_us = (self._total_time_ns / max(self._call_count, 1)) / 1000
        return {
            "engine": "Rust" if self._use_rust else "Python",
            "total_calls": self._call_count,
            "total_ms": round(self._total_time_ns / 1_000_000, 3),
            "avg_us": round(avg_us, 2),
        }
```

### 8.4 UI 勾选框设计（a_replay_trainer.py）

在复盘 UI 的配置面板中增加"Rust 加速"设置区域：

```python
# a_replay_trainer.py 配置面板新增

# === Rust 加速开关组 ===
RUST_SWITCH_CONFIG = [
    {
        "key": "use_rust_all",
        "label": "全局 Rust 加速",
        "type": "checkbox",
        "default": False,
        "tip": "勾选后所有计算模块使用 Rust 实现，可直观感受速度提升",
    },
    {
        "key": "use_rust_math",
        "label": "技术指标用 Rust",
        "type": "checkbox", 
        "default": False,
        "tip": "MACD/BOLL/KDJ/RSI 等指标计算用 Rust，预计加速 5-10 倍",
    },
    {
        "key": "use_rust_combiner",
        "label": "K线合并用 Rust",
        "type": "checkbox",
        "default": False,
        "tip": "包含处理用 Rust 计算，预计加速 3-5 倍",
    },
    # ... 其他模块开关
]
```

**UI 交互规范**：
- 勾选 `use_rust_all` 时，下面的模块级开关全部置灰（不可单独操作）
- 取消 `use_rust_all` 时，恢复各模块开关的独立状态
- 切换任何 Rust 开关后，**弹窗提示**："切换 Rust 加速开关后，当前复盘进度和结果将重置，是否继续？"
- 确认后触发 `reconfig`，重建会话

### 8.5 耗时对比展示

在复盘 UI 的底部状态栏或侧边面板中，实时展示当前使用的计算引擎和各模块耗时：

```
┌─────────────────────────────────────────────┐
│  计算引擎：Rust ⚡  |  累计耗时：12.3ms       │
│  ─────────────────────────────────────────  │
│  MACD:     Rust  0.8ms  (Python: 6.2ms)     │
│  Combiner: Python 4.1ms  (Rust: 1.1ms)      │
│  Bi:       Python 5.2ms  (Rust: 2.0ms)      │
│  Seg:      Python 2.2ms  (Rust: 0.9ms)      │
│  ─────────────────────────────────────────  │
│  切换 Rust 后预计总耗时: 12.3ms → 4.8ms      │
└─────────────────────────────────────────────┘
```

实现方式：在 `step()` 完成后，收集各模块的 `get_stats()` 汇总渲染。

### 8.6 调试阶段的操作流程

```
用户操作流程：
1. 打开复盘 UI，加载某只股票
2. 默认全部走 Python（所有 Rust 开关关闭）
3. 勾选"全局 Rust 加速" → 弹窗确认 → reconfig 重建
4. 观察同一只股票的计算结果是否与 Python 一致
5. 对比底部状态栏的耗时数据
6. 如有差异，回退到 Python 排查，修复 Rust 逻辑
7. 修复后重新勾选 Rust，验证一致性
```

### 8.7 持久化兼容

切换 Rust 开关涉及 `reconfig`，注意：
- `AppRollbackSnapshot` 中新增 `rust_switches: dict` 字段，记录当前各模块开关状态
- 回退时恢复开关状态，确保 `step()` 使用正确的计算引擎
- 旧版 pkl 文件缺少 `rust_switches` 时，默认全部 `False`（走 Python）

### 8.8 禁止事项

| 禁止 | 原因 |
|------|------|
| 删除 Python 原有计算逻辑 | 调试阶段需要双轨对比，Python 逻辑是"基准" |
| Rust 和 Python 混用同一模块内部 | 同一模块内部必须全走 Rust 或全走 Python，避免数据不一致 |
| 切换开关时不弹窗确认 | 切换会重置复盘进度，必须告知用户 |
| 硬编码 `use_rust=True` | 必须通过配置读取，默认 `False` |

### 8.9 前端选项卡：Python转Rust效果验证

在 `a_replay_trainer.py` 前端 UI 中新增一个独立选项卡 **"Python转Rust效果验证"**，用于调试阶段逐阶段验证 Rust 改写的加载成功性、耗时对比和计算结果一致性。

#### 8.9.1 选项卡布局

```
┌──────────────────────────────────────────────────────────────┐
│  [复盘训练] [配置] [Python转Rust效果验证] ← 新增选项卡        │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  选择验证阶段：                                               │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ ○ 阶段1: 技术指标 (MACD/BOLL/KDJ/RSI)                │    │
│  │ ○ 阶段2: K线合并 (包含处理)                          │    │
│  │ ○ 阶段3: 笔计算 (Bi)                                 │    │
│  │ ○ 阶段4: 线段计算 (Seg)                              │    │
│  │ ○ 阶段5: 中枢计算 (ZS)                               │    │
│  │ ○ 阶段6: 买卖点判定 (BSP)                            │    │
│  │ ○ 全阶段 (端到端)                                    │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  测试数据：                                                   │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ 股票代码: [000001.SZ  ▼]  周期: [日线 ▼]             │    │
│  │ 日期范围: [2024-01-01] ~ [2024-12-31]                │    │
│  │ K线数量: [自动获取]                                   │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  [ 开始验证 ]  [ 停止 ]                                      │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│  验证结果                                                     │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─ Python 加载 ───────────────────────────────────────┐    │
│  │ 入口状态:  ✅ 成功 / ❌ 失败                          │    │
│  │ 加载耗时:  123.45 ms                                  │    │
│  │ 计算耗时:  456.78 ms                                  │    │
│  │ 总耗时:    580.23 ms                                  │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌─ Rust 加载 ─────────────────────────────────────────┐    │
│  │ 入口状态:  ✅ 成功 / ❌ 失败                          │    │
│  │ 加载耗时:  12.34 ms                                   │    │
│  │ 计算耗时:  45.67 ms                                   │    │
│  │ 总耗时:    58.01 ms                                   │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌─ 对比结果 ──────────────────────────────────────────┐    │
│  │ 加速比:           9.99x                                │    │
│  │ 结果一致性:       ✅ 完全一致 (0 处差异)               │    │
│  │ 差异详情:         [展开查看]                           │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌─ 历史记录 ──────────────────────────────────────────┐    │
│  │ #  日期       阶段      加速比   一致性    Rust加载    │    │
│  │ 1  06-06 16:30  Math     9.5x     ✅        ✅        │    │
│  │ 2  06-06 16:25  Math     9.5x     ✅        ✅        │    │
│  │ 3  06-06 16:20  Math     9.5x     ❌ 3处   ✅        │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

#### 8.9.2 后端 API 接口

在 `a_replay_trainer.py` 中新增以下 API 端点：

```python
# a_replay_trainer.py 新增 API

@app.post("/api/rust_verify/run")
async def rust_verify_run(req: RustVerifyRequest):
    """
    执行 Rust 效果验证，同时跑 Python 和 Rust 两套计算，返回对比结果。
    
    Request:
    {
        "stage": "math",          # 验证阶段: math/combiner/bi/seg/zs/bsp/all
        "code": "000001.SZ",
        "k_type": "K_DAY",
        "begin_date": "2024-01-01",
        "end_date": "2024-12-31",
        "autype": "QFQ"
    }
    
    Response:
    {
        "python": {
            "load_ok": true,
            "load_ms": 123.45,
            "calc_ms": 456.78,
            "total_ms": 580.23,
            "error": null
        },
        "rust": {
            "load_ok": true,
            "load_ms": 12.34,
            "calc_ms": 45.67,
            "total_ms": 58.01,
            "error": null
        },
        "compare": {
            "speedup": 9.99,
            "consistent": true,
            "diff_count": 0,
            "diff_details": []
        }
    }
    """
    pass
```

#### 8.9.3 验证逻辑实现

```python
# a_rust_core/a_rust_verify.py（新增文件，a_ 前缀）

import time
import traceback
from typing import Optional

class RustVerifyRunner:
    """Rust 改写效果验证器 —— 同时跑 Python 和 Rust，对比加载成功性、耗时、结果一致性"""
    
    def __init__(self, config: CChanConfig):
        self._config = config
    
    def run_verify(self, stage: str, code: str, k_type: str,
                   begin_date: str, end_date: str, autype: str) -> dict:
        """
        执行单阶段验证，返回 python/rust/compare 三部分结果。
        """
        result = {
            "python": self._run_python(stage, code, k_type, begin_date, end_date, autype),
            "rust": self._run_rust(stage, code, k_type, begin_date, end_date, autype),
        }
        result["compare"] = self._compare(result["python"], result["rust"])
        return result
    
    def _run_python(self, stage, code, k_type, begin_date, end_date, autype) -> dict:
        """纯 Python 加载并计算，返回耗时和结果"""
        try:
            t0 = time.perf_counter()
            # 1. 加载数据（计时）
            kl_data = self._load_kl_data(code, k_type, begin_date, end_date, autype)
            t_load = time.perf_counter()
            
            # 2. 执行对应阶段的计算（计时）
            py_result = self._calc_python(stage, kl_data)
            t_calc = time.perf_counter()
            
            return {
                "load_ok": True,
                "load_ms": round((t_load - t0) * 1000, 2),
                "calc_ms": round((t_calc - t_load) * 1000, 2),
                "total_ms": round((t_calc - t0) * 1000, 2),
                "result": py_result,  # 结构化结果，供 diff 对比
                "error": None,
            }
        except Exception as e:
            return {
                "load_ok": False,
                "load_ms": 0, "calc_ms": 0, "total_ms": 0,
                "result": None,
                "error": f"{type(e).__name__}: {str(e)}",
            }
    
    def _run_rust(self, stage, code, k_type, begin_date, end_date, autype) -> dict:
        """Rust 加载并计算，返回耗时和结果"""
        try:
            t0 = time.perf_counter()
            # 1. 加载数据（共用 Python 数据加载，不计入 Rust 差异）
            kl_data = self._load_kl_data(code, k_type, begin_date, end_date, autype)
            t_load = time.perf_counter()
            
            # 2. 将数据转为 Rust 格式（numpy → Rust，计时）
            rust_input = self._to_rust_format(kl_data)
            t_convert = time.perf_counter()
            
            # 3. 执行 Rust 侧计算（计时）
            import chan_core
            rust_result = chan_core.compute_stage(stage, rust_input, self._config)
            t_calc = time.perf_counter()
            
            return {
                "load_ok": True,
                "load_ms": round((t_load - t0) * 1000, 2),
                "calc_ms": round((t_calc - t_convert) * 1000, 2),  # 仅 Rust 计算耗时
                "total_ms": round((t_calc - t0) * 1000, 2),
                "result": rust_result,
                "error": None,
            }
        except Exception as e:
            return {
                "load_ok": False,
                "load_ms": 0, "calc_ms": 0, "total_ms": 0,
                "result": None,
                "error": f"{type(e).__name__}: {str(e)}",
            }
    
    def _compare(self, py: dict, rust: dict) -> dict:
        """对比 Python 和 Rust 的结果"""
        if not py["load_ok"] or not rust["load_ok"]:
            return {"speedup": 0, "consistent": False, "diff_count": -1, "diff_details": ["加载失败，无法对比"]}
        
        if py["result"] is None or rust["result"] is None:
            return {"speedup": 0, "consistent": False, "diff_count": -1, "diff_details": ["计算结果为空"]}
        
        speedup = round(py["total_ms"] / max(rust["total_ms"], 0.001), 2)
        diffs = self._diff_results(py["result"], rust["result"])
        
        return {
            "speedup": speedup,
            "consistent": len(diffs) == 0,
            "diff_count": len(diffs),
            "diff_details": diffs[:20],  # 最多展示 20 条差异
        }
    
    def _diff_results(self, py_result, rust_result) -> list:
        """逐条对比 Python 和 Rust 的计算结果，返回差异列表"""
        diffs = []
        # 根据 stage 类型对比不同结构
        # 示例：对比笔的方向、端点价格、时间
        for i, (py_item, rust_item) in enumerate(zip(py_result, rust_result)):
            if py_item != rust_item:
                diffs.append({
                    "index": i,
                    "python": str(py_item),
                    "rust": str(rust_item),
                })
        if len(py_result) != len(rust_result):
            diffs.append({
                "index": "count",
                "python": f"共 {len(py_result)} 条",
                "rust": f"共 {len(rust_result)} 条",
            })
        return diffs
```

#### 8.9.4 前端实现要点

| 要点 | 实现 |
|------|------|
| 阶段选择 | 单选按钮组，默认选中"阶段1: 技术指标" |
| 测试数据 | 股票代码下拉框（复用现有数据源），日期范围选择器 |
| 开始验证 | 按钮点击后调用 `/api/rust_verify/run`，轮询等待结果 |
| 结果展示 | 3 个区域：Python 结果（绿/红边框）、Rust 结果（绿/红边框）、对比结果（加速比+一致性） |
| 差异详情 | 折叠面板，点击展开显示逐条差异的 Python vs Rust 值 |
| 历史记录 | 表格展示最近 20 条验证记录，存储在前端 `localStorage` 或后端内存 |
| 加载状态 | 验证过程显示进度条或 spinner，按钮置灰防重复点击 |

#### 8.9.5 各阶段验证输出内容

| 阶段 | 验证输出框内容 |
|------|--------------|
| 阶段1: Math | MACD 值列表（diff/dea/macd）、BOLL 上下轨、KDJ K/D/J 值、RSI 值 |
| 阶段2: Combiner | 合并后 K 线数量、每根合并 K 线的 OHLC、分型标记 |
| 阶段3: Bi | 笔数量、每笔的方向/起点/终点/极值点 |
| 阶段4: Seg | 线段数量、每段的方向/起点/终点/特征序列分型 |
| 阶段5: ZS | 中枢数量、每个中枢的区间(ZD/ZG)、进出中枢笔 |
| 阶段6: BSP | 买卖点数量、每个买卖点的类型/位置/中枢关联 |
| 全阶段 | 以上所有阶段的汇总，端到端总耗时对比 |

#### 8.9.6 持久化兼容

- 验证历史记录存储在 `a_rust_verify_history.json`（UI 工作目录），不存入 `AppRollbackSnapshot`（避免污染复盘快照）
- 历史记录最多保留 50 条，超出自动清理旧记录
- 切换 Rust 开关时不影响验证历史

---

## 九、禁止事项

### 9.1 核心层禁止事项

| 禁止 | 原因 |
|------|------|
| `core::` 中 `use pyo3::*` | 破坏 Android 移植性 |
| `core::` 中 `use jni::*` | 破坏 Python 绑定 |
| `core::` 中直接 `println!` 调试 | 使用 `log` crate，Android 侧无 stdout |
| `core::` 中 `unsafe` 无文档注释 | 每次 `unsafe` 必须注释原因和 SAFETY 说明 |
| 硬编码 Python 类型（如 `PyDict`） | 用 `HashMap<String, serde_json::Value>` 代替 |
| 绕过双轨验证直接上线 | 每个阶段必须通过 diff 验证 |

### 9.2 平台层禁止事项

| 禁止 | 原因 |
|------|------|
| `platform::python` 中引入 `jni` | 编译膨胀 |
| `platform::android` 中引入 `pyo3` | 编译膨胀 |
| PyO3 绑定中暴露 `Rc`/`RefCell` | Python 侧无法理解 Rust 所有权 |
| JNI 绑定中暴露 Rust `Vec` 裸指针 | 生命周期不安全 |

### 9.3 性能禁止事项

| 禁止 | 原因 |
|------|------|
| Python-Rust 边界频繁小对象拷贝 | 批量传递 numpy 数组 |
| 每次 `step()` 都序列化全量结构 | 仅传递增量 diff |
| Rust 侧内部使用 `Mutex` 逐K锁 | 单线程模型，用 `RefCell` |
| 逐K递归重建整个线段树 | 增量更新，只重算受影响部分 |

---

## 十、注意事项

1. **持久化兼容**：`a_replay_trainer.py` 的 `AppRollbackSnapshot` 序列化依赖 Python 对象，Rust 计算结果需通过 `serde` 序列化为 pickle 兼容格式（JSON/MessagePack），或先保持 Python 侧 snapshot 不变。
2. **多模式兼容**：Rust 侧计算逻辑需与 Python 侧 `chan-mode-compat` Skill 中定义的 4 维度模式兼容，特别是 `逐K喂数据` 模式下的当下性语义。
3. **配置同步**：Rust 侧 `ChanConfig` 必须与 Python 侧 `ChanConfig.py` 保持字段一一对应，新增配置项需两边同步。
4. **错误处理**：Rust 侧使用 `Result<T, ChanError>` 而非 `panic!`，`ChanError` 需实现 `From<ChanError> for PyErr`。
5. **测试覆盖**：每个 Rust 模块至少有一组集成测试，使用 `a_Data/` 下的真实数据验证。
6. **性能基准**：每个阶段完成后运行 `cargo bench`，对比 Python 版本记录加速比。