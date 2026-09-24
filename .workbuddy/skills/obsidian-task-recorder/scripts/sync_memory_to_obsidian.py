#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sync_memory_to_obsidian.py — 把 chan_month5 项目记忆 .workbuddy/memory/*.md
复制进 Obsidian Vault/chan-month5/memory/ 作为可检索副本。

约定（与 obsidian-task-recorder 同源原则一致）：
- 源：仓库 `.workbuddy/memory/`（WorkBuddy 直接读写的项目记忆，唯一权威）。
- 副本：Vault/chan-month5/memory/，加 frontmatter + 来源说明，原文保真，LF/UTF-8，[[wikilinks]]。
- 源文件保留不动（WorkBuddy 仍需直接读），本脚本只产生副本。
- 幂等：synced 取源文件 mtime 日期；若生成的副本全文与现有一致则跳过写，避免无谓改动。

用法：
  python sync_memory_to_obsidian.py
  python sync_memory_to_obsidian.py --dry-run
  python sync_memory_to_obsidian.py --vault "/path/chan-month5" --memory-dir "/path/.workbuddy/memory"
"""
import argparse
import os
import re
import sys
from datetime import datetime

MEMORY_TAG = "chan/工作记忆"


def _read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def _write(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(s)


def _build_copy(name, body, source_path, synced_date):
    """由源正文生成 Vault 副本全文（frontmatter + 标题 + 来源说明 + 原文）。"""
    lines = body.split("\n")
    # 找首非空行
    first_idx = 0
    while first_idx < len(lines) and not lines[first_idx].strip():
        first_idx += 1
    m = re.match(r"^(\d{4}-\d{2}-\d{2})\.md$", name)
    if first_idx < len(lines) and lines[first_idx].startswith("# "):
        title = lines[first_idx]
        rest = "\n".join(lines[first_idx + 1:]).strip()
    elif m:
        title = f"# {m.group(1)} 工作记忆（Obsidian 副本）"
        rest = "\n".join(lines).strip()
    else:
        title = f"# {name}（Obsidian 副本）"
        rest = "\n".join(lines).strip()

    fm = [
        "---",
        "tags:",
        "  - chan-month5",
        f"  - {MEMORY_TAG}",
        f"source: {source_path}",
        "migrate_mode: copy",
        f"synced: {synced_date}",
        "---",
    ]
    prov = (
        "> [!info] 来源与同步\n"
        f"> 本篇为 WorkBuddy 项目记忆 `{source_path}` 的 Obsidian 副本（原文保真，**请勿手改**；"
        "修订请先改源文件再跑 `sync_memory_to_obsidian.py` 重新同步）。\n"
        f"> 最新同步：{synced_date}。"
    )
    out = ["\n".join(fm), "", title, "", prov, "", rest, ""]
    return "\n".join(out)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_memory = os.path.normpath(
        os.path.join(here, "..", "..", "..", "..", ".workbuddy", "memory")
    )
    default_vault = os.path.normpath(
        os.path.join(
            os.environ.get("USERPROFILE", "C:/Users/86185"),
            "Documents", "Obsidian Vault", "chan-month5",
        )
    )
    ap = argparse.ArgumentParser()
    ap.add_argument("--memory-dir", default=default_memory)
    ap.add_argument("--vault", default=default_vault)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not os.path.isdir(args.memory_dir):
        print(f"[ERR] memory 目录不存在: {args.memory_dir}", file=sys.stderr)
        sys.exit(1)

    out_dir = os.path.join(args.vault, "memory")
    done = []
    dry_done = []
    for fn in sorted(os.listdir(args.memory_dir)):
        if not fn.endswith(".md"):
            continue
        src = os.path.join(args.memory_dir, fn)
        if not os.path.isfile(src):
            continue
        mtime = os.path.getmtime(src)
        synced_date = datetime.fromtimestamp(mtime).strftime("%Y-%m-%d")
        body = _read(src)
        source_path = "file:///" + src.replace("\\", "/")
        copy_text = _build_copy(fn, body, source_path, synced_date)
        dest = os.path.join(out_dir, fn)
        if os.path.exists(dest) and _read(dest) == copy_text:
            continue  # 幂等跳过
        if args.dry_run:
            print(f"[DRY] 将同步 {fn} (synced={synced_date})")
            dry_done.append(fn)
            continue
        _write(dest, copy_text)
        done.append(fn)

    if args.dry_run:
        if dry_done:
            print(f"[DRY] 共 {len(dry_done)} 篇记忆需同步到 {out_dir}：")
            for fn in dry_done:
                print(f"  - {fn}")
        else:
            print("[DRY] 记忆副本已是最新（无变化）")
    elif done:
        print(f"[OK] 已同步 {len(done)} 篇记忆到 {out_dir}：")
        for fn in done:
            print(f"  - {fn}")
    else:
        print("[OK] 记忆副本已是最新（无变化）")


if __name__ == "__main__":
    main()
