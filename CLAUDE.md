# Claude Code · 本仓库接任务前必读

接任何编码/修改任务前，**必须先完整阅读**：

1. [`AGENT_LONG_TERM_MEMORY.md`](AGENT_LONG_TERM_MEMORY.md)（主规范·最高优先级）
2. [`AGENTS.md`](AGENTS.md)（角色与 CHAN_RUST 常驻口径）

关键约束摘要：

- 用户消息**未包含「确认执行」**→ **禁止**改 app 关键逻辑；须先用文字提出修改请求，等用户确认后再动代码。
- 任务完成后写 [`task-log.md`](task-log.md)；演示文案用**白话**，少写代码名。
- 开发演示阶段默认开：见 `AGENT_LONG_TERM_MEMORY.md` §2.1。
