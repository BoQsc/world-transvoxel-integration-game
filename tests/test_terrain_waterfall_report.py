#!/usr/bin/env python3

from __future__ import annotations

import json
import pathlib
import sys
import tempfile
import unittest


TOOLS = pathlib.Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))

import terrain_waterfall_report as report


def native_event(
    sequence: int,
    elapsed_ms: float,
    kind: str,
    cause: int = 0,
    chunk_x: int | None = None,
    duration_ms: float = 0.0,
    auxiliary: int = 0,
    status: int = 0,
) -> dict:
    event = {
        "sequence": sequence,
        "elapsed_ns": int(elapsed_ms * 1_000_000),
        "duration_ns": int(duration_ms * 1_000_000),
        "kind": kind,
        "thread_role": "runtime",
        "cause_id": cause,
        "auxiliary": auxiliary,
        "status": status,
        "generation": 0,
        "has_chunk": chunk_x is not None,
    }
    if chunk_x is not None:
        event.update({
            "chunk_x": chunk_x,
            "chunk_y": 2,
            "chunk_z": chunk_x,
            "chunk_lod": 0,
            "generation": 2,
        })
    return event


def edit_chain(sequence: int, origin_ms: float, cause: int, chunk_x: int) -> list[dict]:
    kinds = [
        ("edit_submitted", 0.0, 0.0),
        ("edit_processing_started", 1.0, 0.0),
        ("edit_committed", 4.0, 3.0),
        ("chunk_demand_accepted", 5.0, 0.0),
        ("storage_requested", 6.0, 0.0),
        ("storage_started", 8.0, 0.0),
        ("storage_finished", 24.0, 16.0),
        ("storage_completion_consumed", 25.0, 0.0),
        ("sample_started", 26.0, 0.0),
        ("sample_finished", 46.0, 20.0),
        ("mesh_started", 47.0, 0.0),
        ("mesh_finished", 67.0, 20.0),
        ("mesh_completion_consumed", 68.0, 0.0),
        ("publication_queued", 69.0, 0.0),
        ("publication_popped", 70.0, 0.0),
        ("frontend_publication_processed", 72.0, 2.0),
        ("render_sink_applied", 74.0, 2.0),
        ("collision_sink_applied", 78.0, 4.0),
        ("visibility_replacement_ready", 79.0, 0.0),
        ("visibility_staging_blocked", 80.0, 0.0),
    ]
    events = []
    for offset, (kind, delta, duration) in enumerate(kinds):
        has_chunk = kind not in {"visibility_staging_blocked", "visibility_batch_published"}
        events.append(native_event(
            sequence + offset,
            origin_ms + delta,
            kind,
            cause,
            chunk_x if has_chunk else None,
            duration,
            1 if kind == "chunk_demand_accepted" else 0,
        ))
    events.append(native_event(
        sequence + len(kinds),
        origin_ms + 82.0,
        "visibility_region_replacement_member",
        77,
        chunk_x,
        auxiliary=3,
        status=1,
    ))
    events.append(native_event(
        sequence + len(kinds) + 1,
        origin_ms + 82.1,
        "visibility_region_replacement_member",
        77,
        98,
        auxiliary=3,
        status=1,
    ))
    events.append(native_event(
        sequence + len(kinds) + 2,
        origin_ms + 82.2,
        "visibility_region_replacement_member",
        77,
        99,
        auxiliary=3,
        status=1,
    ))
    events.append(native_event(
        sequence + len(kinds) + 3,
        origin_ms + 82.3,
        "visibility_region_retirement_member",
        77,
        50,
        auxiliary=3,
        status=1,
    ))
    events.append(native_event(
        sequence + len(kinds) + 4,
        origin_ms + 84.0,
        "visibility_coverage_priority_requested",
        3,
        99,
        auxiliary=1,
    ))
    batch = native_event(
        sequence + len(kinds) + 5,
        origin_ms + 92.0,
        "visibility_batch_published",
        3,
        auxiliary=1,
        status=1,
    )
    batch["generation"] = 77
    events.append(batch)
    return events


class TerrainWaterfallReportTest(unittest.TestCase):
    def test_complete_human_session_is_analyzed(self) -> None:
        native = [native_event(0, 0.0, "trace_started")]
        first_chain = edit_chain(1, 3000.0, 10, 10)
        native.extend(first_chain)
        second_chain = edit_chain(1 + len(first_chain), 7000.0, 20, 20)
        native.extend(second_chain)
        native.append(native_event(1 + len(first_chain) + len(second_chain), 9000.0, "trace_stopped"))
        frames = [
            {
                "sequence": 0,
                "elapsed_us": 100000,
                "frame": 1,
                "kind": "physics_frame",
                "frame_us": 16000,
                "player_position": {"x": 0, "y": 40, "z": 0},
                "movement": {"mode": "fly", "accepted": True, "requested_speed": 32, "distance": 80},
            },
            {
                "sequence": 1,
                "elapsed_us": 200000,
                "frame": 2,
                "kind": "physics_frame",
                "frame_us": 45000,
                "player_position": {"x": 80, "y": 40, "z": 80},
                "movement": {"mode": "fly", "accepted": True, "requested_speed": 32, "distance": 80},
                "pipeline": {"metrics": {"scheduler_queued_jobs": 4}},
            },
            {
                "sequence": 3,
                "elapsed_us": 3090000,
                "frame": 3,
                "kind": "physics_frame",
                "frame_us": 16000,
                "player_position": {"x": 160, "y": 40, "z": 160},
                "movement": {"mode": "walk", "accepted": True, "requested_speed": 0, "distance": 0},
                "pipeline": {"target": {"present": True, "get_generation": 2, "get_render_generation": 2, "get_collision_generation": 2, "is_visual_ready": True, "is_collision_ready": True}, "metrics": {
                    "blocked_pending_chunk_replacements": 2,
                    "pending_chunk_replacements": 2,
                    "first_blocked_replacement_key_x": 99,
                    "first_blocked_replacement_key_y": 2,
                    "first_blocked_replacement_key_z": 99,
                    "first_blocked_replacement_key_lod": 0,
                    "first_blocked_replacement_generation": 7,
                    "first_blocked_replacement_visual_required": True,
                    "first_blocked_replacement_visual_ready": False,
                }},
            },
            {
                "sequence": 5,
                "elapsed_us": 7090000,
                "frame": 4,
                "kind": "physics_frame",
                "frame_us": 16000,
                "player_position": {"x": 320, "y": 40, "z": 320},
                "movement": {"mode": "walk", "accepted": True, "requested_speed": 0, "distance": 0},
                "pipeline": {"target": {"present": True, "get_generation": 4, "get_render_generation": 4, "get_collision_generation": 4, "is_visual_ready": True, "is_collision_ready": True}, "metrics": {
                    "blocked_pending_chunk_replacements": 1,
                    "pending_chunk_replacements": 1,
                    "first_blocked_replacement_key_x": 20,
                    "first_blocked_replacement_key_y": 2,
                    "first_blocked_replacement_key_z": 20,
                    "first_blocked_replacement_key_lod": 0,
                    "first_blocked_replacement_generation": 2,
                    "first_blocked_replacement_collision_required": True,
                    "first_blocked_replacement_collision_ready": False,
                }},
            },
        ]
        requests = [
            {"sequence": 2, "elapsed_us": 3000000, "kind": "edit_submission_requested", "payload": {"mode": "carve", "center": {"x": 160, "y": 40, "z": 160}}, "pipeline": {"target": {"get_generation": 1}}},
            {"sequence": 4, "elapsed_us": 7000000, "kind": "edit_submission_requested", "payload": {"mode": "construct", "center": {"x": 320, "y": 40, "z": 320}}, "pipeline": {"target": {"get_generation": 3}}},
        ]
        trace = {
            "schema": report.TRACE_SCHEMA,
            "final": True,
            "reason": "test",
            "started_unix_ms": 1_000_000,
            "duration_us": 9_000_000,
            "dropped_event_count": 0,
            "observer": {"capture_time_us_total": 1000, "pipeline_capture_time_us_total": 1000},
            "events": [*frames, *requests],
            "native": {
                "complete": True,
                "source_overwrite_count": 17,
                "consumer_gap_event_count": 0,
                "local_dropped_event_count": 0,
                "capture_time_us_total": 1000,
                "events": native,
            },
        }
        usage = {
            "schema": "world_transvoxel.terrain_waterfall_usage.v1",
            "logical_cpu_affinity": [0, 1, 2],
            "logical_cpu_capacity": 3,
            "wall_seconds": 9.0,
            "rss_bytes_maximum": 1000,
            "samples": [
                {"unix_time_seconds": 1003.02, "process_cpu_percent": 120.0},
                {"unix_time_seconds": 1003.08, "process_cpu_percent": 180.0},
                {"unix_time_seconds": 1007.02, "process_cpu_percent": 150.0},
                {"unix_time_seconds": 1007.08, "process_cpu_percent": 210.0},
            ],
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            trace_path = root / "trace.json"
            usage_path = root / "usage.json"
            trace_path.write_text(json.dumps(trace), encoding="utf-8")
            usage_path.write_text(json.dumps(usage), encoding="utf-8")
            result = report.build_session_report([trace_path], usage_path)
        self.assertEqual(result["schema"], report.REPORT_SCHEMA)
        self.assertTrue(result["decision"]["trace_integrity_complete"])
        self.assertFalse(
            result["traces"][0]["integrity"]["native_source_overwrite_implied_loss"]
        )
        self.assertEqual(len(result["traces"][0]["edits"]), 2)
        self.assertTrue(
            result["traces"][0]["edits"][0]["process_usage_during_pipeline"]["available"]
        )
        self.assertEqual(
            result["traces"][0]["edits"][0]["sampled_first_blocker"]["dominant_relation"],
            "other_replacement",
        )
        self.assertEqual(
            result["traces"][0]["edits"][1]["sampled_first_blocker"]["dominant_relation"],
            "edit_replacement",
        )
        publication = result["traces"][0]["edits"][0][
            "correlated_visibility_publication"
        ]
        self.assertEqual(
            publication["classification"],
            "BOUNDED_REGIONAL_BATCH_CONTAINS_EDIT_REPLACEMENTS",
        )
        self.assertEqual(publication["replacement_count"], 3)
        self.assertEqual(publication["retirement_count"], 1)
        self.assertEqual(publication["coverage_priority_other_key_count"], 1)
        self.assertEqual(publication["edit_replacement_members"], 1)
        self.assertEqual(publication["additional_replacements"], 2)
        self.assertTrue(publication["all_edit_replacements_included"])
        self.assertTrue(publication["exact_membership_available"])
        self.assertEqual(
            publication["non_edit_origin"]["classification"],
            "ORIGIN_NOT_RETAINED",
        )
        self.assertGreater(result["traces"][0]["stage_usage"]["meshing"]["duration_ms_total"], 0)
        self.assertFalse(result["decision"]["gpu_architecture_selected"])
        self.assertNotEqual(result["decision"]["classification"], "TRACE_INVALID_OR_INCOMPLETE")


if __name__ == "__main__":
    unittest.main()
