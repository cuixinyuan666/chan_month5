# -*- coding: utf-8 -*-
"""Rust Chan parity CLI: golden session run and BSP hash output."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

GOLDEN_CODE = "sh.688687"
GOLDEN_BEGIN = "2021-04-01"
GOLDEN_END = "2021-04-10"
GOLDEN_K_TYPE = "daily"
GOLDEN_CACHE = os.path.join(_ROOT, "a_replay_cache", "rust_chan_golden.json")


def _run_presentation(code: str, begin: str, end: str, k_type: str) -> dict:
    from a_replay_core.a_init_perf import init_perf_run
    from a_replay_core.a_replay_api_models import InitReq
    from a_replay_core.a_rust_chan_parity import (
        bsp_history_hash,
        chart_bsp_hash,
        structure_step_hash,
        structure_step_signature,
    )
    from a_replay_trainer import (
        APP_STATE,
        ChanStepper,
        DEFAULT_DATA_SOURCE_PRIORITY_NAMES,
        _api_init_impl,
        apply_data_source_priority,
    )

    apply_data_source_priority(list(DEFAULT_DATA_SOURCE_PRIORITY_NAMES))
    APP_STATE.ready = False
    APP_STATE.stepper = ChanStepper()
    APP_STATE.stepper2 = None
    APP_STATE.multi_steppers = []

    req = InitReq(
        code=code,
        begin_date=begin,
        end_date=end,
        initial_cash=1_000_000.0,
        autype="qfq",
        chan_config={"chan_algo": "classic"},
        k_type=k_type,
        chart_mode="single",
        confirm_offline=True,
        data_source_priority=list(DEFAULT_DATA_SOURCE_PRIORITY_NAMES),
        data_form_mode="traditional",
        data_feed_mode="step",
        chan_record_enabled=False,
    )
    with init_perf_run("rust_chan_parity"):
        payload = _api_init_impl(req, {})
    APP_STATE.session_params = dict(APP_STATE.session_params or {})
    APP_STATE.session_params["kline_presentation_mode"] = "instant"
    APP_STATE.apply_kline_presentation_end()

    stepper = APP_STATE.stepper
    kl_list = stepper.chan[0]
    chart = stepper.build_chart_payload_cached(include_kline_all=False)
    return {
        "code": code,
        "begin": begin,
        "end": end,
        "k_type": k_type,
        "step_idx": int(stepper.step_idx),
        "step_count": int(stepper.step_idx) + 1,
        "final_step_hash": structure_step_hash(kl_list),
        "bsp_history_hash": bsp_history_hash(APP_STATE.bsp_history),
        "chart_bsp_hash": chart_bsp_hash(chart),
        "final_signature": structure_step_signature(kl_list),
        "init_perf": payload.get("init_perf"),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Rust Chan parity golden runner")
    parser.add_argument("--code", default=GOLDEN_CODE)
    parser.add_argument("--begin", default=GOLDEN_BEGIN)
    parser.add_argument("--end", default=GOLDEN_END)
    parser.add_argument("--k-type", default=GOLDEN_K_TYPE, dest="k_type")
    parser.add_argument("--write-golden", action="store_true")
    parser.add_argument("--compare", action="store_true")
    args = parser.parse_args()

    t0 = time.perf_counter()
    result = _run_presentation(args.code, args.begin, args.end, args.k_type)
    wall_s = time.perf_counter() - t0

    print(f"wall={wall_s:.2f}s step_idx={result['step_idx']}")
    print(f"bsp_history_hash={result['bsp_history_hash']}")
    print(f"chart_bsp_hash={result['chart_bsp_hash']}")
    print(f"final_step_hash={result['final_step_hash']}")

    if args.write_golden:
        os.makedirs(os.path.dirname(GOLDEN_CACHE), exist_ok=True)
        with open(GOLDEN_CACHE, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, indent=2, default=str)
        print(f"golden written: {GOLDEN_CACHE}")

    if args.compare:
        if not os.path.isfile(GOLDEN_CACHE):
            raise SystemExit(f"golden missing: {GOLDEN_CACHE}")
        with open(GOLDEN_CACHE, encoding="utf-8") as f:
            golden = json.load(f)
        for key in ("bsp_history_hash", "chart_bsp_hash", "final_step_hash"):
            if golden.get(key) != result.get(key):
                raise SystemExit(f"MISMATCH {key}: golden={golden.get(key)} now={result.get(key)}")
        print("compare OK")


if __name__ == "__main__":
    main()
