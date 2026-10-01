---
name: obsidian
description: Sync task results into the Obsidian vault for chan_month5. Append a faithful entry to task-log.md (the single source of truth), then mirror it into the dated note and refresh the MOC timeline. Triggers on "记录到 obsidian", "同步 obsidian", or finishing a task worth archiving.
license: MIT
metadata:
  derived_from: ".cursor/skills/obsidian-task-recorder (repo-local)"
  version: 1.0.0
---

# Obsidian Task Recorder (chan_month5)

Mirror every completed task into the Obsidian vault as a dated, searchable note.
## Core invariants (do not violate)

- **Source of truth is `task-log.md`** at the repo root. Obsidian is a *copy*.
- **Never hand-edit task text inside Obsidian.** Fix `task-log.md` first, then re-sync.
- UTF-8, LF line endings, `[[wikilinks]]`.
- Do **not** migrate `AGENTS.md`, `ROBOT_VERIFY.md`, `CLAUDE.md`, or `OPENCODE.md` through this skill.

## When to use

After finishing any task in `chan_month5` that produced a result worth keeping: a bug fix, a feature, a refactor, a verification/test pass, or a docs task.

## Steps

1. Append an entry to `task-log.md` (heading `## YYYY-MM-DD · 执行者 · 类型 · 标题`).
2. Append the **same** entry to `Obsidian Vault/chan-month5/YYYY-MM-DD.md`; if absent, create from the date-note template (frontmatter + `prev` link).
3. Chain `next`/`prev` if the adjacent day note exists.
4. Update the MOC timeline row for that day (date / entry count / link).
5. Update `index-memory.md` / `index-plans.md` / `index-demos.md` if memory, plans, or demos changed.
