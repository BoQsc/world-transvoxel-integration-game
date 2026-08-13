#!/usr/bin/env python3
"""Run paired CPU-B2 trace-off/trace-on human-equivalent measurements."""

from __future__ import annotations

import argparse
from collections import Counter
import json
import pathlib
import statistics
import sys
from typing import Any

import psutil

import godot_import_assets
import p0_runtime_baseline as baseline
import p2_production_integration_game_quality as integration_quality


SCHEMA = "world_transvoxel.cpu_b2_qualification.v3"
TRACE_SCHEMA = "world_transvoxel.cpu_causal_trace.v2"
CAUSAL_EDIT_READY_WAIT_FRAMES = 1800
REQUIRED_NATIVE_KINDS = {
    "trace_started",
    "trace_stopped",
    "viewer_plan_started",
    "viewer_plan_applied",
    "chunk_demand_accepted",
    "edit_submitted",
    "edit_processing_started",
    "edit_committed",
    "storage_requested",
    "storage_started",
    "storage_finished",
    "storage_completion_consumed",
    "sample_started",
    "sample_finished",
    "mesh_started",
    "mesh_finished",
    "mesh_completion_consumed",
    "transition_mesh_started",
    "transition_mesh_finished",
    "transition_mesh_completion_consumed",
    "publication_queued",
    "publication_popped",
    "frontend_publication_processed",
    "render_sink_applied",
    "collision_sink_applied",
    "visibility_replacement_ready",
    "visibility_staging_blocked",
    "visibility_batch_published",
}

EDIT_REPLACEMENT_KINDS = {
    "storage_requested",
    "storage_started",
    "storage_finished",
    "storage_completion_consumed",
    "sample_started",
    "sample_finished",
    "mesh_started",
    "mesh_finished",
    "mesh_completion_consumed",
    "publication_queued",
    "publication_popped",
    "frontend_publication_processed",
    "render_sink_applied",
    "collision_sink_applied",
    "visibility_replacement_ready",
}


def load_object(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError(f"expected a JSON object: {path}")
    return value


def median(values: list[float]) -> float:
    return float(statistics.median(values))


def relative_delta(traced: float, untraced: float) -> float | None:
    if untraced == 0.0:
        return None
    return (traced - untraced) / untraced


def event_identity(event: dict[str, Any]) -> tuple[int, int, int, int, int] | None:
    if event.get("has_chunk") is not True:
        return None
    return tuple(
        int(event[name])
        for name in ("chunk_x", "chunk_y", "chunk_z", "chunk_lod", "generation")
    )


def event_elapsed_ms(event: dict[str, Any], origin_ns: int) -> float:
    return (int(event["elapsed_ns"]) - origin_ns) / 1_000_000.0


def transition_attribution(trace: dict[str, Any]) -> dict[str, Any]:
    native_events = [
        event for event in trace["native"]["events"] if isinstance(event, dict)
    ]
    started = [
        event for event in native_events
        if event.get("kind") == "transition_mesh_started"
    ]
    finished = [
        event for event in native_events
        if event.get("kind") == "transition_mesh_finished"
    ]
    consumed = [
        event for event in native_events
        if event.get("kind") == "transition_mesh_completion_consumed"
    ]

    def job_key(event: dict[str, Any]) -> tuple[int, ...] | None:
        identity = event_identity(event)
        if identity is None:
            return None
        return (*identity, int(event.get("cause_id", -1)), int(event.get("auxiliary", -1)))

    def completion_key(event: dict[str, Any]) -> tuple[int, ...] | None:
        identity = event_identity(event)
        if identity is None:
            return None
        return (*identity, int(event.get("auxiliary", -1)))

    started_jobs = Counter(key for event in started if (key := job_key(event)) is not None)
    finished_jobs = Counter(key for event in finished if (key := job_key(event)) is not None)
    successful_finished_completions = Counter(
        key for event in finished
        if int(event.get("status", -1)) == 0
        and (key := completion_key(event)) is not None
    )
    consumed_completions = Counter(
        key for event in consumed if (key := completion_key(event)) is not None
    )
    masks = sorted({
        int(event.get("auxiliary", -1)) for event in [*started, *finished, *consumed]
    })
    invalid_masks = [mask for mask in masks if mask < 1 or mask > 0x3F]
    unsuccessful_finishes = sum(
        1 for event in finished if int(event.get("status", -1)) != 0
    )
    unmatched_consumptions = consumed_completions - successful_finished_completions
    complete = (
        bool(started)
        and bool(finished)
        and bool(consumed)
        and started_jobs == finished_jobs
        and not unmatched_consumptions
        and not invalid_masks
    )
    return {
        "complete": complete,
        "classification": (
            "EXPLICIT_TRANSITION_MESH_CHAIN_CONFIRMED" if complete else "UNATTRIBUTED"
        ),
        "started_event_count": len(started),
        "finished_event_count": len(finished),
        "completion_consumed_event_count": len(consumed),
        "transition_masks": masks,
        "invalid_transition_masks": invalid_masks,
        "unmatched_started_jobs": sum((started_jobs - finished_jobs).values()),
        "unmatched_finished_jobs": sum((finished_jobs - started_jobs).values()),
        "unmatched_completion_consumptions": sum(unmatched_consumptions.values()),
        "unsuccessful_finished_jobs": unsuccessful_finishes,
        "claim_boundary": (
            "This proves explicit transition-mask meshing work traversed the measured "
            "CPU route; it does not infer transition correctness from aggregate counters."
        ),
    }


def causal_attribution(trace: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    native = trace["native"]
    native_events = [event for event in native["events"] if isinstance(event, dict)]
    downstream_events = [event for event in trace["events"] if isinstance(event, dict)]
    edit_events = [event for event in native_events if event.get("kind") == "edit_submitted"]
    if len(edit_events) != 1:
        return ({
            "complete": False,
            "classification": "UNATTRIBUTED",
            "failure": f"expected one native edit submission, found {len(edit_events)}",
        }, edit_events)

    edit = edit_events[0]
    edit_ns = int(edit["elapsed_ns"])
    edit_cause = int(edit["cause_id"])
    demands = [
        event for event in native_events
        if event.get("kind") == "chunk_demand_accepted"
        and int(event.get("cause_id", -1)) == edit_cause
        and int(event.get("auxiliary", -1)) == 1
    ]
    replacement_identities = {
        identity for identity in (event_identity(event) for event in demands)
        if identity is not None
    }
    replacement_reports: list[dict[str, Any]] = []
    causal_slice = [edit, *demands]
    all_replacements_complete = bool(replacement_identities)
    latest_sink_ns = edit_ns
    latest_ready_ns = edit_ns
    for identity in sorted(replacement_identities):
        events = [
            event for event in native_events
            if event_identity(event) == identity
            and int(event["elapsed_ns"]) >= edit_ns
        ]
        kinds = {str(event.get("kind")) for event in events}
        missing = sorted(EDIT_REPLACEMENT_KINDS - kinds)
        all_replacements_complete = all_replacements_complete and not missing
        stages: dict[str, list[float]] = {}
        for event in events:
            kind = str(event.get("kind"))
            if kind in EDIT_REPLACEMENT_KINDS:
                stages.setdefault(kind, []).append(event_elapsed_ms(event, edit_ns))
                causal_slice.append(event)
            if kind in {"render_sink_applied", "collision_sink_applied"}:
                latest_sink_ns = max(latest_sink_ns, int(event["elapsed_ns"]))
            if kind == "visibility_replacement_ready":
                latest_ready_ns = max(latest_ready_ns, int(event["elapsed_ns"]))
        replacement_reports.append({
            "chunk": {
                "x": identity[0], "y": identity[1], "z": identity[2],
                "lod": identity[3], "generation": identity[4],
            },
            "complete": not missing,
            "missing_event_kinds": missing,
            "stage_elapsed_ms": stages,
        })

    visibility_events = [
        event for event in native_events
        if str(event.get("kind", "")).startswith("visibility_")
        and int(event["elapsed_ns"]) >= edit_ns
    ]
    blockers = [
        event for event in visibility_events
        if event.get("kind") == "visibility_staging_blocked"
        and int(event["elapsed_ns"]) >= latest_ready_ns
    ]
    batches = [
        event for event in visibility_events
        if event.get("kind") == "visibility_batch_published"
        and int(event["elapsed_ns"]) >= latest_ready_ns
    ]
    blocker = blockers[0] if blockers else None
    batch = batches[0] if batches else None
    decisive_visibility_events = [
        event for event in (blocker, blockers[-1] if blockers else None, batch)
        if event is not None
    ]
    causal_slice.extend(decisive_visibility_events)
    downstream_exact = [{
        "kind": event.get("kind"),
        "elapsed_us": int(event.get("elapsed_us", -1)),
        "frame": int(event.get("frame", -1)),
        "cause_id": event.get("cause_id"),
        "payload": event.get("payload"),
    } for event in downstream_events
        if event.get("kind") in {"exact_render_published", "exact_collision_published"}
    ]
    causal_slice.extend(downstream_exact)

    blocker_is_global = (
        blocker is not None
        and int(blocker.get("cause_id", 0)) > len(replacement_identities)
    )
    complete = (
        all_replacements_complete
        and blocker_is_global
        and batch is not None
        and bool(downstream_exact)
    )
    last_sink_ms = (latest_sink_ns - edit_ns) / 1_000_000.0
    last_ready_ms = (latest_ready_ns - edit_ns) / 1_000_000.0
    batch_ms = event_elapsed_ms(batch, edit_ns) if batch is not None else None
    return ({
        "complete": complete,
        "classification": (
            "GLOBAL_VISIBILITY_STAGING_BARRIER_AFTER_RELOCATION"
            if complete else "UNATTRIBUTED"
        ),
        "edit_cause_id": edit_cause,
        "edit_replacement_count": len(replacement_identities),
        "all_edit_replacement_pipelines_complete": all_replacements_complete,
        "edit_replacements": replacement_reports,
        "last_edit_replacement_sink_elapsed_ms": last_sink_ms,
        "last_edit_replacement_ready_elapsed_ms": last_ready_ms,
        "first_global_blocker_after_ready": None if blocker is None else {
            "elapsed_ms": event_elapsed_ms(blocker, edit_ns),
            "pending_chunk_replacements": int(blocker["cause_id"]),
            "pending_chunk_retirements": int(blocker["auxiliary"]),
            "pending_render_retirements": int(blocker["status"]),
        },
        "first_visibility_batch_after_ready": None if batch is None else {
            "elapsed_ms": batch_ms,
            "staged_render_records": int(batch["cause_id"]),
            "staged_collision_records": int(batch["auxiliary"]),
        },
        "visibility_wait_after_last_sink_ms": (
            None if batch_ms is None else batch_ms - last_sink_ms
        ),
        "exact_publication_events": downstream_exact,
        "finding": (
            "Edited chunks completed storage, sampling, meshing, publication, and "
            "both Godot sinks before a relocation-wide replacement set cleared; "
            "the conservative global visibility batch was the observed delay."
            if complete else
            "The trace did not establish the complete edit-to-visibility chain."
        ),
    }, sorted(causal_slice, key=lambda event: int(event.get("elapsed_ns", 0))))


def movement_attribution(trace: dict[str, Any]) -> dict[str, Any]:
    downstream_events = [event for event in trace["events"] if isinstance(event, dict)]
    moving_frames = [
        event for event in downstream_events
        if event.get("kind") == "physics_frame"
        and float(event.get("movement", {}).get("requested_speed", 0.0)) > 0.0
    ]
    blocked_frames = [
        event for event in moving_frames
        if event.get("movement", {}).get("accepted") is False
    ]
    sampled_blocked = [
        event for event in blocked_frames
        if isinstance(event.get("pipeline", {}).get("metrics"), dict)
    ]
    metric_names = (
        "collision_required_not_ready_chunk_records",
        "pending_chunk_replacements",
        "blocked_pending_chunk_replacements",
        "scheduler_queued_jobs",
        "storage_queued_requests",
        "pending_chunk_retirements",
    )
    blocked_samples = []
    for event in sampled_blocked:
        metrics = event["pipeline"]["metrics"]
        blocked_samples.append({
            "frame": int(event["frame"]),
            "phase": str(event.get("phase", "")),
            "frame_ms": float(event.get("frame_us", 0)) / 1000.0,
            "metrics": {name: int(metrics.get(name, -1)) for name in metric_names},
        })
    largest_frame = max(moving_frames, key=lambda event: int(event.get("frame_us", 0)))
    largest_metrics = largest_frame.get("pipeline", {}).get("metrics", {})
    complete = (
        bool(blocked_frames)
        and bool(sampled_blocked)
        and all(
            int(event["pipeline"]["metrics"].get(
                "collision_required_not_ready_chunk_records", 0
            )) > 0
            and int(event["pipeline"]["metrics"].get(
                "blocked_pending_chunk_replacements", 0
            )) > 0
            for event in sampled_blocked
        )
    )
    return {
        "complete": complete,
        "classification": (
            "COLLISION_READINESS_GATE_DURING_RELOCATION_BACKLOG"
            if complete else "UNATTRIBUTED"
        ),
        "movement_frames": len(moving_frames),
        "blocked_movement_frames": len(blocked_frames),
        "sampled_blocked_movement_frames": len(sampled_blocked),
        "blocked_samples": blocked_samples,
        "largest_movement_frame": {
            "frame": int(largest_frame["frame"]),
            "phase": str(largest_frame.get("phase", "")),
            "frame_ms": float(largest_frame.get("frame_us", 0)) / 1000.0,
            "movement_accepted": bool(largest_frame["movement"].get("accepted")),
            "metrics": {
                name: int(largest_metrics.get(name, -1)) for name in metric_names
            } if largest_metrics else {},
        },
        "finding": (
            "Observed movement rejection is the production player's collision-"
            "readiness gate while relocation has a large not-ready collision and "
            "replacement backlog. The largest movement-frame hitch was accepted, "
            "so frame-time spikes remain a separate CPU-B3 target."
            if complete else
            "The trace did not retain enough blocked movement context."
        ),
        "claim_boundary": (
            "This run attributes observed movement rejection, not every source of "
            "flight frame-time variance."
        ),
    }


def summarize_trace(trace: dict[str, Any]) -> dict[str, Any]:
    if trace.get("schema") != TRACE_SCHEMA or trace.get("final") is not True:
        raise RuntimeError("CPU-B2 trace is not a final v2 envelope")
    native = trace.get("native")
    events = native.get("events") if isinstance(native, dict) else None
    if not isinstance(native, dict) or not isinstance(events, list):
        raise RuntimeError("CPU-B2 native trace stream is missing")
    kinds = {str(event.get("kind")) for event in events if isinstance(event, dict)}
    missing = sorted(REQUIRED_NATIVE_KINDS - kinds)
    transition = transition_attribution(trace)
    complete = native.get("complete") is True and not missing and transition["complete"]
    downstream_events = trace.get("events")
    if not isinstance(downstream_events, list):
        raise RuntimeError("CPU-B2 downstream trace stream is missing")
    observer = trace.get("observer")
    if not isinstance(observer, dict):
        raise RuntimeError("CPU-B2 observer summary is missing")
    event_count = int(trace.get("event_count", 0))
    return {
        "complete": complete,
        "missing_native_event_kinds": missing,
        "native_event_kinds": sorted(kinds),
        "transition_attribution": transition,
        "native_event_count": len(events),
        "native_source_overwrite_count": int(native.get("source_overwrite_count", -1)),
        "native_consumer_gap_event_count": int(native.get("consumer_gap_event_count", -1)),
        "native_local_dropped_event_count": int(native.get("local_dropped_event_count", -1)),
        "downstream_event_count": event_count,
        "downstream_dropped_event_count": int(trace.get("dropped_event_count", -1)),
        "observer_capture_us_total": int(observer.get("capture_time_us_total", -1)),
        "observer_capture_us_maximum": int(observer.get("capture_time_us_maximum", -1)),
        "pipeline_snapshot_count": int(observer.get("pipeline_snapshot_count", -1)),
        "pipeline_capture_us_total": int(observer.get("pipeline_capture_time_us_total", -1)),
        "native_capture_us_total": int(native.get("capture_time_us_total", -1)),
        "native_capture_us_maximum": int(native.get("capture_time_us_maximum", -1)),
        "serialization_probe_us": int(observer.get("serialization_probe_us", -1)),
        "duration_us": int(trace.get("duration_us", -1)),
    }


def metric(run: dict[str, Any], *keys: str) -> float:
    value: Any = run
    for key in keys:
        if not isinstance(value, dict):
            raise RuntimeError(f"malformed metric path: {keys}")
        value = value[key]
    return float(value)


def pair_comparison(
    untraced_runs: list[dict[str, Any]],
    traced_runs: list[dict[str, Any]],
    untraced_executions: list[dict[str, Any]],
    traced_executions: list[dict[str, Any]],
) -> dict[str, Any]:
    fields = {
        "frame_p95_ms": ("frame_time_ms", "p95"),
        "frame_p99_ms": ("frame_time_ms", "p99"),
        "frame_maximum_ms": ("frame_time_ms", "maximum"),
        "blocked_movement_frames": ("movement", "blocked_frames"),
        "authority_commit_ms": ("edit", "authority_commit_ms"),
        "relocation_to_visual_ready_ms": ("edit", "relocation_to_visual_ready_ms"),
        "relocation_to_collision_ready_ms": ("edit", "relocation_to_collision_ready_ms"),
    }
    output: dict[str, Any] = {}
    for name, path in fields.items():
        off_values = [metric(run, *path) for run in untraced_runs]
        on_values = [metric(run, *path) for run in traced_runs]
        off_median = median(off_values)
        on_median = median(on_values)
        output[name] = {
            "trace_off_values": off_values,
            "trace_on_values": on_values,
            "trace_off_median": off_median,
            "trace_on_median": on_median,
            "delta": on_median - off_median,
            "relative_delta": relative_delta(on_median, off_median),
        }
    for name in ("wall_seconds", "process_cpu_seconds", "average_active_cores"):
        off_values = [float(item[name]) for item in untraced_executions]
        on_values = [float(item[name]) for item in traced_executions]
        off_median = median(off_values)
        on_median = median(on_values)
        output[name] = {
            "trace_off_values": off_values,
            "trace_on_values": on_values,
            "trace_off_median": off_median,
            "trace_on_median": on_median,
            "delta": on_median - off_median,
            "relative_delta": relative_delta(on_median, off_median),
        }
    return output


def write_causal_slices(
    output: pathlib.Path,
    trace_paths: list[str],
    causal_slices: list[list[dict[str, Any]]],
) -> list[str]:
    slice_paths = []
    for index, events in enumerate(causal_slices, start=1):
        slice_path = output.parent / f"causal_slice_{index:02d}.json"
        slice_path.write_text(json.dumps({
            "schema": "world_transvoxel.cpu_b2_causal_slice.v1",
            "source_trace": trace_paths[index - 1],
            "events": events,
        }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        slice_paths.append(slice_path.name)
    return slice_paths


def reanalyze_existing(project: pathlib.Path, output: pathlib.Path) -> int:
    report = load_object(output)
    trace_contract = report.get("trace_contract")
    trace_paths = trace_contract.get("trace_paths") if isinstance(trace_contract, dict) else None
    if not isinstance(trace_paths, list) or not trace_paths:
        raise RuntimeError("existing CPU-B2 report has no trace paths")
    traces = [load_object(project / str(path)) for path in trace_paths]
    summaries = [summarize_trace(trace) for trace in traces]
    causal_runs = []
    causal_slices = []
    movement_runs = []
    transition_runs = []
    for trace in traces:
        causal_run, causal_slice = causal_attribution(trace)
        causal_runs.append(causal_run)
        causal_slices.append(causal_slice)
        movement_runs.append(movement_attribution(trace))
        transition_runs.append(transition_attribution(trace))
    traces_complete = all(item["complete"] for item in summaries)
    causal_complete = all(item["complete"] for item in causal_runs)
    movement_complete = all(item["complete"] for item in movement_runs)
    transition_complete = all(item["complete"] for item in transition_runs)
    report["schema"] = SCHEMA
    report["status"] = "PASS" if (
        traces_complete and causal_complete and movement_complete and transition_complete
    ) else "FAIL"
    report["trace_contract"]["summaries"] = summaries
    report["trace_contract"]["traces_complete"] = traces_complete
    report["causal_attribution"] = {
        "complete": causal_complete,
        "classification": (
            "GLOBAL_VISIBILITY_STAGING_BARRIER_AFTER_RELOCATION"
            if causal_complete else "UNATTRIBUTED"
        ),
        "runs": causal_runs,
    }
    report["movement_attribution"] = {
        "complete": movement_complete,
        "classification": (
            "COLLISION_READINESS_GATE_DURING_RELOCATION_BACKLOG"
            if movement_complete else "UNATTRIBUTED"
        ),
        "runs": movement_runs,
    }
    report["transition_attribution"] = {
        "complete": transition_complete,
        "classification": (
            "EXPLICIT_TRANSITION_MESH_CHAIN_CONFIRMED"
            if transition_complete else "UNATTRIBUTED"
        ),
        "runs": transition_runs,
    }
    report["claim_boundaries"] = {
        "authoritative_for": [
            "event availability and order on the Godot 4.7 CPU-B1 route",
            "bounded trace retention and explicit loss accounting",
            "observed trace overhead on this machine and route",
            "causal attribution of delayed first-edit visibility on this route",
            "causal attribution of observed collision-gated movement rejection",
            "explicit transition-mask mesh work on the measured CPU route",
        ],
        "not_authoritative_for": [
            "performance remediation",
            "complete attribution of flight frame-time spikes",
            "universal hardware overhead",
            "GPU architecture selection",
            "CPU or whole-system watts",
        ],
    }
    report["trace_contract"]["retained_causal_slices"] = write_causal_slices(
        output, [str(path) for path in trace_paths], causal_slices
    )
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"WT_CPU_B2_REANALYZE_{report['status']} output={output}")
    return 0 if report["status"] == "PASS" else 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", help="Path to the Godot 4.7 executable.")
    parser.add_argument("--project", default=str(integration_quality.repo_root()))
    parser.add_argument("--pairs", type=int, default=1)
    parser.add_argument("--collision-radius", type=int, default=2)
    parser.add_argument("--collision-prediction", type=float, default=24.0)
    parser.add_argument("--procedural-generation-workers", type=int, default=2)
    parser.add_argument("--output", help="Qualification JSON output path.")
    parser.add_argument("--reanalyze-existing", action="store_true")
    args = parser.parse_args(argv)
    if args.pairs < 1:
        raise RuntimeError("--pairs must be at least 1")
    if not 1 <= args.procedural_generation_workers <= 2:
        raise RuntimeError("CPU-B2 permits one or two terrain workers")

    project = pathlib.Path(args.project).resolve()
    if args.reanalyze_existing:
        if not args.output:
            raise RuntimeError("--reanalyze-existing requires --output")
        return reanalyze_existing(project, pathlib.Path(args.output).resolve())
    godot = integration_quality.find_godot(args.godot)
    affinity = psutil.Process().cpu_affinity()
    if affinity != [0, 1, 2]:
        raise RuntimeError(f"CPU-B2 requires exact affinity [0, 1, 2], got {affinity!r}")
    if baseline._git(project, "status", "--short"):
        raise RuntimeError("CPU-B2 requires a clean committed integration worktree")
    integration_quality.verify_material_boundary_shader_contract(project)
    godot_import_assets.run_godot_import(godot, project)
    godot_import_assets.verify_imports(project)

    capture_dir = integration_quality.default_capture_dir(project, "cpu_b2_causal_trace")
    trace_dir = capture_dir / "traces"
    off_runs: list[dict[str, Any]] = []
    on_runs: list[dict[str, Any]] = []
    off_exec: list[dict[str, Any]] = []
    on_exec: list[dict[str, Any]] = []
    trace_summaries: list[dict[str, Any]] = []
    trace_attributions: list[dict[str, Any]] = []
    movement_attributions: list[dict[str, Any]] = []
    transition_attributions: list[dict[str, Any]] = []
    causal_slices: list[list[dict[str, Any]]] = []
    trace_paths: list[str] = []
    for index in range(1, args.pairs + 1):
        off_run, off_execution = baseline._run_measurement(
            godot, project, capture_dir, index, args.collision_radius,
            args.collision_prediction, args.procedural_generation_workers,
            stem_prefix="trace_off",
            edit_ready_wait_frames=CAUSAL_EDIT_READY_WAIT_FRAMES,
        )
        trace_path = trace_dir / f"trace_on_{index:02d}.json"
        on_run, on_execution = baseline._run_measurement(
            godot, project, capture_dir, index, args.collision_radius,
            args.collision_prediction, args.procedural_generation_workers,
            causal_trace_path=trace_path, stem_prefix="trace_on",
            edit_ready_wait_frames=CAUSAL_EDIT_READY_WAIT_FRAMES,
        )
        off_runs.append(off_run)
        on_runs.append(on_run)
        off_exec.append(off_execution)
        on_exec.append(on_execution)
        trace = load_object(trace_path)
        trace_summaries.append(summarize_trace(trace))
        attribution, causal_slice = causal_attribution(trace)
        trace_attributions.append(attribution)
        movement_attributions.append(movement_attribution(trace))
        transition_attributions.append(transition_attribution(trace))
        causal_slices.append(causal_slice)
        trace_paths.append(str(trace_path.relative_to(project)).replace("\\", "/"))

    pin = load_object(project / "AUTHORITY_HOTFIX_PIN.json")
    traces_complete = all(item["complete"] for item in trace_summaries)
    attributions_complete = all(item["complete"] for item in trace_attributions)
    movement_attributions_complete = all(
        item["complete"] for item in movement_attributions
    )
    transition_attributions_complete = all(
        item["complete"] for item in transition_attributions
    )
    report = {
        "schema": SCHEMA,
        "date": "2026-08-13",
        "status": "PASS" if (
            traces_complete
            and attributions_complete
            and movement_attributions_complete
            and transition_attributions_complete
        ) else "FAIL",
        "milestone": "CPU-B2",
        "purpose": "real-time causal terrain pipeline trace qualification",
        "provenance": baseline._provenance(project, godot, affinity),
        "authority_pin": pin["authority"],
        "route": {
            "profile": baseline.PROFILE,
            "mode": baseline.MODE,
            "pairs": args.pairs,
            "collision_radius_chunks": args.collision_radius,
            "collision_prediction_distance": args.collision_prediction,
            "procedural_generation_workers": args.procedural_generation_workers,
            "logical_cpu_affinity": affinity,
            "edit_ready_observation_frames": CAUSAL_EDIT_READY_WAIT_FRAMES,
        },
        "trace_contract": {
            "schema": TRACE_SCHEMA,
            "required_native_event_kinds": sorted(REQUIRED_NATIVE_KINDS),
            "no_aggregate_fallback": True,
            "trace_disabled_by_default": True,
            "traces_complete": traces_complete,
            "trace_paths": trace_paths,
            "summaries": trace_summaries,
        },
        "causal_attribution": {
            "complete": attributions_complete,
            "classification": (
                "GLOBAL_VISIBILITY_STAGING_BARRIER_AFTER_RELOCATION"
                if attributions_complete else "UNATTRIBUTED"
            ),
            "runs": trace_attributions,
        },
        "movement_attribution": {
            "complete": movement_attributions_complete,
            "classification": (
                "COLLISION_READINESS_GATE_DURING_RELOCATION_BACKLOG"
                if movement_attributions_complete else "UNATTRIBUTED"
            ),
            "runs": movement_attributions,
        },
        "transition_attribution": {
            "complete": transition_attributions_complete,
            "classification": (
                "EXPLICIT_TRANSITION_MESH_CHAIN_CONFIRMED"
                if transition_attributions_complete else "UNATTRIBUTED"
            ),
            "runs": transition_attributions,
        },
        "performance_comparison": pair_comparison(off_runs, on_runs, off_exec, on_exec),
        "trace_off": {"runs": off_runs, "executions": off_exec},
        "trace_on": {"runs": on_runs, "executions": on_exec},
        "claim_boundaries": {
            "authoritative_for": [
                "event availability and order on the Godot 4.7 CPU-B1 route",
                "bounded trace retention and explicit loss accounting",
                "observed trace overhead on this machine and route",
                "causal attribution of delayed first-edit visibility on this route",
                "causal attribution of observed collision-gated movement rejection",
                "explicit transition-mask mesh work on the measured CPU route",
            ],
            "not_authoritative_for": [
                "performance remediation",
                "complete attribution of flight frame-time spikes",
                "universal hardware overhead",
                "GPU architecture selection",
                "CPU or whole-system watts",
            ],
        },
    }
    output = pathlib.Path(args.output).resolve() if args.output else capture_dir / "qualification.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    report["trace_contract"]["retained_causal_slices"] = write_causal_slices(
        output, trace_paths, causal_slices
    )
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"WT_CPU_B2_{report['status']} pairs={args.pairs} output={output}")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
