#!/usr/bin/env python3
"""Run paired CPU-B2 trace-off/trace-on human-equivalent measurements."""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import sys
from typing import Any

import psutil

import godot_import_assets
import p0_runtime_baseline as baseline
import p2_production_integration_game_quality as integration_quality


SCHEMA = "world_transvoxel.cpu_b2_qualification.v1"
TRACE_SCHEMA = "world_transvoxel.cpu_causal_trace.v2"
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
    "publication_queued",
    "publication_popped",
    "frontend_publication_processed",
    "render_sink_applied",
    "collision_sink_applied",
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


def summarize_trace(trace: dict[str, Any]) -> dict[str, Any]:
    if trace.get("schema") != TRACE_SCHEMA or trace.get("final") is not True:
        raise RuntimeError("CPU-B2 trace is not a final v2 envelope")
    native = trace.get("native")
    events = native.get("events") if isinstance(native, dict) else None
    if not isinstance(native, dict) or not isinstance(events, list):
        raise RuntimeError("CPU-B2 native trace stream is missing")
    kinds = {str(event.get("kind")) for event in events if isinstance(event, dict)}
    missing = sorted(REQUIRED_NATIVE_KINDS - kinds)
    complete = native.get("complete") is True and not missing
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


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", help="Path to the Godot 4.7 executable.")
    parser.add_argument("--project", default=str(integration_quality.repo_root()))
    parser.add_argument("--pairs", type=int, default=1)
    parser.add_argument("--collision-radius", type=int, default=2)
    parser.add_argument("--collision-prediction", type=float, default=24.0)
    parser.add_argument("--procedural-generation-workers", type=int, default=2)
    parser.add_argument("--output", help="Qualification JSON output path.")
    args = parser.parse_args(argv)
    if args.pairs < 1:
        raise RuntimeError("--pairs must be at least 1")
    if not 1 <= args.procedural_generation_workers <= 2:
        raise RuntimeError("CPU-B2 permits one or two terrain workers")

    project = pathlib.Path(args.project).resolve()
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
    trace_paths: list[str] = []
    for index in range(1, args.pairs + 1):
        off_run, off_execution = baseline._run_measurement(
            godot, project, capture_dir, index, args.collision_radius,
            args.collision_prediction, args.procedural_generation_workers,
            stem_prefix="trace_off",
        )
        trace_path = trace_dir / f"trace_on_{index:02d}.json"
        on_run, on_execution = baseline._run_measurement(
            godot, project, capture_dir, index, args.collision_radius,
            args.collision_prediction, args.procedural_generation_workers,
            causal_trace_path=trace_path, stem_prefix="trace_on",
        )
        off_runs.append(off_run)
        on_runs.append(on_run)
        off_exec.append(off_execution)
        on_exec.append(on_execution)
        trace = load_object(trace_path)
        trace_summaries.append(summarize_trace(trace))
        trace_paths.append(str(trace_path.relative_to(project)).replace("\\", "/"))

    pin = load_object(project / "AUTHORITY_HOTFIX_PIN.json")
    traces_complete = all(item["complete"] for item in trace_summaries)
    report = {
        "schema": SCHEMA,
        "date": "2026-08-13",
        "status": "PASS" if traces_complete else "FAIL",
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
        "performance_comparison": pair_comparison(off_runs, on_runs, off_exec, on_exec),
        "trace_off": {"runs": off_runs, "executions": off_exec},
        "trace_on": {"runs": on_runs, "executions": on_exec},
        "claim_boundaries": {
            "authoritative_for": [
                "event availability and order on the Godot 4.7 CPU-B1 route",
                "bounded trace retention and explicit loss accounting",
                "observed trace overhead on this machine and route",
            ],
            "not_authoritative_for": [
                "performance remediation",
                "universal hardware overhead",
                "GPU architecture selection",
                "CPU or whole-system watts",
            ],
        },
    }
    output = pathlib.Path(args.output).resolve() if args.output else capture_dir / "qualification.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"WT_CPU_B2_{report['status']} pairs={args.pairs} output={output}")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
