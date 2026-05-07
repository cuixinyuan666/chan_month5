from typing import Any


def kline_view_rows_filtered(bars: list[dict[str, Any]], view: str) -> list[dict[str, Any]]:
    v = str(view or "kline").strip().lower()
    if v in ("kline", "ohlc", "k", "k线"):
        out: list[dict[str, Any]] = []
        for b in bars:
            out.append(
                {
                    "x": b.get("x"),
                    "t": b.get("t"),
                    "o": b.get("o"),
                    "h": b.get("h"),
                    "l": b.get("l"),
                    "c": b.get("c"),
                }
            )
        return out
    if v in ("volume_chip", "vol", "chip", "成交量", "筹码"):
        out2: list[dict[str, Any]] = []
        for b in bars:
            row: dict[str, Any] = {"x": b.get("x"), "t": b.get("t"), "v": b.get("v")}
            if "chip_tick_bins" in b:
                row["chip_tick_bins"] = b.get("chip_tick_bins")
            out2.append(row)
        return out2
    if v in ("all", "full", "全部", "raw"):
        return [dict(b) for b in bars]
    raise ValueError("view 须为 kline、volume_chip 或 all")

