# 多 Agent 协同规则（调用细节）

> 本文件是 AGENTS.md「多 Agent 协同规则」入口的**完整落地文档**。AGENTS.md 只保留入口指针，细节以此文件为准。
> 规则由 grill-me 采访构想，2026-10-11 定稿。

## ① 定位与总则

- **主 agent**：你当前会话直接对话的 agent——接收指令、拆解、派发、汇总、对你负责、最终落盘。
- **子 agent**：被主 agent 派出去干活的 agent（WorkBuddy subagents / 可调 skills / 经 freellmapi 拉起的模型实例），**只向主 agent 汇报，不直接对你**。

## ② 触发

你说"多agent / 多 agent"（可带模式名，如"多 agent 辩论"）→ 主 agent 进入多 agent 模式，走下列环节。

## ③ 标准环节

- **L0 入口确认**：主 agent 复述任务 + 推荐模式，请你确认模式。
- **L1 选模式（逐模式人话说明）**：主 agent 用自然语言**逐条**向你说清每个模式（见 ④ 的「一句话含义」），给推荐，你拍板。
- **L1.5 获取并推荐 agent**：主 agent **实时获取**本机可用 agent 清单（skills + subagents + freellmapi 模型池 + dsh/opencode 等）；基于任务给「推荐 agent 组合」；**你选型（三途径）**：
  ① 手动勾选；
  ② 智能择优（freellmapi 模型/技能池按能力标签打分取 top N，如前十——*若 freellmapi 无内置排行则由主 agent 打分取 top N*）；
  ③ 自指定（你指定 opencode 等工具并指定 llm）。
- **L2 模式化拆解**：用 L1.5 选定 agent 落成「子 agent 任务卡」（派谁、输入、输出、汇总）；**列出派发方案，必须请你确认后才执行**（确认执行门禁覆盖多 agent 派发）。
- **L2.5 开 worktree**：为每个子 agent `git worktree add` 新建独立分支（`multiagent/<任务>-<序号>`），子 agent 在该 worktree 内拥有全部权限。
- **L3 派发执行**：拉起子 agent，并发策略由 L7 决定；子 agent 只汇报主 agent。
- **L4 模式化裁决（精细化，见 ④ 表）**。
- **L5 汇总交付**：主 agent 整合为最终交付，对你负责。
- **L6 销毁 worktree 与终端**：总任务完毕，销毁各自 worktree（`git worktree remove`）+ 关闭各自启用的终端。
- **L7 资源（三选一 + 自适应）**：你选 **并发 / 串行 / 自适应（推荐）**；自适应按本机负载动态调度三态（探测 CPU%、可用内存%、freellmapi 负载；`CPU<50% 且 内存>30%`→并发，`50–80%`→multiple 限流≤2–3，`>80%`或内存紧张→串行；执行中动态降级 graceful）。

## ④ 七种模式

| 模式 | 一句话含义 | 执行参数(默认) | 终止条件 | 近似模式与区别 |
|---|---|---|---|---|
| **协同** Collaboration | 大活拆互补块并行做，我拼起来 | 各块并行；拼接校验对齐 | 全块交付且对齐无冲突 | vs 流水线：并行↔串行两极 |
| **考试** Exam | 同活复制 N 份各做，挑最好的 | 份数 **N=3**；评分=正确性/完整度/简洁；择优=最高分或融合 top2 | 凑齐 N 份或超时 | vs 委员会：产出连续解↔离散决策；vs 评审：从零做↔改已有 |
| **辩论** Debate | 多方站对立面互怼，我当裁判 | **轮次 R=3** 互驳 | 一方重复/认输、轮次用尽、或主 agent 判充分→裁判结论 | vs 红队：观点交锋↔实现攻击；有交互↔单向 |
| **评审** Review | 先出东西再派人挑刺，我改 | **轮次 K=2**（初评+覆评）；只提问题 | 无新问题/达成共识/轮次上限→修订定稿 | vs 红队：红队=评审的对抗强化版（更狠偏安全） |
| **红队** Red-Team | 派"对手"专找漏洞打穿，我补 | **攻击轮次=2**；假设敌找 exploit | 无可 exploit 或轮次上限→补强清单 | 近似评审（见上） |
| **委员会** Committee | 多人独立投票，少数服从多数 | 多数决；平票主 agent 裁决/加投 | 投票完成 | 近似考试（离散决策版） |
| **流水线** Pipeline | 切几步接力，A 喂 B 喂 C | 串行阶段；每阶段满足准入才进下阶段 | 末阶段验收通过；不达标回退重做 | vs 协同：串行↔并行 |

### 一句话选法

- 还**没定方向要吵清** → **辩论**
- 方向已定**要经得起打** → **红队**
- **从零要最好解** → **考试**
- 已有产出**想改好** → **评审**
- **判断题/选择题拍板** → **委员会**
- 能拆**互补块** → **协同**
- 有**前后依赖** → **流水线**

## ⑤ 门禁边界（铁律）

- L2 派发前**必须你确认**（确认执行门禁覆盖多 agent 派发）。
- 子 agent 在 worktree 内拥有全部权限，但**「禁止改 AGENTS.md」门禁对子 agent 同样生效，不容商量**。
- 成果去向按模式分：协同/流水线→先合并回主树再销毁；考试/辩论/评审/红队/委员会→只取结论文本、worktree 改动直接丢弃。

## ⑥ 本机可用 Agent 清单（落点参考）

- **用户级 skills**：`grill-me` / `mysql__skillhub` / `obsidian` / `rust-windows-mingw-gnu`
- **项目级 skills** (chan_month5)：`auto-commit-obsidian` / `obsidian-task-recorder`
- **Claude Code 全局 skills**（可作 agent 池，30+）：含 `cross-review` / `zen-review`（评审）、`research`（调研）、`plan`、`agent-browser`
- **freellmapi**：已安装运行（v0.13.6），多模型后端（OpenAI 兼容 + 自动 failover）
- **内置 subagents**（当前会话直调）：`general-purpose` / `Explore` / `Plan` / `sheet-agent` 等
- **dsh**：DeepSeek harness（`dsh.cmd` 路径存在）

## ⑦ 默认假设（写入后可改）

- freellmapi 智能排行若无内置则主 agent 按模型/技能标签打分取 top N；
- 自适应阈值：CPU 50% / 80% 分界，内存可用 30% 分界；
- 辩论 3 轮 / 评审 2 轮 / 考试 3 份。
