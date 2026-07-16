# 项目长期记忆：CHAN_RUST 缠论（Rust + Flutter）

## 最高优先级约束（用户明确，任何改动都不得违反）
- **全层同构**：每层用同一算法建立在 `LevelSegment` 上（K0=level1/K1=level2…）。
- **基于当前 Rust 版已实现的形态学元素**，**禁止更改**任何已实现元素逻辑（合并引擎 `CombineEngine` / 分型 / 段构造 `LevelSegment` / 层级递归 `propagate` / `run_pipeline` / v1 算法）。
- 不引入 Python 式独立「笔(bi)」；中枢进出段引用相邻 `LevelSegment.idx`。
- 无未来函数：只读冻结段（排除 `active_unit`）。

## 新增「中枢/框/指标」到 CHAN_RUST 的全链路范式（已验证，可复用）
1. Rust 计算模块（新增 `chan_data/src/<x>.rs`）：只读冻结 `LevelSegment`，导出 `XxxFrame`(serde) + `level_xxx_frames` + `build_xxx_for_levels`；不碰已有元素逻辑。
2. `lib.rs`：`mod` + `pub use` 导出。
3. `pipeline.rs`：`LevelBundleOut` 增 `xxx_frames: Vec<XxxFrame>`（带 `#[serde(default)]`），`export()` 挂载，`PipelineOptions`/`LevelState` 增对应 config（Default 合理）。
4. `chan_ffi/src/lib.rs`：`CombineRequest` 增 `#[serde(default)] xxx_config: Option<X>`，`parse_combine_request` 注入。
5. Flutter 消费：新增 `models/<x>_frame.dart`（字段对齐 Rust serde snake_case key）；`level_models.dart` 增 `xxxFrames` + fromJson `'xxx_frames'`；`chart_indicator.dart` 增枚举种类+标签+`buildMainIndicatorCatalog`；`chart_level_line_style.dart` 增 `forXxx` 独立配色；`kline_chart.dart` 加 switch 分支 + `_drawXxxOnMainChart`（复用 `_combineFrameHSpan`）；`history/app_debug_snapshot.dart` 加 `_writeXxx`；`history/msg_history.dart` 的 `appendNamingRename` 文案随当前口径更新；`main.dart` 默认指标集；`test/` 加单测。
6. 构建：`cargo build --release -p chan_ffi` 产 `chan_ffi.dll`，替换 `flutter/chan_kline/windows/native/`（旧版先备份）。
7. 验证：`cargo test -p chan_data` + `flutter analyze` + `flutter test`（纯 Dart 测试文件，避免触发 native 依赖）。

## 关键技巧
- ZS 在 Flutter 端**无需 Dart 本地重算**：pipeline `export()` 每步基于冻结段重算 `zs_frames`，Flutter 直接消费即可（省代码、防算法漂移）。
- BSP 同此原则：Flutter 直接消费 Rust 末态 `bsp_frames`，不本地重算；三类买卖点为**纯结构趋势末端**（用户决策，不做 MACD 背驰）——一类=≥min_zs_cnt 中枢趋势末段端点，二类=回踩不破一类，三类=离开返回不回中枢带[ZG,ZD]；渲染买红/卖绿（涨红跌绿）、一类圆/二类三角/三类菱形。
- Flutter 同文件每次只改一处，避免 "modified since read" 编辑失败（先 Read 再 Edit）。
- Flutter 透传类型（如 `BSPFrame`）经 `level_models.dart` 引入即可，勿在 `kline_chart.dart` 再直接 `import '../models/bsp_frame.dart'`，否则触发 `unused_import` 告警。
- 路径：Rust 根 `CHAN_RUST/rust/`（cargo workspace）；Flutter 根 `CHAN_RUST/flutter/chan_kline/`。flutter SDK 在 D 盘，PowerShell 跑 `flutter.bat` 用原生 Windows 路径（Git Bash 下路径会被 MSYS 错位）。

## 历史按钮（常驻，禁止当调试代码删）
`chan_kline` 设置面板必须保留「一键复制历史记录」「查看历史记录」「复制页面快照」（实现位于 `lib/history/`，勿放 `lib/debug/`）。
