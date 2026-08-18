# 任务日志

> 所有智能体在完成任务后，应在此文件记录操作要点。格式如下，新增条目时追加到末尾。

---

## 条目格式

```markdown
### YYYY-MM-DD HH:MM — {任务标题}

- **执行者**：{智能体名称/标识}
- **任务类型**：{如：功能开发 / Bug修复 / 重构 / 配置 / 数据处理 / 复盘}
- **上下文**：{简要说明任务背景}
- **关键操作**：
  1. {操作要点 1}
  2. {操作要点 2}
- **结果**：{完成情况 / 产出文件 / 变更范围}
- **注意事项**：{如需后续跟进、待确认事项}
```

---

## 记录入口

1. 任务完成后，在本文件末尾追加一个新的 `###` 条目。
2. 填写执行者、任务类型、上下文、关键操作、结果。
3. 如有跨模块影响或后续依赖，在"注意事项"中注明。
4. 本文件采用 UTF-8 编码，提交至版本控制。

---

### 2026-07-28 — 修复中枢虚框定型的未来函数

- **要点**：离开 Kn 仅在确认态且与上一中枢不重叠时，上一虚框才变实线定型；动态 Kn 离开不得定型。新增 `find_zs_with_confirmed(n_confirmed)`，绘制跟 `is_sure`。
- **关键路径**：`CHAN_RUST/rust/chan_data/src/zs.rs`、`pipeline.rs`、`CHAN_RUST/flutter/chan_kline/lib/widgets/kline_chart.dart`、`lib/history/msg_history.dart`
- **注意**：改 Rust 后需 `build_rust.ps1` 重载 DLL；全层同构。

### 2026-07-28 — 添加 K0 中枢设计优化方案与样张

- **要点**：新增 K0 中枢设计文档与可视化样张，引入设计令牌体系，记录命名纠偏与单段虚框展示逻辑，提升用户体验与界面美观度。
- **关键路径**：`CHAN_RUST/docs/DESIGN_OPTIMIZATION.md`, `CHAN_RUST/docs/design_mockup.html`, `CHAN_RUST/flutter/chan_kline/lib/compute/zs_compute.dart`, `CHAN_RUST/rust/chan_data/src/zs.rs`, `CHAN_RUST/rust/chan_data/src/combine.rs`
- **注意**：引入设计令牌体系需后续协调统一颜色、排版和组件规范；与 Rust 端口径保持一致

### 2026-07-26 — Kn原生中枢十字线 as-of 动态显示，并补 ZS vs 跨段差异测试

- **要点**：实现十字线 as-of 动态显示功能（端段冻结时本地重算原生中枢），增加离开-返回与相邻合并对比测试，对齐 Rust find_zs 默认口径。
- **关键路径**：`CHAN_RUST/README.md`, `CHAN_RUST/flutter/chan_kline/lib/compute/zs_compute.dart`, `CHAN_RUST/rust/chan_data/src/zs.rs`, `CHAN_RUST/flutter/chan_kline/lib/widgets/kline_chart.dart`
- **注意**：需确保关闭十字线时仍绘制 Rust 末态逻辑；测试覆盖跨段差异场景

### 2026-07-27 — 删除跨段中枢(KuaDuan)功能并更新文档

- **要点**：彻底移除跨段中枢计算与展示逻辑，清理 Rust 计算层、Flutter 展示层及测试代码；在 README.md 后续规划中记录变更。
- **关键路径**：`CHAN_RUST/README.md`, `CHAN_RUST/rust/chan_data/src/kuaduan.rs`, `CHAN_RUST/flutter/chan_kline/lib/models/kuaduan_frame.dart`, `CHAN_RUST/flutter/chan_kline/lib/compute/kuaduan_compute.dart`, `CHAN_RUST/flutter/chan_kline/test/kuaduan_compute_test.dart`
- **注意**：推送含文件删除的变更到 main 分支需人工确认，以免被自动拦截

---

### 2026-07-27 13:59 — 清理构建产物与 IDE 缓存

- **执行者**：opencode
- **任务类型**：清理
- **上下文**：删除对工程无影响的调试日志、编译构建目录、IDE 缓存，释放磁盘空间并避免误提交
- **关键操作**：
  1. 删除 `CHAN_RUST/rust/target/`（Rust 编译产物）
  2. 删除 `CHAN_RUST/rust/target_alt/`（Rust 备用编译产物）
  3. 删除 `CHAN_RUST/flutter/chan_kline/build/`（Flutter 构建产物）
  4. 删除 `CHAN_RUST/flutter/chan_kline/.dart_tool/`（Dart/Flutter IDE 缓存）
  5. 删除 `CHAN_RUST/flutter/chan_kline/.idea/`（IDE 缓存）
  6. 删除 `CHAN_RUST/rust/chan_data/test.log`（Rust 测试日志）
  7. 更新 `.gitignore`，补充 `build/`、`.dart_tool/`、`.idea/` 条目
- **结果**：所有目标已删除；`.gitignore` 已更新，防止下次误提交
- **注意事项**：下次执行 `cargo build` 或 `flutter run` 时，相关目录会自动重新生成

### 2026-07-28 22:30 — 删除 Normal 中枢，统一 ZS 指标

- **执行者**：opencode
- **任务类型**：重构
- **上下文**：调查发现 `ZSAlgo::Normal` 与 `ZSAlgo::OverSeg` 在 `find_zs()` 中从未产生分支，两套输出数据完全相同。删除冗余的 Normal，保留 OverSeg 并统一命名为「中枢(ZS)」。
- **关键操作**：
  1. Rust `zs.rs`：删除 `ZSAlgo` 枚举、`ZSConfig.zs_algo` 字段、`with_algo()` 方法
  2. Rust `pipeline.rs`：删除 `zs_inc_normal` / `zs_normal_frames`，`zs_inc_over` → `zs_inc`，`zs_over_seg_frames` → `zs_frames`
  3. Rust `combine.rs`：删除 `zs_k0_normal_frames`，`build_k0_zs()` 返回单套，`zs_k0_over_seg_frames` → `zs_k0_frames`
  4. Rust `lib.rs`：删除 `ZSAlgo` re-export
  5. Flutter `chart_indicator.dart`：删除 `zsNormal`，`zsOverSeg` → `zs`，label 改为 `'K$kn中枢'`，catalog 四类严格分组（合并→KN→连线→中枢）
  6. Flutter `chart_level_line_style.dart`：删除 Normal 玫红配色，OverSeg 蓝青配色统一为 `_zsColors` + `forZS()`
  7. Flutter `kline_chart.dart`：删除 `zsK0NormalFrames`、Normal 绘制分支，`_drawZSOnMainChart` 去掉 algo 参数
  8. Flutter `zs_compute.dart`：删除 `ZSAlgoKind` 枚举，所有函数去掉 algo 参数
  9. Flutter `main.dart`：删除 `_zsK0NormalFrames`，默认指标改为 `MainChartIndicator.zs(0/1)`
  10. Flutter `level_models.dart` / `kline_combine_bundle.dart`：字段重命名 + JSON key 更新
  11. Flutter `msg_history.dart` / `app_debug_snapshot.dart`：调试文本更新
  12. Flutter `zs_compute_test.dart`：对齐新 API
  13. Rust FFI `chan_ffi/src/lib.rs`：更新注释
- **结果**：16 个文件改动；Rust `cargo test` 64/64 通过，Flutter `dart analyze` 0 errors，`flutter test` 3/3 通过
- **注意事项**：中枢配色 K0=蓝色 `#3B82F6`（非红色）；主图指标 picker 分隔线按类别（合并/KN/连线/中枢）严格分隔

### 2026-07-28 23:10 — 中枢虚线框变实线框时机修正

- **执行者**：opencode
- **任务类型**：Bug修复
- **上下文**：中枢虚线→实线的判定逻辑不完整。动态 Kn 时末 ZS 可能被误判为实线；无 active_unit 时末 ZS 始终为虚线（应实线）。
- **关键操作**：
  1. Rust `pipeline.rs` `export()`：`find_zs()` 返回后，若 `active_unit.is_none()` 则强制末 ZS `is_sure=true`（所有段已冻结，中枢定型）
  2. Flutter `kline_chart.dart` `_drawZSOnMainChart()`：新增 `hasActive` 判断——有 active_unit 时所有中枢框强制虚线，无 active_unit 时由 `is_sure` 控制
- **结果**：2 个文件改动；Rust `cargo test` 64/64 通过，Flutter `dart analyze` 0 errors，`flutter test` 3/3 通过
- **注意事项**：K0 无 active_unit 概念，虚实完全由 `is_sure` 控制（全层同构）### 2026-07-28 — 统一中枢框架，移除 Normal/OverSeg 概念

- **要点**：删除冗余的 Normal 中枢算法，统一使用 OverSeg 并命名为「中枢(ZS)」；修复中枢虚实线判定逻辑，确保无 active_unit 时末 ZS 正确定型为实线。
- **关键路径**：`CHAN_RUST/rust/chan_data/src/zs.rs`, `pipeline.rs`, `lib.rs`, `CHAN_RUST/flutter/chan_kline/lib/widgets/kline_chart.dart`, `lib/history/msg_history.dart`, `task-log.md`
- **注意**：Rust `cargo test` 64/64 通过，Flutter `dart analyze` 0 errors，`flutter test` 3/3 通过
---

### 2026-07-28 — Tooltip 中枢内容重构：连续中枢4行格式 + 数字方形框 + 分隔线 + 全屏启动

- **执行者**：opencode (big-pickle)
- **任务类型**：功能开发
- **上下文**：tooltip 中枢部分原为单行 `Kn中枢seq·count dir ZG/ZD`，需仿照 Kn合并 模式拆为4行；数字值需加方形框区分；同层内容用 `-。-` 分隔线；App 默认全屏启动。
- **关键操作**：
  1. Rust `zs.rs`：`ZSFrame` 新增 `gg`/`dd` 字段，`zs_to_frames` 从 `ZS` 赋值；`seq` 改从 0 起
  2. Dart `zs_frame.dart`：新增 `gg`/`dd` 字段 + `fromJson` 兼容
  3. Dart `zs_compute.dart`：中枢行拆为4行——价格(GG/DD/ZG/ZD)/Kn序(count)/组No.(seq)/确认(上一帧isSure，仅首根K检测)
  4. Dart `bar_feature_lookup.dart`：新增 `starSeparator` 工厂 + `boxNum()`/`boxNumInString()` 静态方法；K0/Kn块插入 `-。-` 分隔线；所有数字值加 `【】`
  5. Dart `crosshair_tooltip_panel.dart`：渲染 `-。-。` 分隔线
  6. Dart `bar_feature_lookup.dart`：副图区域跳过 `fractalConfirm` kn=1（已在 K0 块输出，消除重复）
  7. Dart `main.dart`：`maximize()` → `setFullScreen(true)`；全屏按钮同步切换
  8. 测试更新：`zs_compute_test.dart` 5个用例 + `bar_feature_lookup_test.dart` 2个用例全部通过
- **结果**：Rust 8个ZS测试通过，Dart 7个tooltip测试通过；6个文件修改
- **注意事项**：全层同构（K0/Kn 行为一致）；`确认`语义=上一中枢首次确认（isSure）；`boxNumInString` 用正则 `(\d+\.?\d*)` 匹配数字
---

### 2026-08-15 — 智能体长期记忆：Task Log + test 演示 + 同页前后对比

- **执行者**：cursor
- **任务类型**：配置 / 文档 / 演示基础设施
- **上下文**：为 Cursor、OpenCode、Claude Code、WorkBuddy 等建立统一长期记忆与任务验收流程
- **关键操作**：
  1. 新增 `AGENT_LONG_TERM_MEMORY.md`、`.cursor/rules/agent-long-term-memory.mdc`、`.trae/skills/chan-agent-memory/SKILL.md`
  2. 新增 `a_Data/test/demos/` 目录与 `_template`、本任务自举演示 `2026-08-15-agent-long-term-memory`
  3. Flutter：`lib/task_demo/` + test 面板「任务演示/前后对比」；`msg_history.appendAgentLongTermMemory`
  4. 更新 `AGENTS.md`、`.workbuddy/memory/MEMORY.md`
- **结果**：全智能体任务完成必写 task-log；修改类任务须可演示 + 上下对比（全新功能可免对比）
- **演示**：test → 任务演示/前后对比 → `2026-08-15-agent-long-term-memory`
- **注意事项**：后续任务复制 `_template` 建演示；Rust 改动仍须重编 DLL

---

### 2026-08-15 — 开发演示阶段：启动自动加载 + 点击下一步步进

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：在长期记忆基础上，开发阶段启动 exe 应自动展示最新任务完成项，并支持步进动图演示；用户可退出演示阶段自行加载
- **关键操作**：
  1. `TaskDemoSettingsStore`（`.chan_task_demo_settings.json`）持久化「开发演示阶段」开关，默认开
  2. `TaskDemoWalkthroughOverlay`：主图底部叠层，左原本/右本次，下一步/自动播放/退出
  3. `manifest.walkthroughSteps` + 启动时 `latestDemo` 自动 `_startTaskDemoWalkthrough`
  4. 更新 `AGENT_LONG_TERM_MEMORY.md` §2.1、`msg_history.appendDevelopmentDemoPhaseLaunch`
- **结果**：演示阶段开→冷启动自动加载；关→不自动加载，可手动打开列表或最新演示
- **演示**：冷启动即见叠层；设置关「开发演示阶段」后重启验证不再自动加载
- **注意事项**：`autoLaunchOnStartup: false` 可让某 manifest 不参与启动自动加载

---

### 2026-08-15 — 确认执行门禁 + 演示白话 + 全智能体必读入口

- **执行者**：cursor
- **任务类型**：配置 / 文档
- **上下文**：无「确认执行」禁止改关键逻辑；演示用白话；确保各智能体接任务能读到记忆文件
- **关键操作**：
  1. `AGENT_LONG_TERM_MEMORY.md` §0：确认执行门禁、白话演示、接任务必读顺序
  2. 新增 `CLAUDE.md`、`OPENCODE.md` 指向主规范
  3. 更新 `.cursor/rules`、`AGENTS.md`、WorkBuddy、Trae skill
  4. `msg_history.appendAgentConfirmExecuteGate`；演示 manifest 改白话示例
- **结果**：关键逻辑改动须用户原话含「确认执行」；演示文案禁止堆代码引用
- **演示**：冷启动叠层第 3 步说明含「确认执行」门禁
- **注意事项**：非关键逻辑（演示 md、task-log）仍可随任务直接改

---

### 2026-08-15 05:44 — Tooltip 成交量/笔数循环补 asOf 截断（与当下性纪律对齐）

- **执行者**：workbuddy
- **任务类型**：重构 / 演示
- **上下文**：审查 tooltip 合规性时发现，成交量/笔数（含 B/S/G 分解）两个循环未像其它区段那样按悬停 asOf 截断；经追 `_accumulateConfirmGated` 确认取值本身已是累计到 i 的因果量（无未来数据），故悬停显示不变，但为与 tooltip 其余项当下性纪律统一，补防御性 asOf 截断。
- **关键操作**：
  1. `CHAN_RUST/flutter/chan_kline/lib/models/bar_feature_lookup.dart` 成交量循环与笔数循环：在 `for (var i = 0; i < bars.length; i++)` 体首补 `if (asOf != null && bars[i].idx > asOf) continue;`
  2. 配套 test 演示：`a_Data/test/demos/2026-08-15-tooltip-vol-tick-asof/`（manifest.json + before.md + after.md，白话文案）
- **结果**：2 处循环补截断；悬停显示行为不变（只读当前根）；tooltip 全区段 asOf 纪律一致
- **演示**：test → 任务演示/前后对比 → `2026-08-15-tooltip-vol-tick-asof`；默认股 002003 任意根悬停验证读数一致
- **注意事项**：此改纯防御性、无显示变化；未动 `msg_history`（口径未变）；非 Rust 改动，无需重编 DLL

---

### 2026-08-15 10:06 — 背驰「斜率」特征键改 ASCII line_slope（算法保留）

- **执行者**：cursor
- **任务类型**：重构 / 演示
- **上下文**：ML 特征键混入汉字「斜率」，易与旧 slope（振幅摊平）混淆；确认执行后只改键名，不删这一路算法
- **关键操作**：
  1. `DivergenceAlgo.lineSlope.key`=`line_slope`；新增 `labelSuffix`=`斜率` 给副图芯片/十字
  2. 十字 tip、副图选择器用显示名；`diverFeatureKey` 仍走 ASCII
  3. ML 中文映射：`line_slope`→连线斜率，`slope`→振幅摊平；最长匹配解析 full_area 等
  4. 历史记录 + TASK_LOG；演示 `2026-08-15-diver-line-slope-ascii`
- **结果**：图上仍显示「背驰_斜率」；导出键 `diver_line_slope_*`；schema_version 仍为 1
- **演示**：默认股 002003 勾 K0背驰_斜率；冷启动自动加载本条演示
- **注意事项**：纯 Flutter，无需重编 DLL；旧 feature.meta / 旧模型须重导出重训；未改 volumn 拼写

---

### 2026-08-15 11:36 — 分支1快进合入 main，清理编号分支与 2worktree

- **执行者**：cursor
- **任务类型**：配置
- **上下文**：用户要求将当前分支 1 与 main 合并，删除分支 2–10，删除 2worktree
- **关键操作**：
  1. 确认分支 1 比 main 超前 17 个提交、main 无独有提交；本地编号分支仅有 2/3/4/8/`2worktree`（无 5–7、9–10）
  2. 因 `chan_ffi.dll.bak_224828` 被占用无法常规 merge，改用 `reset --soft` 将 main 快进到与 1 同一提交 `b0bcc018`，并重建索引对齐工作区
  3. 删除 worktree `2worktree/`（目录已移除）；删除本地 2/3/4/8/`2worktree`；删除远端 origin/2、origin/3、origin/4、origin/8
  4. 删除前将 2worktree 里未入库的 tooltip 审计稿拷到 `CHAN_RUST/tooltip_audit_2026-08-14.md`（仍未跟踪）
- **结果**：当前在 `main`，与分支 1 同提交；本地 main 比 origin/main 超前 18 个提交（未推送）；分支 1 仍保留
- **演示**：全新功能·免对比（纯 git 整理）
- **注意事项**：未推送 main；未删除分支 1 / origin/1；工作区仅余未跟踪审计稿

---

### 2026-08-15 12:50 — 交易条件变量目录阶段0（分支 trade）

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：确认执行后从 main 开 `trade` 分支；回测先建可交易变量目录，不另起一套指标、不在图上另判箭头
- **关键操作**：
  1. 登记 K0 开高低收量、各层虚拟K开高低收、各层布林三轨；读现有取样与布林冻结仓
  2. 中枢高低、一类买卖点、三型/节奏等只盘点不进公式；混层/混钟禁止组合
  3. 没有数=不可用；布林热身仍按图上出数。历史记录 + TASK_LOG
- **结果**：单测 `signal_data_catalog_test` 全过；未改缠论内核/步进冻结；无需重编 DLL
- **演示**：全新功能·免对比；阶段0无图上买卖标记，不自动加载任务演示
- **注意事项**：公式引擎、撮合、账户、主图策略箭头尚未做；下一刀才是同钟 CROSS + K0 布林示范策略

---

### 2026-08-15 13:10 — 交易钟类型门禁（Clock + 契约 + K0成交）

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：把同层同钟收成编译期规则，混钟表达式直接非法；条件只在计算钟上算，成交永远在 K0
- **关键操作**：
  1. 操作数带层号和钟族；比较/穿越必须先编译成同钟对，否则非法
  2. 契约补上计算钟/展示钟；K1 收盘与布林走虚拟K样本，不拿铺平K0阶梯做穿越
  3. 历史记录写明：K1收盘对K1布林可以，K0收盘对K1布林禁止
- **结果**：单测覆盖合法/非法编译 + K1 计算钟样本与取样右端对齐
- **演示**：全新功能·免对比；仍无图上策略箭头，不自动加载演示
- **注意事项**：尚未做 CROSS 求值与撮合；未改缠论内核

---

### 2026-08-15 13:55 — CROSS 求值（只上穿/下穿，不撮合）

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：同钟计算钟样本上做穿越边沿；事件时间落到当时已知的 K0
- **关键操作**：
  1. 上穿/下穿只在相邻两根计算钟样本上判断，边沿打一次点，待在轨外不重复
  2. K1收盘对K1布林上/下轨可求值；K0收盘对K1布林直接非法、不出事件
  3. 不走铺平后的 K0 格子；截断后看不到未来样本。未做撮合/箭头
- **结果**：`cross_eval_test` + 目录单测全过
- **演示**：全新功能·免对比；无图上策略箭头，不自动加载演示
- **注意事项**：未改缠论内核；无需重编 DLL

---

### 2026-08-15 14:20 — Phase2 最小交易闭环（信号→下一根K0开盘→交易记录）

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：一次做完单仓多头闭环，不拆订单/成交/账户；不做统计和界面
- **关键操作**：
  1. 穿越信号标成买/卖；当根知道、下一根K0开盘成交；没有下一根就过期
  2. 没仓才能买、有仓才能卖；再买/空仓卖直接拒绝。K1信号仍在真实K0成交
  3. 布林不再无冻结仓现算。手续费/滑点接口先当 0
- **结果**：场景单测全过，含布林下穿再上穿合成一笔交易记录
- **演示**：全新功能·免对比；无图上箭头，不自动加载演示
- **注意事项**：未做净值/回撤/Sharpe；未改缠论内核

---

### 2026-08-15 14:22 — Phase3 回测结果引擎（净值 + 绩效）

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：在最小闭环之上一次接完逐K0净值、回测结果对象、收益/交易质量/最大回撤/连续盈亏、未平仓语义；不做界面
- **关键操作**：
  1. 每根K0记现金、持仓市值、净值、已实现/浮盈；净值=现金+持仓×收盘价
  2. 期末有仓不算闭合交易，但净值仍含浮盈；已平仓/未平仓/期末净值分开
  3. 没有亏损交易时盈亏因子记∞而不是 NaN；最大回撤只看净值曲线，不拿交易盈亏代替
- **结果**：场景单测覆盖盈/亏/连续/持仓到最后/末根无法成交/无交易/只有盈或只有亏/手续费滑点非0，以及「交易赢但中途回撤很大」
- **演示**：全新功能·免对比；无图上箭头，不自动加载演示
- **注意事项**：未做 Sharpe/做空/加仓/策略界面；未改缠论内核；无需重编 DLL

---

### 2026-08-15 14:38 — Phase4 策略回测工作台

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：把已有回测核心接到可操作工作台：选层号、跑回测、图上策买策卖、报告与图表互跳
- **关键操作**：
  1. 策略只选 K 层，收盘和布林锁死同层，选不出 K0 收盘穿 K1 布林
  2. 图上「策买/策卖」只展示这一次回测信号，不是缠论 1Ba
  3. 报告直接端净值、回撤、交易明细；点交易跳图，点图上策略点打开信号到成交链路
- **结果**：工作台单测 + 原回测单测；历史记录已写；不自动加载演示
- **演示**：全新功能·免对比；需加载股票并步进后在设置里打开「策略回测」
- **注意事项**：未改缠论内核/冻结/K0成交规则；无需重编 DLL；未做做空加仓优化

### 2026-08-15 15:20 — Phase5 通用交易条件构建器 v1

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：回测引擎已能跑，但策略还是固定布林穿越；升级成可搭积木的买卖条件树
- **关键操作**：
  1. 买卖条件可搭比较、上穿下穿、AND/OR，右边可以是同一层变量或常数；界面只建树
  2. 第一批变量只有收开高低和布林三轨；K0 和 K1 不能拼在同一条比较或同一棵树上
  3. 每条策买/策卖写出条件、触发时取值、发现在哪根 K0；默认布林穿越与旧路径发现点一致
- **结果**：条件树单测 + 工作台单测；历史记录已写；不自动加载演示
- **演示**：全新功能·免对比；加载股票并步进后在设置里打开「策略回测」，搭条件再运行
- **注意事项**：未改缠论内核/冻结/K0成交规则；无需重编 DLL；未做 MACD/RSI/买卖点/背驰/做空/加仓

### 2026-08-15 16:05 — Phase6 指标变量扩展层 v1

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：条件树能搭，但可交易变量还只有收开高低和布林；把 MACD/RSI/KDJ 和 K0 成交量接到同一套契约
- **关键操作**：
  1. MACD 的 DIF/DEA/柱、RSI、KDJ 的 K/D/J 只读图上已冻住的格子，没有仓就是不可用，不另算一套
  2. 成交量只开放 K0；条件积木按层和类别动态列出已登记变量；左侧可看变量诊断
  3. 金标核对图上格子、交易读数、计算钟样本一致；K1 MACD 上穿 DEA 并且 RSI<50 的综合策略能跑完整链路
- **结果**：`indicator_var_ext` / 目录 / 条件树 / 工作台单测全过；历史记录已写；不自动加载演示
- **演示**：全新功能·免对比；加载股票并步进后打开策略回测，选 MACD/RSI 再运行
- **注意事项**：未改缠论内核/冻结/K0成交规则；无需重编 DLL；未做 Kn 成交量/均量、买卖点、背驰、做空、加仓

### 2026-08-15 17:20 — Phase7 缠论结构事件变量层 v1

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：条件树已能选 MACD/RSI，但缠论一类/二类、分型确认、中枢确认还不能当交易事件
- **关键操作**：
  1. 一类/二类买卖点、分型确认、中枢确认按「出现一次」登记；动态段后续几根即使还挂着同一个点，也不再打新的交易信号
  2. 事件只能和同层同钟用并且/或者拼接，不能拿去比大小或上穿下穿；分型确认是连线钟，不能直接和 RSI 拼
  3. 买：K1 一类买点并且 RSI<50；卖：K1 一类卖点或者 MACD 下穿。成交仍是下一根 K0 开盘。未来才确认的点不会写进过去
- **结果**：结构事件单测 + 目录/条件树/工作台/指标变量单测全过；历史记录已写；不自动加载演示
- **演示**：全新功能·免对比；加载股票并步进后打开策略回测，选一类买点再运行
- **注意事项**：未改缠论内核/BS 计算/冻结/K0成交规则；无需重编 DLL；未做 N 类、中枢高低、背驰、节奏、做空、加仓

### 2026-08-15 22:45 — Phase8 缠论结构对象契约 + 中枢数值变量 v1

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：Phase7 已证明事件型变量；下一步把中枢做成有身份的结构对象，再投影成可交易高低，避免「到底是哪一个中枢」
- **关键操作**：
  1. 中枢按稳定身份跟踪：同一个框动态拉长仍是它自己；当时看见的高低冻住，以后扩大不改过去
  2. 第一版只开放「当前层最新一个已经确认的中枢」的高/低/中轴；未确认的不进公式；没有确认中枢是不可用不是 0
  3. K1 收盘可以低于该层中枢低、也可以上穿中枢高；K0 不能跟 K1 中枢比。买：一类买点并且收盘低于中枢低；卖：一类卖点或者收盘上穿中枢高。成交仍是下一根开盘
- **结果**：对象身份/历史冻结/切换/缺失/混钟单测 + 完整回测链路通过；历史记录已写；不自动加载演示
- **演示**：全新功能·免对比；默认股票步进后打开策略回测，选确认中枢高/低再运行
- **注意事项**：未改中枢算法/确认/冻结/Clock/K0成交规则；无需重编 DLL；未做未确认中枢、N 类、背驰、节奏、三型四型、做空、加仓

### 2026-08-15 23:30 — Phase9 背驰结构关系变量 v1

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：Phase8 已有结构对象身份；下一步把背驰从副图力度结果收成「哪一个结构对比哪一个结构、在哪根 K 形成」的可交易关系
- **关键操作**：
  1. 背驰按稳定关系编号跟踪：比较对象优先绑已有中枢，否则绑段；同一个比较对后面再拉长仍是它自己；当时力度比冻住，以后不回写
  2. 第一版只开放确认的 MACD 面积背驰：出现一次、力度比、方向。出现是事件，力度比可和数字比，方向只能等于向上或向下。没有当时可见关系是不可用不是 0
  3. 买 A：一类买点并且背驰出现；买 B：力度比小于阈值并且 RSI 偏低。成交仍是下一根开盘。K0 不能跟 K1 拼
- **结果**：对象身份/历史冻结/确认翻转/缺失/类型门禁单测 + 两组综合回测链路通过；历史记录已写；不自动加载演示
- **演示**：全新功能·免对比；默认股票步进后打开策略回测，选背驰出现/力度比/方向再运行
- **注意事项**：未改背驰算法/冻结/Clock/K0成交规则；无需重编 DLL；未做其它背驰算法、N 类、节奏、三型四型、做空、加仓

### 2026-08-16 00:50 — Phase10～15 缠论交易变量与回测基础设施收口

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：Phase8/9 已有中枢对象和背驰关系。下一阶段把 N 类事件、统一结构契约、条件树类型、求值链、规则归因、运行上下文和标准策略回归一次收口
- **关键操作**：
  1. 三类及以上买卖点用带类号的出现条件接入现有会话历史；同一身份动态后续不重复下单；未来点不进过去
  2. 中枢对象和背驰关系接到同一套结构编号；条件树编译分清类型错、混钟、不可用；每笔信号带求值链
  3. 回测结果按买卖规则做归因；运行记录引擎/策略/契约/结构四套版本。成交仍是下一根开盘
- **结果**：N 类事件/结构契约/类型门禁/标准策略回归单测；演示不自动弹出
- **演示**：全新功能·免对比；id=2026-08-16-chan-trade-complete
- **注意事项**：未改缠论内核、指标算法、BS/中枢/背驰计算、冻结和 K0 成交钟；无需重编 DLL；未做做空、加仓、多品种、参数优化、全市场选股

### 2026-08-16 23:40 — 分型确认当根脉冲；同一根先平后开

- **执行者**：cursor
- **任务类型**：Bug修复
- **上下文**：默认分笔上买卖都选分型确认时，副图 7、8 都有点，回测只打 7；要对齐金字塔 CROSS 脉冲和先平后开
- **关键操作**：
  1. 分型确认等「出现」条件按当根出信号，连着两颗不同确认都认；收盘大于均线仍假变真
  2. 同一根既买又卖时先平后开：7 空仓只开，8 先平再开；成交仍是下一根开盘
  3. 不拆顶/底确认积木
- **结果**：单测覆盖 7/8 两颗确认与同一根先平后开；历史记录已写；演示 id=2026-08-16-pyramid-event-pulse
- **演示**：默认股票 002003 分笔可验；id=2026-08-16-pyramid-event-pulse
- **注意事项**：无需重编 DLL；未做做空、加仓、当根收盘成交、顶底拆积木

### 2026-08-17 02:12 — 策买画在发现根；交易写成交时间；拖动跟着走

- **执行者**：cursor
- **任务类型**：Bug修复
- **上下文**：撮合已是第 7 根空仓只开、第 8 根开盘成交，但图上曾画出被拒的卖、交易时间和对点对不齐，拖动时三角还不跟 K 线走
- **关键操作**：
  1. 图上只画已成交的策买/策卖，画在发现当根；空仓被拒的卖不画
  2. 交易明细写成交那根的时间和 K 号，并注明信号在哪根
  3. 拖动/缩放时策略点跟着蜡烛走
- **结果**：用户确认已修好；调试埋点已拆除
- **注意事项**：无需重编 DLL



### 2026-08-18 10:14 — 策略标记买/卖2红绿；交易与信号链路表格

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：trade 分支回测 UI：策买/策卖改名改色；交易与信号链路用表格展示
- **关键操作**：
  1. 主图策略标记：策买→买（红）、策卖→卖2（绿）；集中 `strategySideLabel` / `strategySideColor`
  2. 报告「交易」「信号链路」Tab 改为可横滑表格，点行仍联动跳 K 与高亮
  3. 同步 `main.dart`、`backtest_workbench.dart`、`msg_history.dart` 说明文案
- **结果**：`flutter test test/backtest_workbench_test.dart` 全过（10 项）
- **演示**：打开策略回测 → 运行 → 主图见红「买」、绿「卖2」；报告两 Tab 为表格
- **注意事项**：纯 Flutter UI；无需重编 DLL

### 2026-08-18 18:50 — 回测成交价格：本周期收盘 / 次周期开盘

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：策略回测需在设置里选成交价；与步进「信号当根已知」对齐，默认本周期收盘价
- **关键操作**：
  1. 新增 `TradeFillPriceMode`：本周期收盘价（默认）、次周期开盘价；买/卖共用
  2. 策略表单下拉 + 说明弹窗；撮合走 `planFill`，引擎版本升至 v9
  3. 同步 `msg_history.dart`、`CHAN_RUST/TASK_LOG.md`；回归单测更新
- **结果**：`flutter test` 回测相关用例全过
- **演示**：策略回测 → 设置「成交价格」默认「本周期收盘价」→ 运行后交易明细成交K与发现K一致；改「次周期开盘价」则成交在下一根
- **注意事项**：纯 Flutter；无需重编 DLL；图上买/卖2仍在发现根

### 2026-08-19 01:38 — 策略买卖组号：买1/卖1、买2/卖2

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：策略回测要把每次闭合交易的买/卖编为一组，主图与工作台名称一致
- **关键操作**：
  1. 新增 `buildStrategyRoundIndex`：按闭合交易顺序编组，期末持仓仅买N
  2. 主图策略点显示买1/卖1、买2/卖2；报告交易表「组」列、信号链路方向/组列同步
  3. 同步工作台说明、帮助弹窗、`msg_history`
- **结果**：`flutter test test/backtest_workbench_test.dart` 全过（12 项）
- **演示**：运行回测后主图见买1/卖1；交易 Tab 第一列「买1→卖1」；信号链路方向列「买1」「卖1」
- **注意事项**：纯 Flutter；无需重编 DLL；被拒信号仍无组号

