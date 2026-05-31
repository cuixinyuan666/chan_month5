from __future__ import annotations

import hashlib
import json
import math
import shutil
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


PAYLOAD_VERSION = 2
RUST_MODULE_NAME = "a_rust_core_ext"


def _default_cache_dir() -> Path:
    return Path(__file__).resolve().parents[1] / "a_replay_cache" / "a_perf_engine_cache"


def _load_rust_backend():
    try:
        return __import__(RUST_MODULE_NAME)
    except Exception:
        return None


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        v = float(value)
    except Exception:
        return default
    if not math.isfinite(v):
        return default
    return v


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except Exception:
        return default


def _parse_time_ms(text: Any) -> int:
    s = str(text or "").strip()
    if not s:
        return 0
    for fmt in (
        "%Y/%m/%d %H:%M:%S",
        "%Y/%m/%d %H:%M",
        "%Y/%m/%d",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d",
    ):
        try:
            dt = datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
            return int(dt.timestamp() * 1000)
        except Exception:
            continue
    return 0


def _series_fingerprint(meta: dict[str, Any], bars: list[dict[str, Any]], chip_bars: list[dict[str, Any]]) -> str:
    h = hashlib.blake2b(digest_size=16)
    h.update(json.dumps(meta, ensure_ascii=False, sort_keys=True, default=str).encode("utf-8"))
    for src in (bars, chip_bars):
        h.update(str(len(src)).encode("ascii"))
        for item in (src[:2] + src[-2:] if len(src) > 4 else src):
            keep = {
                "x": item.get("x"),
                "t": item.get("t"),
                "o": item.get("o"),
                "h": item.get("h"),
                "l": item.get("l"),
                "c": item.get("c"),
                "v": item.get("v"),
            }
            h.update(json.dumps(keep, ensure_ascii=False, sort_keys=True, default=str).encode("utf-8"))
    return h.hexdigest()


def normalize_bars(bars: list[dict[str, Any]]) -> dict[str, list[Any]]:
    """把 dict K线转成列式数组；Rust/安卓后续共用这个形状。"""
    out: dict[str, list[Any]] = {
        "x": [],
        "t": [],
        "time_ms": [],
        "open": [],
        "high": [],
        "low": [],
        "close": [],
        "volume": [],
    }
    for idx, bar in enumerate(bars or []):
        t = str(bar.get("t", ""))
        out["x"].append(_safe_int(bar.get("x"), idx))
        out["t"].append(t)
        out["time_ms"].append(_parse_time_ms(t))
        out["open"].append(_safe_float(bar.get("o", bar.get("open"))))
        out["high"].append(_safe_float(bar.get("h", bar.get("high"))))
        out["low"].append(_safe_float(bar.get("l", bar.get("low"))))
        out["close"].append(_safe_float(bar.get("c", bar.get("close"))))
        out["volume"].append(_safe_float(bar.get("v", bar.get("volume"))))
    return out


@dataclass(frozen=True)
class PerfSession:
    session_id: str
    payload_version: int
    engine_mode: str
    bar_count: int
    chip_bar_count: int
    cache_file: str


class PerfEngine:
    """高性能过渡引擎门面。

    Rust 扩展可用时优先走 Rust；不可用时使用严格等价的 Python fallback。
    """

    def __init__(self, cache_dir: Optional[str | Path] = None, requested_mode: str = "rust_auto") -> None:
        self.cache_dir = Path(cache_dir) if cache_dir is not None else _default_cache_dir()
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.requested_mode = str(requested_mode or "rust_auto")
        self._rust = _load_rust_backend()
        self._sessions: dict[str, dict[str, Any]] = {}

    @property
    def rust_available(self) -> bool:
        return self._rust is not None

    def _engine_mode(self) -> str:
        if self.requested_mode == "python_legacy":
            return "python-legacy"
        if self.rust_available:
            return "rust"
        return "python-fallback"

    def _cache_path(self, session_id: str) -> Path:
        safe = "".join(ch if ch.isalnum() else "_" for ch in session_id)
        return self.cache_dir / f"{safe}.json"

    def load_session(
        self,
        *,
        code: str,
        k_type: str,
        begin_date: str,
        end_date: Optional[str],
        bars: list[dict[str, Any]],
        chip_bars: Optional[list[dict[str, Any]]] = None,
    ) -> PerfSession:
        chip_src = list(chip_bars or bars or [])
        bar_src = list(bars or [])
        meta = {
            "code": str(code),
            "k_type": str(k_type),
            "begin": str(begin_date),
            "end": str(end_date or ""),
            "payload_version": PAYLOAD_VERSION,
        }
        session_id = _series_fingerprint(meta, bar_src, chip_src)
        cache_path = self._cache_path(session_id)
        series = normalize_bars(bar_src)
        chip_series = normalize_bars(chip_src)
        payload = {
            "meta": meta,
            "series": series,
            "chip_series": chip_series,
            # 原始 chip_tick_bins 只在服务端缓存，前端拿 profile，不再扫全历史。
            "chip_bars": chip_src,
        }
        self._sessions[session_id] = payload
        if not cache_path.exists():
            cache_path.write_text(
                json.dumps(
                    {
                        "meta": meta,
                        "bar_count": len(bar_src),
                        "chip_bar_count": len(chip_src),
                        "first_t": bar_src[0].get("t") if bar_src else "",
                        "last_t": bar_src[-1].get("t") if bar_src else "",
                    },
                    ensure_ascii=False,
                    separators=(",", ":"),
                ),
                encoding="utf-8",
            )
        return PerfSession(
            session_id=session_id,
            payload_version=PAYLOAD_VERSION,
            engine_mode=self._engine_mode(),
            bar_count=len(bar_src),
            chip_bar_count=len(chip_src),
            cache_file=str(cache_path),
        )

    def _get_session(self, session_id: str) -> dict[str, Any]:
        try:
            return self._sessions[str(session_id)]
        except KeyError as exc:
            raise KeyError(f"性能引擎会话不存在: {session_id}") from exc

    def step_to(self, session_id: str, target_step: int) -> dict[str, Any]:
        return self.next_step_delta(session_id, target_step - 1, target_step)

    def next_step_delta(self, session_id: str, from_step: int, to_step: int) -> dict[str, Any]:
        sess = self._get_session(session_id)
        series = sess["series"]
        total = len(series["x"])
        if total <= 0:
            return {"from_step": from_step, "to_step": -1, "append_kline": [], "tail_patch": None, "structure_dirty": False}
        target = max(0, min(_safe_int(to_step), total - 1))
        start = max(0, min(_safe_int(from_step) + 1, target))
        append = []
        for i in range(start, target + 1):
            append.append(
                {
                    "x": series["x"][i],
                    "t": series["t"][i],
                    "o": series["open"][i],
                    "h": series["high"][i],
                    "l": series["low"][i],
                    "c": series["close"][i],
                    "v": series["volume"][i],
                }
            )
        return {
            "from_step": _safe_int(from_step),
            "to_step": target,
            "append_kline": append,
            "tail_patch": append[-1] if append else None,
            "structure_dirty": True,
        }

    def chip_profile(self, session_id: str, *, cutoff_x: Optional[int] = None, bucket_step: float = 0.1) -> dict[str, Any]:
        sess = self._get_session(session_id)
        chip_bars = sess.get("chip_bars") or []
        if not chip_bars:
            return self._empty_chip_profile(session_id, cutoff_x, bucket_step)
        step = max(0.001, _safe_float(bucket_step, 0.1))
        cut = cutoff_x
        if cut is not None:
            use_bars = [b for b in chip_bars if _safe_int(b.get("x"), -1) <= int(cut)]
        else:
            use_bars = list(chip_bars)
            cut = _safe_int(use_bars[-1].get("x"), len(use_bars) - 1) if use_bars else -1
        profile_id = f"{session_id}:{cut}:{step:g}"
        profile_path = self.cache_dir / f"chip_{profile_id.replace(':', '_').replace('.', 'p')}.json"
        if profile_path.exists():
            try:
                return json.loads(profile_path.read_text(encoding="utf-8"))
            except Exception:
                pass

        buckets_s: dict[int, float] = {}
        buckets_b: dict[int, float] = {}
        for bar in use_bars:
            tick_bins = bar.get("chip_tick_bins")
            if isinstance(tick_bins, dict) and isinstance(tick_bins.get("p"), list):
                prices = tick_bins.get("p") or []
                s_vals = tick_bins.get("s") if isinstance(tick_bins.get("s"), list) else None
                b_vals = tick_bins.get("b") if isinstance(tick_bins.get("b"), list) else None
                w_vals = tick_bins.get("w") if isinstance(tick_bins.get("w"), list) else None
                for idx, price_raw in enumerate(prices):
                    p = _safe_float(price_raw, math.nan)
                    if not math.isfinite(p):
                        continue
                    key = math.floor(p / step)
                    sv = _safe_float(s_vals[idx], 0.0) if s_vals and idx < len(s_vals) else 0.0
                    bv = _safe_float(b_vals[idx], 0.0) if b_vals and idx < len(b_vals) else 0.0
                    if not b_vals and w_vals and idx < len(w_vals):
                        bv = _safe_float(w_vals[idx], 0.0)
                    if sv > 0:
                        buckets_s[key] = buckets_s.get(key, 0.0) + sv
                    if bv > 0:
                        buckets_b[key] = buckets_b.get(key, 0.0) + bv
                continue
            self._accumulate_ohlc_triangle(bar, step, buckets_b)

        keys = sorted(set(buckets_s) | set(buckets_b))
        prices = [round(k * step, 6) for k in keys]
        s_arr = [buckets_s.get(k, 0.0) for k in keys]
        b_arr = [buckets_b.get(k, 0.0) for k in keys]
        total = [s_arr[i] + b_arr[i] for i in range(len(keys))]
        out = {
            "profile_id": profile_id,
            "cutoff_x": cut,
            "bucket_step": step,
            "prices": prices,
            "s": s_arr,
            "b": b_arr,
            "total": total,
            "max_total": max(total) if total else 0.0,
            "source": "rust" if self.rust_available else "python-fallback",
        }
        try:
            profile_path.write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
        except Exception:
            pass
        return out

    @staticmethod
    def _accumulate_ohlc_triangle(bar: dict[str, Any], step: float, buckets_b: dict[int, float]) -> None:
        low = min(_safe_float(bar.get("l", bar.get("low"))), _safe_float(bar.get("h", bar.get("high"))))
        high = max(_safe_float(bar.get("l", bar.get("low"))), _safe_float(bar.get("h", bar.get("high"))))
        close = _safe_float(bar.get("c", bar.get("close")), low)
        mode = min(high, max(low, close))
        vol = max(0.0, _safe_float(bar.get("v", bar.get("volume")), 0.0))
        if high < low or vol <= 0:
            return
        i0 = math.floor(low / step)
        i1 = math.ceil(high / step)
        if i1 < i0:
            return
        if abs(high - low) < 1e-12:
            buckets_b[i0] = buckets_b.get(i0, 0.0) + vol
            return
        weights = []
        total_w = 0.0
        for key in range(i0, i1 + 1):
            p = key * step
            if abs(mode - low) < 1e-12:
                w = (high - p) / max(1e-12, high - low)
            elif abs(high - mode) < 1e-12:
                w = (p - low) / max(1e-12, high - low)
            elif p <= mode:
                w = (p - low) / max(1e-12, mode - low)
            else:
                w = (high - p) / max(1e-12, high - mode)
            w = max(0.0, w)
            weights.append((key, w))
            total_w += w
        if total_w <= 1e-12:
            return
        for key, w in weights:
            if w > 0:
                buckets_b[key] = buckets_b.get(key, 0.0) + (w / total_w) * vol

    @staticmethod
    def _empty_chip_profile(session_id: str, cutoff_x: Optional[int], bucket_step: float) -> dict[str, Any]:
        return {
            "profile_id": f"{session_id}:{cutoff_x if cutoff_x is not None else -1}:{bucket_step:g}",
            "cutoff_x": cutoff_x,
            "bucket_step": bucket_step,
            "prices": [],
            "s": [],
            "b": [],
            "total": [],
            "max_total": 0.0,
            "source": "empty",
        }

    def cache_status(self) -> dict[str, Any]:
        files = list(self.cache_dir.glob("*.json")) if self.cache_dir.exists() else []
        total_bytes = sum(p.stat().st_size for p in files if p.exists())
        return {
            "cache_dir": str(self.cache_dir),
            "file_count": len(files),
            "total_bytes": total_bytes,
            "rust_available": self.rust_available,
            "requested_mode": self.requested_mode,
            "engine_mode": self._engine_mode(),
            "payload_version": PAYLOAD_VERSION,
        }

    def clear_cache(self) -> dict[str, Any]:
        base = _default_cache_dir().resolve()
        target = self.cache_dir.resolve()
        if target != base and base not in target.parents:
            raise ValueError(f"拒绝清理非性能缓存目录: {target}")
        removed = 0
        if target.exists():
            for item in target.glob("*.json"):
                try:
                    item.unlink()
                    removed += 1
                except Exception:
                    pass
            for item in target.iterdir():
                if item.is_dir():
                    shutil.rmtree(item, ignore_errors=True)
        self._sessions.clear()
        return {"removed": removed, **self.cache_status()}


_GLOBAL_ENGINE = PerfEngine()


def load_session(**kwargs: Any) -> PerfSession:
    return _GLOBAL_ENGINE.load_session(**kwargs)


def step_to(session_id: str, target_step: int) -> dict[str, Any]:
    return _GLOBAL_ENGINE.step_to(session_id, target_step)


def next_step_delta(session_id: str, from_step: int, to_step: int) -> dict[str, Any]:
    return _GLOBAL_ENGINE.next_step_delta(session_id, from_step, to_step)


def chip_profile(session_id: str, *, cutoff_x: Optional[int] = None, bucket_step: float = 0.1) -> dict[str, Any]:
    return _GLOBAL_ENGINE.chip_profile(session_id, cutoff_x=cutoff_x, bucket_step=bucket_step)


def cache_status() -> dict[str, Any]:
    return _GLOBAL_ENGINE.cache_status()


def clear_cache() -> dict[str, Any]:
    return _GLOBAL_ENGINE.clear_cache()
