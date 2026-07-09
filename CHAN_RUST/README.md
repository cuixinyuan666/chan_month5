# CHAN_RUST

全新缠论子项目：**计算层 Rust**，**展示层 Flutter**。与上层 Python `chan.py` 解耦，首期从 `a_Data` 离线分笔聚合 K 线并绘制蜡烛图。

## 目录结构

```
CHAN_RUST/
├── README.md
├── scripts/
│   └── build_rust.ps1      # 编译 Rust 并复制 DLL 到 Flutter Windows
├── rust/
│   ├── chan_data/          # a_Data 分笔解析 + K 线聚合（纯 Rust）
│   └── chan_ffi/           # Flutter FFI（JSON 桥）
└── flutter/
    └── chan_kline/         # Flutter K 线应用
```

## 数据路径

默认读取 `chan.py/a_Data/`（与 `CHAN_RUST` 同级的离线分笔目录），与 Python `COfflineInline` 分笔格式一致。

## 环境要求

- Rust 1.70+
- Flutter 3.x（已测 Windows 桌面）
- 数据源：`../a_Data` 下已有分笔 txt

## 构建与运行（Windows）

```powershell
# 1. 编译 Rust 并复制 chan_ffi.dll
.\CHAN_RUST\scripts\build_rust.ps1

# 2. 启动 Flutter 桌面
cd CHAN_RUST\flutter\chan_kline
flutter pub get
flutter run -d windows
```

## Rust 本地测试

```powershell
cd CHAN_RUST\rust
cargo test -p chan_data
```

## FFI 接口（chan_ffi）

| 函数 | 说明 |
|------|------|
| `chan_default_data_root()` | 返回默认 a_Data 路径 JSON |
| `chan_list_stock_codes(data_root)` | 枚举六位代码目录 |
| `chan_load_klines(root, code, begin, end, period)` | 加载 K 线 JSON 数组 |
| `chan_kline_combine_frames(bars_json)` | K线 → N 段流水线整包（frames/bi_confirms/bar_features/levels…） |
| `chan_free_string(ptr)` | 释放返回字符串 |

`period` 支持：`1m` `5m` `15m` `60m` `day` `week` `month` 等。

## N 段递归流水线（历史记录：配置项与层级语义）

- 层级命名：**笔=1段，线段=2段，…**；递归链：`N-1段K线 → 包含合并 → 三元素分型确认 → 锚定配对 → N段K线`，直到某层再无产出（穷尽），层数动态。
- **「1 段判定适用 N 段」三层语义**（评审口径，避免与 bootstrap 混淆）：

  | 层次 | 是否全层同构 | 说明 |
  |------|-------------|------|
  | 判定内核（包含合并 + 三元素分型） | ✅ | `engine.rs` 唯一实现；L1 合并 1 分钟 K，L2 合并 1 段 K，… |
  | 成段机制（锚定配对 + 有效性校验 + 冻结去重） | ✅ | `pipeline.rs` 的 `on_confirm` 全层共用 |
  | 首段业务策略（bootstrap/审判默认笔） | ❌ 仅 L1 | `feature.rs`；复盘 UI/旧工程兼容，非 N 段通用判定 |

- 代码分工（合并/分型全工程唯一实现，勿再复制）：
  - `rust/chan_data/src/engine.rs`：包含合并 + 分型内核（`CombineEngine::feed/probe`）；
  - `rust/chan_data/src/pipeline.rs`：单遍逐K驱动的 N 段递归 + 每K每层十字线快照（`LevelSnap`）；
  - `rust/chan_data/src/combine.rs`：旧字段兼容映射（`frames/bi_*/seg_analysis` 均由流水线导出）。
- **锚定配对**：段端点锚定"最近已用端点分型"；同向分型直接丢弃（不回写历史端点），链条无缝（上一段终点=下一段起点，测试保证）。
- **有效性校验（可配置）**：`PipelineOptions.validity_check`（默认 `true`）＝最低限度"顶极值>底极值"：上段要求顶分型组 high > 底分型组 low，倒挂分型跳过不配对。关闭后任意异向分型即配对。FFI 入口固定用默认值；如需暴露到 UI 再加参数。
- **逐K当下性**：分型确认/段冻结均在当步写入即冻结，未来结构不回写；`bar_features[i].levels` 为该 K 当步的各层快照（ML/tooltip 同源）；前缀重放一致性有测试（`snapshots_frozen_per_bar_no_future`，全量 `LevelSnap` 逐字段相等）。
- **进行中段探测（方案A）**：N 层进行中段K线（锚点极点→当步K 区间）只读探测 N+1 层分型（`probe`，与 `feed` 语义一致），可提前段确认，不污染永久合并链。
- **首段策略**：仅 1 段（笔）层保留引导/审判默认笔（bootstrap/promoted，`default_bi_policy`）；2 段及以上首段=前两个异向分型配对。
- **Dart 端纯 FFI**：Flutter 无缠论回退实现；`compute/` 仅剩视图组装（半侧衔接、十字线 as-of 查表重绘）。tooltip 按 K 线块模板逐层输出 N 段全量信息（`{n}段K线[序号] / OHLCV / 合并序 / 合并H:L / 合并分型确认`，其中 n 段块的确认=n+1 层端点确认）。

## 后续规划

- [ ] 中枢 Rust 核心
- [ ] Android JNI 复用 `chan_data`
- [ ] 逐 K 步进增量 API（复用 pipeline 状态，免前缀全量重算）
