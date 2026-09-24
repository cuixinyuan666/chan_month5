#!/usr/bin/env python3
"""Commit + push + Obsidian-sync one sub-task, self-contained and safe.

Stages ONLY the files passed on the command line plus task-log.md and today's
.workbuddy/memory/YYYY-MM-DD.md. Never `git add -A`, never `git push --force`.
On push rejection it does ONE `git pull --rebase --autostash` then retries.

Usage:
  python commit_push_record.py --message "feat: 标题" file1 file2 ...
  python commit_push_record.py --message "..." --no-push file1
  python commit_push_record.py --message "..." --no-sync file1
  python commit_push_record.py --message "..." --dry-run file1
  python commit_push_record.py --message "..." --repo /path/to/repo file1
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from datetime import date
from pathlib import Path


def detect_repo_root(override: str | None) -> Path:
    if override:
        return Path(override).resolve()
    here = Path(__file__).resolve()
    for p in [here, *here.parents]:
        if (p / ".git").exists() and (p / "task-log.md").exists():
            return p
    raise RuntimeError(
        "could not auto-detect repo root (need a dir containing both .git and task-log.md)"
    )


def run(cmd, cwd: Path, check: bool = True):
    r = subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True)
    if check and r.returncode != 0:
        msg = (r.stderr or r.stdout).strip()
        raise RuntimeError(f"command failed: {' '.join(cmd)}\n{msg}")
    return r


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--message", "-m", required=True)
    ap.add_argument("--repo", default=None)
    ap.add_argument("--no-push", action="store_true")
    ap.add_argument("--no-sync", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("files", nargs="*")
    args = ap.parse_args()

    repo = detect_repo_root(args.repo)
    if not (repo / ".git").exists():
        print(f"[ERR] repo root not found at {repo}", file=sys.stderr)
        return 2

    # Files to stage: explicit args + task-log.md + today's memory note.
    to_add = list(args.files)
    to_add.append("task-log.md")
    mem = repo / ".workbuddy" / "memory" / f"{date.today().isoformat()}.md"
    if mem.exists():
        to_add.append(str(mem.relative_to(repo)))

    # De-dup and reduce to repo-relative paths (drop anything outside repo).
    seen: set[str] = set()
    rels: list[str] = []
    for f in to_add:
        p = Path(f)
        if not p.is_absolute():
            p = repo / f
        try:
            rel = str(p.relative_to(repo))
        except ValueError:
            continue
        if rel in seen:
            continue
        seen.add(rel)
        rels.append(rel)

    upstream = run(
        ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
        cwd=repo,
        check=False,
    )
    upstream_str = upstream.stdout.strip() if upstream.returncode == 0 else "(none)"

    if args.dry_run:
        print("[DRY-RUN] plan:")
        print(f"  repo root : {repo}")
        print(f"  upstream  : {upstream_str}")
        print(f"  message   : {args.message}")
        print(f"  stage     : {rels}")
        print(f"  push      : {'no' if args.no_push else 'yes'}")
        print(f"  sync      : {'no' if args.no_sync else 'yes'}")
        return 0

    # Stage explicitly (safe — never `git add -A`).
    run(["git", "add", "--", *rels], cwd=repo)

    staged = run(["git", "diff", "--cached", "--quiet"], cwd=repo, check=False)
    if staged.returncode == 0:
        print("[SKIP] nothing staged to commit.")
        return 0

    commit = run(["git", "commit", "-m", args.message], cwd=repo)
    head = run(["git", "rev-parse", "--short", "HEAD"], cwd=repo, check=False)
    print(f"[OK] committed {head.stdout.strip()}: {args.message}")

    if not args.no_push:
        push_ok = False
        try:
            run(["git", "push"], cwd=repo)
            push_ok = True
        except RuntimeError:
            print("[WARN] push rejected; trying `git pull --rebase --autostash` once...")
            try:
                run(["git", "pull", "--rebase", "--autostash"], cwd=repo)
                run(["git", "push"], cwd=repo)
                push_ok = True
            except RuntimeError as e:
                print(f"[ERR] push still failed after one rebase attempt:\n{e}", file=sys.stderr)
                print("[ERR] local commit kept; push manually when ready.", file=sys.stderr)
        print(f"[OK] push: {'done' if push_ok else 'FAILED (local commit kept)'}")

    if not args.no_sync:
        sync = (
            repo
            / ".workbuddy"
            / "skills"
            / "obsidian-task-recorder"
            / "scripts"
            / "sync_task_to_obsidian.py"
        )
        if sync.exists():
            try:
                run([sys.executable, str(sync)], cwd=repo)
                print("[OK] obsidian sync done.")
            except RuntimeError as e:
                print(f"[WARN] obsidian sync failed:\n{e}", file=sys.stderr)
        else:
            print("[WARN] obsidian sync script not found; skipped.", file=sys.stderr)

    print("[DONE]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
