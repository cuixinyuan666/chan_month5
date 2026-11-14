#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全市场分笔流水线：按股票串行 —— 下载全历史 → 按年分卷 zip → 上传 → 删本地。

支持两机抢传：进度/claims/锁放在共享目录；本机缓存仍用本机 dataRoot。
配置来自 --job job.json 或环境变量；令牌从 settings JSON 读取，不写死在脚本里。
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import zipfile
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

# 子进程不另开控制台，避免每下一只股票弹出一个黑框
_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def _run_hidden(cmd: list[str], **kwargs):
    if _NO_WINDOW:
        kwargs["creationflags"] = kwargs.get("creationflags", 0) | _NO_WINDOW
    return subprocess.run(cmd, **kwargs)

# ---- defaults (overridden by configure) ----
REPO = Path(r"D:\2\chan_month5")
EXE = REPO / "CHAN_RUST" / "rust" / "target" / "release" / "examples" / "export_all_ticks.exe"
SUMMARY = REPO / "exports" / "a_shares_daily" / "summary.csv"
DATA_ROOT = Path(r"G:\chan_month5_data")
CACHE_ROOT = DATA_ROOT / "tdx_cache"
OUT_DIR = DATA_ROOT / "export_tmp"
ZIP_DIR = DATA_ROOT / "zips_work"
STATE_DIR = DATA_ROOT / "state" / "ticks"
STATE = STATE_DIR / "ticks_stream_state.json"
INDEX = STATE_DIR / "ticks_stream_index.json"
CLAIMS_DIR = STATE_DIR / "claims"
LOCK = STATE_DIR / "state.lock"
LOG = DATA_ROOT / "pipeline_stream.log"
LOCAL_DIR = DATA_ROOT / "local"
CURRENT_CODE_FILE = LOCAL_DIR / "current_code.txt"
STATUS_JSON = LOCAL_DIR / "status.json"
INDEX_PUBLISHED_FLAG = STATE_DIR / "index_published.flag"

MACHINE = socket.gethostname()
TOKEN = ""
CHAT_ID = ""
PROXY = "127.0.0.1:19828"
SETTINGS_PATH: Path | None = None
JOB_DIR: Path | None = None
SHARE_DIR: Path | None = None

# 本机代理（127.0.0.1:19828）实测单次上传阈值：3MB/5MB 可过（33~38KB/s），
# 6MB 传到一半被远端断开、10MB 立刻断 TLS。故包上限压到 4MB 留余量。
MAX_ZIP_MB = 4
RATE = 2.5
LOCK_STALE_SEC = 30
CLAIM_STALE_SEC = 600  # 10 min
HEARTBEAT_INTERVAL = 60

_last_heartbeat = 0.0
_current_code: str | None = None
_hb_lock = threading.Lock()

# 进度上报：最近 10 分钟完成时刻，用来算「只/分」；以及 status 写入节流
_done_marks: list[float] = []
_session_start = time.time()
_last_status_at = 0.0
_status_done = 0
_status_total = 0


def configure(
    *,
    share_dir: str | None = None,
    settings_path: str | None = None,
    machine: str | None = None,
    data_root: str | None = None,
    repo_root: str | None = None,
    job_path: str | None = None,
) -> None:
    global REPO, EXE, SUMMARY, DATA_ROOT, CACHE_ROOT, OUT_DIR, ZIP_DIR
    global STATE_DIR, STATE, INDEX, CLAIMS_DIR, LOCK, LOG
    global LOCAL_DIR, CURRENT_CODE_FILE, STATUS_JSON, INDEX_PUBLISHED_FLAG
    global MACHINE, TOKEN, CHAT_ID, PROXY, SETTINGS_PATH, JOB_DIR, SHARE_DIR

    if job_path:
        JOB_DIR = Path(job_path).resolve().parent
        job = json.loads(Path(job_path).read_text(encoding="utf-8-sig"))
        share_dir = share_dir or job.get("shareDir") or job.get("share_dir")
        settings_path = settings_path or job.get("settingsPath") or job.get("settings_path")
        machine = machine or job.get("machineName") or job.get("machine")
        data_root = data_root or job.get("dataRoot") or job.get("data_root")
        repo_root = repo_root or job.get("repoRoot") or job.get("repo_root")

    share_dir = share_dir or os.environ.get("TICKS_SHARE_DIR") or ""
    settings_path = settings_path or os.environ.get("TICKS_SETTINGS_PATH") or ""
    machine = machine or os.environ.get("TICKS_MACHINE") or socket.gethostname()
    data_root = data_root or os.environ.get("TICKS_DATA_ROOT") or r"G:\chan_month5_data"
    repo_root = repo_root or os.environ.get("TICKS_REPO_ROOT") or str(REPO)

    MACHINE = str(machine).strip() or socket.gethostname()
    DATA_ROOT = Path(data_root)
    REPO = Path(repo_root)
    EXE = REPO / "CHAN_RUST" / "rust" / "target" / "release" / "examples" / "export_all_ticks.exe"
    SUMMARY = REPO / "exports" / "a_shares_daily" / "summary.csv"
    CACHE_ROOT = DATA_ROOT / "tdx_cache"
    OUT_DIR = DATA_ROOT / "export_tmp"
    ZIP_DIR = DATA_ROOT / "zips_work"
    LOG = DATA_ROOT / "pipeline_stream.log"
    LOCAL_DIR = DATA_ROOT / "local"
    CURRENT_CODE_FILE = LOCAL_DIR / "current_code.txt"
    STATUS_JSON = LOCAL_DIR / "status.json"

    if share_dir.strip():
        SHARE_DIR = Path(share_dir.strip())
        STATE_DIR = SHARE_DIR
    else:
        SHARE_DIR = None
        STATE_DIR = DATA_ROOT / "state" / "ticks"

    STATE = STATE_DIR / "ticks_stream_state.json"
    INDEX = STATE_DIR / "ticks_stream_index.json"
    CLAIMS_DIR = STATE_DIR / "claims"
    LOCK = STATE_DIR / "state.lock"
    INDEX_PUBLISHED_FLAG = STATE_DIR / "index_published.flag"

    if settings_path.strip():
        SETTINGS_PATH = Path(settings_path.strip())
    else:
        # 常见落点：仓库 flutter 工程 cwd
        candidates = [
            REPO / "CHAN_RUST" / "flutter" / "chan_kline" / ".chan_telegram_settings.json",
            Path.cwd() / ".chan_telegram_settings.json",
        ]
        SETTINGS_PATH = next((p for p in candidates if p.is_file()), candidates[0])

    _load_credentials()


def _load_credentials() -> None:
    global TOKEN, CHAT_ID, PROXY
    TOKEN = os.environ.get("TG_BOT_TOKEN", "").strip()
    CHAT_ID = os.environ.get("TG_CHAT_ID", "").strip()
    PROXY = os.environ.get("TG_PROXY", "").strip()
    if SETTINGS_PATH and SETTINGS_PATH.is_file():
        try:
            s = json.loads(SETTINGS_PATH.read_text(encoding="utf-8-sig"))
            if not TOKEN:
                TOKEN = (s.get("bot_token") or "").strip()
            if not CHAT_ID:
                CHAT_ID = (s.get("chat_id") or "").strip()
            if not PROXY and s.get("proxy"):
                PROXY = str(s.get("proxy") or "").strip()
        except Exception as e:
            log(f"settings read fail: {e}")
    if not PROXY:
        PROXY = "127.0.0.1:19828"


def _opener():
    handlers = []
    if PROXY:
        p = PROXY if "://" in PROXY else f"http://{PROXY}"
        handlers.append(urllib.request.ProxyHandler({"http": p, "https": p}))
    return urllib.request.build_opener(*handlers)


def log(msg: str) -> None:
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def load_state() -> dict:
    if STATE.is_file():
        try:
            return json.loads(STATE.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"files": {}}


def save_state(st: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(st, ensure_ascii=False, indent=1)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(payload, encoding="utf-8")
    try:
        tmp.replace(STATE)
        return
    except OSError:
        pass
    try:
        if STATE.exists():
            STATE.unlink()
        tmp.replace(STATE)
        return
    except OSError:
        pass
    STATE.write_text(payload, encoding="utf-8")
    try:
        tmp.unlink()
    except OSError:
        pass


def _lock_payload() -> bytes:
    return json.dumps(
        {"pid": os.getpid(), "machine": MACHINE, "time": time.time()},
        ensure_ascii=False,
    ).encode("utf-8")


def _lock_is_stale(path: Path) -> bool:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        t = float(data.get("time") or 0)
        return (time.time() - t) > LOCK_STALE_SEC
    except Exception:
        # 无法解析：看 mtime
        try:
            return (time.time() - path.stat().st_mtime) > LOCK_STALE_SEC
        except Exception:
            return True


@contextmanager
def state_lock(timeout: float = 30.0) -> Iterator[None]:
    """短锁：O_CREAT|O_EXCL；超时/心跳过期可抢。"""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    deadline = time.time() + timeout
    acquired = False
    while time.time() < deadline:
        try:
            fd = os.open(str(LOCK), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            try:
                os.write(fd, _lock_payload())
            finally:
                os.close(fd)
            acquired = True
            break
        except FileExistsError:
            if LOCK.is_file() and _lock_is_stale(LOCK):
                try:
                    LOCK.unlink()
                except OSError:
                    pass
            time.sleep(0.05)
        except OSError:
            time.sleep(0.05)
    if not acquired:
        raise TimeoutError(f"state.lock timeout: {LOCK}")
    try:
        yield
    finally:
        try:
            LOCK.unlink(missing_ok=True)
        except OSError:
            pass


def _read_claim(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _claim_alive(meta: dict | None) -> bool:
    if not meta:
        return False
    try:
        hb = float(meta.get("heartbeat_at") or meta.get("started_at") or 0)
    except (TypeError, ValueError):
        return False
    return (time.time() - hb) <= CLAIM_STALE_SEC


def _claim_is_ours(meta: dict | None) -> bool:
    if not meta:
        return False
    try:
        pid = int(meta.get("pid") or 0)
    except (TypeError, ValueError):
        return False
    return meta.get("machine") == MACHINE and pid == os.getpid()


def _settled_codes(st: dict) -> set:
    """已上传或已确认没有分笔文件的股票，都不再抢。"""
    return set((st.get("files") or {}).keys()) | set((st.get("skipped") or {}).keys())


def skip_no_files(code: str) -> None:
    """下载成功但没有任何分笔文件：记入跳过，避免两台反复抢同一只。"""
    with state_lock():
        st = load_state()
        skipped = st.setdefault("skipped", {})
        skipped[code] = {
            "reason": "no_files",
            "at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "machine": MACHINE,
        }
        save_state(st)
        release_claim(code)
    log(f"  {code} skip no files (skipped={len(skipped)})")
    # #region agent log
    try:
        dbg = Path(r"d:\2\chan_month5\.cursor\debug-ac456b.log")
        dbg.parent.mkdir(parents=True, exist_ok=True)
        dbg.open("a", encoding="utf-8").write(
            json.dumps(
                {
                    "sessionId": "ac456b",
                    "hypothesisId": "E",
                    "location": "pipeline_stream_ticks.py:skip_no_files",
                    "message": "empty stock skipped",
                    "data": {"code": code, "skipped": len(skipped)},
                    "timestamp": int(time.time() * 1000),
                },
                ensure_ascii=False,
            )
            + "\n"
        )
    except Exception:
        pass
    # #endregion


def claim_next(codes: list[str]) -> str | None:
    """持短锁写下占用后立刻放锁，再读回确认是自己，避免两台抢到同一只。"""
    CLAIMS_DIR.mkdir(parents=True, exist_ok=True)
    for _attempt in range(8):
        chosen: str | None = None
        with state_lock():
            st = load_state()
            done = _settled_codes(st)
            for p in list(CLAIMS_DIR.glob("*.json")):
                meta = _read_claim(p)
                if not _claim_alive(meta):
                    try:
                        p.unlink()
                    except OSError:
                        pass
            live = {p.stem for p in CLAIMS_DIR.glob("*.json")}
            for code in codes:
                if code in done or code in live:
                    continue
                now = time.time()
                payload = {
                    "machine": MACHINE,
                    "pid": os.getpid(),
                    "started_at": now,
                    "heartbeat_at": now,
                    "code": code,
                }
                claim_path = CLAIMS_DIR / f"{code}.json"
                claim_path.write_text(
                    json.dumps(payload, ensure_ascii=False, indent=1),
                    encoding="utf-8",
                )
                chosen = code
                break
        if not chosen:
            return None
        time.sleep(0.4)
        owned = _read_claim(CLAIMS_DIR / f"{chosen}.json")
        if _claim_is_ours(owned):
            return chosen
        log(f"  lost claim race {chosen} -> {(owned or {}).get('machine')}")
    return None


def heartbeat(code: str) -> None:
    global _last_heartbeat
    path = CLAIMS_DIR / f"{code}.json"
    if not path.is_file():
        return
    try:
        meta = _read_claim(path) or {}
        if meta.get("machine") not in (None, MACHINE) or int(meta.get("pid") or 0) not in (0, os.getpid()):
            return
        meta["heartbeat_at"] = time.time()
        meta["machine"] = MACHINE
        meta["pid"] = os.getpid()
        meta["code"] = code
        path.write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
        _last_heartbeat = time.time()
        # 单只股票可能要传好几分钟，顺手刷新 status，别让界面看着像停住了
        if time.time() - _last_status_at >= 30:
            write_status(_status_done, _status_total, code)
    except Exception as e:
        log(f"  heartbeat fail {code}: {e}")


def maybe_heartbeat(code: str) -> None:
    global _last_heartbeat
    if time.time() - _last_heartbeat < HEARTBEAT_INTERVAL:
        return
    # 并发上传时可能有多个线程同时到期，用非阻塞锁保证只有一路真正去写 claim 文件
    if not _hb_lock.acquire(blocking=False):
        return
    try:
        heartbeat(code)
    finally:
        _hb_lock.release()


def release_claim(code: str) -> None:
    path = CLAIMS_DIR / f"{code}.json"
    try:
        path.unlink(missing_ok=True)
    except OSError:
        pass


def complete_code(code: str, entry: dict) -> None:
    # 记下是谁、什么时候传完的：多机共用一个进度文件，界面才能按机器分账
    entry = dict(entry or {})
    entry["machine"] = MACHINE
    entry["at"] = time.strftime("%Y-%m-%d %H:%M:%S")
    with state_lock():
        st = load_state()
        st.setdefault("files", {})[code] = entry
        save_state(st)
        release_claim(code)
    _done_marks.append(time.time())


def _partial_years(code: str) -> dict:
    """取本机已成功传过的分段落账，中断后接着传，不重复上传。"""
    try:
        st = load_state()
    except Exception:
        return {}
    p = st.get("partial")
    if not isinstance(p, dict):
        return {}
    v = p.get(code)
    if not isinstance(v, dict) or v.get("machine") != MACHINE:
        return {}
    years = v.get("years")
    return dict(years) if isinstance(years, dict) else {}


def _save_partial(code: str, years: dict) -> None:
    """每传完一个包就落一次账（只写 partial 段，不计入 files 完成数）。"""
    try:
        with state_lock():
            st = load_state()
            partial = st.setdefault("partial", {})
            partial[code] = {
                "years": dict(years or {}),
                "machine": MACHINE,
                "at": time.strftime("%Y-%m-%d %H:%M:%S"),
            }
            save_state(st)
    except Exception as e:
        log(f"  partial save failed {code}: {e}")


def _drop_partial(code: str) -> None:
    try:
        with state_lock():
            st = load_state()
            partial = st.get("partial")
            if isinstance(partial, dict) and code in partial:
                partial.pop(code, None)
                save_state(st)
    except Exception:
        pass


def write_current_code(code: str | None) -> None:
    global _current_code
    _current_code = code
    LOCAL_DIR.mkdir(parents=True, exist_ok=True)
    try:
        if code:
            CURRENT_CODE_FILE.write_text(code, encoding="utf-8")
        elif CURRENT_CODE_FILE.is_file():
            CURRENT_CODE_FILE.write_text("", encoding="utf-8")
    except Exception:
        pass


def _trim_marks(now: float) -> None:
    horizon = now - 600.0
    while _done_marks and _done_marks[0] < horizon:
        _done_marks.pop(0)


def rate_per_min(window_sec: float = 600.0) -> float:
    """最近 window_sec 的完成速度（只/分）。观察窗口不足时按实际跨度算，不虚高。"""
    now = time.time()
    _trim_marks(now)
    kept = [t for t in _done_marks if t >= now - window_sec]
    if not kept:
        return 0.0
    span = min(window_sec, max(60.0, now - _session_start))
    return round(len(kept) / (span / 60.0), 2)


def write_status(done: int, total: int, current: str | None) -> None:
    global _last_status_at, _status_done, _status_total
    _status_done, _status_total = done, total
    _last_status_at = time.time()
    payload = {
        "done": done,
        "total": total,
        "current": current or "",
        "machine": MACHINE,
        "pid": os.getpid(),
        "rate_per_min": rate_per_min(),
        "session_done": len(_done_marks),
        "updated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "updated_epoch": round(time.time(), 3),
    }
    text = json.dumps(payload, ensure_ascii=False, indent=1)
    LOCAL_DIR.mkdir(parents=True, exist_ok=True)
    try:
        STATUS_JSON.write_text(text, encoding="utf-8")
    except Exception:
        pass
    # 再写一份到共享目录：别的电脑（和另一台 App）靠它看到「这一台」的进度与速率
    if SHARE_DIR is not None:
        try:
            status_dir = SHARE_DIR / "status"
            status_dir.mkdir(parents=True, exist_ok=True)
            (status_dir / f"{MACHINE}.json").write_text(text, encoding="utf-8")
        except Exception:
            pass


def _flag_paths(name: str) -> list[Path]:
    paths: list[Path] = []
    if JOB_DIR is not None:
        paths.append(JOB_DIR / name)
    paths.append(LOCAL_DIR / name)
    paths.append(DATA_ROOT / "state" / "local" / name)
    if SHARE_DIR is not None:
        paths.append(SHARE_DIR.parent / name)
        paths.append(SHARE_DIR / name)
    return paths


def pause_flag_exists() -> bool:
    return any(p.is_file() for p in _flag_paths("pause.flag"))


def stop_flag_exists() -> bool:
    return any(p.is_file() for p in _flag_paths("stop.flag"))


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
    with _opener().open(req, timeout=300) as resp:
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
    with _opener().open(req, timeout=300) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _zip_and_size(code: str, tag: str, files: list[Path]) -> tuple[Path, float]:
    zip_path = ZIP_DIR / f"{code}_{tag}_ticks.zip"
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for f in files:
            z.write(f, arcname=f.name)
    return zip_path, zip_path.stat().st_size / 1024 / 1024


def upload_chunk(code: str, tag: str, files: list[Path], depth: int = 0) -> dict:
    """上传一个包；超上限时把文件序列对半拆，递归到每包 <= MAX_ZIP_MB。

    实测本机代理只可靠支持 5MB 以内的单次上传（6MB 会被远端断开），
    所以不再按「年」二分并限制两层，而是按文件序列无限细分，保证每包都能过。
    """
    maybe_heartbeat(code)
    zip_path, mb = _zip_and_size(code, tag, files)
    if mb > MAX_ZIP_MB:
        zip_path.unlink(missing_ok=True)
        if len(files) <= 1:
            raise RuntimeError(f"chunk {code} {tag} too large {mb:.1f}MB")
        mid = len(files) // 2
        left, right = files[:mid], files[mid:]
        flat = {}
        for sub, name in (
            (left, f"{left[0].name[:8]}-{left[-1].name[:8]}"),
            (right, f"{right[0].name[:8]}-{right[-1].name[:8]}"),
        ):
            if not sub:
                continue
            r = upload_chunk(code, name, sub, depth + 1)
            if "__split__" in r:
                flat.update(r["__split__"])
            else:
                flat[name] = r
        return {"__split__": flat}
    time.sleep(1.0 / RATE)
    last_err = None
    for attempt in range(3):
        maybe_heartbeat(code)
        try:
            resp = send_doc(zip_path, f"#ticks {code} {tag} ({len(files)}d)")
            if resp.get("ok"):
                zip_path.unlink(missing_ok=True)
                return {
                    "file_id": resp["result"]["document"]["file_id"],
                    "message_id": resp["result"]["message_id"],
                    "days": len(files),
                    "zip_mb": round(mb, 1),
                    "from": files[0].name[:8],
                    "to": files[-1].name[:8],
                }
            last_err = resp
        except Exception as e:
            last_err = e
        time.sleep(2 + attempt * 2)
    zip_path.unlink(missing_ok=True)
    raise RuntimeError(f"upload reject: {last_err}")


def plan_chunks(by_year: dict[str, list[Path]], recent_years: set[str]) -> list[tuple[str, list[Path]]]:
    """近 3 年按年单独打包；更早年份每 8 年（或 ~120MB 原始）一包。"""
    chunks: list[tuple[str, list[Path]]] = []
    for y in sorted(by_year):
        if y in recent_years:
            chunks.append((y, by_year[y]))
    older = [y for y in sorted(by_year) if y not in recent_years]
    batch: list[str] = []
    batch_bytes = 0
    for y in older:
        sz = sum(f.stat().st_size for f in by_year[y])
        if batch and (len(batch) >= 8 or batch_bytes + sz > 120 * 1024 * 1024):
            chunks.append((f"{batch[0]}-{batch[-1]}", [f for yy in batch for f in by_year[yy]]))
            batch, batch_bytes = [], 0
        batch.append(y)
        batch_bytes += sz
    if batch:
        chunks.append((f"{batch[0]}-{batch[-1]}", [f for yy in batch for f in by_year[yy]]))
    return chunks


def fetch_stock(code: str) -> bool:
    """调用 Rust 导出器拉单只全历史到本机缓存。"""
    maybe_heartbeat(code)
    src = REPO / "a_Data" / ".tdx_protocol_cache" / code
    dst = CACHE_ROOT / ".tdx_protocol_cache" / code
    if src.is_dir() and not dst.is_dir():
        dst.parent.mkdir(parents=True, exist_ok=True)
        _run_hidden(["cmd", "/c", "move", str(src), str(dst)], capture_output=True)
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
    r = _run_hidden(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        log(f"  fetch fail {code}: {(r.stderr or r.stdout)[-300:]}")
        return False
    return True


def _clear_code_cache(code: str) -> None:
    d = CACHE_ROOT / ".tdx_protocol_cache" / code
    _run_hidden(["cmd", "/c", "rmdir", "/s", "/q", str(d)], capture_output=True)


def _live_claims() -> list[str]:
    CLAIMS_DIR.mkdir(parents=True, exist_ok=True)
    live = []
    for p in CLAIMS_DIR.glob("*.json"):
        meta = _read_claim(p)
        if _claim_alive(meta):
            live.append(p.stem)
        else:
            try:
                p.unlink()
            except OSError:
                pass
    return live


def try_publish_index(total_codes: int) -> None:
    """仅当全部完成且无活占用时发布一次；index_published.flag 防双发。"""
    with state_lock():
        if INDEX_PUBLISHED_FLAG.is_file():
            log("index already published (flag exists), skip")
            return
        st = load_state()
        done_n = len(st.get("files") or {})
        skipped_n = len(st.get("skipped") or {})
        live = _live_claims()
        # 只把真有 file_id 的年份放进索引；日志补种的股票只用来跳过，不写进索引
        publish_files = {}
        for code, meta in (st.get("files") or {}).items():
            years = (meta or {}).get("years") or {}
            kept = {k: v for k, v in years.items() if isinstance(v, dict) and v.get("file_id")}
            if kept:
                publish_files[code] = {**(meta or {}), "years": kept}
        if done_n + skipped_n < total_codes or live:
            log(f"index not ready: done={done_n} skipped={skipped_n}/{total_codes} live_claims={live}")
            return
        index = {
            "version": 3,
            "kind": "ticks_zip_hybrid",
            "count": len(publish_files),
            "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "files": publish_files,
        }
        INDEX.write_text(json.dumps(index, ensure_ascii=False, indent=1), encoding="utf-8")
        published_ok = True
        if os.environ.get("TICKS_SKIP_INDEX_PUBLISH") == "1":
            log("index publish skipped by TICKS_SKIP_INDEX_PUBLISH")
        else:
            try:
                import publish_ticks_index as pub

                pub.STATE_DIR = STATE_DIR
                pub.INDEX = STATE_DIR / "ticks_index.json"
                pub.HINT = STATE_DIR / "ticks_index_hint.json"
                pub.TOKEN = TOKEN
                pub.CHAT_ID = CHAT_ID
                pub.PROXY = PROXY
                if SETTINGS_PATH:
                    pub.APP_SETTINGS = SETTINGS_PATH
                rc = pub.main()
                if rc not in (0, None):
                    published_ok = False
                    log(f"index publish rc={rc}, flag not written")
            except Exception as e:
                published_ok = False
                log(f"index publish fail: {e}")
        if not published_ok:
            return
        INDEX_PUBLISHED_FLAG.write_text(
            json.dumps(
                {"at": time.strftime("%Y-%m-%d %H:%M:%S"), "machine": MACHINE, "count": done_n},
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        log(f"index published flag written, count={done_n}")


def load_codes() -> list[str]:
    codes: list[str] = []
    with SUMMARY.open(encoding="utf-8") as f:
        next(f)
        for line in f:
            p = line.split(",")
            if len(p) >= 3 and len(p[0]) == 6:
                codes.append(p[0])
    return codes


def process_one(code: str) -> bool:
    """下载/打包/上传一只；成功 True。失败释放 claim 并清缓存。"""
    global _last_heartbeat
    t0 = time.time()
    heartbeat(code)
    _last_heartbeat = time.time()
    write_current_code(code)
    if not fetch_stock(code):
        release_claim(code)
        _clear_code_cache(code)
        write_current_code(None)
        return False
    d = CACHE_ROOT / ".tdx_protocol_cache" / code
    files = sorted(d.glob("*.txt")) if d.is_dir() else []
    if not files:
        log(f"  {code} no files")
        skip_no_files(code)
        _clear_code_cache(code)
        write_current_code(None)
        return False
    by_year: dict[str, list[Path]] = {}
    for f in files:
        by_year.setdefault(f.name[:4], []).append(f)
    now_year = time.localtime().tm_year
    recent = {str(y) for y in range(now_year - 2, now_year + 1)}
    chunks = plan_chunks(by_year, recent)
    entry: dict = {"years": _partial_years(code)}
    ok = True
    for tag, chunk_files in chunks:
        if tag in entry["years"]:
            log(f"  resume {code} {tag}: already uploaded, skip")
            continue
        if stop_flag_exists():
            ok = False
            log(f"  stop.flag seen, abort {code}")
            break
        try:
            maybe_heartbeat(code)
            r = upload_chunk(code, tag, chunk_files)
            if "__split__" in r:
                for sub_tag, sub in r["__split__"].items():
                    entry["years"][sub_tag] = sub
            else:
                entry["years"][tag] = r
            _save_partial(code, entry["years"])
        except Exception as e:
            ok = False
            log(f"  fail {code} {tag}: {e}")
            break
    if ok:
        complete_code(code, entry)
        _drop_partial(code)
        _clear_code_cache(code)
        log(f"  {code} done {len(files)}d in {time.time()-t0:.0f}s (uploaded {len(entry['years'])} packs)")
        write_current_code(None)
        return True
    release_claim(code)
    _clear_code_cache(code)
    log(f"  {code} failed {len(entry['years'])} packs, cache cleared, will retry")
    write_current_code(None)
    return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="ticks stream pipeline (shared claim)")
    parser.add_argument("--job", default="", help="path to job.json")
    args = parser.parse_args(argv)

    configure(job_path=args.job or None)

    if not TOKEN or not CHAT_ID:
        log("missing bot_token / chat_id (settings or TG_BOT_TOKEN/TG_CHAT_ID)")
        return 2

    for p in (CACHE_ROOT, OUT_DIR, ZIP_DIR, STATE_DIR, CLAIMS_DIR, LOCAL_DIR):
        p.mkdir(parents=True, exist_ok=True)

    codes = load_codes()
    limit = int(os.environ.get("PIPE_LIMIT", "0") or 0)
    claimed = 0
    log(
        f"machine={MACHINE} share={STATE_DIR} dataRoot={DATA_ROOT} "
        f"total={len(codes)} limit={limit or 'none'}"
    )

    while True:
        if stop_flag_exists():
            log("stop.flag present -> exit")
            write_current_code(None)
            return 0
        if pause_flag_exists():
            write_status(len(load_state().get("files") or {}), len(codes), None)
            time.sleep(3)
            continue

        free_gb = shutil.disk_usage(CACHE_ROOT).free / (1024 ** 3)
        if free_gb < 5:
            log(f"disk low on {CACHE_ROOT}: {free_gb:.1f}GB free -> stop")
            break

        if limit > 0 and claimed >= limit:
            log(f"PIPE_LIMIT={limit} reached")
            break

        st = load_state()
        done_n = len(st.get("files") or {})
        write_status(done_n, len(codes), None)

        code = claim_next(codes)
        if not code:
            log(f"no more codes to claim (done={done_n}/{len(codes)})")
            try_publish_index(len(codes))
            break

        claimed += 1
        log(f"[claim #{claimed}] {code} (done {done_n}/{len(codes)})")
        write_status(done_n, len(codes), code)
        process_one(code)

    write_current_code(None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
