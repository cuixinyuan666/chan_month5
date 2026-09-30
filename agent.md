# 机器人验证（专属执行逻辑 · 高优先级）

> **权限**：用户口头授权且会话 `active` 时生效；**不得**擅自替用户编译或启动 App。  
> 与 [`AGENTS.md`](AGENTS.md) 关系：总则见 `AGENTS.md`；**启停与分工以本文件为准**。

## 人机协同（半自动）分工

| 步骤 | 执行者 |
|------|--------|
| 口头授权、写入/更新 `session.json` | 用户 + 智能体（按对话） |
| **编译**、**打开 App** | **仅用户** |
| App 内跑完整套件 + **可视化进度** | App 自动 |
| **完整报告复制到剪贴板** | **App 自动**（结束时） |
| **关闭 App** | **仅用户**（手动关窗） |
| 将剪贴板内容粘贴回对话 | 用户 |

智能体**默认不再**关 App、**默认不再**替用户复制剪贴板（除非用户明确要求，可用 `robot_verify_agent_finish.ps1 -NoClose` 仅从 `last_report.txt` 重试复制）。

## 界面行为

1. **启用即可见**：独立「机器人验证」窗口，步骤清单 + 进度条，确认模式已开启。  
2. **结束后**：界面**仅**显示「验证已完成」、通过/失败摘要、剪贴板提示；**不展示**报告全文。  
3. **不自动退出**：用户自行关闭窗口。

验证：`flutter test`（indicator_search，JSON 汇总）+ 进程内自检 + **连续单步冻结对拍**（002003 1m/tick，与主图步进同管道）；报告为 **单行 UTF-8 JSON**（剪贴板 / `last_report.json` / `last_report.txt` 同内容），`status.json` 仍为摘要。

## 启用条件

1. **仅用户口头授权**。  
2. **仅限当前任务**验收。  
3. 下一任务开始前默认 **`session.json` → `active: false`**；再次口头授权且 **`suiteId` 相同**可保留套件定义。

## 启动方式

- `session.json` 为 `active: true` 时，用户正常启动 App 即进入机器人验证。  
- 可选环境变量：`CHAN_REPO_ROOT`、`CHAN_KLINE_ROOT`。

## 可选：智能体仅重试剪贴板

```powershell
powershell -NoProfile -File CHAN_RUST/scripts/robot_verify_agent_finish.ps1 -NoClose
```

（默认脚本也不关 App；`-Close` 才会结束进程。）

## 当前登记套件

| suiteId | 用途 | 连续单步冻结对拍 |
|---------|------|------------------|
| `indicator_search_opt_20260930` | 寻优枚举 2026-09-30 批次 | **是** |

- 注册表：`lib/robot_verify/robot_verify_registry.dart`
- 能力开关：`lib/robot_verify/robot_verify_suite_meta.dart`（`continuousStepFreeze: true` 时自动挂载 `continuous_step_freeze` 阶段）
- 对拍实现（**已保存、可单独调用**）：`lib/robot_verify/continuous_step_verify.dart` → `runContinuousStepFreezePhase`

### 连续单步验收：含义与是否「阉割」

**含义（不是截图）**：用与主图相同的 `ChanPipelineSession.syncTo` 逐根 K 喂数据，把本步 Rust 结构喂进与主图相同的 **冻结会话合并函数**（买卖点、中枢信号、分型判断、Kn 比例/斜率/节奏），再与「一次性走完 + 瘦增量」路径的**同口径数据签名**对拍。这是仓库里 `run_to_end_vs_step_freeze_test` 的同一套逻辑，迁到 `lib` 供机器人验证调用。

**能否 100% 替代你在界面上「连续点单步 + 眼看主图」？** **不能。** 机器人做的是**可重复的数据对拍**，不操作 Widget、不模拟键盘点击。相对主图 `_rebuildCombine` 全链路，当前对拍是**有意收窄的子集**（不是把已有对拍逻辑砍短）：

| 已覆盖（与发布闸门单测一致） | 未覆盖（主图步进仍有、机器人未验） |
|------------------------------|-------------------------------------|
| 管道步进 / 走完瘦包末态一致 | **步退**、换股重载、仅筹码模式 |
| 1/2/N 类买卖、中枢确认/判断、分型判断 | **BS 裁决**（`bsVerdict`）合并 |
| Kn 比例、斜率、节奏会话历史 | **Math/背驰冻结仓**、截断开关 `_truncationCheck` 传入差异 |
| 002003 固定区间 1m + 分笔 | 任意代码/区间、验收探针 T1/T2 锚点（如分笔 77–114 节奏持值） |
| 末态签名 + 半程快照冻段数 | 每一根中间步的「肉眼点位」抽检（只验末态对拍，不逐步列印全历史） |

**结论**：`continuous_step_verify` **没有**相对原 `run_to_end_vs_step_freeze_test` 做阉割；**有**相对「主图完整步进语义」的**范围缺口**。若要缩小缺口，应在该文件（或共享 harness）**增补**合并项/场景，而不是改 UI。

无 `a_Data/002003` 时阶段 `skipped`（`skipReason: no_offline_002003`），总评仍可通过；有数据则失败即真失败。

新套件需要连续单步：在 `robot_verify_suite_meta.dart` 登记 `continuousStepFreeze: true` 即可，无需复制对拍代码。

---

*其它协作规则见 [`AGENTS.md`](AGENTS.md)。*
