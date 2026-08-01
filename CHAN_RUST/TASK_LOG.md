# TASK_LOG

> 口径/行为变更记录（复制排查用）；与 `lib/history/msg_history.dart` 常驻历史同步维护。

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
