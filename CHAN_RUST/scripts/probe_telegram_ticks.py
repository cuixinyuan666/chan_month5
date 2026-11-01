#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""随机抽查 Telegram 上的分笔包：下载 → 解压 → 校验笔数列 → 计时。"""
from __future__ import annotations

import io
import json
import os
import random
import time
import urllib.request
import zipfile
from pathlib import Path

STATE = Path(r"G:\chan_month5_data\state\ticks\ticks_stream_state.json")
TOKEN = os.environ.get("TG_BOT_TOKEN", "")
PROXY = "127.0.0.1:19828"


def opener():
    p = f"http://{PROXY}"
    return urllib.request.build_opener(urllib.request.ProxyHandler({"http": p, "https": p}))


def get_json(url: str) -> dict:
    with opener().open(url, timeout=60) as r:
        return json.loads(r.read().decode())


def main() -> int:
    st = json.loads(STATE.read_text(encoding="utf-8-sig"))
    codes = [c for c, e in st["files"].items() if (e or {}).get("years")]
    random.seed(20261101)
    picks = random.sample(codes, 3)
    print(f"随机抽查 {picks}")
    for code in picks:
        years = st["files"][code]["years"]
        tag = random.choice(sorted(years))
        meta = years[tag]
        t0 = time.time()
        info = get_json(f"https://api.telegram.org/bot{TOKEN}/getFile?file_id={meta['file_id']}")
        fp = info["result"]["file_path"]
        with opener().open(
            f"https://api.telegram.org/file/bot{TOKEN}/{fp}", timeout=120
        ) as r:
            blob = r.read()
        t_dl = time.time() - t0
        zf = zipfile.ZipFile(io.BytesIO(blob))
        names = sorted(n for n in zf.namelist() if n.endswith(".txt"))
        sample = zf.read(names[0]).decode("utf-8").splitlines()
        print(
            f"\n{code} {tag}: {meta.get('days')} 天 / {len(blob)/1024/1024:.1f}MB "
            f"下载+解压 {time.time()-t0:.1f}s（下载 {t_dl:.1f}s）"
        )
        print("  文件数", len(names), "首文件", names[0])
        for line in sample[:6]:
            print("   ", line)
        has_ticks = any(len(l.split("\t")) >= 4 and l.split("\t")[3].strip().isdigit() for l in sample[2:])
        print("  笔数列存在:", has_ticks)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
