#!/usr/bin/env python3
"""Run the paired TQP-64 large-world GPU meshing shadow qualification."""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import time
from typing import Any

import psutil


SCHEMA = "world_transvoxel.tqp64_gpu_shadow_qualification.v1"
PROFILE = "g23_four_biomes_lakes_mountains_roads_2k_256_on_demand"
MATERIAL = "production_texture_array"
CONTROLLER_COUNTERS = (
    "submitted_results",
    "matched_results",
    "terrain_matched_results",
    "static_water_matched_results",
    "transition_matched_results",
    "mismatched_results",
    "stale_results",
    "identity_rejections",
)
NATIVE_COUNTERS = (
    "queued_requests",
    "in_flight_requests",
    "captured_requests",
    "capacity_rejections",
    "matched_results",
    "mismatched_results",
    "stale_results",
    "unknown_results",
    "identity_mismatches",
)
EDIT_PHASES = ("relocated_carve", "relocated_construct")


def load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _status_snapshots(trace: dict[str, Any]) -> list[tuple[int, dict[str, Any]]]:
    snapshots: list[tuple[int, dict[str, Any]]] = []
    for event in trace.get("events", []):
        pipeline = event.get("pipeline")
        if not isinstance(pipeline, dict):
            continue
        status = pipeline.get("gpu_meshing_shadow")
        if isinstance(status, dict):
            snapshots.append((int(event.get("frame", 0)), status))
    return snapshots


def _maximum_counters(
    snapshots: list[tuple[int, dict[str, Any]]],
    keys: tuple[str, ...],
    nested_key: str | None = None,
) -> dict[str, int]:
    result = {key: 0 for key in keys}
    for _, status in snapshots:
        source = status.get(nested_key, {}) if nested_key else status
        if not isinstance(source, dict):
            continue
        for key in keys:
            result[key] = max(result[key], int(source.get(key, 0)))
    return result


def _edit_shadow_deltas(
    trace: dict[str, Any], snapshots: list[tuple[int, dict[str, Any]]]
) -> dict[str, int]:
    events = trace.get("events", [])
    end_frames = sorted(
        int(event.get("frame", 0))
        for event in events
        if event.get("kind") == "autonomous_edit_wait_finished"
    )
    result: dict[str, int] = {}
    for phase in EDIT_PHASES:
        starts = [
            int(event.get("frame", 0))
            for event in events
            if event.get("kind") == "phase_started" and event.get("phase") == phase
        ]
        if not starts:
            result[phase] = 0
            continue
        start_frame = starts[0]
        end_frame = next((frame for frame in end_frames if frame >= start_frame), start_frame)
        values = [
            int(status.get("terrain_matched_results", 0))
            for frame, status in snapshots
            if start_frame <= frame <= end_frame
        ]
        result[phase] = max(values, default=0) - min(values, default=0)
    return result


def summarize_trace(trace: dict[str, Any]) -> dict[str, Any]:
    snapshots = _status_snapshots(trace)
    native = trace.get("native", {})
    if not isinstance(native, dict):
        native = {}
    controller = _maximum_counters(snapshots, CONTROLLER_COUNTERS)
    native_counters = _maximum_counters(snapshots, NATIVE_COUNTERS, "native_metrics")
    return {
        "schema": trace.get("schema", ""),
        "reason": trace.get("reason", ""),
        "final": bool(trace.get("final", False)),
        "dropped_event_count": int(trace.get("dropped_event_count", 0)),
        "native_complete": bool(native.get("complete", False)),
        "native_consumer_gap_event_count": int(
            native.get("consumer_gap_event_count", 0)
        ),
        "native_local_dropped_event_count": int(
            native.get("local_dropped_event_count", 0)
        ),
        "snapshot_count": len(snapshots),
        "shadow_running_observed": any(
            bool(status.get("running", False)) for _, status in snapshots
        ),
        "cpu_render_authority": bool(snapshots) and all(
            bool(status.get("cpu_render_authority", False))
            for _, status in snapshots
        ),
        "cpu_collision_authority": bool(snapshots) and all(
            bool(status.get("cpu_collision_authority", False))
            for _, status in snapshots
        ),
        "gpu_publication_observed": any(
            bool(status.get("gpu_publication_enabled", False))
            for _, status in snapshots
        ),
        "controller_maximum": controller,
        "native_maximum": native_counters,
        "relocated_edit_terrain_match_deltas": _edit_shadow_deltas(
            trace, snapshots
        ),
    }


def summarize_report(report: dict[str, Any]) -> dict[str, Any]:
    traces = report.get("traces", [])
    trace = traces[0] if len(traces) == 1 else {}
    decision = report.get("decision", {})
    movement = trace.get("movement", {})
    frame_ms = movement.get("frame_ms", {})
    integrity = trace.get("integrity", {})
    coverage = trace.get("coverage", {})
    return {
        "classification": decision.get("classification", ""),
        "trace_count": len(traces),
        "trace_integrity_complete": bool(integrity.get("complete", False)),
        "required_human_route_covered": bool(
            decision.get("required_human_route_covered", False)
        ),
        "coverage": {
            key: bool(coverage.get(key, False))
            for key in (
                "has_flight",
                "has_long_flight",
                "has_carve",
                "has_construction",
                "has_relocated_edit",
            )
        },
        "flight_distance": float(movement.get("flight_distance", 0.0)),
        "flight_frame_count": int(movement.get("flight_frame_count", 0)),
        "blocked_flight_frame_count": int(
            movement.get("blocked_flight_frame_count", 0)
        ),
        "frame_ms": {
            key: float(frame_ms.get(key, 0.0))
            for key in ("mean", "p50", "p95", "p99", "maximum")
        },
        "relocated_edit_count": len(
            [edit for edit in trace.get("edits", []) if edit.get("relocated_area")]
        ),
    }


def summarize_usage(usage: dict[str, Any]) -> dict[str, Any]:
    gpu_utilization = usage.get("gpu_board_utilization_percent", {})
    gpu_power = usage.get("gpu_board_power_watts", {})
    return {
        "logical_cpu_affinity": usage.get("logical_cpu_affinity", []),
        "logical_cpu_capacity": int(usage.get("logical_cpu_capacity", 0)),
        "wall_seconds": float(usage.get("wall_seconds", 0.0)),
        "process_cpu_percent_mean": float(
            usage.get("process_cpu_percent_mean", 0.0)
        ),
        "process_cpu_percent_maximum": float(
            usage.get("process_cpu_percent_maximum", 0.0)
        ),
        "average_active_logical_cores": float(
            usage.get("average_active_logical_cores", 0.0)
        ),
        "rss_bytes_maximum": int(usage.get("rss_bytes_maximum", 0)),
        "gpu_board_telemetry_scope": usage.get(
            "gpu_board_telemetry_scope", "unavailable"
        ),
        "gpu_board_utilization_percent": gpu_utilization,
        "gpu_board_power_watts": gpu_power,
    }


def evaluate_run(mode: str, summary: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    trace = summary["trace"]
    report = summary["report"]
    usage = summary["usage"]
    required = {
        "process_exit_zero": summary["exit_code"] == 0,
        "trace_final": trace["final"],
        "trace_native_complete": trace["native_complete"],
        "trace_no_dropped_events": trace["dropped_event_count"] == 0,
        "trace_no_native_consumer_gaps": (
            trace["native_consumer_gap_event_count"] == 0
        ),
        "trace_no_native_local_drops": trace["native_local_dropped_event_count"] == 0,
        "report_single_trace": report["trace_count"] == 1,
        "report_integrity_complete": report["trace_integrity_complete"],
        "route_covered": report["required_human_route_covered"],
        "cpu_limit_at_most_three": 0 < usage["logical_cpu_capacity"] <= 3,
        "cpu_render_authority": trace["cpu_render_authority"],
        "cpu_collision_authority": trace["cpu_collision_authority"],
        "gpu_never_published": not trace["gpu_publication_observed"],
    }
    if mode == "cpu_baseline":
        required["shadow_disabled"] = not trace["shadow_running_observed"]
    else:
        controller = trace["controller_maximum"]
        native = trace["native_maximum"]
        edit_deltas = trace["relocated_edit_terrain_match_deltas"]
        required.update(
            {
                "shadow_running": trace["shadow_running_observed"],
                "shadow_captured": native["captured_requests"] > 0,
                "shadow_matched": controller["matched_results"] > 0,
                "terrain_matched": controller["terrain_matched_results"] > 0,
                "transition_matched": controller["transition_matched_results"] > 0,
                "relocated_carve_matched": edit_deltas["relocated_carve"] > 0,
                "relocated_construct_matched": edit_deltas["relocated_construct"] > 0,
                "no_controller_mismatch": controller["mismatched_results"] == 0,
                "no_controller_identity_rejection": (
                    controller["identity_rejections"] == 0
                ),
                "no_native_mismatch": native["mismatched_results"] == 0,
                "no_native_unknown_result": native["unknown_results"] == 0,
                "no_native_identity_mismatch": native["identity_mismatches"] == 0,
            }
        )
    for name, passed in required.items():
        if not passed:
            failures.append(name)
    summary["requirements"] = required
    return failures


def _percent_change(baseline: float, candidate: float) -> float | None:
    if baseline == 0.0:
        return None
    return ((candidate - baseline) / baseline) * 100.0


def compare_pair(baseline: dict[str, Any], shadow: dict[str, Any]) -> dict[str, Any]:
    baseline_frame = baseline["report"]["frame_ms"]
    shadow_frame = shadow["report"]["frame_ms"]
    baseline_usage = baseline["usage"]
    shadow_usage = shadow["usage"]
    fields = {
        "wall_seconds": (
            baseline_usage["wall_seconds"], shadow_usage["wall_seconds"]
        ),
        "process_cpu_percent_mean": (
            baseline_usage["process_cpu_percent_mean"],
            shadow_usage["process_cpu_percent_mean"],
        ),
        "frame_p95_ms": (baseline_frame["p95"], shadow_frame["p95"]),
        "frame_p99_ms": (baseline_frame["p99"], shadow_frame["p99"]),
        "gpu_board_utilization_mean_percent": (
            float(
                baseline_usage["gpu_board_utilization_percent"].get("mean", 0.0)
            ),
            float(shadow_usage["gpu_board_utilization_percent"].get("mean", 0.0)),
        ),
        "gpu_board_power_mean_watts": (
            float(baseline_usage["gpu_board_power_watts"].get("mean", 0.0)),
            float(shadow_usage["gpu_board_power_watts"].get("mean", 0.0)),
        ),
    }
    return {
        name: {
            "cpu_baseline": values[0],
            "gpu_shadow": values[1],
            "shadow_change_percent": _percent_change(values[0], values[1]),
        }
        for name, values in fields.items()
    }


def _terminate_tree(process: subprocess.Popen[str]) -> None:
    try:
        parent = psutil.Process(process.pid)
        children = parent.children(recursive=True)
        for child in children:
            child.terminate()
        parent.terminate()
        _, alive = psutil.wait_procs([*children, parent], timeout=5.0)
        for item in alive:
            item.kill()
    except psutil.Error:
        process.kill()


def run_mode(
    project: pathlib.Path,
    raw_root: pathlib.Path,
    driver: str,
    mode: str,
    godot: str | None,
    timeout_seconds: float,
) -> dict[str, Any]:
    stem = f"{driver}_{mode}"
    trace_path = raw_root / f"{stem}_trace.json"
    report_path = raw_root / f"{stem}_report.json"
    usage_path = raw_root / f"{stem}_usage.json"
    log_path = raw_root / f"{stem}.log"
    command = [
        sys.executable,
        str(project / "tools" / "run_human_playtest.py"),
        "--project",
        str(project),
        "--latest",
        "--windowed",
        "--terrain-waterfall-autonomous",
        "--terrain-waterfall-output",
        str(trace_path),
        "--terrain-waterfall-report-output",
        str(report_path),
        "--rendering-driver",
        driver,
        "--procedural-generation-workers",
        "2",
    ]
    if godot:
        command.extend(["--godot", godot])
    if mode == "gpu_shadow":
        command.append("--gpu-meshing-shadow")

    raw_root.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    process = subprocess.Popen(
        command,
        cwd=project,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
    )
    try:
        output, _ = process.communicate(timeout=timeout_seconds)
        exit_code = process.returncode
    except subprocess.TimeoutExpired:
        _terminate_tree(process)
        output, _ = process.communicate()
        output += f"\nTQP64_TIMEOUT seconds={timeout_seconds}\n"
        exit_code = 124
    log_path.write_text(output, encoding="utf-8")

    result: dict[str, Any] = {
        "driver": driver,
        "mode": mode,
        "exit_code": exit_code,
        "runner_wall_seconds": time.perf_counter() - started,
        "artifacts": {
            "trace": trace_path.relative_to(project).as_posix(),
            "report": report_path.relative_to(project).as_posix(),
            "usage": usage_path.relative_to(project).as_posix(),
            "log": log_path.relative_to(project).as_posix(),
        },
    }
    missing = [path.name for path in (trace_path, report_path, usage_path) if not path.is_file()]
    if missing:
        result["missing_artifacts"] = missing
        result["trace"] = summarize_trace({})
        result["report"] = summarize_report({})
        result["usage"] = summarize_usage({})
    else:
        result["trace"] = summarize_trace(load_json(trace_path))
        result["report"] = summarize_report(load_json(report_path))
        result["usage"] = summarize_usage(load_json(usage_path))
    result["failures"] = evaluate_run(mode, result)
    result["passed"] = not result["failures"]
    return result


def parse_args(argv: list[str]) -> argparse.Namespace:
    default_project = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(
        description="Run paired TQP-64 CPU baseline/GPU shadow large-world routes."
    )
    parser.add_argument("--project", default=str(default_project))
    parser.add_argument("--godot")
    parser.add_argument(
        "--drivers",
        nargs="+",
        choices=("vulkan", "d3d12"),
        default=("vulkan", "d3d12"),
    )
    parser.add_argument("--timeout-seconds", type=float, default=300.0)
    parser.add_argument(
        "--output",
        help="Committed compact qualification JSON path.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    project = pathlib.Path(args.project).resolve()
    if not (project / "project.godot").is_file():
        raise FileNotFoundError(f"project.godot not found under {project}")
    raw_root = (
        project
        / ".godot"
        / "world_transvoxel_captures"
        / "tqp64_gpu_shadow_qualification"
    )
    output_path = (
        pathlib.Path(args.output).resolve()
        if args.output
        else project
        / "docs"
        / "evidence"
        / "tqp64_large_world_gpu_shadow_20260824"
        / "qualification.json"
    )
    pairs: dict[str, Any] = {}
    all_passed = True
    for driver in dict.fromkeys(args.drivers):
        print(f"TQP64_START driver={driver} mode=cpu_baseline", flush=True)
        baseline = run_mode(
            project, raw_root, driver, "cpu_baseline", args.godot,
            args.timeout_seconds,
        )
        print(
            f"TQP64_RESULT driver={driver} mode=cpu_baseline "
            f"passed={baseline['passed']} failures={baseline['failures']}",
            flush=True,
        )
        print(f"TQP64_START driver={driver} mode=gpu_shadow", flush=True)
        shadow = run_mode(
            project, raw_root, driver, "gpu_shadow", args.godot,
            args.timeout_seconds,
        )
        print(
            f"TQP64_RESULT driver={driver} mode=gpu_shadow "
            f"passed={shadow['passed']} failures={shadow['failures']}",
            flush=True,
        )
        pair_passed = baseline["passed"] and shadow["passed"]
        pairs[driver] = {
            "passed": pair_passed,
            "cpu_baseline": baseline,
            "gpu_shadow": shadow,
            "comparison": compare_pair(baseline, shadow),
        }
        all_passed = all_passed and pair_passed

    payload = {
        "schema": SCHEMA,
        "classification": (
            "PASS_LARGE_WORLD_SHADOW_VALIDATION"
            if all_passed
            else "FAIL_LARGE_WORLD_SHADOW_VALIDATION"
        ),
        "passed": all_passed,
        "profile": PROFILE,
        "material": MATERIAL,
        "logical_cpu_limit": 3,
        "drivers": list(pairs),
        "pairs": pairs,
        "claim_boundary": {
            "validation_only": True,
            "cpu_render_authority": True,
            "cpu_collision_authority": True,
            "gpu_publication_qualified": False,
            "performance_promotion": False,
            "trace_timing_is_release_baseline": False,
            "gpu_board_telemetry_scope": "board_global_not_process_attributed",
        },
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"TQP64_QUALIFICATION classification={payload['classification']} "
        f"output={output_path}",
        flush=True,
    )
    return 0 if all_passed else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
