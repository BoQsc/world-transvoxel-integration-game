#!/usr/bin/env python3
"""Repeat and aggregate the g23 player-critical runtime baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import platform
import re
import subprocess
import statistics
import sys
import time

import psutil

import godot_import_assets
import p2_production_integration_game_quality as integration_quality


PROFILE = integration_quality.FOUR_BIOME_WORLD_PROFILE
MODE = "runtime_baseline_gate"
RUNTIME_BASELINE_PREFIX = "WT_RUNTIME_BASELINE_SUMMARY "


def _git(project: pathlib.Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", *args],
        cwd=project,
        text=True,
        capture_output=True,
        check=True,
    )
    return completed.stdout.strip()


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _runtime_baseline_from_stdout(stdout: str) -> dict[str, object]:
    for line in stdout.splitlines():
        if line.startswith(RUNTIME_BASELINE_PREFIX):
            value = json.loads(line[len(RUNTIME_BASELINE_PREFIX) :].strip())
            if not isinstance(value, dict):
                break
            return value
    raise RuntimeError("Godot output did not contain a runtime baseline summary")


def _validate_completed_measurement(baseline: dict[str, object]) -> None:
    if baseline.get("enabled") is not True:
        raise RuntimeError(f"runtime baseline was not enabled: {baseline!r}")
    if baseline.get("measurement_complete") is not True:
        raise RuntimeError(f"runtime baseline measurement was incomplete: {baseline!r}")
    for section in ("movement", "edit", "frame_time_ms", "backlog", "acceptance"):
        if not isinstance(baseline.get(section), dict):
            raise RuntimeError(f"runtime baseline section {section!r} is missing")
    if int(_number(baseline, "movement", "frames")) < 1000:
        raise RuntimeError("runtime baseline movement route was not fully exercised")
    if baseline["edit"].get("interaction_accepted") is not True:
        raise RuntimeError("runtime baseline edit was not accepted")


def _run_measurement(
    godot: pathlib.Path,
    project: pathlib.Path,
    capture_dir: pathlib.Path,
    index: int,
    collision_radius: int,
    collision_prediction: float,
    procedural_generation_workers: int,
) -> tuple[dict[str, object], dict[str, object]]:
    capture_dir.mkdir(parents=True, exist_ok=True)
    stem = f"run_{index:02d}"
    capture_path = capture_dir / f"{stem}.png"
    command = [
        str(godot),
        "--path",
        str(project),
        "--",
        "--p2-profile",
        PROFILE,
        "--human-visual-capture",
        str(capture_path),
        "--human-visual-capture-mode",
        MODE,
        "--human-visual-capture-wait-frames",
        "180",
        "--player-collision-invoker-radius-chunks",
        str(collision_radius),
        "--player-collision-prediction-distance",
        str(collision_prediction),
        "--procedural-generation-workers",
        str(procedural_generation_workers),
    ]
    started = time.perf_counter()
    process = subprocess.Popen(
        command,
        cwd=project,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    peak_rss_bytes = 0
    process_cpu_seconds = 0.0
    deadline = started + 1800.0
    while process.poll() is None:
        if time.perf_counter() >= deadline:
            process.kill()
            process.communicate()
            raise RuntimeError("runtime baseline exceeded 1800 seconds")
        try:
            tracked = [psutil.Process(process.pid)]
            tracked.extend(tracked[0].children(recursive=True))
            rss_bytes = 0
            cpu_seconds = 0.0
            for tracked_process in tracked:
                try:
                    rss_bytes += tracked_process.memory_info().rss
                    cpu = tracked_process.cpu_times()
                    cpu_seconds += cpu.user + cpu.system
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    continue
            peak_rss_bytes = max(peak_rss_bytes, rss_bytes)
            process_cpu_seconds = max(process_cpu_seconds, cpu_seconds)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
        time.sleep(0.05)
    stdout, stderr = process.communicate()
    wall_seconds = time.perf_counter() - started
    stdout_path = capture_dir / f"{stem}.stdout.log"
    stderr_path = capture_dir / f"{stem}.stderr.log"
    stdout_path.write_text(stdout, encoding="utf-8")
    stderr_path.write_text(stderr, encoding="utf-8")

    baseline = _runtime_baseline_from_stdout(stdout)
    _validate_completed_measurement(baseline)
    acceptance = baseline["acceptance"]
    failures = acceptance.get("failures", [])
    if not isinstance(failures, list):
        raise RuntimeError("runtime baseline acceptance failures are malformed")
    execution = {
        "run": index,
        "command": command,
        "godot_returncode": process.returncode,
        "wall_seconds": wall_seconds,
        "process_cpu_seconds": process_cpu_seconds,
        "average_active_cores": process_cpu_seconds / max(wall_seconds, 0.001),
        "peak_process_tree_rss_bytes": peak_rss_bytes,
        "measurement_complete": True,
        "target_status": (
            "MEASURED_TARGET_PASS"
            if acceptance.get("ok") is True
            else "MEASURED_TARGET_MISS"
        ),
        "acceptance_failures": failures,
        "stdout_log": str(stdout_path.relative_to(project)).replace("\\", "/"),
        "stderr_log": str(stderr_path.relative_to(project)).replace("\\", "/"),
        "renderer_device": _renderer_device(stdout),
    }
    print(
        "WT_P0_RUNTIME_BASELINE_RUN "
        f"run={index} status={execution['target_status']} "
        f"returncode={process.returncode} failures={','.join(str(v) for v in failures)}"
    )
    return baseline, execution


def _renderer_device(stdout: str) -> str:
    match = re.search(r"Using Device #\d+:\s*(.+)", stdout)
    return match.group(1).strip() if match else "unknown"


def _provenance(
    project: pathlib.Path,
    godot: pathlib.Path,
    affinity: list[int],
) -> dict[str, object]:
    pin = json.loads((project / "AUTHORITY_HOTFIX_PIN.json").read_text(encoding="utf-8"))
    debug_binary = project / "addons/world_transvoxel/bin/world_transvoxel.windows.template_debug.x86_64.dll"
    release_binary = project / "addons/world_transvoxel/bin/world_transvoxel.windows.template_release.x86_64.dll"
    return {
        "integration_repository": "world-transvoxel-integration-game",
        "integration_commit": _git(project, "rev-parse", "HEAD"),
        "integration_tree": _git(project, "rev-parse", "HEAD^{tree}"),
        "measurement_contract": "authoritative_cpu_human_baseline_v1",
        "authority_commit": pin["authority"]["commit"],
        "authority_addon_tree": pin["authority"]["addon_tree"],
        "authority_package_digest_sha256": pin["authority"]["package_digest_sha256"],
        "debug_binary_sha256": _sha256(debug_binary),
        "release_binary_sha256": _sha256(release_binary),
        "godot_executable": str(godot),
        "runtime_kind": "godot_editor_debug",
        "platform": platform.platform(),
        "processor": platform.processor(),
        "logical_cpu_count": os.cpu_count(),
        "logical_cpu_affinity": affinity,
        "power_source": _power_source(),
    }


def _power_source() -> dict[str, object]:
    battery = psutil.sensors_battery()
    if battery is None:
        return {"available": False}
    return {
        "available": True,
        "plugged_in": battery.power_plugged,
        "battery_percent": battery.percent,
        "watts_available": False,
    }


def _number(summary: dict[str, object], *path: str) -> float:
    value: object = summary
    for key in path:
        if not isinstance(value, dict):
            raise RuntimeError(f"baseline field path is not a dictionary: {path!r}")
        value = value[key]
    return float(value)


def _aggregate(
    runs: list[dict[str, object]],
    executions: list[dict[str, object]],
    procedural_generation_workers: int,
    provenance: dict[str, object],
) -> dict[str, object]:
    fields = {
        "blocked_frames": ("movement", "blocked_frames"),
        "maximum_consecutive_blocked_frames": (
            "movement",
            "maximum_consecutive_blocked_frames",
        ),
        "frame_p95_ms": ("frame_time_ms", "p95"),
        "frame_p99_ms": ("frame_time_ms", "p99"),
        "frame_maximum_ms": ("frame_time_ms", "maximum"),
        "physics_target_wait_frames": ("edit", "physics_target_wait_frames"),
        "physics_target_wait_ms": ("edit", "physics_target_wait_ms"),
        "authority_commit_frames": ("edit", "authority_commit_frames"),
        "authority_commit_ms": ("edit", "authority_commit_ms"),
        "visual_ready_frames_after_commit": (
            "edit",
            "visual_ready_frames_after_commit",
        ),
        "collision_ready_frames_after_commit": (
            "edit",
            "collision_ready_frames_after_commit",
        ),
        "relocation_to_visual_ready_ms": (
            "edit",
            "relocation_to_visual_ready_ms",
        ),
        "relocation_to_collision_ready_ms": (
            "edit",
            "relocation_to_collision_ready_ms",
        ),
        "visual_collision_divergence_frames": (
            "edit",
            "visual_collision_divergence_frames",
        ),
        "maximum_scheduler_queued_jobs": (
            "backlog",
            "maximum_scheduler_queued_jobs",
        ),
        "maximum_pending_chunk_replacements": (
            "backlog",
            "maximum_pending_chunk_replacements",
        ),
        "maximum_collision_apply_time_ms_observed": (
            "backlog",
            "maximum_collision_apply_time_ns_observed",
        ),
        "maximum_collision_apply_frame_time_ms_observed": (
            "runtime_metric_delta",
            "collision_apply_frame_time_ns_maximum_end",
        ),
        "maximum_collision_apply_frame_items_observed": (
            "runtime_metric_delta",
            "collision_apply_frame_items_maximum_end",
        ),
        "collision_apply_frame_deadline_overruns": (
            "runtime_metric_delta",
            "collision_apply_frame_deadline_overruns",
        ),
        "maximum_sample_job_time_ms_observed": (
            "runtime_metric_delta",
            "sample_job_time_ns_maximum_end",
        ),
        "maximum_mesh_job_time_ms_observed": (
            "runtime_metric_delta",
            "mesh_job_time_ns_maximum_end",
        ),
    }
    aggregates: dict[str, object] = {}
    for label, path in fields.items():
        values = [_number(run, *path) for run in runs]
        if label in {
            "maximum_collision_apply_time_ms_observed",
            "maximum_collision_apply_frame_time_ms_observed",
            "maximum_sample_job_time_ms_observed",
            "maximum_mesh_job_time_ms_observed",
        }:
            values = [value / 1_000_000.0 for value in values]
        aggregates[label] = {
            "values": values,
            "median": statistics.median(values),
            "minimum": min(values),
            "maximum": max(values),
        }
    execution_fields = {
        "wall_seconds": "wall_seconds",
        "process_cpu_seconds": "process_cpu_seconds",
        "average_active_cores": "average_active_cores",
        "peak_process_tree_rss_bytes": "peak_process_tree_rss_bytes",
    }
    for label, key in execution_fields.items():
        values = [float(run[key]) for run in executions]
        aggregates[label] = {
            "values": values,
            "median": statistics.median(values),
            "minimum": min(values),
            "maximum": max(values),
        }
    target_miss = any(run["target_status"] == "MEASURED_TARGET_MISS" for run in executions)
    failure_names = sorted(
        {
            str(failure)
            for run in executions
            for failure in run["acceptance_failures"]
        }
    )
    return {
        "schema": "world_transvoxel_authoritative_cpu_human_baseline_v1",
        "status": "MEASURED_TARGET_MISS" if target_miss else "MEASURED_TARGET_PASS",
        "correctness_status": "RETAINED_FROM_PINNED_REVIEWED_BASELINE",
        "causal_attribution_status": "UNRESOLVED_REQUIRES_REAL_TIME_PIPELINE_TRACE",
        "optimization_status": "BLOCKED_PENDING_CAUSAL_ATTRIBUTION",
        "tqp58_gpu_decision_status": "BLOCKED_PENDING_CAUSAL_ATTRIBUTION",
        "provenance": provenance,
        "profile": PROFILE,
        "mode": MODE,
        "run_count": len(runs),
        "collision_invoker_radius_chunks": int(
            _number(runs[0], "collision_invoker_radius_chunks")
        ),
        "collision_prediction_distance": _number(
            runs[0], "collision_prediction_distance"
        ),
        "procedural_generation_workers": procedural_generation_workers,
        "route_contract": {
            "movement_frames_per_run": int(_number(runs[0], "movement", "frames")),
            "normal_speed": _number(runs[0], "normal_speed"),
            "fast_speed": _number(runs[0], "fast_speed"),
            "fixed_post_flight_edit_position": runs[0]["fixed_post_flight_edit_position"],
            "edit_operation": "carve",
        },
        "observed_target_failures": failure_names,
        "aggregates": aggregates,
        "executions": executions,
        "runs": runs,
        "claim_boundaries": {
            "authoritative_for": [
                "Godot 4.7 editor/debug human-equivalent g23 flight frame behavior",
                "first carve readiness after fixed post-flight relocation",
                "three-logical-CPU comparison before optimization",
            ],
            "not_authoritative_for": [
                "release-export runtime performance",
                "CPU or whole-system watts",
                "root-cause attribution",
                "GPU architecture selection",
                "universal hardware performance",
            ],
        },
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", help="Path to a Godot 4 executable.")
    parser.add_argument(
        "--project",
        default=str(integration_quality.repo_root()),
        help="Path to the integration game project.",
    )
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--collision-radius", type=int, default=2)
    parser.add_argument("--collision-prediction", type=float, default=24.0)
    parser.add_argument("--procedural-generation-workers", type=int, default=2)
    parser.add_argument(
        "--output",
        help="Aggregate JSON output path. Defaults under .godot captures.",
    )
    args = parser.parse_args(argv)
    if args.runs < 1:
        raise RuntimeError("--runs must be at least 1")
    if not 1 <= args.procedural_generation_workers <= 8:
        raise RuntimeError("--procedural-generation-workers must be between 1 and 8")

    project = pathlib.Path(args.project).resolve()
    godot = integration_quality.find_godot(args.godot)
    affinity = psutil.Process().cpu_affinity()
    if affinity != [0, 1, 2]:
        raise RuntimeError(
            "authoritative baseline requires exact logical CPU affinity [0, 1, 2], "
            f"got {affinity!r}"
        )
    if _git(project, "status", "--short"):
        allowed = {"M scripts/wt_runtime_baseline_gate.gd", "M tools/p0_runtime_baseline.py"}
        actual = set(_git(project, "status", "--short").splitlines())
        if actual != allowed:
            raise RuntimeError(
                "baseline worktree has unrelated changes before measurement: "
                + ", ".join(sorted(actual))
            )
    integration_quality.verify_material_boundary_shader_contract(project)
    godot_import_assets.run_godot_import(godot, project)
    godot_import_assets.verify_imports(project)
    capture_dir = integration_quality.default_capture_dir(
        project, "p0_runtime_baseline"
    )
    baselines: list[dict[str, object]] = []
    executions: list[dict[str, object]] = []
    for index in range(args.runs):
        baseline, execution = _run_measurement(
            godot,
            project,
            capture_dir,
            index + 1,
            args.collision_radius,
            args.collision_prediction,
            args.procedural_generation_workers,
        )
        baselines.append(baseline)
        executions.append(execution)

    aggregate = _aggregate(
        baselines,
        executions,
        args.procedural_generation_workers,
        _provenance(project, godot, affinity),
    )
    output = (
        pathlib.Path(args.output).resolve()
        if args.output
        else capture_dir / "aggregate.json"
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(aggregate, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(aggregate["aggregates"], indent=2, sort_keys=True))
    print(
        "WT_P0_RUNTIME_BASELINE_RETAINED "
        f"status={aggregate['status']} runs={args.runs} output={output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
