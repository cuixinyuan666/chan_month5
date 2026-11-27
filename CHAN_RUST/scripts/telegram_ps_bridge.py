#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PowerShell 调 Telegram API（走系统代理），供 Python urllib 不通时使用。"""
from __future__ import annotations

import json
import os
import subprocess
import sys


def ps_get(url: str, timeout: int = 120) -> dict:
    cmd = (
        f"try {{ (Invoke-WebRequest -Uri '{url}' -UseBasicParsing -TimeoutSec {timeout}).Content }}"
        f" catch {{ $_.Exception.Message; exit 1 }}"
    )
    r = subprocess.run(
        ["powershell", "-NoProfile", "-Command", cmd],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if r.returncode != 0:
        raise RuntimeError(r.stderr or r.stdout or "powershell failed")
    return json.loads(r.stdout.strip())


def ps_post_multipart(url: str, fields: dict, file_path: str, timeout: int = 300) -> dict:
    # 用 curl.exe（Windows 10+ 自带）更可靠地上传文件
    args = ["curl.exe", "-sS", "-m", str(timeout), "-F", f"chat_id={fields['chat_id']}"]
    if fields.get("caption"):
        args += ["-F", f"caption={fields['caption']}"]
    args += ["-F", f"document=@{file_path}", url]
    r = subprocess.run(args, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        raise RuntimeError(r.stderr or r.stdout or "curl failed")
    return json.loads(r.stdout.strip() or "{}")


if __name__ == "__main__":
    token = os.environ.get("TG_BOT_TOKEN", "")
    print(ps_get(f"https://api.telegram.org/bot{token}/getMe"))
