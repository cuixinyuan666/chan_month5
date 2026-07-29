# ����Ҫ����־

## 最新记录

### 2026-07-29 — 一字线仅 open=close；指标条避让标记

- **要点**：中枢一字锚定改为仅 `open==close`（去掉 high-low/tick 近一字误判，避免 18 这类塌成 ZG=ZD）；主图 `padT`/副图顶留白加大，指标名按钮不再盖住主副图标记。
- **关键路径**：`CHAN_RUST/rust/chan_data/src/zs.rs`；`flutter/.../kline_viewport.dart`、`kline_chart.dart`
- **注意**：需重载新 `chan_ffi.dll` 后一字线口径才生效

### 2026-07-29 — ZG/ZD常见命名互换 + Kn一买全层同构

- **要点**：中枢字段改为常见命名 ZG=上沿/ZD=下沿（框 high/low 几何不变）；新增一买：当前中枢框整体在上个下方触发，框内 1a/1b…不回写，层首 Kn 不参与；副图「Kn一买」与中枢同层同号。
- **关键路径**：`CHAN_RUST/rust/chan_data/src/zs.rs`、`buy1.rs`、`pipeline.rs`、`combine.rs`；Flutter `chart_indicator.dart`、`kline_chart.dart`、`buy1_frame.dart`、`msg_history.dart`
- **注意**：需用新 `chan_ffi.dll`（若 App 占用 dll 请先退出再复制）；触发条件为 `ZG_curr < ZD_prev`

### 2026-07-29 — Fix chart_level_line_style_test.dart failing tests

- **要点**：1) 添加 forZSOverSeg() 方法解决编译错误；2) 为 level 4-6 添加 frozenDashPattern 使测试通过；3) 新增 _zsOverSegColors 数组为 OverSeg 中枢提供独立配色
- **关键路径**：lib/widgets/chart_level_line_style.dart
- **注意**：同层 Normal/OverSeg 中枢必须不同色，测试期望 K0-K5 层配色相互独立

### 2026-07-29 — Create branch "bs-point"

- **要点**：Create new branch "bs-point" for new feature development; switch to branch
- **关键路径**：git branch, git checkout operation
- **注意**：Branch name uses hyphen instead of space per Git convention; all pending changes included

### 2026-07-28 ��� ������ȫ������������ + tooltip �ָ�������

- **Ҫ��**������/��󻯸�Ϊ `fillDesktopWorkArea`��`visibleSize`�����ܿ���������ʮ���� tooltip �� `====`/`��-��` �����ظ�������������ұ߿�
- **�ؼ�·��**��`CHAN_RUST/flutter/chan_kline/lib/window_work_area.dart`��`lib/main.dart`��`lib/widgets/crosshair_tooltip_panel.dart`��`windows/runner/main.cpp`
- **ע��**������������������ runner / pubspec���������ز�����

### 2026-07-28 — Update task log and commit/push

- **要点**：更新 TASK_LOG.md 记录当日工作，并执行 git commit + push 操作
- **关键路径**：TASK_LOG.md、CHAN_RUST/flutter/chan_kline/ 目录下的多个文件
- **注意**：分支为 kuaduan-deletion-branch，已与 origin 同步
