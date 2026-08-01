# TASK_LOG

> 口径/行为变更记录（复制排查用）；与 `lib/history/msg_history.dart` 常驻历史同步维护。

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
