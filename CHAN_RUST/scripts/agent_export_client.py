#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""通过 App 智能体验证（Agent API）启动/查询数据导出任务。"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

PORT = 12321


def repo_root() -> str:
    here = os.path.abspath(os.path.dirname(__file__))
    return os.path.normpath(os.path.join(here, "..", ".."))


def read_token() -> str:
    p = os.path.join(repo_root(), "a_Data", "agent_live", "agent_api_token.txt")
    if not os.path.isfile(p):
        raise SystemExit(f"找不到令牌文件（App 需 CHAN_AGENT_API=1 启动）：{p}")
    return open(p, encoding="utf-8").read().strip()


def api(method: str, path: str, token: str, body: dict | None = None) -> dict:
    url = f"http://127.0.0.1:{PORT}{path}"
    data = None
    headers = {"X-Agent-Token": token}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8"))


def wait_task(token: str, task_id: str, poll: float = 2.0) -> dict:
    while True:
        j = api("GET", f"/export_task?task_id={task_id}", token)
        if not j.get("ok"):
            return j
        phase = j.get("phase")
        print(
            f"  [{phase}] {j.get('detail')} "
            f"done={j.get('done')}/{j.get('total')} "
            f"elapsed={j.get('elapsed_seconds')}s",
            flush=True,
        )
        if phase in ("done", "failed", "cancelled"):
            if j.get("error"):
                print("  error:", j["error"], flush=True)
            if j.get("summary"):
                print("  summary:", json.dumps(j["summary"], ensure_ascii=False), flush=True)
            return j
        time.sleep(poll)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--type", choices=("export_ticks", "export_daily"), required=True)
    ap.add_argument("--codes", default="", help="逗号分隔，如 000001,600519,002003")
    ap.add_argument("--begin", default="", help="YYYYMMDD，分笔导出")
    ap.add_argument("--end", default="", help="YYYYMMDD，分笔导出")
    ap.add_argument("--threads", type=int, default=12)
    ap.add_argument("--wait", action="store_true", help="轮询直到任务结束")
    args = ap.parse_args()

    token = read_token()
    health = api("GET", "/health", token)
    print("health:", health.get("ok"), "pid", health.get("pid"))

    body: dict = {"type": args.type, "quantity": args.threads}
    if args.codes:
        body["code"] = args.codes
    if args.begin:
        body["begin"] = args.begin
    if args.end:
        body["end"] = args.end

    resp = api("POST", "/command", token, body)
    print(json.dumps(resp, ensure_ascii=False, indent=2))
    if not resp.get("ok"):
        return 2
    task_id = (resp.get("data") or {}).get("task_id")
    if args.wait and task_id:
        final = wait_task(token, task_id)
        return 0 if final.get("phase") == "done" and not final.get("error") else 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
