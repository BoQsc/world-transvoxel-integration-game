#!/usr/bin/env python3
"""Analyze optional human terrain-pipeline waterfall captures.

The raw native stream is authoritative for pipeline order. This analyzer keeps
human movement and target-readiness observations separate and reports trace
overhead explicitly; it does not treat traced timing as a performance baseline.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
import math
import pathlib
import statistics
import sys
from typing import Any, Iterable


TRACE_SCHEMA = "world_transvoxel.cpu_causal_trace.v2"
REPORT_SCHEMA = "world_transvoxel.terrain_waterfall_report.v1"
HITCH_THRESHOLD_MS = 33.3
LONG_RELOCATION_DISTANCE = 128.0
EDIT_RELOCATION_DISTANCE = 64.0

STAGE_BY_KIND = {
    "viewer_plan_started": "viewer",
    "viewer_plan_applied": "viewer",
    "chunk_demand_accepted": "demand",
    "edit_submitted": "authority",
    "edit_processing_started": "authority",
    "edit_committed": "authority",
    "edit_rejected": "authority",
    "storage_requested": "storage",
    "storage_started": "storage",
    "storage_finished": "storage",
    "storage_completion_consumed": "storage",
    "sample_started": "sampling",
    "sample_finished": "sampling",
    "mesh_started": "meshing",
    "mesh_finished": "meshing",
    "mesh_completion_consumed": "meshing",
    "transition_mesh_started": "transition_meshing",
    "transition_mesh_finished": "transition_meshing",
    "transition_mesh_completion_consumed": "transition_meshing",
    "publication_queued": "publication",
    "publication_popped": "publication",
    "frontend_publication_processed": "publication",
    "render_sink_applied": "render_sink",
    "collision_sink_applied": "collision_sink",
    "visibility_replacement_ready": "visibility",
    "visibility_staging_blocked": "visibility",
    "visibility_batch_published": "visibility",
    "visibility_coverage_priority_requested": "visibility",
    "visibility_coverage_priority_applied": "visibility",
}

PIPELINE_ORDER = (
    "viewer",
    "authority",
    "demand",
    "storage",
    "sampling",
    "meshing",
    "transition_meshing",
    "publication",
    "render_sink",
    "collision_sink",
    "visibility",
)


def load_object(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError(f"expected JSON object: {path}")
    return value


def percentile(values: list[float], quantile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return float(ordered[lower])
    fraction = position - lower
    return float(ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction)


def position(value: Any) -> tuple[float, float, float] | None:
    if not isinstance(value, dict):
        return None
    try:
        return (float(value["x"]), float(value["y"]), float(value["z"]))
    except (KeyError, TypeError, ValueError):
        return None


def distance(left: tuple[float, float, float], right: tuple[float, float, float]) -> float:
    return math.sqrt(sum((left[index] - right[index]) ** 2 for index in range(3)))


def native_identity(event: dict[str, Any]) -> tuple[int, int, int, int, int] | None:
    if event.get("has_chunk") is not True:
        return None
    return tuple(
        int(event.get(name, 0))
        for name in ("chunk_x", "chunk_y", "chunk_z", "chunk_lod", "generation")
    )


def metrics_from_event(event: dict[str, Any]) -> dict[str, Any]:
    pipeline = event.get("pipeline")
    if not isinstance(pipeline, dict):
        return {}
    metrics = pipeline.get("metrics")
    return metrics if isinstance(metrics, dict) else {}


def target_from_event(event: dict[str, Any]) -> dict[str, Any]:
    pipeline = event.get("pipeline")
    if not isinstance(pipeline, dict):
        return {}
    target = pipeline.get("target")
    return target if isinstance(target, dict) else {}


def classify_sampled_blocker(
    frame: dict[str, Any], native_window: list[dict[str, Any]]
) -> str:
    movement = frame.get("movement")
    movement = movement if isinstance(movement, dict) else {}
    metrics = metrics_from_event(frame)
    if movement.get("accepted") is False:
        if int(metrics.get("collision_required_not_ready_chunk_records", 0)) > 0:
            return "COLLISION_READINESS_GATE"
        return "MOVEMENT_REJECTED_UNATTRIBUTED"
    target = target_from_event(frame)
    if target.get("present") is True and target.get("is_visual_ready") is False:
        if int(metrics.get("storage_queued_requests", 0)) > 0 or int(
            metrics.get("storage_active_requests", 0)
        ) > 0:
            return "TARGET_WAIT_STORAGE"
        if int(metrics.get("scheduler_queued_jobs", 0)) > 0:
            return "TARGET_WAIT_SAMPLE_OR_MESH"
        if int(metrics.get("queued_render", 0)) > 0:
            return "TARGET_WAIT_RENDER_APPLICATION"
        return "TARGET_VISUAL_NOT_READY"
    if target.get("present") is True and target.get("is_collision_ready") is False:
        return "TARGET_WAIT_COLLISION_APPLICATION"
    if int(metrics.get("blocked_pending_chunk_replacements", 0)) > 0:
        return "VISIBILITY_STAGING_REPLACEMENTS"
    duration_events = [
        event for event in native_window if int(event.get("duration_ns", 0)) > 0
    ]
    if duration_events:
        largest = max(duration_events, key=lambda event: int(event["duration_ns"]))
        return f"NATIVE_{STAGE_BY_KIND.get(str(largest.get('kind')), 'PIPELINE').upper()}"
    return "FRAME_TIME_UNATTRIBUTED"


def stage_usage(native_events: list[dict[str, Any]]) -> dict[str, Any]:
    stages: dict[str, dict[str, Any]] = {}
    for stage in (*PIPELINE_ORDER, "other"):
        stages[stage] = {
            "event_count": 0,
            "timed_event_count": 0,
            "duration_ms_total": 0.0,
            "duration_ms_maximum": 0.0,
            "thread_roles": {},
            "event_kinds": {},
        }
    role_counts: dict[str, Counter[str]] = defaultdict(Counter)
    kind_counts: dict[str, Counter[str]] = defaultdict(Counter)
    for event in native_events:
        kind = str(event.get("kind", "unknown"))
        stage = STAGE_BY_KIND.get(kind, "other")
        item = stages[stage]
        item["event_count"] += 1
        role_counts[stage][str(event.get("thread_role", "unknown"))] += 1
        kind_counts[stage][kind] += 1
        duration_ms = float(event.get("duration_ns", 0)) / 1_000_000.0
        if duration_ms > 0.0:
            item["timed_event_count"] += 1
            item["duration_ms_total"] += duration_ms
            item["duration_ms_maximum"] = max(
                float(item["duration_ms_maximum"]), duration_ms
            )
    for stage, item in stages.items():
        item["thread_roles"] = dict(sorted(role_counts[stage].items()))
        item["event_kinds"] = dict(sorted(kind_counts[stage].items()))
        item["duration_ms_mean"] = (
            float(item["duration_ms_total"]) / int(item["timed_event_count"])
            if int(item["timed_event_count"]) else 0.0
        )
    return stages


def frame_analysis(
    downstream_events: list[dict[str, Any]], native_events: list[dict[str, Any]]
) -> dict[str, Any]:
    frames = [event for event in downstream_events if event.get("kind") == "physics_frame"]
    frame_ms = [float(event.get("frame_us", 0)) / 1000.0 for event in frames]
    moving = [
        event for event in frames
        if float((event.get("movement") or {}).get("requested_speed", 0.0)) > 0.0
    ]
    flying = [
        event for event in moving
        if str((event.get("movement") or {}).get("mode", "walk")) == "fly"
    ]
    blocked = [
        event for event in moving if (event.get("movement") or {}).get("accepted") is False
    ]
    hitches = [event for event in frames if float(event.get("frame_us", 0)) >= 33_300.0]
    worst_frames = []
    for frame in sorted(frames, key=lambda event: int(event.get("frame_us", 0)), reverse=True)[:12]:
        end_us = int(frame.get("elapsed_us", 0))
        begin_ns = max(0, end_us - int(frame.get("frame_us", 0))) * 1000
        end_ns = end_us * 1000
        native_window = [
            event for event in native_events
            if begin_ns <= int(event.get("elapsed_ns", -1)) <= end_ns
        ]
        worst_frames.append({
            "frame": int(frame.get("frame", -1)),
            "elapsed_ms": end_us / 1000.0,
            "frame_ms": float(frame.get("frame_us", 0)) / 1000.0,
            "movement": frame.get("movement", {}),
            "classification": classify_sampled_blocker(frame, native_window),
            "sampled_metrics": metrics_from_event(frame),
            "native_event_kinds": dict(sorted(Counter(
                str(event.get("kind", "unknown")) for event in native_window
            ).items())),
            "native_timed_duration_ms": sum(
                float(event.get("duration_ns", 0)) / 1_000_000.0
                for event in native_window
            ),
        })
    classifications = Counter(item["classification"] for item in worst_frames)
    return {
        "frame_count": len(frames),
        "movement_frame_count": len(moving),
        "flight_frame_count": len(flying),
        "blocked_movement_frame_count": len(blocked),
        "blocked_flight_frame_count": sum(1 for event in flying if (event.get("movement") or {}).get("accepted") is False),
        "hitch_frame_count": len(hitches),
        "movement_distance": sum(float((event.get("movement") or {}).get("distance", 0.0)) for event in moving),
        "flight_distance": sum(float((event.get("movement") or {}).get("distance", 0.0)) for event in flying),
        "frame_ms": {
            "mean": statistics.fmean(frame_ms) if frame_ms else 0.0,
            "p50": percentile(frame_ms, 0.50),
            "p95": percentile(frame_ms, 0.95),
            "p99": percentile(frame_ms, 0.99),
            "maximum": max(frame_ms, default=0.0),
        },
        "worst_frame_classifications": dict(sorted(classifications.items())),
        "worst_frames": worst_frames,
    }


def stage_window(
    events: Iterable[dict[str, Any]], origin_ns: int
) -> list[dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        stage = STAGE_BY_KIND.get(str(event.get("kind", "")))
        if stage:
            grouped[stage].append(event)
    rows = []
    for stage in PIPELINE_ORDER:
        stage_events = grouped.get(stage, [])
        if not stage_events:
            continue
        start_ns = min(int(event.get("elapsed_ns", origin_ns)) for event in stage_events)
        end_ns = max(
            int(event.get("elapsed_ns", origin_ns)) + int(event.get("duration_ns", 0))
            for event in stage_events
        )
        rows.append({
            "stage": stage,
            "start_ms": (start_ns - origin_ns) / 1_000_000.0,
            "end_ms": (end_ns - origin_ns) / 1_000_000.0,
            "span_ms": (end_ns - start_ns) / 1_000_000.0,
            "timed_duration_ms": sum(
                int(event.get("duration_ns", 0)) for event in stage_events
            ) / 1_000_000.0,
            "event_count": len(stage_events),
            "event_kinds": dict(sorted(Counter(
                str(event.get("kind", "unknown")) for event in stage_events
            ).items())),
        })
    return rows


def _first_event(
    events: Iterable[dict[str, Any]], kind: str, cause_id: int | None = None
) -> dict[str, Any] | None:
    for event in events:
        if event.get("kind") != kind:
            continue
        if cause_id is not None and int(event.get("cause_id", -1)) != cause_id:
            continue
        return event
    return None


def _last_event(events: Iterable[dict[str, Any]], kinds: set[str]) -> dict[str, Any] | None:
    matching = [event for event in events if str(event.get("kind")) in kinds]
    return max(matching, key=lambda event: int(event.get("elapsed_ns", 0))) if matching else None


def _target_generation_ready(
    target: dict[str, Any], generation_before: int, sink: str
) -> bool:
    if target.get("present") is not True:
        return False
    generation = int(target.get("get_generation", -1))
    if generation <= generation_before:
        return False
    if sink == "render":
        return (
            target.get("is_visual_ready") is True
            and int(target.get("get_render_generation", -1)) >= generation
        )
    return (
        target.get("is_collision_ready") is True
        and int(target.get("get_collision_generation", -1)) >= generation
    )


def edit_analysis(
    downstream_events: list[dict[str, Any]], native_events: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    requests = [
        event for event in downstream_events
        if event.get("kind") == "edit_submission_requested"
    ]
    native_submissions = [
        event for event in native_events if event.get("kind") == "edit_submitted"
    ]
    frames = [event for event in downstream_events if event.get("kind") == "physics_frame"]
    first_player_position = position(frames[0].get("player_position")) if frames else None
    previous_center = first_player_position
    reports = []
    for index, submission in enumerate(native_submissions):
        origin_ns = int(submission.get("elapsed_ns", 0))
        end_ns = (
            int(native_submissions[index + 1].get("elapsed_ns", origin_ns))
            if index + 1 < len(native_submissions)
            else 2**63 - 1
        )
        events = [
            event for event in native_events
            if origin_ns <= int(event.get("elapsed_ns", -1)) < end_ns
        ]
        cause_id = int(submission.get("cause_id", -1))
        demands = [
            event for event in events
            if event.get("kind") == "chunk_demand_accepted"
            and int(event.get("cause_id", -2)) == cause_id
            and int(event.get("auxiliary", 0)) == 1
        ]
        replacement_identities = {
            identity for event in demands
            if (identity := native_identity(event)) is not None
        }
        replacement_events = [
            event for event in events
            if native_identity(event) in replacement_identities
            or event.get("kind") in {
                "edit_submitted", "edit_processing_started", "edit_committed",
                "edit_rejected", "visibility_staging_blocked",
                "visibility_batch_published",
            }
        ]
        request = requests[index] if index < len(requests) else {}
        request_elapsed_us = int(request.get("elapsed_us", origin_ns // 1000))
        next_request_elapsed_us = (
            int(requests[index + 1].get("elapsed_us", 2**63 - 1))
            if index + 1 < len(requests) else 2**63 - 1
        )
        edit_frames = [
            event for event in frames
            if request_elapsed_us <= int(event.get("elapsed_us", -1)) < next_request_elapsed_us
        ]
        request_target = target_from_event(request)
        target_generation_before = int(request_target.get("get_generation", -1))
        target_visual_frame = next((
            event for event in edit_frames
            if _target_generation_ready(
                target_from_event(event), target_generation_before, "render"
            )
        ), None)
        target_collision_frame = next((
            event for event in edit_frames
            if _target_generation_ready(
                target_from_event(event), target_generation_before, "collision"
            )
        ), None)
        ready_event = _last_event(replacement_events, {"visibility_replacement_ready"})
        ready_ns = int(ready_event.get("elapsed_ns", origin_ns)) if ready_event else origin_ns
        batch_event = next((
            event for event in events
            if event.get("kind") == "visibility_batch_published"
            and int(event.get("elapsed_ns", 0)) >= ready_ns
        ), None)
        blocker_event = next((
            event for event in events
            if event.get("kind") == "visibility_staging_blocked"
            and int(event.get("elapsed_ns", 0)) >= ready_ns
        ), None)
        center = position((request.get("payload") or {}).get("center"))
        relocation_distance = (
            distance(previous_center, center)
            if previous_center is not None and center is not None else None
        )
        if center is not None:
            previous_center = center
        preceding_begin_us = (
            int(requests[index - 1].get("elapsed_us", 0))
            if index > 0 else 0
        )
        preceding_frames = [
            event for event in frames
            if preceding_begin_us <= int(event.get("elapsed_us", -1)) < request_elapsed_us
        ]
        preceding_flight = [
            event for event in preceding_frames
            if str((event.get("movement") or {}).get("mode", "walk")) == "fly"
        ]
        committed = _first_event(events, "edit_committed", cause_id)
        stage_rows = stage_window(replacement_events, origin_ns)
        gaps = []
        previous_end = 0.0
        for row in stage_rows:
            current_end = max(previous_end, float(row["end_ms"]))
            gaps.append({
                "stage": row["stage"],
                "wait_from_previous_stage_ms": max(
                    0.0, float(row["start_ms"]) - previous_end
                ),
                "stage_end_ms": current_end,
            })
            previous_end = current_end
        dominant_gap = max(
            gaps, key=lambda item: float(item["wait_from_previous_stage_ms"]),
            default={"stage": "unattributed", "wait_from_previous_stage_ms": 0.0},
        )
        if blocker_event is not None and batch_event is not None:
            blocker_wait = (
                int(batch_event.get("elapsed_ns", ready_ns)) - ready_ns
            ) / 1_000_000.0
            if blocker_wait > float(dominant_gap["wait_from_previous_stage_ms"]):
                dominant_gap = {
                    "stage": "visibility_staging",
                    "wait_from_previous_stage_ms": blocker_wait,
                }
        final_event = batch_event or ready_event or _last_event(
            replacement_events, {"render_sink_applied", "collision_sink_applied"}
        ) or committed
        completion_ms = (
            (int(final_event.get("elapsed_ns", origin_ns)) - origin_ns) / 1_000_000.0
            if final_event is not None else None
        )
        reports.append({
            "index": index + 1,
            "mode": str((request.get("payload") or {}).get("mode", "unknown")),
            "center": (request.get("payload") or {}).get("center"),
            "native_cause_id": cause_id,
            "request_elapsed_ms": request_elapsed_us / 1000.0,
            "target_generation_before": target_generation_before,
            "replacement_count": len(replacement_identities),
            "relocation_distance_from_previous_edit": relocation_distance,
            "relocated_area": relocation_distance is not None and relocation_distance >= EDIT_RELOCATION_DISTANCE,
            "preceding_flight_frames": len(preceding_flight),
            "preceding_flight_distance": sum(
                float((event.get("movement") or {}).get("distance", 0.0))
                for event in preceding_flight
            ),
            "preceding_blocked_movement_frames": sum(
                1 for event in preceding_frames
                if (event.get("movement") or {}).get("accepted") is False
            ),
            "authority_commit_ms": (
                (int(committed.get("elapsed_ns", origin_ns)) - origin_ns) / 1_000_000.0
                if committed is not None else None
            ),
            "target_visual_ready_ms": (
                (int(target_visual_frame.get("elapsed_us", request_elapsed_us)) - request_elapsed_us) / 1000.0
                if target_visual_frame is not None else None
            ),
            "target_collision_ready_ms": (
                (int(target_collision_frame.get("elapsed_us", request_elapsed_us)) - request_elapsed_us) / 1000.0
                if target_collision_frame is not None else None
            ),
            "pipeline_completion_ms": completion_ms,
            "visibility_wait_after_replacements_ms": (
                (int(batch_event.get("elapsed_ns", ready_ns)) - ready_ns) / 1_000_000.0
                if batch_event is not None and ready_event is not None else None
            ),
            "visibility_blocker": None if blocker_event is None else {
                "pending_chunk_replacements": int(blocker_event.get("cause_id", 0)),
                "pending_chunk_retirements": int(blocker_event.get("auxiliary", 0)),
                "pending_render_retirements": int(blocker_event.get("status", 0)),
            },
            "dominant_wait": dominant_gap,
            "waterfall": stage_rows,
            "complete": committed is not None and bool(replacement_identities) and final_event is not None,
        })
    return reports


def _cpu_sample_summary(samples: list[dict[str, Any]], capacity: int) -> dict[str, Any]:
    cpu = [float(sample.get("process_cpu_percent", 0.0)) for sample in samples if isinstance(sample, dict)]
    saturation_threshold = capacity * 100.0 * 0.85
    return {
        "available": True,
        "logical_cpu_capacity": capacity,
        "sample_count": len(cpu),
        "process_cpu_percent_mean": statistics.fmean(cpu) if cpu else 0.0,
        "process_cpu_percent_p95": percentile(cpu, 0.95),
        "process_cpu_percent_maximum": max(cpu, default=0.0),
        "average_active_logical_cores": (
            statistics.fmean(cpu) / 100.0 if cpu else 0.0
        ),
        "saturated_sample_fraction": (
            sum(value >= saturation_threshold for value in cpu) / len(cpu)
            if cpu else 0.0
        ),
    }


def usage_analysis(usage: dict[str, Any] | None) -> dict[str, Any]:
    if usage is None:
        return {"available": False}
    samples_value = usage.get("samples")
    samples = samples_value if isinstance(samples_value, list) else []
    capacity = max(1, int(usage.get("logical_cpu_capacity", 1)))
    return {
        **_cpu_sample_summary(samples, capacity),
        "logical_cpu_affinity": usage.get("logical_cpu_affinity", []),
        "rss_bytes_maximum": int(usage.get("rss_bytes_maximum", 0)),
        "wall_seconds": float(usage.get("wall_seconds", 0.0)),
    }


def usage_window_analysis(
    usage: dict[str, Any] | None,
    start_unix_seconds: float,
    end_unix_seconds: float,
) -> dict[str, Any]:
    if usage is None or end_unix_seconds < start_unix_seconds:
        return {"available": False}
    samples_value = usage.get("samples")
    samples = samples_value if isinstance(samples_value, list) else []
    selected = [
        sample for sample in samples
        if isinstance(sample, dict)
        and start_unix_seconds <= float(sample.get("unix_time_seconds", -1.0))
        <= end_unix_seconds
    ]
    if not selected:
        return {"available": False}
    capacity = max(1, int(usage.get("logical_cpu_capacity", 1)))
    return {
        **_cpu_sample_summary(selected, capacity),
        "window_start_unix_seconds": start_unix_seconds,
        "window_end_unix_seconds": end_unix_seconds,
    }


def trace_report(path: pathlib.Path) -> dict[str, Any]:
    trace = load_object(path)
    if trace.get("schema") != TRACE_SCHEMA:
        raise RuntimeError(f"unsupported trace schema in {path}: {trace.get('schema')}")
    native = trace.get("native")
    if not isinstance(native, dict) or not isinstance(native.get("events"), list):
        raise RuntimeError(f"native event stream missing: {path}")
    downstream_events = [event for event in trace.get("events", []) if isinstance(event, dict)]
    native_events = [event for event in native["events"] if isinstance(event, dict)]
    frames = frame_analysis(downstream_events, native_events)
    edits = edit_analysis(downstream_events, native_events)
    observer = trace.get("observer") if isinstance(trace.get("observer"), dict) else {}
    duration_us = max(1, int(trace.get("duration_us", 1)))
    integrity = {
        "final": trace.get("final") is True,
        "native_complete": native.get("complete") is True,
        "native_source_overwrite_count": int(native.get("source_overwrite_count", -1)),
        "native_consumer_gap_event_count": int(native.get("consumer_gap_event_count", -1)),
        "native_local_dropped_event_count": int(native.get("local_dropped_event_count", -1)),
        "downstream_dropped_event_count": int(trace.get("dropped_event_count", -1)),
    }
    # This counter is cumulative and also advances when an already-consumed
    # source-ring slot is reused. Only a consumer sequence gap proves that ring
    # rotation overtook the trace drain and lost evidence.
    integrity["native_source_overwrite_implied_loss"] = (
        integrity["native_consumer_gap_event_count"] > 0
    )
    integrity["complete"] = all([
        integrity["final"],
        integrity["native_complete"],
        integrity["native_consumer_gap_event_count"] == 0,
        integrity["native_local_dropped_event_count"] == 0,
        integrity["downstream_dropped_event_count"] == 0,
    ])
    return {
        "path": str(path),
        "reason": trace.get("reason"),
        "started_unix_ms": int(trace.get("started_unix_ms", 0)),
        "duration_seconds": duration_us / 1_000_000.0,
        "integrity": integrity,
        "observer": {
            **observer,
            "record_capture_wall_fraction": (
                float(observer.get("capture_time_us_total", 0)) / duration_us
            ),
            "pipeline_capture_wall_fraction": (
                float(observer.get("pipeline_capture_time_us_total", 0)) / duration_us
            ),
            "native_drain_wall_fraction": (
                float(native.get("capture_time_us_total", 0)) / duration_us
            ),
            "fractions_are_non_additive": True,
            "trace_is_performance_baseline": False,
        },
        "stage_usage": stage_usage(native_events),
        "movement": frames,
        "edits": edits,
        "coverage": {
            "has_movement": frames["movement_frame_count"] > 0,
            "has_flight": frames["flight_frame_count"] > 0,
            "has_long_flight": frames["flight_distance"] >= LONG_RELOCATION_DISTANCE,
            "has_edit": bool(edits),
            "has_relocated_edit": any(edit["relocated_area"] for edit in edits),
            "has_carve": any(edit["mode"] in {"carve", "remove_static_water"} for edit in edits),
            "has_construction": any(edit["mode"] in {"construct", "place", "place_static_water"} for edit in edits),
        },
    }


def decision_for(traces: list[dict[str, Any]], usage: dict[str, Any]) -> dict[str, Any]:
    integrity = all(trace["integrity"]["complete"] for trace in traces)
    coverage = {
        key: any(trace["coverage"][key] for trace in traces)
        for key in traces[0]["coverage"]
    } if traces else {}
    edits = [edit for trace in traces for edit in trace["edits"]]
    relocation_edits = [edit for edit in edits if edit["relocated_area"]]
    frame_p99 = max(
        (float(trace["movement"]["frame_ms"]["p99"]) for trace in traces),
        default=0.0,
    )
    maximum_edit_ms = max(
        (
            float(edit["pipeline_completion_ms"])
            for edit in relocation_edits
            if edit["pipeline_completion_ms"] is not None
        ),
        default=0.0,
    )
    required_coverage = all(
        coverage.get(key, False)
        for key in ("has_long_flight", "has_relocated_edit", "has_carve", "has_construction")
    )
    active_cores = float(usage.get("average_active_logical_cores", 0.0))
    capacity = float(usage.get("logical_cpu_capacity", 0.0))
    saturated_fraction = float(usage.get("saturated_sample_fraction", 0.0))
    delayed_edit_windows = [
        edit.get("process_usage_during_pipeline", {})
        for edit in relocation_edits
        if float(edit.get("pipeline_completion_ms") or 0.0) > 100.0
    ]
    complete_edit_windows = [
        window for window in delayed_edit_windows
        if window.get("available") is True and int(window.get("sample_count", 0)) >= 2
    ]
    edit_window_usage_complete = (
        bool(delayed_edit_windows)
        and len(complete_edit_windows) == len(delayed_edit_windows)
    )
    edit_window_saturation = [
        float(window.get("saturated_sample_fraction", 0.0))
        for window in complete_edit_windows
    ]
    if not integrity:
        classification = "TRACE_INVALID_OR_INCOMPLETE"
        finding = "The retained ordering stream has a loss or finalization failure."
    elif not required_coverage:
        classification = "EVIDENCE_INCOMPLETE_REPEAT_HUMAN_ROUTE"
        finding = (
            "The session did not yet include long flight plus relocated carve and "
            "construction, so it cannot close CPU exhaustion or GPU eligibility."
        )
    elif frame_p99 <= HITCH_THRESHOLD_MS and maximum_edit_ms <= 100.0:
        classification = "ORDER_ACCEPTABLE_CONFIRM_WITH_TRACE_OFF_BASELINE"
        finding = (
            "The traced route did not retain a material movement or relocated-edit "
            "delay; confirm performance with tracing disabled."
        )
    elif edit_window_usage_complete and min(edit_window_saturation) < 0.50:
        classification = "CPU_PATH_NOT_EXHAUSTED_STANDARD_REMEDIATION_REMAINS"
        finding = (
            "At least one delayed relocated-edit window did not sustain the bounded "
            "CPU capacity. Queue ordering, readiness, and publication remain candidates "
            "before a GPU architecture decision."
        )
    elif edit_window_usage_complete and min(edit_window_saturation) >= 0.50:
        classification = "GPU_REVIEW_ELIGIBLE_NOT_SELECTED"
        finding = (
            "Every delayed relocated-edit window saturated the three-logical-CPU "
            "envelope for at least half its samples. A trace-off paired run and "
            "stage-specific remedy audit are still required before selecting GPU work."
        )
    elif capacity > 0.0 and active_cores < capacity * 0.80:
        classification = "CPU_PATH_NOT_EXHAUSTED_STANDARD_REMEDIATION_REMAINS"
        finding = (
            "Observed delays occurred without sustained use of the bounded CPU "
            "capacity. Queue ordering, readiness, and publication remain candidates "
            "before a GPU architecture decision."
        )
    elif saturated_fraction >= 0.50:
        classification = "GPU_REVIEW_ELIGIBLE_NOT_SELECTED"
        finding = (
            "The covered route retained delays while the three-logical-CPU envelope "
            "was saturated for at least half the samples. A trace-off paired run and "
            "stage-specific remedy audit are still required before selecting GPU work."
        )
    else:
        classification = "CPU_ATTRIBUTION_OR_STANDARD_REMEDIATION_REMAINS"
        finding = (
            "The route is covered, but evidence does not establish sustained CPU "
            "exhaustion. Use the dominant waterfall gaps before considering GPU work."
        )
    return {
        "classification": classification,
        "finding": finding,
        "trace_integrity_complete": integrity,
        "required_human_route_covered": required_coverage,
        "combined_coverage": coverage,
        "relocated_edit_count": len(relocation_edits),
        "maximum_relocated_edit_pipeline_ms": maximum_edit_ms,
        "maximum_trace_frame_p99_ms": frame_p99,
        "edit_window_usage_complete": edit_window_usage_complete,
        "edit_window_saturated_fraction_minimum": (
            min(edit_window_saturation) if edit_window_saturation else None
        ),
        "edit_window_saturated_fraction_maximum": (
            max(edit_window_saturation) if edit_window_saturation else None
        ),
        "gpu_architecture_selected": False,
        "claim_boundary": (
            "Causal ordering and queue attribution are valid only when trace integrity "
            "is complete. Trace-on timing is intrusive and is never the release "
            "performance baseline."
        ),
    }


def build_session_report(
    trace_paths: list[pathlib.Path], usage_path: pathlib.Path | None = None
) -> dict[str, Any]:
    usage_raw = load_object(usage_path.resolve()) if usage_path and usage_path.is_file() else None
    traces = [trace_report(path.resolve()) for path in trace_paths]
    for trace in traces:
        trace_started_unix = float(trace.get("started_unix_ms", 0)) / 1000.0
        if trace_started_unix <= 0.0:
            trace["process_usage_during_trace"] = {"available": False}
            continue
        trace["process_usage_during_trace"] = usage_window_analysis(
            usage_raw,
            trace_started_unix,
            trace_started_unix + float(trace.get("duration_seconds", 0.0)),
        )
        for edit in trace["edits"]:
            request_unix = trace_started_unix + float(edit["request_elapsed_ms"]) / 1000.0
            completion_ms = edit.get("pipeline_completion_ms")
            if completion_ms is None:
                edit["process_usage_during_pipeline"] = {"available": False}
                continue
            edit["process_usage_during_pipeline"] = usage_window_analysis(
                usage_raw,
                request_unix,
                request_unix + float(completion_ms) / 1000.0,
            )
    usage = usage_analysis(usage_raw)
    return {
        "schema": REPORT_SCHEMA,
        "purpose": (
            "optional human movement, flight, relocation-edit, and terrain-pipeline "
            "ordering attribution"
        ),
        "trace_count": len(traces),
        "traces": traces,
        "process_usage": usage,
        "decision": decision_for(traces, usage),
        "authoritative_for": [
            "ordered native CPU terrain lifecycle events retained without loss",
            "sampled Godot movement acceptance and queue state",
            "per-edit stage ordering and observed dominant waits",
            "process CPU use inside the configured three-logical-CPU envelope",
        ],
        "not_authoritative_for": [
            "trace-off release performance",
            "GPU performance or wattage",
            "GPU architecture selection by itself",
            "unobserved engine or operating-system stalls",
        ],
    }


def summary_text(report: dict[str, Any]) -> str:
    decision = report["decision"]
    usage = report["process_usage"]
    lines = [
        "World Transvoxel Terrain Waterfall",
        "===================================",
        f"Decision: {decision['classification']}",
        f"Finding: {decision['finding']}",
        "",
        f"Trace integrity complete: {decision['trace_integrity_complete']}",
        f"Required human route covered: {decision['required_human_route_covered']}",
        f"Relocated edits: {decision['relocated_edit_count']}",
        f"Maximum relocated edit pipeline: {decision['maximum_relocated_edit_pipeline_ms']:.3f} ms",
        f"Maximum traced frame p99: {decision['maximum_trace_frame_p99_ms']:.3f} ms",
    ]
    if usage.get("available"):
        lines.extend([
            f"Average active logical CPU cores: {usage['average_active_logical_cores']:.3f}",
            f"CPU p95: {usage['process_cpu_percent_p95']:.1f}% of one logical core",
            f"Saturated sample fraction: {usage['saturated_sample_fraction']:.3f}",
        ])
    for trace in report["traces"]:
        lines.extend([
            "",
            f"Trace: {trace['path']}",
            f"Flight distance: {trace['movement']['flight_distance']:.3f}",
            f"Blocked flight frames: {trace['movement']['blocked_flight_frame_count']}",
            f"Frame p99/max: {trace['movement']['frame_ms']['p99']:.3f} / {trace['movement']['frame_ms']['maximum']:.3f} ms",
        ])
        for edit in trace["edits"]:
            edit_usage = edit.get("process_usage_during_pipeline", {})
            usage_text = "cpu-window=n/a"
            if edit_usage.get("available"):
                usage_text = "cpu-window={cores:.2f} cores saturated={saturated:.3f}".format(
                    cores=float(edit_usage["average_active_logical_cores"]),
                    saturated=float(edit_usage["saturated_sample_fraction"]),
                )
            lines.append(
                "Edit {index} {mode}: relocation={distance} m completion={completion} ms dominant={dominant} {usage}".format(
                    index=edit["index"],
                    mode=edit["mode"],
                    distance=(
                        "n/a" if edit["relocation_distance_from_previous_edit"] is None
                        else f"{edit['relocation_distance_from_previous_edit']:.3f}"
                    ),
                    completion=(
                        "incomplete" if edit["pipeline_completion_ms"] is None
                        else f"{edit['pipeline_completion_ms']:.3f}"
                    ),
                    dominant=edit["dominant_wait"]["stage"],
                    usage=usage_text,
                )
            )
    lines.extend([
        "",
        "Timing warning: tracing is intentionally intrusive. Use this report for order and attribution, then run trace-off comparisons for performance.",
    ])
    return "\n".join(lines) + "\n"


def write_report(
    report: dict[str, Any], output: pathlib.Path, summary_output: pathlib.Path
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    summary_output.write_text(summary_text(report), encoding="utf-8")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace", action="append", required=True)
    parser.add_argument("--usage")
    parser.add_argument("--output", required=True)
    parser.add_argument("--summary-output")
    args = parser.parse_args(argv)
    output = pathlib.Path(args.output).resolve()
    summary = (
        pathlib.Path(args.summary_output).resolve()
        if args.summary_output else output.with_suffix(".txt")
    )
    report = build_session_report(
        [pathlib.Path(path) for path in args.trace],
        pathlib.Path(args.usage) if args.usage else None,
    )
    write_report(report, output, summary)
    print(
        "WT_TERRAIN_WATERFALL_REPORT "
        f"decision={report['decision']['classification']} output={output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
