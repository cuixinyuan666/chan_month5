# test 任务演示目录

每个**修改类任务**在无法仅用默认股票 `002003` 验收时，在此新增子目录。

## 文案要求（重要）

- `before.md` / `after.md` / `manifest` 里所有说明：**白话 + 缠论术语**（K0、步进、副图、一类买点…）
- **不要**大段写代码、函数名、文件路径（路径只写在 `task-log.md` 给智能体看）

## 快速开始

1. 复制 `_template/` → `{task_id}/`
2. 填 `manifest.json`、`before.md`（改代码**前**写）
3. 完成后写 `task-log.md`
4. 冷启动（开发演示阶段开着）会自动加载最新一条

详见 `AGENT_LONG_TERM_MEMORY.md`。
