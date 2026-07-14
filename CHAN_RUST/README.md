# CHAN_RUST

全新缠论子项目：**计算层 Rust**，**展示层 Flutter**。与上层 Python `chan.py` 解耦，首期从 `a_Data` 离线分笔聚合 K 线并绘制蜡烛图。

## 目录结构

```
CHAN_RUST/
├── README.md
├── scripts/
│   ├── build_rust.ps1      # 编译 Rust 并复制 DLL 到 Flutter Windows
│   └── build_rust.sh       # 编译 Rust 并复制 .so 到 Flutter Linux（WSL 通用）
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

> **本机支持 WSL**：本机可在 WSL（Windows Subsystem for Linux）中直接编译运行。
> WSL 下 Rust 产物为 Linux 动态库 `libchan_ffi.so`（而非 Windows 的 `.dll`），
> 对应构建脚本为 `scripts/build_rust.sh`，Flutter 以 Linux 桌面目标运行。

## 构建与运行（Windows）

```powershell
# 1. 编译 Rust 并复制 chan_ffi.dll
.\CHAN_RUST\scripts\build_rust.ps1

# 2. 启动 Flutter 桌面
cd CHAN_RUST\flutter\chan_kline
flutter pub get
flutter run -d windows
```

## 构建与运行（WSL / Linux）

```bash
# 1. 编译 Rust 并复制 libchan_ffi.so 到 Flutter Linux 目录
bash CHAN_RUST/scripts/build_rust.sh
# 或先赋予执行权限后直接运行：
# chmod +x CHAN_RUST/scripts/build_rust.sh && ./CHAN_RUST/scripts/build_rust.sh

# 2. 启动 Flutter 桌面（Linux 目标）
cd CHAN_RUST/flutter/chan_kline
flutter pub get
flutter run -d linux
```

> WSL 首次运行 Flutter Linux 桌面需安装依赖：`clang cmake ninja-build pkg-config libgtk-3-dev`
> 以及 GUI 环境（Windows 11 的 WSLg 已内置图形支持）。

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

## Kn 递归流水线（历史记录：配置项与层级语义）

- **命名历史**：旧「1段/2段/n段K线」→「K1/K2/Kn」；原始周期K=K0；主图/副图统一层号：指标 `kn`=层号（1..maxKn），展示名比层号小 1。主图：`K(n-1)连线` / `K(n-1)合并`（旧「笔连线」=K0连线，曾称 K1连线；线段=K1连线；`K0合并` 等合并不偏移）。副图：`K(n-1)分型确认` / `K(n-1)分型极点距` / `K(n-1)截断`（对应 `level=kn` 的 confirms）。三组指标 kn 口径完全一致。
- **命名历史（2026-07-15，取消「笔/线段」概念）**：代码统一 K0/K1/…/KN，不再用「笔/线段」叫法（仅本节历史记录保留旧名）。笔=K0连线、线段=K1连线；笔虚拟K=K1、线段虚拟K=K2。字段 `bi_*`→`k0_*`/`k1_*`、`seg_*`→`k1_*`（如 `bi_segments`→`k0_lines`、`bi_combine_frames`→`k1_combine_frames`、`seg_lines`→`k1_lines`）；Rust 类型 `BiSegment`→`K0Line`、`BiVirtualBar`→`K1Bar`、`SegLine`→`K1Line`、`SegAnalysisBundle`→`K1AnalysisBundle` 等；JSON key 同步变更并重建 `chan_ffi.dll`。内部 `level` 1-based 不变；泛用 `segment` 英文词（`LevelSegment`/`segments`/`segment_policy`）与模块文件名 `seg_eigen.rs`/`segment_first.rs` 保留。
- 层级：**K0=原始K，K1=K0连线(笔)，K2=K1连线(线段)，…**（旧名作括注）；递归链：`K(n-1) → 包含合并 → 三元素分型确认 → 锚定配对 → Kn`，穷尽为止。
- **「K1 判定适用 Kn」三层语义**（评审口径，避免与 bootstrap 混淆）：

  | 层次 | 是否全层同构 | 说明 |
  |------|-------------|------|
  | 判定内核（包含合并 + 三元素分型） | ✅ | `engine.rs` 唯一实现；K1 合并 K0，K2 合并 K1，… |
  | 成段机制（锚定配对 + 有效性校验 + 冻结去重） | ✅ | `pipeline.rs` 的 `on_confirm` 全层共用 |
  | 首段业务策略（pending + 反向极值 trial） | ✅ | `segment_first.rs` 全层同构；`default_segment_policies[]` |

- 代码分工（合并/分型全工程唯一实现，勿再复制）：
  - `rust/chan_data/src/engine.rs`：包含合并 + 分型内核（`CombineEngine::feed/probe`）；
  - `rust/chan_data/src/segment_first.rs`：全层首段策略（pending 占位、反向极值 trial、retained/purged）；
  - `rust/chan_data/src/pipeline.rs`：单遍逐K驱动的 N 段递归 + 每K每层十字线快照（`LevelSnap`）；
  - `rust/chan_data/src/combine.rs`：旧字段兼容映射（`frames/bi_*/seg_analysis` + `level_segments`/`level_virtual_units`）。
- **锚定配对**：段端点锚定"最近已用端点分型"；同向分型直接丢弃（不回写历史端点），链条无缝（上一段终点=下一段起点，测试保证）。
- **有效性校验（可配置）**：`PipelineOptions.validity_check`（默认 `true`）＝最低限度"顶极值>底极值"：上段要求顶分型组 high > 底分型组 low，倒挂分型跳过不配对。关闭后任意异向分型即配对。FFI 目前仅暴露 `truncation_check`；`validity_check` 仍用默认。
- **逐K当下性**：分型确认/段冻结均在当步写入即冻结，未来结构不回写；`bar_features[i].levels` 为该 K 当步的各层快照（ML/tooltip 同源）；前缀重放一致性有测试（`snapshots_frozen_per_bar_no_future`，全量 `LevelSnap` 逐字段相等）。
- **下层确认后才能参与上层（全层同构，`all_confirm`）**：只有永久冻结的 K(n-1) 单元才能 `feed` 进 Kn 并触发分型/成段；进行中单元仍可 `probe` 上层合并态，但仅用于十字线/展示快照，**不再提前 `on_confirm`**。
- **截断确认（全层同构，`PipelineOptions.truncation_check` 默认开启）**：救"暴力反转单元被包含吸收吃掉信号"的场景。截断同样只对**已确认冻结**的下层单元生效（K1合并框/as-of 合并不喂进行中笔；进行中探测不加截断 guard）。
  - Flutter 设置面板「截断机制」开关可关：关=添加截断前旧吸收行为；开=当前截断口径。FFI 入参 `{bars, truncation_check}`（纯数组仍兼容，默认开）。
  - 上升截断：上行阶段（锚点=底分型）新单元 `最高价>=左框最高价 且 最低价<上个底分型中组最低价`（参照=本层最近一次底分型确认，含同向丢弃/校验失败的）→ 左框=顶分型中组当场确认（高低不被改写，端点=左框峰值K，非截断K），截断K强制断开成新下行组并参与后续三元素监控（监控范围>=第四根）；下降截断镜像。
  - **触发单元改写**：断开成新组时，将触发K高低改写为「可作第三元素」形态——下降截断抬低点（保留触发高）、上升截断压高点（保留破位低），便于后续双高/双低三元素接续；原始K0行情不变，仅合并引擎内几何改写。
  - 监控按锚点方向分工：上行只监控上升截断、下行只监控下降截断，首分型确认前不监控；`feed_guarded`/`probe_guarded` 语义一致（engine.rs 唯一实现）。
  - 确认事件带 `truncated` 标记（`LevelConfirm`/`BiConfirmSignal`/`SegConfirmSignal`，serde 默认 false 向后兼容）；tooltip 确认行显示 `值(截断)`，确认柱样式不变。
  - 后续步骤同常规确认：`on_confirm` 锚定配对/有效性校验/冻结去重全流程；关闭开关=旧行为（吸收，便于新旧对比排查）。
  - 已知口径现象（评审确认）：截断场景下行段起点=左框峰值K，区间真实极值可能在截断K上（设计内，Q7=B）；分型极点取合并框语义，个别K的被吸收影线可能低/高于端点价（与截断无关的既有合并口径）。
- **首段策略（全层同构）**：
  - **pending**：首确认前，首输入单元→当步末单元临时默认段（仅展示）；
  - **trial PASS → retained**：反向极值→分型极点区间合法即升格，`is_promoted_default=true`，当场喂上层；
  - **trial FAIL → purged**：只设锚点不产段，等第二异向端点配对；无 bootstrap 引导段；
  - 导出：`default_segment_policies[]`、`level_segments[]`、`level_virtual_units[]`；`default_bi_policy`=`[0]` 兼容别名。
- **PipelineOptions**：`first_segment_bootstrap`（默认 `true`）控制全层首段 trial；`validity_check` 仍仅作用于 Pair。
- **Dart 端纯 FFI**：Flutter 无缠论回退实现；`compute/` 仅剩视图组装。tooltip 按 K0/Kn 块模板输出（`Kn[序号] / OHLCV / 合并序 / 合并H:L / 合并分型确认`，Kn 确认=K(n+1) 端点）。
- **历史记录常驻**：设置面板「一键复制历史记录 / 查看历史记录 / 复制页面快照」与 `lib/history/`；合并到 main 时不得当调试入口删除。

## 后续规划

- [x] 跨段中枢 Rust 核心：`chan_data/src/kuaduan.rs`（`KuaDuan`/`KuaDuanFrame`/`find_kuaduan`/`build_kuaduan_for_levels`/`level_kuaduan_frames`，松重叠吸收器，全层同构；`run_pipeline` 的 `LevelBundleOut.kuaduan_frames` 逐层挂载，无未来函数）
- [x] 跨段中枢 Flutter 可视化：主图指标新增 `跨段中枢(kuaduan)`，展示名 `K(n-1)跨段中枢`（笔跨段中枢=K0跨段中枢），复用合并框横向渲染画 ZD/ZG 半透明框 + 标签；默认勾选 `kuaduan(1)`
- [ ] Android JNI 复用 `chan_data`
- [ ] 逐 K 步进增量 API（复用 pipeline 状态，免前缀全量重算）
