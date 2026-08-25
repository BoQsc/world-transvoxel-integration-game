#!/usr/bin/env python3
"""Qualify the TQP-64 resident GPU candidate against the CPU large-world route."""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import time
from typing import Any

import psutil

import run_tqp64_gpu_shadow_qualification as shared


SCHEMA = "world_transvoxel.tqp64_gpu_resident_qualification.v1"
PROFILE = "g23_four_biomes_lakes_mountains_roads_2k_256_on_demand"
MATERIAL = "production_texture_array"
STATUS_COUNTERS = (
    "tracked_chunks",
    "active_chunks",
    "submitted_surfaces",
    "validated_surfaces",
    "activated_chunks",
    "retired_chunks",
    "rejected_chunks",
    "recovery_count",
    "application_wait_expirations",
)
EFFECT_COUNTERS = (
    "resident_entry_count",
    "active_entry_count",
    "prepared_entries",
    "activated_entries",
    "retired_entries",
    "resident_capacity_rejections",
    "indirect_draw_calls",
    "geometry_readback_bytes",
    "arena_page_count",
    "arena_allocated_slot_count",
    "arena_peak_active_slot_count",
    "arena_allocated_bytes",
    "arena_slot_leases",
    "arena_slot_reuses",
    "arena_slot_releases",
    "packing_requests",
    "packing_usec_total",
    "packing_usec_max",
    "packed_bytes_total",
    "native_packed_requests",
    "native_packed_bytes_total",
    "visibility_test_count",
    "visibility_culled_count",
    "compact_indirect_command_records",
    "source_cell_indirect_records_avoided",
    "max_compact_command_records_per_view",
    "max_source_cell_records_avoided_per_view",
)
NATIVE_COUNTERS = (
    "capacity",
    "captured_requests",
    "capacity_rejections",
    "reserved_capture_slots",
    "capture_reservation_attempts",
    "capture_reservation_rejections",
    "reserved_captures",
    "released_capture_slots",
    "priority_dequeues",
    "dequeue_superseded_requests",
    "queued_requests",
    "in_flight_requests",
    "validation_attempts",
    "validation_ready",
    "validation_rejections",
    "stale_skips",
    "readiness_attempts",
    "readiness_waits",
    "readiness_ready",
    "readiness_stale",
    "activated_chunks",
    "retired_chunks",
    "restored_cpu_chunks",
)


def _snapshots(trace: dict[str, Any]) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    result = []
    for event in trace.get("events", []):
        pipeline = event.get("pipeline")
        if not isinstance(pipeline, dict):
            continue
        status = pipeline.get("gpu_resident_render")
        if isinstance(status, dict):
            result.append((pipeline, status))
    return result


def _maximum(
    snapshots: list[tuple[dict[str, Any], dict[str, Any]]],
    keys: tuple[str, ...],
    nested: str | None = None,
) -> dict[str, int]:
    result = {key: 0 for key in keys}
    for _, status in snapshots:
        source = status.get(nested, {}) if nested else status
        if not isinstance(source, dict):
            continue
        for key in keys:
            result[key] = max(result[key], int(source.get(key, 0)))
    return result


def summarize_trace(trace: dict[str, Any]) -> dict[str, Any]:
    snapshots = _snapshots(trace)
    native_envelope = trace.get("native", {})
    if not isinstance(native_envelope, dict):
        native_envelope = {}
    coverage_ratios = []
    for pipeline, status in snapshots:
        metrics = pipeline.get("metrics", {})
        render_resources = int(metrics.get("render_resources", 0)) \
            if isinstance(metrics, dict) else 0
        if render_resources > 0:
            coverage_ratios.append(
                int(status.get("active_chunks", 0)) / render_resources
            )
    final_status = snapshots[-1][1] if snapshots else {}
    final_native = final_status.get("native_metrics", {}) \
        if isinstance(final_status, dict) else {}
    if not isinstance(final_native, dict):
        final_native = {}
    return {
        "schema": trace.get("schema", ""),
        "reason": trace.get("reason", ""),
        "final": bool(trace.get("final", False)),
        "dropped_event_count": int(trace.get("dropped_event_count", 0)),
        "native_complete": bool(native_envelope.get("complete", False)),
        "native_consumer_gap_event_count": int(
            native_envelope.get("consumer_gap_event_count", 0)
        ),
        "native_local_dropped_event_count": int(
            native_envelope.get("local_dropped_event_count", 0)
        ),
        "snapshot_count": len(snapshots),
        "running_observed": any(
            bool(status.get("running", False)) for _, status in snapshots
        ),
        "cpu_collision_authority": bool(snapshots) and all(
            bool(status.get("cpu_collision_authority", False))
            for _, status in snapshots
        ),
        "production_material_parity": bool(snapshots) and all(
            bool(status.get("production_material_parity", False))
            for _, status in snapshots
            if bool(status.get("running", False))
        ),
        "native_request_handoff_decoupled": any(
            bool(status.get("native_request_handoff_decoupled", False))
            for _, status in snapshots
        ),
        "native_world_position_space": bool(snapshots) and all(
            str(status.get("native_position_space", "")) == "world"
            for _, status in snapshots
            if bool(status.get("running", False))
        ),
        "compacted_surface_indirect_commands": bool(snapshots) and all(
            bool(status.get("effect_status", {}).get(
                "compacted_surface_indirect_commands", False
            ))
            for _, status in snapshots
            if bool(status.get("running", False))
        ),
        "maximum": _maximum(snapshots, STATUS_COUNTERS),
        "effect_maximum": _maximum(snapshots, EFFECT_COUNTERS, "effect_status"),
        "native_maximum": _maximum(snapshots, NATIVE_COUNTERS, "native_metrics"),
        "native_final": {
            key: int(final_native.get(key, 0)) for key in NATIVE_COUNTERS
        },
        "maximum_gpu_chunk_coverage_ratio": max(coverage_ratios, default=0.0),
        "final_status": {
            "tracked_chunks": int(final_status.get("tracked_chunks", 0)),
            "active_chunks": int(final_status.get("active_chunks", 0)),
            "last_error": str(final_status.get("last_error", "")),
        },
    }


def _run_mode(
    project: pathlib.Path,
    raw_root: pathlib.Path,
    driver: str,
    mode: str,
    godot: str | None,
    timeout_seconds: float,
) -> int:
    stem = f"{driver}_{mode}"
    command = [
        sys.executable,
        str(project / "tools" / "run_human_playtest.py"),
        "--project",
        str(project),
        "--latest",
        "--windowed",
        "--terrain-waterfall-autonomous",
        "--terrain-waterfall-output",
        str(raw_root / f"{stem}_trace.json"),
        "--terrain-waterfall-report-output",
        str(raw_root / f"{stem}_report.json"),
        "--rendering-driver",
        driver,
        "--procedural-generation-workers",
        "2",
    ]
    if godot:
        command.extend(["--godot", godot])
    if mode == "gpu_resident":
        command.append("--gpu-resident-render-candidate")
    started = time.perf_counter()
    process = subprocess.Popen(command, cwd=project)
    try:
        exit_code = process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        shared._terminate_tree(process)
        exit_code = 124
    print(
        f"TQP64_RESIDENT_RUN driver={driver} mode={mode} exit={exit_code} "
        f"seconds={time.perf_counter() - started:.3f}",
        flush=True,
    )
    return exit_code


def _load_mode(raw_root: pathlib.Path, driver: str, mode: str) -> dict[str, Any]:
    stem = f"{driver}_{mode}"
    paths = {
        kind: raw_root / f"{stem}_{kind}.json"
        for kind in ("trace", "report", "usage")
    }
    missing = [path.name for path in paths.values() if not path.is_file()]
    if missing:
        return {"missing_artifacts": missing, "measurement_pass": False}
    trace_source = shared.load_json(paths["trace"])
    result = {
        "artifacts": {
            key: path.name for key, path in paths.items()
        },
        "trace": summarize_trace(trace_source),
        "report": shared.summarize_report(shared.load_json(paths["report"])),
        "usage": shared.summarize_usage(shared.load_json(paths["usage"])),
    }
    trace = result["trace"]
    report = result["report"]
    usage = result["usage"]
    requirements = {
        "trace_final": bool(trace.get("final")),
        "native_trace_complete": bool(trace.get("native_complete")),
        "no_trace_drops": int(trace.get("dropped_event_count", 0)) == 0,
        "no_native_trace_gaps": (
            int(trace.get("native_consumer_gap_event_count", 0)) == 0
        ),
        "no_native_local_drops": (
            int(trace.get("native_local_dropped_event_count", 0)) == 0
        ),
        "single_complete_report": (
            int(report.get("trace_count", 0)) == 1
            and bool(report.get("trace_integrity_complete", False))
        ),
        "required_route_covered": bool(
            report.get("required_human_route_covered", False)
        ),
        "logical_cpu_limit": 0 < int(usage.get("logical_cpu_capacity", 0)) <= 3,
    }
    if mode == "gpu_resident":
        maximum = trace.get("maximum", {})
        effect = trace.get("effect_maximum", {})
        native = trace.get("native_maximum", {})
        native_final = trace.get("native_final", {})
        requirements.update({
            "resident_route_observed": bool(trace.get("running_observed", False)),
            "cpu_collision_authoritative": bool(
                trace.get("cpu_collision_authority", False)
            ),
            "exact_handoff_decoupled": bool(
                trace.get("native_request_handoff_decoupled", False)
            ),
            "native_world_position_space": bool(
                trace.get("native_world_position_space", False)
            ),
            "compacted_surface_indirect_commands": bool(
                trace.get("compacted_surface_indirect_commands", False)
            ),
            "compaction_observed": (
                int(effect.get("compact_indirect_command_records", 0)) > 0
                and int(effect.get(
                    "source_cell_indirect_records_avoided", 0
                )) > 0
            ),
            "visibility_tested": int(
                effect.get("visibility_test_count", 0)
            ) > 0,
            "resident_chunk_activated": int(maximum.get("activated_chunks", 0)) > 0,
            "resident_entry_retired": int(
                effect.get("retired_entries", 0)
            ) > 0,
            "arena_slot_reuse_observed": (
                int(effect.get("arena_slot_releases", 0)) > 0
                and int(effect.get("arena_slot_reuses", 0)) > 0
            ),
            "pre_mesh_capture_admission_observed": (
                int(native.get("capture_reservation_attempts", 0)) > 0
                and int(native.get("reserved_captures", 0)) > 0
            ),
            "no_capture_reservation_leak": int(
                native_final.get("reserved_capture_slots", -1)
            ) == 0,
            "no_fail_closed_recovery": int(maximum.get("recovery_count", 0)) == 0,
            "no_geometry_readback": int(
                effect.get("geometry_readback_bytes", -1)
            ) == 0,
        })
    result["requirements"] = requirements
    result["measurement_pass"] = all(requirements.values())
    return result


def _percent_change(baseline: float, candidate: float) -> float | None:
    return None if baseline == 0.0 else ((candidate - baseline) / baseline) * 100.0


def _comparison(baseline: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    baseline_frame = baseline["report"]["frame_ms"]
    candidate_frame = candidate["report"]["frame_ms"]
    baseline_usage = baseline["usage"]
    candidate_usage = candidate["usage"]
    pairs = {
        "wall_seconds": (
            baseline_usage["wall_seconds"], candidate_usage["wall_seconds"]
        ),
        "frame_p95_ms": (baseline_frame["p95"], candidate_frame["p95"]),
        "frame_p99_ms": (baseline_frame["p99"], candidate_frame["p99"]),
        "rss_bytes_maximum": (
            baseline_usage["rss_bytes_maximum"],
            candidate_usage["rss_bytes_maximum"],
        ),
        "process_cpu_percent_mean": (
            baseline_usage["process_cpu_percent_mean"],
            candidate_usage["process_cpu_percent_mean"],
        ),
        "gpu_board_utilization_mean_percent": (
            float(baseline_usage["gpu_board_utilization_percent"].get("mean", 0)),
            float(candidate_usage["gpu_board_utilization_percent"].get("mean", 0)),
        ),
        "gpu_board_power_mean_watts": (
            float(baseline_usage["gpu_board_power_watts"].get("mean", 0)),
            float(candidate_usage["gpu_board_power_watts"].get("mean", 0)),
        ),
    }
    return {
        key: {
            "cpu_baseline": values[0],
            "gpu_resident": values[1],
            "candidate_change_percent": _percent_change(values[0], values[1]),
        }
        for key, values in pairs.items()
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    project_default = pathlib.Path(__file__).resolve().parents[1]
    parser.add_argument("--project", type=pathlib.Path, default=project_default)
    parser.add_argument("--godot")
    parser.add_argument(
        "--drivers", nargs="+", choices=("vulkan", "d3d12"), default=("vulkan",)
    )
    parser.add_argument("--timeout-seconds", type=float, default=240.0)
    parser.add_argument("--reuse-raw", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args(argv)
    project = args.project.resolve()
    raw_root = args.reuse_raw.resolve() if args.reuse_raw else (
        project / ".godot" / "world_transvoxel_captures"
        / "tqp64_gpu_resident_qualification"
    )
    raw_root.mkdir(parents=True, exist_ok=True)
    output = args.output.resolve() if args.output else (
        project / "docs" / "evidence"
        / "tqp64_large_world_gpu_resident_candidate_20260825"
        / "qualification.json"
    )
    results = {}
    measurement_pass = True
    for driver in dict.fromkeys(args.drivers):
        if args.reuse_raw is None:
            for mode in ("cpu_baseline", "gpu_resident"):
                _run_mode(
                    project, raw_root, driver, mode, args.godot,
                    args.timeout_seconds,
                )
        baseline = _load_mode(raw_root, driver, "cpu_baseline")
        candidate = _load_mode(raw_root, driver, "gpu_resident")
        pair_measurement_pass = bool(
            baseline.get("measurement_pass", False)
            and candidate.get("measurement_pass", False)
        )
        comparison = _comparison(baseline, candidate) \
            if pair_measurement_pass else {}
        promotion_gates = {}
        if pair_measurement_pass:
            trace = candidate["trace"]
            maximum = trace["maximum"]
            native = trace["native_maximum"]
            promotion_gates = {
                "production_material_parity": bool(
                    trace["production_material_parity"]
                ),
                "at_least_95_percent_chunk_coverage": (
                    float(trace["maximum_gpu_chunk_coverage_ratio"]) >= 0.95
                ),
                "no_candidate_rejections": int(maximum["rejected_chunks"]) == 0,
                "no_native_capacity_rejections": (
                    int(native["capacity_rejections"]) == 0
                ),
                "frame_p95_within_10_percent": (
                    float(candidate["report"]["frame_ms"]["p95"])
                    <= float(baseline["report"]["frame_ms"]["p95"]) * 1.10
                ),
                "rss_within_25_percent": (
                    int(candidate["usage"]["rss_bytes_maximum"])
                    <= int(baseline["usage"]["rss_bytes_maximum"]) * 1.25
                ),
                "wall_time_within_25_percent": (
                    float(candidate["usage"]["wall_seconds"])
                    <= float(baseline["usage"]["wall_seconds"]) * 1.25
                ),
            }
        results[driver] = {
            "measurement_pass": pair_measurement_pass,
            "promotion_pass": bool(promotion_gates) and all(
                promotion_gates.values()
            ),
            "cpu_baseline": baseline,
            "gpu_resident": candidate,
            "comparison": comparison,
            "promotion_gates": promotion_gates,
        }
        measurement_pass = measurement_pass and pair_measurement_pass
    promotion_pass = measurement_pass and all(
        item["promotion_pass"] for item in results.values()
    )
    payload = {
        "schema": SCHEMA,
        "classification": (
            "PASS_PRODUCTION_GPU_RESIDENT"
            if promotion_pass
            else "BLOCKED_PRODUCTION_GPU_RESIDENT_ARCHITECTURE"
        ),
        "measurement_pass": measurement_pass,
        "promotion_pass": promotion_pass,
        "profile": PROFILE,
        "material": MATERIAL,
        "logical_cpu_limit": 3,
        "drivers": list(results),
        "results": results,
        "claim_boundary": {
            "bounded_lifecycle_qualified_separately": True,
            "whole_chunk_relocation_qualified_separately": True,
            "large_world_production_backend_qualified": promotion_pass,
            "cpu_collision_authority": True,
            "production_material_parity": False,
            "gpu_field_generation": False,
            "performance_promotion": False,
            "gpu_board_telemetry_scope": "board_global_not_process_attributed",
        },
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"TQP64_GPU_RESIDENT_QUALIFICATION classification={payload['classification']} "
        f"measurement_pass={measurement_pass} promotion_pass={promotion_pass} "
        f"output={output}",
        flush=True,
    )
    return 0 if measurement_pass else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
