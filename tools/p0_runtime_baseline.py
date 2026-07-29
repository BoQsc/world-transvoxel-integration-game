#!/usr/bin/env python3
"""Repeat and aggregate the g23 player-critical runtime baseline."""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import sys

import godot_import_assets
import p2_production_integration_game_quality as integration_quality


PROFILE = integration_quality.FOUR_BIOME_WORLD_PROFILE
MODE = "runtime_baseline_gate"


def _number(summary: dict[str, object], *path: str) -> float:
    value: object = summary
    for key in path:
        if not isinstance(value, dict):
            raise RuntimeError(f"baseline field path is not a dictionary: {path!r}")
        value = value[key]
    return float(value)


def _aggregate(
    runs: list[dict[str, object]],
    procedural_generation_workers: int,
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
        "authority_commit_frames": ("edit", "authority_commit_frames"),
        "visual_ready_frames_after_commit": (
            "edit",
            "visual_ready_frames_after_commit",
        ),
        "collision_ready_frames_after_commit": (
            "edit",
            "collision_ready_frames_after_commit",
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
    return {
        "schema": "world_transvoxel_p0_runtime_baseline_v2",
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
        "aggregates": aggregates,
        "runs": runs,
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
    integration_quality.verify_material_boundary_shader_contract(project)
    godot_import_assets.run_godot_import(godot, project)
    godot_import_assets.verify_imports(project)
    capture_dir = integration_quality.default_capture_dir(
        project, "p0_runtime_baseline"
    )
    baselines: list[dict[str, object]] = []
    for index in range(args.runs):
        _capture, summary = integration_quality.run_visual_capture_summary(
            godot,
            project,
            MODE,
            capture_dir,
            180,
            profile=PROFILE,
            capture_stem=f"run_{index + 1:02d}",
            extra_args=(
                "--player-collision-invoker-radius-chunks",
                str(args.collision_radius),
                "--player-collision-prediction-distance",
                str(args.collision_prediction),
                "--procedural-generation-workers",
                str(args.procedural_generation_workers),
            ),
        )
        baseline = summary.get("runtime_baseline")
        if not isinstance(baseline, dict):
            raise RuntimeError(f"runtime baseline result missing: {summary!r}")
        baselines.append(baseline)

    aggregate = _aggregate(baselines, args.procedural_generation_workers)
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
    print(f"WT_P0_RUNTIME_BASELINE_PASS runs={args.runs} output={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
