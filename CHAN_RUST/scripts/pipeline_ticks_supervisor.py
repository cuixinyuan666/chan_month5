#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全市场分笔上传监视器：单实例、托盘、拉起 pipeline_stream_ticks.py 并在退出后按计划重启。"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)

SCRIPTS_DIR = Path(__file__).resolve().parent
WORKER = SCRIPTS_DIR / "pipeline_stream_ticks.py"


def _load_job(job_path: Path) -> dict:
    return json.loads(job_path.read_text(encoding="utf-8-sig"))


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False
    except Exception:
        # Windows: os.kill may work; fallback tasklist
        try:
            r = subprocess.run(
                ["tasklist", "/FI", f"PID eq {pid}"],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                creationflags=_NO_WINDOW,
            )
            return str(pid) in (r.stdout or "")
        except Exception:
            return False


def _lock_path(job: dict, job_path: Path) -> Path:
    data_root = Path(job.get("dataRoot") or job.get("data_root") or r"G:\chan_month5_data")
    local = data_root / "local"
    local.mkdir(parents=True, exist_ok=True)
    # 优先 dataRoot/local；job 旁也写一份便于排查
    return local / "supervisor.lock"


def _acquire_single_instance(lock: Path) -> bool:
    if lock.is_file():
        try:
            meta = json.loads(lock.read_text(encoding="utf-8"))
            pid = int(meta.get("pid") or 0)
            if _pid_alive(pid):
                print("already running", flush=True)
                return False
        except Exception:
            pass
        try:
            lock.unlink()
        except OSError:
            pass
    lock.write_text(
        json.dumps({"pid": os.getpid(), "started_at": time.time()}, ensure_ascii=False),
        encoding="utf-8",
    )
    return True


def _flag_paths(job: dict, job_path: Path, name: str) -> list[Path]:
    data_root = Path(job.get("dataRoot") or job.get("data_root") or r"G:\chan_month5_data")
    share = Path(job.get("shareDir") or job.get("share_dir") or "")
    paths = [
        job_path.parent / name,
        data_root / "local" / name,
        data_root / "state" / "local" / name,
    ]
    if str(share):
        paths.append(share.parent / name)
        paths.append(share / name)
    return paths


def _any_flag(job: dict, job_path: Path, name: str) -> bool:
    return any(p.is_file() for p in _flag_paths(job, job_path, name))


def _write_flag(job: dict, job_path: Path, name: str) -> None:
    # 本机 pause/stop：写在 job 旁 + dataRoot/local
    data_root = Path(job.get("dataRoot") or job.get("data_root") or r"G:\chan_month5_data")
    for p in (job_path.parent / name, data_root / "local" / name):
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("1", encoding="utf-8")


def _clear_flag(job: dict, job_path: Path, name: str) -> None:
    for p in _flag_paths(job, job_path, name):
        try:
            p.unlink(missing_ok=True)
        except OSError:
            pass


def _read_done(job: dict) -> str:
    share = Path(job.get("shareDir") or job.get("share_dir") or "")
    if not share:
        data_root = Path(job.get("dataRoot") or job.get("data_root") or r"G:\chan_month5_data")
        share = data_root / "state" / "ticks"
    state = share / "ticks_stream_state.json"
    try:
        st = json.loads(state.read_text(encoding="utf-8"))
        return str(len(st.get("files") or {}))
    except Exception:
        return "?"


def _read_current(job: dict) -> str:
    data_root = Path(job.get("dataRoot") or job.get("data_root") or r"G:\chan_month5_data")
    p = data_root / "local" / "current_code.txt"
    try:
        return (p.read_text(encoding="utf-8") or "").strip() or "-"
    except Exception:
        return "-"


def _log_path(job: dict) -> Path:
    data_root = Path(job.get("dataRoot") or job.get("data_root") or r"G:\chan_month5_data")
    return data_root / "pipeline_stream.log"


def _supervisor_log(job: dict) -> Path:
    data_root = Path(job.get("dataRoot") or job.get("data_root") or r"G:\chan_month5_data")
    p = data_root / "local" / "supervisor.log"
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def _append_log(path: Path, line: str) -> None:
    try:
        with path.open("a", encoding="utf-8") as f:
            f.write(line)
            if not line.endswith("\n"):
                f.write("\n")
    except Exception:
        pass


class Supervisor:
    def __init__(self, job_path: Path, job: dict):
        self.job_path = job_path
        self.job = job
        self.proc: subprocess.Popen | None = None
        self.stop_requested = False
        self.machine = (
            job.get("machineName")
            or job.get("machine")
            or os.environ.get("COMPUTERNAME")
            or "pc"
        )
        self.slog = _supervisor_log(job)
        self._icon = None

    def start_worker(self) -> None:
        if self.proc and self.proc.poll() is None:
            return
        cmd = [sys.executable, str(WORKER), "--job", str(self.job_path)]
        self._append(f"start worker: {' '.join(cmd)}")
        self.proc = subprocess.Popen(
            cmd,
            cwd=str(SCRIPTS_DIR),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            creationflags=_NO_WINDOW,
        )
        threading.Thread(target=self._pump_stdout, daemon=True).start()

    def _append(self, msg: str) -> None:
        line = f"[{time.strftime('%H:%M:%S')}] {msg}"
        print(line, flush=True)
        _append_log(self.slog, line)

    def _pump_stdout(self) -> None:
        p = self.proc
        if not p or not p.stdout:
            return
        log = _log_path(self.job)
        try:
            for line in p.stdout:
                _append_log(log, line.rstrip("\n"))
                _append_log(self.slog, line.rstrip("\n"))
        except Exception:
            pass

    def kill_worker(self) -> None:
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate()
            except Exception:
                pass
            try:
                self.proc.wait(timeout=5)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
        self.proc = None

    def tray_title(self) -> str:
        done = _read_done(self.job)
        cur = _read_current(self.job)
        return f"{self.machine} done={done} cur={cur}"

    def on_pause(self, *_a) -> None:
        _write_flag(self.job, self.job_path, "pause.flag")
        self._append("pause.flag written")

    def on_resume(self, *_a) -> None:
        _clear_flag(self.job, self.job_path, "pause.flag")
        self._append("pause.flag cleared")

    def on_open_log(self, *_a) -> None:
        log = _log_path(self.job)
        log.parent.mkdir(parents=True, exist_ok=True)
        if not log.is_file():
            log.write_text("", encoding="utf-8")
        try:
            os.startfile(str(log))  # type: ignore[attr-defined]
        except Exception as e:
            self._append(f"open log fail: {e}")

    def on_quit(self, icon=None, *_a) -> None:
        self.stop_requested = True
        _write_flag(self.job, self.job_path, "stop.flag")
        self.kill_worker()
        self._append("stop requested")
        if icon is not None:
            try:
                icon.stop()
            except Exception:
                pass

    def run_loop(self) -> None:
        """无托盘时：forever 拉起 worker。"""
        while not self.stop_requested and not _any_flag(self.job, self.job_path, "stop.flag"):
            self.start_worker()
            assert self.proc is not None
            code = self.proc.wait()
            self._append(f"worker exit {code}")
            self.proc = None
            if self.stop_requested or _any_flag(self.job, self.job_path, "stop.flag"):
                break
            time.sleep(5)
        self.kill_worker()

    def run_with_tray(self) -> bool:
        try:
            import pystray
            from PIL import Image, ImageDraw
        except Exception as e:
            self._append(f"tray unavailable ({e}), headless mode")
            return False

        img = Image.new("RGB", (64, 64), color=(30, 90, 160))
        d = ImageDraw.Draw(img)
        d.ellipse((8, 8, 56, 56), fill=(240, 240, 240))
        d.text((22, 20), "T", fill=(30, 90, 160))

        menu = pystray.Menu(
            pystray.MenuItem(lambda i: self.tray_title(), lambda *_: None, enabled=False),
            pystray.MenuItem("暂停", self.on_pause),
            pystray.MenuItem("继续", self.on_resume),
            pystray.MenuItem("打开日志", self.on_open_log),
            pystray.MenuItem("结束本机任务", self.on_quit),
        )

        icon = pystray.Icon("ticks_full_upload", img, self.tray_title(), menu)
        self._icon = icon

        def worker_forever():
            self.run_loop()
            try:
                icon.stop()
            except Exception:
                pass

        def title_refresh():
            while not self.stop_requested:
                try:
                    icon.title = self.tray_title()
                except Exception:
                    pass
                time.sleep(5)

        threading.Thread(target=worker_forever, daemon=True).start()
        threading.Thread(target=title_refresh, daemon=True).start()
        icon.run()
        return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", required=True)
    args = parser.parse_args(argv)
    job_path = Path(args.job).resolve()
    if not job_path.is_file():
        print(json.dumps({"ok": False, "message": f"job not found: {job_path}"}))
        return 2
    job = _load_job(job_path)
    lock = _lock_path(job, job_path)
    if not _acquire_single_instance(lock):
        return 0

    # 启动前清 stop（否则立刻退出）；pause 保留
    _clear_flag(job, job_path, "stop.flag")

    sup = Supervisor(job_path, job)
    try:
        if not sup.run_with_tray():
            # 写 status 供 App 读
            data_root = Path(job.get("dataRoot") or r"G:\chan_month5_data")
            status = data_root / "local" / "supervisor_status.json"
            status.parent.mkdir(parents=True, exist_ok=True)
            status.write_text(
                json.dumps(
                    {
                        "mode": "headless",
                        "machine": sup.machine,
                        "pid": os.getpid(),
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            sup.run_loop()
    finally:
        try:
            lock.unlink(missing_ok=True)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
