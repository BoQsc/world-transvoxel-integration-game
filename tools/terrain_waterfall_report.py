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
CHUNK_SIZE = 16.0
CHUNK_CELLS_PER_AXIS = 16

STAGE_BY_KIND = {
    "viewer_plan_started": "viewer",
    "viewer_plan_applied": "viewer",
    "viewer_plan_cancelled": "viewer",
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
    "visibility_coverage_priority_outcome": "visibility",
    "visibility_region_replacement_member": "visibility",
    "visibility_region_retirement_member": "visibility",
    "visibility_region_desired_snapshot": "visibility",
    "transition_remesh_generation_created": "visibility",
    "readiness_repair_generation_created": "visibility",
    "scheduler_job_queued": "scheduler",
    "scheduler_job_priority_observed": "scheduler",
    "scheduler_job_dequeued": "scheduler",
    "page_meshing_ownership_established": "sampling",
}

PRIORITY_OUTCOME_BY_STATUS = {
    0: "APPLIED",
    1: "SCHEDULER_GENERATION_STALE",
    2: "SCHEDULER_REPRIORITIZE_FAILED",
    3: "PAGE_GENERATION_STALE",
    4: "SCHEDULER_APPLIED_PAGE_RECORD_NOT_FOUND",
}
SCHEDULER_APPLIED_PRIORITY_OUTCOMES = {0, 3, 4}

PIPELINE_ORDER = (
    "viewer",
    "authority",
    "demand",
    "scheduler",
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


ChunkKey = tuple[int, int, int, int]


def chunk_bounds(key: ChunkKey) -> tuple[tuple[int, int, int], tuple[int, int, int]]:
    extent = CHUNK_CELLS_PER_AXIS << key[3]
    minimum = tuple(key[axis] * extent for axis in range(3))
    return minimum, tuple(minimum[axis] + extent for axis in range(3))


def chunk_bounds_overlap(left: ChunkKey, right: ChunkKey) -> bool:
    left_minimum, left_maximum = chunk_bounds(left)
    right_minimum, right_maximum = chunk_bounds(right)
    return all(
        left_minimum[axis] < right_maximum[axis]
        and right_minimum[axis] < left_maximum[axis]
        for axis in range(3)
    )


def chunk_bounds_share_face(left: ChunkKey, right: ChunkKey) -> bool:
    if chunk_bounds_overlap(left, right):
        return False
    left_minimum, left_maximum = chunk_bounds(left)
    right_minimum, right_maximum = chunk_bounds(right)
    for face_axis in range(3):
        if left_maximum[face_axis] != right_minimum[face_axis] and \
                right_maximum[face_axis] != left_minimum[face_axis]:
            continue
        other_axes = [axis for axis in range(3) if axis != face_axis]
        if all(
            left_minimum[axis] < right_maximum[axis]
            and right_minimum[axis] < left_maximum[axis]
            for axis in other_axes
        ):
            return True
    return False


def chunk_bounds_contains(outer: ChunkKey, inner: ChunkKey) -> bool:
    outer_minimum, outer_maximum = chunk_bounds(outer)
    inner_minimum, inner_maximum = chunk_bounds(inner)
    return all(
        outer_minimum[axis] <= inner_minimum[axis]
        and inner_maximum[axis] <= outer_maximum[axis]
        for axis in range(3)
    )


def child_chunk_keys(parent: ChunkKey) -> Iterable[ChunkKey]:
    if parent[3] == 0:
        return
    child_lod = parent[3] - 1
    for child_z in range(2):
        for child_y in range(2):
            for child_x in range(2):
                yield (
                    parent[0] * 2 + child_x,
                    parent[1] * 2 + child_y,
                    parent[2] * 2 + child_z,
                    child_lod,
                )


def replacement_set_covers(target: ChunkKey, replacements: set[ChunkKey]) -> bool:
    if any(chunk_bounds_contains(replacement, target) for replacement in replacements):
        return True
    if target[3] == 0:
        return False
    for child in child_chunk_keys(target):
        if not any(chunk_bounds_overlap(child, replacement) for replacement in replacements):
            return False
        if not replacement_set_covers(child, replacements):
            return False
    return True


def publication_component_audit(
    replacements: set[ChunkKey], retirements: set[ChunkKey]
) -> dict[str, Any]:
    """Mirror the authority's overlap and unsafe-LOD-face component rule."""
    nodes = {
        *(("replacement", key) for key in replacements),
        *(("retirement", key) for key in retirements),
    }
    adjacency = {node: set() for node in nodes}
    overlap_edges = 0
    unsafe_lod_boundary_edges = 0
    for replacement in replacements:
        replacement_node = ("replacement", replacement)
        for retirement in retirements:
            if chunk_bounds_overlap(replacement, retirement):
                overlap_edges += 1
            elif abs(replacement[3] - retirement[3]) > 1 and \
                    chunk_bounds_share_face(replacement, retirement):
                unsafe_lod_boundary_edges += 1
            else:
                continue
            retirement_node = ("retirement", retirement)
            adjacency[replacement_node].add(retirement_node)
            adjacency[retirement_node].add(replacement_node)

    component_sizes: list[int] = []
    unseen = set(nodes)
    while unseen:
        stack = [unseen.pop()]
        size = 0
        while stack:
            node = stack.pop()
            size += 1
            connected = adjacency[node] & unseen
            unseen.difference_update(connected)
            stack.extend(connected)
        component_sizes.append(size)
    component_sizes.sort(reverse=True)

    overlapping_replacement_pairs = 0
    ordered_replacements = sorted(replacements)
    for index, left in enumerate(ordered_replacements):
        overlapping_replacement_pairs += sum(
            chunk_bounds_overlap(left, right)
            for right in ordered_replacements[index + 1:]
        )
    duplicate_role_keys = replacements & retirements
    uncovered_retirements = sorted(
        retirement for retirement in retirements
        if not replacement_set_covers(retirement, replacements)
    )
    connected = bool(nodes) and len(component_sizes) == 1
    complete_coverage = bool(replacements) and bool(retirements) and \
        not uncovered_retirements
    valid_ownership = not overlapping_replacement_pairs and not duplicate_role_keys
    minimal_under_authority_rule = connected and complete_coverage and valid_ownership
    if minimal_under_authority_rule:
        classification = "MINIMAL_UNDER_AUTHORITY_COMPONENT_RULE"
    elif not connected:
        classification = "REGION_CONTAINS_DISCONNECTED_COMPONENTS"
    elif not complete_coverage:
        classification = "REGION_HAS_INCOMPLETE_RETIREMENT_COVERAGE"
    else:
        classification = "REGION_HAS_INVALID_REPLACEMENT_OWNERSHIP"
    return {
        "available": True,
        "classification": classification,
        "minimal_under_authority_rule": minimal_under_authority_rule,
        "replacement_count": len(replacements),
        "retirement_count": len(retirements),
        "component_count": len(component_sizes),
        "component_sizes": component_sizes,
        "overlap_edge_count": overlap_edges,
        "unsafe_lod_boundary_edge_count": unsafe_lod_boundary_edges,
        "total_edge_count": overlap_edges + unsafe_lod_boundary_edges,
        "maximum_node_degree": max(map(len, adjacency.values()), default=0),
        "isolated_node_count": sum(not neighbors for neighbors in adjacency.values()),
        "overlapping_replacement_pair_count": overlapping_replacement_pairs,
        "duplicate_role_key_count": len(duplicate_role_keys),
        "uncovered_retirement_count": len(uncovered_retirements),
        "uncovered_retirements": [
            {"x": key[0], "y": key[1], "z": key[2], "lod": key[3]}
            for key in uncovered_retirements[:16]
        ],
        "claim_boundary": (
            "Minimal means this exact cohort is one complete connected component "
            "under the authority policy: volume-overlap ownership plus face "
            "neighbors required to avoid an LOD gap above one. It does not prove "
            "that the policy itself is the only possible crack-free publication "
            "architecture or that this cohort is globally latency-optimal."
        ),
    }


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


def sampled_blocker_analysis(
    frames: list[dict[str, Any]],
    replacement_identities: set[tuple[int, int, int, int, int]],
    request_elapsed_us: int,
) -> dict[str, Any]:
    replacement_keys = {identity[:4] for identity in replacement_identities}
    samples = []
    transitions = []
    last_signature = None
    for event in frames:
        metrics = metrics_from_event(event)
        blocked = int(metrics.get("blocked_pending_chunk_replacements", 0))
        if blocked <= 0:
            continue
        key = tuple(int(metrics.get(name, 0)) for name in (
            "first_blocked_replacement_key_x",
            "first_blocked_replacement_key_y",
            "first_blocked_replacement_key_z",
            "first_blocked_replacement_key_lod",
        ))
        if bool(metrics.get("first_blocked_replacement_missing", False)):
            reason = "record_missing"
        elif (
            bool(metrics.get("first_blocked_replacement_visual_required", False))
            and not bool(metrics.get("first_blocked_replacement_visual_ready", False))
        ):
            reason = "visual_not_ready"
        elif (
            bool(metrics.get("first_blocked_replacement_collision_required", False))
            and not bool(metrics.get("first_blocked_replacement_collision_ready", False))
        ):
            reason = "collision_not_ready"
        else:
            reason = "application_or_sink_not_ready"
        relation = "edit_replacement" if key in replacement_keys else "other_replacement"
        sample = {
            "elapsed_from_request_ms": (
                int(event.get("elapsed_us", request_elapsed_us)) - request_elapsed_us
            ) / 1000.0,
            "key": {"x": key[0], "y": key[1], "z": key[2], "lod": key[3]},
            "generation": int(metrics.get("first_blocked_replacement_generation", 0)),
            "reason": reason,
            "relation": relation,
            "blocked_count": blocked,
            "pending_replacements": int(metrics.get("pending_chunk_replacements", 0)),
            "pending_retirements": int(metrics.get("pending_chunk_retirements", 0)),
            "ready_staged_replacements": int(metrics.get("ready_staged_chunk_replacements", 0)),
            "visibility_priority_pending": int(metrics.get("visibility_coverage_priority_pending", 0)),
        }
        samples.append(sample)
        signature = (key, sample["generation"], reason, relation)
        if signature != last_signature and len(transitions) < 32:
            transitions.append(sample)
            last_signature = signature
    if not samples:
        return {"available": False, "sample_count": 0, "transitions": []}
    reason_counts = Counter(sample["reason"] for sample in samples)
    relation_counts = Counter(sample["relation"] for sample in samples)
    key_counts = Counter(
        (sample["key"]["x"], sample["key"]["y"], sample["key"]["z"], sample["key"]["lod"])
        for sample in samples
    )
    dominant_key = key_counts.most_common(1)[0][0]
    return {
        "available": True,
        "sample_count": len(samples),
        "first_sample_ms": samples[0]["elapsed_from_request_ms"],
        "last_sample_ms": samples[-1]["elapsed_from_request_ms"],
        "distinct_first_blocker_keys": len(key_counts),
        "dominant_key": {
            "x": dominant_key[0], "y": dominant_key[1],
            "z": dominant_key[2], "lod": dominant_key[3],
        },
        "dominant_reason": reason_counts.most_common(1)[0][0],
        "dominant_relation": relation_counts.most_common(1)[0][0],
        "edit_replacement_sample_fraction": (
            relation_counts["edit_replacement"] / len(samples)
        ),
        "peak_blocked_count": max(sample["blocked_count"] for sample in samples),
        "peak_pending_replacements": max(
            sample["pending_replacements"] for sample in samples
        ),
        "transitions": transitions,
    }


def regional_publication_analysis(
    events: list[dict[str, Any]],
    all_native_events: list[dict[str, Any]],
    replacement_identities: set[tuple[int, int, int, int, int]],
    origin_ns: int,
    ready_ns: int,
    batch_event: dict[str, Any] | None,
) -> dict[str, Any]:
    if batch_event is None:
        return {
            "available": False,
            "classification": "NO_POST_REPLACEMENT_VISIBILITY_BATCH",
            "exact_membership_available": False,
        }
    batch_ns = int(batch_event.get("elapsed_ns", ready_ns))
    replacement_count = int(batch_event.get("cause_id", 0))
    retirement_count = int(batch_event.get("auxiliary", 0))
    regional = int(batch_event.get("status", 0)) == 1
    cohort_id = int(batch_event.get("generation", 0))
    replacement_keys = {identity[:4] for identity in replacement_identities}
    replacement_member_events = [
        event for event in events
        if event.get("kind") == "visibility_region_replacement_member"
        and int(event.get("cause_id", 0)) == cohort_id
        and int(event.get("elapsed_ns", -1)) <= batch_ns
    ] if cohort_id > 0 else []
    retirement_member_events = [
        event for event in events
        if event.get("kind") == "visibility_region_retirement_member"
        and int(event.get("cause_id", 0)) == cohort_id
        and int(event.get("elapsed_ns", -1)) <= batch_ns
    ] if cohort_id > 0 else []
    replacement_members = {
        identity for event in replacement_member_events
        if (identity := native_identity(event)) is not None
    }
    retirement_members = {
        identity[:4] for event in retirement_member_events
        if (identity := native_identity(event)) is not None
    }
    exact_membership = (
        cohort_id > 0
        and len(replacement_members) == replacement_count
        and len(retirement_members) == retirement_count
    )
    component_audit = (
        publication_component_audit(
            {identity[:4] for identity in replacement_members},
            retirement_members,
        )
        if exact_membership else {
            "available": False,
            "classification": "EXACT_MEMBERSHIP_REQUIRED",
            "minimal_under_authority_rule": False,
        }
    )
    desired_snapshot_events = [
        event for event in events
        if event.get("kind") == "visibility_region_desired_snapshot"
        and int(event.get("generation", 0)) == cohort_id
        and int(event.get("elapsed_ns", -1)) <= batch_ns
    ] if cohort_id > 0 else []
    desired_snapshot = (
        max(
            desired_snapshot_events,
            key=lambda event: int(event.get("elapsed_ns", 0)),
        )
        if desired_snapshot_events else None
    )
    desired_status_by_identity = {
        identity: int(event.get("status", 0))
        for event in replacement_member_events
        if (identity := native_identity(event)) is not None
    }
    required_member_count = sum(
        1 for status in desired_status_by_identity.values() if status & 0x3
    )
    visual_required_member_count = sum(
        1 for status in desired_status_by_identity.values() if status & 0x1
    )
    collision_required_member_count = sum(
        1 for status in desired_status_by_identity.values() if status & 0x2
    )
    staged_member_count = sum(
        1 for status in desired_status_by_identity.values() if status & 0x4
    )
    fully_ready_member_count = sum(
        1 for status in desired_status_by_identity.values() if status & 0x8
    )
    desired_snapshot_exact = len(desired_snapshot_events) == 1
    open_viewer_plans = (
        int(desired_snapshot.get("auxiliary", -1))
        if desired_snapshot is not None else None
    )
    latest_completed_viewer_plan = (
        int(desired_snapshot.get("cause_id", 0))
        if desired_snapshot is not None else None
    )
    exact_latest_drained_ownership = (
        exact_membership
        and desired_snapshot_exact
        and open_viewer_plans == 0
        and required_member_count == replacement_count
        and fully_ready_member_count == replacement_count
    )
    if not desired_snapshot_events:
        desired_ownership_classification = "DESIRED_SNAPSHOT_NOT_RETAINED"
    elif not desired_snapshot_exact:
        desired_ownership_classification = "DESIRED_SNAPSHOT_AMBIGUOUS"
    elif not exact_membership:
        desired_ownership_classification = "COHORT_MEMBERSHIP_INCOMPLETE"
    elif open_viewer_plans != 0:
        desired_ownership_classification = "VIEWER_PLAN_PUBLICATION_OPEN"
    elif required_member_count != replacement_count:
        desired_ownership_classification = "COHORT_CONTAINS_UNREQUIRED_REPLACEMENT"
    elif fully_ready_member_count != replacement_count:
        desired_ownership_classification = "COHORT_CONTAINS_NOT_READY_REPLACEMENT"
    else:
        desired_ownership_classification = "EXACT_LATEST_DRAINED_PLAN_OWNERSHIP"
    edit_members = replacement_members & replacement_identities
    all_edit_replacements_included = (
        bool(replacement_identities)
        and replacement_identities <= replacement_members
    )
    priority_events = [
        event for event in events
        if event.get("kind") == "visibility_coverage_priority_requested"
        and origin_ns <= int(event.get("elapsed_ns", -1)) <= batch_ns
        and int(event.get("cause_id", -1)) == replacement_count
        and int(event.get("auxiliary", -1)) == retirement_count
    ]
    priority_identities = {
        identity for event in priority_events
        if (identity := native_identity(event)) is not None
    }
    priority_keys = {identity[:4] for identity in priority_identities}
    priority_edit_keys = priority_keys & replacement_keys
    viewer_plan_times = {
        int(event.get("cause_id", 0)): int(event.get("elapsed_ns", 0))
        for event in all_native_events
        if event.get("kind") == "viewer_plan_started"
        and int(event.get("elapsed_ns", -1)) <= batch_ns
    }
    demand_events_by_identity: dict[
        tuple[int, int, int, int, int], list[dict[str, Any]]
    ] = defaultdict(list)
    for event in all_native_events:
        if event.get("kind") != "chunk_demand_accepted" or \
                int(event.get("elapsed_ns", -1)) > batch_ns:
            continue
        identity = native_identity(event)
        if identity is not None:
            demand_events_by_identity[identity].append(event)
    viewer_origin_counts: Counter[int] = Counter()
    unmatched_non_edit_members = 0
    for identity in replacement_members - edit_members:
        matching = [
            event for event in demand_events_by_identity.get(identity, [])
            if int(event.get("cause_id", 0)) in viewer_plan_times
        ]
        if not matching:
            unmatched_non_edit_members += 1
            continue
        latest_demand = max(
            matching, key=lambda event: int(event.get("elapsed_ns", 0))
        )
        viewer_origin_counts[int(latest_demand.get("cause_id", 0))] += 1
    plans_before_edit = [
        cause for cause, elapsed_ns in viewer_plan_times.items()
        if elapsed_ns < origin_ns
    ]
    latest_plan_before_edit = max(
        plans_before_edit,
        key=lambda cause: viewer_plan_times[cause],
        default=None,
    )
    latest_plan_before_publication = max(
        viewer_plan_times,
        key=lambda cause: viewer_plan_times[cause],
        default=None,
    )
    older_origin_members = (
        sum(
            count for cause, count in viewer_origin_counts.items()
            if viewer_plan_times[cause] < viewer_plan_times[latest_plan_before_edit]
        )
        if latest_plan_before_edit is not None else 0
    )
    additional_replacements = (
        len(replacement_members - edit_members)
        if exact_membership else max(0, replacement_count - len(replacement_identities))
    )
    broad = regional and additional_replacements >= 32
    if exact_membership and not all_edit_replacements_included:
        classification = "EXACT_BATCH_DOES_NOT_CONTAIN_ALL_EDIT_REPLACEMENTS"
    elif broad and exact_membership:
        classification = "BROAD_REGIONAL_BATCH_CONTAINS_EDIT_REPLACEMENTS"
    elif regional and exact_membership:
        classification = "BOUNDED_REGIONAL_BATCH_CONTAINS_EDIT_REPLACEMENTS"
    elif broad:
        classification = "BROAD_REGIONAL_BATCH_CORRELATED_WITH_EDIT_ACTIVATION"
    elif regional:
        classification = "BOUNDED_REGIONAL_BATCH_CORRELATED_WITH_EDIT_ACTIVATION"
    else:
        classification = "GLOBAL_BATCH_CORRELATED_WITH_EDIT_ACTIVATION"
    return {
        "available": True,
        "classification": classification,
        "regional": regional,
        "cohort_id": cohort_id,
        "replacement_count": replacement_count,
        "retirement_count": retirement_count,
        "edit_replacement_count": len(replacement_identities),
        "edit_replacement_members": len(edit_members),
        "all_edit_replacements_included": all_edit_replacements_included,
        "additional_replacements": additional_replacements,
        "coverage_priority_requested_count": len(priority_events),
        "coverage_priority_unique_key_count": len(priority_keys),
        "coverage_priority_edit_key_count": len(priority_edit_keys),
        "coverage_priority_other_key_count": len(priority_keys - replacement_keys),
        "non_edit_origin": {
            "classification": (
                "MULTI_VIEWER_PLAN_ORIGINS"
                if len(viewer_origin_counts) > 1 else
                "SINGLE_VIEWER_PLAN_ORIGIN"
                if viewer_origin_counts else "ORIGIN_NOT_RETAINED"
            ),
            "viewer_plan_member_count": sum(viewer_origin_counts.values()),
            "unmatched_member_count": unmatched_non_edit_members,
            "distinct_viewer_plan_origins": len(viewer_origin_counts),
            "latest_viewer_plan_before_edit": latest_plan_before_edit,
            "latest_viewer_plan_before_publication": latest_plan_before_publication,
            "members_from_plans_older_than_latest_pre_edit_plan": older_origin_members,
            "viewer_plan_origin_counts": {
                str(cause): count
                for cause, count in sorted(viewer_origin_counts.items())
            },
            "claim_boundary": (
                "An older demand origin proves that the publication component "
                "spans multiple accepted viewer plans. It does not prove stale "
                "or superseded work: a chunk may remain desired without receiving "
                "a new generation in every later plan."
            ),
        },
        "desired_ownership": {
            "available": desired_snapshot is not None,
            "exact": exact_latest_drained_ownership,
            "classification": desired_ownership_classification,
            "snapshot_event_count": len(desired_snapshot_events),
            "latest_completed_viewer_plan_revision": latest_completed_viewer_plan,
            "open_viewer_plan_publications": open_viewer_plans,
            "required_member_count": required_member_count,
            "visual_required_member_count": visual_required_member_count,
            "collision_required_member_count": collision_required_member_count,
            "staged_member_count": staged_member_count,
            "fully_ready_member_count": fully_ready_member_count,
            "claim_boundary": (
                "Exact means every retained replacement in this publication "
                "cohort was still required and fully ready after the "
                "latest fully drained frontend viewer plan. It does not cover "
                "a future viewer plan that had not yet reached the frontend."
                if exact_latest_drained_ownership else
                "Current desired ownership is not proven unless one exact "
                "publication-boundary snapshot and every cohort member are retained."
            ),
        },
        "publication_after_edit_replacements_ready_ms": (
            batch_ns - ready_ns
        ) / 1_000_000.0,
        "replacement_lod_counts": dict(sorted(Counter(
            identity[3] for identity in replacement_members
        ).items())),
        "retirement_lod_counts": dict(sorted(Counter(
            key[3] for key in retirement_members
        ).items())),
        "replacement_members": [
            {
                "x": identity[0], "y": identity[1], "z": identity[2],
                "lod": identity[3], "generation": identity[4],
                "desired_roles_available": desired_snapshot_exact,
                "visual_required": (
                    bool(desired_status_by_identity.get(identity, 0) & 0x1)
                    if desired_snapshot_exact else None
                ),
                "collision_required": (
                    bool(desired_status_by_identity.get(identity, 0) & 0x2)
                    if desired_snapshot_exact else None
                ),
                "staged_replacement": (
                    bool(desired_status_by_identity.get(identity, 0) & 0x4)
                    if desired_snapshot_exact else None
                ),
                "fully_ready": (
                    bool(desired_status_by_identity.get(identity, 0) & 0x8)
                    if desired_snapshot_exact else None
                ),
                "relation": (
                    "edit_replacement" if identity in replacement_identities
                    else "non_edit_replacement"
                ),
            }
            for identity in sorted(replacement_members)
        ],
        "retirement_members": [
            {"x": key[0], "y": key[1], "z": key[2], "lod": key[3]}
            for key in sorted(retirement_members)
        ],
        "exact_membership_available": exact_membership,
        "publication_component_audit": component_audit,
        "claim_boundary": (
            "The authority emitted every member of the successfully published "
            "regional cohort. Edit identity is exact. Non-edit members are proven "
            "not to be edit replacements. The nested desired-ownership result "
            "separately states whether those members were still required at the "
            "latest fully drained frontend plan boundary."
            if exact_membership else
            "The retained event stream correlates this batch with edit activation "
            "and exposes its counts and not-ready priority keys. It does not emit "
            "the complete regional membership, so it cannot yet prove that every "
            "edit replacement belonged to this batch or classify every additional "
            "replacement's ownership."
        ),
    }


def batch_contains_replacements(
    events: list[dict[str, Any]],
    batch_event: dict[str, Any],
    replacement_identities: set[tuple[int, int, int, int, int]],
) -> bool:
    cohort_id = int(batch_event.get("generation", 0))
    if cohort_id <= 0 or not replacement_identities:
        return False
    batch_ns = int(batch_event.get("elapsed_ns", 0))
    members = {
        identity for event in events
        if event.get("kind") == "visibility_region_replacement_member"
        and int(event.get("cause_id", 0)) == cohort_id
        and int(event.get("elapsed_ns", -1)) <= batch_ns
        and (identity := native_identity(event)) is not None
    }
    return replacement_identities <= members


def pre_edit_destination_readiness(
    downstream_events: list[dict[str, Any]],
    native_events: list[dict[str, Any]],
    request: dict[str, Any],
    submission: dict[str, Any],
) -> dict[str, Any]:
    payload = request.get("payload") or {}
    center = position(payload.get("center"))
    if center is None:
        return {
            "available": False,
            "classification": "EDIT_CENTER_NOT_RETAINED",
        }
    mode = str(payload.get("mode", "unknown"))
    target_key = (
        math.floor(center[0] / CHUNK_SIZE),
        math.floor(center[1] / CHUNK_SIZE),
        math.floor(center[2] / CHUNK_SIZE),
        0,
    )
    request_us = int(request.get(
        "elapsed_us", int(submission.get("elapsed_ns", 0)) // 1000
    ))
    origin_ns = int(submission.get("elapsed_ns", request_us * 1000))
    relocation_label = f"flight_relocation_{mode}"
    relocation_phases = [
        event for event in downstream_events
        if event.get("kind") == "phase_started"
        and str((event.get("payload") or {}).get("label", "")) == relocation_label
        and int(event.get("elapsed_us", -1)) <= request_us
    ]
    relocation_phase = max(
        relocation_phases,
        key=lambda event: int(event.get("elapsed_us", 0)),
        default=None,
    )
    relocation_start_us = (
        int(relocation_phase.get("elapsed_us", 0))
        if relocation_phase is not None else 0
    )
    surface_phases = [
        event for event in downstream_events
        if event.get("kind") == "phase_started"
        and str((event.get("payload") or {}).get("label", "")) == "relocation_surface_wait"
        and relocation_start_us <= int(event.get("elapsed_us", -1)) <= request_us
    ]
    surface_phase = max(
        surface_phases,
        key=lambda event: int(event.get("elapsed_us", 0)),
        default=None,
    )
    surface_start_us = (
        int(surface_phase.get("elapsed_us", 0))
        if surface_phase is not None else None
    )
    window_start_ns = relocation_start_us * 1000
    target_events = [
        event for event in native_events
        if window_start_ns <= int(event.get("elapsed_ns", -1)) < origin_ns
        and (identity := native_identity(event)) is not None
        and identity[:4] == target_key
    ]
    demands = [
        event for event in target_events
        if event.get("kind") == "chunk_demand_accepted"
    ]
    first_demand = min(
        demands,
        key=lambda event: int(event.get("elapsed_ns", 0)),
        default=None,
    )
    render_by_generation = {
        int(event.get("generation", 0)): event
        for event in target_events
        if event.get("kind") == "render_sink_applied"
    }
    collision_by_generation = {
        int(event.get("generation", 0)): event
        for event in target_events
        if event.get("kind") == "collision_sink_applied"
    }
    common_generations = render_by_generation.keys() & collision_by_generation.keys()
    ready_candidates = [
        (
            max(
                int(render_by_generation[generation].get("elapsed_ns", 0)),
                int(collision_by_generation[generation].get("elapsed_ns", 0)),
            ),
            generation,
        )
        for generation in common_generations
    ]
    ready_ns, ready_generation = max(
        ready_candidates,
        default=(None, None),
    )
    if first_demand is None:
        classification = "NO_RELOCATION_WINDOW_TARGET_DEMAND_RETAINED"
    elif ready_ns is None:
        classification = "TARGET_DEMANDED_BUT_FULL_READINESS_NOT_RETAINED"
    else:
        classification = "DESTINATION_FULLY_READY_BEFORE_EDIT"

    first_demand_ns = (
        int(first_demand.get("elapsed_ns", 0))
        if first_demand is not None else None
    )
    return {
        "available": first_demand is not None,
        "classification": classification,
        "target": {
            "x": target_key[0],
            "y": target_key[1],
            "z": target_key[2],
            "lod": target_key[3],
        },
        "relocation_phase": relocation_label,
        "relocation_phase_start_ms": relocation_start_us / 1000.0,
        "surface_wait_start_ms": (
            surface_start_us / 1000.0 if surface_start_us is not None else None
        ),
        "edit_submission_ms": origin_ns / 1_000_000.0,
        "first_demand": None if first_demand is None else {
            "generation": int(first_demand.get("generation", 0)),
            "viewer_plan_revision": int(first_demand.get("cause_id", 0)),
            "elapsed_ms": first_demand_ns / 1_000_000.0,
            "after_relocation_start_ms": (
                first_demand_ns - window_start_ns
            ) / 1_000_000.0,
            "before_surface_wait_ms": (
                (surface_start_us * 1000 - first_demand_ns) / 1_000_000.0
                if surface_start_us is not None else None
            ),
            "before_edit_ms": (origin_ns - first_demand_ns) / 1_000_000.0,
        },
        "full_readiness": (
            {
                "available": True,
                "generation": ready_generation,
                "elapsed_ms": ready_ns / 1_000_000.0,
                "after_relocation_start_ms": (
                    ready_ns - window_start_ns
                ) / 1_000_000.0,
                "before_edit_ms": (origin_ns - ready_ns) / 1_000_000.0,
            }
            if ready_ns is not None else {"available": False}
        ),
        "claim_boundary": (
            "This proves retained render and collision sink application for the "
            "eventual LOD0 edit chunk before authority accepted the edit. It does "
            "not prove that every member of the surrounding atomic visibility "
            "publication region was ready."
            if ready_ns is not None else
            "No complete pre-edit render/collision pair was retained for the "
            "eventual LOD0 edit chunk in this relocation window."
        ),
    }


def publication_blocker_critical_path_analysis(
    native_events: list[dict[str, Any]],
    blocker: dict[str, Any],
    publication: dict[str, Any],
    origin_ns: int,
    batch_event: dict[str, Any] | None,
) -> dict[str, Any]:
    transitions = blocker.get("transitions")
    if batch_event is None or not isinstance(transitions, list) or not transitions:
        return {
            "available": False,
            "classification": "BLOCKER_PATH_NOT_RETAINED",
            "path_count": 0,
        }
    batch_ns = int(batch_event.get("elapsed_ns", origin_ns))
    cohort_members = {}
    for member in publication.get("replacement_members", []):
        if not isinstance(member, dict):
            continue
        identity = tuple(
            int(member.get(name, 0))
            for name in ("x", "y", "z", "lod", "generation")
        )
        cohort_members[identity] = member

    observed: dict[tuple[int, int, int, int, int], list[dict[str, Any]]] = {}
    for transition in transitions:
        if not isinstance(transition, dict):
            continue
        key = transition.get("key")
        if not isinstance(key, dict):
            continue
        identity = (
            int(key.get("x", 0)),
            int(key.get("y", 0)),
            int(key.get("z", 0)),
            int(key.get("lod", 0)),
            int(transition.get("generation", 0)),
        )
        observation = dict(transition)
        observation["source"] = "sampled_first_blocker"
        observed.setdefault(identity, []).append(observation)

    ready_events_by_identity: dict[
        tuple[int, int, int, int, int], list[dict[str, Any]]
    ] = defaultdict(list)
    for event in native_events:
        if event.get("kind") != "visibility_replacement_ready" or \
                int(event.get("elapsed_ns", -1)) > batch_ns:
            continue
        identity = native_identity(event)
        if identity in cohort_members:
            ready_events_by_identity[identity].append(event)
    terminal_ready_ns = max(
        (
            int(event.get("elapsed_ns", 0))
            for events in ready_events_by_identity.values()
            for event in events
        ),
        default=0,
    )
    terminal_identities = {
        identity for identity, events in ready_events_by_identity.items()
        if any(
            int(event.get("elapsed_ns", 0)) == terminal_ready_ns
            for event in events
        )
    }
    for identity in terminal_identities:
        member = cohort_members[identity]
        observed.setdefault(identity, []).append({
            "elapsed_from_request_ms": (
                terminal_ready_ns - origin_ns
            ) / 1_000_000.0,
            "reason": "terminal_readiness_controller",
            "relation": str(member.get("relation", "non_edit_replacement")),
            "source": "terminal_readiness_controller",
        })

    paths = []

    def queue_composition_at_admission(
        admission: dict[str, Any] | None,
    ) -> dict[str, Any]:
        if admission is None or not bool(admission.get("has_queue_state", False)):
            return {
                "available": False,
                "classification": "QUEUE_ADMISSION_NOT_RETAINED",
            }
        target_event_sequence = int(admission.get("sequence", -1))
        target_job_sequence = int(admission.get("job_sequence", 0))
        active: dict[int, dict[str, Any]] = {}
        for event in sorted(
            native_events,
            key=lambda item: int(item.get("sequence", 0)),
        ):
            event_sequence = int(event.get("sequence", -1))
            if event_sequence > target_event_sequence:
                break
            kind = str(event.get("kind", ""))
            job_sequence = int(event.get("job_sequence", 0))
            if kind == "scheduler_job_queued":
                queued_identity = native_identity(event)
                if job_sequence > 0 and queued_identity is not None:
                    active[job_sequence] = {
                        "identity": queued_identity,
                        "stage": str(event.get("job_stage", "unknown")),
                        "priority": int(event.get("effective_priority", 0)),
                    }
            elif kind == "scheduler_job_priority_observed":
                if job_sequence in active:
                    active[job_sequence]["priority"] = int(
                        event.get("effective_priority", 0)
                    )
            elif kind == "scheduler_job_dequeued":
                active.pop(job_sequence, None)
        if target_job_sequence not in active:
            return {
                "available": False,
                "classification": "TARGET_JOB_NOT_RECONSTRUCTED",
            }
        ordered = sorted(
            active.items(),
            key=lambda item: (-int(item[1]["priority"]), item[0]),
        )
        target_index = next(
            index for index, item in enumerate(ordered)
            if item[0] == target_job_sequence
        )
        ahead = [item[1] for item in ordered[:target_index]]
        target_priority = int(active[target_job_sequence]["priority"])
        same_priority_ahead = [
            item for item in ahead
            if int(item["priority"]) == target_priority
        ]
        same_region_ahead = [
            item for item in ahead
            if item["identity"] in cohort_members
        ]
        same_priority_same_region_ahead = [
            item for item in same_priority_ahead
            if item["identity"] in cohort_members
        ]

        def counts(items: list[dict[str, Any]], name: str) -> dict[str, int]:
            return dict(sorted(Counter(str(item[name]) for item in items).items()))

        reported_jobs_ahead = int(admission.get("jobs_ahead", 0))
        reported_same_priority = int(
            admission.get("same_priority_jobs_ahead", 0)
        )
        exact = (
            target_index == reported_jobs_ahead
            and len(same_priority_ahead) == reported_same_priority
        )
        return {
            "available": True,
            "classification": (
                "EXACT_QUEUE_COMPOSITION_RECONSTRUCTED"
                if exact else "QUEUE_COMPOSITION_COUNT_MISMATCH"
            ),
            "exact": exact,
            "reconstructed_jobs_ahead": target_index,
            "reported_jobs_ahead": reported_jobs_ahead,
            "stage_counts": counts(ahead, "stage"),
            "lod_counts": dict(sorted(Counter(
                int(item["identity"][3]) for item in ahead
            ).items())),
            "same_priority_jobs_ahead": len(same_priority_ahead),
            "same_priority_stage_counts": counts(
                same_priority_ahead, "stage"
            ),
            "same_publication_region_jobs_ahead": len(same_region_ahead),
            "same_priority_same_publication_region_jobs_ahead": len(
                same_priority_same_region_ahead
            ),
            "all_jobs_ahead_are_same_priority_publication_members": (
                bool(ahead)
                and len(same_priority_same_region_ahead) == len(ahead)
            ),
        }

    for identity, observations in observed.items():
        identity_events = sorted(
            (
                event for event in native_events
                if int(event.get("elapsed_ns", -1)) <= batch_ns
                and native_identity(event) == identity
            ),
            key=lambda event: int(event.get("elapsed_ns", 0)),
        )
        by_kind: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for event in identity_events:
            by_kind[str(event.get("kind", ""))].append(event)

        def first_event(kind: str, after_ns: int = 0) -> dict[str, Any] | None:
            return next((
                event for event in by_kind.get(kind, [])
                if int(event.get("elapsed_ns", -1)) >= after_ns
            ), None)

        def first_job_event(
            kind: str,
            stage: str,
            after_ns: int = 0,
        ) -> dict[str, Any] | None:
            return next((
                event for event in by_kind.get(kind, [])
                if str(event.get("job_stage", "")) == stage
                and int(event.get("elapsed_ns", -1)) >= after_ns
            ), None)

        demand = first_event("chunk_demand_accepted")
        demand_ns = int(demand.get("elapsed_ns", 0)) if demand is not None else 0
        expect_chunk = next((
            event for event in by_kind.get("publication_queued", [])
            if int(event.get("auxiliary", -1)) == 0
        ), None)
        expect_chunk_ns = (
            int(expect_chunk.get("elapsed_ns", 0))
            if expect_chunk is not None else 0
        )
        transition_origin = first_event("transition_remesh_generation_created")
        repair_origin = first_event("readiness_repair_generation_created")
        explicit_origin = transition_origin or repair_origin
        explicit_origin_ns = (
            int(explicit_origin.get("elapsed_ns", 0))
            if explicit_origin is not None else 0
        )
        if transition_origin is not None:
            generation_origin = "TRANSITION_REMESH"
        elif repair_origin is not None and int(repair_origin.get("auxiliary", 0)) == 1:
            generation_origin = "READINESS_REPAIR_STAGED"
        elif repair_origin is not None:
            generation_origin = "READINESS_REPAIR_UNSTAGED"
        elif demand is not None and int(demand.get("auxiliary", 0)) == 1:
            generation_origin = "EDIT_REPLACEMENT_DEMAND"
        elif demand is not None:
            generation_origin = "VIEWER_DEMAND"
        elif expect_chunk is not None:
            generation_origin = "EXPECT_CHUNK_WITHOUT_DEMAND_EVENT"
        else:
            generation_origin = "GENERATION_ORIGIN_NOT_RETAINED"
        priority_requested = first_event(
            "visibility_coverage_priority_requested", origin_ns
        )
        priority_requested_ns = (
            int(priority_requested.get("elapsed_ns", 0))
            if priority_requested is not None else 0
        )
        priority_applied = first_event(
            "visibility_coverage_priority_applied",
            priority_requested_ns or origin_ns,
        )
        priority_applied_ns = (
            int(priority_applied.get("elapsed_ns", 0))
            if priority_applied is not None else 0
        )
        priority_outcome = first_event(
            "visibility_coverage_priority_outcome",
            priority_requested_ns or origin_ns,
        )
        priority_outcome_ns = (
            int(priority_outcome.get("elapsed_ns", 0))
            if priority_outcome is not None else 0
        )
        priority_outcome_status = (
            int(priority_outcome.get("status", -1))
            if priority_outcome is not None else None
        )
        priority_outcome_classification = (
            PRIORITY_OUTCOME_BY_STATUS.get(
                priority_outcome_status,
                "UNKNOWN_STATUS_%d" % priority_outcome_status,
            )
            if priority_outcome_status is not None else
            "OUTCOME_NOT_RETAINED"
        )
        priority_scheduler_applied = (
            priority_outcome_status in SCHEDULER_APPLIED_PRIORITY_OUTCOMES
            if priority_outcome_status is not None else
            priority_applied is not None
        )
        sample_queued = first_job_event("scheduler_job_queued", "sample")
        sample_queued_ns = (
            int(sample_queued.get("elapsed_ns", 0))
            if sample_queued is not None else 0
        )
        priority_observed = first_job_event(
            "scheduler_job_priority_observed",
            "sample",
            priority_requested_ns or origin_ns,
        )
        priority_observed_ns = (
            int(priority_observed.get("elapsed_ns", 0))
            if priority_observed is not None else 0
        )
        sample_dequeued = first_job_event(
            "scheduler_job_dequeued",
            "sample",
            sample_queued_ns,
        )
        sample_dequeued_ns = (
            int(sample_dequeued.get("elapsed_ns", 0))
            if sample_dequeued is not None else 0
        )
        page_ownership = first_job_event(
            "page_meshing_ownership_established",
            "sample",
            sample_dequeued_ns,
        )
        page_ownership_ns = (
            int(page_ownership.get("elapsed_ns", 0))
            if page_ownership is not None else 0
        )
        sample_started = first_event("sample_started", demand_ns)
        sample_started_ns = (
            int(sample_started.get("elapsed_ns", 0))
            if sample_started is not None else 0
        )
        sample_finished = first_event("sample_finished", sample_started_ns)
        sample_finished_ns = (
            int(sample_finished.get("elapsed_ns", 0))
            if sample_finished is not None else 0
        )
        storage_requested = first_event("storage_requested", demand_ns)
        storage_requested_ns = (
            int(storage_requested.get("elapsed_ns", 0))
            if storage_requested is not None else 0
        )
        storage_started = first_event("storage_started", storage_requested_ns)
        storage_started_ns = (
            int(storage_started.get("elapsed_ns", 0))
            if storage_started is not None else 0
        )
        storage_finished = first_event("storage_finished", storage_started_ns)
        storage_finished_ns = (
            int(storage_finished.get("elapsed_ns", 0))
            if storage_finished is not None else 0
        )
        storage_consumed = first_event(
            "storage_completion_consumed", storage_finished_ns
        )
        storage_consumed_ns = (
            int(storage_consumed.get("elapsed_ns", 0))
            if storage_consumed is not None else 0
        )
        dependency_boundaries = [
            elapsed_ns for elapsed_ns in (sample_finished_ns, storage_consumed_ns)
            if elapsed_ns > 0
        ]
        dependencies_ready_ns = (
            max(dependency_boundaries) if dependency_boundaries else 0
        )
        mesh_queued = first_job_event(
            "scheduler_job_queued",
            "mesh",
            dependencies_ready_ns,
        )
        mesh_queued_ns = (
            int(mesh_queued.get("elapsed_ns", 0))
            if mesh_queued is not None else 0
        )
        mesh_dequeued = first_job_event(
            "scheduler_job_dequeued",
            "mesh",
            mesh_queued_ns,
        )
        mesh_dequeued_ns = (
            int(mesh_dequeued.get("elapsed_ns", 0))
            if mesh_dequeued is not None else 0
        )
        mesh_started = first_event("mesh_started", dependencies_ready_ns)
        mesh_started_ns = (
            int(mesh_started.get("elapsed_ns", 0))
            if mesh_started is not None else 0
        )
        mesh_finished = first_event("mesh_finished", mesh_started_ns)
        mesh_finished_ns = (
            int(mesh_finished.get("elapsed_ns", 0))
            if mesh_finished is not None else 0
        )
        mesh_consumed = first_event("mesh_completion_consumed", mesh_finished_ns)
        mesh_consumed_ns = (
            int(mesh_consumed.get("elapsed_ns", 0))
            if mesh_consumed is not None else mesh_finished_ns
        )
        render_applied = first_event("render_sink_applied", mesh_consumed_ns)
        render_applied_ns = (
            int(render_applied.get("elapsed_ns", 0))
            if render_applied is not None else 0
        )
        collision_applied = first_event("collision_sink_applied", mesh_consumed_ns)
        collision_applied_ns = (
            int(collision_applied.get("elapsed_ns", 0))
            if collision_applied is not None else 0
        )
        member = cohort_members.get(identity)
        visual_required = (
            bool(member.get("visual_required")) if member is not None else None
        )
        collision_required = (
            bool(member.get("collision_required")) if member is not None else None
        )
        required_sink_boundaries = [
            elapsed_ns for elapsed_ns, required in (
                (render_applied_ns, visual_required),
                (collision_applied_ns, collision_required),
            )
            if elapsed_ns > 0 and required is not False
        ]
        sinks_ready_ns = max(required_sink_boundaries) if required_sink_boundaries else 0
        replacement_ready = first_event("visibility_replacement_ready", sinks_ready_ns)
        replacement_ready_ns = (
            int(replacement_ready.get("elapsed_ns", 0))
            if replacement_ready is not None else 0
        )
        def from_edit_ms(event_ns: int) -> float | None:
            return (
                (event_ns - origin_ns) / 1_000_000.0
                if event_ns > 0 else None
            )

        def queue_event_summary(
            event: dict[str, Any] | None,
        ) -> dict[str, Any] | None:
            if event is None:
                return None
            summary = {
                "from_edit_ms": from_edit_ms(int(event.get("elapsed_ns", 0))),
                "stage": str(event.get("job_stage", "unknown")),
                "effective_priority": int(event.get("effective_priority", 0)),
                "job_sequence": int(event.get("job_sequence", 0)),
                "has_queue_state": bool(event.get("has_queue_state", False)),
            }
            if summary["has_queue_state"]:
                summary.update({
                    "queue_depth_before": int(
                        event.get("queue_depth_before", 0)
                    ),
                    "queue_depth_after": int(event.get("queue_depth_after", 0)),
                    "jobs_ahead": int(event.get("jobs_ahead", 0)),
                    "same_priority_jobs_ahead": int(
                        event.get("same_priority_jobs_ahead", 0)
                    ),
                })
            return summary

        segments = []

        def add_segment(
            classification: str,
            duration_ns: int,
            segment_kind: str = "queue_or_handoff",
        ) -> None:
            if duration_ns < 0:
                return
            segments.append({
                "classification": classification,
                "kind": segment_kind,
                "duration_ms": duration_ns / 1_000_000.0,
            })

        if priority_requested_ns > 0:
            add_segment(
                "EDIT_TO_PRIORITY_REQUEST",
                priority_requested_ns - origin_ns,
            )
        first_pipeline_ns = min(
            (elapsed_ns for elapsed_ns in (sample_started_ns, storage_requested_ns)
             if elapsed_ns > 0),
            default=0,
        )
        priority_boundary_ns = (
            priority_applied_ns
            or (priority_outcome_ns if priority_scheduler_applied else 0)
            or priority_requested_ns
        )
        if priority_requested_ns > 0 and priority_observed_ns > 0:
            add_segment(
                "PRIORITY_REQUEST_TO_SCHEDULER_OBSERVATION",
                priority_observed_ns - priority_requested_ns,
            )
        if priority_observed_ns > 0 and sample_dequeued_ns > 0:
            add_segment(
                "PRIORITY_OBSERVATION_TO_SAMPLE_DEQUEUE",
                sample_dequeued_ns - priority_observed_ns,
            )
        elif priority_boundary_ns > 0 and first_pipeline_ns > 0:
            add_segment(
                (
                    "PRIORITY_TO_PIPELINE_START"
                    if priority_scheduler_applied else
                    "PRIORITY_REQUEST_TO_PIPELINE_START"
                ),
                first_pipeline_ns - priority_boundary_ns,
            )
        elif first_pipeline_ns > origin_ns:
            add_segment(
                "EDIT_TO_PIPELINE_START",
                first_pipeline_ns - origin_ns,
            )
        if sample_dequeued_ns > 0 and sample_started_ns > 0:
            add_segment(
                "SAMPLE_DEQUEUE_TO_START",
                sample_started_ns - sample_dequeued_ns,
            )
        if sample_started_ns > 0 and page_ownership_ns > 0:
            add_segment(
                "SAMPLE_START_TO_PAGE_OWNERSHIP",
                page_ownership_ns - sample_started_ns,
            )
        if sample_finished is not None:
            add_segment(
                "SAMPLE_WORK",
                int(sample_finished.get("duration_ns", 0)),
                "measured_work",
            )
        if storage_requested_ns > 0 and storage_started_ns > 0:
            add_segment(
                "STORAGE_QUEUE",
                storage_started_ns - storage_requested_ns,
            )
        if storage_finished is not None:
            add_segment(
                "STORAGE_WORK",
                int(storage_finished.get("duration_ns", 0)),
                "measured_work",
            )
        if storage_finished_ns > 0 and storage_consumed_ns > 0:
            add_segment(
                "STORAGE_COMPLETION_HANDOFF",
                storage_consumed_ns - storage_finished_ns,
            )
        if dependencies_ready_ns > 0 and mesh_queued_ns > 0:
            add_segment(
                "DEPENDENCIES_READY_TO_MESH_QUEUE",
                mesh_queued_ns - dependencies_ready_ns,
            )
        if mesh_queued_ns > 0 and mesh_dequeued_ns > 0:
            add_segment(
                "MESH_SCHEDULER_QUEUE",
                mesh_dequeued_ns - mesh_queued_ns,
            )
        if mesh_dequeued_ns > 0 and mesh_started_ns > 0:
            add_segment(
                "MESH_DEQUEUE_TO_START",
                mesh_started_ns - mesh_dequeued_ns,
            )
        elif dependencies_ready_ns > 0 and mesh_started_ns > 0:
            add_segment(
                "DEPENDENCIES_READY_TO_MESH",
                mesh_started_ns - dependencies_ready_ns,
            )
        if mesh_finished is not None:
            add_segment(
                "MESH_WORK",
                int(mesh_finished.get("duration_ns", 0)),
                "measured_work",
            )
        if mesh_finished_ns > 0 and mesh_consumed_ns > 0:
            add_segment(
                "MESH_COMPLETION_HANDOFF",
                mesh_consumed_ns - mesh_finished_ns,
            )
        first_sink_ns = min(required_sink_boundaries, default=0)
        if mesh_consumed_ns > 0 and first_sink_ns > 0:
            add_segment(
                "MESH_TO_FIRST_SINK",
                first_sink_ns - mesh_consumed_ns,
            )
        if len(required_sink_boundaries) > 1:
            add_segment(
                "REQUIRED_SINK_SPAN",
                max(required_sink_boundaries) - min(required_sink_boundaries),
            )
        if sinks_ready_ns > 0 and replacement_ready_ns > 0:
            add_segment(
                "SINKS_TO_VISIBILITY_READY",
                replacement_ready_ns - sinks_ready_ns,
            )
        dominant_segment = max(
            segments,
            key=lambda segment: float(segment["duration_ms"]),
            default={
                "classification": "NO_COMPLETE_SEGMENT",
                "kind": "unknown",
                "duration_ms": 0.0,
            },
        )
        required_events_present = (
            replacement_ready is not None
            and (
                visual_required is not True
                or (
                    sample_finished is not None
                    and mesh_finished is not None
                    and render_applied is not None
                )
            )
            and (collision_required is not True or collision_applied is not None)
        )
        sampled_observations = [
            item for item in observations
            if item.get("source") == "sampled_first_blocker"
        ]
        is_terminal_controller = identity in terminal_identities
        paths.append({
            "identity": {
                "x": identity[0], "y": identity[1], "z": identity[2],
                "lod": identity[3], "generation": identity[4],
            },
            "relation": str(
                (sampled_observations[0] if sampled_observations else observations[0])
                .get("relation", "unknown")
            ),
            "sampled_reason": (
                str(sampled_observations[0].get("reason", "unknown"))
                if sampled_observations else None
            ),
            "observation_count": len(observations),
            "sampled_observation_count": len(sampled_observations),
            "terminal_readiness_controller": is_terminal_controller,
            "first_observed_from_edit_ms": min(
                float(item.get("elapsed_from_request_ms", 0.0))
                for item in observations
            ),
            "exact_cohort_member": member is not None,
            "visual_required": visual_required,
            "collision_required": collision_required,
            "complete": required_events_present,
            "demand_origin_retained": demand is not None,
            "generation_origin_classification": generation_origin,
            "explicit_generation_origin_retained": explicit_origin is not None,
            "priority_apply_retained": priority_applied is not None,
            "priority_outcome_retained": priority_outcome is not None,
            "priority_outcome_status": priority_outcome_status,
            "priority_outcome_classification": priority_outcome_classification,
            "priority_scheduler_applied": priority_scheduler_applied,
            "scheduler_queue_path_complete": all(event is not None for event in (
                sample_queued,
                sample_dequeued,
                page_ownership,
                mesh_queued,
                mesh_dequeued,
            )),
            "interactive_priority_at_sample_observation": (
                int(priority_observed.get("effective_priority", 0)) == 2147483647
                if priority_observed is not None else None
            ),
            "interactive_priority_at_mesh_admission": (
                int(mesh_queued.get("effective_priority", 0)) == 2147483647
                if mesh_queued is not None else None
            ),
            "interactive_priority_at_mesh_dequeue": (
                int(mesh_dequeued.get("effective_priority", 0)) == 2147483647
                if mesh_dequeued is not None else None
            ),
            "scheduler_queue": {
                "sample_admission": queue_event_summary(sample_queued),
                "priority_observation": queue_event_summary(priority_observed),
                "sample_dequeue": queue_event_summary(sample_dequeued),
                "page_ownership": queue_event_summary(page_ownership),
                "mesh_admission": queue_event_summary(mesh_queued),
                "mesh_dequeue": queue_event_summary(mesh_dequeued),
                "mesh_admission_ahead_composition": (
                    queue_composition_at_admission(mesh_queued)
                ),
                "sample_residency_ms": (
                    (sample_dequeued_ns - sample_queued_ns) / 1_000_000.0
                    if sample_queued_ns > 0 and sample_dequeued_ns > 0 else None
                ),
                "mesh_residency_ms": (
                    (mesh_dequeued_ns - mesh_queued_ns) / 1_000_000.0
                    if mesh_queued_ns > 0 and mesh_dequeued_ns > 0 else None
                ),
            },
            "viewer_plan_origin": (
                int(demand.get("cause_id", 0)) if demand is not None else None
            ),
            "demand_before_edit_ms": (
                (origin_ns - demand_ns) / 1_000_000.0
                if demand_ns > 0 else None
            ),
            "demand_from_edit_ms": from_edit_ms(demand_ns),
            "expect_chunk_from_edit_ms": from_edit_ms(expect_chunk_ns),
            "explicit_generation_origin_from_edit_ms": from_edit_ms(
                explicit_origin_ns
            ),
            "stages_from_edit_ms": {
                "priority_requested": from_edit_ms(priority_requested_ns),
                "priority_applied": from_edit_ms(priority_applied_ns),
                "priority_outcome": from_edit_ms(priority_outcome_ns),
                "sample_queued": from_edit_ms(sample_queued_ns),
                "priority_observed": from_edit_ms(priority_observed_ns),
                "sample_dequeued": from_edit_ms(sample_dequeued_ns),
                "page_ownership": from_edit_ms(page_ownership_ns),
                "sample_started": from_edit_ms(sample_started_ns),
                "sample_finished": from_edit_ms(sample_finished_ns),
                "storage_requested": from_edit_ms(storage_requested_ns),
                "storage_started": from_edit_ms(storage_started_ns),
                "storage_finished": from_edit_ms(storage_finished_ns),
                "storage_consumed": from_edit_ms(storage_consumed_ns),
                "dependencies_ready": from_edit_ms(dependencies_ready_ns),
                "mesh_queued": from_edit_ms(mesh_queued_ns),
                "mesh_dequeued": from_edit_ms(mesh_dequeued_ns),
                "mesh_started": from_edit_ms(mesh_started_ns),
                "mesh_finished": from_edit_ms(mesh_finished_ns),
                "mesh_consumed": from_edit_ms(mesh_consumed_ns),
                "render_applied": from_edit_ms(render_applied_ns),
                "collision_applied": from_edit_ms(collision_applied_ns),
                "visibility_ready": from_edit_ms(replacement_ready_ns),
                "publication": from_edit_ms(batch_ns),
            },
            "segments": segments,
            "dominant_segment": dominant_segment,
            "ready_before_publication_ms": (
                (batch_ns - replacement_ready_ns) / 1_000_000.0
                if replacement_ready_ns > 0 else None
            ),
        })

    dominant_counts = Counter(
        str(path["dominant_segment"]["classification"])
        for path in paths
    )
    overall_dominant = max(
        (path for path in paths if path.get("dominant_segment")),
        key=lambda path: float(path["dominant_segment"]["duration_ms"]),
        default=None,
    )
    exact_path_count = sum(path["exact_cohort_member"] for path in paths)
    complete_path_count = sum(path["complete"] for path in paths)
    non_edit_path_count = sum(
        path["relation"] == "other_replacement" for path in paths
    )
    terminal_paths = [
        path for path in paths if path["terminal_readiness_controller"]
    ]
    terminal_complete_count = sum(path["complete"] for path in terminal_paths)
    terminal_demand_origin_count = sum(
        path["demand_origin_retained"] for path in terminal_paths
    )
    terminal_priority_apply_count = sum(
        path["priority_apply_retained"] for path in terminal_paths
    )
    terminal_priority_outcome_count = sum(
        path["priority_outcome_retained"] for path in terminal_paths
    )
    terminal_priority_scheduler_applied_count = sum(
        path["priority_scheduler_applied"] for path in terminal_paths
    )
    terminal_complete_queue_path_count = sum(
        path["scheduler_queue_path_complete"] for path in terminal_paths
    )
    terminal_interactive_mesh_priority_count = sum(
        path["interactive_priority_at_mesh_admission"] is True
        and path["interactive_priority_at_mesh_dequeue"] is True
        for path in terminal_paths
    )
    sampled_paths = [
        path for path in paths if path["sampled_observation_count"] > 0
    ]
    unmatched_sampled_path_count = sum(
        not path["exact_cohort_member"] for path in sampled_paths
    )
    terminal_dominant_counts = Counter(
        str(path["dominant_segment"]["classification"])
        for path in terminal_paths
    )
    terminal_origin_counts = Counter(
        str(path["generation_origin_classification"])
        for path in terminal_paths
    )
    terminal_priority_outcome_counts = Counter(
        str(path["priority_outcome_classification"])
        for path in terminal_paths
    )
    terminal_overall_dominant = max(
        terminal_paths,
        key=lambda path: float(path["dominant_segment"]["duration_ms"]),
        default=None,
    )
    if (
        terminal_paths
        and terminal_complete_count == len(terminal_paths)
        and all(path["exact_cohort_member"] for path in terminal_paths)
    ):
        classification = "EXACT_TERMINAL_CONTROLLER_PATHS_RETAINED"
    elif paths and exact_path_count == len(paths) and complete_path_count == len(paths):
        classification = "EXACT_BLOCKER_CRITICAL_PATHS_RETAINED"
    elif paths:
        classification = "PARTIAL_BLOCKER_CRITICAL_PATHS_RETAINED"
    else:
        classification = "BLOCKER_PATH_NOT_RETAINED"
    return {
        "available": bool(paths),
        "classification": classification,
        "path_count": len(paths),
        "complete_path_count": complete_path_count,
        "exact_cohort_member_path_count": exact_path_count,
        "non_edit_path_count": non_edit_path_count,
        "sampled_path_count": len(sampled_paths),
        "unmatched_sampled_path_count": unmatched_sampled_path_count,
        "terminal_controller_path_count": len(terminal_paths),
        "terminal_controller_complete_path_count": terminal_complete_count,
        "terminal_controller_demand_origin_path_count": terminal_demand_origin_count,
        "terminal_controller_priority_apply_path_count": terminal_priority_apply_count,
        "terminal_controller_priority_outcome_path_count": terminal_priority_outcome_count,
        "terminal_controller_priority_scheduler_applied_path_count": (
            terminal_priority_scheduler_applied_count
        ),
        "terminal_controller_complete_scheduler_queue_path_count": (
            terminal_complete_queue_path_count
        ),
        "terminal_controller_interactive_mesh_priority_path_count": (
            terminal_interactive_mesh_priority_count
        ),
        "dominant_segment_counts": dict(sorted(dominant_counts.items())),
        "terminal_controller_dominant_segment_counts": dict(sorted(
            terminal_dominant_counts.items()
        )),
        "terminal_controller_generation_origin_counts": dict(sorted(
            terminal_origin_counts.items()
        )),
        "terminal_controller_priority_outcome_counts": dict(sorted(
            terminal_priority_outcome_counts.items()
        )),
        "terminal_controller_overall_dominant": (
            {
                "identity": terminal_overall_dominant["identity"],
                **terminal_overall_dominant["dominant_segment"],
            }
            if terminal_overall_dominant is not None else None
        ),
        "overall_dominant": (
            {
                "identity": overall_dominant["identity"],
                **overall_dominant["dominant_segment"],
            }
            if overall_dominant is not None else None
        ),
        "paths": paths,
        "claim_boundary": (
            "Terminal controllers come from the exact cohort member with the last "
            "retained visibility-readiness event before publication. Complete path "
            "means required sinks and readiness are retained; demand origin and "
            "priority outcomes are reported independently because replacement "
            "generations can enter through viewer demand, transition remesh, or "
            "readiness repair paths. A scheduler-applied outcome does not claim that "
            "the page runtime still owned the same generation. Sampled paths remain "
            "cadence-bounded and can include a preceding cohort."
        ),
    }


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
        batch_candidates = [
            event for event in events
            if event.get("kind") == "visibility_batch_published"
            and int(event.get("elapsed_ns", 0)) >= ready_ns
        ]
        batch_event = next((
            event for event in batch_candidates
            if batch_contains_replacements(events, event, replacement_identities)
        ), None) or next(iter(batch_candidates), None)
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
        completion_elapsed_us = (
            int(final_event.get("elapsed_ns", origin_ns)) // 1000
            if final_event is not None else next_request_elapsed_us
        )
        blocker_analysis = sampled_blocker_analysis(
            [
                event for event in edit_frames
                if int(event.get("elapsed_us", -1)) <= completion_elapsed_us
            ],
            replacement_identities,
            request_elapsed_us,
        )
        publication_analysis = regional_publication_analysis(
            events,
            native_events,
            replacement_identities,
            origin_ns,
            ready_ns,
            batch_event,
        )
        destination_readiness = pre_edit_destination_readiness(
            downstream_events,
            native_events,
            request,
            submission,
        )
        blocker_critical_paths = publication_blocker_critical_path_analysis(
            native_events,
            blocker_analysis,
            publication_analysis,
            origin_ns,
            batch_event,
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
            "sampled_first_blocker": blocker_analysis,
            "publication_blocker_critical_paths": blocker_critical_paths,
            "pre_edit_destination_readiness": destination_readiness,
            "correlated_visibility_publication": publication_analysis,
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
            blocker = edit.get("sampled_first_blocker", {})
            critical_paths = edit.get("publication_blocker_critical_paths", {})
            publication = edit.get("correlated_visibility_publication", {})
            destination = edit.get("pre_edit_destination_readiness", {})
            usage_text = "cpu-window=n/a"
            if edit_usage.get("available"):
                usage_text = "cpu-window={cores:.2f} cores saturated={saturated:.3f}".format(
                    cores=float(edit_usage["average_active_logical_cores"]),
                    saturated=float(edit_usage["saturated_sample_fraction"]),
                )
            blocker_text = "blocker=n/a"
            if blocker.get("available"):
                blocker_text = "blocker={relation}/{reason}".format(
                    relation=blocker["dominant_relation"],
                    reason=blocker["dominant_reason"],
                )
            critical_text = "critical-path=n/a"
            overall_critical = (
                critical_paths.get("terminal_controller_overall_dominant")
                or critical_paths.get("overall_dominant")
            )
            if critical_paths.get("available") and isinstance(overall_critical, dict):
                critical_text = "critical-path={classification}/{duration:.3f}ms exact={exact}/{total}".format(
                    classification=overall_critical["classification"],
                    duration=float(overall_critical["duration_ms"]),
                    exact=critical_paths["exact_cohort_member_path_count"],
                    total=critical_paths["path_count"],
                )
            publication_text = "publication=n/a"
            if publication.get("available"):
                component = publication.get("publication_component_audit", {})
                publication_text = "publication={replacements}R/{retirements}D membership={membership}".format(
                    replacements=publication["replacement_count"],
                    retirements=publication["retirement_count"],
                    membership=(
                        "exact" if publication["exact_membership_available"]
                        else "correlated-only"
                    ),
                )
                if component.get("available"):
                    publication_text += " component={classification}".format(
                        classification=component["classification"],
                    )
            destination_text = "destination=n/a"
            if destination.get("available"):
                demand = destination.get("first_demand") or {}
                readiness = destination.get("full_readiness") or {}
                destination_text = "destination={classification} demand-lead={demand:.3f}ms ready-lead={ready}".format(
                    classification=destination["classification"],
                    demand=float(demand.get("before_edit_ms", 0.0)),
                    ready=(
                        f"{float(readiness['before_edit_ms']):.3f}ms"
                        if readiness.get("available") else "n/a"
                    ),
                )
            lines.append(
                "Edit {index} {mode}: relocation={distance} m completion={completion} ms dominant={dominant} {usage} {blocker} {critical} {publication} {destination}".format(
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
                    blocker=blocker_text,
                    critical=critical_text,
                    publication=publication_text,
                    destination=destination_text,
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
