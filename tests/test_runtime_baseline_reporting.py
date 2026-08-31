"""The physics clock cannot substitute for post-draw latency."""

import copy
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools"))
import p0_runtime_baseline as baseline


class RuntimeBaselineReportingTests(unittest.TestCase):
    def setUp(self):
        self.measurement = {
            **baseline.FRAME_TIMING_CONTRACTS,
            "frame_time_ms": {"p50": 1.0, "p95": 2.0, "p99": 3.0, "maximum": 4.0},
            "render_frame_interval_ms": {
                "p50": 10.0, "p95": 20.0, "p99": 30.0, "maximum": 40.0,
            },
        }

    def test_clocks_have_distinct_names_and_values(self):
        result = baseline.frame_timing_metrics(self.measurement)
        self.assertEqual(result["physics_signal_interval_p95_ms"], 2.0)
        self.assertEqual(result["frame_post_draw_interval_p95_ms"], 20.0)
        self.assertEqual(result["frame_post_draw_interval_p99_ms"], 30.0)
        self.assertNotIn("frame_p95_ms", result)

    def test_missing_post_draw_samples_never_fall_back_to_physics(self):
        del self.measurement["render_frame_interval_ms"]
        with self.assertRaises(KeyError):
            baseline.frame_timing_metrics(self.measurement)

    def test_unknown_or_missing_contract_is_rejected(self):
        for key in baseline.FRAME_TIMING_CONTRACTS:
            for value in (None, "display_present"):
                with self.subTest(key=key, value=value):
                    changed = copy.deepcopy(self.measurement)
                    changed[key] = value
                    with self.assertRaises(RuntimeError):
                        baseline.frame_timing_metrics(changed)

    def test_incomplete_measurement_cannot_be_aggregated_as_pass(self):
        with self.assertRaisesRegex(RuntimeError, "incomplete"):
            baseline._aggregate(
                [{"enabled": True, "measurement_complete": False}],
                [{"target_status": "MEASUREMENT_INCOMPLETE"}], 2, 0, {},
            )

    def test_aggregation_requires_matching_nonempty_executions(self):
        for runs, executions in (([], []), ([self.measurement], [])):
            with self.subTest(runs=len(runs), executions=len(executions)):
                with self.assertRaisesRegex(RuntimeError, "matching nonempty"):
                    baseline._aggregate(runs, executions, 2, 0, {})

    def test_completed_samples_do_not_hide_an_incomplete_execution(self):
        self.measurement.update({
            "enabled": True,
            "measurement_complete": True,
            "movement": {"frames": 1020},
            "edit": {"interaction_accepted": True},
            "backlog": {},
            "acceptance": {},
        })
        for execution in (
            {"measurement_complete": False, "target_status": "MEASURED_TARGET_PASS"},
            {"measurement_complete": True, "target_status": "MEASUREMENT_INCOMPLETE"},
        ):
            with self.subTest(execution=execution):
                with self.assertRaisesRegex(RuntimeError, "baseline execution"):
                    baseline._aggregate([self.measurement], [execution], 2, 0, {})


if __name__ == "__main__":
    unittest.main()
