# 机器人验证（专属执行逻辑 · 高优先级）

> **权限**：用户口头授权且会话 `active` 时生效；**不得擅自关闭 App**。  
> 与 [`AGENTS.md`](AGENTS.md) 关系：**总则见 `AGENTS.md`**（含确认门禁、编译与重启、提交与推送）；本文件只管**机器人验证专属**的启停、界面与验收口径。  
> **编译与启动按 `AGENTS.md`「完成后 · 编译与重启」节执行**：由智能体后台（detached）跑 `build_rust.ps1`，它会自动杀旧 App、编译，并在编译成功后自动拉起新 App。

## 人机协同（半自动）分工

| 步骤 | 执行者 |
|------|--------|
| 口头授权、写入/更新 `session.json` | 用户 + 智能体（按对话） |
| **编译** | 智能体（后台 `build_rust.ps1`，见 `AGENTS.md` 编译与重启节） |
| **打开 App** | 智能体（脚本编译成功后自动拉起） |
| App 内点「开始」、肉眼验界面 | **仅用户**（需在场操作） |
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

- 首次启用：复制 `a_Data/robot_verify/session.json.example` → `session.json`（后者仅本机，已 gitignore），再将 `active` 设为 `true`。  
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
| `jiyou_keypoint_20261001` | **计优**（关键点位指标统计）2026-10-01 批次 | **是** |

- 注册表：`lib/robot_verify/robot_verify_registry.dart`
- 能力开关：`lib/robot_verify/robot_verify_suite_meta.dart`（`continuousStepFreeze: true` 时自动挂载 `continuous_step_freeze` 阶段）
- 对拍实现（**已保存、可单独调用**）：`lib/robot_verify/continuous_step_verify.dart` → `runContinuousStepFreezePhase`
- 计优套件实现（**已保存、可单独调用**）：`lib/robot_verify/suites/jiyou_keypoint_20261001.dart` → `runJiyouKeyPointInProcess`

### 计优套件的四个阶段（`jiyou_keypoint_20261001`）

| 阶段 | id | 验什么 |
|------|----|--------|
| 1 | `flutter_test_jiyou` | `flutter test test/jiyou/`（80 例：统计算子 / 关键点位收集 / 编排落盘 / 门控·诊断·差异度·复现参数 / UI 面板与对话框） |
| 2 | `inprocess_jiyou_keypoint` | 002003 1m 连续单步 → 建冻结账 → 收转折点 → 出表；15 项断言（点位去重、只收已确认、分组非空、均值夹在最小最大、中位数夹在四分位、众数命中 ≤ 样本数、同输入重跑逐字节一致、JSON/TSV 可序列化） |
| 3 | **`jiyou_contrast_walk`** | **机器人自己连续单步走到末根** → 收点 → 出表 → 顶底差异度；断言「每步只喂 1 根且步数 = K0 总根数」（`StepFreezeWalkTrace.isOneByOne`，从根上排除「一次性喂满再算」）、差异度降序单调、与手工重算对拍；`details.topContrast` 输出 Top-10 差异清单 |
| 4 | `continuous_step_freeze` | 002003 1m + 分笔 连续单步 vs 走完瘦包 对拍（自动挂载） |

无 `a_Data/002003` 时阶段 2/3/4 `skipped`（`skipReason: no_verify_data`），总评仍可通过。

**阶段 3 为什么存在**：原先「冷启动连续单步走到末根 K → 点计优 → 看顶底差异有没有洞察」只能靠人眼，且规定不许用「一键跳末」代替。现在这条由机器人自己跑完：`StepFreezeParityDriver.walkWithTrace` 在原本的逐根循环里留下轨迹（纯记录，不改任何计算语义），用它证明确实是逐根。**但「有没有洞察」是主观判断、写不成断言** —— 所以只把 Top-N 差异清单原样输出到 JSON，由人看报告判读；机器人负责证明链路正确（逐根走完 → 账是逐根冻的 → 面板第一行确实是差异最大的），不假装能理解洞察。

**计优口径（验收时按这个判）**：关键点位 = 各级别连线**已确认冻结**的转折点（顶/底）；取值 = **转折极点 K 那一行**的指标冻结值（读 `BarFeatureLookup.byIdx[poleX]`，与十字线/ML 同源），`confirmX` 只作审计不参与取值；分组 = 级别 × 顶/底 + 全部汇总；数值型给 均值/中位/标准差/最小/最大/P25/P75/众数（分桶近似，**桶命中占比低于阈值即判「无显著众数」**），类别型给精确众数 + 占比；空样本一律「—」不补 0；默认分组样本下限 3；面板默认按**顶底差异度** `|顶均值−底均值| / RMS(两组标准差)` 降序。

### 连续单步验收：含义与是否「阉割」

**含义（不是截图）**：主图 `_rebuildCombine` 冻结合并已抽到 `lib/step_freeze/step_freeze_merger.dart`（`StepFreezeSessionState` + `StepFreezeMerger`），机器人 `StepFreezeParityDriver` 与主图**同源**。逐根 K `syncTo` 后合并全类冻结仓，再与「走完瘦包」路径做签名对拍；分笔另跑探针 T1/T2（`audit_probe_assertions.dart`）。

**能否 100% 替代你在界面上「连续点单步 + 眼看主图」？** **不能。** 机器人做的是**可重复的数据对拍**，不操作 Widget、不模拟键盘点击。相对主图 `_rebuildCombine` 全链路，当前对拍是**有意收窄的子集**（不是把已有对拍逻辑砍短）：

| 已覆盖（与发布闸门单测一致） | 未覆盖（主图步进仍有、机器人未验） |
|------------------------------|-------------------------------------|
| 管道步进 / 走完瘦包末态一致 | **步退**、换股重载、仅筹码模式 |
| 1/2/N 类买卖、中枢确认/判断、分型判断 | **BS 裁决**（`bsVerdict`）合并 |
| Kn 比例、斜率、节奏会话历史 | **Math/背驰冻结仓**、截断开关 `_truncationCheck` 传入差异 |
| 002003 固定区间 1m + 分笔 | 任意代码/区间、验收探针 T1/T2 锚点（如分笔 77–114 节奏持值） |
| 末态签名 + 半程快照冻段数 | 每一根中间步的「肉眼点位」抽检（只验末态对拍，不逐步列印全历史） |
| **寻优报告头文案 + 结果面板 Tab 计数**（`indicator_search_report_header_test.dart`，含 `testWidgets`） | 报告头在**真实主图会话**下的观感（字号/换行是否溢出，仍需人眼） |
| **「内弱外强不被切点前占仓扭曲」回归**（`indicator_search_slot_distortion_test.dart`：合成信号确定性证明 + 002003 逐候选不变量） | 其它标的/区间上「差异确实发生」的样本量（非固定数据集，差异可能为 0） |
| **取消扫描**（`indicator_search_cancel_test.dart`：Runner 语义 + 真实对话框 tap「取消扫描」→「已取消」） | 取消时**正在落盘的大 TSV** 人工查看是否可读 |

**结论**：`continuous_step_verify` **没有**相对原 `run_to_end_vs_step_freeze_test` 做阉割；**有**相对「主图完整步进语义」的**范围缺口**。若要缩小缺口，应在该文件（或共享 harness）**增补**合并项/场景，而不是改 UI。

### 寻优 UI 层：已可机器人替代的 spot-check（2026-09-30 增补）

原先「请人工开寻优看一眼」的三条，现已全部进入 `test/indicator_search/`，**随第一阶段 `flutter_test_indicator_search` 一并跑**（用例数由 12 增至 25）：

| 原人工 spot-check | 现状 | 用例 |
|------------------|------|------|
| 报告头「内外各独立重跑」文案 | ✅ 自动：`reportHeader()` 断言 + `testWidgets` 断言面板**真的渲染出**该行 | `indicator_search_report_header_test.dart` |
| 「内弱外强不再被切点前占仓扭曲」 | ✅ 自动：合成信号确定性复现「切点前占仓 → 切点后买点被拒」，并证明独立重跑不拒；002003 逐候选断言外段成交根全 > 切点、笔数 ≥ 旧切单 | `indicator_search_slot_distortion_test.dart` |
| 「取消扫描」→「已取消」 | ✅ 自动：Runner `requestCancel` 语义 + 真实 `IndicatorSearchDialog` tap「取消扫描」→ 断言阶段「已取消」、按钮消失、保留部分 TSV | `indicator_search_cancel_test.dart` |

仍需人眼的只剩**观感类**：报告头在真实主图会话下的换行/字号是否溢出、取消时那份大 TSV 手工打开是否可读。

> **落地要点（Widget 测试踩坑，务必照做）**
>
> 1. `path_provider` 测试环境无插件 → `pubspec.yaml` 的 `dev_dependencies` 已加
>    `path_provider_platform_interface`，测试内注入指向临时目录的假实现。
> 2. 对话框返回 `AlertDialog`，**必须 `showDialog` 挂载**；直接塞进 `body` 不会
>    渲染出按钮（`find.text('取消扫描')` 恒空）。
> 3. **FakeAsync 两面性，缺一不可**：
>    - 真实 IO / FFI（取路径、落盘、冻结）只在 `tester.runAsync()` 里推进；
>    - 扫描循环挂在 `Future.delayed(Duration.zero)` 上，属 FakeAsync 定时器，
>      **无时长 `pump()` 不会唤醒它**，点完取消后必须改用**带时长** `pump(1ms)`
>      才能推进到循环开头的取消检查。
> 4. `pump(duration)` 会把窗口内零时长定时器**一次性排空** —— 想在扫描中途插
>    手，就用**无时长** `pump()` 逐步推进（配合 `scanYieldEvery: 1`）。
> 5. 为此给生产类加了 4 个**仅测试用、生产路径为 null** 的钩子：
>    `IndicatorSearchDialog.runnerFactory` / `candidateOverride` / `scanYieldEvery`，
>    以及 `IndicatorSearchRunner.onCancelRequested`（证明取消信号真的送达了扫描器）。
>    均为可选命名参数，**不改变任何生产语义**。


无 `a_Data/002003` 时阶段 `skipped`（`skipReason: no_offline_002003`），总评仍可通过；有数据则失败即真失败。

新套件需要连续单步：在 `robot_verify_suite_meta.dart` 登记 `continuousStepFreeze: true` 即可，无需复制对拍代码。

---

*其它协作规则见 [`AGENTS.md`](AGENTS.md)。*
