# 智能体验证（Agent API）能力扩展计划

> 版本：2026-10-30 · 起草：MainAgent（仅出计划，不执行）
> 执行主体：由用户指定的其它智能体按本文档执行
> 本计划文档本身不改任何代码；执行前须通读下方「执行须知」并遵守工程门禁。

---

## 一、计划概要

**目标**：把「智能体验证」（本地 Agent API，`CHAN_AGENT_API=1` 启用，端口 127.0.0.1:12321）从当前的「控制 + 缠论快照」扩展为 **agent 可等价完成人类在 App 上的全部功能操作、并拿到全部数据** 的通道。

**一句话交付**：人类能对 App 做的功能操作（换股、换周期、步进、指标切换、配置修改、寻优、回测、ML、取数）——agent 都能通过 HTTP/文件轮询通道完成并拿到结果；**不改 Rust、不改 FFI、不改任何缠论/回测/寻优计算逻辑**，全部是 Flutter/Dart 层的「出口」扩展。

**能力覆盖目标**（对照人类操作）：

| 人类操作 | 现状 | 目标 |
|---|---|---|
| 选股加载 / 换周期 / 步进 / 播放走完 | ✅ 已有 | 保持 |
| 读缠论结构快照 / 单根十字线 / 截图 / 状态摘要 | ✅ 已有 | 保持 |
| 机器人验证 | ✅ 已有 | 保持 |
| **原始 K 线序列（OHLCV）导出** | ❌ 缺 | **P0 新增** |
| **主图/副图指标切换** | ❌ set_indicators 未实现 | **P0 新增** |
| **筹码/笔数/截断开关/数学指标参数读写** | ⚠️ 有读缺写 | **P0 新增** |
| **历史消息（msg_history）读取** | ❌ 缺 | **P0 新增** |
| **指标寻优（提交 + 结果）** | ❌ 缺 | **P1 新增** |
| **回测（提交 + 结果）** | ❌ 缺 | **P1 新增** |
| ML 工作台 | ❌ 缺 | P2 可选 |
| 批量任务（一次多标的） | ❌ 缺 | P2 可选 |
| 主题色/窗口/动画等纯观感操作 | — | **非目标**（无功能意义，不做） |

---

## 二、需求范围与边界

### 2.1 需求

1. **控制等价**：agent 能触发与用户手动操作**等价**的动作（走主界面同一个函数，不另起计算）。
2. **数据等价**：agent 能拿到与画面/落盘**同源**的数据（K 线、指标值、缠论结构、寻优/回测/ML 结果）。
3. **双通道一致**：HTTP 端点与文件轮询（`a_Data/agent_live/`）都能用，语义一致。
4. **安全边界保持**：仅 `127.0.0.1:12321` 监听 + `X-Agent-Token` 认证；新端点一律走同一认证。

### 2.2 非目标（明确不做）

- ❌ 不改 Rust `chan_data` 缠论内核、不改 `chan_ffi.dll`、不改 FFI 协议号。
- ❌ 不改任何缠论计算口径（合并/分型/段/中枢/买卖点/步进管道/采样钟/当下性）。
- ❌ 不新增指标、不改绘制算法、不触碰 `chart_indicator.dart` 目录本身（`set_indicators` 只做「切换既有指标集」，等价用户勾选）。
- ❌ 不实现纯 UI 观感类操作（主题色、窗口大小、弹窗动画、拖拽/右键交互形态）。
- ❌ 不把「重计算」在 agent_api 层重写一遍（寻优/回测/ML 全部复用既有 runner/模块）。

### 2.3 工程边界（执行智能体必须遵守，来源：AGENTS.md）

| # | 门禁 | 内容 |
|---|---|---|
| G1 | 确认执行门禁 | 涉 Rust 缠论内核、Flutter 步进/冻结/会话历史合并、主图绘制语义、`chan_bridge` 管道、步进当下性/冻结不回写 —— 必须先文字提方案，等用户「确认」再改。**本计划全部任务均不触碰上述范围**，但仍须在开工时向用户说明边界。 |
| G2 | AGENTS.md 修改门禁 | **任何 agent 不得修改 `AGENTS.md`**（除非用户自己提出）。 |
| G3 | 当下性 | 任何时刻计算只基于当前及之前 K 线，不用未来数据；「计优」是事后统计属例外。Agent API 只是读取/触发，不得引入任何新口径。 |
| G4 | 动态段/冻段专项门禁 | 回测核心口径始终使用动态段（当下性）；凡涉及「仅用冻段/等段定型/采样钟最终态 vs asOf」的决策必须先问用户。本计划不涉及此类决策，但验收时若发现信号落点异常，先按 `lessons_learned` 第 8 条排查。 |
| G5 | 提交与推送 | commit 由执行智能体自行执行（验收全绿后），**必须拆小粒度 commit，一事一提交**；**push 前必须向用户确认**（列分支、提交列表、文件数）。 |
| G6 | 编译与重启 | 需要重启 App 验证时，由执行智能体**后台（detached）**跑 `CHAN_RUST/scripts/build_rust.ps1`，输出重定向到 `build_rust_run.log`（**禁止**重定向到 `build_windows_last.log`）；跑完读 `build_rust_run.log` 判成败。**硬约束：不得关闭用户正在手动使用的 App** —— 先探测 `chan_kline` 是否在运行且非 agent 启动，若是则提示用户。 |
| G7 | 任务总结格式 | 每次给用户的任务总结按「开场词（祝你每天开心，早日发财。）→ 简洁版 → 详细版」两版固定顺序写。 |
| G8 | 记录与同步 | 每次完成修改类任务：`task-log.md` 末尾追加一条（执行者/类型/操作/结果/演示）；随后按 `obsidian` skill 同步 Obsidian 副本（当日笔记 + MOC + 索引）。 |

---

## 三、现状基线（已核实，2026-10-30）

### 3.1 已有端点（`lib/agent_api/agent_api_server.dart`）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 版本、FFI ABI、pid、data_root、uptime |
| GET | `/state` | code/period/stepIdx/totalBars/isPlaying/main+sub indicators/chip+tick 配置/truncationCheck |
| GET | `/snapshot` | AgentSnapshot：各层段、分型确认、买卖点、中枢、末根 bar_feature |
| GET | `/tooltip?idx=N` | 单根十字线 tooltip 行 |
| GET | `/screenshot` | 图表 RepaintBoundary PNG |
| POST | `/command` | step_to / step / play / pause / stop / run_to_end / load_code / set_period / run_robot_verify；`set_indicators` 返回「未实现」 |
| GET | `/` | 服务标识 |

命令类型定义在 `lib/agent_api/agent_api_host.dart` 的 `AgentCommand`；认证 `_checkAuth` 校验 `X-Agent-Token`；文件轮询通道 `command.json` → `result.json` / `state.json`（500ms）。

### 3.2 关键实现事实

- 契约层：`AgentApiHost` 抽象类（`lib/agent_api/agent_api_host.dart`），主界面 `_KlineHomePageState implements AgentApiHost`（`main.dart:362`）。
- 主界面步进/换股/换周期复用的就是用户按钮函数（`_stepForward`、`_loadKlines` 等），**天然与手动操作等价、同管道**。
- 原始 K 线：主界面持有 `_bars`（`List<KlineBar>`，`main.dart` `_loadKlines` 载入）；**已有数据但无序列化出口**。
- 指标集：`_mainIndicators` / `_subIndicators` 为强类型枚举集；目录构建在 `lib/widgets/kline_chart.dart`（`buildMainIndicatorCatalog(maxKn)` / `buildSubIndicatorCatalog`），label 与枚举的映射可从目录取（勿硬编码指标名）。
- 配置：`ChipConfig` / `TickDistConfig` / `_truncationCheck` / `MathIndicatorConfig`（bollN/donchianN/regressK）均在主界面有状态与既有修改入口。
- 历史消息：主界面 `_msgHistory`（`lib/history/msg_history.dart`）。
- 寻优：`IndicatorSearchRunner`（`lib/indicator_search/indicator_search_runner.dart`）已是**纯逻辑类**（compileCache / evaluateCandidate / runAll），结果 `ComboVerdict` 可序列化；结果另有落盘 TSV（`indicator_search_results.tsv`）。对话框 `indicator_search_dialog.dart` 是 UI 状态机（取数→冻结→枚举→扫描），其中「枚举+扫描」主体逻辑在 runner，可直接复用。
- 回测：`executeStrategyBacktest`（`lib/backtest/backtest_run.dart` 等）已是纯逻辑；`StrategyConfig`（buyAst/sellAst/quantity/…）可序列化；回测指标 `SegmentMetrics` 可序列化。
- ML：`lib/ml/`（ml_workbench / ml_xgb_trainer / ml_rule_score / ml_feature_schema）已存在。
- 数据下载：`loadKlinesEx(tickSource: 'protocol')` 自动走通达信协议逐交易日拉分笔落缓存（`tdx.rs`），**加载代码即自动取数**。

### 3.3 文档基线

- `AGENT_VERIFY.md`（根目录）是智能体验证的现行规格文档；**实现完成后必须同步更新该文档**（新增端点表）。
- 机器人验证规格见 `ROBOT_VERIFY.md`（套件登记、连续单步、绕过主界面等口径）。

---

## 四、总体方案与架构原则

### 4.1 架构原则（每一条都是硬约束）

1. **只加出口，不加逻辑**：所有新能力 = 「主界面既有状态/函数 → 契约方法 → HTTP 端点」三层接线。禁止在 `agent_api/` 下重写任何计算（第 15 条：已有权威实现别再写一份等价物）。
2. **契约先行**：先在 `AgentApiHost` 抽象类加方法（纯 Dart、可离线单测），再在 `_KlineHomePageState` 实现，最后在 `AgentApiServer` 加路由；`AgentCommand` 枚举同步扩展。
3. **与手动等价**：新命令必须调用主界面用户操作同一条路径（如指标切换走用户勾选指标的同一设置函数），不得绕过主界面状态直接改内部字段（否则步进当下性/冻结仓语义会分叉）。
4. **认证一致**：所有新端点复用 `_checkAuth`（`X-Agent-Token`）；文件轮询通道不加新文件，复用 `command.json`/`result.json`/`state.json` 结构。
5. **异步重计算**：寻优/回测/ML 可能耗时数分钟，HTTP 请求**不得同步阻塞** —— 采用「POST /command 发起（返回任务 id）→ 轮询 result.json/state.json 或 GET /task?id= 取结果」模式。
6. **序列化友好**：所有返回 JSON 的字段沿用现有 `toJson()` 命名风格（snake_case），复用 `agentJsonEncode`。
7. **不留测试垃圾**：临时测试代码调试完删除，保持工程干净。

### 4.2 模块改动地图（全部任务的总览）

```
lib/agent_api/agent_api_host.dart     ← 契约：新增方法 + AgentCommand 新类型 + 新 DTO
lib/agent_api/agent_api_server.dart   ← 路由：新增端点 + 命令分发
lib/main.dart                         ← _KlineHomePageState 实现新契约方法（复用既有函数）
lib/widgets/kline_chart.dart          ← 只读：指标目录 label→枚举映射的取用点（不改目录本身）
lib/indicator_search/*                ← P1：抽「纯逻辑入口」复用 runner（不重写）
lib/backtest/*                        ← P1：复用 executeStrategyBacktest 与 metrics 序列化
lib/ml/*                              ← P2：可选，接 run + 结果读取
AGENT_VERIFY.md                       ← 文档同步（每个阶段完成后）
test/agent_api/*                      ← 新增单测（契约层纯 Dart 测试 + 主界面接线测试）
```

---

## 五、阶段任务分解

### P0 · 数据与配置出口（优先级最高，预计 1 个工作日）

**验收总则（每个子任务都执行）**：
- `flutter analyze --no-pub lib test 2>&1 | Select-String "error -"` 必须为空（**只看 error 行**，条数仅供参考，见 `lessons_learned` 第 17 条）；
- 新增/修改测试全绿；
- `AGENT_VERIFY.md` 端点表同步更新；
- 提交（小粒度、一事一提交）。

#### P0-1 原始 K 线序列导出（/klines）

- **目的**：agent 直接拿到当前/指定区间 OHLCV，覆盖「000001 最近一个月数据」这类需求。
- **契约**（`AgentApiHost` 新增）：
  ```dart
  /// 当前已加载会话的 K 线序列（与主图同源；含 idx/时间/open/high/low/close/volume/tickCount）。
  List<KlineBar> get bars;
  ```
- **端点**：`GET /klines?period=<周期>&days=<N>`（可选参数；缺省返回当前会话全部 bars）。
  - 返回：`{"ok":true, "code":…, "period":…, "bars":[{"idx":…,"ts":…,"open":…,"high":…,"low":…,"close":…,"volume":…,"tick_count":…}, …]}`
  - 用 `period`/`days` 过滤时：**复用主界面 `_loadKlines` 的区间口径**（begin/end 换算规则一致），不得另造区间算法；数据不足时返回 `ok:false` + 提示「本地无数据，请先 load_code 触发协议下载」。
- **实现要点**：
  - `bars` getter 直接返回主界面 `_bars`（只读视图，序列化时转 map，不暴露可变引用）。
  - `KlineBar` 的字段以 `lib/models/kline_bar.dart` 为准；序列化放 `agent_api_host.dart` 内新增 `agentBarJson(KlineBar)`（勿改 KlineBar 本身）。
- **验收**：启用 API 实测：加载 002003（已有数据）后 `GET /klines` 返回根数与 `/state.total_bars` 一致；逐条抽样比对最后一根的 close 与 `/snapshot.tail_bar_feature` 一致。加 `days=5` 参数后根数符合预期。

#### P0-2 指标切换（set_indicators 实现）

- **目的**：agent 能等价用户勾选主图/副图指标。
- **契约**（`AgentApiHost` 新增）：
  ```dart
  /// 按目录 label 设置主/副图指标集（等价用户在面板勾选；触发重算重绘）。
  Future<String> setIndicators({required Set<String> mainLabels, required Set<String> subLabels});
  ```
- **命令扩展**：`AgentCommand` 增加 `main_indicators` / `sub_indicators`（**逗号分隔的目录 label 列表**，可空字符串表示清空该侧）。`_executeCommand` 的 `set_indicators` 分支从「返回未实现」改为调用 `host.setIndicators`。
- **实现要点**：
  - label→枚举映射**必须从目录取**：`buildMainIndicatorCatalog(maxKn)` / `buildSubIndicatorCatalog(maxKn)`（`kline_chart.dart`），按 `label` 反查枚举；查不到返回明确错误（不要静默忽略）。
  - 设置动作走主界面**用户勾选指标的同一条函数/状态变更路径**（先 grep 出主界面设置指标的实际入口，如 `_mainIndicators` 的赋值点与重算触发点，直接复用）；**不得**在 agent_api 层复制一份「设置 + 重绘」逻辑（第 11/15 条）。
  - 属于「主图绘制语义」边界？——**否**：只是切换既有指标集的显示，不改变绘制算法、不新增指标。但开工时仍按 G1 向用户说明。
- **验收**：`set_indicators` 后 `/state.main_indicators` / `sub_indicators` 与设置一致；`/snapshot` 结构不变；界面（人工或截图 `/screenshot`）与设置一致；传不存在的 label 返回 `ok:false` 且状态未变。

#### P0-3 配置读写（筹码/笔数/截断/数学指标参数）

- **目的**：agent 能读改这些设置并触发等价重算。
- **契约**（`AgentApiHost` 新增）：
  ```dart
  /// 按 key 更新配置；返回新配置 JSON。支持：chip_enabled/chip_bucket/tick_enabled/tick_bucket/
  /// truncation_check/boll_n/donchian_n/regress_k。
  Future<Map<String, dynamic>> updateConfig(String key, dynamic value);
  ```
- **命令扩展**：`AgentCommand` 增加 `config_key` / `config_value`；`type=set_config`。
- **实现要点**：
  - 读：`/state` 已覆盖（chip/tick/truncation）；补 boll_n/donchian_n/regress_k 到 `/state` 的 `math_config` 段。
  - 写：**必须走主界面用户修改配置的同一条路径**（grep 出 chip/tick/truncation/math 的设置函数，复用；注意 truncation 开关切换会重建 pipeline / 清冻结仓——这正是用户手动操作的行为，等价即可，**不得额外清仓**）。
  - 数值校验：非法值（如 bollN<1、bucket≤0）返回 `ok:false` 并给出合法范围。
- **验收**：改 `truncation_check` 后 `/state` 反映新值且 App 正常（主界面不崩检查，见第六节）；非法值被拒；改 chip_bucket 后 `/snapshot` 的筹码相关字段（若有）随新桶步长变化（或至少 `/state` 生效）。

#### P0-4 历史消息读取（/messages）

- **目的**：agent 能读到 App 内部消息流（初始化提示、验证启动等）。
- **契约**：`AgentApiHost` 新增 `List<Map<String, String>> historyMessages();`（取 `_msgHistory` 最近 N 条，含时间戳与正文）。
- **端点**：`GET /messages?limit=N`（默认 50）。
- **验收**：与 App 内消息面板内容一致（抽样比对）；limit 生效。

### P1 · 计算任务入口（寻优 / 回测，预计 2~3 个工作日）

**原则**：全部复用既有纯逻辑模块，只补「任务发起 + 结果读取」两个出口；采用异步任务模式。

#### P1-1 指标寻优（run_search）

- **契约**（`AgentApiHost` 新增）：
  ```dart
  /// 发起寻优：复用 IndicatorSearchRunner 全量扫描；返回任务 id。
  /// 参数：code/period/begin/end（缺省取当前会话）、max_candidates（默认 12000，尊重
  /// IndicatorSearchSettingsStore 现有设置）、in_ratio（默认 0.7）。
  Future<String> startSearch({required String code, String? period, String? begin, String? end,
      int? maxCandidates, double inRatio = 0.7});
  /// 查询任务进度/结果：phase/done/total + verdicts（ComboVerdict 序列化）。
  Map<String, dynamic> searchTaskStatus(String taskId);
  ```
- **实现要点**：
  - 复用 `IndicatorSearchRunner.runAll`（`indicator_search_runner.dart`）——**它已经是纯逻辑**；`indicator_search_dialog.dart` 里「取数→冻结→枚举→扫描」的驱动循环里，除 UI 状态更新外的部分抽到 `lib/indicator_search/indicator_search_job.dart` 新文件（`IndicatorSearchJob`：入参 bars/harness/settings，出参 stats+verdicts，带进度回调）；对话框改为调用同一个 job，保证两条路径同源（第 11 条：同能力两条路径必须同实现）。
  - 任务表放 `AgentApiServer` 进程内 `Map<String, _TaskState>`；结果同时**照旧落盘 TSV**（既有 `indicator_search_results.tsv` 路径），API 读进程内结果即可。
  - 取消：`type=cancel_search` + taskId，调用 `IndicatorSearchRunner.requestCancel()`。
- **端点**：`POST /command {"type":"run_search", ...}` → `{"ok":true,"data":{"task_id":"..."}}`；`GET /search_task?task_id=...` → 进度/结果。
- **验收**：对 002003 发起一次小规模寻优（max_candidates=200）与 GUI 寻优结果对拍（**同批候选、同 splitX、verdicts 逐条一致**）；取消语义与 `indicator_search_cancel_test.dart` 对齐；大候选（12000）只验「能发起、进度推进、可取消」，不强制跑完。

#### P1-2 回测（run_backtest）

- **契约**（`AgentApiHost` 新增）：
  ```dart
  /// 以给定买卖条件跑全区间回测并返回 SegmentMetrics 全量指标。
  /// 买卖条件用「可读文本/变量 id 表达」——先实现最小可用集：
  ///   buy: {"event":"STRUCTURE.K0.BUY1"} 或 {"cmp":{"left":"RAW.K0.CLOSE","op":"gt","right":10.0}}
  /// 与既有 TradeAst 序列化对齐（复用 condition_ast.dart 的 toJson/fromJson）。
  Future<Map<String, dynamic>> runBacktest({required Map<String,dynamic> buyAst,
      required Map<String,dynamic> sellAst, String? code, String? period,
      String? begin, String? end, int? quantity, double? commissionRate, double? slippageAmount});
  ```
- **实现要点**：
  - 复用 `executeStrategyBacktest`（`lib/backtest/backtest_run.dart`）与 `computeSegmentMetrics`；`TradeAst` 的 JSON 序列化已有（`condition_ast.dart` 里 `tradeAstFromJson` 等），直接复用，**不另造条件语言**。
  - 撮合参数（quantity/费率/滑点/成交价模式）与回测工作台默认值一致（`StrategyConfig` 默认），agent 可覆盖。
  - 异步任务模式同 P1-1。
- **端点**：`POST /command {"type":"run_backtest", ...}`；`GET /backtest_task?task_id=...`。
- **验收**：对 002003 用「K0 一类买点 → K0 一类卖点」跑回测，与回测工作台 GUI 结果**逐指标一致**（trades/winRate/netProfit/…）；成交价/费率参数生效（设非零费率后 netProfit 变化方向合理）。

### P2 · 可选扩展（按需，不排期）

- **ML 工作台**：`run_ml_train` / `GET /ml_task`，复用 `ml_workbench.dart` / `ml_xgb_trainer.dart`；输出训练摘要 + 特征/规则文件落盘路径。
- **批量任务队列**：`run_search_batch`（多 code），复用 P1 的任务表 + 顺序执行（工程当前无并发需求，先串行）。
- 验收原则：与对应 GUI 结果对拍一致；落盘产物路径随结果返回。

---

## 六、验收策略（每阶段必做）

### 6.1 代码级
1. `flutter analyze --no-pub lib test 2>&1 | Select-String "error -"` **为空**（第 17 条：只看 error 行）。
2. 新增单测：
   - 契约层纯 Dart 测试：`test/agent_api/agent_api_contract_test.dart`（AgentCommand 序列化往返、新 DTO toJson、无 UI 依赖）；
   - 端点路由测试：mock `AgentApiHost` 实现，逐端点断言路径/参数/返回结构/401（复用既有 `agentJsonEncode` 风格）；
   - 接线测试：`set_indicators` 的 label→枚举映射用**真实目录**（`buildMainIndicatorCatalog`）测「已知 label 命中 / 未知 label 拒绝」。

### 6.2 端到端（智能体验证实测，脚本见 AGENT_VERIFY.md 第六节）
1. 环境变量 `CHAN_AGENT_API=1` 启动；`GET /health` 拿 token 路径；
2. 用 `X-Agent-Token` 逐一实测**新端点**：返回结构、参数生效、非法输入被拒（401/400/ok:false）；
3. 命令走文件轮询通道 `command.json` → `result.json` 各测一次，与 HTTP 结果一致。

### 6.3 主界面不崩检查（第 19 条：机器人验证绕过主界面，必须单独验主界面）
1. `a_Data/robot_verify/session.json` → `active:false`；
2. 启动 exe，stdout/stderr 重定向文件；
3. 等 30~60 秒：进程存活、`Responding=True`、日志无 `EXCEPTION` / `Null check operator`。

### 6.4 机器人验证（如新增套件）
- 若需要「命令步进 == 主图步进同管道」回归：在 `lib/robot_verify/robot_verify_registry.dart` 登记新套件 `agent_api_20261030`，`robot_verify_suite_meta.dart` 置 `continuousStepFreeze: true`（自动挂载连续单步对拍）；用 `robot_verify_auto.ps1 -SuiteId agent_api_20261030` 跑。
- **注意**：机器人验证走 `RobotVerifyApp` 绕过主界面，**不能**替代 6.3 的主界面检查。

### 6.5 编译与重启纪律
- 改动涉及 `lib/` 源码 → 需要重编验证（第 20 条：`-SkipBuild` 会测旧二进制）。
- 由执行智能体**后台**跑 `build_rust.ps1`，输出到 `build_rust_run.log`（第 2/3 条）；**先探测 `chan_kline` 是否在运行且非 agent 启动**——若是用户手动使用，提示用户并等确认再 build（G6 + ROBOT_VERIFY 例外）。

---

## 七、提交与推送策略

1. 每个 P0/P1 子任务独立一个 commit（一事一提交），commit message 遵循仓库既有风格（如 `feat(agent_api): ...` / `fix(agent_api): ...`）。
2. **不得把「代码 + 文档 + 日志」混进同一 commit**；临时脚本、`build_rust_run.log`、截图等不得入库（必要时加 `.gitignore`）。
3. commit 前 `git status` 自查：只应剩有意提交的内容。
4. **push 前必须向用户确认**：列分支、提交列表、文件数，得到明确同意再 push。

---

## 八、风险与注意事项（对照 lessons_learned.md，执行时逐条对照）

| 风险 | 对策 |
|---|---|
| R1 重计算阻塞 HTTP（寻优/回测跑数分钟） | 异步任务 + 轮询；HTTP 同步只做发起与查询 |
| R2 同能力两条路径漂移（对话框 vs API） | P1 强制「对话框与 API 共用同一 job/runner」（第 11 条） |
| R3 在 agent_api 层重写已有计算 | 硬约束：只接线，不重写（第 15 条） |
| R4 写中文/$ 的 Dart 源码经 PowerShell 命令行损坏 | 源码用 `write` 工具落盘 / base64 中转，**不经 PowerShell 字符串字面量**（第 7 条） |
| R5 analyze 只看条数漏 error | 只看 `Select-String "error -"` 行（第 17 条） |
| R6 机器人验证全绿 ≠ 主界面正常 | 机器人验证走 RobotVerifyApp 绕过主界面，必须补 6.3 主界面检查（第 19 条） |
| R7 改 lib/ 用 -SkipBuild 验证旧产物 | Dart 源码变了必须重编（第 20 条） |
| R8 冻结仓逐格冻结 | 涉及步进的测试若需历史序列，用逐根步进而非跳步（第 18 条）；agent_api 不新增此类计算，仅复读既有仓 |
| R9 杀掉用户正在用的 App | build 前探测进程归属；用户手动使用则提示等待确认（G6） |
| R10 指标 label 硬编码 | 映射一律从 `buildMainIndicatorCatalog` / `buildSubIndicatorCatalog` 目录取（AGENTS.md 指标同步清单） |
| R11 配置写触发重建/清仓语义 | 走主界面用户操作同一条路径；不得额外清冻结仓 |
| R12 大 JSON 响应 | /klines 用 period/days 限制；超长区间返回前 N 根 + 总数，不一次塞爆内存 |
| R13 测试环境无插件 | 新测试涉及 `path_provider` 时注入假实现（ROBOT_VERIFY.md 落地要点 1） |

---

## 九、收尾义务（每个阶段完成后）

1. `task-log.md` 末尾追加一条（执行者、类型、操作、结果、演示）。
2. 按 `obsidian` skill 同步 Obsidian 副本（当日笔记 + MOC 时间线 + 相关索引；task-log 是唯一源，Obsidian 只做保真副本）。
3. `AGENT_VERIFY.md` 端点表同步更新（P0 完成后补 /klines、/messages、set_config、set_indicators；P1 后补寻优/回测任务端点）。
4. 给用户的任务总结按 G7 两版格式（开场词 + 简洁版 + 详细版），验收结论必须如实（失败项逐条列出，不得放宽判据放行）。

---

## 十、执行智能体开场须知（开工前 10 分钟必读清单）

1. 通读本仓库 `AGENTS.md`（唯一正文）→ `lessons_learned.md`（开工前必读，命中的坑照做）→ `ROBOT_VERIFY.md`（验收口径）→ `AGENT_VERIFY.md`（本任务直接作用的规格文档）。
2. 确认执行边界：本计划全部任务 = Flutter/Dart 层「出口」扩展，**不触碰 G1 列出的关键逻辑**；若执行中发现任何改动会落入 G1/G4 范围，停下先文字问用户。
3. 开工时先向用户复述一次「本次改动范围 + 非目标」，得到用户认可后再动代码。
4. 每完成一个 P0/P1 子任务：按第六节验收 → 按第七节提交 → 按第九节收尾 → 按 G7 汇报。
5. 全部完成后：整理最终交付说明（新增端点清单 + 实测记录 + 遗留问题），push 前等用户确认。
