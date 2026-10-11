# 机器人验证（专属执行逻辑 · 高优先级）

> **权限（2026-10-10 起 · 用户明确要求放开）**：**默认全自动化，由 agent 全程负责**。
> 唯一硬约束：**不得关闭用户正在手动使用的 App**。
> 与 [`AGENTS.md`](AGENTS.md) 关系：**总则见 `AGENTS.md`**（含确认门禁、编译与重启、提交与推送）；本文件只管**机器人验证专属**的启停、界面与验收口径。  
> **编译与启动按 `AGENTS.md`「完成后 · 编译与重启」节执行**：由智能体后台（detached）跑 `build_rust.ps1`，它会自动杀旧 App、编译，并在编译成功后自动拉起新 App。

## 人机协同（**全自动**）分工

| 步骤 | 执行者 |
|------|--------|
| 写/更新 `session.json`（`active:true` + `suiteId`） | **智能体**（默认自动，无需逐次授权） |
| **编译** | **智能体**（后台 `build_rust.ps1`，见 `AGENTS.md` 编译与重启节） |
| **打开 App**（自动进入机器人验证模式） | **智能体**（脚本编译成功后自动拉起） |
| App 内点「开始」、跑完整套件 | **App 自动** |
| 轮询 `status.json` 等待 `phase=done` | **智能体** |
| **关闭 App** | **智能体**（`robot_verify_auto.ps1` 自动关；`-NoClose` 可保留窗口） |
| 读取报告（`last_report.json` 优先，剪贴板兜底） | **智能体** |
| **分析报告、产出验收结论**（逐条列出失败项） | **智能体** |
| 是否 push | **智能体**（验收通过后可直接 push；**不通过必须如实报告，不得放宽判据放行**） |

> **唯一的例外**：若探测到 `chan_kline` **已在运行且不是本次 agent 启动的**，
> 说明用户正在手动使用 —— 此时**不得关闭**，应提示用户并改用其它取报告方式。
> 确认逻辑见 `robot_verify_auto.ps1` 的 `-Force` 参数（默认不杀外部已开进程）。

## 界面行为

1. **启用即可见**：独立「机器人验证」窗口，步骤清单 + 进度条，确认模式已开启。  
2. **结束后**：界面**仅**显示「验证已完成」、通过/失败摘要、剪贴板提示；**不展示**报告全文。  
3. **可自动退出**：agent 全自动模式下由脚本关闭；人工旁观时仍可手动关窗。  

验证：`flutter test`（indicator_search，JSON 汇总）+ 进程内自检 + **连续单步冻结对拍**（002003 1m/tick，与主图步进同管道）；报告为 **单行 UTF-8 JSON**（剪贴板 / `last_report.json` / `last_report.txt` 同内容），`status.json` 仍为摘要。

## 覆盖边界（必读 · 2026-10-10 实测补充）

**机器人验证走的是 `RobotVerifyApp`，完全绕过主界面。**
`main.dart:123` 里 `_robotVerifyEnabled()` 为真时 `main()` 直接返回 `RobotVerifyApp(...)`，
**根本不会构建 `ChanKlineApp` / `KlineHomePage`**。

因此：

> **「E2E ALL PASS」不能作为主界面正常的证据。**

要验主界面，必须先 `a_Data/robot_verify/session.json` → `active:false`，再直接启动 exe。

**判定主界面是否崩，不用眼睛**（崩了必退进程 + 必打堆栈）：

1. `session.json` 置 `active:false`；
2. 启动 exe 并**把 stdout/stderr 重定向到文件**；
3. 等 30~60 秒，看：① 进程是否还活着 ② `Responding` 是否 `True`
   ③ 日志里有无 `EXCEPTION` / `Null check operator`。

2026-10-10 实测：进程存活 256 秒、`Responding=True`、日志无异常 → **主界面不崩**。
`widget_test` 那次空指针是**测试环境无数据源、K 线图未挂载**导致的假崩溃。

## 启用条件

1. **默认由智能体自行启用**，无需用户在场；`session.json` → `active: true` 即可。
2. 套件按当前任务选（见「当前登记套件」），**为本轮改动新建/复用的套件须登记在册**。
3. 下一任务开始前由 agent 默认把 `session.json` → `active: false`；同一 `suiteId` 可保留套件定义。

## 一键全自动化（推荐入口）

```powershell
# 写 session.json -> 后台编译 -> 启动 App -> 轮询 -> 自动关 App -> 读报告 -> 打印结论
powershell -NoProfile -File CHAN_RUST/scripts/robot_verify_auto.ps1 -SuiteId <suiteId>
```

| 参数 | 作用 |
| --- | --- |
| `-SuiteId` | 要跑哪个套件（写入 `session.json`）；默认取 `session.json` 里已有值 |
| `-SkipBuild` | 跳过编译（App 已是本轮最新产物时用，省时间） |
| `-NoClose` | 跑完**不关 App**（人工旁观时用） |
| `-TimeoutSec` | 轮询超时上限，默认 1800 秒 |
| `-Json` | 只把报告 JSON 打到标准输出，便于 agent 解析 |

**报告读取优先级**：`last_report.json` → `last_report.txt` → 剪贴板。
**结论判定**：agent 读 `ok` 字段；任一 phase `ok:false` 即整体不通过，
`skipped` 视同通过（但要在结论里如实注明「被跳过的项」）。

## 启动方式

- 首次启用：复制 `a_Data/robot_verify/session.json.example` → `session.json`（后者仅本机，已 gitignore），再将 `active` 设为 `true`。  
- `session.json` 为 `active: true` 时，启动 App 即进入机器人验证。  
- 可选环境变量：`CHAN_REPO_ROOT`、`CHAN_KLINE_ROOT`。

## 可选：仅重试取报告（不启动 App）

```powershell
powershell -NoProfile -File CHAN_RUST/scripts/robot_verify_agent_finish.ps1 -NoClose
```

（默认脚本也不关 App；`-Close` 才会结束进程。全自动场景请直接用上面的 `robot_verify_auto.ps1`。）

## 当前登记套件

| suiteId | 用途 | 连续单步冻结对拍 |
|---------|------|------------------|
| `indicator_search_opt_20260930` | 寻优枚举 2026-09-30 批次 | **是** |
| `jiyou_keypoint_20261001` | **计优**（关键点位指标统计）2026-10-01 批次 | **是** |
| **`e2e_20261010`** | **本轮 E2E**（S3 当下性 + 线型签名 + 工程治理），见下节 | **是** |

- 注册表：`lib/robot_verify/robot_verify_registry.dart`
- 能力开关：`lib/robot_verify/robot_verify_suite_meta.dart`（`continuousStepFreeze: true` 时自动挂载 `continuous_step_freeze` 阶段）
- 对拍实现（**已保存、可单独调用**）：`lib/robot_verify/continuous_step_verify.dart` → `runContinuousStepFreezePhase`
- 计优套件实现（**已保存、可单独调用**）：`lib/robot_verify/suites/jiyou_keypoint_20261001.dart` → `runJiyouKeyPointInProcess`

### 本轮 E2E 套件（`e2e_20261010` · 2026-10-10 增补）

| 阶段 | id | 验什么 |
|------|----|--------|
| 1 | `flutter_test_e2e` | `kn_clock_causality_test.dart`（采样钟因果，含 S3 两条）+ `indicator_legend_test.dart`（线型签名） |
| 2 | **`inprocess_s3_presence`** | **本轮核心**：走**回测出信号的那条链**（`readEvalClockSeries`），逐 `asOf` 与「只喂 `bars[0..asOf]` 重算」的前缀重放对拍；另钉死「该层无段时刻不得提前报值」，并反向断言「旧最终态口径此处确实报了值」防止探针失效 |
| 3 | `inprocess_legend_signature` | 布林 `中实/上实/下虚`、唐奇安 `中长虚/上点虚/下实`、回归全虚 —— 三类签名互不相同；且**同层必须同色**（颜色不同反而说明层色体系被破坏） |
| 4 | `continuous_step_freeze` | 002003 1m + 分笔 连续单步 vs 走完瘦包 对拍（自动挂载） |

**阶段 2 为什么必须走 `readEvalClockSeries`**：`lookupTradeNumeric`（取值/tooltip）与
`readEvalClockSeries`（出信号）是**两条不同的链**，只验前者会漏掉真正的求值路径。
**前缀侧必须带自己的时钟**，否则两侧采样格点不同，比的是采样密度而不是因果性
（`lessons_learned` 第 13 条）。

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

原先「请人工开寻优看一眼」的三条，**随第一阶段 `flutter_test_indicator_search` 一并跑**：

| 原人工 spot-check | 现状 | 用例 |
|------------------|------|------|
| 报告头「内外各独立重跑」文案 | ❌ **覆盖已丢失**（见下方警告） | ~~`indicator_search_report_header_test.dart`~~ **已被 `b7d0729d` 删除** |
| 「内弱外强不再被切点前占仓扭曲」 | ✅ 自动：合成信号确定性复现「切点前占仓 → 切点后买点被拒」，并证明独立重跑不拒；002003 逐候选断言外段成交根全 > 切点、笔数 ≥ 旧切单 | `indicator_search_slot_distortion_test.dart` |
| 「取消扫描」→「已已取消」 | ✅ 自动：Runner `requestCancel` 语义 + 真实 `IndicatorSearchDialog` tap「取消扫描」→ 断言阶段「已取消」、按钮消失、保留部分 TSV | `indicator_search_cancel_test.dart` |

> ### ⚠️ 覆盖回退警告（2026-10-10 核实）
>
> `b7d0729d`（2026-10-08「寻优口径切回本地版」）在**重写寻优核心约 2000 行**
> （`search_core.dart` 363 / `search_verdict_views.dart` 227 /
> `result_panel.dart` **1043 行**）的**同一次提交**里，删除了 5 个测试文件约 700 行：
>
> ```
> indicator_search_report_header_test.dart      -243
> indicator_search_inf_payoff_diag_test.dart    -212
> indicator_search_early_stop_parity_test.dart   -63
> indicator_search_oos_slice_test.dart           -88
> indicator_search_parity_test.dart              -66
> ```
>
> 连带后果：`reportHeader()`（`search_env.dart:387`）**失去唯一调用方，已成死代码**；
> 本文件上一版本却仍把它列为「已可机器人替代的 spot-check」—— **文档失真**。
>
> **`robot_verify_full_suite_test.dart` 里 `minExpected = 42` 那个魔数是报警器，
> 不是过期数字**（实测 `test/indicator_search/` 现存 24 例且全过）。
> **不要把它改成 24** —— 那等于拆掉报警器、掩盖覆盖回退。
> 正确处置是**恢复被删的测试**（注意被测 API 已在该提交大改，旧用例未必还能编译）。

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
