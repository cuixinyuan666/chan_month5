#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全市场分笔流水线：按股票串行 —— 下载全历史 → 按年分卷 zip → 上传 → 删本地。

- 下载：调用 Rust export_all_ticks.exe（单股、16 线程），缓存写 G 盘
- 上传：Telegram sendDocument（按年 zip，单卷 ≤ 45MB）
- 删：该股全部年份上传成功后，删本地缓存目录与 zip
- 断点续传：ticks_stream_state.json 记录 code → {years: {year: file_id...}}
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

REPO = Path(r"D:\2\chan_month5")
EXE = REPO / "CHAN_RUST" / "rust" / "target" / "release" / "examples" / "export_all_ticks.exe"
SUMMARY = REPO / "exports" / "a_shares_daily" / "summary.csv"
CACHE_ROOT = Path(r"G:\chan_month5_data\tdx_cache")
OUT_DIR = Path(r"G:\chan_month5_data\export_tmp")
ZIP_DIR = Path(r"G:\chan_month5_data\zips")
STATE_DIR = Path(r"G:\chan_month5_data\state\ticks")
STATE = STATE_DIR / "ticks_stream_state.json"
INDEX = STATE_DIR / "ticks_stream_index.json"
LOG = Path(r"G:\chan_month5_data\pipeline_stream.log")

TOKEN = os.environ.get("TG_BOT_TOKEN", "")
CHAT_ID = os.environ.get("TG_CHAT_ID", "")
PROXY = os.environ.get("TG_PROXY", "127.0.0.1:19828").strip()
MAX_ZIP_MB = 45
RATE = 2.5


def _opener():
    handlers = []
    if PROXY:
        p = PROXY if "://" in PROXY else f"http://{PROXY}"
        handlers.append(urllib.request.ProxyHandler({"http": p, "https": p}))
    return urllib.request.build_opener(*handlers)


def log(msg: str) -> None:
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def load_state() -> dict:
    if STATE.is_file():
        try:
            return json.loads(STATE.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"files": {}}


def save_state(st: dict) -> None:
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(st, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(STATE)


def api(method: str, fields: dict | None = None) -> dict:
    url = f"https://api.telegram.org/bot{TOKEN}/{method}"
    if fields is None:
        req = urllib.request.Request(url)
    else:
        import uuid

        boundary = "----chan" + uuid.uuid4().hex
        parts: list[bytes] = []
        for k, v in fields.items():
            parts.append(f"--{boundary}\r\n".encode())
            parts.append(f'Content-Disposition: form-data; name="{k}"\r\n\r\n'.encode())
            parts.append(str(v).encode("utf-8"))
            parts.append(b"\r\n")
        parts.append(f"--{boundary}--\r\n".encode())
        body = b"".join(parts)
        req = urllib.request.Request(
            url, data=body, headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}
        )
    with _opener().open(req, timeout=600) as resp:
        return json.loads(resp.read().decode("utf-8"))


def send_doc(path: Path, caption: str) -> dict:
    import uuid

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
    body = b"".join(parts)
    url = f"https://api.telegram.org/bot{TOKEN}/sendDocument"
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}
    )
    with _opener().open(req, timeout=600) as resp:
        return json.loads(resp.read().decode("utf-8"))


def upload_year(code: str, year: str, files: list[Path]) -> dict:
    tag = year
    if len(files) > 300:
        pass
    zip_path = ZIP_DIR / f"{code}_{tag}_ticks.zip"
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for f in files:
            z.write(f, arcname=f.name)
    mb = zip_path.stat().st_size / 1024 / 1024
    if mb > MAX_ZIP_MB:
        # 按半年再拆
        zip_path.unlink()
        h1 = [f for f in files if int(f.name[4:6]) <= 6]
        h2 = [f for f in files if int(f.name[4:6]) > 6]
        out = {}
        for sub_tag, sub in ((f"{year}H1", h1), (f"{year}H2", h2)):
            if sub:
                out[sub_tag] = upload_year_files(code, sub_tag, sub)
        return {"split": out}
    time.sleep(1.0 / RATE)
    resp = send_doc(zip_path, f"#ticks {code} {tag} ({len(files)}d)")
    zip_path.unlink(missing_ok=True)
    if not resp.get("ok"):
        raise RuntimeError(f"upload reject: {resp}")
    return {
        "file_id": resp["result"]["document"]["file_id"],
        "message_id": resp["result"]["message_id"],
        "days": len(files),
        "zip_mb": round(mb, 1),
    }


def upload_year_files(code: str, tag: str, files: list[Path]) -> dict:
    zip_path = ZIP_DIR / f"{code}_{tag}_ticks.zip"
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for f in files:
            z.write(f, arcname=f.name)
    mb = zip_path.stat().st_size / 1024 / 1024
    if mb > MAX_ZIP_MB:
        zip_path.unlink()
        raise RuntimeError(f"chunk {code} {tag} too large {mb:.1f}MB")
    time.sleep(1.0 / RATE)
    resp = send_doc(zip_path, f"#ticks {code} {tag} ({len(files)}d)")
    zip_path.unlink(missing_ok=True)
    if not resp.get("ok"):
        raise RuntimeError(f"upload reject: {resp}")
    return {
        "file_id": resp["result"]["document"]["file_id"],
        "message_id": resp["result"]["message_id"],
        "days": len(files),
        "zip_mb": round(mb, 1),
    }


def fetch_stock(code: str) -> bool:
    """调用 Rust 导出器拉单只全历史到 G 缓存；D 盘已有缓存则先搬过来。"""
    src = Path(r"D:\2\chan_month5\a_Data\.tdx_protocol_cache") / code
    dst = CACHE_ROOT / ".tdx_protocol_cache" / code
    if src.is_dir() and not dst.is_dir():
        dst.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["cmd", "/c", "move", str(src), str(dst)], capture_output=True)
    if dst.is_dir() and any(dst.glob("*.txt")):
        return True
    cmd = [
        str(EXE),
        "--codes", code,
        "--begin", "19900101",
        "--end", time.strftime("%Y%m%d"),
        "--threads", "1",
        "--day-threads", "48",
        "--cache-root", str(CACHE_ROOT),
        "--out", str(OUT_DIR),
        "--codes-from", str(SUMMARY),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        log(f"  fetch fail {code}: {(r.stderr or r.stdout)[-300:]}")
        return False
    return True


def main() -> int:
    if not TOKEN or not CHAT_ID:
        log("missing TG_BOT_TOKEN / TG_CHAT_ID")
        return 2
    for p in (CACHE_ROOT, OUT_DIR, ZIP_DIR, STATE_DIR):
        p.mkdir(parents=True, exist_ok=True)

    codes = []
    with SUMMARY.open(encoding="utf-8") as f:
        next(f)
        for line in f:
            p = line.split(",")
            if len(p) >= 3 and len(p[0]) == 6:
                codes.append(p[0])
    st = load_state()
    done = set(st["files"].keys())
    todo = [c for c in codes if c not in done]
    log(f"total codes {len(codes)}, done {len(done)}, todo {len(todo)}")

    for i, code in enumerate(todo, 1):
        t0 = time.time()
        log(f"[{i}/{len(todo)}] {code} fetch ...")
        if not fetch_stock(code):
            continue
        d = CACHE_ROOT / ".tdx_protocol_cache" / code
        files = sorted(d.glob("*.txt")) if d.is_dir() else []
        if not files:
            log(f"  {code} no files")
            continue
        by_year: dict[str, list[Path]] = {}
        for f in files:
            by_year.setdefault(f.name[:4], []).append(f)
        entry = {"years": {}}
        ok = True
        for year in sorted(by_year):
            if year in entry["years"]:
                continue
            try:
                entry["years"][year] = upload_year(code, year, by_year[year])
                save_state({**st, "files": {**st["files"], code: entry}})
            except Exception as e:
                ok = False
                log(f"  fail {code} {year}: {e}")
        st["files"][code] = entry
        save_state(st)
        if ok:
            subprocess.run(["cmd", "/c", "rmdir", "/s", "/q", str(d)], capture_output=True)
            log(f"  {code} done {len(files)}d in {time.time()-t0:.0f}s (uploaded {len(entry['years'])}y)")

    index = {
        "version": 2,
        "kind": "ticks_zip_yearly",
        "count": len(st["files"]),
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "files": st["files"],
    }
    INDEX.write_text(json.dumps(index, ensure_ascii=False, indent=1), encoding="utf-8")
    try:
        resp = send_doc(INDEX, f"#ticks_index {len(st['files'])}")
        if resp.get("ok"):
            log(f"index uploaded file_id={resp['result']['document']['file_id']}")
    except Exception as e:
        log(f"index upload fail: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
