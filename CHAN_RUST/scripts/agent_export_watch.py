#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""智能体验证：启动全市场分笔全历史导出并监控，失败写 agent_live/export_watch.json。"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

PORT = 12321
REPO = Path(__file__).resolve().parents[2]
LIVE = REPO / "a_Data" / "agent_live"
WATCH = LIVE / "export_watch.json"


def token() -> str:
    p = LIVE / "agent_api_token.txt"
    if not p.is_file():
        raise SystemExit(f"缺少 {p}，请先 CHAN_AGENT_API=1 启动 App")
    return p.read_text(encoding="utf-8").strip()


def api(method: str, path: str, tok: str, body: dict | None = None) -> dict:
    url = f"http://127.0.0.1:{PORT}{path}"
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body else None
    headers = {"X-Agent-Token": tok}
    if data:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8"))


def save_watch(obj: dict) -> None:
    LIVE.mkdir(parents=True, exist_ok=True)
    WATCH.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> int:
    tok = token()
    health = api("GET", "/health", tok)
    if not health.get("ok"):
        print("health fail", health)
        return 2

    end = time.strftime("%Y%m%d")
    body = {
        "type": "export_ticks",
        "quantity": 16,
        "begin": "19900101",
        "end": end,
    }
    resp = api("POST", "/command", tok, body)
    print(json.dumps(resp, ensure_ascii=False, indent=2))
    if not resp.get("ok"):
        save_watch({"phase": "start_failed", "response": resp, "ts": time.time()})
        return 3
    task_id = (resp.get("data") or {}).get("task_id")
    save_watch({"phase": "running", "task_id": task_id, "ts": time.time()})

    while True:
        j = api("GET", f"/export_task?task_id={task_id}", tok)
        phase = j.get("phase")
        save_watch({**j, "watched_at": time.time()})
        print(
            f"[{phase}] {j.get('detail')} {j.get('done')}/{j.get('total')} "
            f"elapsed={j.get('elapsed_seconds')}s",
            flush=True,
        )
        if phase in ("done", "failed", "cancelled"):
            return 0 if phase == "done" and not j.get("error") else 4
        time.sleep(30)


if __name__ == "__main__":
    sys.exit(main())
