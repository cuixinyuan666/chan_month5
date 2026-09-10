# 任务日志

> 所有智能体在完成任务后，应在此文件末尾追加。格式见下。本文件是**唯一**任务日志：已按时间从早到晚合并根目录原 `task-log.md`、`CHAN_RUST/TASK_LOG.md`（口径条目前加【口径】）、`CHAN_RUST/tooltip_audit_2026-08-14.md`（【审计】）。

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
3. 口径/行为变更也写在本文件（可继续用【口径】标题），并对用户可见时同步 `CHAN_RUST/flutter/chan_kline/lib/history/msg_history.dart`。
4. 如有跨模块影响或后续依赖，在「注意事项」中注明。
5. 本文件采用 UTF-8 编码，提交至版本控制。

---

### 2026-07-26 — Kn原生中枢十字线 as-of 动态显示，并补 ZS vs 跨段差异测试

- **要点**：实现十字线 as-of 动态显示功能（端段冻结时本地重算原生中枢），增加离开-返回与相邻合并对比测试，对齐 Rust find_zs 默认口径。
- **关键路径**：`CHAN_RUST/README.md`, `CHAN_RUST/flutter/chan_kline/lib/compute/zs_compute.dart`, `CHAN_RUST/rust/chan_data/src/zs.rs`, `CHAN_RUST/flutter/chan_kline/lib/widgets/kline_chart.dart`
- **注意**：需确保关闭十字线时仍绘制 Rust 末态逻辑；测试覆盖跨段差异场景

---

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

---

### 2026-07-28 — 修复中枢虚框定型的未来函数

- **要点**：离开 Kn 仅在确认态且与上一中枢不重叠时，上一虚框才变实线定型；动态 Kn 离开不得定型。新增 `find_zs_with_confirmed(n_confirmed)`，绘制跟 `is_sure`。
- **关键路径**：`CHAN_RUST/rust/chan_data/src/zs.rs`、`pipeline.rs`、`CHAN_RUST/flutter/chan_kline/lib/widgets/kline_chart.dart`、`lib/history/msg_history.dart`
- **注意**：改 Rust 后需 `build_rust.ps1` 重载 DLL；全层同构。

---

### 2026-07-28 — 添加 K0 中枢设计优化方案与样张

- **要点**：新增 K0 中枢设计文档与可视化样张，引入设计令牌体系，记录命名纠偏与单段虚框展示逻辑，提升用户体验与界面美观度。
- **关键路径**：`CHAN_RUST/docs/DESIGN_OPTIMIZATION.md`, `CHAN_RUST/docs/design_mockup.html`, `CHAN_RUST/flutter/chan_kline/lib/compute/zs_compute.dart`, `CHAN_RUST/rust/chan_data/src/zs.rs`, `CHAN_RUST/rust/chan_data/src/combine.rs`
- **注意**：引入设计令牌体系需后续协调统一颜色、排版和组件规范；与 Rust 端口径保持一致

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

### 2026-07-28 — Update task log and commit/push

- **要点**：更新 TASK_LOG.md 记录当日工作，并执行 git commit + push 操作
- **关键路径**：TASK_LOG.md、CHAN_RUST/flutter/chan_kline/ 目录下的多个文件
- **注意**：分支为 kuaduan-deletion-branch，已与 origin 同步

---

### 2026-07-28 — 窗口铺满工作区 + tooltip 分隔线修复

- **要点**：最大化改为 `fillDesktopWorkArea` / `visibleSize`；十字 tooltip 用 `====` / `-。-` 分隔，避免重复内容撑破右边框。原文标题在旧 `TASK_LOG.md` 中已损坏，按残留路径还原。
- **关键路径**：`CHAN_RUST/flutter/chan_kline/lib/window_work_area.dart`、`lib/main.dart`、`lib/widgets/crosshair_tooltip_panel.dart`、`windows/runner/main.cpp`
- **注意**：需同步 Windows runner / pubspec 后热重载

---

### 2026-07-28 — 统一中枢框架，移除 Normal/OverSeg 概念

- **要点**：删除冗余的 Normal 中枢算法，统一使用 OverSeg 并命名为「中枢(ZS)」；修复中枢虚实线判定逻辑，确保无 active_unit 时末 ZS 正确定型为实线。
- **关键路径**：`CHAN_RUST/rust/chan_data/src/zs.rs`, `pipeline.rs`, `lib.rs`, `CHAN_RUST/flutter/chan_kline/lib/widgets/kline_chart.dart`, `lib/history/msg_history.dart`, `task-log.md`
- **注意**：Rust `cargo test` 64/64 通过，Flutter `dart analyze` 0 errors，`flutter test` 3/3 通过

---

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

---

### 2026-07-28 23:10 — 中枢虚线框变实线框时机修正

- **执行者**：opencode
- **任务类型**：Bug修复
- **上下文**：中枢虚线→实线的判定逻辑不完整。动态 Kn 时末 ZS 可能被误判为实线；无 active_unit 时末 ZS 始终为虚线（应实线）。
- **关键操作**：
  1. Rust `pipeline.rs` `export()`：`find_zs()` 返回后，若 `active_unit.is_none()` 则强制末 ZS `is_sure=true`（所有段已冻结，中枢定型）
  2. Flutter `kline_chart.dart` `_drawZSOnMainChart()`：新增 `hasActive` 判断——有 active_unit 时所有中枢框强制虚线，无 active_unit 时由 `is_sure` 控制
- **结果**：2 个文件改动；Rust `cargo test` 64/64 通过，Flutter `dart analyze` 0 errors，`flutter test` 3/3 通过
- **注意事项**：K0 无 active_unit 概念，虚实完全由 `is_sure` 控制（全层同构）

---

### 2026-07-29 — Create branch "bs-point"

- **要点**：Create new branch "bs-point" for new feature development; switch to branch
- **关键路径**：git branch, git checkout operation
- **注意**：Branch name uses hyphen instead of space per Git convention; all pending changes included

---

### 2026-07-29 — Fix chart_level_line_style_test.dart failing tests

- **要点**：1) 添加 forZSOverSeg() 方法解决编译错误；2) 为 level 4-6 添加 frozenDashPattern 使测试通过；3) 新增 _zsOverSegColors 数组为 OverSeg 中枢提供独立配色
- **关键路径**：lib/widgets/chart_level_line_style.dart
- **注意**：同层 Normal/OverSeg 中枢必须不同色，测试期望 K0-K5 层配色相互独立

---

### 2026-07-29 — ZG/ZD常见命名互换 + Kn一买全层同构

- **要点**：中枢字段改为常见命名 ZG=上沿/ZD=下沿（框 high/low 几何不变）；新增一买：当前中枢框整体在上个下方触发，框内 1a/1b…不回写，层首 Kn 不参与；副图「Kn一买」与中枢同层同号。
- **关键路径**：`CHAN_RUST/rust/chan_data/src/zs.rs`、`buy1.rs`、`pipeline.rs`、`combine.rs`；Flutter `chart_indicator.dart`、`kline_chart.dart`、`buy1_frame.dart`、`msg_history.dart`
- **注意**：需用新 `chan_ffi.dll`（若 App 占用 dll 请先退出再复制）；触发条件为 `ZG_curr < ZD_prev`

---

### 2026-07-29 — 一字线仅 open=close；指标条避让标记

- **要点**：中枢一字锚定改为仅 `open==close`（去掉 high-low/tick 近一字误判，避免 18 这类塌成 ZG=ZD）；主图 `padT`/副图顶留白加大，指标名按钮不再盖住主副图标记。
- **关键路径**：`CHAN_RUST/rust/chan_data/src/zs.rs`；`flutter/.../kline_viewport.dart`、`kline_chart.dart`
- **注意**：需重载新 `chan_ffi.dll` 后一字线口径才生效

---

### 2026-07-29 — Kn一类BS 全层同构收尾

- **要点**：一买同枢更高低不标；标签改 `1Ba/1Bb…`；镜像落地一卖 `1Sa…`（ZD_curr>ZG_prev）；副图改名「Kn一类BS」买卖同画（+1/-1）。
- **相关路径**：`buy1.rs`、`pipeline.rs`、`combine.rs`；Flutter `sell1_frame.dart`、`chart_indicator.dart`、`kline_chart.dart`、`msg_history.dart`
- **注意**：native `chan_ffi.dll` 若被占用需关应用后重跑 `build_rust.ps1`；Debug 目录 DLL 已更新。

---

### 2026-07-29 — 一类BS副图标签色与DLL重载

- **要点**：关掉占用中的 chan_kline 后重编并复制 chan_ffi.dll，使副图标签切到 1Ba/1Sa；买点固定红、卖点固定绿。
- **相关路径**：`scripts/build_rust.ps1`、`kline_chart.dart` `_drawKnClass1BsSubChart`

---

### 2026-07-29 — Kn≥1 动态Kn参与一类BS

- **要点**：一类BS与动态中枢同喂入（冻段+active_unit）；`unit_to_segment` 按 dir 锚定买卖极点；回归锁死 active 可出 1Ba/1Sa。
- **相关路径**：`zs.rs` unit_to_segment、`buy1.rs` 测试、`msg_history.dart`
- **注意**：已重载 chan_ffi.dll，需冷启动查看副图

---

### 2026-07-29 — 一类BS：动态Kn参与 + 步进显示消值（未达标复盘）

- **要点**：①Kn≥1 一类BS须与动态中枢同喂入（冻段+active_unit），仅补极点/单测不算验收完成，须冷启动逐步验证副图标记随进行中Kn出现。②步进时曾出现的一类BS/副图读数不得在下一步被整表替换清掉（须像分型判断一样会话级追加冻结；当前 `_rebuildCombine` 直接覆盖 `_buy1*`/`levels` 是高危根因）。③多次「宣称完成」但用户可见行为未达标：DLL未覆盖、标签仍1a、动态段未真正参与显示——验收以画面步进为准，不以单测绿为准。
- **相关路径**：`pipeline.rs` export；`buy1.rs`；`main.dart` `_rebuildCombine`；`msg_history.dart`
- **注意**：此后同类任务完成前必须：关占用重载DLL + 冷启动 + 至少连续步进观察「出现→下一步仍在」。

---

### 2026-07-29 — 一类BS步进消值：会话冻结 + 禁asOf覆盖

- **要点**：日志证实 rawLostN>0 而 histLostN=0；`_rebuildCombine` 改为会话追加冻结。十字 as-of 不得用重算 buy1/sell1 覆盖冻结历史（overlay + 绘制改读会话帧）。
- **相关路径**：`main.dart` `_mergeBsHistory`；`kline_chart.dart` `_overlayFrozenClass1Bs` / `_buy1FramesForKn`

---

### 2026-07-30 — Kn一类BS：未标后同高从1Sa重起 + active不消点

- **要点**：002003 在 idx=25 上涨段不出新卖；26 与未标的 25 同高应从 `1Sa`（非 `1Sb`）；27 同动态 K1 仍输出且 x 钉在发现步。Rust 未标成员后同极值重起字母；active 且本枢已有前序标签时 x=begin+1。Flutter 十字读数从发现 x 铺到 active.x2。
- **相关路径**：`buy1.rs`、`pipeline.rs`；`bar_feature_lookup.dart`；`msg_history.dart`
- **注意**：已重载 `chan_ffi.dll`；请冷启动后连续单步 25→27 验收（一键跳末≠步进验收）。

---

### 2026-07-30 — Kn一类BS 步进/十字：同动态尾柱仍显示

- **要点**：上次 Rust 计算已对但 UI 仍丢：步进后十字线未跟末柱、副图只画发现 x、tooltip 未 overlay 冻结帧。现步进吸附末柱；active 段在尾柱重复画点+铺读数（冻结 x 仍停在发现步）。
- **相关路径**：`kline_chart.dart`、`bar_feature_lookup.dart`
- **注意**：展示层方案后演进为「history 按K0步追加颗粒度点」（见最新条），非尾柱回显。

---

### 2026-07-30 — 页面快照补一类BS字段

- **要点**：用户末态快照(step=288)无法核对 25–27；快照原先不输出 buy1/sell1。现增加【一类BS·会话冻结】段。
- **相关路径**：`app_debug_snapshot.dart`、`main.dart`
- **注意**：请热重载/冷启后，复位再**连续单步到 26/27** 再复制快照（不要一键跳末）。

---

### 2026-07-30 — 一类BS对齐Kn分型判断会话日志

- **要点**：按分型判断同构：`class1_bs_compute` 追加去重；副图/十字只扫 `buy1HistoryByKn`/`sell1HistoryByKn`（`x<=maxX`）；去掉尾柱重复画与读数铺展。
- **相关路径**：`class1_bs_compute.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`
- **注意**：**已被上条纠正**——仅冻发现x不够；动态active延伸须按K0步追加颗粒度点。

---

### 2026-07-30 — 一类BS：动态Kn按K0颗粒度追加点 + 清埋点落坑

- **要点**：对齐分型判断≠只冻首次发现x。稳定键`层|段|标签` + 颗粒度键含x；Kn≥1 active本步仍成立则追加`x=stepIdx`（002003：26与27各有1Sa）。误用稳定键去重→Rust仍出、Flutter skip→副图/十字当前步空。已清调试埋点。
- **相关路径**：`class1_bs_compute.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：勿再把「去掉尾柱回显」当成对齐分型判断；验收须连续单步看当前尾柱/十字读数。

---

### 2026-07-30 — 一类BS同枢：B比框最低 / S比框最高（全层镜像）

- **要点**：同中枢内后续极值一律与「本枢已见最低low / 最高high」比，跳过时不抬高/压低参照（禁止与上一成员比）。B/S镜像、K0..Kn同构。002003：26/27 active high低于框最高故不新标卖，保留更早1Sa。
- **相关路径**：`buy1.rs`；`msg_history.dart`、`app_debug_snapshot.dart`、`AGENTS.md`
- **注意**：须重载 `chan_ffi.dll` 后冷启；旧「等于未标成员即重开」口径已废。

---

### 2026-07-30 — 一类BS同枢框极值 + K0颗粒度：用户确认达标

- **要点**：①同枢 B 比已见最低 low、S 比已见最高 high（跳过不改参照；全层镜像）。②对齐分型判断：动态 active 延伸按 stepIdx 追加颗粒度点（键含 x）。用户确认完成预期。
- **相关路径**：`buy1.rs`、`class1_bs_compute.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：关占用重载 `chan_ffi.dll` 后冷启；一键跳末≠步进验收。

---

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

---

### 2026-07-30 — 二类BS字母随一类复位（收紧）

- **要点**：同资格中枢框内，一类建框/严格新极值更新 `box_min_low`/`box_max_high` 时，二类字母序 `letter_ord` 同步复位为 `None`（后续从 2Ba/2Sa 重起）。之前仅一类字母复位，二类在极值后继续续字母（2Bc/2Sc），现在改为 2Ba/2Sa。
- **涉及文件**：`buy2.rs`（find_buy2_with_active/find_sell2_with_active 的 `None`/新极值分支追加 `letter_ord=None`）；`buy2.rs` 测试同步更新；`AGENTS.md`/`README.md`/`msg_history.dart`/`TASK_LOG.md` 文档同步。
- **镜像**：全层同构；B/S 镜像。
- **注意**：关占用冷启后须连续单步验收；测试已覆盖复位场景。

---

### 2026-07-30 — 三类+N类BS全层同构落地 + catalog/副图绘制

- **要点**：Rust `buy_n.rs`（新）→ pipeline/combine → Flutter `buy_n_frame.dart`/`sell_n_frame.dart`（新数据模型）、`class_n_bs_compute.dart`（新·会话冻结/合并）、`chart_indicator.dart`（`SubIndicatorKind.buyN` + `bsClass` 字段 + catalog `maxBsClass`）、`kline_chart.dart`（副图 `_drawKnClassNBsSubChart`）、`bar_feature_lookup.dart`（十字 tooltip）、`chart_level_line_style.dart`（色阶扩展至 9 类暖/冷族）。默认 catalog 含 K0..Kn 三类..九类 BS。
- **架构说明**：
  - `buyN` 与 `buy1`/`buy2` 全层全口径同构：会话双键冻结、S上B下、副图同一套 `paintMark` 逻辑。
  - `bsClass` 用于区分 ≥3 的类号；最多到 `maxBsClass`（默认 9，随数据观察自动扩大）。
  - 色阶：买=暖族（深红→浅暖黄），卖=冷族（深蓝→浅冷），类越大色越浅。
- **涉及文件**：`buy_n.rs`（新）、`lib.rs`、`combine.rs`、`pipeline.rs`、`zs.rs`；Flutter 侧 `buy_n_frame.dart`/`sell_n_frame.dart`（新）、`class_n_bs_compute.dart`（新）、`chart_indicator.dart`、`main.dart`、`kline_chart.dart`、`chart_level_line_style.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`app_debug_snapshot.dart`

---

### 2026-07-30 — 副图chip bar动态高度 + BS标记对齐主图

- **要点**：
  1. 副图指标开关按钮(ChipBar)的 `innerTop` 原固定 `26px`，选多行指标后会遮挡副图画布内容。改为 `GlobalKey` 测量实际渲染高度 + `addPostFrameCallback` 动态更新。
  2. BS 副图标记（一类/二类/N类）的 `cx` 去掉 `+dx`（`confirmStackOffsetX` 水平偏移），圆点精确落在 `_barCenterX` 上，与主图 K0 蜡烛和十字线竖线对齐。
  3. 之前尝试全局 BS stack 计数分散水平位置防止重叠，但与"对齐主图"需求冲突——对齐优先，重叠靠颜色/标签文字区分。
- **踩坑**：BS 标记用 `dx` 做水平扇出虽然视觉上不重叠，但步进/十字线时圆点偏离 K 线中轴，用户感知为"没对齐"。最后方案是去掉全部 `dx`/`stackRank`/`stackCount`。
- **涉及文件**：`kline_chart.dart`（`_KlineChartState` 新增 `_subChipBarKey`/`_subChipBarHeight`/`_measureSubChipBar`；`_KlineCompositePainter` 新增 `subChipBarHeight` 参数；三类 BS 方法去掉 `dx` 和 `stackRank`/`stackCount`/轮廓描边）

---

### 2026-07-30 — CHAN_RUST 筹码分布图全层同构落地

- **要点**：按 `chan-chip-distribution` 口径为 Flutter+Rust 新增 Kn筹码分布：离线分笔注入 `chip_tick_bins`，Rust `chip_profile`/`chan_chip_profile` 按 cutoff 分桶；主图右侧水平柱（S绿/B红）+ 峰延长线；副图 catalog `Kn筹码分布` 全层同构；十字 as-of 截断；配置落盘 `.chan_chip_config.json`。
- **关键路径**：`CHAN_RUST/rust/chan_data/src/chip.rs`（新）、`offline.rs`、`chan_ffi`；Flutter `chart_indicator.dart`、`kline_chip.dart`、`chip_profile_compute.dart`、`chip_config.dart`、`chip_settings_store.dart`、`kline_chart.dart`、`main.dart`、`msg_history.dart`、`test/chip_profile_test.dart`
- **注意**：关占用后需重编/替换 `chan_ffi.dll`；验收勾选 K0筹码分布 + 连续单步/十字回滚，勿只用一键跳末。

---

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

---

### 2026-07-31 — 接入 Kn相邻比例 + Kn步进节奏副图

- **要点**：关闭 `_chipOnlyMode` 恢复缠论步进；按 skill 口径落地全层同构副图「Kn相邻比例」「Kn步进节奏」（Dart 会话冻结，不做主图水平节奏线）；默认不勾选，catalog 可选手选。
- **关键路径**：`adjacent_ratio_compute.dart`、`step_rhythm_compute.dart`、`chart_indicator.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`level_models.dart`、`test/adjacent_ratio_step_rhythm_test.dart`
- **注意**：验收须连续单步（非一键跳末）。

---

### 2026-07-31 — 相邻比例/节奏改为动态子线（不要求已确认）

- **要点**：`K$n相邻比例`/`K$n步进节奏` 子线改为冻段+展示轨虚线/种子（与主图同源）；prev/cur 不要求 isSure；原则注释：指标默认动态计算。实测 step26/42 的 K1相邻比例均有值。
- **关键路径**：`adjacent_ratio_compute.dart`、`step_rhythm_compute.dart`、`main.dart`、`msg_history.dart`、`chart_indicator.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`

---

### 2026-07-31 — 相邻比例按主图连线出现链（虚实不论·K0颗粒度）

- **要点**：全层同构；子线=主图出现链（冻段+展示轨虚线/种子）；按 `beginX` 排序取末两根 `ratio=|cur|/|prev|`，无视虚实；每步 K0 `displayX` 写入。002003 实测 K1@26≈0.217、@39≈0.391、@42≈1.111。
- **关键路径**：`adjacent_ratio_compute.dart`、`step_rhythm_compute.dart`、`msg_history.dart`
- **注意**：禁止用 isSure/endConfirmX 过滤或排序。

---

### 2026-07-31 — 步进节奏：0-0组 + 父分型切组 + 子分型停窗

- **要点**：仅 normal；命名从 0-0；组锚=父分型极值；子反向分型确认后停写（25 的点不连到 26+）；父分型确认切组（39 起降组 a0=极高）。002003 日志验收：26–38 无产出，39 起 `0-0 down` a0=11.89。
- **关键路径**：`step_rhythm_compute.dart`、`kline_chart.dart`、`msg_history.dart`、`test/adjacent_ratio_step_rhythm_test.dart`

---

### 2026-07-31 — 步进节奏副图：点线/左侧名/同父级冷暖色

- **要点**：同 key 仅 Δx==1 点线续连（缺口不自动连）；打点对准 K0 柱心；名称标在系列最左点左侧；同 roundRef 同色，升暖降冷。
- **关键路径**：`kline_chart.dart`、`msg_history.dart`

---

### 2026-07-31 — 拆除步进节奏调试埋点

- **要点**：移除 `step_rhythm_compute` 内 NDJSON 埋点；删除临时 dump 测试与 `debug-2e4a01.log`。
- **关键路径**：`step_rhythm_compute.dart`；已删 `test/dump_rhythm_debug_tmp_test.dart`

---

### 2026-07-31 — 去掉未用 combine_frames_to_segments

- **要点**：删除 `combine.rs` 中已无引用的私有函数，消除 `dead_code` warning（K0 中枢已改用 `kline_bars_to_segments`）。
- **关键路径**：`CHAN_RUST/rust/chan_data/src/combine.rs`

---

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

---

### 2026-07-31 — 主图层色同层同色 + 删 OverSeg 遗留配色

- **要点**：主图 Kn合并/连线/连续中枢（含构建中虚线、种子框）按展示层共用一色：K0蓝、K1黄、K2粉、K3+自定；Kn蜡烛仍红绿。删除未使用的 `forZSOverSeg`/`_zsOverSegColors`（此前误导为双套中枢逻辑）。
- **关键路径**：`chart_level_line_style.dart`、`kline_chart.dart`、`msg_history.dart`、`main.dart`、`app_debug_snapshot.dart`、`test/chart_level_line_style_test.dart`

---

### 2026-07-31 — 筹码开启时 Y 轴价签改左侧 + 拆除层色调试埋点

- **要点**：勾选筹码分布后，主图 Y 轴刻度与十字价格标签移到左侧（避让右侧筹码）；拆除 `chart_level_line_style` NDJSON 调试埋点。
- **关键路径**：`kline_chart.dart`、`chart_level_line_style.dart`、`msg_history.dart`

---

### 2026-07-31 — Kn中枢命名/层序 + 副图顶底色 + 中枢斜线填充

- **要点**：展示名「Kn连续中枢」→「Kn中枢」；同层序 Kn→合并→中枢→连线；中枢框斜线填充区分合并；副图分型确认/判断与截断：底/向下截断红、顶蓝（全层同构，注释已写清自定义口径）。
- **关键路径**：`chart_indicator.dart`、`kline_chart.dart`、`fractal_confirm_paint.dart`、`zs_compute.dart`、`main_indicator_picker.dart`、`msg_history.dart`

---

### 2026-07-31 — 筹码迁主图 + 相邻比例/节奏进副图 Kn指标

- **要点**：Kn筹码分布改主图指标并进「Kn指标」层全选（层内序末项）；副图 Kn相邻比例/步进节奏纳入「Kn指标」层全选与默认 K0 全选；副图 catalog 按显示层交错。
- **关键路径**：`chart_indicator.dart`、`kline_chart.dart`、`main.dart`、`sub_indicator_picker.dart`、`msg_history.dart`、相关单测

---

### 2026-07-31 — 中枢填充加深 + 副图读数跟 chip

- **要点**：Kn中枢斜线/底色加深便于与合并框区分；副图变量值显示在已选指标名后方（青字），取消右上独立读数框。
- **关键路径**：`kline_chart.dart`、`indicator_picker_chip.dart`、`msg_history.dart`

---

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

---

### 2026-07-31 — 指标开孔 + tick 真实筹码 + 默认分笔 K0

- **要点**：默认 `period=tick` 一字线画点；同分钟 `+i ms` 不撞戳；聚合周期仍 ticks→1m 并扩展多周期。标题条左开孔改为屏宽-140（修右侧指标单击被拖动区挡住）。tick 筹码按分笔序写 bins、禁三角。
- **相关路径**：`chan_data/{kline,tick,offline,chip}.rs`、`main.dart`、`kline_chart.dart`、`chip_profile_compute.dart`、`msg_history.dart`
- **注意**：冷启；native `chan_ffi.dll` 若占用需关进程后再 `build_rust.ps1`；长区间建议收窄日期。

---

### 2026-07-31 — 标题条 RIGHT OVERFLOW 修复

- **要点**：固定开孔 `屏宽-140` + 窗控实测约 174px 导致溢出 34px。改为 `Expanded(IgnorePointer)` 穿透指标点击，窗控前窄条拖窗。
- **相关路径**：`chan_kline/lib/main.dart` `_buildCaptionBar`

---

### 2026-08-01 — 【口径】build_rust.ps1 自动关闭运行中 app

- **问题**：chan_kline 运行时 `chan_ffi.dll` 被占用，`build_rust.ps1` 复制 DLL 失败。
- **变更**：脚本内新增「检测→Stop-Process 强制关闭→WaitForExit 等待句柄释放」逻辑；两处 DLL 复制改为带 5 次重试的 `Copy-Dll`。
- **踩坑**：脚本原为 UTF-16 LE 编码（PowerShell 5.1 原生支持中文）；若写成无 BOM UTF-8 会被 5.1 按 GBK 误读，中文乱码且 `$` 被吞（`$($App.Id)` 变字面），修改后必须还原 UTF-16 LE。
- **验证**：启动 app 后跑脚本，自动关闭（PID 输出正确）、两处复制均成功。

---

### 2026-08-01 — 【口径】筹码分布迁设置·仅K0

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

---

### 2026-08-01 — 【口径】十字 tooltip 标签格式化·全层同构

- **需求**：tooltip 内容格式化——各层标签统一「idx」命名；K0合并 仿照 K0中枢 取 GG/DD；中枢行「Kn」换为对应层级；另保留原 H/L 命名 MG/MD。
- **变更**：
  - `zs_compute.dart`：中枢行「K{n}中枢价格」→「K{n}中枢」；「K{n}中枢Kn序」→「K{n}中枢K{n} idx」（Kn→对应层级）；「K{n}中枢组No.」→「K{n}中枢 idx」。
  - `bar_feature_lookup.dart`：K0 块「K0[No.]」→「K0 idx」、「K0合并K0序」→「K0合并K0 idx」、「K0合并组No.」→「K0合并 idx」；合并行值 `GG/DD/MG/MD`：GG/DD=逐K当下区间极值（combineHigh/Low），MG/MD=合并框框体高低点（M=merge；K0 取 combineFrames 框体、Kn 取 levels[n].combineFrames 框体，as-of 与主图框同源、无未来函数；无框体时回退同值）；Kn 块行序与 K0 块同构：合并→合并K序→合并idx→分型确认/判断（含占位块补「K{n}合并 idx」行）。
  - `kline_chart.dart`：tooltip 的 `BarFeatureLookup.build` 的 K0 combineFrames 改用 `_effectiveK0CombineFrames`（十字 as-of 重建，避免 MG/MD 读到未来框体）；chip 轻量分支 K0[No.]→K0 idx。
  - `msg_history.dart`：新增 `appendTooltipFormatting`（进程内去重）。
- **口径**：`K{n}合并` GG/DD=逐K当下区间极值；MG/MD=合并框框体高低点（闭合框时与 GG/DD 同值，构建中虚线框悬停框内中段时不同）；中枢数量行标签=`K{中枢层}中枢K{中枢层} idx`。
- **验证**：`flutter test` 中 `zs_compute_test`、`bar_feature_lookup_test` 断言已同步更新并通过（含新增 MG/MD 框体取值用例）。

---

### 2026-08-01 — 【口径】切周期立即自动重载（修复聚合显示为一字线）

- **问题**：App 周期下拉选 1min 及以上时，图表整屏一字线，疑似聚合错误。
- **定位**：后端 Rust 聚合正确（经 ctypes 直调 `chan_ffi.dll` 验证：1m/5m/1d/1mon/1y 均产出真 OHLC 蜡烛，`load_klines` 单测亦通过）。根因在 Flutter 前端：切换周期只 `setState(_period)` 触发重绘，并不重载数据；于是图表用「新周期蜡烛画法」去画内存中仍为 tick 的旧数据（每根 O=H=L=C），整屏一字线；须手动重载（长按中区/改日期）后才显示正确蜡烛。
- **变更**：
  - `main.dart`：周期下拉 `onChanged` 选中后立即 `_loadKlines()` 按新周期自动重载（选中代码非空时）；周期说明弹窗操作步骤同步更新（无需再手动加载）。
  - `msg_history.dart`：新增 `appendPeriodAutoReload`（进程内去重），记录该口径变更。
- **口径**：聚合逻辑不变（仍 ticks→1m→升周期，主图恢复蜡烛）；仅切换周期时自动重载，图表始终与所选周期一致。
- **验证**：`flutter analyze` 无新增问题；聚合正确性由 Rust 单测 + FFI 直调验证（见上）。

---

### 2026-08-01 — 【口径】K0/Kn合并 GG/DD 口径修正：组内原始区间极值

- **需求**：K0 idx=2（10:47 11.66/11.66、10:48 H11.70 L11.68、10:49 11.70/11.70，后两根向上包含合并）tooltip「K0合并」的 **DD** 应为 **11.68**（组内 idx1 的 low），而非当时显示 11.70。
- **根因**：GG/DD 此前取 Rust 快照 `combine_high/combine_low`，而 `MergeEngine` 向上合并取「高高/高低」（`absorb`：Up 分支 `self.low = self.low.max(u.low)`，见 `engine.rs:335-341`），框体低点=11.70；框体高低点实为 MG/MD 语义。
- **变更**（`bar_feature_lookup.dart`）：
  - `build`：K0 合并循环内按悬停合并组 x1..x2 切原始K重算 `combine_range_high/low`（max(high)/min(low)，逐K当下、无未来函数）；各层 Kn 以当步单元高低跑组内极值（`combineX1` 变则切组重算），写入 `combine_range_high_$n/low_$n`，与 K0 全层同构。
  - `crosshairTooltipRows` / `_levelBlockRowsFor`：GG/DD 改取原始区间极值（无则回退快照合并值）；MG/MD 仍为合并框框体高低点。
  - `msg_history.dart`：新增 `appendMergeRangeExtreme`（进程内去重）；`main.dart` 启动时调用。
- **口径**：`K{n}合并` GG/DD=组内原始区间极值；MG/MD=合并框框体高低点（闭合时同值，构建中虚线框悬停中段时不同）。
- **验证**：`flutter test` 中 `bar_feature_lookup_test` 新增 K0 用例（idx=2 断言 `K0合并:GG【11.70】/DD【11.68】/MG【11.70】/MD【11.70】`）；旧用例（无 combineFrames / 框体 MG/MD）不受影响。

---

### 2026-08-01 — K0 逐笔：合成秒 + 成交量三分色 + 筹码灰度 w + 角标

- **要点**：X 轴真正走到秒（同分钟 n 笔均分 `base+k*60000/n ms`，替换无效的 +i ms 全卡 :00）；`normalize_native` 不再把无 BS 改 B（`has_bs=false` 保留）。筹码三分量：S→s 绿、B→b 红、无 BS→w 灰（w 不再= s+b 合计，`total=s+b+w`，`ChipProfile`/前缀索引/Isolate wire 全链路带 w）。K0 tick 成交量按 `metrics.tick_side` 着色（B红/S绿/灰），聚合周期与 Kn≥1 仍涨红跌绿。筹码柱右对齐三段（右B/中S/左灰），右上角 `B:xx, S:xx, 灰度:xx` 角标（十字 as-of/步进末根共用 profile）。X 轴与十字时间 `secondLike` 到秒。
- **相关路径**：`chan_data/src/{tick,chip,offline}.rs`、`chan_kline/lib/{compute/chip_profile_compute,widgets/kline_chart,widgets/kline_chip,models/chip_config,history/msg_history}.dart`、`test/chip_profile_test.dart`
- **踩坑/经验**：
  1. Rust 测试 `chip_profile_cutoff_freezes_history`：同价位两 bar 同桶累加，p1 total=110 而非 100。
  2. Dart 前缀索引 `_cacheKey` 只含首末 bar 时间/idx：单测两用例同构 bar 会缓存命中串结果，测试须用不同 timeMs。
  3. `_tooltipRowsForBar` 在 `_KlineChartState` 内，period 须 `widget.period`；painter 内才是字段。
- **验收**：冷启分笔周期——同分钟秒位递进；09:25 无 BS 量灰/B红/S绿；筹码含灰段+角标随步进与十字变化；1m 量恢复涨跌色。
- **注意**：关占用重载 `chan_ffi.dll` → 冷启动 → 连续单步验收（一键跳末≠验收）。

---

### 2026-08-01 — 筹码角标：十字悬停高亮单根 B/S/灰

- **要点**：`_drawCornerSums` 累计行（B/S/灰度）下，十字悬停时追加「当前」行——按该根 `chip_tick_bins` 求和分色（B 红/S 绿/灰），与累计区分。chip 层 `shouldRepaint` 已含 `segAsOf`（=bars[crosshairBarIdx].idx），十字移动即重画。纯 Dart 改动，无 DLL。
- **相关路径**：`chan_kline/lib/widgets/{kline_chip,kline_chart}.dart`、`history/msg_history.dart`

---

### 2026-08-01 — Kn笔数：Rust 分笔第4列真实笔数（方案B）

- **要点**：修复 688687/20240102 上 Kn笔数副图变量恒 0（根因①查表缺 tickCount 分支→读数恒 0；根因② bins 数组长度≠笔数，tick 恒 3/日线=3×价位数）。Rust `parse_tick_line` 解析第 4 列笔数（无列/非数字按 1 笔；显式 0 见 2026-08-02 条），`TickRow` 增 `ticks` 字段；chip.rs 三路径（tick/Day3/普通桶）写 `tick_count`/`buy_tick_count`（B）/`sell_tick_count`（S），灰度 w 仅进总数，非法行（价/量）不计。Flutter K0 笔数优先读 `metrics.tick_count`/`buy_tick_count`（键存在即用、可为 0），旧数据回退 bins 长度再回退 tick_side；`BarFeatureLookup` 写 `tick_count_${kn}`/`buy_tick_count_${kn}` 系列，`crosshairSubRows` 增 tickCount 分支 → 副图读数/十字 tooltip 出真实笔数。
- **相关路径**：`chan_data/src/{tick,chip}.rs`、`chan_kline/lib/{compute/kn_volume_series_compute,models/bar_feature_lookup,main,history/msg_history}.dart`、`TASK_LOG.md`
- **踩坑/经验**：
  1. bins 三数组每价位恒各 push 1（缺方向补 0.0）——长度只能当「价位数」，不能当笔数。
  2. 笔数 metrics 判断须用「键存在」，不用「值>0」（灰度行 buy=0 合法；显式总笔数 0 亦合法）。
  3. 老格式行 `HH:MM 价格 量 B`（第4列即方向）parse_float 失败→默认 1 笔；显式写 `0` 不得默认成 1。
- **验收**：关占用重载 `chan_ffi.dll` → 冷启动 → 688687/20240102 tick 周期副图「K0笔数」读数=分笔第4列（如 10），日线=当日笔数求和（非 3×价位数）；十字 tooltip 副图行含笔数。
- **注意**：`chan_ffi.dll` 已重建替换（15:36）；进程 15296 已结束待冷启。

---

### 2026-08-02 — 【口径】经验汇总（GG/DD 口径 + 切周期重载 + DLL 占用）

- **合并 GG/DD ≠ 框体高低**：Rust `MergeEngine` 向上合并取「高高/高低」，框体低点会被抬高；tooltip 的 GG/DD 必须在合并组内按原始K（Kn 用当步单元）重算 max(high)/min(low)。框体高低点只配 MG/MD。勿再把 `combine_high/low` 当 GG/DD。
- **切周期一字线 ≠ 聚合坏了**：Rust 聚合产出真 OHLC；前端若只 `setState(_period)` 不重载，会用「新周期蜡烛画法」画内存里仍是 tick 的数据（O=H=L=C）→ 整屏一字线。下拉选周期后必须立刻 `_loadKlines()`。排查先分清后端/前端，可用 ctypes 直调 `chan_ffi.dll` 证聚合。
- **DLL 复制仍失败**：`build_rust.ps1` 会杀 `chan_kline` 进程并重试复制；若终端里仍挂着 `flutter run`，`windows/native/chan_ffi.dll` 可能继续被占用。应先在该终端 `q` 退出 `flutter run`（或结束整个 Flutter/Dart 树）再跑脚本。
- **build_rust.ps1 编码（再踩）**：必须 **UTF-16 LE + BOM（FF FE）**。无 BOM 的 UTF-16 会被 PS 按系统码页误读 → 中文乱码 + `Missing closing ')'`（`$($App.Id)` 被拆坏）。编辑后应用解析检查确认 `PARSE_OK`，勿只看文件「看起来像 UTF-16」。
- **落盘位置**：口径正文见下方 2026-08-01 两条；UI 常驻历史见 `msg_history.appendMergeRangeExtreme` / `appendPeriodAutoReload`。

---

### 2026-08-02 — 【口径】tooltip VOL/笔数 B/S/G + 应显尽显槽位

- **需求**：各层 VOL 分 B/S/G（G=gray）；笔数同设计；`-。-` 分类别、`===` 分层；不按指标勾选过滤；类别后接下一层时只留 `===`。
- **变更**：
  - `kn_volume_series_compute.dart`：K0/Kn 成交量与笔数 B/S/G 序列（bins 三分解 / metrics 笔数）。
  - `bar_feature_lookup.dart`：OHLCV→`VOL B/S/G`，新增 `Kn笔数`；层内 `_joinCategories`；层末不挂 star；极点距/截断/BS/比例/节奏固定槽位。
  - `kline_chart.dart`：tooltip 中枢/副图计算喂全 catalog。
  - `crosshair_tooltip_panel.dart`：类别分隔改为 `-。-` 重复。
- **口径**：无 tick 数据时量全归 G；有 bins 时按 b+s+w 占比分 volume。
- **验证**：`bar_feature_lookup_test` 覆盖 B/S/G、笔数、无勾选仍显、层前无 star。

---

### 2026-08-02 — 【口径】tooltip 成交量独立行 + 比例/节奏动态名

- **需求**：VOL 从 Kn OHLC 拆出为 `Kn成交量`；数值一律【】；相邻比例→比例、步进节奏→节奏；X类BS 与 比例/节奏 各成独立类别；同 K0 多节奏显示为 `K0节奏0-0` 动态行。
- **变更**：`bar_feature_lookup` 层内序=价量笔→合并/分型→中枢→极点距/截断→BS→比例/节奏；`step_rhythm_lines_*` 存多点；`chart_indicator` 标签缩短。
- **验证**：`bar_feature_lookup_test`（独立成交量/多节奏行）、`adjacent_ratio_step_rhythm_test` 标签断言。

---

### 2026-08-02 — 【口径】K0筹码峰/笔数峰 tooltip + 左侧笔数分布

- **需求**：tooltip 仅 K0 增加筹码峰/笔数峰独立类别（动态 -/＋n）；笔数分布主图左侧同构筹码；价签在分布右侧。
- **变更**：`profile_peak_classify.dart`；Rust `chip_tick_count_bins`；`TickDistProfileCompute` + `TickDistConfig`；`ChipProfilePainter.alignLeft`；设置面板「笔数分布」。
- **口径**：-1=低价下最近峰，+n=高价上第 n 峰；框内无号。格式 `K0筹码峰-1：【价】/B：【】S：【】G：【】`。
- **注意**：须重编 DLL 后冷启；旧数据无 count bins 时回退收盘价落笔数。

---

### 2026-08-02 — 【口径】分笔第4列显式0保留0（副图/笔数分布全无柱）

- **需求**：离线写笔数=0 时，Kn笔数副图与左侧笔数分布应全无柱；勿显示成每根 1。
- **根因**：`parse_tick_line` 仅 `v>0` 才采纳，显式 `0` 被当成非法仍默认 1。
- **变更**：数字且 `v>=0` 原样用（含 0）；仅无列或第4列为 B/S 时默认 1；`chip_tick_count_bins` 仅 `ticks>0` 才写。
- **相关**：`tick.rs` / `chip.rs` 注释、`msg_history.appendTickCountZeroLiteral`、根 `task-log.md`。
- **注意**：须重编 `chan_ffi.dll` 后冷启；002003 等旧文件笔数列全 0 → 预期全无柱。

---

### 2026-08-02 — tooltip 成交量独立行 + 比例/节奏动态名

- **要点**：VOL 从 Kn OHLC 拆为 `Kn成交量`；相邻比例→比例、步进节奏→节奏；X类BS 与比例/节奏独立类别；多节奏动态行如 `K0节奏0-0`。
- **相关路径**：`bar_feature_lookup.dart`、`chart_indicator.dart`、相关 test、`msg_history.dart`

---

### 2026-08-02 — K0筹码峰/笔数峰 tooltip + 左侧笔数分布

- **要点**：tooltip 仅 K0 增加筹码峰/笔数峰（动态 -/＋n）；主图左侧笔数分布同构筹码（`chip_tick_count_bins`）；价签在分布右侧；设置面板「笔数分布」。
- **相关路径**：`profile_peak_classify.dart`、`tick_dist_*`、`chip.rs`、`kline_chip.dart`、`kline_chart.dart`、`chip_settings_store.dart`、`msg_history.dart`
- **注意**：须重编 DLL；无 count bins 时回退收盘价落笔数。

---

### 2026-08-02 — 分笔第4列显式0保留0（副图/笔数分布全无柱）

- **要点**：`parse_tick_line` 对显式笔数 `0` 不再默认成 1；仅无列或第4列为 B/S 时按 1 笔。002003 等笔数列全 0 时，Kn笔数副图与左侧笔数分布应全无柱。
- **相关路径**：`chan_data/src/{tick,chip}.rs`、`msg_history.dart`、`main.dart`、`kn_volume_series_compute.dart`、`tick_dist_profile_compute.dart`、`CHAN_RUST/TASK_LOG.md`
- **注意**：须重编 `chan_ffi.dll` 后冷启；metrics 键存在即用（含 0），勿回退成 bins 长度/1。

---

### 2026-08-02 — K0分型确认/极点距/截断语义统一

- **要点**：显示名 K0分型确认/极点距/截断一律读 `k0_confirm` + `barFeatures.fractalPeakDist`；副图/tooltip 不再优先 `LevelBundle(level==1)`。`level==1.confirms` 与 k0 同源（输入=原始K），units 才是 K1——双轨易误判为「读 K1」。
- **相关路径**：`bar_feature_lookup.dart`、`kline_chart.dart`、`msg_history.dart`、`bar_feature_lookup_test.dart`
- **注意**：勿再写「K0分型确认=K1端点」；kn==1→k0/feat，kn≥2→level_confirms。

---

### 2026-08-02 — Tooltip 四准则全修（1B+2A）

- **要点**：十字 asOf 时中枢/levels 禁回落末态；K0合并改用 Rust `asOfBundle.frames`；标签改为「Kn上一中枢确认」（算法不变）；BS 删 levels 末态兜底。量能双轨与动态峰/节奏仅文档化。
- **相关路径**：`zs_compute.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`zs_compute_test.dart`、`msg_history.dart`、`main.dart`
- **注意**：asOf bundle 失败→空结构；ML 用 feat/history 固定键，勿解析 tip 动态行。

---

### 2026-08-02 — 副图 Kn连线斜率（全层同构）

- **要点**：新增副图「K{n}连线斜率」；复用比例出现链末根算 slope=dP/dX；K0 颗粒度会话冻结；折线+0轴；tip/层全选/默认K0与比例同口径。纯 Flutter。
- **相关路径**：`line_slope_compute.dart`、`chart_indicator.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`line_slope_compute_test.dart`、`msg_history.dart`
- **注意**：虚线延伸步 slope 随终点变；验收连续单步，非一键跳末。

---

### 2026-08-02 — 主图 Kn三型平移线 / Kn四型对线（v1）

- **要点**：新增主图延伸指标「K{n}三型平移线」「K{n}四型对线」；确认分型前 N 锚点；三型两同斜率过异型向右，四型两顶+两底弦线向右；十字 asOf 禁末态；层全选/默认 K0。纯 Flutter。
- **相关路径**：`fx_extend_line_compute.dart`、`chart_indicator.dart`、`kline_chart.dart`、`fx_extend_line_compute_test.dart`、`msg_history.dart`、`main.dart`
- **注意**：前 N 按确认序冻结；延伸画到视口右缘；验收连续单步。

---

### 2026-08-02 — 三型/四型改为滑动窗多组（K0步进）

- **要点**：修复「只出一组」：确认序滑动窗（三型窗3、四型窗4）每窗合格即画一组，随步进累积；asOf 用 confirms 前缀。
- **相关路径**：`fx_extend_line_compute.dart`、`kline_chart.dart`、`fx_extend_line_compute_test.dart`、`msg_history.dart`
- **注意**：勿再只取全图最早前 N。

---

### 2026-08-02 — 三型/四型：最新/十字近邻 + tip

- **要点**：无十字只画最新窗；开十字画焦点近邻窗；tooltip 增「Kn三型平移线」「Kn四型对线」斜率读数，与主图筛选同口径。
- **相关路径**：`fx_extend_line_compute.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`
- **注意**：tip 按柱 asOf 取近邻窗，非勾选门控。

---

### 2026-08-02 — tip 三型/四型改为延长线落点价

- **要点**：tooltip「Kn三型平移线/四型对线」改为延长线落到该根 K0 的价格（y0+slope·Δx）；四型分顶/底价。
- **相关路径**：`fx_extend_line_compute.dart`、`bar_feature_lookup.dart`、`msg_history.dart`
- **注意**：与主图近邻窗筛选同口径；非斜率。

---

### 2026-08-02 — 清理三型/四型调试埋点

- **要点**：移除 `kline_chart` / `bar_feature_lookup` 中 debug-5fbfa5 文件埋点及仅用于埋点的 `dart:io`/`dart:convert` 引用。
- **相关路径**：`kline_chart.dart`、`bar_feature_lookup.dart`

---

### 2026-08-03 — 主图 Kn趋势线（段内支撑/压力）

- **要点**：移植旧 `Math/TrendLine.py` 为延伸类主图指标「K{n}趋势线」；子线层同号（子=level n+1、父=level n+2，K0≈旧工程）；呈现/tip 对齐三型四型（最新/近邻窗、延长线落点价撑/压）。
- **相关路径**：`trend_line_compute.dart`、`chart_indicator.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`trend_line_compute_test.dart`
- **注意**：依赖父层；最高层不作显示名；maxKn<2 目录挂 K0 占位（计算空）；纯 Flutter。

---

### 2026-08-03 — 主图 Kn均线 / Kn通道（TrendModel）

- **要点**：移植旧 `Math/TrendModel.py` 为「K{n}均线」(MEAN)与「K{n}通道」(MAX/MIN)；kn 同中枢；K0=bars.close、Kn=unitBars.close；周期可配并落盘；tip/层全选/默认 K0。
- **相关路径**：`trend_model_compute.dart`、`trend_model_config.dart`、`chart_indicator.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`main.dart`、`msg_history.dart`
- **注意**：与 Kn趋势线无关；设置面板改周期；热重启加载。

---

### 2026-08-03 — Kn MACD/BOLL/RSI/KDJ/Demark 接线

- **要点**：主图 K{n}布林/Demark、副图 K{n}MACD/RSI/KDJ 全层同构接线完成；`MathIndicatorConfig` 统一参数落盘；十字 tooltip 增 MACD/布林/RSI/KDJ/Demark 槽位；修复 catalog 标签插值编译错误。
- **关键路径**：`kline_chart.dart`、`bar_feature_lookup.dart`、`main.dart`、`msg_history.dart`、`math_classic_compute_test.dart`、`chart_indicator.dart`
- **注意**：动态 Kn=unitBars+active OHLC；asOf 截断；设置面板「数学指标参数」兼容旧 `.chan_trend_model_config.json`。

---

### 2026-08-03 — Kn背驰 12 算法分项输出

- **要点**：先提交 Math/趋势线等改动；再实现 K{n}背驰_{algo}（12 种力度分项），输出 in/out/ratio 与 diver∈{1,-1,0}；非买卖点；默认不勾。
- **相关路径**：`divergence_compute.dart`、`divergence_algo.dart`、`chart_indicator.dart`、`bar_feature_lookup.dart`、`kline_chart.dart`、`math_indicator_config.dart`、`msg_history.dart`、`divergence_compute_test.dart`
- **注意**：K0 进出段=分钟K段 idx；力度用 K0 MACD/RSI；turnrate 缺字段 diver=0；`divergenceRate>100` 保送。

---

### 2026-08-03 — Kn背驰迁副图并修变量清空

- **要点**：背驰 12 项从主图迁到副图「背驰」类（算法分子标题×层分层）；副图画 ratio 折线+diver 柱；修复 diver=0 时 in/out/ratio 仍 hold 旧值；过滤非有限 ratio。
- **相关路径**：`chart_indicator.dart`、`sub_indicator_picker.dart`、`kline_chart.dart`、`divergence_compute.dart`、`kn_ohlc_sample_compute.dart`、`bar_feature_lookup.dart`、`msg_history.dart`
- **注意**：默认不勾、不进副图层全选；特征键不变。

---

### 2026-08-03 — Kn Math/均线/通道/Demark 当下冻结

- **要点**：审计确认 K1 上 MACD/BOLL/RSI/KDJ/Demark内容/均线/通道会步进回写；成交量与背驰本样本不回写。新增 `MathSeriesFreezeStore` 会话格点冻结，主图/副图/十字读仓。
- **相关路径**：`math_series_freeze_store.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`dump_indicator_rewrite_audit.dart`
- **注意**：参数变更清空并 0..当前步重冻；冻结 instrumentation 暂留待 UI 验收。

---

### 2026-08-04 — 清理 Math 当下冻结调试埋点

- **要点**：用户确认修复后移除 `math_series_freeze_store` 文件埋点；审计 dump 测试改为正规回归 `math_series_freeze_store_test.dart`。
- **相关路径**：`math_series_freeze_store.dart`、`math_series_freeze_store_test.dart`

---

### 2026-08-04 — Demark迁副图 + Math十字asOf + Kn绑定补齐

- **要点**：Demark 从主图迁副图并进「Kn指标」层全选；均线/通道/布林 `_paintPriceSeries` 十字 asOf 右侧不画；副图 chip/crosshairSubRows 接 Demark；坑点写入 `AGENTS.md` 常驻节。
- **相关路径**：`chart_indicator.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`AGENTS.md`、`math_classic_compute_test.dart`

---

### 2026-08-04 — 背驰12算法进「Kn指标」层全选

- **要点**：`subIndicatorsForLevel` 纳入全部背驰算法；启动默认仍不勾（`defaultSubIndicatorsK0` 过滤）。修正「默认不勾≠不进层全选」口径。
- **相关路径**：`chart_indicator.dart`、`AGENTS.md`、`msg_history.dart`、`math_classic_compute_test.dart`

---

### 2026-08-04 — Kn背驰全层同构：本层力度+冻结仓

- **要点**：背驰力度改跟 `displayKn`（优先读 Math 仓）；新增 `DivergenceFreezeStore` 格点冻结，动态离开段只追加不挪旧点；副图/十字读仓+asOf 截断。BSP 不动。
- **相关路径**：`divergence_compute.dart`、`divergence_freeze_store.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：验收须连续单步；默认仍不勾背驰

---

### 2026-08-05 — Kn中枢判断/确定副图（对齐分型）

- **要点**：新增副图「Kn中枢判断」「Kn中枢确定」全层同构；会话冻结打点（稳定键层|x1，开放枢可逐K追加；确定首次 is_sure 冻结）；catalog/层全选/绘制/十字 asOf 齐套。
- **相关路径**：`zs_signal_compute.dart`、`chart_indicator.dart`、`main.dart`、`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：验收须连续单步；值=dir 符号；勿用 seq 作稳定键

---

### 2026-08-06 — Kn中枢判断对齐分型稀疏度

- **要点**：单开放枢只首次打点；≥2 不确定（离开窗）才逐步追加末候选；重叠合回归零。确定仍 `isSure` 首次冻结。日志证实旧口径对单开放逐步刷点过密。
- **相关路径**：`zs_signal_compute.dart`、`zs_signal_compute_test.dart`、`msg_history.dart`、`chart_indicator.dart`
- **注意**：验收连续单步对照 52–85；埋点暂留待复验

---

### 2026-08-06 — 中枢红绿配色 + 十字交互与 MACD 越界修复

- **要点**：中枢判断/确定升红降绿；MACD 副图对冻结仓长度做边界保护；左右键吞系统 repeat 防双步进；上下键滚 tooltip；中键切换 tooltip（不关十字）；chip ※ 按层级排序。
- **相关路径**：`fractal_confirm_paint.dart`、`kline_chart.dart`、`zs_signal_compute.dart`、`indicator_picker_chip.dart`
- **注意**：已移除中枢调试埋点

---

### 2026-08-06 — 中枢确认改名 + 默认绘制静音 + RSI/KDJ 越界

- **要点**：`Kn中枢确定`→`Kn中枢确认`（确认/判断同升红降绿）；层全选仍关联全集，默认只绘制主图 Kn/合并/中枢/连线与副图分型确认/判断/截断/中枢确认/判断，其余删除线静音；RSI/KDJ/成交量副图对冻结仓长度做边界保护。
- **相关路径**：`chart_indicator.dart`、`kline_chart.dart`、`msg_history.dart`、`zs_signal_compute_test.dart`
- **注意**：新层全选新增的非核心项同样默认静音；单击 chip 可打开绘制

---

### 2026-08-06 — 中枢确认配色口径（上个中枢方向）

- **要点**：锁定确认色语义——绿=上个下降中枢被确认，红=上个上升中枢被确认（跟确认框自身 dir；例 K0 idx=54 绿、85 红）；非价格涨跌、非新虚框/分型符号。
- **相关路径**：`fractal_confirm_paint.dart`、`zs_signal_compute.dart`、`msg_history.dart`

---

### 2026-08-06 — 中枢判断跟「上个中枢」同色 + 禁自动开 DevTools

- **要点**：判断离开窗值/色改跟被离开旧框 dir（与确认统一：升红降绿；例 52/57 红、85 确认红、90 判断绿）；`dart.openDevTools=never`，并关闭 `cursor.terminal.usePreviewBox`，避免终端 DevTools 链接默认开网页。
- **相关路径**：`zs_signal_compute.dart`、`fractal_confirm_paint.dart`、`msg_history.dart`、`.vscode/settings.json`、用户 `settings.json`
- **注意**：打点身份仍用离开候选 x1；热重载后连续单步复验

---

### 2026-08-06 — 中枢确认/判断改空间升降色（抬高红下移绿）

- **要点**：确认/判断色不再用框 `first.dir`，改为上个中枢相对前一枢中轴抬高=红、下移=绿（实证 77/84 判断红、85 确认红、90 判断绿、91 确认绿）；并加 `cursor.browser.autoOpenLocalhostUrls=false` 试图禁 Cursor 内嵌打开 localhost。
- **相关路径**：`zs_signal_compute.dart`、`fractal_confirm_paint.dart`、`msg_history.dart`、用户/`\.vscode` settings
- **注意**：若仍弹内嵌预览，到 Settings → Tools & MCP 关闭「Show Localhost Links in Browser」

---

### 2026-08-06 — Kn中枢确认/判断：空间升降色 + 默认静音绘制（提交）

- **要点**：①中枢确认/判断对「上个中枢」：相对前一枢中轴抬高红、下移绿（禁 first.dir）；②`中枢确定`→`中枢确认`；③层全选关联全集但默认只画主图四类+副图五类，其余 muted；④RSI/KDJ/成交量越界保护；⑤背驰全层同构冻结仓等同批落地。
- **相关路径**：`zs_signal_compute.dart`、`zs_signal_event.dart`、`chart_indicator.dart`、`kline_chart.dart`、`divergence_*`、`msg_history.dart`、`AGENTS.md`、`TASK_LOG.md`
- **注意**：验收连续单步对照 77/84/85/90/91；Cursor 内嵌 localhost 预览须在 Tools&MCP 关「Show Localhost Links in Browser」

---

### 2026-08-06 — 中枢判断：只打未确认上个框，新种子不当步

- **要点**：判断仅离开窗（≥2 不确定）对尚未确认的上个虚框打点；单开放/确认同拍新种子不打，消确认+判断同 x。K0 段密、离开常同拍定型 → K0中枢判断可长期全 0（可接受）；K0分型判断仍会在成立当步非零。
- **相关路径**：`zs_signal_compute.dart`、`zs_signal_compute_test.dart`、`msg_history.dart`

---

### 2026-08-06 — 中枢判断恢复首次可判+离开窗对上个框（全层同构）

- **要点**：收回「新种子不当步」；对齐分型——单开放首次可判打点；离开窗/动态离开对尚未确认上个框逐K打点；K0/Kn 同一规则无层特例。空间升降色不变。
- **相关路径**：`zs_signal_compute.dart`、`zs_signal_compute_test.dart`、`msg_history.dart`
- **注意**：K0 上确认与新种子首次判断仍可能同拍（同构代价）；非「K0 必须全 0」

---

### 2026-08-06 — 中枢确认当步抑制新种子首次判断（消同拍异框）

- **要点**：同拍常见「确认刚定型上个框 + 判断新芽」异 x1（例 K0 idx=7：确认 x1=6、判断 x1=-1 新芽）。先确认后判断；本步有新确认则 `suppressNewSeedFirstHit`，新芽延后到下一步首次可判；离开窗对上个框仍可打。全层同构。
- **相关路径**：`zs_signal_compute.dart`、`main.dart`、`zs_signal_compute_test.dart`、`msg_history.dart`
- **注意**：验收连续单步看 idx=7：应只亮确认、判断不与确认异框同亮

---

### 2026-08-06 — 记录口径：判断/确认对象=未确认结构（非新芽）

- **要点**：Kn分型判断/确认与 Kn中枢判断/确认，一律是对「尚未确认」的分型或中枢；不是对新芽、新分型、新中枢。已写入 AGENTS 常驻条、`msg_history` v10、中枢 merge 注释。
- **相关路径**：`AGENTS.md`、`msg_history.dart`、`main.dart`、`zs_signal_compute.dart`、`TASK_LOG.md`

---

### 2026-08-06 — K0中枢判断/确认同拍共点重叠（全层同构）

- **要点**：对象=未确认中枢非新芽；去掉单开放首次可判；离开窗打上个 + 确认当步对刚定型框同拍打判断。K0 无动态Kn → 判断与确认同 x/x1 副图重叠（预期）；Kn≥1 同一规则可多步离开。
- **相关路径**：`zs_signal_compute.dart`、`main.dart`、`zs_signal_compute_test.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：验收 K0 连续单步：确认点处判断应同亮同色同框，不得打新芽

---

### 2026-08-06 — 中枢判断/确认：未确认共点 + 经验落盘（提交）

- **要点**：对象=尚未确认中枢（非新芽）；离开窗打上个 + 确认当步对刚定型框同拍打判断。K0 无动态Kn → 副图判断/确认同 x/x1 重叠（预期）；全层同一 merge。经验写入 `zs_signal_compute` 头注释、`AGENTS`、`msg_history` v11。
- **相关路径**：`zs_signal_compute.dart`、`main.dart`、`kline_chart.dart`、`zs_signal_compute_test.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：踩坑——勿 first.dir 配色；勿同拍打新芽（idx=7 异框）；勿套分型「新芽首次可判」破坏 K0 重叠；确认同拍须补判断否则 K0 判断易全 0

---

### 2026-08-06 — Kn背驰 v5：本枢末Kn vs 上枢末Kn

- **要点**：背驰改由中枢判断±1 启动本枢；比较上枢末 Kn 与本枢末 Kn（`end_idx`，含动态 active）；K0 颗粒度只写当前步格；重叠合并当步重映射本枢，旧格冻结不回写；废除破 ZG/ZD 门槛。
- **相关路径**：`zs.rs`、`zs_frame.dart`、`divergence_compute.dart`、`divergence_freeze_store.dart`、`main.dart`、`msg_history.dart`、`divergence_compute_test.dart`
- **注意**：须重编 `chan_ffi.dll` 后冷启；验收连续单步（非一键跳末）

---

### 2026-08-06 — Kn背驰 v6：包中用上/上上，突破用本/上

- **要点**：相对最新动态中枢，动态Kn完全落在 ZG/ZD 内则比较上枢末与上上枢末；破上沿或下沿才用本枢末 vs 上枢末。启动仍靠中枢判断会话。
- **相关路径**：`divergence_compute.dart`、`msg_history.dart`、`divergence_compute_test.dart`、`AGENTS.md`
- **注意**：验收默认分笔 K0=90 应为 21vs23；K0=104 破枢后应为 23vs26

---

### 2026-08-07 — 背驰area学习观察：自动叠KnMACD + 十字高亮比较段

- **要点**：默认背驰率 1.0（旧 1e9 加载时迁移）；勾选 Kn背驰_area 自动并入同号 MACD 并取消静音；十字 asOf 下 MACD 副图蓝/琥珀条带高亮 in/out 两段。观察向，可删。
- **相关路径**：`divergence_compute.dart`、`divergence_freeze_store.dart`、`chart_indicator.dart`、`kline_chart.dart`、`math_indicator_settings_store.dart`、`msg_history.dart`
- **注意**：高亮依赖步进冻结的 span；一键跳末/连续单步后十字才有区间；冷启重载配置后背驰率应为 1.0

---

### 2026-08-07 — 背驰 MACD 四算法差异化高亮（area/peak/full_area/diff）

- **要点**：理清四算法对 MACD 柱的贡献差异后，十字 asOf 下按实际贡献柱高亮（不再整段 lo–hi 糊满）；peak 另描峰值。勾任一 MACD 类背驰自动叠同号 MACD。
- **相关路径**：`divergence_compute.dart`、`divergence_algo.dart`、`chart_indicator.dart`、`kline_chart.dart`、`msg_history.dart`、`divergence_compute_test.dart`
- **注意**：area=端点同号连续；peak/full_area=整段同向；diff=整段全非空。旧 span 缺 begin/end/dir 需重步进。

---

### 2026-08-07 — Kn背驰_slope 副图高亮比较 Kn 整段

- **要点**：十字 asOf 下，Kn背驰_slope 副图用蓝/琥珀条带高亮 in/out 两段整 Kn 区间（slope 吃几何整段，非 MACD 贡献子集）。
- **相关路径**：`kline_chart.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：依赖 DivergenceFreezeStore.span；与 MACD 类高亮配色一致

---

### 2026-08-07 — 新增 Kn背驰_斜率（与连线斜率同源）

- **要点**：13 算法；力度=`|(endVal-beginVal)/(endX-beginX)|`（冻段 endConfirmX；active 随 asOf）；取绝对值做 ratio；副图整段蓝/琥珀高亮。旧 `slope` 保留。
- **相关路径**：`divergence_algo.dart`、`adjacent_ratio_compute.dart`、`divergence_compute.dart`、`kline_chart.dart`、`msg_history.dart`
- **注意**：K0 无连线段不写斜率背驰；勿与旧 slope（振幅摊平）混淆

---

### 2026-08-07 — 全体背驰副图整段高亮（补 amp/成交量/RSI 等）

- **要点**：十字 asOf 下，所有 Kn背驰_* 副图均蓝/琥珀高亮比较两段整 Kn；此前仅 slope/斜率。MACD 四算法仍额外在 MACD 副图按贡献柱高亮。
- **相关路径**：`kline_chart.dart`、`divergence_algo.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：依赖 DivergenceFreezeStore.span

---

### 2026-08-07 — KnDemark 同柱上下排 + 买卖/类型分色

- **要点**：同 K0 多标记改为上下排列（setup 上、countdown 下）；买(dir<0)红/橙、卖(dir>0)绿/青，setup 加粗。
- **相关路径**：`kline_chart.dart`、`bar_feature_lookup.dart`、`msg_history.dart`
- **注意**：十字 tip 仍空格拼接；配色不跟层色

---

### 2026-08-08 — KnDemark 主图标注 + 设置三项（宽松Countdown/完美9/反向打断）

- **要点**：Demark 从副图迁主图，锚 K0 低点垂直排 S/C 与「完成买/卖」（Setup9 与 Countdown13 均算完整信号）。设置增加 Countdown 宽松/原版严（默认宽松）、完美9（默认关）、反向 Setup 打断 Countdown（默认严=打断）。
- **相关路径**：`demark_compute.dart`、`math_indicator_config.dart`、`chart_indicator.dart`、`kline_chart.dart`、`main.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：旧会话若仍勾副图 Demark 会被 prune；需在主图「Kn指标」打开 Demark（默认静音）

---

### 2026-08-08 — 延伸线 asOf 截断 / 清 Demark 副图枚举 / 删 turnrate 背驰 / 桶宽进 Math 输入框

- **要点**：三型/四型/趋势线射线十字下截到 asOf；删除 `SubIndicatorKind.demark`；背驰去掉 turnrate_avg（12 算法）；筹码桶宽从拉条迁入「数学指标参数」输入框（最小 0.01，笔数分布共用）。
- **相关路径**：`kline_chart.dart`、`chart_indicator.dart`、`divergence_algo.dart`、`divergence_compute.dart`、`main.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：旧会话若勾过背驰_turnrate 会被 prune；桶宽仍落盘筹码配置

---

### 2026-08-08 — 方案B：结构层 0 起编，消除 displayKn↔level +1 双轨

- **要点**：Rust 首层 `level==0`（K0连线）；中枢/BS 帧 `level=structure+1` 避 zs_k0 撞号。Flutter 连线族 `kn==displayKn`；中枢/Math/BS 的 K1+ 取 `structure==kn-1`；`collect*ByKn` 写 `out[lv.level+1]`。已重编并覆盖 `chan_ffi.dll`。
- **相关路径**：`pipeline.rs`、`zs.rs`、`chart_indicator.dart`、`kline_chart.dart`、各 `*_compute.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：旧会话勾选 kn 语义漂移需冷启动；趋势线/节奏仍看父层 `displayKn+1`（非旧偏移尾巴）

---

### 2026-08-08 — 设置增加「复制调试信息」（例1–例5审计探针）

- **要点**：设置面板常驻按钮，一键复制例1（K1合并 tip/主图层号）、例2（asOf vs 会话计数）、例3（一类BS x）、例4（三型/四型上界）、例5（bar_features 缺 zs/BS）核对文本，便于粘贴验证猜想。
- **相关路径**：`CHAN_RUST/flutter/chan_kline/lib/history/audit_probe_snapshot.dart`、`main.dart`、`msg_history.dart`
- **注意**：建议跳末后点；会多次前缀 FFI；与「复制页面快照」并存，勿当临时调试删

---

### 2026-08-08 — 审计修复例1/2/4/5（K1合并同源·asOf禁回落·三型上界·zs进lookup）

- **要点**：tip「K1合并」改与主图 `k1CombineFrames` 同源；十字 asOf 下 lookup 禁回落会话 levels；三型/四型特征上界=structureMax；lookup.sub 写入 zs_*（BS 仍会话历史）。例3本样本未漂未改 Rust。
- **相关路径**：`bar_feature_lookup.dart`、`kline_chart.dart`、`audit_probe_snapshot.dart`、`msg_history.dart`、`bar_feature_lookup_test.dart`
- **注意**：热重载后跳末→十字 idx=12 看 tip K1合并；再点「复制调试信息」应见 OK_FIXED

---

### 2026-08-08 — BS x冻结 / sure中枢禁改写 / bar_features.zs·bs1 / tip类上界

- **要点**：Rust 钉死一类/二类 discovery x；`try_combine` 跳过已 `is_sure`；`bar_features` 增 `zs_hits`/`bs1_hits`；tip 三类+跟 `maxBsClass`。「复制调试信息」改绑本轮 A/B/C/D 验收。须重编 `chan_ffi.dll`。
- **相关路径**：`pipeline.rs`、`zs.rs`、`feature.rs`、`combine.rs`、`bar_crosshair_feature.dart`、`bar_feature_lookup.dart`、`audit_probe_snapshot.dart`
- **注意**：冷启后跳末→复制调试信息看判定；flutter run 占用 DLL 时先 `q` 再跑 `build_rust.ps1`

---

### 2026-08-08 — build_rust.ps1 编完后自动 flutter run -d windows

- **要点**：`CHAN_RUST/scripts/build_rust.ps1` 在复制 `chan_ffi.dll` 后进入 `flutter/chan_kline` 执行 `flutter run -d windows`。
- **相关路径**：`CHAN_RUST/scripts/build_rust.ps1`
- **注意**：脚本会先杀占用中的 `chan_kline`；`flutter run` 占住该终端

---

### 2026-08-08 — 本批：探针A/D·Peak·末枢sure·口径文案·asOf bundle

- **要点**：复制调试信息改验本批；A改会话+bar_features；D实扫 tip 最高类键（中文类名扩到二十）；Rust Peak 按 DD/GG 合并；删无 active 强制末枢 is_sure；N类每成员/1Ba锁/k1_*=structure0 落注释与历史；十字 painter 直接传 asOfBundle.levels/k0/zsK0。
- **相关路径**：`zs.rs`、`pipeline.rs`、`audit_probe_snapshot.dart`、`kline_chart.dart`、`msg_history.dart`、`chart_indicator.dart`
- **注意**：须重编 `chan_ffi.dll` 后冷启；跳末→复制调试信息看 A/D/E/F/G/H

---

### 2026-08-08 — A探针修：K0 bs1_hits 写入 bar_features

- **要点**：验收贴文 A=`BUG_无bs1_hits` 因会话 kn=0 而结构层 hits 无 K0。`run_pipeline` 逐K补写 K0 zs/bs1（discovery 冻结）；探针改取全层最早 x。D/E/F/G/H 已通过。
- **相关路径**：`pipeline.rs`、`audit_probe_snapshot.dart`
- **注意**：须重编 DLL 冷启后再点「复制调试信息」看 A

---

### 2026-08-08 — 本批验收通过（A/D/E/F/G/H）

- **要点**：用户贴文确认 A=`OK_FIXED`（K0 bs1_hits x=2）、D tip 十一类、E Peak 已接线、F 虚线末枢、G 口径、H asOf 段数差；本批结案。
- **注意**：Peak 默认仍为 zs；UI 切 peak 需传 `zs_config.zs_combine_mode=peak`

---

### 2026-08-08 — tip三类分桶 + Kn节奏迁主图（价轴）

- **要点**：十字 tip 层内拆三类（背驰 / 比例+节奏 / 其它指标）；Kn节奏从副图干净迁主图（`MainIndicatorKind.stepRhythm`，挂节奏投影价，进 Kn指标、默认静音）；「复制调试信息」改绑本批 T1/T2。
- **相关路径**：`chart_indicator.dart`、`bar_feature_lookup.dart`、`kline_chart.dart`、`audit_probe_snapshot.dart`、`msg_history.dart`、`AGENTS.md`
- **注意**：冷启后跳末→复制调试信息看 T1/T2；主图 chip 点开节奏才绘制

---

### 2026-08-09 — 【口径】Kn节奏关窗持值（全层同构）

- **需求**：升组子顶关窗后、子底确认前继续用上个 x-x；锚点分笔·K1·K0 77–114 续 0-0；tip 同源；复制调试信息仅本批。
- **变更**：`StepRhythmState.holdLines`；关窗 `holdStepRhythmFromCache`；开窗刷新模板；父切组清缓存；探针 T1/T2 改绑持值+tip。
- **验证**：`adjacent_ratio_step_rhythm_test` 持值/切组清缓存通过。
- **注意**：冷启跳末→复制调试信息看 T1/T2。

---

### 2026-08-09 — 本批验收通过（T1 tip三类·T2 节奏主图）

- **要点**：用户贴文确认 T1=`OK_FIXED`（背驰/比例+节奏/其它序与 `-。-` 分隔、混桶=N）、T2=`OK_FIXED`（main节奏 kn=0..4、副图无残留、层全选/默认静音）；本批结案。
- **注意**：主图 chip 点开「Kn节奏」才绘制（默认静音）

---

### 2026-08-09 — Kn节奏关窗持值（全层同构）

- **要点**：子反向分型关窗后、下一同向分型确认前，持上个 x-x 原值逐K写入会话历史（升：顶关→底前；降镜像）；再开窗恢复实时；父切组清 holdLines。主图/tooltip 同源；「复制调试信息」改绑 T1 持值（分笔·K1·77–114 续 0-0）·T2 tip 同源。
- **相关路径**：`step_rhythm_compute.dart`、`audit_probe_snapshot.dart`、`msg_history.dart`、`main.dart`、`AGENTS.md`
- **注意**：冷启跳末→复制调试信息看 T1/T2；主图 chip 点开「Kn节奏」才绘制

---

### 2026-08-09 — 探针 T2 改按 tip 三位小数同源比对

- **要点**：T1=`OK_FIXED`；T2 误报因 hist 全精度 vs tip `toStringAsFixed(3)`。探针改为与 tip 同口径比三位小数字符串。
- **相关路径**：`audit_probe_snapshot.dart`
- **注意**：热重载/冷启后再点「复制调试信息」看 T2

---

### 2026-08-09 — 本批验收通过（T1 K1节奏持值·T2 tip同源）

- **要点**：用户贴文确认 T1=`OK_FIXED`（分笔·K1·77–114 续上个 0-0，ok=38）、T2=`OK_FIXED`（tip【11.726】与 hist3 同源）；本批结案。
- **注意**：主图 chip 点开「Kn节奏」才绘制（默认静音）

---

### 2026-08-09 — ML 分支：设置入口 + 图面使用权交接 + JSONL 导出

- **要点**：新建分支 `ML`；设置「机器学习」进入后图面由 `MlWorkbench` 占用（预览只读），退出归还复盘；只读导出 `schema_version=1` JSONL 至 `ml_exports/`，不改 tip/`BarFeatureLookup` 生产逻辑。
- **相关路径**：`lib/ml/*`、`main.dart`、`msg_history.dart`、`docs/ML_FEATURE_SPEC.md`、`test/ml_feature_export_test.dart`
- **注意**：进入前需已步进；禁止 tip 动态行名作键

---

### 2026-08-09 — ML 新手成果页：自动加载跳末 + tip 分类打分

- **要点**：设置选好标的后点「机器学习」即自动加载并完整跳末；成果整页展示总分/教学建议/8 类 tip 打分卡 + K 线小预览；可选导出 JSONL；图面使用权进出交接不变。
- **相关路径**：`lib/ml/ml_rule_score.dart`、`ml_workbench.dart`、`main.dart`、`docs/ML_FEATURE_SPEC.md`、`test/ml_rule_score_test.dart`
- **注意**：规则评分非训练模型；计算走 `_runToEnd` 不省略逻辑

---

### 2026-08-09 — K0一类BS机器学习闭环（对齐 Vespa demo5/6）

- **要点**：ML 改为事件样本：完整跳末采 K0 一类 BS 当下 tip 同源特征→α label（末态集合√/× + K0连线高低极值）→导出 libsvm/meta；Rust FFI `chan_ml_predict` 加载外部 model.json；成果页替换规则打分。
- **相关路径**：`lib/ml/ml_bsp_*`、`ml_workbench.dart`、`main.dart`、`chan_data/ml_predict.rs`、`chan_ffi`、`docs/ML_FEATURE_SPEC.md`
- **注意**：需重编并覆盖 `chan_ffi.dll` 后预测才可用；模型可用 `chan_ml_v1` 权重 JSON

---

### 2026-08-09 — ML成果页：无K线图 + 训练/考试集可设置可看

- **要点**：ML 主区不再挂 K 线；后台取数采 K0 一类 BS 后按时间序切分训练/考试（默认70/30，滑条可调并即时重切）；成果页默认考试集α准确率与样本列表，导出 train/exam libsvm + 考试报告，模型预测后显示考试准确率。
- **相关路径**：`lib/ml/ml_workbench.dart`、`ml_dataset_split.dart`、`ml_split_config.dart`、`ml_bsp_export.dart`、`main.dart`、`docs/ML_FEATURE_SPEC.md`
- **注意**：后台仍 `_loadKlines` 算特征，只是 UI 不展示图

---

### 2026-08-09 — ML当前阶段：先设切分再加载，考试集看经验胜率

- **要点**：进 ML 先设训练/考试比例，点「加载」显示进度；用训练集拟合经验应用到考试集；结果含经验胜率/基准胜率/准确率/覆盖率/买卖侧；本阶段去掉导出与外部模型加载，只基于当前股票、不展示K线。
- **相关路径**：`lib/ml/ml_experience_trainer.dart`、`ml_workbench.dart`、`main.dart`、`docs/ML_FEATURE_SPEC.md`
- **注意**：经验=内存逻辑回归；经验胜率=采纳且α=√ / 采纳数

---

### 2026-08-10 — ML修正：训练/验证/测试时序三截 + 仅验证调参

- **要点**：按样本 x 严格前→后切训练|验证|测试；网格超参只在验证集选；锁参后测试集只评估一次；UI 默认报测试经验胜率，并展示调参摘要。
- **相关路径**：`ml_dataset_split.dart`、`ml_split_config.dart`、`ml_experience_trainer.dart`、`ml_workbench.dart`、`main.dart`、`docs/ML_FEATURE_SPEC.md`
- **注意**：禁止用测试集调参；样本不足 3 条时验证可能为空并跳过调参

---

### 2026-08-10 — ML收紧：展望窗α + 测试锁定 + 漂移报告

- **要点**：α改为发现后固定展望窗内用当步live一类与asOf截断极值打标（禁跳末末态）；测试评估成功后锁定不可改比例重跑；结果页增加三截标签√率与特征漂移告警。
- **相关路径**：`ml_bsp_labeler.dart`、`ml_label_config.dart`、`ml_drift_report.dart`、`ml_workbench.dart`、`main.dart`、`docs/ML_FEATURE_SPEC.md`
- **注意**：锁定仅防同会话窥探；单票过拟合仍在

---

### 2026-08-10 — 跑通特征价值评估（002003 1m）

- **要点**：对 002003 两日 1m（465根）采 K0一类样本275、特征维416；测试准确率74.5%、经验胜率66.7%但仅采纳6条；漂移告警；结论=有弱信号但不值得整包 tip 特征当主力。
- **相关路径**：`test/ml_feature_worth_eval_test.dart`
- **注意**：复跑：`flutter test test/ml_feature_worth_eval_test.dart`

---

### 2026-08-10 — ML特征数值化：BS/节奏/Demark 编码

- **要点**：tooltip 字符串汇总保留；BS 追加 `*_code`、节奏追加 `labelInt`、Demark 追加 `demark_marks` 结构化数组；`mean_text_/channel_text_/demark_text_/buy*_N` 展示键禁入 flatten（去 `__has` 冗余）。
- **相关路径**：`lib/ml/ml_bs_code.dart`、`bar_feature_lookup.dart`、`ml_feature_schema.dart`、`ml_feature_label.dart`、`msg_history.dart`
- **注意**：不改 Rust；验收 `flutter test test/ml_bs_feature_code_test.dart`

---

### 2026-08-10 — 节奏 ML：补 dirInt + 禁 label/dir 字符串

- **要点**：核实 BS `*_code` 已就绪；节奏 `dir` 实为 up/down 字符串会 flatten 成 `__has` 丢方向，现写 `dirInt`；schema 禁 `step_rhythm_lines_*[.label|.dir]`（匹配含 `sub.` 全路径）与 `step_rhythm_N`。
- **相关路径**：`bar_feature_lookup.dart`、`ml_feature_schema.dart`、`ml_feature_label.dart`、`msg_history.dart`、`test/ml_bs_feature_code_test.dart`
- **注意**：答复2 建议的 `^step_rhythm_…\.label$` 匹配不到 `sub.` 前缀，已改为无锚前缀的后缀匹配

---

### 2026-08-10 — XGB 训推：Python 训 + Rust 推（纠偏落地）

- **要点**：新增 `ml_train_xgb.py`（0-based CSR、valid early stop、sidecar 绑 meta/schema）；Flutter `MlXgbTrainer`+工作台 LR/XGB 切换；验证选阈值、测试锁定与 LR 同口径；Rust `ml_predict` 读 `default_left`。
- **相关路径**：`ml_train_xgb.py`、`ml_xgb_trainer.dart`、`ml_workbench.dart`、`main.dart`、`ml_predict.rs`、`msg_history.dart`
- **注意**：打包 `pyinstaller ml_train_xgb.spec` 拷到 `windows/native/`；无 EXE 可回退 `python ml_train_xgb.py`；改 Rust 后需重编覆盖 `chan_ffi.dll`

---

### 2026-08-12 — 一/二类BS 标签 V2.1

- **要点**：一类恢复等高/等低递增（`1Ba→1Bb→1Bc…`/`1Sa→1Sb…`）；严格新极值仍复位为 `a` 并更新 box 参照。二类改为仅标严格更高低点/更低高点（`2Ba…`/`2Sa…`）；等高/等低不再产生二类，消除同价 `1B*+2B*` 双标。
- **涉及文件**：`buy1.rs`（`find_buy1_with_active`/`find_sell1_with_active` 区分新极值 vs 等高确认）；`buy2.rs`（等高 `continue`、仅严格更高/更低标二类）；Rust 测试 V2.1 验收场景；`AGENTS.md`/`msg_history.dart`/`TASK_LOG.md`。
- **不变**：`mark_x`、冻结/merge 双键、ML α 判定、`buy_n.rs`、`approx_eq`、FFI 结构。
- **Flutter/ML**：`MlBsCode` 已支持 `1Bb/1Bc/2Sc` 等单字母后缀；无硬编码仅认 `1Ba` 的显示逻辑需改。
- **注意**：改 Rust 后须重编并覆盖 `chan_ffi.dll`；连续单步验收。

---

### 2026-08-13 — 【口径】Lookup 增量化（仅 profiling+设计，未实现）

- **需求**：消除每步 `BarFeatureLookup.build` 全量重建；不改 Rust/Delta/History/asOf/BS。
- **测量**：`phase2b3_lookup_profile_test`。N=2000 末步 Lookup≈5.5s（占 96%），mergeDelta≈0；Painter 每帧 2 次 build。Lookup 随 N 超线性。
- **设计**：`docs/PHASE2B3_LOOKUP_INCREMENTAL_DESIGN.md` 方案 A（增量 Lookup 挂 cache，只写脏区间）。**等待批准**。

---

### 2026-08-13 — 【口径】Flutter 接入 PipelineDelta（presentation cache）

- **需求**：步进走 `chan_pipeline_append_delta`；Flutter 建 presentation cache + `mergeDelta`；Full Snapshot 仅首包/回退/asOf。
- **不变**：Rust 算法、Delta 语义、Lookup 填表算法、History/asOf/V2.1 BS；不做二进制/字段级 patch/ZS-BS 优化。
- **变更**：`PipelineDelta`/`PresentationCache`；`ChanPipelineSession` 首包 Full、其后 Delta；旧 DLL 无符号则全程 Full。
- **验证**：`pipeline_delta_session_test` 全过。002003 step24–28 Full==Delta；reset+replay；asOf；History/BS/副图/十字/ML。N=200 末步 Delta≈Full 的 31%。报告 `docs/PHASE2B3_FLUTTER_DELTA_REPORT.md`。
- **注意**：须重编并复制 `chan_ffi.dll` 后冷启。

---

### 2026-08-13 — 【口径】PresentationCache 增量 Lookup（Phase 2B-3A）

- **需求**：消除每步 `BarFeatureLookup.build` 全历史重建（N=2000 Lookup≈5.5s / 96%）；Painter 不得重复建 Lookup。
- **不变**：Rust / Delta / FFI / 算法 / History / asOf 语义 / mark_x / V2.1 BS；Full `build()` 保留黄金参考。
- **变更**：`IncrementalBarFeatureLookup` + `PresentationCache.syncLookup`；热路径 `applyStep`；三型只算当前 x；asOf 视图短前缀 Math + 冻格。KlineChart / ML 复用 `lookupEngine`。
- **验证**：`incremental_lookup_session_test` 全过（002003 step24–28 Incremental==Full、reset+replay、asOf 24–28）。N=2000 FullLookup=6259ms / Incremental=1048ms（6.0x）；Full 随 N 增 26.4x，Incremental 6.2x。报告 `docs/PHASE2B3_INCREMENTAL_LOOKUP_REPORT.md`。
- **注意**：不进 Phase 2C；冷启后连续单步验收。

---

### 2026-08-14 — 【口径】全类 BSP 在线对错（Pending/Correct/Wrong）

- **需求**：对 CHAN_RUST 当前能产生的全部 BSP（1…n B / 1…n S）建立统一在线对错；不改 BSP 生成；K0…KN 同一 judge；无未来、终态冻结；供后续 ML label；副图错标可叠加 X（设置开关）。
- **不变**：buy1/buy2/buy_n 判点规则、mark_x、会话双键冻结、旧 `ml_bsp_sample.isCorrect` 展望窗 α（隔离，不删）。
- **语义（继承既有结构，不发明止盈止损）**：
  - 全类成功/失败：后续 **已定型** 中枢 `zs_above_prev` / `zs_below_prev`（买上移成功、卖下移成功；镜像失败）。
  - 一类/二类额外失败：同框严格新极值（一类破自身价；二类破当时 box 极值，不是 2B 自身价）。
  - 三类+：代码无独立极值语义（同框全员打点），不套一类极值失败。
- **变更**：`chan_data/src/bs_eval.rs`；`LevelBundleOut.bs_verdict_frames` + `bs_verdict_k0_frames`；pipeline/combine/delta；Flutter 接收冻结 + asOf + 设置「BSP对错叠加X」。
- **验证**：`cargo test -p chan_data --lib bs_eval` 全过（全类 1..8 × 买卖 × Correct/Wrong × K0/K1/K2、冻结、无未来、不回写）。
- **注意**：须重编并复制 `chan_ffi.dll` 后冷启；连续单步验收。**同日已被「离开事件语义」修正：三类+不再只能等后续定型 ZS。**

---

### 2026-08-14 — 【口径】BSP 在线对错：离开事件语义（不再只等后续中枢升降）

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

---

### 2026-08-14 — 【审计】Flutter 十字 tooltip 全量审计诊断记录

# CHAN_RUST Flutter 十字 tooltip 全量审计诊断记录
日期：2026-08-14  
审计对象：`flutter/chan_kline` 十字 tooltip（`kline_chart._tooltipRowsForBar` → `BarFeatureLookup.build` / `crosshairTooltipRows` + `zsCrosshairTooltipRows` + `classifyProfilePeaks` + `chip_profile_compute` / `tick_dist_profile_compute`）  
审计方法：静态只读代码走查（本机无 Flutter/Dart 工具链，未新增可运行测试代码；如后续补测，按约定测完即删）。  
判定四原则：① 全层同构（K0/K1…/KN 同口径同冻结）② 不使用未来数据（as-of 截断）③ 不回写数据（会话历史/冻结仓，写入即冻结）④ 设计思路一致（应显尽显、同源同口径）。

---

## 0. 数据流信任链（自上而下）
1. `_tooltipRowsForBar`（kline_chart.dart:755-868）
   - `asOf = _crosshairEnabled && _crosshairBarIdx!=null ? _crosshairAsOfIdx() : null`（:762）
   - `asOfBundle = _bundleForZsAsOf(asOf)`（:765）
   - 十字开启时：`tipLevels = asOfBundle?.levels ?? const []`、`tipK0Confirms = asOfBundle?.k0Confirms ?? const []`、`tipZsK0 = asOfBundle?.zsK0Frames ?? const []`（:798-806）——**失败=空，禁回落末态**。
   - 所有 `*HistoryByKn` 一律传 `widget.*`（会话冻结历史），**不现场重算**（:818-831）。
   - `cut = asOf ?? bar.idx`（:841）→ 筹码/笔数峰 `cutoffX: cut`（:846,855）。
2. `BarFeatureLookup.build(... asOf: asOf, ...)`（bar_feature_lookup.dart:101-1009）—— 主体写入 `byIdx`。
3. `crosshairTooltipRows(idx,...)`（bar_feature_lookup.dart:1158）从 `byIdx[idx]` 读数并装配。

**关键结论**：进入 `build` 的 `levels`/`k0Confirms`/`zsK0Frames` 在十字态已由 Rust `asOfBundle` 截断；其余 sub 系列全部经 `maxX: asOf` 的 `expand*ToSeries` 或 `compute*ForLevel(..., asOf)` 或冻结仓截断。信任链闭合。

---

## 1. 逐项检查结果（按 tooltip 展现顺序）

### A. 表头 & K0 核心块（:1205-1266）
| 信息 | 取值来源 | ①同构 | ②无未来 | ③不回写 | ④一致 | 证据 |
|---|---|---|---|---|---|---|
| 日期时间+星期 | `barFeatures[idx]` | — | ✅ | ✅ | ✅ | :1168,`weekdayToW` |
| K0 idx | `row['idx']` | — | ✅ | ✅ | ✅ | :1206 |
| K0 (OHLC) | 当前根 `open/high/low/close` | — | ✅ | ✅ | ✅ | :1209 |
| K0成交量(B/S/G) | `sub['volume_0']`/`buy_volume_0`…（K0=原生 bars 点值） | ✅ | ✅ | ✅ | ✅ | :1177-1179,`computeAllKnVolumeSeries` |
| K0笔数(B/S/G) | `sub['tick_count_0']`…（点值） | ✅ | ✅ | ✅ | ✅ | :1183 |
| K0筹码峰 / K0笔数峰 | `classifyProfilePeaks` + `ChipProfileCompute.compute(cutoffX:cut)` | — | ✅ | ✅ | ✅ | :843-851,见 G |
| K0合并 GG/DD/MG/MD | `combineFrames`（十字=`_effectiveK0CombineFrames`=asOfBundle.frames） | ✅ | ✅ | ✅ | ✅ | :1228-1234,见 B |
| K0合并K0 idx / 合并 idx | `barFeatures.mergeInnerSeq/mergeBoxSeq`（逐根口径） | ✅ | ✅ | ✅ | ✅ | :1236-1238 |
| K0分型确认 | `k0_confirm`（按 `sig.x` 写，非未来） | ✅ | ✅ | ✅ | ✅ | :303-318 |
| K0分型判断 | `fractal_judgment_0`（judgmentHistoryByKn 展开 `maxX:asOf`） | ✅ | ✅ | ✅ | ✅ | :626-652 |
| K0中枢 rows (zsAfterK0) | `zsCrosshairTooltipRows(asOfBundle)` | ✅ | ✅ | ✅ | ✅ | 见 C |

### B. K0 合并框写入（build:220-244）— 结构依赖注意
- 该循环本身**无显式 `asOf` 守卫**，但对所有 `x∈[f.x1,f.x2]` 写 `row['combine']`。
- 安全性来自：`combineFrames = _effectiveK0CombineFrames`（kline_chart.dart:638），十字态返回 `asOfBundle.frames`（Rust 已截断），**失败=`const []`**（禁末态框）。故 `f.x2 ≤ asOf`，循环不会覆盖未来根。
- **状态：合规（有结构依赖，见第 3 节脆弱点 1）。**

### C. 中枢 rows（zs_compute.zsCrosshairTooltipRows + computeZsFramesAtAsOf）
- `asOf!=null` 时要求 `asOfBundle` 非空，否则 `const []`（禁回落末态）；逐框 `if (asOfIdx < f.x1 || asOfIdx > f.x2) continue`（kline_chart 侧与 zs_compute 侧双重截断）。
- 输出 GG/DD/ZG/ZD、`K{kn}中枢K{kn} idx`、`seq`、`上一中枢确认`（仅首根）。
- **状态：✅ 四原则全过。**

### D. K0 层内类别 `_levelCategoryExtras(idx,0)`（:1703-1936）
读 `sub` 中已由 build 截断写入的值：
| 类别 | 键 | 截断来源 | 状态 |
|---|---|---|---|
| fxExtra | `fractal_peak_dist_0`、`K0截断` | `barFeatures` / `level_confirms`（:1722,:1730-1745） | ✅ |
| bs | `buy1_0/sell1_0`、`buy2_0/sell2_0`、`buyN_0_cls` | 会话历史 `expand*LabelsToSeries(maxX:asOf)`（:460-605） | ✅ 不回写 |
| divergence | `K0背驰_*`(12 算法) | 冻结仓 `truncateDivergenceMap(asOf)` 或 `computeDivergenceForLevel(asOf)`（:942-954） | ✅ |
| ratioRhythm | `adjacent_ratio_0`、`step_rhythm_0/0-0…` | `expandAdjacentRatioToSeries(maxX:asOf)` / `stepRhythm` 循环 `if(asOf!=null && b.idx>asOf) continue`（:684-719） | ✅ |
| otherMath | 斜率/三型/四型/趋势线/均线/通道/MACD/布林/RSI/KDJ/Demark | 全部 `compute*ForLevel(asOf)` 或冻结仓，循环 `if(asOf!=null && b.idx>asOf) continue`（:746-982） | ✅ |

### E. Kn 块 `K{n}`（n≥1，`_levelBlockRows`:1498-1571）
- `snap.level == n-1`（方案B，`totalLevels` 上界）（:1510-1518）。
- 核心：`snap.unitIdx/OHLC/volume/tick`（来自 asOfBundle 冻结段，点值，无未来）。
- 合并 GG/DD：`combine_range_high_$displayKn`（:269-301，循环无显式 asOf 守卫，但 `levels=tipLevels=asOfBundle` → snaps 已 bounded，见脆弱点 2）与 `combine_box_$displayKn`（:248-258，**有 `if(asOf!=null && x>asOf) continue` 守卫**）。
- 合并 K{n} idx：`snap.mergeInnerSeq/mergeBoxSeq`（asOf 段口径）。
- 分型确认/判断：`level_confirms[displayKn]`（由 `tipLevels.confirms` 建，:202-205、:169-175）+ `fractal_judgment_$n`（maxX:asOf）。
- **状态：✅ 四原则全过（合并 GG/DD 依赖脆弱点 2，非当前违规）。**

### F. Kn 层内类别
同 D 表，键为 `K{n}*`、`displayKn=n`；BS/背驰/比例节奏/斜率/三型/四型/趋势线/均线/通道/MACD/布林/RSI/KDJ/Demark 全部 `sub['*_$n']`，写入路径见 D 的 build 段（maxX:asOf 或冻结仓或 asOfBundle）。**✅ 全过，且与 K0 同源同口径（全层同构）。**

### G. 筹码峰 / 笔数峰
- `ChipProfileCompute.compute(bars, cutoffX:cut)` → `_prefix.profileAt(cutoffX)` 二分 `deltas[mid].idx <= cutoffX` 仅累加截止 as-of（chip_profile_compute.dart:396-433）。
- `TickDistProfileCompute.compute` → `if (bar.idx > cutoffX) break;`（tick_dist_profile_compute.dart:35-38）。
- `classifyProfilePeaks` 仅按当前根 low/high 分类（profile_peak_classify.dart），时间截断在上游已保证。
- **状态：✅ 四原则全过（仅 K0 显示，符合 AGENTS「筹码仅 K0」口径，非违规）。**

---

## 2. 四象限判定汇总
| 原则 | 结论 | 范围 |
|---|---|---|
| ① 全层同构 | **PASS** | K0/K1…/KN 共用 `build` → `crosshairTooltipRows` → `_levelCategoryExtras`；键 `K{kn}*` 统一；方案B `displayKn=level+1`；连线族 `level==displayKn`、趋势线 child=displayKn/parent=displayKn+1；背驰同号 `displayKn`。 |
| ② 不使用未来数据 | **PASS** | 十字态 `levels/k0Confirms/zsK0Frames` 经 `asOfBundle` 截断；所有 sub 经 `maxX:asOf` 或 `compute*ForLevel(asOf)` 或冻结仓截断；筹码/笔数峰 `cutoffX=asOf`；`expand*ToSeries` 均含 `if(maxX!=null && e.x>maxX) continue`。 |
| ③ 不回写数据 | **PASS** | BS/判断/中枢信号/ZS 信号全部来自会话历史（`widget.*HistoryByKn`）展开，写入即 `maxX:asOf` 冻结；数学/背驰用 `MathSeriesFreezeStore`/`DivergenceFreezeStore` 首非空冻结，参数变更清空重冻；无「整表重算消点」。 |
| ④ 设计思路一致 | **PASS** | tooltip「应显尽显、按层不按勾选」与 AGENTS 口径一致；BS 1..9 类全显、筹码仅 K0、中枢全层输出均符合既定设计；无与多数指标相悖的特例分支。 |

**未发现任何违反四项原则的信息项。**

---

## 3. 潜在脆弱点 / 设计注意（非当前违规，建议记入口径）
1. **K0 合并框写入循环（build:220-244）无显式 `asOf` 守卫**，安全性完全依赖 `_effectiveK0CombineFrames` 在十字态返回 `asOfBundle.frames`。若将来该函数改回 `widget.combineFrames`（末态）作为十字 fallback，将泄漏未来合并框。建议在循环内补 `if (asOf != null && x > asOf) continue;` 作为双保险（与 :248-258、:262 一致）。
2. **`combine_range_high_$displayKn` 计算循环（build:269-301）无 `asOf` 守卫**，安全性依赖 `tipLevels=asOfBundle`。同脆弱点 1，建议在写入 `row['combine_range_*']` 前加 `if (asOf != null && b.idx > asOf) continue;`（虽然当前因只读取 `bar.idx==asOf` 不会外显未来，但属隐式安全）。
3. **非十字态（asOf==null）** 使用 `widget.levels`（末态）与全量 `cut`，属「完整末态视图」，无未来概念（数据仅到末根），符合预期；但注意该路径下 `combineFrames=widget.combineFrames` 为末态框，与十字态行为不同——这是设计分层，非违规。

---

## 4. 测试代码说明
本机无 Flutter/Dart 工具链，本次为纯静态走查，**未新增任何测试代码**，故无需清理。如用户后续要求在 CI/本机补单测验证 as-of 截断，建议在 `test/` 下新建临时用例，测完按约定删除。

---

## 5. 结论
十字 tooltip 的全部信息项（表头、K0 核心、K0 合并、中枢 rows、K0/Kn 层内 fxExtra/BS/背驰/比例节奏/其它数学、筹码峰/笔数峰）**均满足全层同构、不使用未来数据、不回写数据、设计思路一致四项原则**。仅发现 2 处「依赖上游 asOfBundle 截断而非显式守卫」的隐式安全点，建议补守卫以消结构依赖，属健壮性增强而非缺陷修复。

---

### 2026-08-15 — 【口径】连线斜率背驰特征键 ASCII（line_slope）

- **需求**：ML 特征键不再混入汉字「斜率」；算法本身保留（与 Kn连线斜率同源）。
- **不变**：计算公式、冻结仓、副图芯片/十字显示名仍为 `K{n}背驰_斜率`；旧 `slope`（振幅摊平）不动。
- **变更**：`DivergenceAlgo.lineSlope.key`=`line_slope`；新增 `labelSuffix`=`斜率` 给界面；`diver_line_slope_*`；ML 中文名「连线斜率」vs 旧 slope「振幅摊平」。`schema_version` 仍为 1。
- **验证**：`divergence_compute_test` catalog 显示名 + ASCII 键；`ml_feature_label_test`。
- **注意**：纯 Flutter；无需重编 DLL。旧 `feature.meta` / 旧模型须重导出并重训。

---

### 2026-08-15 — 【口径】Phase4 策略回测工作台

- **需求**：配置策略 → 调用现有回测核心 → 图上策略点 → 报告；Flutter 不重算条件/指标/收益。
- **配置**：第一版只选层号；买=该层收盘下穿该层布林下轨，卖=该层收盘上穿该层布林上轨。同层同钟门禁；选不出 K0收盘×K1布林。
- **运行**：`BacktestRun` 记下 strategyConfig、数据范围、engineVersion、runId。
- **图**：主图覆盖「策买/策卖」，只画 `BacktestResult.signals`，与 1Ba/1Sa 分离。
- **报告**：净利润/收益率/胜率/盈亏比/Profit Factor/最大回撤、净值与回撤曲线、交易明细、信号→订单→成交链路。点交易跳入场/再点出场；点图上策略点打开链路。
- **验证**：`flutter test test/backtest_workbench_test.dart test/backtest_result_test.dart test/mini_loop_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。未做做空/加仓/优化/新指标。

---

### 2026-08-15 — 【口径】Phase3 回测结果引擎（Equity + PnL + 核心绩效）

- **需求**：一次接完逐K0净值、回测结果对象、收益/交易质量/最大回撤/连续盈亏、未平仓语义。不做 Flutter 回测 UI。
- **净值**：每根 K0 记 cash / positionQty / positionValue / equity / realizedPnL / unrealizedPnL；`equity = cash + qty × close`。持仓计入浮盈。
- **结果**：`BacktestResult` = signals / orders / fills / trades / equityCurve / metrics；`closedTrades` 与 `openPosition` 分开。
- **收益**：`netProfit = finalEquity - initialCapital`。
- **交易质量**：胜率、毛盈亏、均盈均亏、盈亏因子、盈亏比、期望；无亏损交易 → `∞` / `不可用`，禁止 NaN。
- **回撤**：只看净值曲线；记录峰/谷/起止K/回到前高的K。TradeRecord 盈亏 ≠ 净值回撤。
- **费用**：比例手续费、固定价差滑点可非 0；默认仍 0。
- **验证**：`flutter test test/backtest_result_test.dart test/mini_loop_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。无箭头、不做 Sharpe/做空/加仓/多品种。

---

### 2026-08-15 — 【口径】Phase2 最小交易闭环（Signal→Order→K0开盘Fill→Position→TradeRecord）

- **需求**：一次接完单仓多头闭环；不实现统计/UI。
- **成交**：`discoveryX=X` → `executeX=X+1` → 价=`K0[X+1].open`；无下一根则订单过期，禁止用末根收盘虚构。
- **仓位**：无仓才能买、有仓才能卖；再买/无仓卖显式拒绝。
- **布林**：`mathFreeze==null` 不再现算，只读冻结仓。
- **费用**：手续费/滑点接口默认 0。
- **验证**：`flutter test test/mini_loop_test.dart` + catalog/cross 全过。
- **注意**：纯 Flutter；无需重编 DLL。无箭头、不自动弹演示。

---

### 2026-08-15 — 【口径】CROSS 求值（仅上穿/下穿，不撮合）

- **需求**：同层同钟读双方 evalClock 样本，相邻两根判断穿越，只在边沿出一次 `SignalEvent`；`availableAt` 映射到当时已知 K0。
- **不变**：不碰撮合/订单/账户/净值/箭头；不碰 AND/OR；不拿 `lookupTradeNumeric` 铺平值做穿越。
- **合法**：K1.CLOSE vs K1.BOLL.DOWN / UP。**非法**：K0.CLOSE vs K1.BOLL.DOWN（编译期，无事件）。
- **边沿**：CROSS_ABOVE = 上一根 A≤B 且本根 A>B；CROSS_BELOW 镜像。持续在轨外不重复。
- **验证**：`flutter test test/cross_eval_test.dart` + `signal_data_catalog_test.dart` 全过。
- **注意**：纯 Flutter；无需重编 DLL。无图上标记，不自动弹演示。

---

### 2026-08-15 — 【口径】交易钟类型门禁（Clock + 契约 + K0 成交钟）

- **需求**：同层同钟才能比较/穿越，混钟在编译阶段就是非法表达式；条件只在 evalClock 上算。
- **不变**：不碰公式求值、撮合、账户、Rust 指标迁移、策略箭头、缠论内核。
- **变更**：`TradeOperand`（displayKn+clockFamily+evalClock+plotClock）；`compileBinaryOp` 产出 `TradeExprOk`/`TradeExprIllegal`；`SameClockPair` 只能由编译成功得到。`readEvalClockSeries` 给出计算钟样本（availableAt=当时能知道的 K0）。成交钟固定下一根 K0 开盘。
- **例子**：K1.CLOSE vs K1.BOLL.DOWN 合法；K0.CLOSE vs K1.BOLL.DOWN 非法。
- **验证**：`flutter test test/signal_data_catalog_test.dart`。
- **注意**：纯 Flutter；无需重编 DLL。

---

### 2026-08-15 — 【口径】交易条件变量目录阶段0（SignalDataCatalog）

- **需求**：回测先建可交易变量目录，不在 Flutter 里另判条件画箭头。阶段0只登记身份清楚、能取值的变量。
- **不变**：缠论内核、步进冻结、主图语义、布林算法、MathSeriesFreezeStore；不搬数学指标进 Rust；不做公式/撮合/账户。
- **登记**：`RAW.K0` 开高低收量；`RAW.K{n≥1}` 开高低收（与布林同一套钟：K0原生，K1+结构层 kn-1 虚拟K，含动态段）；`MAIN.K{n}.BOLL.MID/UP/DOWN`（读冻结仓，与图上布林同一份数）。
- **只盘点不进公式**：中枢高低（未写清哪一框）、一类/二类买卖点（未写边沿）、三型/四型/趋势线/节奏/背驰/MACD/RSI 等。
- **钟**：同一显示层 + 同一 `zsMath`/`line` 才能进表达式；禁止 K0 收盘穿 K1 布林。
- **三态**：没有数=不可用，不是条件不成立。布林热身仍按图上出数，不另造前 N 根空白。
- **成交约定（尚未实现）**：信号在当根发现，下一根 K0 开盘成交。
- **验证**：`flutter test test/signal_data_catalog_test.dart` 全过。
- **注意**：纯 Flutter；无需重编 DLL。阶段0无图上买卖标记，不自动弹任务演示。分支 `trade`。

---

### 2026-08-15 — 【口径】Phase5 通用交易条件构建器 v1

- **需求**：策略从写死的布林穿越模板升级为可搭积木的条件 AST；界面只建树，真假仍走现有回测核心。
- **不变**：缠论内核、步进冻结、主图语义、K0 下一根开盘成交、单仓只做多；不新做指标算法/Rust 迁移/MACD/RSI/Buy1/背驰/做空/加仓。
- **AST**：比较 `> < >= <=`、`CROSS_ABOVE`/`CROSS_BELOW`、`AND`/`OR`；操作数=变量或常数；两常数非法。
- **第一批变量**：收/开/高/低 + 布林中/上/下轨。同 displayKn + 同 clockFamily 才能比较或穿越；K0×K1 编译期非法；一棵树上也不能把 K0 和 K1 AND/OR 在一起。
- **求值**：只在 evalClock 样本上算布尔，假变真出 `SignalEvent`。CROSS 仍是边沿脉冲。AND/OR 按 availableAt 对齐。
- **可解释**：每条信号带条件文案、触发时取值、发现 K0 #；链路仍是条件→Signal→Order→Fill→Trade。
- **默认策略**：仍是 K0 收下穿下轨买 / 上穿上轨卖，结果应与旧固定布林路径同一批发现点。
- **验证**：`flutter test test/condition_ast_test.dart test/backtest_workbench_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。不自动弹任务演示。引擎版本 `backtest-workbench-v2-ast`。

---

### 2026-08-15 — 【口径】Phase6 指标变量扩展层 v1

- **需求**：条件树能搭，但可交易变量还只有 OHLC+布林。接入现有 MACD/RSI/KDJ 冻结仓和 K0 成交量，做成统一注册通道。
- **不变**：缠论内核、步进冻结、K0 下一根开盘成交；不新写指标算法；不做空/加仓/Buy1/背驰/节奏/Demark。
- **登记**：`SUB.K{n}.MACD.DIF/DEA/HIST`、`SUB.K{n}.RSI.VALUE`、`SUB.K{n}.KDJ.K/D/J`；成交量只开放 `RAW.K0.VOLUME`（Kn 成交量仍是铺平阶梯，不进公式）。无 `VOLUME_AVG5`。
- **钟**：与布林同一套 zsMath；K0 一根一根，K1+ 虚拟K右端。混层编译期非法。
- **读数**：只读 `MathSeriesFreezeStore`；没有仓/空格=不可用，禁止现场重算。
- **UI**：条件积木按层+类别（开高低收/布林/MACD/RSI/KDJ/成交量）动态列出已登记变量；变量诊断只读目录和冻结仓。
- **验证**：`flutter test test/indicator_var_ext_test.dart test/signal_data_catalog_test.dart test/condition_ast_test.dart test/backtest_workbench_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。引擎版本 `backtest-workbench-v3-indicators`。

---

### 2026-08-15 — 【口径】Phase7 缠论结构事件变量层 v1

- **需求**：把最成熟的缠论事件做成可交易变量：一类/二类 BS、分型确认、中枢确认。不是持续 true，是发现边沿。
- **不变**：缠论内核、BS 计算、步进冻结、K0 下一根开盘成交。不做 N 类、中枢高低、背驰、节奏、几何线、做空、加仓。
- **登记**：`STRUCTURE.K{n}.BUY1/SELL1/BUY2/SELL2`、`SUB.K{n}.FRACTAL_CONFIRM`、`SUB.K{n}.ZS_CONFIRM`。读会话历史/确认列表的**稳定身份首次 x**；动态后续 x 仍留在图上历史，不重复出交易事件。未来 x>asOf 不进过去。
- **AST**：新增 `EVENT_EXISTS`。事件只参与 AND/OR；`BUY1 > 0` / `CROSS(BUY1,X)` 编译期非法。一类买 + RSI 同 zsMath 合法；分型确认是连线钟，和 RSI AND 非法。
- **综合**：买 `K1.BUY1 AND K1.RSI<50`；卖 `K1.SELL1 OR K1.MACD DIF 下穿 DEA`。
- **验证**：`flutter test test/chan_event_var_test.dart test/signal_data_catalog_test.dart test/condition_ast_test.dart test/backtest_workbench_test.dart test/indicator_var_ext_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。引擎版本 `backtest-workbench-v4-chan-events`。

---

### 2026-08-15 — 【口径】Phase8 缠论结构对象契约 + 中枢数值变量 v1

- **需求**：中枢从「确认事件」升级为有身份的结构对象，再投影成可交易数值。禁止直接把 ZS_HIGH 注册成无身份 double。
- **不变**：缠论中枢算法/确认/冻结/Clock；K0 下一根开盘成交。不做 N 类、背驰、节奏、三型四型、未确认中枢、做空、加仓。
- **对象**：稳定 `objectId=ZS|{kn}|{x1}`；动态延伸不换 ID；历史 asOf 快照冻结，未来扩大不回写。生命周期 DISCOVERED/CONFIRMED/ACTIVE/EXTENDED/ENDED。
- **选择**：第一版只暴露 `CURRENT_CONFIRMED_ZS`（该层 asOf 下最新一个已确认且当时可见的中枢）。未确认不进交易变量。没有确认中枢=不可用，不是 0。
- **登记**：`STRUCTURE.K{n}.ZS.CURRENT.HIGH/LOW/CENTER` 为 Numeric Projection。读数路径 `(asOf, kn) → resolveCurrentConfirmedZs → objectId → HIGH/LOW/CENTER`，只消费现有中枢帧步进快照。
- **钟**：与收盘同一套 zsMath；K1.CLOSE vs K1.ZS.CURRENT.LOW 合法；K0.CLOSE vs K1.ZS.CURRENT.HIGH 编译期非法。`ZS_CONFIRM` 仍是事件，不能比较/穿越，可与同层数值 AND/OR。
- **综合**：买 `K1.BUY1 AND K1.CLOSE < K1.ZS.CURRENT.LOW`；卖 `K1.SELL1 OR K1.CLOSE CROSS_ABOVE K1.ZS.CURRENT.HIGH`。
- **验证**：`flutter test test/zs_object_var_test.dart test/chan_event_var_test.dart test/signal_data_catalog_test.dart test/condition_ast_test.dart test/backtest_workbench_test.dart test/indicator_var_ext_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。引擎版本 `backtest-workbench-v5-zs-objects`。

---

### 2026-08-15 — 【口径】Phase9 背驰结构关系变量 v1

- **需求**：背驰从「能显示的指标结果」升级为引用具体结构对象、比较对象、发现时刻的可交易关系。禁止无身份的 `DIVERGENCE=true`，禁止把整个背驰对象当 double 去比较/穿越。
- **不变**：背驰算法/冻结/Clock；不新写第二套计算；K0 下一根开盘成交。不做 N 类、节奏、三型四型、趋势线、做空、加仓、多品种、参数优化。
- **对象**：稳定 `relationId=DIVER|{kn}|area|{referenceObjectId}|{sourceObjectId}|{inSeg}|{outSeg}|{mode}`。比较对象优先绑 `ZS|{kn}|{x1}`，否则 `SEG|{kn}|{segIdx}`。动态延伸同一 relationId；历史 asOf 快照不回写。确认翻转追加新 EXISTS 边沿，不改旧事件。
- **投影**：`STRUCTURE.K{n}.DIVERGENCE.EXISTS` 事件（k0Bar）；`RATIO` Numeric；`DIRECTION` 枚举（只能 `==` 向上/向下）。力度只读现有 MACD 面积冻结仓。没有当时可见确认关系=不可用，不是 0。
- **钟**：zsMath；EXISTS 可与同层一类买/RSI AND；RATIO 可与同层 RSI 比较。K0×K1、EXISTS 比较/穿越、DIRECTION 比大小/CROSS 编译期非法。
- **综合**：买 A `K1.BUY1 AND K1.DIVERGENCE.EXISTS`；买 B `K1.DIVERGENCE.RATIO < 0.8 AND K1.RSI < 50`。
- **验证**：`flutter test test/divergence_relation_var_test.dart test/zs_object_var_test.dart test/chan_event_var_test.dart test/signal_data_catalog_test.dart test/condition_ast_test.dart test/backtest_workbench_test.dart test/indicator_var_ext_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。引擎版本 `backtest-workbench-v6-divergence-rel`。

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

---

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

---

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

---

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

---

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

---

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

---

### 2026-08-16 — 【口径】Phase10～15 缠论交易变量与策略回测基础设施收口

- **需求**：N 类事件 `BUY_N(class)`/`SELL_N(class)`；统一 StructureObject/Relation/Projection/Event；条件树 v2 类型与 ConditionTrace；RulePerformance 归因；BacktestRunContext；6+1 条标准策略回归。禁止重复实现 Phase8/9。
- **不变**：缠论内核、BOLL/MACD/RSI/KDJ/BS/中枢/背驰算法、冻结、K0 下一根开盘成交。不做空/加仓/多品种/参数优化/全市场选股。未确认结构不进策略。
- **Phase10**：`STRUCTURE.K{n}.BUY_N.{cls}` / `SELL_N.{cls}`（cls≥3）；`CHAN.` 别名规范化。只读 buyN/sellN 会话历史；稳定身份首次发现；动态后续 x 不重复信号；x>asOf 不可见。UI 列出 3..6，lookup 可合成到 20。
- **Phase11**：`StructureMeta` 统一 objectId/relationId、source/reference、displayKn、discoveryX、availableAt、state、projection。已有中枢对象、背驰关系接入；不改算法。
- **Phase12**：Number/Boolean/Event/Enum/ObjectProjection/RelationProjection。编译失败分 TypeError/ClockError/Unavailable。Signal 带 ConditionTrace。
- **Phase13**：`BacktestResult.rulePerformances` 按 ruleId 统计信号/接单/成交/闭合/胜率/净利/笔均/盈亏比。只归因，不优化。
- **Phase14**：`BacktestRunContext`：runId、engineVersion、strategyVersion=`ast-v2`、dataContractVersion=`catalog-v2-buy-n`、structureSemanticVersion=`structure-v2`、品种/周期/区间/资金/成本。
- **Phase15**：标准策略（纯指标、BOLL+RSI、BUY1+RSI、BUY1+ZS、BUY1+DIVERGENCE、RATIO+RSI、BUY_N(3) OR BUY1）同一条 AST→Signal→Order→Fill→Trade→Equity→Metrics。
- **验证**：`flutter test test/buy_n_var_test.dart test/structure_contract_test.dart test/chan_strategy_regression_test.dart test/divergence_relation_var_test.dart test/zs_object_var_test.dart test/chan_event_var_test.dart test/signal_data_catalog_test.dart test/condition_ast_test.dart test/backtest_workbench_test.dart test/indicator_var_ext_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。引擎版本 `backtest-workbench-v7-chan-complete`。不自动弹演示。

---

### 2026-08-16 — 【口径】事件脉冲 + 同一根先平后开（对齐金字塔）

- **需求**：分型确认等事件按当根脉冲出信号；连着两颗不同确认（如 K0 7 和 8）都认。同一根既买又卖时先平后开。状态比较仍假变真。
- **不变**：缠论内核、冻结、K0 下一根开盘成交、只做多单仓。不拆顶/底确认积木。不做空、加仓、当根收盘成交。
- **信号**：`EVENT_EXISTS` 当根各打一次；`CLOSE>均线` 等比较仍假变真。同一分型动态后续 x 仍只认首次。
- **撮合**：同一根发现先处理卖再处理买。空仓卖拒绝、只开；有仓先平成交再开。
- **验证**：`flutter test test/chan_event_var_test.dart test/mini_loop_test.dart test/condition_ast_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。引擎版本 `backtest-workbench-v8-event-pulse`。

---

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

---

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

---

### 2026-08-17 — 【口径】策买画在发现根；被拒不画；拖动跟着走

- **需求**：图上策买和交易买入时间对得上；拖动 K 线时绿/紫三角跟着蜡烛走。
- **不变**：撮合仍是发现当根、下一根开盘成交、同一根先平后开。不改缠论内核。
- **显示**：有成交才画策买/策卖，位置在发现根；被拒不画。交易明细写成交K和时间，并注明信号K。
- **拖动**：策略点图层把当时视窗拷下来再比是否重画，避免和蜡烛不同步。
- **注意**：纯 Flutter；无需重编 DLL。

---

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

---

### 2026-08-18 — 【口径】策略标记买/卖2红绿；交易与信号链路表格

- **需求**：主图策买→买（红）、策卖→卖2（绿）；报告「交易」「信号链路」改表格。
- **不变**：撮合、冻结、缠论内核不变；被拒信号仍不画；点行/点图联动跳 K 不变。
- **显示**：`strategySideLabel` / `strategySideColor` 统一主图与报告；表格可横滑。
- **验证**：`flutter test test/backtest_workbench_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。

---

### 2026-08-18 — 【口径】策略回测成交价格：本周期收盘 / 次周期开盘

- **需求**：设置里可选成交价格（买/卖共用）：本周期收盘价（默认）、次周期开盘价。
- **不变**：缠论内核、冻结、步进、策略信号与缠论 BS 分离、同一根先平后开、只做多单仓。
- **撮合**：`TradeFillPriceMode.sameBarClose` → 发现根收盘成交；`nextBarOpen` → 下一根开盘（无下一根过期）。
- **UI**：策略表单下拉 + 说明弹窗；`msg_history` 同步口径。
- **验证**：`flutter test test/mini_loop_test.dart test/backtest_result_test.dart test/chan_strategy_regression_test.dart`
- **注意**：纯 Flutter；引擎版本 `backtest-workbench-v9-fill-price`；无需重编 DLL。

---

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

---

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

---

### 2026-08-19 — 【口径】策略买卖组号：买1/卖1、买2/卖2

- **需求**：每次闭合交易的买/卖为一组，主图与报告同步显示买1/卖1、买2/卖2。
- **不变**：撮合、冻结、缠论 BS 分离、先平后开；被拒信号仍不画。
- **实现**：`buildStrategyRoundIndex` 按闭合交易顺序编号；期末持仓仅买N。
- **UI**：主图标签、交易表「组」列、信号链路方向/组列。
- **验证**：`flutter test test/backtest_workbench_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。

---

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

---

### 2026-08-20 — 【口径】策略回测变量补全：未确认中枢 + 已算好指标

- **需求**：未确认中枢高/低/中轴单独进公式（当下可见、没有就空、不沿用）；图上已实现的均线/通道/Demark/判断/斜率比例节奏/量笔/三型四型趋势线全部可做买卖条件。
- **不变**：整段中枢/整段背驰不当数比；未指定哪一框的 ZS.HIGH 仍只盘点；筹码峰动态名不进；同层同钟门禁；不解析十字文案、不另算第二套指标。
- **未确认中枢**：ACTIVE 与 CURRENT 分开；asOf 落在未确认框 x1..x2 内才有数；当步冻结；确认后只走 CURRENT。
- **取值**：均线/通道/Demark 读 Math 冻结仓；判断/斜率/比例/节奏读会话历史；三型四型趋势优先十字 Lookup 已冻格子。
- **钟**：斜率/比例/节奏/分型判断=连线钟；其余价格类与布林同 zsMath。
- **验证**：`flutter test test/catalog_full_var_test.dart test/zs_object_var_test.dart test/signal_data_catalog_test.dart test/indicator_var_ext_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。

---

### 2026-08-20 — 【口径】K0筹码峰/笔数峰进策略公式

- **需求**：开高低收与筹码峰-1/+1/框内比；笔数峰同样；不混层混钟；斜率暂不执行。
- **口径**：只做 K0；编号与十字同一套（本根高低框）；框内多峰取离收盘更近；没有就空、不填 0、不沿用；当步冻结。
- **不变**：连线斜率仍不能和布林写在同一条；整段中枢/整段背驰仍不当数比。
- **验证**：`flutter test test/chip_peak_var_test.dart test/catalog_full_var_test.dart`
- **注意**：纯 Flutter；无需重编 DLL。

---

### 2026-08-20 19:20 — 策略回测接入未确认中枢及其余已算好指标

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：用户确认执行：未确认中枢高/低/中轴单独变量（没有就空、不沿用）；其它图上已实现指标全部进策略公式
- **关键操作**：
  1. 目录登记未确认中枢、均线、通道、Demark完成买/卖、分型/中枢判断、斜率/比例/节奏、Kn成交量笔数、三型/四型/趋势线投影
  2. 中枢对象仓对未确认框按当步盖住才写快照，框外为空；确认中枢 CURRENT 不变
  3. 取值只读冻结仓/会话历史/十字已冻格子，不解析 tooltip 文案；main 把判断历史、连线历史、Lookup 喂进回测
- **结果**：`flutter test test/catalog_full_var_test.dart test/zs_object_var_test.dart test/signal_data_catalog_test.dart test/indicator_var_ext_test.dart test/buy_n_var_test.dart test/chan_event_var_test.dart test/chan_strategy_regression_test.dart` 全过（57 项）
- **演示**：test 演示 id=2026-08-20-trade-catalog-full
- **注意事项**：纯 Flutter；无需重编 DLL；筹码峰动态名仍不进公式；斜率/节奏是连线钟不能和布林混写

---

### 2026-08-20 22:30 — K0筹码峰/笔数峰进策略公式

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：确认执行：峰价与开高低收比；笔数峰同样做；不混层混钟；斜率暂不执行；完成后合并 main 并开瘦身分支 CHAN_RUST
- **关键操作**：
  1. 登记 K0筹码峰/笔数峰（框内、-1..-3、+1..+3），与 K0 开高低收同一套钟
  2. 按这根高低编号写入冻结仓，没有就空、不沿用、不回写
  3. 演示 id=2026-08-20-chip-peak-vars
- **结果**：`flutter test test/chip_peak_var_test.dart test/catalog_full_var_test.dart test/zs_object_var_test.dart test/buy_n_var_test.dart test/signal_data_catalog_test.dart test/indicator_var_ext_test.dart` 全过（38 项）
- **演示**：test 演示 id=2026-08-20-chip-peak-vars
- **注意事项**：纯 Flutter；无需重编 DLL；K1 筹码峰仍不进公式

---

### 2026-08-25 — 【口径】指标展开直选 + 双指方向缩放

- **需求**：展开视图打开后直接展示主/副图全量指标列表，单击切换选中；已选白字、未选灰字+删除线；摒弃多选框。双指上下=纵向缩放、左右=横向扩张/收紧。点 K 线/主图/副图不唤起指标面板，仅展开钮（三角）可调出。
- **变更**：
  - `indicator_picker_chip.dart`：去掉下拉箭头；全量列表 + 选中态样式。
  - `kline_chart.dart`：展开区直选；移除全屏指标层与点图触发；双指手势改方向缩放。
  - `main/sub_indicator_picker.dart`：对话框同步为文字点选样式（无 Checkbox）。
  - `msg_history.dart`：常驻历史口径同步。
- **验证**：纯 Flutter；无需重编 DLL。`flutter analyze`（本环境未装 SDK，IDE lint 无报错）。

---

### 2026-08-25 — 【口径】指标全屏列表 + 单指平移 + 覆盖安装

- **需求**：伸展钮打开近乎全屏指标列表（每行一项）；单指仅平移、双指缩放；APK 覆盖安装无需卸载。
- **变更**：
  - `indicator_picker_overlay.dart`：全屏列表组件；删除 `indicator_picker_chip.dart`。
  - `kline_chart.dart`：伸展钮唤起全屏层；单指 `pointerCount<2` 仅 `panByPixels`。
  - `android/app/build.gradle.kts` + `key.properties` + `chan_kline-debug.jks`：固定签名，versionCode 递增可覆盖安装。
- **验证**：纯 Flutter + Android 配置；`flutter build apk --release`。

---

### 2026-08-25 — 【口径】双指缩放阈值失效修复

- **问题**：放大/缩小到一定阈值后横纵双指缩放全部失效。
- **根因**：`zoomXAt` 右界硬拽回视窗；双指手势每帧按 dx/dy 抢轴且忽略捏合 scale。
- **修复**：右缘超出改为整体左移；手势锁定轴向 + 捏合 scale 补充；新增 `zoomYBy`。
- **验证**：`flutter test test/kline_viewport_zoom_test.dart`

---

### 2026-08-30 08:29 — 补发 GitHub Windows zip 发布包（v1.0.10）

- **执行者**：cursor（cloud agent）
- **任务类型**：配置 / 发布
- **上下文**：v1.0.10 Release 仅有 Android APK，缺 Windows 解压即用 zip
- **关键操作**：
  1. 新增 `package_windows.ps1`、`release_readme.txt` 与 `release-chan-kline-windows.yml` 工作流
  2. 推送到 ANDROID_RUST / main，打标签 `win-v1.0.10` 触发 CI
  3. GitHub Actions 编译 Rust DLL + Flutter Windows Release，打包含 a_Data 的 zip 并上传到 v1.0.10 Release
- **结果**：`chan_kline-windows-x64.zip`（约 89 MB）已挂到 [v1.0.10 Release](https://github.com/cuixinyuan666/chan_month5/releases/tag/v1.0.10)；工作流 run #33301469836 成功
- **演示**：下载 zip → 解压 → 双击 `chan_kline.exe`；同目录 `a_Data` 含 002003 默认股票
- **注意事项**：Windows 需 VC++ x64 运行库；后续可 Actions 手动 Run「Release chan_kline Windows」补发其它版本

---

### 2026-08-30 08:51 — Windows zip 强化 a_Data 打包并重新发布

- **执行者**：cursor（cloud agent）
- **任务类型**：配置 / 发布
- **上下文**：用户要求 zip 内必须含 a_Data 且解压可运行
- **关键操作**：
  1. `package_windows.ps1` 增加 a_Data 文件数校验（≥5000）、复制后二次校验
  2. 生成「启动 chan_kline.bat」自动设置 `CHAN_DATA_ROOT=%~dp0a_Data`
  3. 修正 CI 标签归并（`win-v1.0.10-*` → Release `v1.0.10`），重新触发构建
- **结果**：v1.0.10 Release 的 `chan_kline-windows-x64.zip` 已更新（含 a_Data 7327 项 + 启动脚本）；CI run 成功
- **演示**：解压 zip → 双击「启动 chan_kline.bat」→ 应能加载 002003
- **注意事项**：若直接双击 exe 需手设 `CHAN_DATA_ROOT`；长期可在 Flutter 侧加 exe 旁 a_Data 自动发现（需确认执行）

---

### 2026-08-31 — 【口径】当步仓：十字/步退禁止末态裁 x、禁止整段重放

- **问题**：播放约 20 秒后整图和十字一起卡；连按步退假死约 38 秒/次。
- **口径**：十字/步退用**当步仓**（播放当时钉下的结构），禁止用末态再裁 x；步退画面变短时 Rust 管道保持最长前缀，禁止整段 reset+replay；管道比画面长时冻结历史不再重复合并。
- **不变**：冻结键、一类/二类打点、mark_x、缠论内核；换股/换周期/截断开关仍重建会话。
- **验证**：连续播放数百根 + 十字左右移 + 连按步退（非一键跳末）。日志：十字 `session_snap` 0–1ms；步退 skipMerge 0–1ms；0 次整段重放。
- **注意**：纯 Flutter；无需重编 DLL。再压每步 JSON/FFI 须「确认执行」。

---

### 2026-08-31 — 【口径】分笔加载太极 + 十字信息框不挡跟手 + 主副图钮降亮

- **分笔加载**：仅分笔周期，初次加载用完整阴阳鱼（易经太极）代替小圆点转圈；其它周期不变。
- **十字信息框**：开十字+信息框时左右移动即使划过信息框，十字仍跟光标；关闭钮可点。
- **主副图钮**：伸展三角与中间调节手柄降低亮度对比。
- **不变**：缠论内核、冻结、步进当下性。
- **验证**：002003 分笔重新加载；双击十字+信息框左右移；看主副图钮。
- **注意**：纯 Flutter；无需重编 DLL。

---

### 2026-08-31 02:50 — 指标选择三级导航 + 绘制与勾选同步

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：Android 指标收纳改为层级→类别→指标；白字=已选=绘制，去掉独立静音集；Kn连线在父层虚拟单元形成前不画
- **关键操作**：
  1. 指标面板改为三级导航（层级 / 类别 / 指标）
  2. 启动默认只勾核心绘制项；选择集即绘制集
  3. Kn连线：父层还没出现首根虚拟单元时不画整批判断链
- **结果**：提交 lib/test 源码；单测含 `indicator_picker_hierarchy_test`、`indicator_draw_sync_test`
- **演示**：全新功能·免对比（选择栏交互）；连线闸门可用 002003 连续单步看 K1 起是否过早成线
- **注意事项**：未提交本机 `local.properties`、Flutter SDK 缓存路径、ephemeral 生成文件

---

### 2026-08-31 17:55 — 播放/十字/步退卡顿：当步仓 + 链式播放

- **执行者**：cursor
- **任务类型**：Bug修复 / 性能
- **上下文**：播放约 20 秒后，播放、K 线显示、十字移动一起卡；连按步退会假死一两分钟。未改缠论判定、未改冻结键。
- **关键操作**：
  1. 播放改成「算完这一根再等至少一帧再走下一根」，避免定时器把步进叠死
  2. 查表按当步追加，不再每步把已有 K 全扫一遍
  3. 十字回看用播放当时钉下的当步仓，不再对 0～当前根重算一遍缠论
  4. 步退直接取当时那步的仓，禁止整段推倒重放；管道比画面长时不再重复合并买卖点/中枢历史
- **结果**：运行时日志：十字换根从约 2 秒降到 0–1ms（全程走当步仓，无全量重算）；步退从约 38 秒/次降到 0–1ms；播放不再叠步。探针已拆除。再压每步 JSON/内核包须「确认执行」。
- **演示**：默认股 002003，冷启动后从头连续播放数百根，开十字左右移，再连按步退。不要用一键跳末代替。热重启后当步仓才会按新代码记满。
- **注意事项**：纯 Flutter 展示层；无需重编 DLL。一键跳末≠步进验收。

---

### 2026-08-31 23:35 — 拆探针 + 分笔太极加载 / 十字信息框跟手 / 主副图钮降亮

- **执行者**：cursor
- **任务类型**：Bug修复 / 界面
- **上下文**：播放卡顿已明显加快；拆掉计时探针。另改三处界面：分笔初次加载图标、十字信息框挡鼠标、主副图调节钮太亮。
- **关键操作**：
  1. 拆掉写入调试日志的探针；性能改动保留
  2. 仅分笔：初次加载时屏幕中央用完整阴阳鱼代替小圆点转圈
  3. 开十字+信息框时，鼠标划过信息框十字仍跟走；关闭钮可点
  4. 主图/副图伸展三角和中间调节手柄降低亮度对比
- **结果**：纯 Flutter；无需重编 DLL
- **演示**：默认股 002003 分笔。重新加载看中央太极；双击开十字和信息框后左右快速移动，十字应一直跟手；主副图左上三角和中间横条应比以前淡
- **注意事项**：其它周期加载仍是小转圈。图上每一根分笔 K 仍是圆点（只换了加载图标）

---

### 2026-09-01 — 【口径】太极仅加载 / 一次性走完少刷查表

- **分笔太极**：只在初次加载时屏幕中央显示完整阴阳鱼；一步进后图上仍是原来的圆点。
- **一次性走完**：循环里仍逐 K 合并冻结，但不再每步刷新查表；走完后一次刷新画面。不改冻结键、不改当下性。
- **再压**：每步内核 JSON 仍大，继续压须「确认执行」。
- **验证**：002003 分笔重新加载看中央太极，步进后圆点；长按一次性走完看耗时。
- **注意**：纯 Flutter；无需重编 DLL。

---

### 2026-09-01 — 【口径】分笔进图稍小太极，操作后回圆点

- **分笔**：刚进入或重新加载后，图上圆点先换成稍小阴阳鱼（有上限，避免首根撑满）。
- **实质操作**：步进、播放、拖图、滚轮、十字、走完等立刻换回原来的圆点。
- **重新加载分笔**会再出现一次阴阳鱼。其它周期仍是蜡烛。
- **不变**：缠论内核、冻结、步进当下性。
- **验证**：002003 分笔冷启动看稍小太极，点步进后变圆点。

---

### 2026-09-01 — 【口径】分笔太极铺满窗口 + 一次性走完少拷表

- **分笔太极**：加载中和刚进图时阴阳鱼拉成窗口矩形铺满（完整 S 形、四边贴齐）；点一下、步进、播放或走完后收起，K 线仍是圆点。
- **一次性走完**：仍逐 K 合并冻结；循环里少拷买卖点/比例表，筹码峰放到走完后一次补写。不改冻结键、不改当下性。
- **再压**：每步内核 JSON 仍大，继续压须「确认执行」。
- **验证**：002003 分笔冷启动看铺满窗口的太极，点一下应变圆点；长按一次性走完看是否比约 84 秒更快。
- **注意**：纯 Flutter；无需重编 DLL。

---

### 2026-09-01 — 【口径】拆掉太极/走完探针

- **范围**：只拆写文件/HTTP 探针和走完循环里的计时；铺满太极、点一下收起、走完少拷表逻辑都保留。
- **不变**：缠论内核、冻结、步进当下性。
- **验证**：002003 分笔冷启动仍铺满太极，点一下变圆点；设置里历史记录按钮仍在。
- **注意**：纯 Flutter；无需重编 DLL。

---

### 2026-09-01 — 【口径】走完中间步仍解析冻段

- **问题**：一次性走完为提速跳过冻段解析，比例/斜率/节奏与连续单步对不上；买卖点/中枢/分型判断仍一致。
- **改法**：瘦包仍解析各层冻段和合并框；只跳过 k1 分析等纯展示表。不改冻结键、不改内核。
- **验证**：002003 1m+分笔 后台单步 vs 走完对拍。
- **注意**：纯 Flutter；无需重编 DLL。

---

### 2026-09-01 — 【口径】P0 信赖闸门：走完=单步 / 走完有进度 / 库版本停机 / 演示默认关

- **走完=单步**：走完中间步仍解析冻段和合并框（此前已修）；对拍覆盖一类/二类/三类+买卖点、中枢、分型判断、比例、斜率、节奏。走完只少纯展示，不少冻结用的连线。
- **长数据**：一次性走完、自动播放显示中文进度；走完可取消（停在当前根，已写点保留）。不靠少解析冻段提速。
- **计算库**：启动核对准 `chan_ffi_abi_version`（现为 1）。对不上或找不到则中文停机。**须重编并覆盖 `windows/native/chan_ffi.dll`；打 Android 包须另编 `jniLibs/*/libchan_ffi.so`（Windows：`CHAN_RUST/scripts/build_rust_android.ps1`）后冷启动。**
- **发布闸门**：打 zip 前跑 `cargo test -p chan_data` + Flutter 库版本测试 + 单步/走完对拍。本地：`CHAN_RUST/scripts/run_release_gate.ps1`。
- **演示阶段**：对外默认关自动加载；设置可开。
- **不变**：冻结键、层号、当下性、历史记录按钮。
- **验证**：002003 1 分钟+分笔连续单步；走完对拍测试；冷启动看库门禁与演示不再自动弹。

---

### 2026-09-01 00:20 — 分笔图上圆点改太极 + 十字信息框改外层跟手

- **执行者**：cursor
- **任务类型**：Bug修复 / 界面
- **上下文**：上一轮只换了加载转圈，图上分笔仍是圆点；信息框叠在鼠标层上十字会停。
- **关键操作**：
  1. 分笔主图每一根圆点改为完整阴阳鱼，外圈随涨跌色
  2. 整张图外层跟鼠标，信息框划过仍更新十字
  3. 主副图钮再降一层透明度
- **演示**：002003 分笔看图上太极；双击十字+信息框左右划过信息框
- **注意事项**：探针仍在，验过后再拆

---

### 2026-09-01 00:55 — 太极只留加载 / 一次性走完少刷查表

- **执行者**：cursor
- **任务类型**：Bug修复 / 性能
- **上下文**：用户只要初次加载显示阴阳鱼，一步进后图上恢复圆点；并问一次性走完能否再快。
- **关键操作**：
  1. 图上分笔改回普通圆点；太极只出现在分笔初次加载转圈
  2. 一次性走完循环里不再每步刷新查表，前缀列表只追加不整段拷贝；冻结仍逐 K 合并
- **结果**：纯 Flutter；再压每步内核 JSON 须「确认执行」
- **演示**：默认股 002003 分笔重新加载看中央太极，点步进后应是圆点；长按一次性走完
- **注意事项**：探针仍在，验过后再拆

---

### 2026-09-01 01:12 — 分笔进图稍小太极，操作后回圆点

- **执行者**：cursor
- **任务类型**：界面
- **上下文**：刚进 app 分笔图上是大圆圈，要换成稍小阴阳鱼；一旦有实质操作就换回圆点。
- **关键操作**：
  1. 分笔刚进入/重新加载：图上圆点画成稍小阴阳鱼（半径有上限，避免首根撑满）
  2. 步进、播放、拖图、滚轮、十字、走完等操作立刻换回原来的圆点
- **演示**：002003 分笔冷启动看稍小太极，点步进或拖一下应变圆点
- **注意事项**：探针仍在，验过后再拆

---

### 2026-09-01 01:20 — 分笔太极铺满窗口 + 一次性走完少拷表

- **执行者**：cursor
- **任务类型**：界面 / 性能
- **上下文**：阴阳鱼太小，要充满屏幕；继续压一次性走完速度。
- **关键操作**：
  1. 分笔加载中和刚进图：阴阳鱼铺满整个窗口（直径=窗口短边），点一下或步进后收起，K 线仍是圆点
  2. 一次性走完：循环里少拷买卖点/比例表，筹码峰放到走完后一次补写；冻结仍逐 K 合并
- **演示**：002003 分笔冷启动看铺满窗口的太极，点一下应变圆点；长按一次性走完看耗时
- **注意事项**：探针仍在，验过后再拆；再压每步内核包须确认执行

---

### 2026-09-01 04:03 — 清除太极/走完调试探针

- **执行者**：cursor
- **任务类型**：清理
- **上下文**：用户确认太极铺满和走完加速后，要求拆掉调试代码。
- **关键操作**：
  1. 拆掉写日志、HTTP 探针、走完循环计时；铺满太极、点一下收起、走完少拷表逻辑都留下
  2. 设置里「一键复制历史记录」等常驻按钮不删
- **结果**：探针已清；冷热重载后不再写调试文件
- **演示**：002003 分笔冷启动仍铺满太极，点一下变圆点；步进/播放/走完行为不变
- **注意事项**：再压每步内核包仍须确认执行

---

### 2026-09-01 08:40 — 后台对拍：单步 vs 一次性走完冻结

- **执行者**：cursor
- **任务类型**：验证
- **上下文**：用户要确认提速有没有改未提速前的结果，改为后台对拍，不再手工点。
- **关键操作**：
  1. 用 002003 默认区间，1 分钟 289 根 + 分笔 988 根，各跑一遍连续单步冻结、一遍走完中间瘦解析
  2. 对拍一类买卖点、中枢判断/确认、分型判断、相邻比例、斜率、节奏
- **结果**：买卖点、中枢、分型判断、末根冻段数一致；比例/斜率/节奏不一致（走完中间步没带冻段）。分笔走完后半程当步仓冻段数为 0。
- **演示**：后台已跑完；改走完瘦包须确认执行
- **注意事项**：未改 app 关键逻辑

---

### 2026-09-01 08:50 — 走完中间步仍解析冻段

- **执行者**：cursor
- **任务类型**：Bug修复
- **上下文**：后台对拍确认走完瘦包跳过冻段，比例/斜率/节奏与单步不一致；用户确认执行后修复。
- **关键操作**：
  1. 走完瘦包仍解析各层已冻住的连线和合并框
  2. 只跳过 k1 分析等纯展示表；买卖点/中枢/分型判断路径未改
- **结果**：002003 1 分钟 289 根、分笔 988 根，单步 vs 走完：买卖点/中枢/分型判断/比例/斜率/节奏全部一致；走完半程当步仓冻段数从 0 回到与单步相同。
- **演示**：默认股 002003 分笔，连续单步与一次性走完后十字看比例应同一套
- **注意事项**：纯 Flutter；无需重编 DLL

---

### 2026-09-01 09:03 — 拆掉走完对拍调试探针

- **执行者**：cursor
- **任务类型**：清理
- **上下文**：走完冻段修复已确认，拆掉写日志探针；单步 vs 走完对拍测试留下。
- **关键操作**：
  1. 对拍测试不再写调试文件
  2. 删除会话调试日志
- **结果**：探针已清；对拍测试仍可后台回归
- **演示**：全新功能·免对比
- **注意事项**：无

---

### 2026-09-01 22:40 — P0 信赖闸门：走完=单步、走完有进度、库版本停机、演示默认关

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：用户确认执行，在分支 `ar` 落地阶段 A·P0（陌生人信赖先锁三件事）。
- **关键操作**：
  1. 走完中间步仍带冻段（沿用已有修复）；对拍测试补上二类/三类+买卖点，002003 的 1 分钟和分笔可后台对拍
  2. 一次性走完、自动播放显示中文进度；走完可取消，已写点保留；不再靠少解析冻段提速
  3. 启动核对计算库版本，对不上或找不到则中文停机
  4. 打 zip 前加 Rust 单测 + Flutter 库版本/走完对拍；本地脚本 `CHAN_RUST/scripts/run_release_gate.ps1`
  5. 对外包默认关开发演示自动加载；设置仍可手动开
- **结果**：`cargo test -p chan_data` 144 通过；已重编并覆盖 `windows/native/chan_ffi.dll`；`flutter test test/chan_ffi_abi_test.dart` 通过；`flutter test test/run_to_end_vs_step_freeze_test.dart` 1 分钟+分笔对拍通过（约 1 分 41 秒）。历史记录已写白话口径；演示目录 `2026-09-01-p0-trust`
- **演示**：默认股 002003，连续单步 vs 一次性走完看副图同一套数；走完看进度；冷启动不应自动弹演示
- **注意事项**：须重编并覆盖 `windows/native/chan_ffi.dll` 后冷启动；验收以连续单步为准，走完只当对拍。DLL 若被占用则先关软件再覆盖，不要强杀正在用的进程

---

### 2026-09-02 — 【口径】策略一类/二类/N类买卖点可跨层 AND/OR

- **改什么**：买条件、卖条件里，一类/二类/N 类买卖点允许跨层用 AND 或 OR 拼（例如 K0 一类买 AND K1 三类买）。
- **AND**：同一根 K0 两边都刚出现才出信号，不是「历史上曾经有过」。
- **OR**：哪一层先出现就先出信号。
- **不放开**：收盘/RSI/布林/分型确认仍禁止 K0 和 K1 拼；跨层买卖点树不能再跟某一层 RSI 混。
- **不变**：缠论各层打点、冻结、步进当下性、历史记录按钮。
- **验证**：条件编译单测 + 同一根/错开根求值；002003 连续单步走出多层买卖点后，策略里跨层 AND/OR 应能编过。
- **注意**：纯 Flutter；无需重编 DLL。

---

### 2026-09-02 08:43 — Android 重编 libchan_ffi.so（与 P0 库版本对齐）

- **执行者**：cursor
- **任务类型**：配置
- **上下文**：P0 已给计算库加版本门禁并覆盖 Windows DLL；用户要求 Android 包另编 `libchan_ffi.so`。
- **关键操作**：
  1. 安装 `cargo-ndk`，补 Android 交叉编译目标
  2. 新增 Windows 脚本 `CHAN_RUST/scripts/build_rust_android.ps1`（对应已有 bash）
  3. 用本机 `D:\android_sdk` 的 NDK 28.2 编 arm64 / armv7 / x86_64，输出到 `jniLibs`
- **结果**：三份 `libchan_ffi.so` 已就位；arm64 库含 `chan_ffi_abi_version` 符号。`.so` 按仓库惯例不入库，打 APK 时从 `jniLibs` 打包。
- **演示**：全新功能·免对比（产物覆盖，无界面改动）
- **注意事项**：真机/模拟器需重新 `flutter build apk` 或 `flutter run -d android` 才会带上新库；冷启动后库版本应对上 1。未改缠论判定。

---

### 2026-09-02 23:10 — 策略一类/二类/N类买卖点跨层 AND/OR

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：用户确认执行：买卖条件里一类/二类/N 类的跨层门禁，AND 和 OR 都取消。
- **关键操作**：
  1. 编译时仅当两边都是一类/二类/N 类买卖点事件时允许跨层 AND/OR
  2. 收盘/RSI/布林/分型确认仍禁混层；跨层拼完的买卖点树不能再跟某一层 RSI 混
  3. AND 仍是同一根 K 两边都刚出现；OR 各层出现各打一次
- **结果**：`chan_event_var_test` / `buy_n_var_test` 覆盖编译与求值。历史记录已写。演示 `2026-09-02-cross-kn-bs-and-or`
- **演示**：002003 连续单步走出 K0/K1 买卖点后，策略买条件选两层一类/N 类用 AND 或 OR，应能编过；AND 很少成交是同一根才算，不是坏了
- **注意事项**：纯 Flutter；无需重编 DLL。验收连续单步，不要只靠一键走完。

---

### 2026-09-03 — 【口径】左右分栏 / 默认一类买卖 / 当根事件跨层 / 策略点跟柱

- **桌面布局**：K 线在左、策略回测在右；手机仍上下。工作台标签一次只开一页（条件/资金/报告各页）。
- **默认买卖**：新策略买=K0 一类买点出现，卖=K0 一类卖点出现；旧的收盘穿布林仍可自己搭，不再当默认。
- **跨层**：所有钉在当根 K 上的事件（一类/二类/N类、分型确认、中枢确认、Demark 完成买/卖）可 AND/OR 跨层。AND 同一根两边都刚出现；OR 各层出现各打一次。收盘/RSI/上穿下穿仍禁跨层。
- **策略点跟柱**：买/卖标记画进主图底图，柱心与蜡烛同一套；平移时跟着 K 线走（视口快照参与重绘，不再单独一层覆盖）。
- **不变**：缠论打点、冻结、步进当下性、历史记录三个按钮。
- **验证**：连续单步；默认条件是一类买/卖出现；拖图策略点跟柱；K0 分型确认可与 K1 一类买拼，分型确认不能和 K1 RSI 拼。
- **注意**：纯 Flutter；无需重编 DLL。

---

### 2026-09-03 — 【口径】策略回测工作台下移避开标题栏 + 关闭整块台子

- **下移**：电脑打开策略回测后，右侧整块工作台（运行、标签、内容）相对图表区再下移 36（标题栏 36、主区四周已有 4，工作台顶约在窗口 y=40），不再挡住右上角最小化/最大化/关闭。手机仍图上、台下，不再加这段顶距。
- **关闭**：工作台右上角关闭（X）关掉整块策略回测，K 线铺回整屏；设置里「策略回测」还能再打开。不是关软件窗口。
- **不变**：左右分栏、一次一页标签、缠论内核、步进/冻结、历史记录三个按钮。
- **验证**：电脑打开策略回测，运行钮不应挡住窗控；点关闭只留 K 线，设置里能再打开。连续单步，不要只靠一键走完。
- **注意**：纯 Flutter；无需重编 DLL。

---

### 2026-09-03 — 【口径】分笔改走通达信协议 + 笔数缺省 0

- **数据源**：普通股票分笔改从通达信行情口（7709，带笔数的历史分笔指令）取；按日缓存在 `a_Data/.tdx_protocol_cache`，不再把本地导出 txt 当权威。test 股 / 自定义 OHLC 仍走文件。单测仍走 `chan_load_klines` 文件路径。
- **周期**：日线及更长周期仍是「分笔 → 1 分钟 → 升周期」，合成算法不变。
- **笔数**：无列或第 4 列是 B/S 记 **0**，不再默认 1；前端也不再用 tick_side 充 1 笔。
- **弹窗**：所选区间存在笔数=0，或缺主动买/主动卖/中性 → 询问是否继续用筹码分布、笔数分布、峰线、副图 Kn 笔数。点「不继续」：K 线与缠论仍加载；本会话静音上述指标，不改落盘设置。
- **库版本**：`CHAN_FFI_ABI_VERSION` / `kChanFfiAbiVersion` 升到 **2**（新增 `chan_load_klines_ex`）。**须重编并覆盖 `windows/native/chan_ffi.dll`；打 Android 包须另编 so，主清单已加联网权限。**
- **不变**：缠论内核、步进/冻结、买卖点、历史记录三个按钮。
- **验证**：002003 默认 2004 区间应弹笔数窗；2018-01-10 不应弹笔数为 0；日线仍能合成；test 不走协议。连续单步，不要只靠一键走完。

---

### 2026-09-03 — 【口径】去掉仓库里的离线分笔 txt


- **改什么**：`a_Data` 下 001312 / 002003 / 688687 / 920992 的导出分笔全部删除；股票目录只留空位，列表里还能选，加载走通达信协议。
- **保留**：`a_Data/test` 演示和自定义 OHLC；协议缓存 `.tdx_protocol_cache` 不删。
- **发布**：Windows 包不再要求五千个数据文件；Android 种子包按现在的 a_Data 重打（不含导出 txt）。
- **测试**：原先读本地 002003 txt 的对拍在无文件时 skip。
- **不变**：缠论内核、步进/冻结。
- **验证**：冷启动仍能选 002003，分笔从行情口来；test 股仍读文件。

---

### 2026-09-03 — 【口径】阴阳鱼正圆 + 走完小太极 + 有成交不再误报缺数据

- **阴阳鱼**：初始分笔界面改为正圆，直径等于当前窗口高度（最大化后即屏幕工作区高度），不再按窗口拉成椭圆。
- **一次性走完**：过程中显示缩小 4 倍、半透明的阴阳鱼，不挡住取消。
- **弹窗**：有成交量时，通达信早期笔数全 0 或没有中性行，不再当成缺少成交数据。仍缺主动买/卖、或完全没有成交量时才询问筹码/笔数指标。
- **不变**：缠论内核、步进/冻结、历史记录三个按钮。
- **验证**：002003 默认分笔 942 根均有成交量，加载跳过弹窗；初始直径=窗高；走完 overlay 高度因子 0.25、透明度 0.5。

---

### 2026-09-03 — 【口径】笔数分布才弹笔数为 0；走完太极独立转

- **弹窗**：只有设置里开了「笔数分布」，且区间分笔笔数为 0，才弹「分笔笔数为 0」。没开这张图不弹。点「不继续」只本会话关掉笔数分布，不改保存的设置。纠正此前「有成交量就不弹」的误判。
- **走完太极**：Windows 上缩小半透明阴阳鱼画在独立 isolate 的分层窗口里，主界面算线时仍约 16ms 一帧；算线本身仍在界面线程（每段约 200ms+），缠论冻结口径未改。
- **不变**：缠论内核、步进/冻结、历史记录三个按钮。
- **验证**：002003 默认分笔、笔数分布开 → 弹窗；走完时 overlay 平均 16ms/帧，同时 compute chunk 200–469ms。

---

### 2026-09-03 00:20 — 左右分栏、默认一类买卖、当根事件跨层、策略点跟柱

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：用户已确认执行，收尾桌面左右分栏、默认买/卖、当根事件跨层、策略买卖点跟柱。
- **关键操作**：
  1. 策略买卖点画进主图底图，柱心与蜡烛同一套；视口快照参与重绘，平移时点跟着 K 走
  2. 默认买=K0 一类买点出现，默认卖=K0 一类卖点出现；布林穿越改为显式旧口径
  3. 分型确认/中枢确认/Demark 完成买等当根事件也可与一类买跨层 AND/OR；收盘/RSI/上穿下穿仍禁跨层
  4. 桌面 K 线左、工作台右；标签一次一页。补单测与白话演示
- **结果**：指定 5 个 Flutter 测试全部通过（56）。历史记录已写。演示 `2026-09-03-workbench-layout-k0bar`
- **演示**：002003 连续单步；看默认条件、左右分栏、切页、拖图点跟柱、跨层能拼/不能拼
- **注意事项**：纯 Flutter；无需重编 DLL。不要用一键走完代替连续单步。

---

### 2026-09-03 00:50 — 策略回测工作台下移避开标题栏并加关闭

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：电脑上策略回测「运行」与窗口最小/最大/关闭重叠；用户要求整块下移并加关闭（X）。未改缠论内核/步进冻结。
- **关键操作**：
  1. 电脑右侧整块工作台相对图表区再下移 36，运行/标签/内容一起躲开标题栏三键
  2. 工作台右上角关闭（X）关掉整块台子，K 线铺回整屏；设置里「策略回测」可再打开
  3. 手机仍图上台下，不加这段顶距；左右分栏与一次一页不变
- **结果**：`flutter test test/backtest_workbench_test.dart`；历史记录已写。演示 `2026-09-03-workbench-caption-close`
- **演示**：电脑打开策略回测，运行钮不应挡住窗控；点关闭只留 K 线，还能再打开。连续单步，不要只靠一键走完
- **注意事项**：纯 Flutter；无需重编 DLL

---

### 2026-09-03 09:50 — 分笔改走通达信协议，笔数缺省改为 0

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：用户确认执行：分笔权威改为通达信行情协议；日线合成算法不变；没笔数不再当 1 笔；缺笔数/买卖标记时弹窗，不继续则会话内关掉筹码/笔数相关图。
- **关键操作**：
  1. Rust 用带笔数的历史分笔指令拉数，按日缓存在 `.tdx_protocol_cache`；`chan_load_klines` 仍走文件供单测
  2. 新增 `chan_load_klines_ex`，APP 普通股票走 protocol，test 走文件；库协议号升到 2
  3. 无笔数列记 0；前端去掉 tick_side 充 1 笔；加载后按质量弹窗，不继续则会话静音筹码/笔数
- **结果**：`cargo test -p chan_data` 150 通过；`flutter test test/kn_volume_series_compute_test.dart`、`test/chan_ffi_abi_test.dart` 通过。历史记录已写。演示 `2026-09-03-tdx-tick-protocol`
- **演示**：002003 默认 2004 区间应弹笔数窗；2018-01-10 不应弹笔数为 0；日线仍能合成；test 不走协议
- **注意事项**：须重编并覆盖 `windows/native/chan_ffi.dll` 后冷启动。Android 正式包已加联网权限。连续单步，不要只靠一键走完

---

### 2026-09-03 10:20 — 删除 a_Data 离线分笔导出

- **执行者**：cursor
- **任务类型**：配置
- **上下文**：分笔已改走通达信协议，用户要求删掉 a_Data 里的离线导出。
- **关键操作**：
  1. 删除 001312 / 002003 / 688687 / 920992 下全部分笔 txt，目录留空以便股票列表仍能选
  2. 保留 test 演示、自定义 OHLC、协议缓存
  3. 下调发布包文件数门槛；重打 Android 种子 zip；无本地 txt 的 002003 文件测试改为 skip
- **结果**：离线导出已清空。演示仍用默认 002003 走协议
- **演示**：002003 冷启动从行情口拉分笔；test 股仍读文件
- **注意事项**：首次加载需联网。原先依赖仓库 txt 的对拍测试会 skip，直到另备数据

---

### 2026-09-03 11:05 — 阴阳鱼正圆、走完小太极、有成交不再误报缺数据

- **执行者**：cursor
- **任务类型**：Bug修复
- **上下文**：初始阴阳鱼被拉成椭圆；一次性走完看不到太极；002003 默认区间明明有成交量仍弹缺数据。
- **关键操作**：
  1. 太极改为正圆，直径等于当前窗口高度
  2. 一次性走完时显示缩小 4 倍、半透明阴阳鱼
  3. 有成交量则不因笔数全 0 或缺中性行弹窗；仍缺主动买/卖才问
- **结果**：运行日志对照：加载 `qShouldPrompt=false` 且 `skip prompt`；初始 `diameter=窗高`、`scale=1`；走完 `heightFactor=0.25`、`opacity=0.5`。历史记录已写。
- **演示**：默认股票 002003 分笔可验
- **注意事项**：纯 Flutter，无需重编 DLL。连续单步仍用于缠论验收；本次走完动画用长按右侧验

---

### 2026-09-03 12:20 — 笔数分布才弹笔数为 0；走完太极独立转

- **执行者**：cursor
- **任务类型**：Bug修复
- **上下文**：开启笔数分布时笔数为 0 应弹窗却被「有成交量」规则吃掉；一次性走完时太极跟算线一起卡。
- **关键操作**：
  1. 弹窗改为：仅当笔数分布已开且笔数为 0 才提示；启动先读完设置再加载
  2. Windows 走完太极改到独立 isolate 分层窗口，不跟界面线程算线抢时间
- **结果**：日志：`tickDistOn=true` 且 `will show zero-tick dialog`；走完 overlay 平均 16ms/帧，同时算线段 200–469ms。历史记录已写。
- **演示**：默认股票 002003 分笔可验
- **注意事项**：无需重编 DLL。Android 走完仍用 Flutter 层太极（主路径是 Windows）

---

### 2026-09-04 — 【口径】策略同一根K可拼 + 走完太极正中 + 价签叠筹码


- **策略**：K0 比例>=1.382 并且最低价<=筹码峰-1 是合法的。两边都按这一根 K 取值，不是混层。比例仍不能直接和价格比；K0 收盘仍不能和 K1 布林/RSI 硬拼。
- **太极**：一次性走完时阴阳鱼对准当前窗口正中心。Windows 独立窗按窗口屏幕矩形居中，不再把逻辑像素当成物理像素偏到一边。
- **价签**：开筹码/笔数分布时，Y 轴数字仍在主图右侧，允许和柱子重叠，不再挪到最左边。
- **不变**：缠论内核、步进/冻结、历史记录三个按钮。
- **验证**：策略工作台配上述买卖条件应能编译；002003 一次性走完看太极是否在窗口正中；开筹码看右侧价签。

---

### 2026-09-04 10:30 — 太极居中、指标读数箭头、筹码角标字号

- **执行者**：cursor
- **任务类型**：Bug修复 / 功能恢复
- **上下文**：一次性走完太极偏上；主/副图指标读数面板被移除；筹码 B/S/灰度角标字太小。
- **关键操作**：
  1. 一次性走完太极按图表内容区居中（避开标题条/边距/进度条；Windows 独立窗同步）
  2. 主/副图伸展钮右侧恢复向右箭头：展开已选指标名+副图读数；单击名称灰度/删除线开关绘制
  3. 筹码分布 B/S/灰度/当前角标字号 8→12
- **结果**：相关单测通过；UI 层改动，未动步进/冻结内核
- **演示**：默认 002003 → 点「一次性走完」看太极是否在画面正中；主/副图点右箭头看读数条；开筹码看右侧角标字号
- **注意事项**：无需重编 DLL

---

### 2026-09-04 10:50 — 修复 IndicatorChipEntry 重复定义导致 Windows 编不过

- **执行者**：cursor
- **任务类型**：Bug修复
- **上下文**：恢复读数条后，chip 与 overlay 两个文件各有一个 `IndicatorChipEntry`，`flutter run -d windows` 报重复导入。
- **关键操作**：
  1. 删掉全屏选择面板里残留的旧类定义，只保留读数条那份
- **结果**：`dart analyze` 不再报该类冲突
- **演示**：重新 `flutter run -d windows` 即可
- **注意事项**：无需重编 DLL

---

### 2026-09-04 14:50 — 策略同一根K可拼、走完太极居中、价签叠筹码

- **执行者**：cursor
- **任务类型**：Bug修复 / 口径澄清
- **上下文**：策略「K0 比例>=1.382 并且最低价<=筹码峰-1」被拦成混层；一次性走完阴阳鱼不在正中；开筹码后 Y 轴数字跑到最左边。
- **关键操作**：
  1. 判定该场景合法：不是混层，是同一根 K0 上连线钟和价钟 AND
  2. 放开「都按这一根 K 取值」的 AND/OR；比较/穿越、K0 与 K1 虚拟K 仍禁止
  3. Windows 走完太极按窗口屏幕矩形居中；Flutter 层去掉人为边距
  4. Y 轴价签改回右侧并画在筹码层上面，允许重叠
- **结果**：相关单测覆盖用户策略；历史记录已写；未动缠论内核
- **演示**：默认 002003：策略工作台配上述条件应能运行；点一次性走完看太极是否在窗口正中；开筹码/笔数分布看右侧价签
- **注意事项**：无需重编 DLL。连续单步口径未改

---

### 2026-09-05 — 【口径】策略买卖点形状 / N类BS填N / 指标单击 / 设置按钮

- **需求**：策略买圆卖三角改为都用三角并按组号与箭头交替；一类/二类/N类条件合并为填 N；指标分类唯一子项单击即选；设置机器学习问号左移、按钮等宽。
- **变更**：
  - 策略点：买1/卖1 三角，买2/卖2 箭头；买在柱下尖朝上，卖在柱上尖朝下。
  - 策略积木：一类/二类并入 N类BS，N=1/2 仍走 BUY1/BUY2；旧 id 兼容。
  - 主副图选择：分类只有一项时直接勾选，不再进子菜单。
  - 设置：问号叠在按钮左侧，按钮高度统一 42。
- **口径**：缠论一类/二类副图绘制与冻结未改；只改策略积木与图上策略标记形状。
- **验证**：`buy_n_var_test`、`indicator_picker_hierarchy_test`、`backtest_workbench_test`。

---

### 2026-09-05 — 【口径】N类BS 0/-1=该侧全部

- **需求**：策略 N 填 0 或 -1 表示该侧全部买卖点。
- **变更**：BUY_N.0 / SELL_N.0 并集一类+二类+三类及以上；-1 与 0 同义。同一根 K 多种买点仍只出一次买信号。
- **验证**：`buy_n_var_test` 覆盖 0/-1 并集与 N=1 仍只取一类。

---

### 2026-09-05 — 【口径】策略跨层指标 AND/OR：同一根 K0 刚发生

- **改什么**：买/卖条件里，各层指标（收盘/RSI/布林/比例等）各自算完后允许 AND 或 OR 跨层拼。例如 K0 最低价下穿布林下轨 AND K1 最低价下穿布林下轨。
- **AND**：必须同一根 K0 两边都刚发生；穿越/事件不往后延（不是「K1 下穿后在这根虚拟K里一直算数」）。
- **OR**：哪一层先发生就先出信号。
- **仍禁止**：同一条比较或穿越混层（K0 最低价去穿 K1 布林）；比例直接和价格比。
- **口径**：颗粒度是 K0 时，正在长的那根虚拟K也是真样本，发现根就是这根 K0。
- **不变**：缠论打点、冻结、步进当下性、历史记录三个按钮。
- **验证**：条件编译/求值单测；002003 连续单步后在策略里搭跨层布林 AND 应能编过。
- **注意**：纯 Flutter；无需重编 DLL。

---

### 2026-09-05 09:10 — 筹码峰编号说明、策略点形状、N类BS、指标单击、设置对齐

- **执行者**：cursor
- **任务类型**：功能开发 / UI
- **上下文**：先讲清筹码/笔数峰 -1/+1；策略买圆卖三角不好分；一类/二类/N类三组重复；指标分类只有一项还要再点一层；机器学习问号挤窄按钮。
- **关键操作**：
  1. 策略买/卖都改三角，按组号奇偶交替箭头
  2. 策略条件一类/二类/N类合并成 N类BS，用户填 N；N=1/2 仍走原来的一类/二类
  3. 主副图指标：分类下只有一项时点一下就勾选
  4. 机器学习问号移到按钮左侧，设置按钮统一高度宽度
- **结果**：相关单测已补；历史记录已写；未动缠论步进/冻结内核
- **演示**：test 演示 id=2026-09-05-ui-bs-picker-settings；默认 002003 可验
- **注意事项**：无需重编 DLL。连续单步看策略三角/箭头；不要只用一键走完

---

### 2026-09-05 09:30 — N类BS 填 0 或 -1 表示该侧全部买卖点

- **执行者**：cursor
- **任务类型**：功能开发
- **上下文**：策略 N 类 BS 需要一个「全部类号」的写法。
- **关键操作**：
  1. N=0 或 -1 时，买点吃一类+二类+三类及以上买点，卖点同理
  2. 输入框允许负号；落盘统一写成类号 0
- **结果**：单测覆盖 0/-1 并集与 N=1 仍只取一类
- **演示**：test 演示 id=2026-09-05-ui-bs-picker-settings
- **注意事项**：无需重编 DLL。不是把买和卖混成一条条件

---

### 2026-09-05 23:40 — 策略跨层指标 AND/OR（同一根 K0 刚发生）

- **执行者**：cursor
- **任务类型**：功能开发 / 口径
- **上下文**：确认执行：K0 最低价下穿布林下轨 AND K1 最低价下穿布林下轨应能拼；定「同一根刚发生」，不要 hold。所有走这套 AND/OR 门禁的指标一起改。
- **关键操作**：
  1. 单条比较/穿越仍禁混层；AND/OR 放开跨层与跨钟族
  2. AND 按同一根 K0 取交集，穿越/事件不往后延；OR 铺到全部 K0，各层出现各打一次
  3. 工作台标题、回测说明、历史记录、演示同步白话口径
- **结果**：相关单测覆盖同根/错开/OR；演示 id=2026-09-05-cross-kn-indicator-and-or
- **演示**：默认 002003 可验；test 演示 id=2026-09-05-cross-kn-indicator-and-or
- **注意事项**：无需重编 DLL。连续单步后再开策略回测；不要只用一键走完

---

### 2026-09-09 09:35 — 合并智能体规则为 AGENTS.md

- **执行者**：cursor
- **任务类型**：配置 / 文档
- **上下文**：Cursor 每轮同时套用 .mdc、AGENTS.md、CLAUDE.md，门禁重复；长期记忆又要求再读一份长文。
- **关键操作**：
  1. 把确认执行、task-log、白话演示、代码规范、CHAN_RUST 口径收进 `AGENTS.md` 一份正文
  2. 删除 `AGENT_LONG_TERM_MEMORY.md` 与 `.cursor/rules/agent-long-term-memory.mdc`
  3. `CLAUDE.md` / `OPENCODE.md` / WorkBuddy / Trae memory skill 改成一行指针
  4. 演示 README、历史记录、设置提示里的旧路径改为 `AGENTS.md`
- **结果**：规则正文只剩 `AGENTS.md`；未改缠论步进/冻结内核
- **演示**：全新功能·免对比（文档入口整理）
- **注意事项**：无需重编 DLL。下次会话应只常驻注入 `AGENTS.md`（`CLAUDE.md` 若仍被 Cursor 加载，只会是一行指针）

---

### 2026-09-09 09:50 — 两份任务日志按时间合并为 task-log.md

- **执行者**：cursor
- **任务类型**：配置 / 文档
- **上下文**：根目录 `TASK_LOG.md`（要点日志，倒序）与 `task-log.md`（完整条目，追加到末尾）并存，智能体入口不统一。
- **关键操作**：
  1. 两份共 175 条按日期从早到晚并入 `task-log.md`（无时刻的当天条目排在有时刻条目之前；原 `TASK_LOG.md` 倒序已翻正）
  2. `2026-08-12` 一/二类 BS V2.1 从夹在 7 月条目中挪到 8 月 10 日之后
  3. 还原 7 月 28 日乱码条（窗口铺满工作区 + tooltip 分隔线）；拆开粘在上一行末尾的「统一中枢框架」条
  4. 删除根目录 `TASK_LOG.md`；`AGENTS.md` 口径入口改为根 `task-log.md`；`CHAN_RUST/TASK_LOG.md` 仍单独记 CHAN_RUST 口径，不并入
- **结果**：根目录只留一份 `task-log.md`；未改缠论步进/冻结内核
- **演示**：全新功能·免对比（文档整理）
- **注意事项**：无需重编 DLL。后续任务仍追加到本文件末尾

---

### 2026-09-09 09:55 — 加固 build_rust.ps1 清理残留插件联接

- **执行者**：cursor
- **任务类型**：脚本 / 文档
- **上下文**：`build_rust.ps1` 编完 DLL 后 `flutter run` 报 PathExistsException：`windows/flutter/ephemeral/.plugin_symlinks/jni` 已存在（errno 183）。上次异常退出联接残留；在 `scripts` 目录执行 `flutter clean` 无效。
- **关键操作**：
  1. `build_rust.ps1` 启动前只拆 `.plugin_symlinks`（不删整个 ephemeral）；联接用 `rmdir`，避免 `Remove-Item -Recurse` 跟进 pub 缓存
  2. `flutter run` 30 秒内非 0 退出则再清一次并重试一次
  3. 未删 `CHAN_RUST/scripts` 其它文件（发布/Android/闸门脚本均有调用方）；README 补全脚本列表，并写明 Flutter 命令必须在 `chan_kline` 下执行
- **结果**：启动脚本可自清残留 `jni` 联接；未改缠论步进/冻结内核
- **演示**：全新功能·免对比（脚本加固）
- **注意事项**：无需重编 DLL。仍用 `.\CHAN_RUST\scripts\build_rust.ps1` 启动即可

---

### 2026-09-09 10:25 — 清理非 CHAN_RUST 残留，三份日志按时间并成一份

- **执行者**：cursor
- **任务类型**：配置 / 文档
- **上下文**：仓库根目录还留着旧 Python 缠论模块和回放缓存；`task-log.md`、`CHAN_RUST/TASK_LOG.md`、十字 tooltip 审计稿三份并存。
- **关键操作**：
  1. 删除未入库的旧工程目录：`Combiner` / `Common` / `DataAPI` / `KLine` / `Math` / `Seg` / `ZS` / `ChanModel` / `a_Script` / `a_replay_core` / `a_replay_cache` / `a_rust_core`
  2. 三份日志按日期从早到晚并入根目录 `task-log.md`（237 条：口径 58 + 审计 1 + 原任务 178）；口径条目标【口径】，审计标【审计】；无时刻条目排在当天有时刻条目之前
  3. 删除 `CHAN_RUST/TASK_LOG.md` 与 `CHAN_RUST/tooltip_audit_2026-08-14.md`；`AGENTS.md` 改为只写这一份 `task-log.md`
  4. `.gitignore` 去掉已删除的 `a_replay_*` / `a_rust_core` 路径
- **结果**：根目录只留 `CHAN_RUST`、`a_Data`、智能体入口和这一份任务日志；未改缠论步进/冻结内核
- **演示**：全新功能·免对比（仓库整理）
- **注意事项**：无需重编 DLL。`a_Data` 仍与 `CHAN_RUST` 同级，加载股票和演示都走这里

---

### 2026-09-09 — 检查并补充 CHAN_RUST/README.md

- **执行者**：Kilo
- **任务类型**：文档 / 配置
- **上下文**：用户要求检查 README.md 并补充缺失/过时内容。
- **关键操作**：
   1. 核对项目实际结构与 README 声称一致：修复 Android 环境安装脚本路径错误（`.cursor/scripts/install-android-env.sh` 位于工程根目录而非 `CHAN_RUST/` 内）。
   2. 补充 FFI 接口表，新增 `chan_load_klines_ex`、`chan_save_test_ohlc`、`chan_pipeline_*` 会话 API、`chan_chip_profile`、`chan_ml_predict` 等 11 个函数。
   3. 更新项目描述，反映当前已非仅「首期聚合 K 线」。
   4. 新增 `## 已实现功能速览` 节，概括 Pipeline Delta+Incremental Lookup、背驰 v12、BS 全类、笔数分布、斜率延伸趋势线、Demark、中枢判断确认副图、ML 闭环、历史记录审计、筹码设置、tick 分笔、tooltip 格式化等 12 项。
   5. 更新 `## 后续规划`：Normal/OverSeg 双中枢已统一为单套 ZS；补充背驰/BS/笔数/斜率/Demark/中枢判断确认/ML/Pipeline Delta/历史记录等已实现项；新增全量离线库一键导入、策略回测框架。
   6. 清理 `## 实现约束与口径` 中过时的 `中枢(Normal|OverSeg)` 引用。
- **结果**：`CHAN_RUST/README.md` 从 245 行扩展至 275 行；`CHAN_RUST/scripts/build_rust_android.sh` 错误提示路径已修正。
- **注意事项**：未改缠论步进/冻结内核；未改 Rust 计算逻辑。

---

### 2026-09-09 — 精简 AGENTS.md，技术口径迁入 CHAN_RUST/README.md

- **执行者**：Kilo
- **任务类型**：重构 / 文档整理
- **上下文**：AGENTS.md 是智能体规则的唯一正文，但混入了大量 CHAN_RUST 技术实现约束，导致维护两份口径。精简 AGENTS.md 只保留行为规则，技术口径统一迁入 README.md。
- **关键操作**：
   1. 在 README.md 的 `## Kn 递归流水线` 节末尾新增 `## 实现约束与口径` 节，迁入 AGENTS.md 中 README 尚无的 6 个技术区块：一次性呈现逐K增强说明、分型/中枢判断·确认对象、一类BS/步进当下性、方案B层号、Kn相邻比例/Kn步进节奏、Math指标/副图绑定/十字asOf；同时迁入项目定位/计算模式/代码引用规范/开发限制/设计约束/增删改查约束/数据约束。
   2. 将 README.md 中 `## Kn 递归流水线` 节内的一类BS 3 条简略 bullet 替换为 AGENTS.md 完整版（含验收门槛、Flutter 方法名、rawLostN/histLostN、V2.1 等细节），去重合并。
   3. 删除 AGENTS.md 中 9 个技术区块（实现约束、一次性呈现、逐K当下性、Flutter 历史记录、项目定位/计算模式/设计约束/数据约束、分型/中枢判断·确认对象、一类BS/步进当下性、方案B层号、Kn相邻比例/节奏、Math指标/副图绑定/十字asOf），仅保留角色、门禁、完成后、代码规范、禁止。
   4. AGENTS.md 末尾追加一行指针：`技术口径详见 CHAN_RUST/README.md「实现约束与口径」节。`
- **结果**：AGENTS.md 从 121 行精简到 42 行；README.md 从 182 行扩展到 245 行；新增 `## 实现约束与口径` 节完整承接全部技术口径。CLAUDE.md / OPENCODE.md 无需改动。
- **注意事项**：后续口径变更只需更新 README.md，无需同步 AGENTS.md。

---

### 2026-09-09 16:40 �?��֤ CHAN_RUST/README.md �ĸ���
- **执行�?**: ��֤ CHAN_RUST/README.md �ĸ���
- **任务类型**: ����ȷ��
- **上下�?**: CHAN_RUST/README.md
- **关键操作**:
  1. �Ķ��� README.md �ļ�����
  2. ������ļ���ʽ���½�������
- **结果**: ��

---

### 2026-09-09 — 桌面脚本改为自动获取公网地址

- **执行者**：Cursor Grok
- **任务类型**：脚本
- **上下文**：桌面 `FreeLLMAPI-CursorConfig.bat` 原先要手填 Cloudflare 公网地址；Quick Tunnel 每次都会变，手填必然过期。
- **关键操作**：
  1. `freellmapi-cursor-config.ps1` 改为先探测本机已有隧道（Cloudflare / localhost.run / Serveo），不通再自动新建。
  2. API Key 优先从 FreeLLMAPI 库里读，不再为公网地址弹窗。
  3. 拿到地址后复制剪贴板，并调用 `npx freellmapi setup-cursor`。
- **结果**：双击桌面 bat 即可自动拿公网 Base URL，无需手填。
- **演示**：确保 FreeLLMAPI 托盘在跑，双击桌面 `FreeLLMAPI-CursorConfig.bat`，弹窗应出现一串 `https://…/v1`，粘贴到 Cursor Override OpenAI Base URL 即可。

---

### 2026-09-10 — 重试给 Agent Debate 接上本机 FreeLLMAPI

- **执行者**：Cursor Grok
- **任务类型**：配置
- **上下文**：Agent Debate 环境变量已经写了本机网关，但辩论开不起来。日志里 Codex / Claude 两段在 PATH 里找不到 ACP 命令，只剩 OpenCode 这一段，不够最少 2 个 Agent。
- **关键操作**：
  1. 全局安装 `@agentclientprotocol/codex-acp`、`@agentclientprotocol/claude-agent-acp`。
  2. Cursor 设置改成 npm 下的绝对路径 `.cmd`，并带上 FreeLLMAPI 密钥与本机 `127.0.0.1:31415`。
  3. 启动超时放到 90 秒。
- **结果**：本机网关 `/v1/models` 返回 291 个模型；Codex、ClaudeCode、OpenCode 都能完成 ACP 握手并开出新会话。
- **演示**：保持 FreeLLMAPI 开着 → Cursor `Ctrl+Shift+P` 执行 Developer: Reload Window → 左侧 Agent Debate 输入题目发送。副图应同时出现至少两个 Agent 在说话，而不是只剩 OpenCode。不要在插件设置页点保存 Agents，那会把网关环境变量清空。
