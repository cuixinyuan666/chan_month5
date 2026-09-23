读仓库根 [`AGENTS.md`](../../AGENTS.md)。

## 工具接入
- Obsidian：已接入。vault 路径 `C:\Users\86185\Documents\Obsidian Vault`（从 %APPDATA%/obsidian/obsidian.json 发现）。使用 user-level skill `obsidian-writer`（零依赖，直接读写 .md/.canvas，无需 Obsidian 运行）。
- grill me：已安装 user-level skill `nox-grill-me`（对计划/设计持续追问直到达成共识，触发词 "grill me"）。

## Obsidian 任务过程记录约定
- Vault：`C:\Users\86185\Documents\Obsidian Vault`（用 `obsidian-writer` skill 读写）。
- 项目笔记文件夹：`chan-month5/`（Vault 顶层，无数字编号）。
- 主源：`chan_month5/task-log.md`（唯一源）；Obsidian 为**副本**，按日归档（38 篇日期笔记 + `MOC.md` + `index-memory.md` / `index-plans.md` / `index-demos.md`）。
- 每次完成任务：追加 task-log 后，同步写当日 `chan-month5/YYYY-MM-DD.md` 并更新 `MOC.md` 索引（详见 AGENTS.md「完成后」）。**禁止在 Obsidian 手改任务原文**，修订须先回写 task-log 再同步。
- 项目记忆镜像：`.workbuddy/memory/*.md`（WorkBuddy 直接读写的项目记忆，含每日工作日志与 `MEMORY.md`）已复制进 Vault `chan-month5/memory/`（原文保真，源保留）；修订后跑 `sync_memory_to_obsidian.py` 重新同步，勿手改副本。
- 已有 `01-projects/chan-regression-channel.md`（回归通道设计）留原地不迁移，仅在 MOC 中放链接。
- 历史缺口：task-log 最早 2026-07-26；此前仅有 2026-07-14 / 07-15 零散记忆（见 `chan-month5/index-memory.md`）。

## Flutter 工程与本机环境（高频复用）
- **Flutter 包根目录是 `CHAN_RUST/flutter/chan_kline`（不是仓库根！）**；源码在 `lib/`，测试在 `test/`。
- flutter 可执行文件：`C:/src/flutter/bin/flutter.BAT`。验证改动：`flutter analyze --no-pub`（关注 `error` 级；`test/` 下大量 pre-existing info/warning 可忽略）。
- `flutter test` 在本沙箱默认会报 `Unable to connect to flutter_tester`（代理劫持 localhost WebSocket）。**解决办法：清掉所有 proxy 环境变量并设 `no_proxy=*` 后再跑**（用 managed Python subprocess 传 env）。
- 本机 bash 偶发 PATH 损坏（`dirname`/`head`/`tail`/`cat`/`rm` 找不到）。**兜底：用 managed Python** `C:/Users/86185/.workbuddy/binaries/python/versions/3.13.12/python.exe` 跑脚本、读写/删文件。

## Flutter UI 踩坑（本项目已踩）
- **`IntrinsicWidth` 不要包裹「Column + Expanded(ListView)」**：ListView 是可滚动控件、无固有宽高，固有测量阶段 Expanded 拿不到高度 → 面板塌陷（表现为"只剩变暗遮罩、面板不显示"）。
- 想让面板宽度"随内容自适应"，正确做法是**用 `TextPainter` 量出内容宽，再给定确定尺寸**（`BoxConstraints(minWidth: w, maxWidth: w, maxHeight: maxH)`），而不是靠 `IntrinsicWidth`。
- 删除嵌套 widget 开括号时**必须成对删掉它的 `),`**，否则 `return xxx(...)` 多一个 `)` → analyze 报 `expected_token`。改完立刻 `flutter analyze` 兜底。
- 改 UI 后若无法目视验收，可临时写 widget 测试断言"面板尺寸非零 + 关键文案可见"，验证后**按 AGENTS.md 规范删除测试文件**。
- **条件包裹丢 State**：在「直接返回 child」与「包一层 Row/LayoutBuilder」之间切换，child 的 Element/State 会被整体重建（无 GlobalKey 时）——tooltip dock 显隐曾因此丢十字线/视口。修法首选**包裹结构恒存在 + `Offstage` 控显隐**（offstage 时占 0 宽、不 paint 不命中、子树仍 build）；GlobalKey 重 parenting 是次选。
- 涉及十字线/dock 子窗口的联动：改 `_crosshairMode` 后**必须调 `_publishTooltipToBridge()`**，否则桌面 dock 左侧子窗口不跟显隐；图表宽度变化且十字线激活时要用 `barCenterX(barIdx, 新宽)` 重算 `_crosshairX`。另注意：鼠标中键入口是 `_toggleTooltipKeepCrosshair`（`_onPointerDown` 判 `kMiddleMouseButton`），别改错成 `_cycleCrosshair`（那是触屏双击中间区路径）。
