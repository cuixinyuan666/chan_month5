# CHAN_RUST


## 目录结构

```
CHAN_RUST/
├── README.md
├── task-log.md
├── docs/                          # 设计文档、性能报告、ML 规格
│   ├── DESIGN_OPTIMIZATION.md
│   ├── ML_FEATURE_SPEC.md
│   ├── PHASE2*_PROFILING_REPORT.md
│   └── superpowers/
├── scripts/
│   ├── build_rust.ps1              # Windows：编 DLL、复制、启动 flutter run
│   ├── build_rust.sh               # Linux/WSL：编 .so 并复制到 Flutter Linux
│   ├── build_rust_android.ps1      # Windows：交叉编译 Android jniLibs
│   ├── build_rust_android.sh       # Linux：交叉编译 Android jniLibs
│   ├── prepare_android_a_data_seed.sh  # 打 Android 内置 a_Data 种子 zip
│   ├── build_android_release.sh    # 种子 + jniLibs + Release APK
│   ├── run_release_gate.ps1        # 发布前：Rust 单测 + Flutter 对拍
│   ├── package_windows.ps1         # 打 Windows zip（含 a_Data）
│   └── release_readme.txt          # zip 内「使用说明.txt」底稿
├── rust/
│   ├── chan_data/          # a_Data 分笔解析 + K 线聚合（纯 Rust）
│   └── chan_ffi/           # Flutter FFI（JSON 桥）
└── flutter/
    └── chan_kline/         # Flutter K 线应用
```

`flutter clean` / `flutter pub get` / `flutter run` 必须在 `flutter/chan_kline` 下执行（该目录才有 `pubspec.yaml`）。在 `scripts/` 下跑会报找不到工程；`build_rust.ps1` 会自行切到 `chan_kline`。

## 数据路径

默认读取 `chan.py/a_Data/`（与 `CHAN_RUST` 同级的离线分笔目录），与 Python `COfflineInline` 分笔格式一致。

## 环境要求

- Rust 1.70+
- Flutter 3.x（已测 Windows / Linux 桌面；Android 见下文）
- 数据源：`../a_Data` 下已有分笔 txt

> **本机支持 WSL**：本机可在 WSL（Windows Subsystem for Linux）中直接编译运行。
> WSL 下 Rust 产物为 Linux 动态库 `libchan_ffi.so`（而非 Windows 的 `.dll`），
> 对应构建脚本为 `scripts/build_rust.sh`，Flutter 以 Linux 桌面目标运行。

## Android 环境（ANDROID_RUST 分支）

Cloud Agent / Linux 首次配置（从工程根目录 `chan_month5/` 执行）：

```bash
# 安装 Android SDK、NDK、Rust 交叉编译目标，并预编译 jniLibs
bash .cursor/scripts/install-android-env.sh
```

本地仅重编 Rust → jniLibs：

```bash
bash CHAN_RUST/scripts/build_rust_android.sh
```

构建并安装调试 APK（需已连接设备或模拟器）：

```bash
cd CHAN_RUST/flutter/chan_kline
flutter pub get
flutter run -d android
# 或仅打包：
flutter build apk --debug
```

说明：

- `chan_bridge.dart` 在 Android 上加载 `libchan_ffi.so`（由 `jniLibs/<abi>/` 打包）。
- `.so` 不入库（`CHAN_RUST/.gitignore`），由 `install-android-env.sh` / `build_rust_android.sh` 生成。
- 默认 `a_Data` 路径仍按桌面相对目录解析；真机部署需另行配置数据目录（待后续任务）。

## 构建与运行（Windows）

```powershell
# 编译 Rust、复制 chan_ffi.dll，并启动 Flutter 桌面（脚本内会进入 chan_kline）
.\CHAN_RUST\scripts\build_rust.ps1

# 若要自己跑 Flutter 命令，必须先进入工程目录：
# cd CHAN_RUST\flutter\chan_kline
# flutter pub get
# flutter run -d windows
# flutter clean
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
| `chan_load_klines_ex(root, code, begin, end, period, tick_source)` | 加载 K 线并返回质量信息（file/protocol） |
| `chan_save_test_ohlc(req_json)` | 保存自定义 OHLCV 到 `test/custom.ohlc.csv` |
| `chan_kline_combine_frames(bars_json)` | K 线 → N 段流水线整包（frames/bi_confirms/bar_features/levels…） |
| `chan_pipeline_create(opt_json)` | 创建流水线会话，返回 handle |
| `chan_pipeline_append(handle, bar_json)` | 逐根 append，返回完整 bundle |
| `chan_pipeline_append_delta(handle, bar_json)` | 逐根 append，返回增量 delta（历史不重复发送） |
| `chan_pipeline_snapshot(handle)` | 非消费快照 |
| `chan_pipeline_reset(handle)` | 清空已喂入 K，保留选项 |
| `chan_pipeline_len(handle)` | 当前会话已喂入根数 |
| `chan_pipeline_free(handle)` | 销毁会话 |
| `chan_chip_profile(req_json)` | 筹码分桶 profile |
| `chan_ml_predict(req_json)` | ML 预测打分（model.json + dense 向量） |
| `chan_free_string(ptr)` | 释放返回字符串 |

协议号 `chan_ffi_abi_version()` 裸返回 u32；DLL 版本对不上时界面停机，禁止混用旧库。

`period` 支持：`tick` `1m` `5m` `15m` `60m` `day` `week` `month` 等。`tick_source` 支持 `file` / `protocol`。

## Kn 递归流水线（历史记录：配置项与层级语义）

- **设计约束（新增功能全层同构）**：所有新增功能要全层同构（K0/K1/…/KN 递归链上每一层行为一致），除非当前逻辑无法全层自洽；新增指标/中枢/连线/副图等须与合并/连线/中枢(Normal|OverSeg)/买卖点同层同号、同口径、同冻结语义。确实无法全层自洽而例外的，必须在「历史记录」中写明原因，便于复制排查。
- **增删改查约束**：所有增/删/改/查功能必须基于当前功能的实现，不允许设计新的逻辑来显性或隐性地替代现有功能；所有增/删/改/查功能必须基于当前功能的格式与呈现逻辑，不允许设计新的逻辑使其与当前的操作和呈现逻辑相突兀。
- **命名历史**：旧「1段/2段/n段K线」→「K1/K2/Kn」；原始周期K=K0；主图/副图统一层号：指标 `kn`=层号（1..maxKn），展示名比层号小 1。主图：`K(n-1)连线` / `K(n-1)合并`（旧「笔连线」=K0连线，曾称 K1连线；线段=K1连线；`K0合并` 等合并不偏移）。副图：`K(n-1)分型确认` / `K(n-1)分型极点距` / `K(n-1)截断`（对应 `level=kn` 的 confirms）。三组指标 kn 口径完全一致。
- **命名历史（2026-07-15，取消「笔/线段」概念）**：代码统一 K0/K1/…/KN，不再用「笔/线段」叫法（仅本节历史记录保留旧名）。笔=K0连线、线段=K1连线；笔虚拟K=K1、线段虚拟K=K2。字段 `bi_*`→`k0_*`/`k1_*`、`seg_*`→`k1_*`（如 `bi_segments`→`k0_lines`、`bi_combine_frames`→`k1_combine_frames`、`seg_lines`→`k1_lines`）；Rust 类型 `BiSegment`→`K0Line`、`BiVirtualBar`→`K1Bar`、`SegLine`→`K1Line`、`SegAnalysisBundle`→`K1AnalysisBundle` 等；JSON key 同步变更并重建 `chan_ffi.dll`。内部 `level` 1-based 不变；泛用 `segment` 英文词（`LevelSegment`/`segments`/`segment_policy`）与模块文件名 `seg_eigen.rs`/`segment_first.rs` 保留。
- 层级：**K0=原始K，K1=K0连线(笔)，K2=K1连线(线段)，…**（旧名作括注）；递归链：`K(n-1) → 包含合并 → 三元素分型确认 → 锚定配对 → Kn`，穷尽为止。
- **「K1 判定适用 Kn」三层语义**（评审口径，避免与 bootstrap 混淆）：

  | 层次 | 是否全层同构 | 说明 |
  |------|-------------|------|
  | 判定内核（包含合并 + 三元素分型） | ✅ | `engine.rs` 唯一实现；K1 合并 K0，K2 合并 K1，… |
  | 成段机制（锚定配对 + 有效性校验 + 冻结去重） | ✅ | `pipeline.rs` 的 `on_confirm` 全层共用 |
  | 首段业务策略（种子合并框 + A→B/B→C） | ✅ | `pipeline.rs` 全层同构；`segment_first.rs` 极值辅助；例外见下 |

- 代码分工（合并/分型全工程唯一实现，勿再复制）：
  - `rust/chan_data/src/engine.rs`：包含合并 + 分型内核（`CombineEngine::feed/probe`）；
  - `rust/chan_data/src/segment_first.rs`：全层首段策略辅助（区间 OHLCV 聚合、分型极点取首 K）；种子框首段逻辑在 `pipeline.rs` 的 `on_confirm`/快照中；
  - `rust/chan_data/src/pipeline.rs`：单遍逐K驱动的 N 段递归 + 每K每层十字线快照（`LevelSnap`）；
  - `rust/chan_data/src/combine.rs`：旧字段兼容映射（`frames/bi_*/seg_analysis` + `level_segments`/`level_virtual_units`）。
- **锚定配对**：段端点锚定"最近已用端点分型"；同向分型直接丢弃（不回写历史端点），链条无缝（上一段终点=下一段起点，测试保证）。
- **有效性校验（可配置）**：`PipelineOptions.validity_check`（默认 `true`）＝最低限度"顶极值>底极值"：上段要求顶分型组 high > 底分型组 low，倒挂分型跳过不配对。关闭后任意异向分型即配对。FFI 目前仅暴露 `truncation_check`；`validity_check` 仍用默认。
- **逐K当下性**：分型确认/段冻结均在当步写入即冻结，未来结构不回写；`bar_features[i].levels` 为该 K 当步的各层快照（ML/tooltip 同源）；前缀重放一致性有测试（`snapshots_frozen_per_bar_no_future`，全量 `LevelSnap` 逐字段相等）。
- **Kn一类BS / 步进当下性（任务前必读·常驻）**：Kn(n>0) 一类买卖点判定喂入必须与动态中枢同构：冻段 + `active_unit`（`segments_with_optional_active`）；不得只改注释/单测就当完成。
  - 逐K步进：当步已能判定并显示的一类BS标签/副图读数，写入后冻结；下一步不得因整表重算而消除旧显示（对齐分型判断的会话追加日志，禁止 `_buy1*`/`sell1*` 无合并直接覆盖）。
  - Flutter：`_mergeBsHistory` + `_levelsWithFrozenBs`；十字 as-of 只改层结构，一类BS 用会话历史覆盖，禁止 asOf 重算消点。
  - **对齐 Kn分型判断的正确含义（2026-07-30·踩坑）**：按 **K0 步进颗粒度**，以本步 **动态 Kn** 为判断元素，副图/十字显示该步结果——不是「只保留首次发现 x、键不含 x」。
    - 分型判断事件键含 `x`；一类BS 须 `稳定键=层|段|标签` + `颗粒度键=…|x`。
    - Kn≥1：本步仍落在 `active_unit` 且 Rust 仍输出 → 再追加本步 `x=stepIdx`（同 seg/label 可多 x，如 26 与 27 各一颗 1Sa）。
    - 禁止误读「对齐分型判断」为：去掉尾柱回显后只留发现点、或仅用稳定键去重（002003：step27 Rust 仍出、Flutter `dedup_skip` → 副图 `tailHasMark=false`、十字 `sellAtAsOf=null`）。
  - 验收门槛：关占用重载 `chan_ffi.dll` → 冷启动 → **连续单步**确认「出现后下一步仍在」且 **当前步尾柱/十字仍有读数**；一键跳末≠步进验收。单测通过≠用户可见完成。
  - 经验（2026-07-29）：日志用 rawLostN(若整表替换会丢) vs histLostN(冻结后应恒0) 取证。
  - 一类BS 打点 x：禁止回写到「判定尚未成立」的历史极点；首次以步进当下（stepIdx）写入；动态延伸追加新 x，不把旧点挪到新右端；十字 asOf 只显示 x<=asOf。
  - **同枢极值参照（2026-07-30·全层同构+B/S镜像）**：同一中枢框内，B 后续 low **一律与本枢已见最低 low 比**（高于则不标；跳过时不得把参照抬成更高的跳过成员）；S 镜像——一律与本枢已见最高 high 比。禁止改成「与上一成员比」。K0/K1/…/Kn 同一套 `find_buy1`/`find_sell1`。
  - **一类/二类BS V2.1（2026-08-12·方案A演进）**：同资格中枢框内，一类负责建框/严格新极值/等高确认：`low<已见最低`→`1Ba`并更新参照；`low==已见最低`→`1Bb/1Bc…`（不产生二类）；`low>已见最低`→跳过一类。二类仅标严格更高低点/更低高点→`2Ba…`/`2Sa…`；等高/等低不再产生二类（消除同价双标）。严格新极值时一类从 `a` 复位、二类字母同步重起。全链路同构（`buy1.rs`/`buy2.rs`、会话双键冻结、副图、十字）；禁止整表覆盖消点。`mark_x`/冻结/ML α 判定不变。
- **下层确认后才能参与上层（全层同构，`all_confirm`）**：只有永久冻结的 K(n-1) 单元才能 `feed` 进 Kn 并触发分型/成段；进行中单元仍可 `probe` 上层合并态，但仅用于十字线/展示快照，**不再提前 `on_confirm`**。
- **截断确认（全层同构，`PipelineOptions.truncation_check` 默认开启）**：救"暴力反转单元被包含吸收吃掉信号"的场景。截断同样只对**已确认冻结**的下层单元生效（K1合并框/as-of 合并不喂进行中笔；进行中探测不加截断 guard）。
  - Flutter 设置面板「截断机制」开关可关：关=添加截断前旧吸收行为；开=当前截断口径。FFI 入参 `{bars, truncation_check}`（纯数组仍兼容，默认开）。
  - 上升截断：上行阶段（锚点=底分型）新单元 `最高价>=左框最高价 且 最低价<上个底分型中组最低价`（参照=本层最近一次底分型确认，含同向丢弃/校验失败的）→ 左框=顶分型中组当场确认（高低不被改写，端点=左框峰值K，非截断K），截断K强制断开成新下行组并参与后续三元素监控（监控范围>=第四根）；下降截断镜像。
  - **触发单元改写**：断开成新组时，将触发K高低改写为「可作第三元素」形态——下降截断抬低点（保留触发高）、上升截断压高点（保留破位低），便于后续双高/双低三元素接续；原始K0行情不变，仅合并引擎内几何改写。
  - 监控按锚点方向分工：上行只监控上升截断、下行只监控下降截断；常规截断在首分型确认后监察。另：**种子相对第二框包含截断**（见首段策略）在 `seed_skip_first` 路径、首分型前即可触发，`feed_guarded`/`probe_guarded` 同构。
  - 确认事件带 `truncated` 标记（`LevelConfirm`，serde 默认 false 向后兼容）；tooltip 确认行显示 `值(截断)`，确认柱样式不变。
  - 后续步骤同常规确认：`on_confirm` 锚定配对/有效性校验/冻结去重全流程；关闭开关=旧行为（吸收，便于新旧对比排查）。
  - 已知口径现象（评审确认）：截断场景下行段起点=左框峰值K，区间真实极值可能在截断K上（设计内，Q7=B）；分型极点取合并框语义，个别K的被吸收影线可能低/高于端点价（与截断无关的既有合并口径）。
- **首段策略（种子框，口径 A，全层同构）**：
  - 每层 `CombineEngine` 首组为**种子合并框**（`seed_skip_first`）：首两单元不做包含合并（group0 始终单元素、永不吸收第二根；group1 强制自成新组）。这是"合并内核同构"的字面例外，原因登记于下方「例外记录」。
  - **种子相对第二框截断（全层同构）**：第二单元相对种子满足 `h2>=h1 && l2<=l1 && !(h2==h1 && l2==l1)` 时，不按「强制 push group1」而触发截断：`dh=|h2-h1|`、`dl=|l2-l1|`；`dh>dl` 或 `dh==dl` → 向下截断（左框种子 BOTTOM）；`dh<dl` → 向上截断（左框种子 TOP）；复用 `trunc_rewrite_trigger_unit`，`truncated=true`。
  - **动态（口径 A）**：n>0 时，首分型确认前种子框高低/极值可随下层进行中单元 `probe` 刷新；首个 Kn 分型确认后 `seed_confirmed` 冻结几何与方向。
  - 首个真实分型出现时，反推种子框方向（=首个真实分型反向），发射：
    - **A→B 首段**（种子极值→首个分型极值，正式入库，作为本层第一个 `LevelSegment`）；
    - **B→C 第二段**（首个分型极值→次分型极值；配对确认入库，判断态仅快照端点）。
  - 虚实线（`LevelSnap.first_fx_state` / `seed_leave_dir`，**全层同构**）：
    - `UNKNOWN` 第一条虚线限制：首分型确认/判断前对照**动态末组** `hn,ln`（冻组合并 + 下层进行中 pending 的 probe 吸收/成组，与展示轨动态Kn合并同口径；非仅第二框）：sit1(`hn>h1&&ln>l1`)→`+1` 画；sit2(`hn<h1&&ln<l1`)→`-1` 画；`hn<=h1&&ln>=l1`（含全等）及其它→`0` 不画；几何 begin=框内出发极值，尾端从 `seed_box_x2` 外扫；
    - 虚实线优先级：动态Kn/动态Kn合并/Kn分型判断→虚线；确认Kn/确认Kn合并/Kn分型确认→实线；**确认 > 动态/判断**；
    - `JUDGE`（下层进行中单元 probe 出首分型、尚未 `on_confirm`）：有 C 则两线均虚，仅 B 则 A→B 虚（让位 ABC，不再画 UNKNOWN 开口）；
    - `CONFIRM`：A→B 实（冻结段），B→C 虚（进行中/次分型判断）；`seed_leave_dir` 清零。
  - 种子框快照（`LevelSnap.seed_*` / `draw_a/b/c_x`）：逐K当下冻结，供 Flutter 渲染与 ML/tooltip 同源。
  - 导出：`segment_policy`=`seed`（未确认）/`retained`（已确认）；`pending_unit` 恒空（JSON 兼容壳）。
- **例外记录（首两单元不做包含）**：全层同构要求每层 Kn 合并内核一致，但按本设计"第二个 Kn 不再与第一个 Kn 做包含关系"，本层产出 Kn 的前两个单元之间不做包含合并（K1 层首两笔、K2 层首两段…各自独立）。例外之例外：第二框严格包含种子时走截断而非强制 push。其余包含合并与三元素分型判定全层一致。
- （已删除）`PipelineOptions.first_segment_bootstrap` / trial 反向极值 / pending·retained·purged 三态：本设计以种子框取代。
- **Dart 端纯 FFI**：Flutter 无缠论回退实现；`compute/` 仅剩视图组装。tooltip 按 K0/Kn 块模板输出（`K{层} idx / OHLCV / 合并GG:DD:MG:MD / 合并K序 idx / 合并 idx / 分型确认/判断 / 中枢GG:DD:ZG:ZD / 中枢K{层} idx / 中枢 idx / 中枢确认`，GG/DD=逐K当下区间极值、MG/MD=合并框框体高低点；Kn 确认=K(n+1) 端点；K0/Kn 全层同构）。
- **历史记录常驻**：设置面板「一键复制历史记录 / 查看历史记录 / 复制页面快照」与 `lib/history/`；合并到 main 时不得当调试入口删除。

## 实现约束与口径

### 项目定位与通用约束
- **项目定位**：全新项目，用于行情回测、机器学习研究；采用 Rust 开发，以此提升整体计算速度。
- **计算模式**：逐 K step 步进计算，内置缠论逻辑和旧工程大体一致，但局部存在区别。
- **代码引用规范**：如需复用外部项目缠论相关代码，必须提前确认其是否贴合原版缠论逻辑，未确认禁止擅自引用。
- **开发限制**：全程仅使用 Rust，不接入任何拖慢计算性能的其他编程语言。
- **设计约束**：所有新增功能要全层同构（K0/K1/…/KN 递归链上每一层行为一致），除非当前逻辑无法全层自洽；新增指标/中枢/连线/副图等须与合并/连线/中枢/买卖点同层同号、同口径、同冻结语义。确实无法全层自洽而例外的，必须在「历史记录」中写明原因，便于复制排查。
- **增删改查约束**：所有增/删/改/查功能必须基于当前功能的实现，不允许设计新的逻辑来显性或隐性地替代现有功能；所有增/删/改/查功能必须基于当前功能的格式与呈现逻辑，不允许设计新的逻辑使其与当前的操作和呈现逻辑相突兀。
- **数据约束**：分型、笔、合并 K 线序号、十字辅助线特征、全部副图指标计算均禁止使用未来函数；十字辅助线新增 K 线星期、合并 K 线内序号字段，所有指标数据统一作为机器学习训练特征。

### 一次性呈现逐K增强说明
- 配置项：`喂数据方式=逐K喂数据` 且 `K线图呈现形式=一次性呈现`。
- 该模式仅用于复盘首屏加载，不用于模拟操盘，所以逐K过程中的持仓回放、买卖点对错弹窗判定被省略。
- 因为首屏只需要展示“步进跑完后的当时当下买卖点历史”，所以每步完整图表序列化、节奏提示同步被省略。
- 该模式仍逐根执行 `step()`，只做轻量 BSP 增量收集，最后再构建图表首包。

### 分型/中枢 判断·确认对象
- **对象一律是「尚未确认」的分型或中枢**，不是对新芽、新分型、新中枢做判断/确认。
- 适用范围：`Kn分型判断` / `Kn分型确认` / `Kn中枢判断` / `Kn中枢确认`；**全层同一套 merge，无 K0 特例分支**。
- **K0 无动态 Kn**：离开常与定型同拍；判断在确认当步对同一未确认框共点 → **K0 副图判断与确认标记重叠（预期）**。
- **中枢判断**：①离开窗（≥2 不确定）对尚未确认的上个框可逐K打点；②本步刚确认的框同拍再打判断（与确认同 x/x1）；③禁止单开放给新芽打首次可判。
- **中枢确认**：`is_sure` 首次=确认原先未确认的那一框。
- **踩坑**：勿把同拍新种子当判断身份（曾出现 idx=7：确认 x1=6 / 判断 x1=7）；勿为「对齐分型首次可判」给中枢新芽打点——会破坏 K0 重叠预期；确认当步若不共点补判断，K0 判断易全 0；配色禁 first.dir。
- 口径变更写 `lib/history/msg_history.dart` 与根目录 [`task-log.md`](task-log.md)。

### 方案B层号
- **结构层 0 起编**：`levels[].level==0`=K0连线；原 level N → N-1。`chartMaxKn=structureMax+1`。
- **连线族**（line/combine/kn/三型/四型/趋势线/分型/截断/比例/节奏/斜率）：catalog `kn==displayKn`，取数 `LevelBundle.level==kn`；禁止再写 `displayKn+1` / 绘制 `kn-1`。
- **中枢/Math/volume/BS/背驰**：K0=原生 bars/`zs_k0`；K1+ 取 structure `level==kn-1`。帧上 `frame.level=structure+1`（显示中枢号，避与 zs_k0 撞号）。
- **collect*ByKn**：`out[0]=k0`，pipeline 写 `out[lv.level+1]`；`levelsWithFrozen*Bs` history 键=`lv.level+1`。
- **趋势线/节奏父层**：子=`displayKn`，父=`displayKn+1`（仍是「看上一层」，但不再相对旧 1 起编拧着）。
- **DLL**：改 Rust 后必须重编并覆盖 `windows/native/chan_ffi.dll`；冷启动连续单步验收。

### Kn相邻比例 / Kn步进节奏
- **范围**：比例仍副图；**节奏为主图**（`MainIndicatorKind.stepRhythm`，价轴挂投影价）；节奏只保留 **normal**；主图水平节奏线 / transition / strict1382 本轮未做。默认关联进 Kn指标、绘制静音。
- **映射（全层同构·方案B）**：`displayKn` ↔ Kn连线 `level==displayKn`；节奏子分型=`displayKn` confirms；父分型切组=`displayKn+1` confirms。
- **相邻比例**：子线=主图出现链（冻段+展示轨虚线/种子），**虚实不论**；按 `beginX` 出现序取末两根 `ratio=|cur|/|prev|`；K0 颗粒度写入会话。踩坑：勿只读冻段（动态虚线步会变 0）；勿按 `endConfirmX`/`isSure` 过滤排序。
- **步进节奏**：组锚=父分型极值；命名从 **0-0**；子同向分型开窗实时算、反向分型关窗后**持上个 x-x 原值续写**（升：顶关→底确认前；降镜像；其它 x-x 同理）；再开窗恢复实时；父分型确认切组并 `groupId++`、清 holdLines；key 含 groupId。绘制：`value`=节奏投影价挂主图价轴；Δx==1 才点线续连、名在左侧、同 `roundRef` 同色、升暖降冷。禁止副图残留 `SubIndicatorKind.stepRhythm`。锚点：分笔·K1·K0 77–114 续上个 0-0。
- **tooltip 三类（2026-08-08）**：层内 `-。-` 分桶：①`Kn背驰_*`；②`Kn比例`+`Kn节奏*`；③其它（均线/通道/斜率/延伸/MACD/布林/RSI/KDJ/Demark）。
- **验收**：连续单步（非一键跳末）；口径变更写 `lib/history/msg_history.dart` 与根目录 `task-log.md`。

### Math 指标 / 副图绑定 / 十字 asOf
- **Demark（主图）**：`MainIndicatorKind.demark`；锚 K0 低点向上垂直排；文案 `S1…S9`/`C1…C13`/`完成买|完成卖`；Setup9 与 Countdown13 都算完整信号。买红/橙、卖绿/青。进主图「Kn指标」层全选，默认静音。副图枚举已删除。
- **Demark 设置三项**：Countdown 宽松 close↔close[i-2]（默认）/原版严 close↔low|high[i-2]；完美9 默认关；反向 Setup 打断 Countdown 严=打断（默认）/宽松=不打断。
- **Kn绑定清单（副图层全选必须含）**：volume/tickCount/分型类/**中枢判断/确认**/BS/比例/斜率/MACD/RSI/KDJ/**背驰算法**（Demark/节奏已迁主图；无 turnrate）。启动默认仍不勾背驰（`defaultSubIndicatorsK0` 过滤）；点「Kn指标」可一层全选。
- **默认绘制（关联≠全画）**：层全选仍勾全集；默认实际绘制仅主图 Kn/合并/中枢/连线 + 副图分型确认/判断/截断/中枢确认/判断；其余关联项默认删除线静音（`isDefaultDrawnMain/Sub`），单击 chip 可打开。
- **主图 Math/节奏仍绑层全选**：均线/通道/布林/Demark（与中枢同号）；节奏与连线同号。
- **十字 asOf 右侧不画**：蜡烛/成交量/分型/BS/Math 副图已截断；主图均线/通道/布林走 `_paintPriceSeries`；三型/四型/趋势线射线右端截到 asOf 柱心，禁止画到视口右缘「看见未来」。
- **当下冻结**：`MathSeriesFreezeStore` 格点首次非空写入后冻结；参数变更清空并 0..当前步重冻。背驰另有 `DivergenceFreezeStore`（本层 MACD/RSI 力度；旧格不改、新 x 追加）。验收：连续单步（非一键跳末）。
- **背驰 v12**：12 算法（已删 turnrate_avg，离线无换手）；全体 Kn背驰_* 副图十字下整段高亮；MACD 四算法另按贡献柱高亮。含斜率同源连线斜率。显示名 `Kn背驰_斜率`；ML 特征键 `diver_line_slope_*`（勿与旧 slope 振幅摊平混淆）。
- **桶宽**：筹码/笔数分布共用；在「数学指标参数」输入框设置，最小 0.01，落盘筹码配置。
- **踩坑**：新增副图指标时同步改 ①catalog ②`subIndicatorsForLevel` ③绘制分支 ④`crosshairSubRows` ⑤`msg_history`；漏任一环=「没和 Kn指标绑定」或「十字右侧读数空白」。默认不勾≠不进层全选——背驰即此例。背驰力度须与 Math 同号（`displayKn`），禁止再绑死 K0。Math 副图绘制须对冻结仓 `min(bars.length, series.length)`，禁 RSI/KDJ/MACD 越界。

## 已实现功能速览

- **Pipeline 会话 + Delta 增量**：`chan_pipeline_create/append/append_delta/snapshot/reset/free`；Flutter 走 `PipelineDelta` + `PresentationCache` + `IncrementalBarFeatureLookup`，N=2000 Lookup 从 6.3s 降至 1s（6x）。
- **背驰 v12**：12 种力度分项（MACD area/peak/full_area/diff + RSI + slope 等），副图整段蓝/琥珀高亮，MACD 按贡献柱差异化着色；`DivergenceFreezeStore` 冻结。
- **BS 全类**：一类/二类/N 类买卖点全层同构；V2.1 标签（等高递增/严格新极值复位）；会话双键冻结；副图 `Kn一类BS`/`Kn二类BS`/`Kn N类BS`；十字 tooltip/快照/ML 特征闭环。
- **笔数/笔数分布**：分笔第 4 列真实笔数；K0 左侧笔数分布同构筹码；峰分类 `-1/+n`；tooltip 峰/笔数峰独立类别。
- **斜率/延伸/趋势线/均线/通道**：副图 `Kn连线斜率`；主图 `Kn三型平移线`/`Kn四型对线`/`Kn趋势线`/`Kn均线`/`Kn通道`；滑动窗多组；延长线落点价；asOf 截断。
- **Demark**：主图 `KnDemark`（S1–S9/C1–C13/完成买/卖）；三项设置（宽松 Countdown/完美9/反向打断）。
- **中枢判断/确认**：副图 `Kn中枢判断`/`Kn中枢确认`；离开窗/确认同拍共点；空间升降色（抬高红/下移绿）；会话冻结。
- **ML 机器学习**：设置入口 + 时序三截（训练/验证/测试）+ 展望窗 α + 漂移告警 + XGBoost 训推（Python 训 + Rust 推）+ K0 一类 BS 样本 libsvm 导出。
- **历史记录/审计**：复制页面快照、复制调试信息（5 组探针）、审计诊断记录；`msg_history.dart` 常驻口径变更。
- **筹码/笔数设置**：筹码分布迁设置面板（仅 K0）；笔数分布独立开关；桶宽迁「数学指标参数」输入框。
- **tick 分笔**：`period=tick` 一字线画点；同分钟 n 笔均分秒位；成交量三分色（B/S/灰）；笔数 0 保留 0。
- **tooltip 格式化**：层内 `-。-` 分桶；`===` 分层；数字 `【】` 方形框；`K{n}合并` GG/DD=原始区间极值、MG/MD=框体高低点；三类（背驰/比例+节奏/其它）。

## 后续规划

- [x] ~~跨段中枢(KuaDuan)~~：已于 2026-07-27 **彻底移除**（计算/JSON/主图指标/as-of 全清）
- [x] ~~Normal/OverSeg 双中枢~~：已于 2026-07-28 **统一为单套 ZS**（OverSeg 口径），JSON/主图/十字 as-of 全链路对齐
- [x] Android JNI 复用 `chan_data`（环境/SDK/交叉编译 + 内置 a_Data 种子解压；全量离线库导入待补）
- [x] 背驰 v12 / 一类+二类+N 类 BS / 笔数分布 / 斜率延伸趋势线 / Demark / 中枢判断确认副图 / ML 闭环 / Pipeline Delta+Incremental Lookup / 历史记录审计
- [ ] 全量离线库一键导入（当前仅支持单股 `chan_load_klines`）
- [ ] 策略回测框架（基于 Pipeline 会话的增量 replay + 持仓/对错判定）
