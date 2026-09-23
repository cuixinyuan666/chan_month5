---
name: obsidian-task-recorder
description: >-
  Record task results to Obsidian for the chan_month5 project. Use after completing
  any task in this repository: append a structured entry to task-log.md (the single
  source of truth), then run the bundled sync script to mirror it into the Obsidian
  daily note and refresh the MOC timeline. Triggers on "记录到 obsidian", "同步 obsidian",
  "task-log 同步", or finishing a task that should be archived.
agent_created: true
---

# Obsidian Task Recorder (chan_month5)

Mirror every completed task into the Obsidian vault as a dated, searchable note.
This skill codifies the "完成后" convention from `AGENTS.md` so the step is
reproducible and never depends on remembering the exact file format.

## Core invariants (do not violate)

- **Source of truth is `task-log.md`** at the repo root. Obsidian is a *copy*.
- **Never hand-edit task text inside Obsidian.** To fix a record, edit `task-log.md`
  first, then re-run the sync script.
- UTF-8, LF line endings, `[[wikilinks]]` (never `[text](file.md)`).
- Do **not** migrate `AGENTS.md`, `CLAUDE.md`, `OPENCODE.md`, or `a_Data/test/demos/*`
  through this skill — those stay in the repo.

## When to use

After finishing any task in `chan_month5` that produced a result worth keeping:
a bug fix, a feature, a refactor, a verification/test pass, or a docs task.
(The `grill-me` design loop and "确认执行" gating from `AGENTS.md` still apply
before touching core chan-theory logic — this skill only handles the *recording*.)

## Procedure

### 1. Draft and append the entry to `task-log.md`

Append a new block at the end of `task-log.md`. Use this header and structure:

```markdown
---

### YYYY-MM-DD · WorkBuddy · <任务类型> · <标题>

- **执行者**：WorkBuddy
- **任务类型**：<主图指标 / Bug修复 / 验证 / 文档整理 / …>
- **操作**：
  1. …（白话 + 缠论术语，禁止大段贴代码）
- **结果**：…（一句话结论）
- **演示**：…（如何在 GUI 验收，连续单步而非一键跳末）
- **测试**：…（测试文件 + 结果；若未跑通务必写明）
- **注意事项 / 待办**：…（技术债、未覆盖点）
```

Use 白话 + 缠论术语 (K0, 一类买点, 中枢, 步进, 副图). Do not paste large code blocks.
The entry header MUST start with a date `YYYY-MM-DD` — the sync script keys on it.

### 2. Run the sync script

```bash
python <skill_dir>/scripts/sync_task_to_obsidian.py
```

The script (deterministic, idempotent) will:

1. Parse `task-log.md` into entries (split on `### ` headers).
2. For each entry not yet present in its dated Obsidian note, append it
   (inserted before the note's footer nav line).
3. Create the dated note with the correct frontmatter template
   (`tags` / `created` / `date` / `moc` / `prev`) and footer nav if missing.
4. Refresh `MOC.md` timeline rows (entry counts per day) and the totals
   (`时间线索引（N 篇）`, `task-log.md：M 条 / D 天`).

Safe to re-run: entries are deduplicated by their header line, so a second
run is a no-op unless `task-log.md` gained new entries.

Useful flags:

```bash
python <skill_dir>/scripts/sync_task_to_obsidian.py --dry-run   # preview, no writes
python <skill_dir>/scripts/sync_task_to_obsidian.py --date 2026-09-22
python <skill_dir>/scripts/sync_task_to_obsidian.py --vault "/path/chan-month5" --task-log "/path/task-log.md"
```

### 3. Update topic indexes when relevant

If the task touches one of these areas, also sync the matching index note
(Obsidian `chan-month5/`):

- Memory / decisions → `index-memory.md`
- Plans / designs → `index-plans.md`
- Demos / acceptance copy → `index-demos.md`
- Explanatory docs (already migrated) → `index-docs.md`

Only do this when the task actually produced or changed such material; do not
touch indexes for routine fixes.

## Paths (defaults; overridable via flags)

- task-log:  `<repo_root>/task-log.md`
- memory:    `<repo_root>/.workbuddy/memory`  (mirrored into `<vault>/memory`)
- vault:     `<USERPROFILE>/Documents/Obsidian Vault/chan-month5`
