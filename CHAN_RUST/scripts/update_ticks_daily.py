#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""每日分笔增量更新：拉指定交易日全市场分笔 → 一股一包上传 Telegram → 删本地缓存。

规则（用户 2026-11-01 确认）：
  - 盘中（交易日 15:30 前）只更新到「上一个交易日」；
  - 收盘后（>=15:30）才包含当天；
  - 周末/非交易日更新到最近一个交易日。

用法：
  python update_ticks_daily.py                # 自动判定目标日
  python update_ticks_daily.py --date 20261030
  python update_ticks_daily.py --limit 20 --dry-run
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import time
import urllib.request
import uuid
import zipfile
from datetime import date, datetime, timedelta
from pathlib import Path

REPO = Path(r"D:\2\chan_month5")
EXE = REPO / "CHAN_RUST" / "rust" / "target" / "release" / "examples" / "export_all_ticks.exe"
SUMMARY = REPO / "exports" / "a_shares_daily" / "summary.csv"
WORK = Path(r"G:\chan_month5_data\daily_ticks")
CACHE = WORK / "cache"
ZIP_DIR = WORK / "zips"
INDEX_DIR = Path(r"G:\chan_month5_data\state\ticks_daily")
LOG = WORK / "update.log"

TOKEN = os.environ.get("TG_BOT_TOKEN", "")
CHAT_ID = os.environ.get("TG_CHAT_ID", "")
PROXY = os.environ.get("TG_PROXY", "127.0.0.1:19828").strip()
RATE = 4.0
CLOSE_HHMM = (15, 30)


def log(msg: str) -> None:
    WORK.mkdir(parents=True, exist_ok=True)
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


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


def is_trading_day(d: date) -> bool:
    return d.weekday() < 5


def prev_trading_day(d: date) -> date:
    d -= timedelta(days=1)
    while not is_trading_day(d):
        d -= timedelta(days=1)
    return d


def target_date(now: datetime | None = None) -> date:
    """盘中只到上一交易日；收盘后含当天；非交易日回退。"""
    now = now or datetime.now()
    d = now.date()
    if not is_trading_day(d):
        return prev_trading_day(d)
    if (now.hour, now.minute) < CLOSE_HHMM:
        return prev_trading_day(d)
    return d


def fetch_day(target: date, threads: int, codes: str = "") -> bool:
    """调用 Rust 导出器拉全市场某一天的分笔到 G 缓存。"""
    cmd = [
        str(EXE),
        "--begin", target.strftime("%Y%m%d"),
        "--end", target.strftime("%Y%m%d"),
        "--threads", str(threads),
        "--cache-root", str(CACHE),
        "--out", str(WORK / "manifest"),
        "--codes-from", str(SUMMARY),
    ]
    if codes.strip():
        cmd += ["--codes", codes.strip()]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        log("fetch failed: " + (r.stderr or r.stdout)[-500:])
        return False
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", default="")
    ap.add_argument("--threads", type=int, default=24)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--codes", default="", help="逗号分隔，测试用")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not TOKEN or not CHAT_ID:
        print("missing TG_BOT_TOKEN / TG_CHAT_ID")
        return 2

    target = (
        datetime.strptime(args.date, "%Y%m%d").date() if args.date else target_date()
    )
    tag = target.strftime("%Y%m%d")
    log(f"target date {tag} (trading day={is_trading_day(target)})")

    CACHE.mkdir(parents=True, exist_ok=True)
    ZIP_DIR.mkdir(parents=True, exist_ok=True)
    INDEX_DIR.mkdir(parents=True, exist_ok=True)

    t0 = time.time()
    if not fetch_day(target, args.threads, args.codes):
        return 3
    dirs = sorted((CACHE / ".tdx_protocol_cache").glob("*"))
    if args.codes.strip():
        want = {c.strip() for c in args.codes.split(",") if c.strip()}
        dirs = [d for d in dirs if d.name in want]
    if args.limit:
        dirs = dirs[: args.limit]
    log(f"fetched {len(dirs)} stocks in {time.time()-t0:.0f}s")

    month = target.strftime("%Y-%m")
    index_path = INDEX_DIR / f"ticks_daily_{month}.json"
    index = {"version": 1, "kind": "ticks_daily", "month": month, "files": {}}
    if index_path.is_file():
        try:
            index = json.loads(index_path.read_text(encoding="utf-8-sig"))
        except Exception:
            pass
    files = index.setdefault("files", {})

    ok = fail = 0
    for d in dirs:
        code = d.name
        txts = sorted(d.glob("*.txt"))
        if not txts:
            shutil.rmtree(d, ignore_errors=True)
            continue
        entry = files.setdefault(code, {})
        if entry.get(tag, {}).get("file_id"):
            shutil.rmtree(d, ignore_errors=True)
            continue
        zip_path = ZIP_DIR / f"{code}_{tag}_ticks.zip"
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            for f in txts:
                z.write(f, arcname=f.name)
        if args.dry_run:
            log(f"  dry-run {code}: {len(txts)} files, {zip_path.stat().st_size/1024:.0f}KB")
            zip_path.unlink(missing_ok=True)
            ok += 1
            continue
        try:
            time.sleep(1.0 / RATE)
            resp = send_doc(zip_path, f"#ticks {code} {tag}")
            if not resp.get("ok"):
                raise RuntimeError(str(resp))
            entry[tag] = {
                "file_id": resp["result"]["document"]["file_id"],
                "message_id": resp["result"]["message_id"],
                "rows": sum(1 for _ in open(txts[0], encoding="utf-8")) - 3 if txts else 0,
            }
            ok += 1
            shutil.rmtree(d, ignore_errors=True)
        except Exception as e:
            fail += 1
            log(f"  fail {code}: {e}")
        finally:
            zip_path.unlink(missing_ok=True)
        if (ok + fail) % 200 == 0:
            index_path.write_text(json.dumps(index, ensure_ascii=False, indent=1), encoding="utf-8")
            log(f"  progress {ok+fail}/{len(dirs)} ok={ok} fail={fail}")

    index["count"] = len([c for c, v in files.items() if v])
    index["updated_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
    index_path.write_text(json.dumps(index, ensure_ascii=False, indent=1), encoding="utf-8")
    log(f"done {tag}: ok={ok} fail={fail} stocks_in_index={index['count']} elapsed={time.time()-t0:.0f}s")

    if not args.dry_run:
        try:
            resp = send_doc(index_path, f"#ticks_daily_index {month} {tag}")
            if resp.get("ok"):
                log(f"index uploaded: {resp['result']['document']['file_id']}")
                hint = INDEX_DIR / "ticks_daily_hint.json"
                hint.write_text(
                    json.dumps(
                        {
                            "month": month,
                            "file_id": resp["result"]["document"]["file_id"],
                            "last_date": tag,
                        },
                        indent=2,
                    ),
                    encoding="utf-8",
                )
        except Exception as e:
            log(f"index upload fail: {e}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
