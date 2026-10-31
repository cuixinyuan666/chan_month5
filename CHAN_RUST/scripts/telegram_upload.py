#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 A 股日线 CSV 上传到 Telegram bot，并生成可按代码精准取数的索引。

用法：
  set TG_BOT_TOKEN=123:abc
  set TG_CHAT_ID=123456789
  python telegram_upload.py --dir ../../exports/a_shares_daily

产物：
  - 每只股票一个 document（文件名 sz000001.csv）
  - index.json：code -> {file_id, message_id, name, bars, first, last}
  - upload_state.json：断点续传状态（本机，不入库）

说明：只依赖 Python 标准库；遇到 429 按 retry_after 自动退避。
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

API = "https://api.telegram.org/bot{token}/{method}"


def api_call(token: str, method: str, payload: dict | None = None, timeout: int = 60) -> dict:
    url = API.format(token=token, method=method)
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        try:
            return json.loads(body)
        except Exception:
            return {"ok": False, "error_code": e.code, "description": body}


def multipart(fields: dict, file_field: str, file_path: Path) -> tuple[bytes, str]:
    boundary = "----chan" + uuid.uuid4().hex
    lines: list[bytes] = []
    for k, v in fields.items():
        lines.append(f"--{boundary}\r\n".encode())
        lines.append(f'Content-Disposition: form-data; name="{k}"\r\n\r\n'.encode())
        lines.append(str(v).encode("utf-8"))
        lines.append(b"\r\n")
    mime = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
    lines.append(f"--{boundary}\r\n".encode())
    lines.append(
        f'Content-Disposition: form-data; name="{file_field}"; filename="{file_path.name}"\r\n'.encode()
    )
    lines.append(f"Content-Type: {mime}\r\n\r\n".encode())
    lines.append(file_path.read_bytes())
    lines.append(b"\r\n")
    lines.append(f"--{boundary}--\r\n".encode())
    return b"".join(lines), f"multipart/form-data; boundary={boundary}"


def send_document(token: str, chat_id: str, path: Path, caption: str, retries: int = 6) -> dict:
    body, ctype = multipart(
        {"chat_id": chat_id, "caption": caption, "disable_notification": "true"},
        "document",
        path,
    )
    url = API.format(token=token, method="sendDocument")
    for attempt in range(retries):
        req = urllib.request.Request(url, data=body, headers={"Content-Type": ctype}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            text = e.read().decode("utf-8", errors="replace")
            try:
                j = json.loads(text)
            except Exception:
                j = {"ok": False, "description": text}
            if j.get("error_code") == 429:
                wait = int(j.get("parameters", {}).get("retry_after", 5))
                print(f"    429 限流，等待 {wait}s", flush=True)
                time.sleep(wait + 1)
                continue
            if e.code >= 500:
                time.sleep(2 + attempt * 2)
                continue
            return j
        except (urllib.error.URLError, TimeoutError) as e:
            print(f"    网络错误 {e}，重试 {attempt + 1}/{retries}", flush=True)
            time.sleep(2 + attempt * 2)
    return {"ok": False, "description": "重试耗尽"}


def load_json(path: Path, default):
    if path.is_file():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return default
    return default


def save_json(path: Path, obj):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(path)


def parse_caption_name(name: str) -> str:
    return name.replace(",", " ").strip() or "-"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="../../exports/a_shares_daily")
    ap.add_argument("--token", default=os.environ.get("TG_BOT_TOKEN", ""))
    ap.add_argument("--chat-id", default=os.environ.get("TG_CHAT_ID", ""))
    ap.add_argument("--rate", type=float, default=8.0, help="每秒最多上传多少个文件")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--index-only", action="store_true")
    args = ap.parse_args()

    out = Path(args.dir).resolve()
    daily = out / "daily"
    if not daily.is_dir():
        print(f"找不到目录：{daily}")
        return 2

    summary = {}
    sum_path = out / "summary.csv"
    if sum_path.is_file():
        lines = sum_path.read_text(encoding="utf-8").splitlines()
        for line in lines[1:]:
            parts = line.split(",")
            if len(parts) >= 8:
                summary[parts[0]] = {
                    "name": parts[1],
                    "market": int(parts[2] or 0),
                    "bars": int(parts[4] or 0),
                    "first": parts[5],
                    "last": parts[6],
                }

    files = sorted(daily.glob("*.csv"))
    if args.limit:
        files = files[: args.limit]
    print(f"待上传文件：{len(files)} 个（目录 {daily}）")

    state_path = out / "upload_state.json"
    index_path = out / "index.json"
    state = load_json(state_path, {"files": {}})
    index = load_json(index_path, {"version": 1, "files": {}})

    if args.dry_run:
        total_bytes = sum(f.stat().st_size for f in files)
        print(f"dry-run：合计 {total_bytes / 1024 / 1024:.1f} MB，最大单文件 "
              f"{max((f.stat().st_size for f in files), default=0) / 1024:.0f} KB")
        print(f"已上传记录：{len(state['files'])}")
        return 0

    if not args.token or not args.chat_id:
        print("缺少 TG_BOT_TOKEN / TG_CHAT_ID（环境变量或 --token/--chat-id）")
        return 2

    me = api_call(args.token, "getMe")
    if not me.get("ok"):
        print(f"getMe 失败：{me}")
        return 2
    print(f"bot: @{me['result'].get('username')}")

    if not args.index_only:
        interval = 1.0 / max(args.rate, 0.5)
        last = 0.0
        done = 0
        for f in files:
            code = f.stem[-6:]
            if code in state["files"] and state["files"][code].get("file_id"):
                continue
            meta = summary.get(code, {})
            caption = f"#A股 {code} {parse_caption_name(meta.get('name', ''))} " \
                      f"{meta.get('first', '')}~{meta.get('last', '')} {meta.get('bars', 0)}根"
            wait = interval - (time.time() - last)
            if wait > 0:
                time.sleep(wait)
            last = time.time()
            resp = send_document(args.token, args.chat_id, f, caption)
            if not resp.get("ok"):
                print(f"    上传失败 {f.name}: {resp.get('description')}")
                continue
            doc = resp["result"].get("document", {})
            state["files"][code] = {
                "file_id": doc.get("file_id"),
                "message_id": resp["result"].get("message_id"),
                "name": meta.get("name", ""),
                "bars": meta.get("bars", 0),
                "first": meta.get("first", ""),
                "last": meta.get("last", ""),
                "market": meta.get("market", 0),
                "size": f.stat().st_size,
            }
            done += 1
            if done % 25 == 0:
                save_json(state_path, state)
                print(f"  已上传 {done}，累计 {len(state['files'])}", flush=True)

        save_json(state_path, state)

    index["files"] = state["files"]
    index["count"] = len(state["files"])
    index["generated_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
    save_json(index_path, index)

    # 上传索引本身
    resp = send_document(
        args.token,
        args.chat_id,
        index_path,
        f"#A股索引 index.json（{index['count']} 只，按代码精准取数）",
    )
    if resp.get("ok"):
        state["index_message_id"] = resp["result"].get("message_id")
        state["index_file_id"] = resp["result"].get("document", {}).get("file_id")
        save_json(state_path, state)
        print(f"索引已上传：message_id={state['index_message_id']}")
    else:
        print(f"索引上传失败：{resp.get('description')}")

    print(f"完成：共 {index['count']} 只已入 bot。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
