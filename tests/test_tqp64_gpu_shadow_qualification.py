from __future__ import annotations

import pathlib
import sys


TOOLS = pathlib.Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))

import run_tqp64_gpu_shadow_qualification as qualification


def status(frame: int, terrain: int, transition: int = 0) -> dict:
    return {
        "frame": frame,
        "pipeline": {
            "gpu_meshing_shadow": {
                "running": True,
                "terrain_matched_results": terrain,
                "transition_matched_results": transition,
                "matched_results": terrain,
                "cpu_render_authority": True,
                "cpu_collision_authority": True,
                "gpu_publication_enabled": False,
                "native_metrics": {
                    "captured_requests": terrain,
                    "matched_results": terrain,
                },
            }
        },
    }


def test_trace_summary_attributes_matches_to_both_edit_windows() -> None:
    trace = {
        "schema": "world_transvoxel.cpu_causal_trace.v2",
        "final": True,
        "native": {"complete": True},
        "events": [
            {"frame": 10, "kind": "phase_started", "phase": "relocated_carve"},
            status(10, 5),
            status(14, 8, 1),
            {"frame": 15, "kind": "autonomous_edit_wait_finished"},
            {"frame": 30, "kind": "phase_started", "phase": "relocated_construct"},
            status(30, 10, 1),
            status(39, 14, 2),
            {"frame": 40, "kind": "autonomous_edit_wait_finished"},
        ],
    }

    summary = qualification.summarize_trace(trace)

    assert summary["relocated_edit_terrain_match_deltas"] == {
        "relocated_carve": 3,
        "relocated_construct": 4,
    }
    assert summary["controller_maximum"]["transition_matched_results"] == 2
    assert summary["native_maximum"]["captured_requests"] == 14


def test_baseline_rejects_an_active_shadow() -> None:
    summary = {
        "exit_code": 0,
        "trace": {
            "final": True,
            "native_complete": True,
            "dropped_event_count": 0,
            "native_consumer_gap_event_count": 0,
            "native_local_dropped_event_count": 0,
            "shadow_running_observed": True,
            "cpu_render_authority": True,
            "cpu_collision_authority": True,
            "gpu_publication_observed": False,
        },
        "report": {
            "trace_count": 1,
            "trace_integrity_complete": True,
            "required_human_route_covered": True,
        },
        "usage": {"logical_cpu_capacity": 3},
    }

    assert qualification.evaluate_run("cpu_baseline", summary) == [
        "shadow_disabled"
    ]
