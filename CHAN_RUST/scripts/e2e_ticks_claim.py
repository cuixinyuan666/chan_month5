#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""两机抢股票端到端：不下载、不上传电报，只验证共享目录占用。

用法（两台几乎同时启动）:
  set TICKS_SKIP_INDEX_PUBLISH=1
  python e2e_ticks_claim.py --share \\\\host\\chan_ticks_state\\e2e --machine CXY --n 4
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

import pipeline_stream_ticks as pipe


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--share", required=True)
    parser.add_argument("--machine", required=True)
    parser.add_argument("--n", type=int, default=4, help="本机最多抢几只")
    parser.add_argument("--codes", default="000001,000002,000004,000006,000007,000008")
    args = parser.parse_args()

    os.environ["TICKS_SKIP_INDEX_PUBLISH"] = "1"
    share = Path(args.share)
    share.mkdir(parents=True, exist_ok=True)
    pipe.configure(
        share_dir=str(share),
        machine=args.machine,
        data_root=str(share / "_local" / args.machine),
        repo_root=str(Path(__file__).resolve().parents[2]),
    )
    pipe.TOKEN = pipe.TOKEN or "e2e"
    pipe.CHAT_ID = pipe.CHAT_ID or "e2e"
    for p in (pipe.STATE_DIR, pipe.CLAIMS_DIR, pipe.LOCAL_DIR):
        p.mkdir(parents=True, exist_ok=True)

    codes = [c.strip() for c in args.codes.split(",") if c.strip()]
    ready = share / f"ready_{args.machine}.json"
    ready.write_text(args.machine, encoding="utf-8")
    deadline = time.time() + 40
    while time.time() < deadline:
        if len(list(share.glob("ready_*.json"))) >= 2:
            break
        time.sleep(0.2)
    got: list[str] = []
    for _ in range(args.n):
        code = pipe.claim_next(codes)
        if not code:
            break
        pipe.heartbeat(code)
        got.append(code)
        # 占住一会儿，让另一台抢到别的股票
        time.sleep(1.0)
        entry = {"years": {"e2e": {"file_id": f"e2e-{args.machine}-{code}", "days": 1}}}
        pipe.complete_code(code, entry)

    result = {
        "machine": args.machine,
        "claimed": got,
        "at": time.strftime("%H:%M:%S"),
    }
    out = share / f"result_{args.machine}.json"
    out.write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))

    st = pipe.load_state()
    done_n = len(st.get("files") or {})
    if done_n >= len(codes) and not pipe._live_claims():
        pipe.try_publish_index(len(codes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
