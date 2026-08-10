# 任务要点日志

## 最新记录

### 2026-08-10 — 跑通特征价值评估（002003 1m）

- **要点**：对 002003 两日 1m（465根）采 K0一类样本275、特征维416；测试准确率74.5%、经验胜率66.7%但仅采纳6条；漂移告警；结论=有弱信号但不值得整包 tip 特征当主力。
- **相关路径**：`test/ml_feature_worth_eval_test.dart`
- **注意**：复跑：`flutter test test/ml_feature_worth_eval_test.dart`

### 2026-08-10 — ML收紧：展望窗α + 测试锁定 + 漂移报告

- **要点**：α改为发现后固定展望窗内用当步live一类与asOf截断极值打标（禁跳末末态）；测试评估成功后锁定不可改比例重跑；结果页增加三截标签√率与特征漂移告警。
- **相关路径**：`ml_bsp_labeler.dart`、`ml_label_config.dart`、`ml_drift_report.dart`、`ml_workbench.dart`、`main.dart`、`docs/ML_FEATURE_SPEC.md`
- **注意**：锁定仅防同会话窥探；单票过拟合仍在

### 2026-08-10 — ML修正：训练/验证/测试时序三截 + 仅验证调参

- **要点**：按样本 x 严格前→后切训练|验证|测试；网格超参只在验证集选；锁参后测试集只评估一次；UI 默认报测试经验胜率，并展示调参摘要。
- **相关路径**：`ml_dataset_split.dart`、`ml_split_config.dart`、`ml_experience_trainer.dart`、`ml_workbench.dart`、`main.dart`、`docs/ML_FEATURE_SPEC.md`
- **注意**：禁止用测试集调参；样本不足 3 条时验证可能为空并跳过调参

### 2026-08-09 — ML当前阶段：先设切分再加载，考试集看经验胜率

- **要点**：进 ML 先设训练/考试比例，点「加载」显示进度；用训练集拟合经验应用到考试集；结果含经验胜率/基准胜率/准确率/覆盖率/买卖侧；本阶段去掉导出与外部模型加载，只基于当前股票、不展示K线。
- **相关路径**：`lib/ml/ml_experience_trainer.dart`、`ml_workbench.dart`、`main.dart`、`docs/ML_FEATURE_SPEC.md`
- **注意**：经验=内存逻辑回归；经验胜率=采纳且α=√ / 采纳数

### 2026-08-09 — ML成果页：无K线图 + 训练/考试集可设置可看

- **要点**：ML 主区不再挂 K 线；后台取数采 K0 一类 BS 后按时间序切分训练/考试（默认70/30，滑条可调并即时重切）；成果页默认考试集α准确率与样本列表，导出 train/exam libsvm + 考试报告，模型预测后显示考试准确率。
- **相关路径**：`lib/ml/ml_workbench.dart`、`ml_dataset_split.dart`、`ml_split_config.dart`、`ml_bsp_export.dart`、`main.dart`、`docs/ML_FEATURE_SPEC.md`
- **注意**：后台仍 `_loadKlines` 算特征，只是 UI 不展示图

### 2026-08-09 — K0一类BS机器学习闭环（对齐 Vespa demo5/6）

- **要点**：ML 改为事件样本：完整跳末采 K0 一类 BS 当下 tip 同源特征→α label（末态集合√/× + K0连线高低极值）→导出 libsvm/meta；Rust FFI `chan_ml_predict` 加载外部 model.json；成果页替换规则打分。
- **相关路径**：`lib/ml/ml_bsp_*`、`ml_workbench.dart`、`main.dart`、`chan_data/ml_predict.rs`、`chan_ffi`、`docs/ML_FEATURE_SPEC.md`
- **注意**：需重编并覆盖 `chan_ffi.dll` 后预测才可用；模型可用 `chan_ml_v1` 权重 JSON

### 2026-08-09 — ML 新手成果页：自动加载跳末 + tip 分类打分

- **要点**：设置选好标的后点「机器学习」即自动加载并完整跳末；成果整页展示总分/教学建议/8 类 tip 打分卡 + K 线小预览；可选导出 JSONL；图面使用权进出交接不变。
- **相关路径**：`lib/ml/ml_rule_score.dart`、`ml_workbench.dart`、`main.dart`、`docs/ML_FEATURE_SPEC.md`、`test/ml_rule_score_test.dart`
- **注意**：规则评分非训练模型；计算走 `_runToEnd` 不省略逻辑

### 2026-08-09 — ML 分支：设置入口 + 图面使用权交接 + JSONL 导出

- **要点**：新建分支 `ML`；设置「机器学习」进入后图面由 `MlWorkbench` 占用（预览只读），退出归还复盘；只读导出 `schema_version=1` JSONL 至 `ml_exports/`，不改 tip/`BarFeatureLookup` 生产逻辑。
- **相关路径**：`lib/ml/*`、`main.dart`、`msg_history.dart`、`docs/ML_FEATURE_SPEC.md`、`test/ml_feature_export_test.dart`
- **注意**：进入前需已步进；禁止 tip 动态行名作键

### 2026-08-09 — 本批验收通过（T1 K1节奏持值·T2 tip同源）

- **要点**：用户贴文确认 T1=`OK_FIXED`（分笔·K1·77–114 续上个 0-0，ok=38）、T2=`OK_FIXED`（tip【11.726】与 hist3 同源）；本批结案。
- **注意**：主图 chip 点开「Kn节奏」才绘制（默认静音）

### 2026-08-09 — 探针 T2 改按 tip 三位小数同源比对

- **要点**：T1=`OK_FIXED`；T2 误报因 hist 全精度 vs tip `toStringAsFixed(3)`。探针改为与 tip 同口径比三位小数字符串。
- **相关路径**：`audit_probe_snapshot.dart`
- **注意**：热重载/冷启后再点「复制调试信息」看 T2

### 2026-08-09 — Kn节奏关窗持值（全层同构）

- **要点**：子反向分型关窗后、下一同向分型确认前，持上个 x-x 原值逐K写入会话历史（升：顶关→底前；降镜像）；再开窗恢复实时；父切组清 holdLines。主图/tooltip 同源；「复制调试信息」改绑 T1 持值（分笔·K1·77–114 续 0-0）·T2 tip 同源。
- **相关路径**：`step_rhythm_compute.dart`、`audit_probe_snapshot.dart`、`msg_history.dart`、`main.dart`、`AGENTS.md`
- **注意**：冷启跳末→复制调试信息看 T1/T2；主图 chip 点开「Kn节奏」才绘制

### 2026-08-09 — 本批验收通过（T1 tip三类·T2 节奏主图）

- **要点**：用户贴文确认 T1=`OK_FIXED`（背驰/比例+节奏/其它序与 `-。-` 分隔、混桶=N）、T2=`OK_FIXED`（main节奏 kn=0..4、副图无残留、层全选/默认静音）；本批结案。
- **注意**：主图 chip 点开「Kn节奏」才绘制（默认静音）

### 2026-08-08 — tip三类分桶 + Kn节奏迁主图（价轴）

- **要点**：十字 tip 层内拆三类（背驰 / 比例+节奏 / 其它指标）；Kn节奏从副图干净迁主图（`MainIndicatorKind.stepRhythm`，挂节奏投影价，进 Kn指标、默认静音）；「复制调试信息」改绑本批 T1/T2。
- **相关路径**：`chart_indicator.dart`、`bar_feature_lookup.dart`、`kline_chart.dart`、`audit_probe_snapshot.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：冷启后跳末→复制调试信息看 T1/T2；主图 chip 点开节奏才绘制

### 2026-08-08 — 本批验收通过（A/D/E/F/G/H）

- **要点**：用户贴文确认 A=`OK_FIXED`（K0 bs1_hits x=2）、D tip 十一类、E Peak 已接线、F 虚线末枢、G 口径、H asOf 段数差；本批结案。
- **注意**：Peak 默认仍为 zs；UI 切 peak 需传 `zs_config.zs_combine_mode=peak`

### 2026-08-08 — A探针修：K0 bs1_hits 写入 bar_features

- **要点**：验收贴文 A=`BUG_无bs1_hits` 因会话 kn=0 而结构层 hits 无 K0。`run_pipeline` 逐K补写 K0 zs/bs1（discovery 冻结）；探针改取全层最早 x。D/E/F/G/H 已通过。
- **相关路径**：`pipeline.rs`、`audit_probe_snapshot.dart`
- **注意**：须重编 DLL 冷启后再点「复制调试信息」看 A

### 2026-08-08 — 本批：探针A/D·Peak·末枢sure·口径文案·asOf bundle

- **要点**：复制调试信息改验本批；A改会话+bar_features；D实扫 tip 最高类键（中文类名扩到二十）；Rust Peak 按 DD/GG 合并；删无 active 强制末枢 is_sure；N类每成员/1Ba锁/k1_*=structure0 落注释与历史；十字 painter 直接传 asOfBundle.levels/k0/zsK0。
- **相关路径**：`zs.rs`、`pipeline.rs`、`audit_probe_snapshot.dart`、`kline_chart.dart`、`msg_history.dart`、`chart_indicator.dart`
- **注意**：须重编 `chan_ffi.dll` 后冷启；跳末→复制调试信息看 A/D/E/F/G/H

### 2026-08-08 — build_rust.ps1 编完后自动 flutter run -d windows

- **要点**：`CHAN_RUST/scripts/build_rust.ps1` 在复制 `chan_ffi.dll` 后进入 `flutter/chan_kline` 执行 `flutter run -d windows`。
- **相关路径**：`CHAN_RUST/scripts/build_rust.ps1`
- **注意**：脚本会先杀占用中的 `chan_kline`；`flutter run` 占住该终端

### 2026-08-08 — BS x冻结 / sure中枢禁改写 / bar_features.zs·bs1 / tip类上界

- **要点**：Rust 钉死一类/二类 discovery x；`try_combine` 跳过已 `is_sure`；`bar_features` 增 `zs_hits`/`bs1_hits`；tip 三类+跟 `maxBsClass`。「复制调试信息」改绑本轮 A/B/C/D 验收。须重编 `chan_ffi.dll`。
- **相关路径**：`pipeline.rs`、`zs.rs`、`feature.rs`、`combine.rs`、`bar_crosshair_feature.dart`、`bar_feature_lookup.dart`、`audit_probe_snapshot.dart`
- **注意**：冷启后跳末→复制调试信息看判定；flutter run 占用 DLL 时先 `q` 再跑 `build_rust.ps1`

### 2026-08-08 — 审计修复例1/2/4/5（K1合并同源·asOf禁回落·三型上界·zs进lookup）

- **要点**：tip「K1合并」改与主图 `k1CombineFrames` 同源；十字 asOf 下 lookup 禁回落会话 levels；三型/四型特征上界=structureMax；lookup.sub 写入 zs_*（BS 仍会话历史）。例3本样本未漂未改 Rust。
- **相关路径**：`bar_feature_lookup.dart`、`kline_chart.dart`、`audit_probe_snapshot.dart`、`msg_history.dart`、`bar_feature_lookup_test.dart`
- **注意**：热重载后跳末→十字 idx=12 看 tip K1合并；再点「复制调试信息」应见 OK_FIXED

### 2026-08-08 — 设置增加「复制调试信息」（例1–例5审计探针）

- **要点**：设置面板常驻按钮，一键复制例1（K1合并 tip/主图层号）、例2（asOf vs 会话计数）、例3（一类BS x）、例4（三型/四型上界）、例5（bar_features 缺 zs/BS）核对文本，便于粘贴验证猜想。
- **相关路径**：`CHAN_RUST/flutter/chan_kline/lib/history/audit_probe_snapshot.dart`、`main.dart`、`msg_history.dart`
- **注意**：建议跳末后点；会多次前缀 FFI；与「复制页面快照」并存，勿当临时调试删

### 2026-08-08 — 方案B：结构层 0 起编，消除 displayKn↔level +1 双轨

- **要点**：Rust 首层 `level==0`（K0连线）；中枢/BS 帧 `level=structure+1` 避 zs_k0 撞号。Flutter 连线族 `kn==displayKn`；中枢/Math/BS 的 K1+ 取 `structure==kn-1`；`collect*ByKn` 写 `out[lv.level+1]`。已重编并覆盖 `chan_ffi.dll`。
- **相关路径**：`pipeline.rs`、`zs.rs`、`chart_indicator.dart`、`kline_chart.dart`、各 `*_compute.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：旧会话勾选 kn 语义漂移需冷启动；趋势线/节奏仍看父层 `displayKn+1`（非旧偏移尾巴）

### 2026-08-08 — 延伸线 asOf 截断 / 清 Demark 副图枚举 / 删 turnrate 背驰 / 桶宽进 Math 输入框

- **要点**：三型/四型/趋势线射线十字下截到 asOf；删除 `SubIndicatorKind.demark`；背驰去掉 turnrate_avg（12 算法）；筹码桶宽从拉条迁入「数学指标参数」输入框（最小 0.01，笔数分布共用）。
- **相关路径**：`kline_chart.dart`、`chart_indicator.dart`、`divergence_algo.dart`、`divergence_compute.dart`、`main.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：旧会话若勾过背驰_turnrate 会被 prune；桶宽仍落盘筹码配置

### 2026-08-08 — KnDemark 主图标注 + 设置三项（宽松Countdown/完美9/反向打断）

- **要点**：Demark 从副图迁主图，锚 K0 低点垂直排 S/C 与「完成买/卖」（Setup9 与 Countdown13 均算完整信号）。设置增加 Countdown 宽松/原版严（默认宽松）、完美9（默认关）、反向 Setup 打断 Countdown（默认严=打断）。
- **相关路径**：`demark_compute.dart`、`math_indicator_config.dart`、`chart_indicator.dart`、`kline_chart.dart`、`main.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：旧会话若仍勾副图 Demark 会被 prune；需在主图「Kn指标」打开 Demark（默认静音）

### 2026-08-07 — KnDemark 同柱上下排 + 买卖/类型分色

- **要点**：同 K0 多标记改为上下排列（setup 上、countdown 下）；买(dir<0)红/橙、卖(dir>0)绿/青，setup 加粗。
- **相关路径**：`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`
- **注意**：十字 tip 仍空格拼接；配色不跟层色

### 2026-08-07 — 全体背驰副图整段高亮（补 amp/成交量/RSI 等）

- **要点**：十字 asOf 下，所有 Kn背驰_* 副图均蓝/琥珀高亮比较两段整 Kn；此前仅 slope/斜率。MACD 四算法仍额外在 MACD 副图按贡献柱高亮。
- **相关路径**：`kline_chart.dart`、`divergence_algo.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：依赖 DivergenceFreezeStore.span

### 2026-08-07 — 新增 Kn背驰_斜率（与连线斜率同源）

- **要点**：13 算法；力度=`|(endVal-beginVal)/(endX-beginX)|`（冻段 endConfirmX；active 随 asOf）；取绝对值做 ratio；副图整段蓝/琥珀高亮。旧 `slope` 保留。
- **相关路径**：`divergence_algo.dart`、`adjacent_ratio_compute.dart`、`divergence_compute.dart`、`kline_chart.dart`、`msg_history.dart`
- **注意**：K0 无连线段不写斜率背驰；勿与旧 slope（振幅摊平）混淆

### 2026-08-07 — Kn背驰_slope 副图高亮比较 Kn 整段

- **要点**：十字 asOf 下，Kn背驰_slope 副图用蓝/琥珀条带高亮 in/out 两段整 Kn 区间（slope 吃几何整段，非 MACD 贡献子集）。
- **相关路径**：`kline_chart.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：依赖 DivergenceFreezeStore.span；与 MACD 类高亮配色一致

### 2026-08-07 — 背驰 MACD 四算法差异化高亮（area/peak/full_area/diff）

- **要点**：理清四算法对 MACD 柱的贡献差异后，十字 asOf 下按实际贡献柱高亮（不再整段 lo–hi 糊满）；peak 另描峰值。勾任一 MACD 类背驰自动叠同号 MACD。
- **相关路径**：`divergence_compute.dart`、`divergence_algo.dart`、`chart_indicator.dart`、`kline_chart.dart`、`msg_history.dart`、`divergence_compute_test.dart`
- **注意**：area=端点同号连续；peak/full_area=整段同向；diff=整段全非空。旧 span 缺 begin/end/dir 需重步进。

### 2026-08-07 — 背驰area学习观察：自动叠KnMACD + 十字高亮比较段

- **要点**：默认背驰率 1.0（旧 1e9 加载时迁移）；勾选 Kn背驰_area 自动并入同号 MACD 并取消静音；十字 asOf 下 MACD 副图蓝/琥珀条带高亮 in/out 两段。观察向，可删。
- **相关路径**：`divergence_compute.dart`、`divergence_freeze_store.dart`、`chart_indicator.dart`、`kline_chart.dart`、`math_indicator_settings_store.dart`、`msg_history.dart`
- **注意**：高亮依赖步进冻结的 span；一键跳末/连续单步后十字才有区间；冷启重载配置后背驰率应为 1.0

### 2026-08-06 — Kn背驰 v6：包中用上/上上，突破用本/上

- **要点**：相对最新动态中枢，动态Kn完全落在 ZG/ZD 内则比较上枢末与上上枢末；破上沿或下沿才用本枢末 vs 上枢末。启动仍靠中枢判断会话。
- **相关路径**：`divergence_compute.dart`、`msg_history.dart`、`divergence_compute_test.dart`、`AGENTS.md`
- **注意**：验收默认分笔 K0=90 应为 21vs23；K0=104 破枢后应为 23vs26

### 2026-08-06 — Kn背驰 v5：本枢末Kn vs 上枢末Kn

- **要点**：背驰改由中枢判断±1 启动本枢；比较上枢末 Kn 与本枢末 Kn（`end_idx`，含动态 active）；K0 颗粒度只写当前步格；重叠合并当步重映射本枢，旧格冻结不回写；废除破 ZG/ZD 门槛。
- **相关路径**：`zs.rs`、`zs_frame.dart`、`divergence_compute.dart`、`divergence_freeze_store.dart`、`main.dart`、`msg_history.dart`、`divergence_compute_test.dart`
- **注意**：须重编 `chan_ffi.dll` 后冷启；验收连续单步（非一键跳末）

### 2026-08-06 — 中枢判断/确认：未确认共点 + 经验落盘（提交）

- **要点**：对象=尚未确认中枢（非新芽）；离开窗打上个 + 确认当步对刚定型框同拍打判断。K0 无动态Kn → 副图判断/确认同 x/x1 重叠（预期）；全层同一 merge。经验写入 `zs_signal_compute` 头注释、`AGENTS`、`msg_history` v11。
- **相关路径**：`zs_signal_compute.dart`、`main.dart`、`kline_chart.dart`、`zs_signal_compute_test.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：踩坑——勿 first.dir 配色；勿同拍打新芽（idx=7 异框）；勿套分型「新芽首次可判」破坏 K0 重叠；确认同拍须补判断否则 K0 判断易全 0

### 2026-08-06 — K0中枢判断/确认同拍共点重叠（全层同构）

- **要点**：对象=未确认中枢非新芽；去掉单开放首次可判；离开窗打上个 + 确认当步对刚定型框同拍打判断。K0 无动态Kn → 判断与确认同 x/x1 副图重叠（预期）；Kn≥1 同一规则可多步离开。
- **相关路径**：`zs_signal_compute.dart`、`main.dart`、`zs_signal_compute_test.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：验收 K0 连续单步：确认点处判断应同亮同色同框，不得打新芽

### 2026-08-06 — 记录口径：判断/确认对象=未确认结构（非新芽）

- **要点**：Kn分型判断/确认与 Kn中枢判断/确认，一律是对「尚未确认」的分型或中枢；不是对新芽、新分型、新中枢。已写入 AGENTS 常驻条、`msg_history` v10、中枢 merge 注释。
- **相关路径**：`AGENTS.md`、`msg_history.dart`、`main.dart`、`zs_signal_compute.dart`、`TASK_LOG.md`

### 2026-08-06 — 中枢确认当步抑制新种子首次判断（消同拍异框）

- **要点**：同拍常见「确认刚定型上个框 + 判断新芽」异 x1（例 K0 idx=7：确认 x1=6、判断 x1=-1 新芽）。先确认后判断；本步有新确认则 `suppressNewSeedFirstHit`，新芽延后到下一步首次可判；离开窗对上个框仍可打。全层同构。
- **相关路径**：`zs_signal_compute.dart`、`main.dart`、`zs_signal_compute_test.dart`、`msg_history.dart`
- **注意**：验收连续单步看 idx=7：应只亮确认、判断不与确认异框同亮

### 2026-08-06 — 中枢判断恢复首次可判+离开窗对上个框（全层同构）

- **要点**：收回「新种子不当步」；对齐分型——单开放首次可判打点；离开窗/动态离开对尚未确认上个框逐K打点；K0/Kn 同一规则无层特例。空间升降色不变。
- **相关路径**：`zs_signal_compute.dart`、`zs_signal_compute_test.dart`、`msg_history.dart`
- **注意**：K0 上确认与新种子首次判断仍可能同拍（同构代价）；非「K0 必须全 0」

### 2026-08-06 — 中枢判断：只打未确认上个框，新种子不当步

- **要点**：判断仅离开窗（≥2 不确定）对尚未确认的上个虚框打点；单开放/确认同拍新种子不打，消确认+判断同 x。K0 段密、离开常同拍定型 → K0中枢判断可长期全 0（可接受）；K0分型判断仍会在成立当步非零。
- **相关路径**：`zs_signal_compute.dart`、`zs_signal_compute_test.dart`、`msg_history.dart`

### 2026-08-06 — Kn中枢确认/判断：空间升降色 + 默认静音绘制（提交）

- **要点**：①中枢确认/判断对「上个中枢」：相对前一枢中轴抬高红、下移绿（禁 first.dir）；②`中枢确定`→`中枢确认`；③层全选关联全集但默认只画主图四类+副图五类，其余 muted；④RSI/KDJ/成交量越界保护；⑤背驰全层同构冻结仓等同批落地。
- **相关路径**：`zs_signal_compute.dart`、`zs_signal_event.dart`、`chart_indicator.dart`、`kline_chart.dart`、`divergence_*`、`msg_history.dart`、`AGENTS.md`、`TASK_LOG.md`
- **注意**：验收连续单步对照 77/84/85/90/91；Cursor 内嵌 localhost 预览须在 Tools&MCP 关「Show Localhost Links in Browser」

### 2026-08-06 — 中枢确认/判断改空间升降色（抬高红下移绿）

- **要点**：确认/判断色不再用框 `first.dir`，改为上个中枢相对前一枢中轴抬高=红、下移=绿（实证 77/84 判断红、85 确认红、90 判断绿、91 确认绿）；并加 `cursor.browser.autoOpenLocalhostUrls=false` 试图禁 Cursor 内嵌打开 localhost。
- **相关路径**：`zs_signal_compute.dart`、`fractal_confirm_paint.dart`、`msg_history.dart`、用户/`\.vscode` settings
- **注意**：若仍弹内嵌预览，到 Settings → Tools & MCP 关闭「Show Localhost Links in Browser」

### 2026-08-06 — 中枢判断跟「上个中枢」同色 + 禁自动开 DevTools

- **要点**：判断离开窗值/色改跟被离开旧框 dir（与确认统一：升红降绿；例 52/57 红、85 确认红、90 判断绿）；`dart.openDevTools=never`，并关闭 `cursor.terminal.usePreviewBox`，避免终端 DevTools 链接默认开网页。
- **相关路径**：`zs_signal_compute.dart`、`fractal_confirm_paint.dart`、`msg_history.dart`、`.vscode/settings.json`、用户 `settings.json`
- **注意**：打点身份仍用离开候选 x1；热重载后连续单步复验

### 2026-08-06 — 中枢确认配色口径（上个中枢方向）

- **要点**：锁定确认色语义——绿=上个下降中枢被确认，红=上个上升中枢被确认（跟确认框自身 dir；例 K0 idx=54 绿、85 红）；非价格涨跌、非新虚框/分型符号。
- **相关路径**：`fractal_confirm_paint.dart`、`zs_signal_compute.dart`、`msg_history.dart`

### 2026-08-06 — 中枢确认改名 + 默认绘制静音 + RSI/KDJ 越界

- **要点**：`Kn中枢确定`→`Kn中枢确认`（确认/判断同升红降绿）；层全选仍关联全集，默认只绘制主图 Kn/合并/中枢/连线与副图分型确认/判断/截断/中枢确认/判断，其余删除线静音；RSI/KDJ/成交量副图对冻结仓长度做边界保护。
- **相关路径**：`chart_indicator.dart`、`kline_chart.dart`、`msg_history.dart`、`zs_signal_compute_test.dart`
- **注意**：新层全选新增的非核心项同样默认静音；单击 chip 可打开绘制

### 2026-08-06 — 中枢红绿配色 + 十字交互与 MACD 越界修复

- **要点**：中枢判断/确定升红降绿；MACD 副图对冻结仓长度做边界保护；左右键吞系统 repeat 防双步进；上下键滚 tooltip；中键切换 tooltip（不关十字）；chip ※ 按层级排序。
- **相关路径**：`fractal_confirm_paint.dart`、`kline_chart.dart`、`zs_signal_compute.dart`、`indicator_picker_chip.dart`
- **注意**：已移除中枢调试埋点

### 2026-08-06 — Kn中枢判断对齐分型稀疏度

- **要点**：单开放枢只首次打点；≥2 不确定（离开窗）才逐步追加末候选；重叠合回归零。确定仍 `isSure` 首次冻结。日志证实旧口径对单开放逐步刷点过密。
- **相关路径**：`zs_signal_compute.dart`、`zs_signal_compute_test.dart`、`msg_history.dart`、`chart_indicator.dart`
- **注意**：验收连续单步对照 52–85；埋点暂留待复验

### 2026-08-05 — Kn中枢判断/确定副图（对齐分型）

- **要点**：新增副图「Kn中枢判断」「Kn中枢确定」全层同构；会话冻结打点（稳定键层|x1，开放枢可逐K追加；确定首次 is_sure 冻结）；catalog/层全选/绘制/十字 asOf 齐套。
- **相关路径**：`zs_signal_compute.dart`、`chart_indicator.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：验收须连续单步；值=dir 符号；勿用 seq 作稳定键

### 2026-08-04 — Kn背驰全层同构：本层力度+冻结仓

- **要点**：背驰力度改跟 `displayKn`（优先读 Math 仓）；新增 `DivergenceFreezeStore` 格点冻结，动态离开段只追加不挪旧点；副图/十字读仓+asOf 截断。BSP 不动。
- **相关路径**：`divergence_compute.dart`、`divergence_freeze_store.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：验收须连续单步；默认仍不勾背驰

### 2026-08-04 — 背驰12算法进「Kn指标」层全选

- **要点**：`subIndicatorsForLevel` 纳入全部背驰算法；启动默认仍不勾（`defaultSubIndicatorsK0` 过滤）。修正「默认不勾≠不进层全选」口径。
- **相关路径**：`chart_indicator.dart`、`AGENTS.md`、`msg_history.dart`、`math_classic_compute_test.dart`

### 2026-08-04 — Demark迁副图 + Math十字asOf + Kn绑定补齐

- **要点**：Demark 从主图迁副图并进「Kn指标」层全选；均线/通道/布林 `_paintPriceSeries` 十字 asOf 右侧不画；副图 chip/crosshairSubRows 接 Demark；坑点写入 `AGENTS.md` 常驻节。
- **相关路径**：`chart_indicator.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`AGENTS.md`、`math_classic_compute_test.dart`

### 2026-08-04 — 清理 Math 当下冻结调试埋点

- **要点**：用户确认修复后移除 `math_series_freeze_store` 文件埋点；审计 dump 测试改为正规回归 `math_series_freeze_store_test.dart`。
- **相关路径**：`math_series_freeze_store.dart`、`math_series_freeze_store_test.dart`

### 2026-08-03 — Kn Math/均线/通道/Demark 当下冻结

- **要点**：审计确认 K1 上 MACD/BOLL/RSI/KDJ/Demark内容/均线/通道会步进回写；成交量与背驰本样本不回写。新增 `MathSeriesFreezeStore` 会话格点冻结，主图/副图/十字读仓。
- **相关路径**：`math_series_freeze_store.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`dump_indicator_rewrite_audit.dart`
- **注意**：参数变更清空并 0..当前步重冻；冻结 instrumentation 暂留待 UI 验收。

### 2026-08-03 — Kn背驰迁副图并修变量清空

- **要点**：背驰 12 项从主图迁到副图「背驰」类（算法分子标题×层分层）；副图画 ratio 折线+diver 柱；修复 diver=0 时 in/out/ratio 仍 hold 旧值；过滤非有限 ratio。
- **相关路径**：`chart_indicator.dart`、`sub_indicator_picker.dart`、`kline_chart.dart`、`divergence_compute.dart`、`kn_ohlc_sample_compute.dart`、`bar_feature_lookup.dart`、`msg_history.dart`
- **注意**：默认不勾、不进副图层全选；特征键不变。

### 2026-08-03 — Kn背驰 12 算法分项输出

- **要点**：先提交 Math/趋势线等改动；再实现 K{n}背驰_{algo}（12 种力度分项），输出 in/out/ratio 与 diver∈{1,-1,0}；非买卖点；默认不勾。
- **相关路径**：`divergence_compute.dart`、`divergence_algo.dart`、`chart_indicator.dart`、`bar_feature_lookup.dart`、`kline_chart.dart`、`math_indicator_config.dart`、`msg_history.dart`、`divergence_compute_test.dart`
- **注意**：K0 进出段=分钟K段 idx；力度用 K0 MACD/RSI；turnrate 缺字段 diver=0；`divergenceRate>100` 保送。

### 2026-08-03 — Kn MACD/BOLL/RSI/KDJ/Demark 接线

- **要点**：主图 K{n}布林/Demark、副图 K{n}MACD/RSI/KDJ 全层同构接线完成；`MathIndicatorConfig` 统一参数落盘；十字 tooltip 增 MACD/布林/RSI/KDJ/Demark 槽位；修复 catalog 标签插值编译错误。
- **关键路径**：`kline_chart.dart`、`bar_feature_lookup.dart`、`main.dart`、`msg_history.dart`、`math_classic_compute_test.dart`、`chart_indicator.dart`
- **注意**：动态 Kn=unitBars+active OHLC；asOf 截断；设置面板「数学指标参数」兼容旧 `.chan_trend_model_config.json`。

### 2026-08-03 — 主图 Kn均线 / Kn通道（TrendModel）

- **要点**：移植旧 `Math/TrendModel.py` 为「K{n}均线」(MEAN)与「K{n}通道」(MAX/MIN)；kn 同中枢；K0=bars.close、Kn=unitBars.close；周期可配并落盘；tip/层全选/默认 K0。
- **相关路径**：`trend_model_compute.dart`、`trend_model_config.dart`、`chart_indicator.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`main.dart`、`msg_history.dart`
- **注意**：与 Kn趋势线无关；设置面板改周期；热重启加载。

### 2026-08-03 — 主图 Kn趋势线（段内支撑/压力）

- **要点**：移植旧 `Math/TrendLine.py` 为延伸类主图指标「K{n}趋势线」；子线层同号（子=level n+1、父=level n+2，K0≈旧工程）；呈现/tip 对齐三型四型（最新/近邻窗、延长线落点价撑/压）。
- **相关路径**：`trend_line_compute.dart`、`chart_indicator.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`trend_line_compute_test.dart`
- **注意**：依赖父层；最高层不作显示名；maxKn<2 目录挂 K0 占位（计算空）；纯 Flutter。

### 2026-08-02 — 清理三型/四型调试埋点

- **要点**：移除 `kline_chart` / `bar_feature_lookup` 中 debug-5fbfa5 文件埋点及仅用于埋点的 `dart:io`/`dart:convert` 引用。
- **相关路径**：`kline_chart.dart`、`bar_feature_lookup.dart`

### 2026-08-02 — tip 三型/四型改为延长线落点价

- **要点**：tooltip「Kn三型平移线/四型对线」改为延长线落到该根 K0 的价格（y0+slope·Δx）；四型分顶/底价。
- **相关路径**：`fx_extend_line_compute.dart`、`bar_feature_lookup.dart`、`msg_history.dart`
- **注意**：与主图近邻窗筛选同口径；非斜率。

### 2026-08-02 — 三型/四型：最新/十字近邻 + tip

- **要点**：无十字只画最新窗；开十字画焦点近邻窗；tooltip 增「Kn三型平移线」「Kn四型对线」斜率读数，与主图筛选同口径。
- **相关路径**：`fx_extend_line_compute.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`
- **注意**：tip 按柱 asOf 取近邻窗，非勾选门控。

### 2026-08-02 — 三型/四型改为滑动窗多组（K0步进）

- **要点**：修复「只出一组」：确认序滑动窗（三型窗3、四型窗4）每窗合格即画一组，随步进累积；asOf 用 confirms 前缀。
- **相关路径**：`fx_extend_line_compute.dart`、`kline_chart.dart`、`fx_extend_line_compute_test.dart`、`msg_history.dart`
- **注意**：勿再只取全图最早前 N。

### 2026-08-02 — 主图 Kn三型平移线 / Kn四型对线（v1）

- **要点**：新增主图延伸指标「K{n}三型平移线」「K{n}四型对线」；确认分型前 N 锚点；三型两同斜率过异型向右，四型两顶+两底弦线向右；十字 asOf 禁末态；层全选/默认 K0。纯 Flutter。
- **相关路径**：`fx_extend_line_compute.dart`、`chart_indicator.dart`、`kline_chart.dart`、`fx_extend_line_compute_test.dart`、`msg_history.dart`、`main.dart`
- **注意**：前 N 按确认序冻结；延伸画到视口右缘；验收连续单步。

### 2026-08-02 — 副图 Kn连线斜率（全层同构）

- **要点**：新增副图「K{n}连线斜率」；复用比例出现链末根算 slope=dP/dX；K0 颗粒度会话冻结；折线+0轴；tip/层全选/默认K0与比例同口径。纯 Flutter。
- **相关路径**：`line_slope_compute.dart`、`chart_indicator.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`line_slope_compute_test.dart`、`msg_history.dart`
- **注意**：虚线延伸步 slope 随终点变；验收连续单步，非一键跳末。

### 2026-08-02 — Tooltip 四准则全修（1B+2A）

- **要点**：十字 asOf 时中枢/levels 禁回落末态；K0合并改用 Rust `asOfBundle.frames`；标签改为「Kn上一中枢确认」（算法不变）；BS 删 levels 末态兜底。量能双轨与动态峰/节奏仅文档化。
- **相关路径**：`zs_compute.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`zs_compute_test.dart`、`msg_history.dart`、`main.dart`
- **注意**：asOf bundle 失败→空结构；ML 用 feat/history 固定键，勿解析 tip 动态行。

### 2026-08-02 — K0分型确认/极点距/截断语义统一

- **要点**：显示名 K0分型确认/极点距/截断一律读 `k0_confirm` + `barFeatures.fractalPeakDist`；副图/tooltip 不再优先 `LevelBundle(level==1)`。`level==1.confirms` 与 k0 同源（输入=原始K），units 才是 K1——双轨易误判为「读 K1」。
- **相关路径**：`bar_feature_lookup.dart`、`kline_chart.dart`、`msg_history.dart`、`bar_feature_lookup_test.dart`
- **注意**：勿再写「K0分型确认=K1端点」；kn==1→k0/feat，kn≥2→level_confirms。

### 2026-08-02 — 分笔第4列显式0保留0（副图/笔数分布全无柱）

- **要点**：`parse_tick_line` 对显式笔数 `0` 不再默认成 1；仅无列或第4列为 B/S 时按 1 笔。002003 等笔数列全 0 时，Kn笔数副图与左侧笔数分布应全无柱。
- **相关路径**：`chan_data/src/{tick,chip}.rs`、`msg_history.dart`、`main.dart`、`kn_volume_series_compute.dart`、`tick_dist_profile_compute.dart`、`CHAN_RUST/TASK_LOG.md`
- **注意**：须重编 `chan_ffi.dll` 后冷启；metrics 键存在即用（含 0），勿回退成 bins 长度/1。

### 2026-08-02 — K0筹码峰/笔数峰 tooltip + 左侧笔数分布

- **要点**：tooltip 仅 K0 增加筹码峰/笔数峰（动态 -/＋n）；主图左侧笔数分布同构筹码（`chip_tick_count_bins`）；价签在分布右侧；设置面板「笔数分布」。
- **相关路径**：`profile_peak_classify.dart`、`tick_dist_*`、`chip.rs`、`kline_chip.dart`、`kline_chart.dart`、`chip_settings_store.dart`、`msg_history.dart`
- **注意**：须重编 DLL；无 count bins 时回退收盘价落笔数。

### 2026-08-02 — tooltip 成交量独立行 + 比例/节奏动态名

- **要点**：VOL 从 Kn OHLC 拆为 `Kn成交量`；相邻比例→比例、步进节奏→节奏；X类BS 与比例/节奏独立类别；多节奏动态行如 `K0节奏0-0`。
- **相关路径**：`bar_feature_lookup.dart`、`chart_indicator.dart`、相关 test、`msg_history.dart`

### 2026-08-01 — Kn笔数：Rust 分笔第4列真实笔数（方案B）

- **要点**：修复 688687/20240102 上 Kn笔数副图变量恒 0（根因①查表缺 tickCount 分支→读数恒 0；根因② bins 数组长度≠笔数，tick 恒 3/日线=3×价位数）。Rust `parse_tick_line` 解析第 4 列笔数（无列/非数字按 1 笔；显式 0 见 2026-08-02 条），`TickRow` 增 `ticks` 字段；chip.rs 三路径（tick/Day3/普通桶）写 `tick_count`/`buy_tick_count`（B）/`sell_tick_count`（S），灰度 w 仅进总数，非法行（价/量）不计。Flutter K0 笔数优先读 `metrics.tick_count`/`buy_tick_count`（键存在即用、可为 0），旧数据回退 bins 长度再回退 tick_side；`BarFeatureLookup` 写 `tick_count_${kn}`/`buy_tick_count_${kn}` 系列，`crosshairSubRows` 增 tickCount 分支 → 副图读数/十字 tooltip 出真实笔数。
- **相关路径**：`chan_data/src/{tick,chip}.rs`、`chan_kline/lib/{compute/kn_volume_series_compute,models/bar_feature_lookup,main,history/msg_history}.dart`、`TASK_LOG.md`
- **踩坑/经验**：
  1. bins 三数组每价位恒各 push 1（缺方向补 0.0）——长度只能当「价位数」，不能当笔数。
  2. 笔数 metrics 判断须用「键存在」，不用「值>0」（灰度行 buy=0 合法；显式总笔数 0 亦合法）。
  3. 老格式行 `HH:MM 价格 量 B`（第4列即方向）parse_float 失败→默认 1 笔；显式写 `0` 不得默认成 1。
- **验收**：关占用重载 `chan_ffi.dll` → 冷启动 → 688687/20240102 tick 周期副图「K0笔数」读数=分笔第4列（如 10），日线=当日笔数求和（非 3×价位数）；十字 tooltip 副图行含笔数。
- **注意**：`chan_ffi.dll` 已重建替换（15:36）；进程 15296 已结束待冷启。

### 2026-08-01 — 筹码角标：十字悬停高亮单根 B/S/灰

- **要点**：`_drawCornerSums` 累计行（B/S/灰度）下，十字悬停时追加「当前」行——按该根 `chip_tick_bins` 求和分色（B 红/S 绿/灰），与累计区分。chip 层 `shouldRepaint` 已含 `segAsOf`（=bars[crosshairBarIdx].idx），十字移动即重画。纯 Dart 改动，无 DLL。
- **相关路径**：`chan_kline/lib/widgets/{kline_chip,kline_chart}.dart`、`history/msg_history.dart`

### 2026-08-01 — K0 逐笔：合成秒 + 成交量三分色 + 筹码灰度 w + 角标

- **要点**：X 轴真正走到秒（同分钟 n 笔均分 `base+k*60000/n ms`，替换无效的 +i ms 全卡 :00）；`normalize_native` 不再把无 BS 改 B（`has_bs=false` 保留）。筹码三分量：S→s 绿、B→b 红、无 BS→w 灰（w 不再= s+b 合计，`total=s+b+w`，`ChipProfile`/前缀索引/Isolate wire 全链路带 w）。K0 tick 成交量按 `metrics.tick_side` 着色（B红/S绿/灰），聚合周期与 Kn≥1 仍涨红跌绿。筹码柱右对齐三段（右B/中S/左灰），右上角 `B:xx, S:xx, 灰度:xx` 角标（十字 as-of/步进末根共用 profile）。X 轴与十字时间 `secondLike` 到秒。
- **相关路径**：`chan_data/src/{tick,chip,offline}.rs`、`chan_kline/lib/{compute/chip_profile_compute,widgets/kline_chart,widgets/kline_chip,models/chip_config,history/msg_history}.dart`、`test/chip_profile_test.dart`
- **踩坑/经验**：
  1. Rust 测试 `chip_profile_cutoff_freezes_history`：同价位两 bar 同桶累加，p1 total=110 而非 100。
  2. Dart 前缀索引 `_cacheKey` 只含首末 bar 时间/idx：单测两用例同构 bar 会缓存命中串结果，测试须用不同 timeMs。
  3. `_tooltipRowsForBar` 在 `_KlineChartState` 内，period 须 `widget.period`；painter 内才是字段。
- **验收**：冷启分笔周期——同分钟秒位递进；09:25 无 BS 量灰/B红/S绿；筹码含灰段+角标随步进与十字变化；1m 量恢复涨跌色。
- **注意**：关占用重载 `chan_ffi.dll` → 冷启动 → 连续单步验收（一键跳末≠验收）。

### 2026-07-31 — 标题条 RIGHT OVERFLOW 修复

- **要点**：固定开孔 `屏宽-140` + 窗控实测约 174px 导致溢出 34px。改为 `Expanded(IgnorePointer)` 穿透指标点击，窗控前窄条拖窗。
- **相关路径**：`chan_kline/lib/main.dart` `_buildCaptionBar`

### 2026-07-31 — 指标开孔 + tick 真实筹码 + 默认分笔 K0

- **要点**：默认 `period=tick` 一字线画点；同分钟 `+i ms` 不撞戳；聚合周期仍 ticks→1m 并扩展多周期。标题条左开孔改为屏宽-140（修右侧指标单击被拖动区挡住）。tick 筹码按分笔序写 bins、禁三角。
- **相关路径**：`chan_data/{kline,tick,offline,chip}.rs`、`main.dart`、`kline_chart.dart`、`chip_profile_compute.dart`、`msg_history.dart`
- **注意**：冷启；native `chan_ffi.dll` 若占用需关进程后再 `build_rust.ps1`；长区间建议收窄日期。

### 2026-07-31 — UI配色/指标归属/读数一轮总览（rate→tick）

- **要点**：本轮在 `rate` 落地：主图层色同层同色；Kn中枢命名与层序；筹码迁主图；副图比例/节奏进 Kn指标；分型/截断顶蓝底红；中枢斜线加深；副图读数跟 chip；筹码开时 Y 轴改左。无残留 NDJSON 调试埋点（层色埋点已拆）。随后 commit+push，切新分支 `tick`。
- **关键路径**：`chart_indicator.dart`、`chart_level_line_style.dart`、`kline_chart.dart`、`fractal_confirm_paint.dart`、`indicator_picker_chip.dart`、`msg_history.dart`、相关 picker/单测
- **踩坑/经验**：
  1. **中枢不是 Normal/OverSeg 双轨**：主图只画 `forZS`；`forZSOverSeg` 是死代码，勿当两套逻辑（已删）。
  2. **「去掉中枢二字」实为去掉「连续」**：展示名 `Kn连续中枢`→`Kn中枢`，与层内序「Kn中枢」一致。
  3. **层内序靠 catalog 交错 + kindOrderInLevel**：chip/层全选/选择栏分隔按 `displayLevel`，勿再按 kind 切 divider。
  4. **相邻比例/节奏进 Kn指标**：须同时进 `subIndicatorsForLevel`、默认全选、且 catalog 按层交错；只改默认不够。
  5. **筹码是主图指标**：绘制仍在右侧 pane；勾选看 `MainIndicatorKind.chip`，设置文案勿再写「副图勾选」。
  6. **副图读数跟 chip**：`IndicatorChipEntry.valueText`；取消 `_drawSubCrosshairReadout`；`msg_history` 相邻字符串拼接勿多写逗号（否则 `append` 两参编译挂）。
  7. **验收**：热重启/冷启；层全选与目视配色/填充；一键跳末≠步进验收（本轮多为 UI）。

### 2026-07-31 — 中枢填充加深 + 副图读数跟 chip

- **要点**：Kn中枢斜线/底色加深便于与合并框区分；副图变量值显示在已选指标名后方（青字），取消右上独立读数框。
- **关键路径**：`kline_chart.dart`、`indicator_picker_chip.dart`、`msg_history.dart`

### 2026-07-31 — 筹码迁主图 + 相邻比例/节奏进副图 Kn指标

- **要点**：Kn筹码分布改主图指标并进「Kn指标」层全选（层内序末项）；副图 Kn相邻比例/步进节奏纳入「Kn指标」层全选与默认 K0 全选；副图 catalog 按显示层交错。
- **关键路径**：`chart_indicator.dart`、`kline_chart.dart`、`main.dart`、`sub_indicator_picker.dart`、`msg_history.dart`、相关单测

### 2026-07-31 — Kn中枢命名/层序 + 副图顶底色 + 中枢斜线填充

- **要点**：展示名「Kn连续中枢」→「Kn中枢」；同层序 Kn→合并→中枢→连线；中枢框斜线填充区分合并；副图分型确认/判断与截断：底/向下截断红、顶蓝（全层同构，注释已写清自定义口径）。
- **关键路径**：`chart_indicator.dart`、`kline_chart.dart`、`fractal_confirm_paint.dart`、`zs_compute.dart`、`main_indicator_picker.dart`、`msg_history.dart`

### 2026-07-31 — 筹码开启时 Y 轴价签改左侧 + 拆除层色调试埋点

- **要点**：勾选筹码分布后，主图 Y 轴刻度与十字价格标签移到左侧（避让右侧筹码）；拆除 `chart_level_line_style` NDJSON 调试埋点。
- **关键路径**：`kline_chart.dart`、`chart_level_line_style.dart`、`msg_history.dart`

### 2026-07-31 — 主图层色同层同色 + 删 OverSeg 遗留配色

- **要点**：主图 Kn合并/连线/连续中枢（含构建中虚线、种子框）按展示层共用一色：K0蓝、K1黄、K2粉、K3+自定；Kn蜡烛仍红绿。删除未使用的 `forZSOverSeg`/`_zsOverSegColors`（此前误导为双套中枢逻辑）。
- **关键路径**：`chart_level_line_style.dart`、`kline_chart.dart`、`msg_history.dart`、`main.dart`、`app_debug_snapshot.dart`、`test/chart_level_line_style_test.dart`

### 2026-07-31 — Kn相邻比例 + Kn步进节奏：总览、踩坑与经验（rate）

- **要点**：关闭 `_chipOnlyMode`；落地全层同构副图「Kn相邻比例」「Kn步进节奏」（仅副图 normal，主图水平节奏线未做）。比例按主图连线出现链（虚实不论、`beginX` 序、末两根比值、K0 颗粒度）。节奏按父分型切组（0-0 起算）、子分型开/关窗、组锚=父极值；绘制点线/左侧名/同父级同色/升暖降冷。
- **关键路径**：`adjacent_ratio_compute.dart`、`step_rhythm_compute.dart`、`main.dart`、`chart_indicator.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`level_models.dart`、`test/adjacent_ratio_step_rhythm_test.dart`；顺手删 `combine_frames_to_segments` dead_code
- **踩坑/经验（以后必读）**：
  1. **显示层↔数据层**：`displayKn` 的 Kn连线 = `LevelBundle.level==displayKn+1`；节奏子分型=`level+1` confirms，父分型=`level+2` confirms——勿把「父段 end_confirm」当成「父分型确认」。
  2. **虚实一视同仁**：idx=26 时 L2 可无冻段，但主图已有展示轨虚线/种子；只读 `segments` 会读成 0。子线必须与主图同源（冻段+`computeDisplayBuildingLines`+种子）。
  3. **出现序≠确认序**：按 `endConfirmX` 排序会把「后确认的长冻段」错当成当前线；应按起点极点 `beginX`（连线出现时机）。
  4. **节奏命名**：旧 skill 从 `1-0` 起；本轮改为 **`0-0`**（`roundCurrent=(evenIdx/2)-1`，`roundRef` 从 0）。
  5. **单点不连后**：子反向分型确认当步关窗（如 25 出点、26 顶确认→26–38 无产出）；副图同 key 仅 `Δx==1` 点线续连，禁止跨缺口自动连。
  6. **切组锚点**：父顶→降组 `a0=fractalHigh`；父底→升组 `a0=fractalLow`；key 含 `groupId` 防跨组串线。同棒先 bootstrap→子窗→父切组（父优先开新组）。
  7. **验收**：002003 `1m` 连续单步看 K0节奏 @25/@26/@39；一键跳末≠步进验收。指标默认不勾选。
  8. **调试后必删**：临时 dump 测试与 NDJSON 埋点；`lib/history/` 与历史记录按钮常驻勿删。

### 2026-07-31 — 去掉未用 combine_frames_to_segments

- **要点**：删除 `combine.rs` 中已无引用的私有函数，消除 `dead_code` warning（K0 中枢已改用 `kline_bars_to_segments`）。
- **关键路径**：`CHAN_RUST/rust/chan_data/src/combine.rs`

### 2026-07-31 — 拆除步进节奏调试埋点

- **要点**：移除 `step_rhythm_compute` 内 NDJSON 埋点；删除临时 dump 测试与 `debug-2e4a01.log`。
- **关键路径**：`step_rhythm_compute.dart`；已删 `test/dump_rhythm_debug_tmp_test.dart`

### 2026-07-31 — 步进节奏副图：点线/左侧名/同父级冷暖色

- **要点**：同 key 仅 Δx==1 点线续连（缺口不自动连）；打点对准 K0 柱心；名称标在系列最左点左侧；同 roundRef 同色，升暖降冷。
- **关键路径**：`kline_chart.dart`、`msg_history.dart`

### 2026-07-31 — 步进节奏：0-0组 + 父分型切组 + 子分型停窗

- **要点**：仅 normal；命名从 0-0；组锚=父分型极值；子反向分型确认后停写（25 的点不连到 26+）；父分型确认切组（39 起降组 a0=极高）。002003 日志验收：26–38 无产出，39 起 `0-0 down` a0=11.89。
- **关键路径**：`step_rhythm_compute.dart`、`kline_chart.dart`、`msg_history.dart`、`test/adjacent_ratio_step_rhythm_test.dart`

### 2026-07-31 — 相邻比例按主图连线出现链（虚实不论·K0颗粒度）

- **要点**：全层同构；子线=主图出现链（冻段+展示轨虚线/种子）；按 `beginX` 排序取末两根 `ratio=|cur|/|prev|`，无视虚实；每步 K0 `displayX` 写入。002003 实测 K1@26≈0.217、@39≈0.391、@42≈1.111。
- **关键路径**：`adjacent_ratio_compute.dart`、`step_rhythm_compute.dart`、`msg_history.dart`
- **注意**：禁止用 isSure/endConfirmX 过滤或排序。

### 2026-07-31 — 相邻比例/节奏改为动态子线（不要求已确认）

- **要点**：`K$n相邻比例`/`K$n步进节奏` 子线改为冻段+展示轨虚线/种子（与主图同源）；prev/cur 不要求 isSure；原则注释：指标默认动态计算。实测 step26/42 的 K1相邻比例均有值。
- **关键路径**：`adjacent_ratio_compute.dart`、`step_rhythm_compute.dart`、`main.dart`、`msg_history.dart`、`chart_indicator.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`

### 2026-07-31 — 接入 Kn相邻比例 + Kn步进节奏副图

- **要点**：关闭 `_chipOnlyMode` 恢复缠论步进；按 skill 口径落地全层同构副图「Kn相邻比例」「Kn步进节奏」（Dart 会话冻结，不做主图水平节奏线）；默认不勾选，catalog 可选手选。
- **关键路径**：`adjacent_ratio_compute.dart`、`step_rhythm_compute.dart`、`chart_indicator.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`level_models.dart`、`test/adjacent_ratio_step_rhythm_test.dart`
- **注意**：验收须连续单步（非一键跳末）。

### 2026-07-31 — 筹码性能：三层分层绘制 + 前缀索引 + Isolate 预热

- **要点**：
  1. **三层 `RepaintBoundary` 分层**（`_ChartPaintLayer.base/chip/crosshair`）：十字移线不再触发蜡烛/筹码重绘；`shouldRepaint` 按层独立判断。
  2. **前缀索引 `_ChipPrefixIndex`**：每 256 根 K 打快照，`profileAt(cutoffX)` 二分定位+从最近快照重算至 cutoff，避免每次从头累加；支持步进增量 append/truncateTo。
  3. **Isolate 后台预热 `warmUpInBackground`**：跳末/换股/加载大序列时在后台线程构建前缀索引，不堵 UI。
  4. **`_drawCandles` 可见范围优化**：不再遍历全部 5 万+ bars，改为只扫视口 ±2 根。
  5. **筹码柱右对齐**：从中心分裂改为 `chipRight` 向右对齐（S 绿左/B 红右），与 Rust 渲染口径一致。
  6. **chipOnlyMode 轻量十字 tooltip**：只显示 OHLC，跳过全表 `BarFeatureLookup` 和缠论 as-of（避免 13–18s 卡死）。
- **关键路径**：`chip_profile_compute.dart`（前缀索引+Isolate 预热+缓存）、`kline_chart.dart`（三层分层+十字 tooltip 分支+可见范围优化）、`kline_chip.dart`（右对齐绘制）、`main.dart`（清缓存+预热）、`bar_feature_lookup.dart`（empty factory）、`msg_history.dart`
- **踩坑**：
  - Isolate 传输只支持基本类型，`KlineBar` 不能跨边界；必须用 compact Map 序列化。
  - 反序列化 `Map<int,double>` 时 JSON 会把 int key 转为 String，必须 `int.parse(k.toString())` 转回。
  - `_warmGen` 版本号防慢 Isolate 结果覆盖新股票前缀（换股时序竞争）。
  - `chipOnlyMode` 下 `_bundleForZsAsOf` 必须返回 null，否则 `BarFeatureLookup.build()` 触发全量 FFI 传输全量 bars（5.6 万根约 1.5–1.8s 一次，十字线每帧触发 → 13–18s 卡死）。
  - `_drawCandles` 原遍历 5 万+ bars 空转每帧；改为视口范围后滚动/缩放大幅流畅。
  - 筹码柱从 `midX +/- halfW` 中心分裂改 `chipRight` 右对齐，否则与 Rust 渲染不一致产生视觉间隙。
  - 十字线鼠标移动跳过 `setState` 的条件必须宽松（Y 差 <0.75px），否则轻微抖动也会触发全 setState。
- **注意**：关占用后热重启即可，无需重编 DLL。

### 2026-07-30 — CHAN_RUST 筹码分布图全层同构落地

- **要点**：按 `chan-chip-distribution` 口径为 Flutter+Rust 新增 Kn筹码分布：离线分笔注入 `chip_tick_bins`，Rust `chip_profile`/`chan_chip_profile` 按 cutoff 分桶；主图右侧水平柱（S绿/B红）+ 峰延长线；副图 catalog `Kn筹码分布` 全层同构；十字 as-of 截断；配置落盘 `.chan_chip_config.json`。
- **关键路径**：`CHAN_RUST/rust/chan_data/src/chip.rs`（新）、`offline.rs`、`chan_ffi`；Flutter `chart_indicator.dart`、`kline_chip.dart`、`chip_profile_compute.dart`、`chip_config.dart`、`chip_settings_store.dart`、`kline_chart.dart`、`main.dart`、`msg_history.dart`、`test/chip_profile_test.dart`
- **注意**：关占用后需重编/替换 `chan_ffi.dll`；验收勾选 K0筹码分布 + 连续单步/十字回滚，勿只用一键跳末。

### 2026-07-30 — 副图chip bar动态高度 + BS标记对齐主图

- **要点**：
  1. 副图指标开关按钮(ChipBar)的 `innerTop` 原固定 `26px`，选多行指标后会遮挡副图画布内容。改为 `GlobalKey` 测量实际渲染高度 + `addPostFrameCallback` 动态更新。
  2. BS 副图标记（一类/二类/N类）的 `cx` 去掉 `+dx`（`confirmStackOffsetX` 水平偏移），圆点精确落在 `_barCenterX` 上，与主图 K0 蜡烛和十字线竖线对齐。
  3. 之前尝试全局 BS stack 计数分散水平位置防止重叠，但与"对齐主图"需求冲突——对齐优先，重叠靠颜色/标签文字区分。
- **踩坑**：BS 标记用 `dx` 做水平扇出虽然视觉上不重叠，但步进/十字线时圆点偏离 K 线中轴，用户感知为"没对齐"。最后方案是去掉全部 `dx`/`stackRank`/`stackCount`。
- **涉及文件**：`kline_chart.dart`（`_KlineChartState` 新增 `_subChipBarKey`/`_subChipBarHeight`/`_measureSubChipBar`；`_KlineCompositePainter` 新增 `subChipBarHeight` 参数；三类 BS 方法去掉 `dx` 和 `stackRank`/`stackCount`/轮廓描边）

### 2026-07-30 — 三类+N类BS全层同构落地 + catalog/副图绘制

- **要点**：Rust `buy_n.rs`（新）→ pipeline/combine → Flutter `buy_n_frame.dart`/`sell_n_frame.dart`（新数据模型）、`class_n_bs_compute.dart`（新·会话冻结/合并）、`chart_indicator.dart`（`SubIndicatorKind.buyN` + `bsClass` 字段 + catalog `maxBsClass`）、`kline_chart.dart`（副图 `_drawKnClassNBsSubChart`）、`bar_feature_lookup.dart`（十字 tooltip）、`chart_level_line_style.dart`（色阶扩展至 9 类暖/冷族）。默认 catalog 含 K0..Kn 三类..九类 BS。
- **架构说明**：
  - `buyN` 与 `buy1`/`buy2` 全层全口径同构：会话双键冻结、S上B下、副图同一套 `paintMark` 逻辑。
  - `bsClass` 用于区分 ≥3 的类号；最多到 `maxBsClass`（默认 9，随数据观察自动扩大）。
  - 色阶：买=暖族（深红→浅暖黄），卖=冷族（深蓝→浅冷），类越大色越浅。
- **涉及文件**：`buy_n.rs`（新）、`lib.rs`、`combine.rs`、`pipeline.rs`、`zs.rs`；Flutter 侧 `buy_n_frame.dart`/`sell_n_frame.dart`（新）、`class_n_bs_compute.dart`（新）、`chart_indicator.dart`、`main.dart`、`kline_chart.dart`、`chart_level_line_style.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`app_debug_snapshot.dart`

### 2026-07-30 — 二类BS字母随一类复位（收紧）

- **要点**：同资格中枢框内，一类建框/严格新极值更新 `box_min_low`/`box_max_high` 时，二类字母序 `letter_ord` 同步复位为 `None`（后续从 2Ba/2Sa 重起）。之前仅一类字母复位，二类在极值后继续续字母（2Bc/2Sc），现在改为 2Ba/2Sa。
- **涉及文件**：`buy2.rs`（find_buy2_with_active/find_sell2_with_active 的 `None`/新极值分支追加 `letter_ord=None`）；`buy2.rs` 测试同步更新；`AGENTS.md`/`README.md`/`msg_history.dart`/`TASK_LOG.md` 文档同步。
- **镜像**：全层同构；B/S 镜像。
- **注意**：关占用冷启后须连续单步验收；测试已覆盖复位场景。

### 2026-07-30 — 二类BS（方案A）全层同构落地（最终总结）

- **要点**：一类收紧为仅建框/严格新极值；同资格中枢框内等高/更弱标二类 2Ba…/2Sa…（镜像）。
Rust `buy2.rs`（新）→ pipeline/combine → Flutter 会话双键冻结（`class2_bs_compute.dart` 新）+ 副图「Kn二类BS」橙/青 + 十字 tooltip + 快照；DLL 已重编拷贝。
- **波及文件**：
  - **Rust**：`buy1.rs`（一类收紧）、`buy2.rs`（新·二类判定）、`lib.rs`（导出buy2）、`combine.rs`（K0二类字段）、`pipeline.rs`（Kn二类字段）
  - **Flutter**：`buy2_frame.dart`/`sell2_frame.dart`（新·数据模型）、`class2_bs_compute.dart`（新·会话冻结/合并/扩展）、`main.dart`（二类状态管理）、`kline_chart.dart`（副图渲染+十字）、`bar_feature_lookup.dart`（十字tooltip）、`chart_indicator.dart`（`SubIndicatorKind.buy2`）、`level_models.dart`/`kline_combine_bundle.dart`（二类字段）、`msg_history.dart`（口径记录）、`app_debug_snapshot.dart`（快照）
  - **文档**：`AGENTS.md`、`CHAN_RUST/README.md`、`TASK_LOG.md`
- **架构说明**：
  - 同资格中枢框 → 建框/严格新极值：一类独占；等高/更弱：二类（同框同序）。
  - 运行参照（`box_min_low`/`box_max_high`）一类/二类共享，两类均不抬高/压低参照。
  - 字母序：一类/二类各自独立（`1Ba…`/`2Ba…`）；同段互斥分区（一类已标则不标二类）。
  - 会话冻结双键（稳定键`层|段|标签` + 颗粒度键含`x`）与一类完全同构；`asOf` 只读冻结，禁覆盖消点。
- **注意**：关占用冷启后须连续单步验收；一键跳末≠步进验收。

### 2026-07-30 — 一类BS同枢框极值 + K0颗粒度：用户确认达标

- **要点**：①同枢 B 比已见最低 low、S 比已见最高 high（跳过不改参照；全层镜像）。②对齐分型判断：动态 active 延伸按 stepIdx 追加颗粒度点（键含 x）。用户确认完成预期。
- **相关路径**：`buy1.rs`、`class1_bs_compute.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：关占用重载 `chan_ffi.dll` 后冷启；一键跳末≠步进验收。

### 2026-07-30 — 一类BS同枢：B比框最低 / S比框最高（全层镜像）

- **要点**：同中枢内后续极值一律与「本枢已见最低low / 最高high」比，跳过时不抬高/压低参照（禁止与上一成员比）。B/S镜像、K0..Kn同构。002003：26/27 active high低于框最高故不新标卖，保留更早1Sa。
- **相关路径**：`buy1.rs`；`msg_history.dart`、`app_debug_snapshot.dart`、`AGENTS.md`
- **注意**：须重载 `chan_ffi.dll` 后冷启；旧「等于未标成员即重开」口径已废。

### 2026-07-30 — 一类BS：动态Kn按K0颗粒度追加点 + 清埋点落坑

- **要点**：对齐分型判断≠只冻首次发现x。稳定键`层|段|标签` + 颗粒度键含x；Kn≥1 active本步仍成立则追加`x=stepIdx`（002003：26与27各有1Sa）。误用稳定键去重→Rust仍出、Flutter skip→副图/十字当前步空。已清调试埋点。
- **相关路径**：`class1_bs_compute.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：勿再把「去掉尾柱回显」当成对齐分型判断；验收须连续单步看当前尾柱/十字读数。

### 2026-07-30 — 一类BS对齐Kn分型判断会话日志

- **要点**：按分型判断同构：`class1_bs_compute` 追加去重；副图/十字只扫 `buy1HistoryByKn`/`sell1HistoryByKn`（`x<=maxX`）；去掉尾柱重复画与读数铺展。
- **相关路径**：`class1_bs_compute.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`
- **注意**：**已被上条纠正**——仅冻发现x不够；动态active延伸须按K0步追加颗粒度点。

### 2026-07-30 — 页面快照补一类BS字段

- **要点**：用户末态快照(step=288)无法核对 25–27；快照原先不输出 buy1/sell1。现增加【一类BS·会话冻结】段。
- **相关路径**：`app_debug_snapshot.dart`、`main.dart`
- **注意**：请热重载/冷启后，复位再**连续单步到 26/27** 再复制快照（不要一键跳末）。

### 2026-07-30 — Kn一类BS 步进/十字：同动态尾柱仍显示

- **要点**：上次 Rust 计算已对但 UI 仍丢：步进后十字线未跟末柱、副图只画发现 x、tooltip 未 overlay 冻结帧。现步进吸附末柱；active 段在尾柱重复画点+铺读数（冻结 x 仍停在发现步）。
- **相关路径**：`kline_chart.dart`、`bar_feature_lookup.dart`
- **注意**：展示层方案后演进为「history 按K0步追加颗粒度点」（见最新条），非尾柱回显。

### 2026-07-30 — Kn一类BS：未标后同高从1Sa重起 + active不消点

- **要点**：002003 在 idx=25 上涨段不出新卖；26 与未标的 25 同高应从 `1Sa`（非 `1Sb`）；27 同动态 K1 仍输出且 x 钉在发现步。Rust 未标成员后同极值重起字母；active 且本枢已有前序标签时 x=begin+1。Flutter 十字读数从发现 x 铺到 active.x2。
- **相关路径**：`buy1.rs`、`pipeline.rs`；`bar_feature_lookup.dart`；`msg_history.dart`
- **注意**：已重载 `chan_ffi.dll`；请冷启动后连续单步 25→27 验收（一键跳末≠步进验收）。

### 2026-07-29 — 一类BS步进消值：会话冻结 + 禁asOf覆盖

- **要点**：日志证实 rawLostN>0 而 histLostN=0；`_rebuildCombine` 改为会话追加冻结。十字 as-of 不得用重算 buy1/sell1 覆盖冻结历史（overlay + 绘制改读会话帧）。
- **相关路径**：`main.dart` `_mergeBsHistory`；`kline_chart.dart` `_overlayFrozenClass1Bs` / `_buy1FramesForKn`

### 2026-07-29 — 一类BS：动态Kn参与 + 步进显示消值（未达标复盘）

- **要点**：①Kn≥1 一类BS须与动态中枢同喂入（冻段+active_unit），仅补极点/单测不算验收完成，须冷启动逐步验证副图标记随进行中Kn出现。②步进时曾出现的一类BS/副图读数不得在下一步被整表替换清掉（须像分型判断一样会话级追加冻结；当前 `_rebuildCombine` 直接覆盖 `_buy1*`/`levels` 是高危根因）。③多次「宣称完成」但用户可见行为未达标：DLL未覆盖、标签仍1a、动态段未真正参与显示——验收以画面步进为准，不以单测绿为准。
- **相关路径**：`pipeline.rs` export；`buy1.rs`；`main.dart` `_rebuildCombine`；`msg_history.dart`
- **注意**：此后同类任务完成前必须：关占用重载DLL + 冷启动 + 至少连续步进观察「出现→下一步仍在」。

### 2026-07-29 — Kn≥1 动态Kn参与一类BS

- **要点**：一类BS与动态中枢同喂入（冻段+active_unit）；`unit_to_segment` 按 dir 锚定买卖极点；回归锁死 active 可出 1Ba/1Sa。
- **相关路径**：`zs.rs` unit_to_segment、`buy1.rs` 测试、`msg_history.dart`
- **注意**：已重载 chan_ffi.dll，需冷启动查看副图

### 2026-07-29 — 一类BS副图标签色与DLL重载

- **要点**：关掉占用中的 chan_kline 后重编并复制 chan_ffi.dll，使副图标签切到 1Ba/1Sa；买点固定红、卖点固定绿。
- **相关路径**：`scripts/build_rust.ps1`、`kline_chart.dart` `_drawKnClass1BsSubChart`

### 2026-07-29 — Kn一类BS 全层同构收尾

- **要点**：一买同枢更高低不标；标签改 `1Ba/1Bb…`；镜像落地一卖 `1Sa…`（ZD_curr>ZG_prev）；副图改名「Kn一类BS」买卖同画（+1/-1）。
- **相关路径**：`buy1.rs`、`pipeline.rs`、`combine.rs`；Flutter `sell1_frame.dart`、`chart_indicator.dart`、`kline_chart.dart`、`msg_history.dart`
- **注意**：native `chan_ffi.dll` 若被占用需关应用后重跑 `build_rust.ps1`；Debug 目录 DLL 已更新。

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
