import os
import shutil
import tempfile
import unittest

from a_replay_core.a_perf_engine import PerfEngine, normalize_bars


class PerfEngineFallbackTest(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.mkdtemp(prefix="a_perf_engine_test_")

    def tearDown(self):
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def test_normalize_bars_keeps_columnar_values_and_time_ms(self):
        bars = normalize_bars(
            [
                {"x": 0, "t": "2024/01/02 09:31", "o": 10, "h": 11, "l": 9, "c": 10.5, "v": 100},
                {"x": 1, "t": "2024/01/02 09:32", "o": 10.5, "h": 12, "l": 10, "c": 11, "v": 80},
            ]
        )

        self.assertEqual(bars["x"], [0, 1])
        self.assertEqual(bars["close"], [10.5, 11.0])
        self.assertEqual(len(bars["time_ms"]), 2)
        self.assertLess(bars["time_ms"][0], bars["time_ms"][1])

    def test_python_legacy_returns_payload_v2_chip_profile_and_cache_status(self):
        engine = PerfEngine(cache_dir=self.tmp_dir, requested_mode="python_legacy")
        bars = [
            {"x": 0, "t": "2024/01/02 09:31", "o": 10, "h": 11, "l": 9, "c": 10, "v": 100},
            {
                "x": 1,
                "t": "2024/01/02 09:32",
                "o": 10,
                "h": 10.5,
                "l": 9.5,
                "c": 10.2,
                "v": 50,
                "chip_tick_bins": {"p": [10.0, 10.1], "s": [20, 5], "b": [30, 15], "w": [50, 20]},
            },
        ]

        session = engine.load_session(
            code="000001",
            k_type="1min",
            begin_date="2024-01-02",
            end_date="2024-01-02",
            bars=bars,
            chip_bars=bars,
        )
        step_delta = engine.next_step_delta(session.session_id, -1, 0)
        chip = engine.chip_profile(session.session_id, cutoff_x=1, bucket_step=0.1)
        status = engine.cache_status()

        self.assertEqual(session.payload_version, 2)
        self.assertEqual(session.engine_mode, "python-legacy")
        self.assertEqual(step_delta["append_kline"][0]["x"], 0)
        self.assertEqual(chip["profile_id"], f"{session.session_id}:1:0.1")
        self.assertGreater(chip["max_total"], 0)
        self.assertTrue(os.path.isdir(status["cache_dir"]))
        self.assertIn("rust_available", status)

    def test_rust_auto_requires_rust_backend(self):
        engine = PerfEngine(cache_dir=self.tmp_dir, requested_mode="rust_auto")
        engine._rust = None

        with self.assertRaisesRegex(RuntimeError, "会话加载计算调用rust失败"):
            engine.load_session(
                code="000001",
                k_type="1min",
                begin_date="2024-01-02",
                end_date="2024-01-02",
                bars=[{"x": 0, "t": "2024/01/02 09:31", "o": 10, "h": 11, "l": 9, "c": 10, "v": 100}],
                chip_bars=None,
            )

    def test_python_legacy_mode_still_forces_compatible_engine_mode(self):
        engine = PerfEngine(cache_dir=self.tmp_dir, requested_mode="python_legacy")
        session = engine.load_session(
            code="000001",
            k_type="1min",
            begin_date="2024-01-02",
            end_date="2024-01-02",
            bars=[{"x": 0, "t": "2024/01/02 09:31", "o": 10, "h": 11, "l": 9, "c": 10, "v": 100}],
            chip_bars=None,
        )

        self.assertEqual(session.engine_mode, "python-legacy")

    def test_rust_backend_methods_are_used_when_available(self):
        class FakeRust:
            def __init__(self):
                self.calls = []

            def load_session(self, **kwargs):
                self.calls.append(("load_session", kwargs))
                return {
                    "session_id": "rust-session",
                    "payload_version": 2,
                    "engine_mode": "rust",
                    "bar_count": len(kwargs.get("bars") or []),
                    "chip_bar_count": len(kwargs.get("chip_bars") or kwargs.get("bars") or []),
                }

            def normalize_bars(self, bars):
                self.calls.append(("normalize_bars", list(bars)))
                return {"x": [7], "t": ["rust"], "open": [1.0], "high": [2.0], "low": [0.5], "close": [1.5], "volume": [10.0]}

            def chip_profile(self, session_id, cutoff_x=None, bucket_step=None):
                self.calls.append(("chip_profile", session_id, cutoff_x, bucket_step))
                return {
                    "profile_id": f"{session_id}:{cutoff_x}:{bucket_step}",
                    "cutoff_x": cutoff_x,
                    "bucket_step": bucket_step,
                    "prices": [1.0],
                    "s": [2.0],
                    "b": [3.0],
                    "total": [5.0],
                    "max_total": 5.0,
                    "source": "rust",
                }

            def next_step_delta(self, session_id, from_step, to_step):
                self.calls.append(("next_step_delta", session_id, from_step, to_step))
                return {"from_step": from_step, "to_step": to_step, "append_kline": [], "tail_patch": None, "structure_dirty": False}

        engine = PerfEngine(cache_dir=self.tmp_dir, requested_mode="rust_auto")
        fake = FakeRust()
        engine._rust = fake

        session = engine.load_session(
            code="000001",
            k_type="1min",
            begin_date="2024-01-02",
            end_date="2024-01-02",
            bars=[{"x": 0, "t": "2024/01/02 09:31", "o": 10, "h": 11, "l": 9, "c": 10, "v": 100}],
            chip_bars=None,
        )
        chip = engine.chip_profile(session.session_id, cutoff_x=0, bucket_step=0.1)

        self.assertEqual(session.session_id, "rust-session")
        self.assertEqual(chip["source"], "rust")
        self.assertIn("load_session", [call[0] for call in fake.calls])
        self.assertIn("normalize_bars", [call[0] for call in fake.calls])
        self.assertIn("chip_profile", [call[0] for call in fake.calls])


if __name__ == "__main__":
    unittest.main()
