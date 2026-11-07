#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""合并分笔索引（整股包 + 按年/年段包）并上传 Telegram，供 App 按代码精准取数。

产物：
  - Telegram 上的 ticks_index.json（含 file_id）
  - G:\\chan_month5_data\\state\\ticks\\ticks_index_hint.json
  - 自动回写 App 的 .chan_telegram_settings.json（tick_index_file_id）
"""
from __future__ import annotations

import json
import os
import time
import urllib.request
import uuid
from pathlib import Path

REPO = Path(r"D:\2\chan_month5")
STATE_DIR = Path(r"G:\chan_month5_data\state\ticks")
INDEX = STATE_DIR / "ticks_index.json"
HINT = STATE_DIR / "ticks_index_hint.json"
APP_SETTINGS = REPO / "CHAN_RUST" / "flutter" / "chan_kline" / ".chan_telegram_settings.json"
TOKEN = os.environ.get("TG_BOT_TOKEN", "")
CHAT_ID = os.environ.get("TG_CHAT_ID", "")
PROXY = os.environ.get("TG_PROXY", "127.0.0.1:19828").strip()


def opener():
    handlers = []
    if PROXY:
        p = PROXY if "://" in PROXY else f"http://{PROXY}"
        handlers.append(urllib.request.ProxyHandler({"http": p, "https": p}))
    return urllib.request.build_opener(*handlers)


def send_doc(path: Path, caption: str) -> dict:
    boundary = "----chan" + uuid.uuid4().hex
    parts: list[bytes] = []
    for k, v in {"chat_id": CHAT_ID, "caption": caption, "disable_notification": "true"}.items():
        parts.append(f"--{boundary}\r\n".encode())
        parts.append(f'Content-Disposition: form-data; name="{k}"\r\n\r\n'.encode())
        parts.append(str(v).encode("utf-8"))
        parts.append(b"\r\n")
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(
        f'Content-Disposition: form-data; name="document"; filename="{path.name}"\r\n'.encode()
    )
    parts.append(b"Content-Type: application/octet-stream\r\n\r\n")
    parts.append(path.read_bytes())
    parts.append(b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{TOKEN}/sendDocument",
        data=b"".join(parts),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    with opener().open(req, timeout=600) as resp:
        return json.loads(resp.read().decode("utf-8"))


def merge_states() -> dict:
    files: dict = {}
    for name in ("ticks_upload_state.json", "ticks_stream_state.json"):
        p = STATE_DIR / name
        if not p.is_file():
            continue
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        for code, meta in (d.get("files") or {}).items():
            prev = files.get(code)
            if prev is None:
                files[code] = meta
                continue
            # 合并 years（保留更全的一份）
            py = (prev or {}).get("years") or {}
            my = (meta or {}).get("years") or {}
            if len(my) > len(py):
                files[code] = meta
    return {
        "version": 3,
        "kind": "ticks_zip_hybrid",
        "count": len(files),
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "files": files,
    }


def main() -> int:
    if not TOKEN or not CHAT_ID:
        print("missing TG_BOT_TOKEN / TG_CHAT_ID")
        return 2
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    index = merge_states()
    INDEX.write_text(json.dumps(index, ensure_ascii=False, indent=1), encoding="utf-8")
    resp = send_doc(INDEX, f"#ticks_index {index['count']}")
    if not resp.get("ok"):
        print("upload failed", resp)
        return 3
    fid = resp["result"]["document"]["file_id"]
    HINT.write_text(
        json.dumps({"chat_id": CHAT_ID, "tick_index_file_id": fid, "count": index["count"]}, indent=2),
        encoding="utf-8",
    )
    if APP_SETTINGS.is_file():
        try:
            s = json.loads(APP_SETTINGS.read_text(encoding="utf-8-sig"))
            s["tick_index_file_id"] = fid
            APP_SETTINGS.write_text(json.dumps(s, ensure_ascii=False, indent=2), encoding="utf-8")
        except Exception as e:
            print("settings update failed:", e)
    print(f"ticks index uploaded: count={index['count']} file_id={fid}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
