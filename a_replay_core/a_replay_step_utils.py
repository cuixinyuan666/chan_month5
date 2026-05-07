from typing import Any, Callable


def serialize_klu_unit_fast(klu: Any, volume_getter: Callable[[Any], float]) -> dict[str, Any]:
    """单根 K 线快速序列化：用于步进时增量追加，避免全量重扫。"""
    return {
        "x": klu.idx,
        "t": klu.time.to_str(),
        "o": float(klu.open),
        "h": float(klu.high),
        "l": float(klu.low),
        "c": float(klu.close),
        "v": float(volume_getter(klu)),
    }

