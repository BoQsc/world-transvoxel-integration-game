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
    events = [
        native_event(
            sequence,
            origin_ms - 200.0,
            "chunk_demand_accepted",
            900,
            chunk_x,
        ),
        native_event(
            sequence + 1,
            origin_ms - 120.0,
            "render_sink_applied",
            chunk_x=chunk_x,
        ),
        native_event(
            sequence + 2,
            origin_ms - 100.0,
            "collision_sink_applied",
            chunk_x=chunk_x,
        ),
    ]
    for kind, delta, duration in kinds:
        has_chunk = kind not in {"visibility_staging_blocked", "visibility_batch_published"}
        events.append(native_event(
            sequence + len(events),
            origin_ms + delta,
            kind,
            cause,
            chunk_x if has_chunk else None,
            duration,
            1 if kind == "chunk_demand_accepted" else 0,
        ))
    desired_snapshot = native_event(
        sequence + len(events),
        origin_ms + 81.9,
        "visibility_region_desired_snapshot",
        900,
        auxiliary=0,
    )
    desired_snapshot["generation"] = 77
    events.append(desired_snapshot)
    events.append(native_event(
        sequence + len(events),
        origin_ms + 82.0,
        "visibility_region_replacement_member",
        77,
        chunk_x,
        status=11,
    ))
    events.append(native_event(
        sequence + len(events),
        origin_ms + 82.1,
        "visibility_region_replacement_member",
        77,
        98,
        status=9,
    ))
    events.append(native_event(
        sequence + len(events),
        origin_ms + 82.2,
        "visibility_region_replacement_member",
        77,
        99,
        status=9,
    ))
    events.append(native_event(
        sequence + len(events),
        origin_ms + 82.3,
        "visibility_region_retirement_member",
        77,
        50,
        auxiliary=3,
        status=1,
    ))
    events.append(native_event(
        sequence + len(events),
        origin_ms + 84.0,
        "visibility_coverage_priority_requested",
        3,
        99,
        auxiliary=1,
    ))
    batch = native_event(
        sequence + len(events),
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
    def test_publication_component_audit_accepts_exact_octree_replacement(self) -> None:
        replacements = {
            (x, y, z, 0)
            for z in range(2)
            for y in range(2)
            for x in range(2)
        }
        result = report.publication_component_audit(
            replacements,
            {(0, 0, 0, 1)},
        )
        self.assertEqual(
            result["classification"],
            "MINIMAL_UNDER_AUTHORITY_COMPONENT_RULE",
        )
        self.assertTrue(result["minimal_under_authority_rule"])
        self.assertEqual(result["component_count"], 1)
        self.assertEqual(result["component_sizes"], [9])
        self.assertEqual(result["overlap_edge_count"], 8)
        self.assertEqual(result["unsafe_lod_boundary_edge_count"], 0)
        self.assertEqual(result["uncovered_retirement_count"], 0)

    def test_publication_component_audit_rejects_disconnected_backlog(self) -> None:
        replacements = {
            (x, y, z, 0)
            for z in range(2)
            for y in range(2)
            for x in range(2)
        }
        replacements.add((8, 0, 0, 0))
        result = report.publication_component_audit(
            replacements,
            {(0, 0, 0, 1)},
        )
        self.assertEqual(
            result["classification"],
            "REGION_CONTAINS_DISCONNECTED_COMPONENTS",
        )
        self.assertFalse(result["minimal_under_authority_rule"])
        self.assertEqual(result["component_count"], 2)
        self.assertEqual(result["component_sizes"], [9, 1])
        self.assertEqual(result["isolated_node_count"], 1)

    def test_publication_component_audit_retains_unsafe_lod_face_edge(self) -> None:
        result = report.publication_component_audit(
            {(4, 0, 0, 0)},
            {(0, 0, 0, 2)},
        )
        self.assertEqual(result["component_count"], 1)
        self.assertEqual(result["overlap_edge_count"], 0)
        self.assertEqual(result["unsafe_lod_boundary_edge_count"], 1)
        self.assertEqual(
            result["classification"],
            "REGION_HAS_INCOMPLETE_RETIREMENT_COVERAGE",
        )

    def test_non_edit_publication_blocker_critical_path_is_attributed(self) -> None:
        identity = (99, 2, 99, 0, 7)
        native = []

        def add(kind: str, elapsed_ms: float, duration_ms: float = 0.0) -> None:
            event = native_event(
                len(native), elapsed_ms, kind, chunk_x=identity[0],
                duration_ms=duration_ms,
            )
            event.update({
                "chunk_y": identity[1],
                "chunk_z": identity[2],
                "chunk_lod": identity[3],
                "generation": identity[4],
            })
            native.append(event)

        def add_job(
            kind: str,
            elapsed_ms: float,
            stage: str,
            priority: int,
            queue_depth: int,
            jobs_ahead: int,
            same_priority_ahead: int,
        ) -> None:
            add(kind, elapsed_ms)
            native[-1].update({
                "has_job_details": True,
                "job_stage": stage,
                "effective_priority": priority,
                "job_sequence": len(native),
                "has_queue_state": True,
                "queue_depth_before": queue_depth,
                "queue_depth_after": queue_depth,
                "jobs_ahead": jobs_ahead,
                "same_priority_jobs_ahead": same_priority_ahead,
            })

        def add_ahead_mesh(
            chunk: int,
            job_sequence: int,
        ) -> None:
            add_job(
                "scheduler_job_queued", 3030.5 + job_sequence / 1000.0,
                "mesh", 2147483647, job_sequence, job_sequence - 1,
                job_sequence - 1,
            )
            native[-1]["job_sequence"] = job_sequence
            native[-1].update({
                "chunk_x": chunk,
                "chunk_y": 2,
                "chunk_z": chunk,
                "chunk_lod": 0,
                "generation": 7,
            })

        add("chunk_demand_accepted", 2800.0)
        add_job("scheduler_job_queued", 2800.1, "sample", 12, 40, 30, 2)
        add("readiness_repair_generation_created", 2995.0)
        native[-1]["auxiliary"] = 1
        add("visibility_coverage_priority_requested", 3010.0)
        add("visibility_coverage_priority_outcome", 3020.0)
        native[-1]["status"] = 3
        add_job(
            "scheduler_job_priority_observed", 3020.1, "sample",
            2147483647, 60, 20, 20,
        )
        add_job(
            "scheduler_job_dequeued", 3030.0, "sample",
            2147483647, 50, 0, 0,
        )
        add("sample_started", 3030.1)
        add_job(
            "page_meshing_ownership_established", 3030.2, "sample",
            2147483647, 0, 0, 0,
        )
        add("sample_finished", 3031.0, 1.0)
        add_ahead_mesh(98, 100)
        add_ahead_mesh(99, 101)
        add_job(
            "scheduler_job_queued", 3031.0, "mesh",
            2147483647, 3, 2, 2,
        )
        native[-1]["job_sequence"] = 102
        add_job(
            "scheduler_job_dequeued", 3060.0, "mesh",
            2147483647, 20, 0, 0,
        )
        add("mesh_started", 3060.1)
        add("mesh_finished", 3065.0, 5.0)
        add("mesh_completion_consumed", 3066.0)
        add("render_sink_applied", 3070.0)
        add("collision_sink_applied", 3071.0)
        add("visibility_replacement_ready", 3075.0)
        batch = native_event(100, 3092.0, "visibility_batch_published")
        blocker = {
            "available": True,
            "transitions": [{
                "elapsed_from_request_ms": 9.0,
                "key": {"x": 99, "y": 2, "z": 99, "lod": 0},
                "generation": 7,
                "reason": "visual_not_ready",
                "relation": "other_replacement",
            }],
        }
        publication = {
            "replacement_members": [
                {
                    "x": chunk,
                    "y": 2,
                    "z": chunk,
                    "lod": 0,
                    "generation": 7,
                    "visual_required": True,
                    "collision_required": True,
                }
                for chunk in (98, 99)
            ],
        }
        result = report.publication_blocker_critical_path_analysis(
            native,
            blocker,
            publication,
            3_000_000_000,
            batch,
        )
        self.assertEqual(
            result["classification"],
            "EXACT_TERMINAL_CONTROLLER_PATHS_RETAINED",
        )
        self.assertEqual(result["non_edit_path_count"], 1)
        self.assertEqual(result["complete_path_count"], 1)
        self.assertEqual(result["terminal_controller_path_count"], 1)
        self.assertEqual(result["terminal_controller_complete_path_count"], 1)
        self.assertEqual(
            result["terminal_controller_generation_origin_counts"],
            {"READINESS_REPAIR_STAGED": 1},
        )
        path = result["paths"][0]
        self.assertTrue(path["explicit_generation_origin_retained"])
        self.assertFalse(path["priority_apply_retained"])
        self.assertTrue(path["priority_outcome_retained"])
        self.assertEqual(
            path["priority_outcome_classification"],
            "PAGE_GENERATION_STALE",
        )
        self.assertTrue(path["priority_scheduler_applied"])
        self.assertEqual(
            result["terminal_controller_priority_outcome_counts"],
            {"PAGE_GENERATION_STALE": 1},
        )
        self.assertEqual(
            result["terminal_controller_priority_scheduler_applied_path_count"],
            1,
        )
        self.assertTrue(path["scheduler_queue_path_complete"])
        self.assertTrue(path["interactive_priority_at_mesh_admission"])
        self.assertTrue(path["interactive_priority_at_mesh_dequeue"])
        self.assertEqual(
            path["scheduler_queue"]["mesh_admission"][
                "same_priority_jobs_ahead"
            ],
            2,
        )
        composition = path["scheduler_queue"][
            "mesh_admission_ahead_composition"
        ]
        self.assertTrue(composition["exact"])
        self.assertEqual(composition["stage_counts"], {"mesh": 2})
        self.assertEqual(composition["same_publication_region_jobs_ahead"], 2)
        self.assertTrue(
            composition["all_jobs_ahead_are_same_priority_publication_members"]
        )
        self.assertEqual(path["scheduler_queue"]["mesh_residency_ms"], 29.0)
        self.assertEqual(
            result["terminal_controller_complete_scheduler_queue_path_count"],
            1,
        )
        self.assertEqual(
            result["terminal_controller_interactive_mesh_priority_path_count"],
            1,
        )
        self.assertEqual(
            result["overall_dominant"]["classification"],
            "MESH_SCHEDULER_QUEUE",
        )
        self.assertEqual(result["overall_dominant"]["duration_ms"], 29.0)

    def test_gpu_first_draw_replaces_later_cpu_visual_tail(self) -> None:
        native = edit_chain(1, 3000.0, 10, 10)
        request = {
            "elapsed_us": 3_000_000,
            "kind": "edit_submission_requested",
            "payload": {"mode": "carve", "center": {"x": 160, "y": 40, "z": 160}},
            "pipeline": {"target": {"get_generation": 1}},
        }
        frame = {
            "elapsed_us": 3_030_000,
            "frame": 102,
            "kind": "physics_frame",
            "pipeline": {
                "target": {
                    "present": True,
                    "get_generation": 2,
                    "get_render_generation": 2,
                    "get_collision_generation": 2,
                    "is_visual_ready": True,
                    "is_collision_ready": True,
                },
                "gpu_resident_render": {
                    "recent_incremental_activations": [{
                        "surface": "terrain",
                        "empty": False,
                        "identity": {
                            "page_x": 10,
                            "page_y": 2,
                            "page_z": 10,
                            "lod": 0,
                            "generation": 3,
                            "world_revision": 10,
                            "incremental_edit": True,
                        },
                    }],
                    "recent_incremental_first_draws": [{
                        "surface": "terrain",
                        "effect_ticks_usec": 123,
                        "identity": {
                            "page_x": 10,
                            "page_y": 2,
                            "page_z": 10,
                            "lod": 0,
                            "generation": 2,
                            "world_revision": 10,
                            "incremental_edit": True,
                        },
                    }],
                },
            },
        }
        edit = report.edit_analysis([request, frame], native)[0]
        self.assertTrue(edit["gpu_visual_completion"]["complete"])
        self.assertEqual(edit["gpu_visual_completion"]["drawn_chunk_count"], 1)
        self.assertEqual(edit["gpu_visual_completion"]["completion_after_request_ms"], 30.0)
        self.assertEqual(edit["collision_publication_ms"], 78.0)
        self.assertEqual(edit["pipeline_completion_ms"], 78.0)
        self.assertEqual(edit["cpu_visibility_completion_ms"], 92.0)
        self.assertNotEqual(edit["dominant_wait"]["stage"], "visibility_staging")

        empty_identity = {
            "page_x": 11,
            "page_y": 2,
            "page_z": 11,
            "lod": 0,
            "generation": 2,
            "world_revision": 10,
            "incremental_edit": True,
        }
        frame["pipeline"]["gpu_resident_render"][
            "recent_incremental_activations"
        ].append({
            "surface": "terrain",
            "empty": True,
            "identity": empty_identity,
        })
        gpu = report.gpu_incremental_first_draw_analysis(
            [frame],
            {(10, 2, 10, 0, 2), (11, 2, 11, 0, 2)},
            10,
            3_000_000,
            3_000_000_000,
        )
        self.assertTrue(gpu["complete"])
        self.assertEqual(gpu["published_chunk_count"], 2)
        self.assertEqual(gpu["drawn_chunk_count"], 1)
        self.assertEqual(gpu["empty_chunk_count"], 1)

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
        self.assertIn(
            "publication_blocker_critical_paths",
            result["traces"][0]["edits"][0],
        )
        destination = result["traces"][0]["edits"][0][
            "pre_edit_destination_readiness"
        ]
        self.assertEqual(
            destination["classification"],
            "DESTINATION_FULLY_READY_BEFORE_EDIT",
        )
        self.assertEqual(destination["first_demand"]["before_edit_ms"], 200.0)
        self.assertEqual(destination["full_readiness"]["before_edit_ms"], 100.0)
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
            publication["desired_ownership"]["classification"],
            "EXACT_LATEST_DRAINED_PLAN_OWNERSHIP",
        )
        self.assertTrue(publication["desired_ownership"]["exact"])
        self.assertEqual(
            publication["desired_ownership"]["latest_completed_viewer_plan_revision"],
            900,
        )
        self.assertEqual(publication["desired_ownership"]["required_member_count"], 3)
        self.assertEqual(publication["desired_ownership"]["visual_required_member_count"], 3)
        self.assertEqual(publication["desired_ownership"]["collision_required_member_count"], 1)
        self.assertEqual(
            publication["non_edit_origin"]["classification"],
            "ORIGIN_NOT_RETAINED",
        )
        self.assertGreater(result["traces"][0]["stage_usage"]["meshing"]["duration_ms_total"], 0)
        self.assertFalse(result["decision"]["gpu_architecture_selected"])
        self.assertNotEqual(result["decision"]["classification"], "TRACE_INVALID_OR_INCOMPLETE")


if __name__ == "__main__":
    unittest.main()
