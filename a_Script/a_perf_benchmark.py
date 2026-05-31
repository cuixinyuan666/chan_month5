import argparse
import sys
import statistics
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from a_replay_core.a_perf_engine import PerfEngine


def _sample_bars(n: int) -> list[dict]:
    bars = []
    price = 10.0
    for i in range(n):
        price += 0.01 if i % 2 == 0 else -0.005
        bars.append(
            {
                "x": i,
                "t": f"2024/01/{1 + (i // 240):02d} 09:{30 + (i % 60):02d}",
                "o": price,
                "h": price + 0.08,
                "l": price - 0.06,
                "c": price + 0.02,
                "v": 100 + (i % 37),
                "chip_tick_bins": {"p": [round(price, 2), round(price + 0.03, 2)], "s": [20, 5], "b": [35, 15]},
            }
        )
    return bars


def _time_call(fn, loops: int) -> list[float]:
    rows = []
    for _ in range(loops):
        t0 = time.perf_counter()
        fn()
        rows.append((time.perf_counter() - t0) * 1000)
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description="a_replay_trainer 性能引擎微基准")
    parser.add_argument("--bars", type=int, default=5000, help="样本K线数量")
    parser.add_argument("--loops", type=int, default=5, help="重复次数")
    args = parser.parse_args()

    bars = _sample_bars(max(1, args.bars))
    engine = PerfEngine(requested_mode="rust_auto")
    t0 = time.perf_counter()
    session = engine.load_session(
        code="000001",
        k_type="1min",
        begin_date="2024-01-01",
        end_date="2024-01-31",
        bars=bars,
        chip_bars=bars,
    )
    load_ms = (time.perf_counter() - t0) * 1000
    step_ms = _time_call(lambda: engine.next_step_delta(session.session_id, args.bars - 2, args.bars - 1), args.loops)
    chip_ms = _time_call(lambda: engine.chip_profile(session.session_id, cutoff_x=args.bars - 1, bucket_step=0.1), args.loops)

    print(f"engine_mode={session.engine_mode} payload_version={session.payload_version}")
    print(f"load_session_ms={load_ms:.3f}")
    print(f"step_delta_ms_avg={statistics.mean(step_ms):.3f} max={max(step_ms):.3f}")
    print(f"chip_profile_ms_avg={statistics.mean(chip_ms):.3f} max={max(chip_ms):.3f}")
    print(f"cache={engine.cache_status()}")


if __name__ == "__main__":
    main()
