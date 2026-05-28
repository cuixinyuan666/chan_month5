# -*- coding: utf-8 -*-
# Offline benchmark for session init (no HTTP server).

from __future__ import annotations

import argparse
import os
import sys
import time

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

os.environ.setdefault("INIT_PERF", "1")


def _print_perf(label: str, perf: dict) -> None:
    print(f"\n=== {label} ===")
    print(f"total_ms: {perf.get('total_ms')}")
    for row in perf.get("rank") or []:
        print(f"  {row.get('stage')}: {row.get('ms')} ms ({row.get('pct')}%)")


def main() -> None:
    parser = argparse.ArgumentParser(description="bench init session path")
    parser.add_argument("--code", default="sh.688687")
    parser.add_argument("--begin", default="2021-04-01")
    parser.add_argument("--end", default="2021-04-10")
    parser.add_argument("--k-type", default="daily", dest="k_type")
    parser.add_argument("--confirm-offline", action="store_true", default=True)
    parser.add_argument("--chan-record", action="store_true", help="enable chan record")
    parser.add_argument("--rounds", type=int, default=2)
    args = parser.parse_args()

    from a_replay_core.a_init_perf import init_perf_report, init_perf_run
    from a_replay_core.a_replay_api_models import InitReq
    from a_replay_trainer import (
        APP_STATE,
        ChanStepper,
        DEFAULT_DATA_SOURCE_PRIORITY_NAMES,
        _api_init_impl,
        apply_data_source_priority,
    )

    prio = list(DEFAULT_DATA_SOURCE_PRIORITY_NAMES)
    apply_data_source_priority(prio)

    req = InitReq(
        code=args.code,
        begin_date=args.begin,
        end_date=args.end,
        initial_cash=1_000_000.0,
        autype="qfq",
        chan_config={},
        k_type=args.k_type,
        chart_mode="single",
        confirm_offline=bool(args.confirm_offline),
        data_source_priority=prio,
        data_form_mode="traditional",
        data_feed_mode="step",
        chan_record_enabled=bool(args.chan_record),
    )

    print(
        f"code={args.code} range={args.begin}~{args.end} k_type={args.k_type} record={args.chan_record}"
    )

    for i in range(max(1, int(args.rounds))):
        APP_STATE.ready = False
        APP_STATE.stepper = ChanStepper()
        APP_STATE.stepper2 = None
        APP_STATE.multi_steppers = []
        t0 = time.perf_counter()
        with init_perf_run(f"round_{i + 1}"):
            payload = _api_init_impl(req, {})
        wall_ms = (time.perf_counter() - t0) * 1000.0
        perf = payload.get("init_perf") or init_perf_report()
        _print_perf(f"round {i + 1} (wall {wall_ms:.1f} ms)", perf)
        kline = (payload.get("chart") or {}).get("kline") or []
        print(f"ready={payload.get('ready')} chart_bars={len(kline)} chip_lazy={payload.get('chip_kline_all_lazy')}")


if __name__ == "__main__":
    main()
