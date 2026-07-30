# 任务要点日志

## 最新记录

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
