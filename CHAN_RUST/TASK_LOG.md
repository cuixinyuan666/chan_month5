# TASK_LOG

> 口径/行为变更记录（复制排查用）；与 `lib/history/msg_history.dart` 常驻历史同步维护。

## 2026-08-02 经验汇总（GG/DD 口径 + 切周期重载 + DLL 占用）

- **合并 GG/DD ≠ 框体高低**：Rust `MergeEngine` 向上合并取「高高/高低」，框体低点会被抬高；tooltip 的 GG/DD 必须在合并组内按原始K（Kn 用当步单元）重算 max(high)/min(low)。框体高低点只配 MG/MD。勿再把 `combine_high/low` 当 GG/DD。
- **切周期一字线 ≠ 聚合坏了**：Rust 聚合产出真 OHLC；前端若只 `setState(_period)` 不重载，会用「新周期蜡烛画法」画内存里仍是 tick 的数据（O=H=L=C）→ 整屏一字线。下拉选周期后必须立刻 `_loadKlines()`。排查先分清后端/前端，可用 ctypes 直调 `chan_ffi.dll` 证聚合。
- **DLL 复制仍失败**：`build_rust.ps1` 会杀 `chan_kline` 进程并重试复制；若终端里仍挂着 `flutter run`，`windows/native/chan_ffi.dll` 可能继续被占用。应先在该终端 `q` 退出 `flutter run`（或结束整个 Flutter/Dart 树）再跑脚本。
- **build_rust.ps1 编码（再踩）**：必须 **UTF-16 LE + BOM（FF FE）**。无 BOM 的 UTF-16 会被 PS 按系统码页误读 → 中文乱码 + `Missing closing ')'`（`$($App.Id)` 被拆坏）。编辑后应用解析检查确认 `PARSE_OK`，勿只看文件「看起来像 UTF-16」。
- **落盘位置**：口径正文见下方 2026-08-01 两条；UI 常驻历史见 `msg_history.appendMergeRangeExtreme` / `appendPeriodAutoReload`。

## 2026-08-01 K0/Kn合并 GG/DD 口径修正：组内原始区间极值

- **需求**：K0 idx=2（10:47 11.66/11.66、10:48 H11.70 L11.68、10:49 11.70/11.70，后两根向上包含合并）tooltip「K0合并」的 **DD** 应为 **11.68**（组内 idx1 的 low），而非当时显示 11.70。
- **根因**：GG/DD 此前取 Rust 快照 `combine_high/combine_low`，而 `MergeEngine` 向上合并取「高高/高低」（`absorb`：Up 分支 `self.low = self.low.max(u.low)`，见 `engine.rs:335-341`），框体低点=11.70；框体高低点实为 MG/MD 语义。
- **变更**（`bar_feature_lookup.dart`）：
  - `build`：K0 合并循环内按悬停合并组 x1..x2 切原始K重算 `combine_range_high/low`（max(high)/min(low)，逐K当下、无未来函数）；各层 Kn 以当步单元高低跑组内极值（`combineX1` 变则切组重算），写入 `combine_range_high_$n/low_$n`，与 K0 全层同构。
  - `crosshairTooltipRows` / `_levelBlockRowsFor`：GG/DD 改取原始区间极值（无则回退快照合并值）；MG/MD 仍为合并框框体高低点。
  - `msg_history.dart`：新增 `appendMergeRangeExtreme`（进程内去重）；`main.dart` 启动时调用。
- **口径**：`K{n}合并` GG/DD=组内原始区间极值；MG/MD=合并框框体高低点（闭合时同值，构建中虚线框悬停中段时不同）。
- **验证**：`flutter test` 中 `bar_feature_lookup_test` 新增 K0 用例（idx=2 断言 `K0合并:GG【11.70】/DD【11.68】/MG【11.70】/MD【11.70】`）；旧用例（无 combineFrames / 框体 MG/MD）不受影响。

## 2026-08-01 切周期立即自动重载（修复聚合显示为一字线）

- **问题**：App 周期下拉选 1min 及以上时，图表整屏一字线，疑似聚合错误。
- **定位**：后端 Rust 聚合正确（经 ctypes 直调 `chan_ffi.dll` 验证：1m/5m/1d/1mon/1y 均产出真 OHLC 蜡烛，`load_klines` 单测亦通过）。根因在 Flutter 前端：切换周期只 `setState(_period)` 触发重绘，并不重载数据；于是图表用「新周期蜡烛画法」去画内存中仍为 tick 的旧数据（每根 O=H=L=C），整屏一字线；须手动重载（长按中区/改日期）后才显示正确蜡烛。
- **变更**：
  - `main.dart`：周期下拉 `onChanged` 选中后立即 `_loadKlines()` 按新周期自动重载（选中代码非空时）；周期说明弹窗操作步骤同步更新（无需再手动加载）。
  - `msg_history.dart`：新增 `appendPeriodAutoReload`（进程内去重），记录该口径变更。
- **口径**：聚合逻辑不变（仍 ticks→1m→升周期，主图恢复蜡烛）；仅切换周期时自动重载，图表始终与所选周期一致。
- **验证**：`flutter analyze` 无新增问题；聚合正确性由 Rust 单测 + FFI 直调验证（见上）。

## 2026-08-01 十字 tooltip 标签格式化·全层同构

- **需求**：tooltip 内容格式化——各层标签统一「idx」命名；K0合并 仿照 K0中枢 取 GG/DD；中枢行「Kn」换为对应层级；另保留原 H/L 命名 MG/MD。
- **变更**：
  - `zs_compute.dart`：中枢行「K{n}中枢价格」→「K{n}中枢」；「K{n}中枢Kn序」→「K{n}中枢K{n} idx」（Kn→对应层级）；「K{n}中枢组No.」→「K{n}中枢 idx」。
  - `bar_feature_lookup.dart`：K0 块「K0[No.]」→「K0 idx」、「K0合并K0序」→「K0合并K0 idx」、「K0合并组No.」→「K0合并 idx」；合并行值 `GG/DD/MG/MD`：GG/DD=逐K当下区间极值（combineHigh/Low），MG/MD=合并框框体高低点（M=merge；K0 取 combineFrames 框体、Kn 取 levels[n].combineFrames 框体，as-of 与主图框同源、无未来函数；无框体时回退同值）；Kn 块行序与 K0 块同构：合并→合并K序→合并idx→分型确认/判断（含占位块补「K{n}合并 idx」行）。
  - `kline_chart.dart`：tooltip 的 `BarFeatureLookup.build` 的 K0 combineFrames 改用 `_effectiveK0CombineFrames`（十字 as-of 重建，避免 MG/MD 读到未来框体）；chip 轻量分支 K0[No.]→K0 idx。
  - `msg_history.dart`：新增 `appendTooltipFormatting`（进程内去重）。
- **口径**：`K{n}合并` GG/DD=逐K当下区间极值；MG/MD=合并框框体高低点（闭合框时与 GG/DD 同值，构建中虚线框悬停框内中段时不同）；中枢数量行标签=`K{中枢层}中枢K{中枢层} idx`。
- **验证**：`flutter test` 中 `zs_compute_test`、`bar_feature_lookup_test` 断言已同步更新并通过（含新增 MG/MD 框体取值用例）。

## 2026-08-01 筹码分布迁设置·仅K0

- **需求**：筹码分布从主图指标移动到设置面板，只保留 K0 分支。
- **变更**：
  - `chart_indicator.dart`：`MainIndicatorKind.chip` 枚举、`MainChartIndicator.chip` 构造、主图 catalog、层全选、默认勾选全部移除，主图指标选择器不再出现筹码。
  - `kline_chart.dart`：chip 层绘制改由 `chipConfig.enabled` 直接驱动（不再查 mainIndicators），`kn` 固定 0，cutoff=步进末根/十字 as-of 所在 K0；主图价签左侧避让同步只看总开关。
  - `chip_profile_compute.dart`：删除死代码 `cutoffForKn`（Kn 层→K0 cutoff 映射）及不再使用的 level_models 导入。
  - `main.dart`：设置面板总开关文案改为「已开启（主图右侧绘制 K0筹码）」；帮助弹窗操作步骤更新（无需再勾选主图指标）。
  - `msg_history.dart` / `bar_feature_lookup.dart`：常驻历史记录与注释口径同步。
  - `chip_profile_test.dart`：断言更新为「目录/默认勾选不再含筹码」。
- **口径**：筹码=设置开关控制；K1/…/Kn 筹码分支移除；`cutoffForKn` 不再存在。
- **验证**：`flutter analyze` 无新增问题；`flutter test` 中 chip_profile 全部通过；`widget_test`、`k0_combine_compute_test` 为改动前已存在的旧失败，与本任务无关。

## 2026-08-01 build_rust.ps1 自动关闭运行中 app

- **问题**：chan_kline 运行时 `chan_ffi.dll` 被占用，`build_rust.ps1` 复制 DLL 失败。
- **变更**：脚本内新增「检测→Stop-Process 强制关闭→WaitForExit 等待句柄释放」逻辑；两处 DLL 复制改为带 5 次重试的 `Copy-Dll`。
- **踩坑**：脚本原为 UTF-16 LE 编码（PowerShell 5.1 原生支持中文）；若写成无 BOM UTF-8 会被 5.1 按 GBK 误读，中文乱码且 `$` 被吞（`$($App.Id)` 变字面），修改后必须还原 UTF-16 LE。
- **验证**：启动 app 后跑脚本，自动关闭（PID 输出正确）、两处复制均成功。
