# 多 Agent 协同规则（调用细节）

> 本文件是 AGENTS.md「多 Agent 协同规则」入口的**完整落地文档**。AGENTS.md 只保留入口指针，细节以此文件为准。
> 规则由 grill-me 采访构想，2026-10-11 定稿；同日经 grill-me 二次采访重构（发现机制 / 选型主权 / 中转保真 / 裁决下沉 / 失败兜底 六处）。

## ① 定位与总则

- **主 agent**：**发起本次多 agent 会话的 agent**——即你与之对话、由其拆解 / 派发 / 汇总、并对你负责、最终落盘的那一个。**不绑定任何具体后端**：可以是 WorkBuddy、opencode、Claude Code（`claude`）、dsh、freellmapi 等任意会话式 agent。本仓库的示例实现基于 WorkBuddy 的 `Agent(resume)`，但**本规范与实现后端无关**——换一个会话式 agent 当主 agent，同样适用。
- **子 agent**：被主 agent 派出去干活的 agent（任意后端的实例，统一用 `backend+model` 记法标识），**只向主 agent 汇报，不直接对你**。
- **`backend+model` 记法（全局统一）**：任何 agent 用 `后端+模型` 标识，模型名归属各后端自己的命名空间。例：`opencode+bigpickle`、`freellmapi+glm-5.2`、`pi+<模型>`、`deepseek+<模型>`、`reasonix+<模型>`、`claude+<模型>`、`codex+<模型>`、`dsh+<模型>`、`builtin_subagent+general-purpose`。这是 L1.5 选型、L5 原文呈现的唯一口径。

## ② 触发

你说"多agent / 多 agent"（可带模式名，如"多 agent 辩论"）→ 主 agent 进入多 agent 模式，走下列环节。

## ③ 标准环节

- **L0 入口确认**：主 agent 复述任务 + 推荐模式，请你确认模式。
- **L1 选模式（逐模式人话说明）**：主 agent 用自然语言**逐条**向你说清每个模式（见 ④ 的「一句话含义」），给推荐，你拍板。**各模式的参与方数量与种类、所用 `backend+model` 均默认给出推荐值，但 100% 由你确认 / 改写**（见 ④ 与 L1.5）。
- **L1.5 扫描本机 + 读注册表 + 你选型（强制 · 混合发现）**：
  - **混合发现（C）**：主 agent 必须**实际扫描本机**（PATH + `AppData\Local` + `AppData\Roaming` + `Program Files` + 注册表，抓 `opencode|codex|claude|dsh|freellm|deepseek|reasonix|pi|openhands|copilot` 等），同时**读取双层注册表**（见下）。扫描结果与注册表**交叉校验**，发现未登记的新后端即提示你补登。
  - **双层注册表**（你维护，模型名你定）：
    - 用户级底座：`~/.workbuddy/multi_agent.agents`（跨项目）
    - 仓库级覆盖/追加：`<仓库>/multi_agent.agents`（项目专用）
    - 格式：每行一条 `backend+model`，如 `opencode+bigpickle`、`pi+<模型>`、`deepseek+<模型>`、`reasonix+<模型>`、`freellmapi+glm-5.2`、`claude+<模型>`、`codex+<模型>`、`dsh+<模型>`、`builtin_subagent+general-purpose`。
    - **模型名规则**：扫描尽力探测，扫到的列出；**扫不到的留 `<模型>` 占位等你补**（桌面应用 / 本地模型的模型名扫不准，必须由你定——呼应"选 agent 包括 llm 交给你"）。
  - **选型主权 100% 归你**：主 agent 呈现“扫描 ∪ 注册表”合并清单后，**由你为每个角色挑选 `backend+model`**；主 agent **绝不自作主张 assign llm**。**注册表中 `<模型>` 占位符（如你写的 `opencode+bigpickle`）不是真实模型串**——opencode 实际只有 `openai/flm-auto`/`openai/auto`，freellmapi 也无 bigpickle；占位符必须等你补真实 id 或勾选，主 agent **不得静默解析/替换**（见 ⑥-a）。选型途径：
    ① 你从清单手动勾选；② 智能择优（freellmapi 池按能力标签打分取 top N；若无内置排行则主 agent 按标签打分取 top N，但**最终仍须你确认**）；③ 你自指定任意 `backend+model`。
  - **记录**：选型时须一并记录每个子 agent 的 `backend+model`（如 `opencode+bigpickle`、`builtin_subagent+general-purpose`），供 L5 原文呈现。
- **L2 模式化拆解**：用 L1.5 选定 agent 落成「子 agent 任务卡」（派谁、**哪个 `backend+model`**、输入、输出、汇总；若是辩论/评审/红队类须注入 ④ 的诚实宪章）；**列出派发方案，必须请你确认后才执行**（确认执行门禁覆盖多 agent 派发）。**确认内容必须显式列出三项**：① 辩论/评审**轮次**（默认 R=3）② 参与 **agent 数量**（辩论默认 4）③ 每个角色的 **`backend+model`**（从 L1.5 清单勾选，**绝不自作主张 assign llm**）。
- **L2.5 开 worktree（含本地文件类问题强制）**：为每个需要落盘代码的子 agent `git worktree add` 新建独立分支（`multiagent/<任务>-<序号>`），子 agent 在该 worktree 内拥有全部权限。
  - **默认**：仅当该子 agent 需要落盘代码时执行；纯文本 / 不产生文件任务的模式可跳过，但须向你说明原因。
  - **⚠️ 强制（不可跳过）**：**凡问题涉及本地项目文件（读取 / 核实仓库代码、diff、测试、构建产物）**，无论辩论 / 评审 / 红队 / 考试，**一律强制开 worktree**；且辩论 / 评审类**禁止纯文本辩论**——每个对抗 agent 必须在 worktree 内**跑命令取证**（`grep` / `diff` / `flutter analyze` / `flutter test` 等真实输出），用代码与命令结果当论据，**不得仅靠主 agent 转述**。理由：此类问题结论必须对得准代码，纯文本辩论等于无证据空辩。
  - 新开 worktree 的分支名避免与主树冲突；销毁见 L6。
- **L2.6 常驻实例 + resume（强制 · 所有模式通用）**：每个（角色 / 立场 / 子任务）**只首次用 `Agent` 拉起一个实例并记下其 `agent_id`**；后续每一轮 / 每一阶段**必须对该 `agent_id` 用 `Agent` 的 `resume` 续跑**。**严禁**为同一角色每轮新建一个 agent 实例、靠把历史塞进 prompt 来"假装连续对话"。即：轮次之间的上下文连续由 agent 自身记忆（resume）保证，而非由主 agent 重新拼 prompt 注入来伪造。
- **L2.7 中转保真 + 全闭环传递（强制 · 所有模式通用）**：
  - **全闭环传递**：当子 agent 数 **N≥2**，每个 agent 的回复必须**原样传递给其余所有 agent**（a→{b,c}、b→{a,c}、c→{a,b}…）。主 agent 每轮结束组装 `context packet` = 本轮所有 agent 的原文回复，下一轮 `resume` 每个 agent 时把**完整 packet 注入**（N 个 agent 各拿 N-1 份 peer 原文）。**严禁只做顺序接力**（a→b→c）。
  - **严格原文**：主 agent 转发时**只许加路由标签**（如 `【反方 R2 原文】`），**绝不 paraphrase / 压缩 / 提炼**子 agent 内容；转发文本直接取自 L5 留存的原文。
  - **传递矩阵**：主 agent 在 L5 transcript 记录「谁收到了谁」，可审计。
- **L3 派发执行**：按 L2.6 常驻实例 + resume、L2.7 全闭环拉起 / 续跑子 agent，并发策略由 L7 决定；子 agent 只汇报主 agent。主 agent 在每轮**留存原文三要素**：发给该子 agent 的 prompt（被问）、该子 agent 的回复、及其 `backend+model`（L1.5/L2 记录值）。
- **L4 模式化裁决（下沉子 agent + 收敛地图 · 见 ④ 表）**：
  - **诚实宪章（所有对抗 / 评审类模式强制写入子 agent 角色提示）**：「基于现实 / 证据辩论，承认对方合理点，不为辩而辩、不编造对立立场」。
  - **判断权下沉**：取消「主 agent 当裁判判胜负」。改为——
    - **末轮子 agent 互评**：每个 agent 明确陈述「我 concede 了对方哪些点 / 仍坚持哪些点 / 哪些已达成一致」；
    - **可选独立裁判子 agent**：若需第三方裁定，由你在 L1.5/L2 从注册表选一个 `backend+model` 担任；**主 agent 必须向其注入本模式全量上下文包**（原始问题 / 背景、执行过程与轮次、全部辩论原文取自 L5、当前收敛地图），裁判只能基于该全量包下结论，**禁止只看末轮或摘要**（即"前世今生"全给，不得空穴来判）。
  - **主 agent 只做收敛统计**：维护「议题表」，每轮把每项标记 `分歧 / 部分统一 / 统一`，最终交付**收敛地图（convergence map）**而非主观胜负结论。
  - **一致度提前收口（辩论 / 评审通用）**：裁判（独立裁判子 agent 或主 agent 兼任）**每轮末**基于收敛地图给「一致度」评分（统一议题数 / 总议题数）；达到阈值（默认 **≥90% 议题统一**）即**提前收口**，不必跑满默认轮次。该评分须写入 L5 transcript 供审计；若用户指定「必须跑满 R 轮」则忽略此条。
- **L5 汇总交付（含原文呈现 · 强制）**：主 agent 整合为最终交付，对你负责。**必须在总结中原文呈现**：每个子 agent、**每一轮次**的 ① 被问（主 agent 发出的 prompt 原文）② 回复（子 agent 返回原文）③ 该子 agent 的 `backend+model`（L1.5/L2 记录值）。**不得改写、摘要或只给结论——逐轮逐 agent 贴原文**，以便你直接核验每句话的来源；并附 L2.7 的传递矩阵与 L4 的收敛地图。
- **L6 销毁 worktree 与终端**：总任务完毕，销毁各自 worktree（`git worktree remove`）+ 关闭各自启用的终端（仅当 L2.5 开了 worktree / 终端时执行；纯文本模式无 worktree 则跳过）。**强制项**：涉及本地项目文件的辩论 / 评审 / 红队，**所有轮次结束后立即销毁新开的 worktree**（不得保留到下次会话）；销毁前确认无未提交且需保留的改动（此类模式 worktree 改动按 ⑤ 默认直接丢弃，无需合并）。
- **L7 资源（三选一 + 自适应）**：你选 **并发 / 串行 / 自适应（推荐）**；自适应按本机负载动态调度三态（探测 CPU%、可用内存%、freellmapi 负载；`CPU<50% 且 内存>30%`→并发，`50–80%`→限流≤2–3，`>80%`或内存紧张→串行；执行中动态降级 graceful）。
- **L8 失败兜底（所有模式通用）**：
  - **触发条件**：超时 / 报错 / 输出空或无效 / 模型不可用 / 限流 / 进程崩。
  - **兜底链（逐级）**：① 同 `backend+model` **重试 1 次**（应对瞬时错误）→ ② 切到该 agent 绑定的**备用 `backend+model`**（见下）→ ③ 仍失败 → 该子任务标 `FAILED`，主 agent **继续其它分支不阻塞整体**，末尾汇总报告。
  - **备用定义（C）**：每个 agent 可在注册表标 `fallback=backend+model`（**agent 级优先**）；未标则走**全局备用列表**（按顺序尝试，注册表以 `global_fallback=` 指定）。
  - **裁判同理**：独立裁判子 agent 挂了也走同一条链。
  - **审计**：所有兜底动作记入 L5 transcript（谁失败、切到哪、结果）。

## ④ 七种模式

> **数量 / 种类由你定**：下表「执行参数」中的数字与角色均为**推荐默认**，你可在 L1/L2 任意改写（增删参与方、换 `backend+model`、改轮次）。各模式附**可改名 / 增减的角色模板**作为骨架，不强制。

| 模式 | 一句话含义 | 执行参数(推荐默认，你可改) | 终止条件 | 近似模式与区别 |
|---|---|---|---|---|
| **协同** Collaboration | 大活拆互补块并行做，我拼起来 | 各块并行；拼接校验对齐；参与方数=块数 | 全块交付且对齐无冲突 | vs 流水线：并行↔串行两极 |
| **考试** Exam | 同活复制 N 份各做，挑最好的 | 份数 **N=3**；评分=正确性/完整度/简洁；择优=最高分或融合 top2 | 凑齐 N 份或超时 | vs 委员会：产出连续解↔离散决策；vs 评审：从零做↔改已有 |
| **辩论** Debate | 多方站对立面互怼，收敛为共识 | **轮次 R=3（默认，可改）**；**阵容默认 = 正方×2 + 反方×2（共 4 个 opencode 辩论实例，本地文件类问题须在 worktree 内自行跑 `grep`/`diff`/`flutter analyze`/`flutter test` 取证、不得纯文本空辩）+ 验证官 1（builtin_subagent，负责命令取证产出证据包）+ 裁判由主 agent 兼任（不做独立 session；如需独立第三方裁定则另开第 5 个 session）**；4 个辩论实例可改名/增减；**派发前必须向你确认轮次与 agent 数量** | 一方重复/认输、轮次用尽、**或裁判（主 agent 兼任）每轮末评估「一致度」达阈值（默认 ≥90% 议题标记为「统一」）**→提前收口（不必跑满 R） | vs 红队：观点交锋↔实现攻击；有交互↔单向 |
| **评审** Review | 先出东西再派人挑刺，我改 | **轮次 K=2**（初评+覆评）；只提问题 | 无新问题/达成共识/轮次上限→修订定稿 | vs 红队：红队=评审的对抗强化版（更狠偏安全） |
| **红队** Red-Team | 派"对手"专找漏洞打穿，我补 | **攻击轮次=2**；假设敌找 exploit | 无可 exploit 或轮次上限→补强清单 | 近似评审（见上） |
| **委员会** Committee | 多人独立投票，少数服从多数 | 参与方 **3~5**；多数决；平票主 agent **程序性加投（非内容裁定）** | 投票完成 | 近似考试（离散决策版） |
| **流水线** Pipeline | 切几步接力，A 喂 B 喂 C | 串行阶段；每阶段满足准入才进下阶段 | 末阶段验收通过；不达标回退重做 | vs 协同：串行↔并行 |

### 一句话选法

- 还**没定方向要吵清** → **辩论**
- 方向已定**要经得起打** → **红队**
- **从零要最好解** → **考试**
- 已有产出**想改好** → **评审**
- **判断题/选择题拍板** → **委员会**
- 能拆**互补块** → **协同**
- 有**前后依赖** → **流水线**

> **所有模式通用铁律（落地在 ③ 的 L2.6 / L2.7 / L4 / L5）**：
> ① 每个角色 / 立场 / 子任务只首次拉起一个 agent 实例、后续必须 `resume` 续跑，**严禁每轮新建实例靠 prompt 注入假装连续**；
> ② 主 agent 最终总结须**原文逐轮逐 agent 呈现**「被问 / 回复 / `backend+model`」，不得改写或只给结论；
> ③ **中转严格原文 + 全闭环传递**（N≥2 时每个 agent 的回复原样广播给其余所有 agent，主 agent 只加路由标签不改内容）；
> ④ **裁决下沉子 agent + 主 agent 只出收敛地图**（对抗/评审类强制诚实宪章，末轮互评，可选独立裁判须持全量上下文，主 agent 不判主观胜负）。

## ⑤ 门禁边界（铁律）

- L2 派发前**必须你确认**（确认执行门禁覆盖多 agent 派发）；**选型主权 100% 归你，主 agent 不得自作主张 assign llm 或替你定参与方数量**。
- 子 agent 在 worktree 内拥有全部权限，但**「禁止改 AGENTS.md」门禁对子 agent 同样生效，不容商量**。
- 成果去向按模式分：协同/流水线→先合并回主树再销毁；考试/辩论/评审/红队/委员会→只取结论文本、worktree 改动直接丢弃。

## ⑥ 本机可用 Agent 清单（须 L1.5 实时扫描，以下为 2026-10-11 扫描快照）

> **本清单只是快照，L1.5 必须重新实时扫描**，不得直接照搬。下方给出检测命令及各后端确认到的落点（均在当前 Windows 本机实测存在）。**注意：桌面应用不在 PATH，须扫 `AppData` 才找得到。**

### 外部 agent CLI / 桌面应用（用户可在 L1.5 指定其 llm 模型）
- **opencode**：已安装（npm 全局 `...\AppData\Roaming\npm\opencode`，另有 `opencode2`）。调用时须指定 provider / model，如 `opencode+bigpickle`。
- **codex**：已安装（npm 全局 `...\AppData\Roaming\npm\codex`，含 `codex-acp` ACP 入口）。调用时须指定模型。
- **Claude Code（`claude`）**：已安装（npm 全局 `...\AppData\Roaming\npm\claude`，含 `claude-agent-acp`）；配置见 `C:\Users\Administrator\.claude\`。
- **dsh（DeepSeek harness）**：已安装（`C:\Users\Administrator\.workbuddy\binaries\node\versions\22.22.2-6\dsh.cmd`，v0.2.0-rc.2）。`dsh web` / `dsh headless` / `dsh tui`。
- **freellmapi**：已安装运行（v0.13.6，`C:\Users\Administrator\AppData\Local\Programs\freellmapi-desktop\FreeLLMAPI.exe`），多模型后端（OpenAI 兼容 + 自动 failover），可作并行对抗 / 智能择优池。
- **Pi Agent Desktop（`pi`）**：已安装（桌面应用，`C:\Users\Administrator\AppData\Local\Pi Agent Desktop`）。不在 PATH，扫描须覆盖 `AppData\Local`。
- **DeepSeek 桌面端（`deepseek`）**：已安装（`C:\Users\Administrator\AppData\...@deepseek-ai` / `@deepseek-aidsh-desktop-updater`）。
- **Reasonix（`reasonix`）**：已安装（桌面应用，`C:\Users\Administrator\AppData\...\reasonix`）。
- **OpenHands Agent Canvas（`openhands`）**：已安装（桌面应用，`C:\Users\Administrator\AppData\Local\OpenHands Agent Canvas`）——可参考其"自主 coding + 隔离工作区 + 错误处理"实现 L2.5 / L8。
- **github-copilot**：已安装（`C:\Users\Administrator\AppData\...\github-copilot`）。

### 内置能力（当前 WorkBuddy 会话直调）
- **内置 subagents**：`general-purpose` / `Explore` / `Plan` / `sheet-agent` / `doc-*` 等。记法 `builtin_subagent+<名>`，如 `builtin_subagent+general-purpose`；派发时可指定 `model`（default / lite / reasoning）作为 `+` 后的模型名。
- **用户级 skills**：`grill-me` / `mysql__skillhub` / `obsidian` / `rust-windows-mingw-gnu`
- **项目级 skills** (chan_month5)：`auto-commit-obsidian` / `obsidian-task-recorder`
- **Claude Code 全局 skills**（可作 agent 池，30+）：含 `cross-review` / `zen-review`（评审）、`research`（调研）、`plan`、`agent-browser`

### ⑥-a agent 启动经验 / 坑点（2026-10-12 复盘补充）

- **opencode 在本机 TUI 必崩**：Bun segfault（CPU 无 AVX 路径，`start-opencode-freellmapi.bat` 也写了 "Default TUI crashes on this CPU"）。**一律非交互模式**：`opencode run --standalone --model openai/<freellmapi真实id> --title <名>`，续跑加 `--session <id>`；或 `opencode web --hostname 127.0.0.1 --port 4096`。不要直跑 TUI。
- **`opencode+bigpickle` 是悬空占位符**：你注册表里写的 `opencode+bigpickle` 没有对应真实模型。opencode 配置（`~/.config/opencode/opencode.jsonc`）只有 `openai/flm-auto` 与 `openai/auto`；freellmapi（31416）也无 `bigpickle`。`flm-auto` 的 name 是 "alias of FreeLLMAPI auto router"——即走你本地免费网关的自动路由，**不是某个叫 bigpickle 的模型**。
  - **若你要「免费模型」**，freellmapi 明确暴露的免费槽位：`free-router`（Free Router）、`claude-haiku-4-5` / `claude-sonnet-4-5` / `claude-opus-4-5`（均标 "auto-routed to a free model"）。opencode 调用应写为 `openai/free-router` 或 `openai/claude-haiku-4-5`。
  - **铁律**：注册表 `<模型>` 占位符（bigpickle 等）必须等你补真实 id 或勾选，**主 agent 不得静默解析/替换**（违反 L1.5 选型主权）。
- **freellmapi 必须先在跑**：opencode 模型 baseURL 是 `127.0.0.1:31416/v1`，freellmapi 桌面端没启动则 opencode 直接连不上。派发前先确认 31416 在监听。
- **opencode `run` 实测可用参数**：`--standalone`（避开后台服务依赖）、`--model openai/flm-auto`、`--session <id>`（resume）、`--title <名>`（首次命名会话，便于取 id）。最小验证：`opencode run --standalone --model openai/flm-auto "Reply OK"`。
- **⚠️ freellmapi chat 端点只接受路由模型（2026-10-12 实测）**：`/v1/models` 列出的 `claude-sonnet-4-5` / `claude-haiku-4-5` / `free-router` 等只是**目录条目**；经 opencode→freellmapi 的 **chat 调用直接报 `Model 'claude-sonnet-4-5' is not in the catalog`**。实际可用的免费模型**只有 `flm-auto` / `auto`**（FreeLLMAPI 自动路由到免费强模型）。用户选 `claude-sonnet-4-5` 会 Model unavailable——此时 fallback 到 `openai/flm-auto` 即可（它走的就是免费网关，不必改模型）。
- **⚠️ opencode 子 agent 读文件被拦 / 取证的权限处理（2026-10-12 实测 + 修正）**：opencode 默认对 `external_directory` 的 Read/Bash 会 **auto-reject**（报 "The user declined this tool call"）。**正确做法（满足 L2.5 强制取证）**：把 opencode 的工作目录 `cwd` 直接设在 worktree 里（使其算「项目内」而非「外部目录」），或在 `opencode.jsonc` 把 worktree 路径加入 `permissions.allow`（如 `Read`、`Bash`），使辩论 agent 能在 worktree 内自行跑 `grep`/`diff`/`flutter analyze`/`flutter test` 取证——这才能让 4 个辩论实例各自独立验证，而非只消费验证官的证据包（符合「外部 agent 也该有 worktree 权限」的要求，**权限可授予、并非不可能**）。**仅当权限确实无法授予时**，才退而用「提示词去掉路径 + 声明只读证据包」的兜底（取证全压在 builtin 验证官身上，属降级方案，辩论质量弱于各 agent 自证）。
- **每 `run` 不带 `--session` 会新建会话（2026-10-12 实测）**：即使同 `--title` 也会开新会话（本次因此产生多个同名 DEBATE-* 会话）；resume 必须 `--session <id>`，用 `opencode session list` 取**最新**的 R1 会话 id 续跑（旧失败会话别误用）。

### L1.5 扫描命令参考
`command -v opencode codex claude dsh`；遍历 `AppData\Local`、`AppData\Roaming`、`Program Files` 抓 `opencode|codex|claude|freellm|deepseek|reasonix|pi|openhands|copilot`；列 freellmapi 安装目录与各级 skills 目录（`~\.workbuddy\skills`、`~\.claude\skills`、`<项目>\.workbuddy\skills`）。**桌面应用靠 `AppData` 目录名命中，不依赖 PATH。**

## ⑦ 默认假设（写入后可改）

- 辩论 **R=3 / 阵容 = 正方×2+反方×2（4 个 opencode 辩论实例）+ 验证官 1（builtin）+ 裁判主 agent 兼任** / 评审 **K=2** / 考试 **N=3** / 委员会 **3~5 方** / 红队 **攻击=2** —— 均为**推荐默认**，你可在 L1/L2 改写；**派发前必须向你确认轮次与 agent 数量**。**辩论收敛默认启用「一致度提前收口」：裁判（主 agent 兼任）每轮末评估一致度，达到阈值（默认 ≥90% 议题统一）即提前收口，不必跑满 R=3**。
- 自适应阈值：CPU 50% / 80% 分界，内存可用 30% 分界。
- 失败兜底：同后端重试 **1 次**；agent 级 `fallback=backend+model` 优先，否则走 `global_fallback=` 全局列表。
- freellmapi 智能排行若无内置则主 agent 按模型/技能标签打分取 top N，但仍须你最终确认。
- 双层注册表：用户级 `~/.workbuddy/multi_agent.agents` 底座 + 仓库级 `multi_agent.agents` 覆盖/追加；模型名扫不到留 `<模型>` 占位由你补。
