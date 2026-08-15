# TASK_LOG

> 口径/行为变更记录（复制排查用）；与 `lib/history/msg_history.dart` 常驻历史同步维护。

## 2026-08-15 Phase7 缠论结构事件变量层 v1

- **需求**：把最成熟的缠论事件做成可交易变量：一类/二类 BS、分型确认、中枢确认。不是持续 true，是发现边沿。
- **不变**：缠论内核、BS 计算、步进冻结、K0 下一根开盘成交。不做 N 类、中枢高低、背驰、节奏、几何线、做空、加仓。
- **登记**：`STRUCTURE.K{n}.BUY1/SELL1/BUY2/SELL2`、`SUB.K{n}.FRACTAL_CONFIRM`、`SUB.K{n}.ZS_CONFIRM`。读会话历史/确认列表的**稳定身份首次 x**；动态后续 x 仍留在图上历史，不重复出交易事件。未来 x>asOf 不进过去。
- **AST**：新增 `EVENT_EXISTS`。事件只参与 AND/OR；`BUY1 > 0` / `CROSS(BUY1,X)` 编译期非法。一类买 + RSI 同 zsMath 合法；分型确认是连线钟，和 RSI AND 非法。
- **综合**：买 `K1.BUY1 AND K1.RSI<50`；卖 `K1.SELL1 OR K1.MACD DIF 下穿 DEA`。
- **验证**：`flutter test test/chan_event_var_test.dart test/signal_data_catalog_test.dart test/condition_ast_test.dart test/backtest_workbench_test.dart test/indicator_var_ext_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。引擎版本 `backtest-workbench-v4-chan-events`。

## 2026-08-15 Phase6 指标变量扩展层 v1

- **需求**：条件树能搭，但可交易变量还只有 OHLC+布林。接入现有 MACD/RSI/KDJ 冻结仓和 K0 成交量，做成统一注册通道。
- **不变**：缠论内核、步进冻结、K0 下一根开盘成交；不新写指标算法；不做空/加仓/Buy1/背驰/节奏/Demark。
- **登记**：`SUB.K{n}.MACD.DIF/DEA/HIST`、`SUB.K{n}.RSI.VALUE`、`SUB.K{n}.KDJ.K/D/J`；成交量只开放 `RAW.K0.VOLUME`（Kn 成交量仍是铺平阶梯，不进公式）。无 `VOLUME_AVG5`。
- **钟**：与布林同一套 zsMath；K0 一根一根，K1+ 虚拟K右端。混层编译期非法。
- **读数**：只读 `MathSeriesFreezeStore`；没有仓/空格=不可用，禁止现场重算。
- **UI**：条件积木按层+类别（开高低收/布林/MACD/RSI/KDJ/成交量）动态列出已登记变量；变量诊断只读目录和冻结仓。
- **验证**：`flutter test test/indicator_var_ext_test.dart test/signal_data_catalog_test.dart test/condition_ast_test.dart test/backtest_workbench_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。引擎版本 `backtest-workbench-v3-indicators`。

## 2026-08-15 Phase5 通用交易条件构建器 v1

- **需求**：策略从写死的布林穿越模板升级为可搭积木的条件 AST；界面只建树，真假仍走现有回测核心。
- **不变**：缠论内核、步进冻结、主图语义、K0 下一根开盘成交、单仓只做多；不新做指标算法/Rust 迁移/MACD/RSI/Buy1/背驰/做空/加仓。
- **AST**：比较 `> < >= <=`、`CROSS_ABOVE`/`CROSS_BELOW`、`AND`/`OR`；操作数=变量或常数；两常数非法。
- **第一批变量**：收/开/高/低 + 布林中/上/下轨。同 displayKn + 同 clockFamily 才能比较或穿越；K0×K1 编译期非法；一棵树上也不能把 K0 和 K1 AND/OR 在一起。
- **求值**：只在 evalClock 样本上算布尔，假变真出 `SignalEvent`。CROSS 仍是边沿脉冲。AND/OR 按 availableAt 对齐。
- **可解释**：每条信号带条件文案、触发时取值、发现 K0 #；链路仍是条件→Signal→Order→Fill→Trade。
- **默认策略**：仍是 K0 收下穿下轨买 / 上穿上轨卖，结果应与旧固定布林路径同一批发现点。
- **验证**：`flutter test test/condition_ast_test.dart test/backtest_workbench_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。不自动弹任务演示。引擎版本 `backtest-workbench-v2-ast`。

## 2026-08-15 交易条件变量目录阶段0（SignalDataCatalog）

- **需求**：回测先建可交易变量目录，不在 Flutter 里另判条件画箭头。阶段0只登记身份清楚、能取值的变量。
- **不变**：缠论内核、步进冻结、主图语义、布林算法、MathSeriesFreezeStore；不搬数学指标进 Rust；不做公式/撮合/账户。
- **登记**：`RAW.K0` 开高低收量；`RAW.K{n≥1}` 开高低收（与布林同一套钟：K0原生，K1+结构层 kn-1 虚拟K，含动态段）；`MAIN.K{n}.BOLL.MID/UP/DOWN`（读冻结仓，与图上布林同一份数）。
- **只盘点不进公式**：中枢高低（未写清哪一框）、一类/二类买卖点（未写边沿）、三型/四型/趋势线/节奏/背驰/MACD/RSI 等。
- **钟**：同一显示层 + 同一 `zsMath`/`line` 才能进表达式；禁止 K0 收盘穿 K1 布林。
- **三态**：没有数=不可用，不是条件不成立。布林热身仍按图上出数，不另造前 N 根空白。
- **成交约定（尚未实现）**：信号在当根发现，下一根 K0 开盘成交。
- **验证**：`flutter test test/signal_data_catalog_test.dart` 全过。
- **注意**：纯 Flutter；无需重编 DLL。阶段0无图上买卖标记，不自动弹任务演示。分支 `trade`。

## 2026-08-15 交易钟类型门禁（Clock + 契约 + K0 成交钟）

- **需求**：同层同钟才能比较/穿越，混钟在编译阶段就是非法表达式；条件只在 evalClock 上算。
- **不变**：不碰公式求值、撮合、账户、Rust 指标迁移、策略箭头、缠论内核。
- **变更**：`TradeOperand`（displayKn+clockFamily+evalClock+plotClock）；`compileBinaryOp` 产出 `TradeExprOk`/`TradeExprIllegal`；`SameClockPair` 只能由编译成功得到。`readEvalClockSeries` 给出计算钟样本（availableAt=当时能知道的 K0）。成交钟固定下一根 K0 开盘。
- **例子**：K1.CLOSE vs K1.BOLL.DOWN 合法；K0.CLOSE vs K1.BOLL.DOWN 非法。
- **验证**：`flutter test test/signal_data_catalog_test.dart`。
- **注意**：纯 Flutter；无需重编 DLL。

## 2026-08-15 CROSS 求值（仅上穿/下穿，不撮合）

- **需求**：同层同钟读双方 evalClock 样本，相邻两根判断穿越，只在边沿出一次 `SignalEvent`；`availableAt` 映射到当时已知 K0。
- **不变**：不碰撮合/订单/账户/净值/箭头；不碰 AND/OR；不拿 `lookupTradeNumeric` 铺平值做穿越。
- **合法**：K1.CLOSE vs K1.BOLL.DOWN / UP。**非法**：K0.CLOSE vs K1.BOLL.DOWN（编译期，无事件）。
- **边沿**：CROSS_ABOVE = 上一根 A≤B 且本根 A>B；CROSS_BELOW 镜像。持续在轨外不重复。
- **验证**：`flutter test test/cross_eval_test.dart` + `signal_data_catalog_test.dart` 全过。
- **注意**：纯 Flutter；无需重编 DLL。无图上标记，不自动弹演示。

## 2026-08-15 Phase2 最小交易闭环（Signal→Order→K0开盘Fill→Position→TradeRecord）

- **需求**：一次接完单仓多头闭环；不实现统计/UI。
- **成交**：`discoveryX=X` → `executeX=X+1` → 价=`K0[X+1].open`；无下一根则订单过期，禁止用末根收盘虚构。
- **仓位**：无仓才能买、有仓才能卖；再买/无仓卖显式拒绝。
- **布林**：`mathFreeze==null` 不再现算，只读冻结仓。
- **费用**：手续费/滑点接口默认 0。
- **验证**：`flutter test test/mini_loop_test.dart` + catalog/cross 全过。
- **注意**：纯 Flutter；无需重编 DLL。无箭头、不自动弹演示。

## 2026-08-15 Phase3 回测结果引擎（Equity + PnL + 核心绩效）

- **需求**：一次接完逐K0净值、回测结果对象、收益/交易质量/最大回撤/连续盈亏、未平仓语义。不做 Flutter 回测 UI。
- **净值**：每根 K0 记 cash / positionQty / positionValue / equity / realizedPnL / unrealizedPnL；`equity = cash + qty × close`。持仓计入浮盈。
- **结果**：`BacktestResult` = signals / orders / fills / trades / equityCurve / metrics；`closedTrades` 与 `openPosition` 分开。
- **收益**：`netProfit = finalEquity - initialCapital`。
- **交易质量**：胜率、毛盈亏、均盈均亏、盈亏因子、盈亏比、期望；无亏损交易 → `∞` / `不可用`，禁止 NaN。
- **回撤**：只看净值曲线；记录峰/谷/起止K/回到前高的K。TradeRecord 盈亏 ≠ 净值回撤。
- **费用**：比例手续费、固定价差滑点可非 0；默认仍 0。
- **验证**：`flutter test test/backtest_result_test.dart test/mini_loop_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。无箭头、不做 Sharpe/做空/加仓/多品种。

## 2026-08-15 Phase4 策略回测工作台

- **需求**：配置策略 → 调用现有回测核心 → 图上策略点 → 报告；Flutter 不重算条件/指标/收益。
- **配置**：第一版只选层号；买=该层收盘下穿该层布林下轨，卖=该层收盘上穿该层布林上轨。同层同钟门禁；选不出 K0收盘×K1布林。
- **运行**：`BacktestRun` 记下 strategyConfig、数据范围、engineVersion、runId。
- **图**：主图覆盖「策买/策卖」，只画 `BacktestResult.signals`，与 1Ba/1Sa 分离。
- **报告**：净利润/收益率/胜率/盈亏比/Profit Factor/最大回撤、净值与回撤曲线、交易明细、信号→订单→成交链路。点交易跳入场/再点出场；点图上策略点打开链路。
- **验证**：`flutter test test/backtest_workbench_test.dart test/backtest_result_test.dart test/mini_loop_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。未做做空/加仓/优化/新指标。

## 2026-08-15 连线斜率背驰特征键 ASCII（line_slope）

- **需求**：ML 特征键不再混入汉字「斜率」；算法本身保留（与 Kn连线斜率同源）。
- **不变**：计算公式、冻结仓、副图芯片/十字显示名仍为 `K{n}背驰_斜率`；旧 `slope`（振幅摊平）不动。
- **变更**：`DivergenceAlgo.lineSlope.key`=`line_slope`；新增 `labelSuffix`=`斜率` 给界面；`diver_line_slope_*`；ML 中文名「连线斜率」vs 旧 slope「振幅摊平」。`schema_version` 仍为 1。
- **验证**：`divergence_compute_test` catalog 显示名 + ASCII 键；`ml_feature_label_test`。
- **注意**：纯 Flutter；无需重编 DLL。旧 `feature.meta` / 旧模型须重导出并重训。

## 2026-08-14 BSP 在线对错：离开事件语义（不再只等后续中枢升降）

- **需求**：`judge_one` 不再把对错近似成「后续已定型 ZS 是否按预期升降」。BSP 出现后观察已发生结构事件，第一个明确顺向确认/反向证伪即判定冻结。强制反例：002003 1min K0 idx=12 的 `4Sa`/`1Ba` 最终都必须 Wrong。
- **不变**：`BsVerdictFrame` / `verdict_store` / `judge_level` / K0…KN 同一入口 / Pending→终态单向 / asOf / 不回写 BSP / 旧 `ml_bsp_sample.isCorrect` 隔离。
- **语义**：
  - 全类（1…n B/S）共用失败路径：后续**非本框成员**段升破本框 ZG / 跌破本框 ZD（买：升破=对、跌破=错；卖镜像）。不要求新 ZS 形成或 `is_sure`。
  - 后续已定型中枢 `zs_above_prev`/`zs_below_prev` 降为事件之一。
  - 一类/二类额外：同框严格新极值（一类破自身价；二类破当时 box 极值）。三类+仍不套极值失败（生成是全员打点）。
  - 同 x 同时命中成功/失败：成功优先（`apply_hits`）；不同 x 取最早。
- **反例**：
  - `4Sa@12`：ZS5 框 ZG=11.69；idx=17 非本框 K 高=11.70 → `leave_above_zg`，`invalid_x=17`。旧实现等 ZS6 `is_sure`（asof=18 才 Wrong，且 asOf 会把 17 提前亮错）。
  - `1Ba@12`：idx=14 同框新低 11.68 → `same_zs_new_extreme`，`invalid_x=14`（一类路径原先就能打到；回归锁死）。
- **变更**：`chan_data/src/bs_eval.rs` 的 `judge_one`；`msg_history.appendBsOnlineVerdict`。
- **验证**：`cargo test -p chan_data --lib bs_eval`（含 002003 连续 asof 与三类+无后续 ZS 反向离开）。
- **注意**：须重编并复制 `chan_ffi.dll` 后冷启；连续单步验收（一键跳末≠步进）。

## 2026-08-14 全类 BSP 在线对错（Pending/Correct/Wrong）

- **需求**：对 CHAN_RUST 当前能产生的全部 BSP（1…n B / 1…n S）建立统一在线对错；不改 BSP 生成；K0…KN 同一 judge；无未来、终态冻结；供后续 ML label；副图错标可叠加 X（设置开关）。
- **不变**：buy1/buy2/buy_n 判点规则、mark_x、会话双键冻结、旧 `ml_bsp_sample.isCorrect` 展望窗 α（隔离，不删）。
- **语义（继承既有结构，不发明止盈止损）**：
  - 全类成功/失败：后续 **已定型** 中枢 `zs_above_prev` / `zs_below_prev`（买上移成功、卖下移成功；镜像失败）。
  - 一类/二类额外失败：同框严格新极值（一类破自身价；二类破当时 box 极值，不是 2B 自身价）。
  - 三类+：代码无独立极值语义（同框全员打点），不套一类极值失败。
- **变更**：`chan_data/src/bs_eval.rs`；`LevelBundleOut.bs_verdict_frames` + `bs_verdict_k0_frames`；pipeline/combine/delta；Flutter 接收冻结 + asOf + 设置「BSP对错叠加X」。
- **验证**：`cargo test -p chan_data --lib bs_eval` 全过（全类 1..8 × 买卖 × Correct/Wrong × K0/K1/K2、冻结、无未来、不回写）。
- **注意**：须重编并复制 `chan_ffi.dll` 后冷启；连续单步验收。**同日已被「离开事件语义」修正：三类+不再只能等后续定型 ZS。**

## 2026-08-13 PresentationCache 增量 Lookup（Phase 2B-3A）

- **需求**：消除每步 `BarFeatureLookup.build` 全历史重建（N=2000 Lookup≈5.5s / 96%）；Painter 不得重复建 Lookup。
- **不变**：Rust / Delta / FFI / 算法 / History / asOf 语义 / mark_x / V2.1 BS；Full `build()` 保留黄金参考。
- **变更**：`IncrementalBarFeatureLookup` + `PresentationCache.syncLookup`；热路径 `applyStep`；三型只算当前 x；asOf 视图短前缀 Math + 冻格。KlineChart / ML 复用 `lookupEngine`。
- **验证**：`incremental_lookup_session_test` 全过（002003 step24–28 Incremental==Full、reset+replay、asOf 24–28）。N=2000 FullLookup=6259ms / Incremental=1048ms（6.0x）；Full 随 N 增 26.4x，Incremental 6.2x。报告 `docs/PHASE2B3_INCREMENTAL_LOOKUP_REPORT.md`。
- **注意**：不进 Phase 2C；冷启后连续单步验收。

## 2026-08-13 Flutter 接入 PipelineDelta（presentation cache）

- **需求**：步进走 `chan_pipeline_append_delta`；Flutter 建 presentation cache + `mergeDelta`；Full Snapshot 仅首包/回退/asOf。
- **不变**：Rust 算法、Delta 语义、Lookup 填表算法、History/asOf/V2.1 BS；不做二进制/字段级 patch/ZS-BS 优化。
- **变更**：`PipelineDelta`/`PresentationCache`；`ChanPipelineSession` 首包 Full、其后 Delta；旧 DLL 无符号则全程 Full。
- **验证**：`pipeline_delta_session_test` 全过。002003 step24–28 Full==Delta；reset+replay；asOf；History/BS/副图/十字/ML。N=200 末步 Delta≈Full 的 31%。报告 `docs/PHASE2B3_FLUTTER_DELTA_REPORT.md`。
- **注意**：须重编并复制 `chan_ffi.dll` 后冷启。

## 2026-08-13 Lookup 增量化（仅 profiling+设计，未实现）

- **需求**：消除每步 `BarFeatureLookup.build` 全量重建；不改 Rust/Delta/History/asOf/BS。
- **测量**：`phase2b3_lookup_profile_test`。N=2000 末步 Lookup≈5.5s（占 96%），mergeDelta≈0；Painter 每帧 2 次 build。Lookup 随 N 超线性。
- **设计**：`docs/PHASE2B3_LOOKUP_INCREMENTAL_DESIGN.md` 方案 A（增量 Lookup 挂 cache，只写脏区间）。**等待批准**。

## 2026-08-09 Kn节奏关窗持值（全层同构）

- **需求**：升组子顶关窗后、子底确认前继续用上个 x-x；锚点分笔·K1·K0 77–114 续 0-0；tip 同源；复制调试信息仅本批。
- **变更**：`StepRhythmState.holdLines`；关窗 `holdStepRhythmFromCache`；开窗刷新模板；父切组清缓存；探针 T1/T2 改绑持值+tip。
- **验证**：`adjacent_ratio_step_rhythm_test` 持值/切组清缓存通过。
- **注意**：冷启跳末→复制调试信息看 T1/T2。

## 2026-08-02 分笔第4列显式0保留0（副图/笔数分布全无柱）

- **需求**：离线写笔数=0 时，Kn笔数副图与左侧笔数分布应全无柱；勿显示成每根 1。
- **根因**：`parse_tick_line` 仅 `v>0` 才采纳，显式 `0` 被当成非法仍默认 1。
- **变更**：数字且 `v>=0` 原样用（含 0）；仅无列或第4列为 B/S 时默认 1；`chip_tick_count_bins` 仅 `ticks>0` 才写。
- **相关**：`tick.rs` / `chip.rs` 注释、`msg_history.appendTickCountZeroLiteral`、根 `TASK_LOG.md`。
- **注意**：须重编 `chan_ffi.dll` 后冷启；002003 等旧文件笔数列全 0 → 预期全无柱。

## 2026-08-02 K0筹码峰/笔数峰 tooltip + 左侧笔数分布

- **需求**：tooltip 仅 K0 增加筹码峰/笔数峰独立类别（动态 -/＋n）；笔数分布主图左侧同构筹码；价签在分布右侧。
- **变更**：`profile_peak_classify.dart`；Rust `chip_tick_count_bins`；`TickDistProfileCompute` + `TickDistConfig`；`ChipProfilePainter.alignLeft`；设置面板「笔数分布」。
- **口径**：-1=低价下最近峰，+n=高价上第 n 峰；框内无号。格式 `K0筹码峰-1：【价】/B：【】S：【】G：【】`。
- **注意**：须重编 DLL 后冷启；旧数据无 count bins 时回退收盘价落笔数。

## 2026-08-02 tooltip 成交量独立行 + 比例/节奏动态名

- **需求**：VOL 从 Kn OHLC 拆出为 `Kn成交量`；数值一律【】；相邻比例→比例、步进节奏→节奏；X类BS 与 比例/节奏 各成独立类别；同 K0 多节奏显示为 `K0节奏0-0` 动态行。
- **变更**：`bar_feature_lookup` 层内序=价量笔→合并/分型→中枢→极点距/截断→BS→比例/节奏；`step_rhythm_lines_*` 存多点；`chart_indicator` 标签缩短。
- **验证**：`bar_feature_lookup_test`（独立成交量/多节奏行）、`adjacent_ratio_step_rhythm_test` 标签断言。

## 2026-08-02 tooltip VOL/笔数 B/S/G + 应显尽显槽位

- **需求**：各层 VOL 分 B/S/G（G=gray）；笔数同设计；`-。-` 分类别、`===` 分层；不按指标勾选过滤；类别后接下一层时只留 `===`。
- **变更**：
  - `kn_volume_series_compute.dart`：K0/Kn 成交量与笔数 B/S/G 序列（bins 三分解 / metrics 笔数）。
  - `bar_feature_lookup.dart`：OHLCV→`VOL B/S/G`，新增 `Kn笔数`；层内 `_joinCategories`；层末不挂 star；极点距/截断/BS/比例/节奏固定槽位。
  - `kline_chart.dart`：tooltip 中枢/副图计算喂全 catalog。
  - `crosshair_tooltip_panel.dart`：类别分隔改为 `-。-` 重复。
- **口径**：无 tick 数据时量全归 G；有 bins 时按 b+s+w 占比分 volume。
- **验证**：`bar_feature_lookup_test` 覆盖 B/S/G、笔数、无勾选仍显、层前无 star。

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
