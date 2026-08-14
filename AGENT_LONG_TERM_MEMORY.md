# 智能体长期记忆（全项目 · 常驻）

> 适用：**Cursor**、**OpenCode**、**Claude Code**、**WorkBuddy**、**Trae** 及本仓库内一切编码智能体。  
> 与 `AGENTS.md` 同级约束；口径/行为变更另写 `TASK_LOG.md`、`CHAN_RUST/TASK_LOG.md`、`lib/history/msg_history.dart`。

---

## 0. 接任务前必读（强制）

**接受任何任务指令时**，须先阅读（按顺序）：

| 顺序 | 文件 | 说明 |
|------|------|------|
| 1 | **本文件** `AGENT_LONG_TERM_MEMORY.md` | 主规范 |
| 2 | [`AGENTS.md`](AGENTS.md) | 角色 + CHAN_RUST 常驻口径 |
| 3 | 工具专用入口（存在则读） | [`CLAUDE.md`](CLAUDE.md) · [`OPENCODE.md`](OPENCODE.md) · [`.cursor/rules/agent-long-term-memory.mdc`](.cursor/rules/agent-long-term-memory.mdc) · [`.workbuddy/memory/MEMORY.md`](.workbuddy/memory/MEMORY.md) · [`.trae/skills/chan-agent-memory/SKILL.md`](.trae/skills/chan-agent-memory/SKILL.md) |

未读上述文件不得开始改代码。各工具维护者应在各自配置中指向本文件（见 §4）。

### 0.1 关键逻辑修改：须用户「确认执行」

**没有用户在对话中包含「确认执行」字样，禁止修改 app 的关键逻辑代码。**

| 允许（无需确认执行） | 须先文字提方案，等「确认执行」后才能改 |
|----------------------|----------------------------------------|
| 阅读、分析、回答问题 | Rust：`chan_data` 缠论内核（合并/分型/段/中枢/买卖点/步进管道等） |
| 写/改演示说明、`task-log`、记忆类 md | Flutter：步进/冻结/会话历史合并、主图绘制语义、`chan_bridge` 管道 |
| 改 `a_Data/test/demos/` 白话文案 | 影响「步进当下性」「冻结不回写」的任何逻辑 |
| 用户**已写明**「确认执行」后的按指示修改 | `a_replay_trainer` 持久化相关逻辑 |

**需要改关键逻辑时**：只用文字说明「想改什么、为什么、影响范围、怎么验」，末尾明确写：**请回复「确认执行」后我再改代码。** 不得先改再问。

「确认执行」以用户原话包含该四字为准；不要用「好的」「继续」自行等同。

### 0.2 演示阶段文案：白话优先

`before.md` / `after.md` / `manifest` 的 `beforeSummary`、`afterSummary`、`verificationPoints`、`walkthroughSteps[].caption`：

- **用你和用户沟通时的口语 + 缠论术语**（K0、一类买点、中枢、步进、副图等）。
- **禁止**大段贴代码、函数名、文件路径当说明（路径最多在 task-log 给智能体看）。
- 写法示例：✅「走到第 12 根 K，副图应出现一颗 1Ba，下一步这颗点还在」；❌「`mergeBsHistory` 在 step=12 输出 `Buy1Frame`」。

---

## 1. 任务完成后：必须写 Task Log

**任何修改类任务在声称完成前**，至少追加一条日志（不可只改代码不写记录）：

| 文件 | 用途 | 何时写 |
|------|------|--------|
| [`task-log.md`](task-log.md) | **全智能体任务台账**（执行者、类型、操作、结果） | **每次**完成任务 |
| [`TASK_LOG.md`](TASK_LOG.md) | 工程级要点（Python/通用） | 影响旧工程或跨模块时 |
| [`CHAN_RUST/TASK_LOG.md`](CHAN_RUST/TASK_LOG.md) | CHAN_RUST 口径/行为变更 | 改 Rust/Flutter 缠论语义时 |
| [`CHAN_RUST/flutter/chan_kline/lib/history/msg_history.dart`](CHAN_RUST/flutter/chan_kline/lib/history/msg_history.dart) | 用户可见「历史记录」文案 | UI/口径对用户可见时 |

### `task-log.md` 条目格式（追加到文件末尾）

```markdown
### YYYY-MM-DD HH:MM — {任务标题}

- **执行者**：{cursor / opencode / claude-code / workbuddy / …}
- **任务类型**：{功能开发 / Bug修复 / 重构 / 配置 / 文档 / 演示}
- **上下文**：{一句话背景}
- **关键操作**：
  1. …
  2. …
- **结果**：{产出文件、验证命令、是否已写演示}
- **演示**：{默认股票可验 / test 演示 id=… / 全新功能免对比}
- **注意事项**：{DLL 重编、连续单步验收等}
```

---

## 2. 每次「修改任务」交付物（双部分）

除写日志外，**可视验证**须满足下列 **A + B**（**全新功能**可免 B，须在日志 `演示` 行注明 `全新功能·免对比`）。

### A. 可演示的示例数据 + 页面说明

1. **优先**用当前默认数据验收（默认股票 `002003`、默认区间/周期，见 `main.dart` `_preferredCode` / `_codeDefaultRanges`）。
2. 若默认数据**无法**清晰展示本次改动：
   - 在股票下拉 **`test`** 下增加可复现演示（见 [`a_Data/test/demos/`](a_Data/test/demos/)）；
   - 在演示页**逐条写明**：验证用 K 线索引、层号、应出现的标记/副图读数、连续单步顺序。
3. 演示数据落盘：
   - `a_Data/test/demos/{task_id}/demo.ohlc.csv`（可选，专用于本任务）；
   - `a_Data/test/demos/{task_id}/manifest.json`（必填元数据）；
   - `before.md` / `before.png`（修改类任务必填其一，见 B）。

### B. 原本实现 vs 本次实现（同页上下对比）

**修改既有逻辑**时（非从零新建模块）：

| 区域 | 内容 |
|------|------|
| **上半区·原本实现** | 改代码**前**快照：`before.md` 文字说明 + 可选 `before.png`；写清旧行为、旧 bug、旧 UI |
| **下半区·本次实现** | 改代码**后**：`after.md` 或 manifest 内 `afterSummary` + 验证步骤；可一键把 `demo.ohlc.csv` 载入 `test` 后在主图对照 |

**打开方式**：设置里股票选 `test` → **「任务演示 / 前后对比」** → 选任务条目；或设置里 **「任务演示列表」**。

**全新实现**（仓库中无可对比旧版）：只交付 A + 日志注明免 B。

---

## 2.1 开发演示阶段（启动 exe 自动加载 · 2026-08-15）

**默认开启**（落盘 `CHAN_RUST/flutter/chan_kline/.chan_task_demo_settings.json` 的 `developmentDemoPhase`）。

| 状态 | 行为 |
|------|------|
| **演示阶段·开**（默认） | 冷启动后自动加载 `a_Data/test/demos/` **最新** `manifest.json`（`autoLaunchOnStartup≠false`）；主图底部叠层：**左=原本、右=本次**；**下一步** / **自动播放** 按 `walkthroughSteps` 或 `keySteps`+`verificationPoints` 步进 K 线 |
| **演示阶段·关** | 用户明确退出（设置关「开发演示阶段」或叠层「退出演示阶段」）→ **不再**自动加载；自行选股 / 「任务演示列表」 / 「手动打开最新任务演示」 |

### manifest 扩展字段

```json
{
  "autoLaunchOnStartup": true,
  "walkthroughSteps": [
    { "stepIdx": 12, "phase": "before", "caption": "原本：走到第 12 根，副图上还没有这颗买点" },
    { "stepIdx": 12, "phase": "after", "caption": "这次：同一根 K 上应看到 1Ba 亮出来" },
    { "stepIdx": 17, "phase": "after", "caption": "再点一步到第 17 根，上一颗点不能消失" }
  ]
}
```

- `phase`：`before` | `after` | `both`（控制叠层左右高亮）
- 未写 `walkthroughSteps` 时由 `keySteps` + `verificationPoints` 自动生成（修改类任务会插入 before 步）
- **caption 一律白话**，见 §0.2

---

## 3. 演示目录约定

```
a_Data/test/demos/
  README.md
  _template/          # 复制改 task_id 即可
    manifest.json
    before.md
    demo.ohlc.csv     # 可选
  {task_id}/          # 例：2026-08-15-bsp-verdict-leave
    manifest.json
    before.md
    after.md          # 可选，与 manifest.afterSummary 二选一
    before.png        # 可选
    demo.ohlc.csv     # 可选
```

### `manifest.json` 最小字段

```json
{
  "id": "2026-08-15-example",
  "title": "任务标题",
  "completedAt": "2026-08-15",
  "agent": "cursor",
  "isNewFeature": false,
  "beforeSummary": "原本行为一句话（白话）",
  "afterSummary": "这次改完后一句话（白话）",
  "verificationPoints": [
    "走到第 12 根 K：副图应出现 …",
    "再步进一根：上一颗点还在"
  ],
  "keySteps": [12, 13],
  "demoCsv": "demo.ohlc.csv",
  "defaultStock": {
    "code": "002003",
    "period": "1min",
    "note": "若默认数据即可验收，填此项并可在 manifest 省略 demoCsv"
  }
}
```

---

## 4. 各智能体如何加载本记忆（须配置到「接任务即读」）

| 智能体 | 入口（任务开始必须打开） |
|--------|--------------------------|
| **全部** | [`AGENT_LONG_TERM_MEMORY.md`](AGENT_LONG_TERM_MEMORY.md) + [`AGENTS.md`](AGENTS.md) |
| **Cursor** | [`.cursor/rules/agent-long-term-memory.mdc`](.cursor/rules/agent-long-term-memory.mdc)（`alwaysApply: true`） |
| **Claude Code** | [`CLAUDE.md`](CLAUDE.md) → 指向本文件 |
| **OpenCode** | [`OPENCODE.md`](OPENCODE.md) → 指向本文件 |
| **WorkBuddy** | [`.workbuddy/AGENT_READ_FIRST.md`](.workbuddy/AGENT_READ_FIRST.md) + [`.workbuddy/memory/MEMORY.md`](.workbuddy/memory/MEMORY.md) |
| **Trae** | [`.trae/skills/chan-agent-memory/SKILL.md`](.trae/skills/chan-agent-memory/SKILL.md) |

维护者新增智能体时：在仓库根增加 `XXX.md` 单行指向本文件，并更新本表。

---

## 5. 完成自检清单（智能体自用）

- [ ] 已读 §0 / `AGENTS.md`（接任务前）  
- [ ] 改关键逻辑前已取得用户「**确认执行**」  
- [ ] `task-log.md` 已追加条目  
- [ ] 口径变更已同步 `TASK_LOG.md` / `msg_history.dart`（如适用）  
- [ ] 默认数据或 `test` 演示可复现  
- [ ] 演示文案为**白话**（§0.2），非代码引用  
- [ ] 修改类：`before.*` + 下半区说明已就绪  
- [ ] Rust 改动：已重编 `chan_ffi.dll` 并注明冷启连续单步验收  
- [ ] 调试用临时代码/单测垃圾已删（规则 9）

---

## 6. 本规范自身的演示

- **演示 id**：`2026-08-15-agent-long-term-memory`（见 `a_Data/test/demos/`）
- **验证**：股票 `test` →「任务演示 / 前后对比」→ 打开上述条目，可见上下对比布局与加载演示数据按钮。
