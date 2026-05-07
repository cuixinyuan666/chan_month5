from typing import Any


def trade_events_same_bar_flip(events: list[dict[str, Any]], prev_side: str, cur_side: str) -> bool:
    """判断是否同一 step、同一 K 线 x 上连续两笔（如平多→做空、平空→做多）。"""
    if len(events) < 2:
        return False
    a, b = events[-2], events[-1]
    if str(a.get("side")) != prev_side or str(b.get("side")) != cur_side:
        return False
    if int(a.get("step_idx", -10_000_000)) != int(b.get("step_idx", -9_000_000)):
        return False
    return a.get("x") == b.get("x")


def msg_buy(detail: dict[str, Any]) -> str:
    if detail.get("noop"):
        return str(detail.get("message") or "无操作")
    sh = int(detail.get("shares", 0))
    return f"开多成功：{sh} 股，耗资 {detail.get('cost')} 元。"


def msg_sell(detail: dict[str, Any]) -> str:
    if detail.get("noop"):
        return str(detail.get("message") or "无操作")
    sh = int(detail.get("shares", 0))
    return f"平多成功：{sh} 股，回笼 {detail.get('proceeds')} 元，盈亏 {detail.get('pnl')} 元。"


def msg_short(detail: dict[str, Any]) -> str:
    sh = int(detail.get("shares", 0))
    return f"开空成功：{sh} 股，名义占用约 {detail.get('proceeds')} 元。"


def msg_cover(detail: dict[str, Any]) -> str:
    if detail.get("noop"):
        return str(detail.get("message") or "无操作")
    sh = int(detail.get("shares", 0))
    return f"平空成功：{sh} 股，支出 {detail.get('cost')} 元，盈亏 {detail.get('pnl')} 元。"

