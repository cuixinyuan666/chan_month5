import copy
import json
from pathlib import Path
from threading import RLock
from typing import Any


RUNTIME_PREFS_PATH = Path(__file__).resolve().parent / "a_runtime_prefs.json"
RUNTIME_PREFS_LOCK = RLock()
DEFAULT_RUNTIME_PREFS = {
    "source_priority": [],
    "shared_settings": {},
}


def load_runtime_prefs() -> dict[str, Any]:
    with RUNTIME_PREFS_LOCK:
        if not RUNTIME_PREFS_PATH.exists():
            return copy.deepcopy(DEFAULT_RUNTIME_PREFS)
        try:
            data = json.loads(RUNTIME_PREFS_PATH.read_text(encoding="utf-8"))
        except Exception:
            return copy.deepcopy(DEFAULT_RUNTIME_PREFS)
        merged = copy.deepcopy(DEFAULT_RUNTIME_PREFS)
        if isinstance(data, dict):
            merged.update(data)
        return merged


def save_runtime_prefs(data: dict[str, Any]) -> dict[str, Any]:
    normalized = copy.deepcopy(DEFAULT_RUNTIME_PREFS)
    if isinstance(data, dict):
        normalized.update(data)
    with RUNTIME_PREFS_LOCK:
        RUNTIME_PREFS_PATH.write_text(
            json.dumps(normalized, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    return copy.deepcopy(normalized)


def read_runtime_pref(key: str, fallback: Any = None) -> Any:
    data = load_runtime_prefs()
    if key not in data:
        return copy.deepcopy(fallback)
    return copy.deepcopy(data[key])


def write_runtime_pref(key: str, value: Any) -> dict[str, Any]:
    data = load_runtime_prefs()
    data[key] = copy.deepcopy(value)
    return save_runtime_prefs(data)
