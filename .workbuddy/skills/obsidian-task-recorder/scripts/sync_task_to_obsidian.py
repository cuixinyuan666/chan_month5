#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sync_task_to_obsidian.py — 把 chan_month5 仓库 task-log.md 的新条目同步到 Obsidian 副本。

设计约定（源自 AGENTS.md「完成后」）：
- 主源：仓库根 task-log.md（唯一权威）。
- 副本：Obsidian Vault/chan-month5/，按日归档、原文保真、LF/UTF-8、[[wikilinks]]。
- 禁止在 Obsidian 手改任务原文；修订须先回写 task-log.md 再同步。

幂等：按条目头行（`### <date> ...`）去重，已存在的条目不重复写。
可批量：一次把 task-log 中尚未同步的多个日期条目补齐。

用法：
  python sync_task_to_obsidian.py
  python sync_task_to_obsidian.py --date 2026-09-22
  python sync_task_to_obsidian.py --task-log /path/to/task-log.md --vault "/path/chan-month5"
  python sync_task_to_obsidian.py --dry-run
"""
import argparse
import os
import re
import sys
from datetime import date, datetime, timedelta


def _read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def _write(p, s):
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(s)


def parse_entries(text):
    """把 task-log.md 拆成条目列表；每条含 header / date / text。

    只把「内容以真实日期 YYYY-MM-DD 开头」的 `### ` 行视为新条目边界；
    其余 `### `（如 `### A.`/`### 2.` 子标题、模板块）归入当前条目正文，
    避免把嵌套子标题误拆成独立条目。
    """
    entries = []
    cur = None
    for line in text.split("\n"):
        if line.startswith("### "):
            content = line[4:].lstrip()
            if re.match(r"\d{4}-\d{2}-\d{2}", content):
                if cur is not None:
                    entries.append(cur)
                cur = {"header": line.strip(), "lines": [line]}
            elif cur is not None:
                cur["lines"].append(line)  # 嵌套子标题 -> 正文
        elif cur is not None:
            cur["lines"].append(line)
    if cur is not None:
        entries.append(cur)
    for e in entries:
        m = re.search(r"\d{4}-\d{2}-\d{2}", e["header"])
        e["date"] = m.group(0) if m else None
        e["text"] = "\n".join(e["lines"]).strip()
    return entries


def existing_daily_notes(vault):
    out = {}
    if not os.path.isdir(vault):
        return out
    for fn in os.listdir(vault):
        m = re.match(r"(\d{4}-\d{2}-\d{2})\.md$", fn)
        if m:
            out[m.group(1)] = os.path.join(vault, fn)
    return out


def prev_next_date(d, notes):
    d0 = datetime.strptime(d, "%Y-%m-%d").date()
    all_dates = sorted(
        datetime.strptime(x, "%Y-%m-%d").date() for x in notes.keys()
    )
    prev_d = next_d = None
    for x in all_dates:
        if x < d0:
            prev_d = x
    for x in reversed(all_dates):
        if x > d0:
            next_d = x
            break
    return (
        prev_d.strftime("%Y-%m-%d") if prev_d else None,
        next_d.strftime("%Y-%m-%d") if next_d else None,
    )


def build_daily_note(d, prev_d, next_d):
    fm = ["---", "tags:", "  - chan/任务日志", "  - chan-month5",
          f"created: {d}", f"date: {d}", 'moc: "[[chan-month5/MOC]]"']
    if prev_d:
        fm.append(f'prev: "[[chan-month5/{prev_d}]]"')
    if next_d:
        fm.append(f'next: "[[chan-month5/{next_d}]]"')
    fm.append("---")
    lines = [
        "\n".join(fm),
        "",
        f"# {d}（任务日志）",
        "",
        "> [!info] 来源与同步",
        "> 本篇由仓库 `task-log.md` 自动回填，原文保真，**请勿手改**；如需修正请先改源文件再同步。",
        f"> 最新同步：{d}。",
        "",
        "---",
        "",
    ]
    # 文末导航
    nav = _nav_line(prev_d, next_d)
    if nav:
        lines.append(nav)
    return "\n".join(lines).rstrip() + "\n"


def _nav_line(prev_d, next_d):
    parts = []
    if prev_d:
        parts.append(f"上一日：[[chan-month5/{prev_d}]]")
    if next_d:
        parts.append(f"下一日：[[chan-month5/{next_d}]]")
    if not parts:
        return None
    return " ｜ ".join(parts) + " ｜ 返回 [[chan-month5/MOC]]"


def append_entry_to_note(note_text, entry_text, prev_d, next_d):
    """把一条 entry 插入到当日笔记（置于文末导航行之前；无导航则追加）。"""
    lines = note_text.split("\n")
    block = "\n---\n\n" + entry_text
    footer_idx = None
    for i, ln in enumerate(lines):
        if ln.strip().startswith("上一日：") or ln.strip().startswith("下一日：") or (
            "返回 [[chan-month5/MOC]]" in ln
        ):
            footer_idx = i
            break
    if footer_idx is not None:
        lines.insert(footer_idx, block.lstrip("\n"))
    else:
        lines.append(block.lstrip("\n"))
        nav = _nav_line(prev_d, next_d)
        if nav:
            lines.append(nav)
    return "\n".join(lines).rstrip() + "\n"


def update_moc(moc_path, vault, task_log_path):
    """刷新 MOC 时间线：扫描 vault 内全部当日笔记，更新/补建每行，并重算总数。

    总数里的「条目数」按各当日笔记真实的 `### ` 头求和（当日笔记无嵌套子标题，
    故等于真实任务条目数），而不是数 task-log.md 的 `### `（那会包含嵌套子标题与模板块）。
    """
    if not os.path.exists(moc_path):
        return
    notes = existing_daily_notes(vault)
    moc = _read(moc_path)
    total_entries = 0
    for d in sorted(notes.keys()):
        count = len(re.findall(r"^### ", _read(notes[d]), re.M))
        total_entries += count
        row_re = re.compile(
            r"^\| " + re.escape(d) + r" \| (\d+) \| \[\[chan-month5/"
            + re.escape(d) + r"\]\] \|$", re.M
        )
        if row_re.search(moc):
            moc = row_re.sub(
                f"| {d} | {count} | [[chan-month5/{d}]] |", moc
            )
        else:
            new_row = f"| {d} | {count} | [[chan-month5/{d}]] |"
            if "最忙日" in moc:
                moc = moc.replace("> 最忙日", new_row + "\n\n> 最忙日", 1)
            else:
                moc = moc.rstrip() + "\n" + new_row + "\n"
    days = len(notes)
    moc = re.sub(r"时间线索引（\d+ 篇）", f"时间线索引（{days} 篇）", moc)
    moc = re.sub(
        r"task-log\.md`?：\d+ 条 / \d+ 天",
        f"task-log.md`：{total_entries} 条 / {days} 天",
        moc,
    )
    # 同步刷新日期区间（起始 → 结束）；否则区间会停留在首次写入时的旧值。
    if notes:
        ds = sorted(notes.keys())
        moc = re.sub(
            r"（\d{4}-\d{2}-\d{2} → \d{4}-\d{2}-\d{2}）",
            f"（{ds[0]} → {ds[-1]}）",
            moc,
        )
    _write(moc_path, moc)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_task_log = os.path.normpath(
        os.path.join(here, "..", "..", "..", "..", "task-log.md")
    )
    default_vault = os.path.normpath(
        os.path.join(
            os.environ.get("USERPROFILE", "C:/Users/86185"),
            "Documents", "Obsidian Vault", "chan-month5",
        )
    )
    ap = argparse.ArgumentParser()
    ap.add_argument("--task-log", default=default_task_log)
    ap.add_argument("--vault", default=default_vault)
    ap.add_argument("--date", default=date.today().strftime("%Y-%m-%d"),
                    help="只同步该日期及之后的条目（默认今天）")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(args.task_log):
        print(f"[ERR] task-log 不存在: {args.task_log}", file=sys.stderr)
        sys.exit(1)

    text = _read(args.task_log)
    entries = parse_entries(text)
    notes = existing_daily_notes(args.vault)
    synced = []

    for e in entries:
        d = e["date"] or args.date
        if d < args.date:
            continue
        note_path = os.path.join(args.vault, d + ".md")
        if d in notes:
            note_text = _read(note_path)
        else:
            prev_d, next_d = prev_next_date(d, notes)
            note_text = build_daily_note(d, prev_d, next_d)
            notes[d] = note_path
        if e["header"] in note_text:
            continue  # 已同步，幂等跳过
        prev_d, next_d = prev_next_date(d, notes)
        new_text = append_entry_to_note(note_text, e["text"], prev_d, next_d)
        if args.dry_run:
            print(f"[DRY] 将同步 {d}: {e['header'][:60]}")
            continue
        _write(note_path, new_text)
        notes[d] = note_path
        synced.append((d, e["header"]))

    if not args.dry_run:
        # 更新 MOC：扫描 vault 全部当日笔记，刷新时间线行与总数
        moc_path = os.path.join(args.vault, "MOC.md")
        update_moc(moc_path, args.vault, args.task_log)

    if synced:
        print(f"[OK] 已同步 {len(synced)} 条：")
        for d, h in synced:
            print(f"  - {d}: {h[:70]}")
    else:
        print("[OK] 无新条目需同步（已是最新）")


if __name__ == "__main__":
    main()
