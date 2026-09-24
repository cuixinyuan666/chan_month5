---
name: auto-commit-obsidian
description: >-
  Ship every sub-task automatically. After completing each unit of work, append
  its entry to task-log.md, then commit (work + task-log + memory), push to the
  branch upstream, and mirror into Obsidian — without manual steps. Triggers on
  "自动提交", "自动commit", "每子任务提交", "commit+push+obsidian", or when the user
  posts a batch of tasks that should be split and shipped incrementally.
agent_created: true
---

# Auto Commit + Push + Obsidian (chan_month5)

Turn "do the work, then remember to commit/push/record" into one deterministic
step per sub-task. When the user posts several tasks at once, split them into
sub-tasks and ship each independently so every commit is a clean, revertible unit
with its Obsidian record attached.

## When to use

- The user asks to auto-commit / auto-push / auto-record, or posts a batch of
  tasks that should be shipped incrementally.
- After finishing any sub-task in `chan_month5` that produced a result worth keeping.
- This skill wraps `obsidian-task-recorder` (append task-log + sync to vault) and
  adds the git commit + push around it. The recorder remains the source of truth
  for the entry format.

## Procedure

### 0. Split the big task into sub-tasks

- If the user's message contains multiple independent items, enumerate them with
  TaskCreate — **one sub-task per deliverable unit** (one coherent change that can
  be described by a single task-log entry + a single commit).
- Keep the list visible so progress is trackable. Do NOT lump several unrelated
  changes into one commit.

### 1. Execute one sub-task

- Perform the change (edit / create / delete files).
- **Respect the AGENTS.md confirm-gate.** If the sub-task touches core chan-theory
  logic (合并/分型/段/中枢/买卖点/步进/冻结/`chan_bridge`), obtain an explicit
  "确认" before editing. This skill only automates *post-completion* mechanics — it
  never lowers the gate.
- Verify minimally (e.g. `dart format --output=none` when `flutter analyze` is
  unavailable in the sandbox).

### 2. Append the task-log entry

- Append a dated block to `task-log.md` using the `obsidian-task-recorder` format:

  ```markdown
  ### YYYY-MM-DD HH:MM — <任务标题>

  - **执行者**：<标识>
  - **任务类型**：<功能开发 / Bug修复 / 重构 / 配置 / 数据处理 / 验证 / 复盘>
  - **上下文**：<背景>
  - **关键操作**：
    1. <要点>
  - **结果**：<产出 / 变更范围>
  - **注意事项**：<后续 / 待确认>
  ```
- Keep the title concise in Chinese — it becomes the commit subject.
- Map 任务类型 → conventional commit prefix for the subject:
  功能开发=`feat`, Bug修复=`fix`, 重构=`refactor`, 配置=`chore`,
  数据处理=`data`, 验证=`test`, 复盘/文档=`docs`.
  Subject form: `<type>: <任务标题>` (e.g. `feat: 删除开发演示阶段与任务演示子系统`).

### 3. Commit + push + sync (one call)

Run the bundled helper. Pass **every file this sub-task changed**:

```bash
python <skill_dir>/scripts/commit_push_record.py \
  --message "<type>: <任务标题>" \
  <changed_file_1> <changed_file_2> ...
```

The helper (deterministic, safe):
1. Resolves repo root = the dir containing both `.git` and `task-log.md`
   (== workspace `chan_month5`).
2. Stages ONLY the passed files PLUS `task-log.md` and today's
   `.workbuddy/memory/YYYY-MM-DD.md` (if present). **Never `git add -A`.**
3. Skips the commit if nothing is staged (no empty commits).
4. Commits with the given message.
5. Pushes to the current branch's upstream (`git push`). On rejection it does
   **ONE** `git pull --rebase --autostash` then retries; if still failing it stops
   and reports. **Never `git push --force`.**
6. Runs the obsidian recorder's sync script to mirror into the vault.

Flags:
- `--no-push` — commit + sync only (keep local).
- `--no-sync` — commit + push only (skip vault mirror).
- `--dry-run` — print the plan (repo root, files to stage, message, upstream) and
  exit without touching git / vault. Use to preview.
- `--repo <path>` — override the auto-detected repo root.

### 4. Loop

- Mark the sub-task completed, then repeat steps 1–3 for the next one. Each
  sub-task lands as its own commit + push + Obsidian entry.

### 5. Close out

- Summarize: N sub-tasks, N commits, last push status, obsidian sync result.

## Invariants / safety

- **Source of truth is `task-log.md`.** Obsidian is a copy; the helper runs the
  recorder's sync script, never hand-edits the vault.
- **No `git add -A`.** Only the files explicitly passed + task-log + today's
  memory are staged. Unrelated working-tree changes are left untouched.
- **No `git push --force`.** At most one rebase-then-retry; then stop and report.
- **Does not bypass AGENTS.md 「确认执行」.** It automates only the commit/push/
  record step after a change is authorized and done.
- A sub-task with no file change (pure research / Q&A) → skip the commit; you may
  still append a task-log entry and run `--no-push --no-sync` (sync only) if the
  user wants it archived.

## Paths (defaults; overridable)

- repo root: auto-detected (dir with `.git` + `task-log.md`).
- obsidian sync: `<repo>/.workbuddy/skills/obsidian-task-recorder/scripts/sync_task_to_obsidian.py`
- vault: `<USERPROFILE>/Documents/Obsidian Vault/chan-month5`
