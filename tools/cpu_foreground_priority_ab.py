#!/usr/bin/env python3
"""Run one bounded CPU foreground-priority off/on comparison."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

import psutil

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import p0_runtime_baseline as baseline
import p2_production_integration_game_quality as integration_quality


AFFINITY = [0, 1, 2]


def _value(root: dict[str, object], *path: str) -> object:
    value: object = root
    for key in path:
        if not isinstance(value, dict) or key not in value:
            raise RuntimeError(f"missing measurement field: {'.'.join(path)}")
        value = value[key]
    return value


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _measurement_summary(
    result: dict[str, object],
    execution: dict[str, object],
    trace_path: pathlib.Path,
    project: pathlib.Path,
) -> dict[str, object]:
    return {
        "target_status": execution["target_status"],
        "wall_seconds": execution["wall_seconds"],
        "average_active_cores": execution["average_active_cores"],
        "frame_p95_ms": _value(result, "frame_time_ms", "p95"),
        "frame_p99_ms": _value(result, "frame_time_ms", "p99"),
        "movement_blocked_frames": _value(
            result, "movement", "blocked_frames"
        ),
        "physics_target_wait_ms": _value(
            result, "edit", "physics_target_wait_ms"
        ),
        "authority_commit_ms": _value(result, "edit", "authority_commit_ms"),
        "relocation_to_visual_ready_ms": _value(
            result, "edit", "relocation_to_visual_ready_ms"
        ),
        "relocation_to_collision_ready_ms": _value(
            result, "edit", "relocation_to_collision_ready_ms"
        ),
        "visual_ready_frames_after_commit": _value(
            result, "edit", "visual_ready_frames_after_commit"
        ),
        "collision_ready_frames_after_commit": _value(
            result, "edit", "collision_ready_frames_after_commit"
        ),
        "maximum_scheduler_queued_jobs": _value(
            result, "backlog", "maximum_scheduler_queued_jobs"
        ),
        "foreground_priority": {
            key: _value(result, "runtime_metric_delta", key)
            for key in (
                "foreground_priority_updates",
                "foreground_priority_matched_keys",
                "foreground_priority_missing_keys",
                "foreground_priority_changed_priorities",
                "foreground_priority_active_sources_end",
                "foreground_priority_support_keys_end",
                "foreground_priority_focus_keys_end",
            )
        },
        "trace": {
            "path": trace_path.relative_to(project).as_posix(),
            "bytes": trace_path.stat().st_size,
            "sha256": _sha256(trace_path),
        },
    }


def _difference(
    disabled: dict[str, object], enabled: dict[str, object], key: str
) -> float:
    return float(enabled[key]) - float(disabled[key])


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", help="Path to a Godot 4 executable.")
    parser.add_argument(
        "--project",
        default=str(integration_quality.repo_root()),
        help="Path to the integration game project.",
    )
    parser.add_argument("--output", required=True)
    parser.add_argument("--collision-radius", type=int, default=2)
    parser.add_argument("--collision-prediction", type=float, default=24.0)
    parser.add_argument("--procedural-generation-workers", type=int, default=2)
    parser.add_argument("--meshing-workers", type=int, default=0)
    parser.add_argument(
        "--order",
        choices=("disabled-first", "enabled-first"),
        default="disabled-first",
    )
    args = parser.parse_args(argv)

    process = psutil.Process()
    process.cpu_affinity(AFFINITY)
    affinity = process.cpu_affinity()
    if affinity != AFFINITY:
        raise RuntimeError(f"exact logical CPU affinity required, got {affinity!r}")

    project = pathlib.Path(args.project).resolve()
    godot = integration_quality.find_godot(args.godot)
    capture_dir = (
        project
        / ".godot/world_transvoxel_captures/cpu_foreground_priority_ab"
        / args.order
    )
    capture_dir.mkdir(parents=True, exist_ok=True)

    results: dict[str, tuple[dict[str, object], dict[str, object]]] = {}
    traces: dict[str, pathlib.Path] = {}
    policies = (
        ("enabled", "disabled")
        if args.order == "enabled-first"
        else ("disabled", "enabled")
    )
    for index, policy in enumerate(policies):
        trace_path = capture_dir / f"{policy}_causal_trace.json"
        traces[policy] = trace_path
        print(f"WT_FOREGROUND_PRIORITY_AB_START policy={policy}", flush=True)
        results[policy] = baseline._run_measurement(
            godot,
            project,
            capture_dir,
            index,
            args.collision_radius,
            args.collision_prediction,
            args.procedural_generation_workers,
            args.meshing_workers,
            causal_trace_path=trace_path,
            stem_prefix=policy,
            edit_ready_wait_frames=900,
            extra_args=[
                "--foreground-priority",
                policy,
                "--foreground-priority-focus-settle-frames",
                "6",
            ],
        )

    disabled = _measurement_summary(
        *results["disabled"], traces["disabled"], project
    )
    enabled = _measurement_summary(
        *results["enabled"], traces["enabled"], project
    )
    disabled_priority = disabled["foreground_priority"]
    enabled_priority = enabled["foreground_priority"]
    assert isinstance(disabled_priority, dict)
    assert isinstance(enabled_priority, dict)
    disabled_is_inert = all(int(value) == 0 for value in disabled_priority.values())
    enabled_is_effective = (
        int(enabled_priority["foreground_priority_updates"]) > 0
        and int(enabled_priority["foreground_priority_matched_keys"]) > 0
        and int(enabled_priority["foreground_priority_changed_priorities"]) > 0
    )
    implementation_valid = disabled_is_inert and enabled_is_effective

    comparison_keys = (
        "wall_seconds",
        "frame_p95_ms",
        "frame_p99_ms",
        "movement_blocked_frames",
        "physics_target_wait_ms",
        "authority_commit_ms",
        "relocation_to_visual_ready_ms",
        "relocation_to_collision_ready_ms",
        "visual_ready_frames_after_commit",
        "collision_ready_frames_after_commit",
        "maximum_scheduler_queued_jobs",
    )
    output = {
        "schema": "world_transvoxel_cpu_foreground_priority_ab_v1",
        "status": "DIAGNOSTIC_COMPLETE" if implementation_valid else "FAIL",
        "purpose": "bounded player-support and cursor-target scheduling priority",
        "affinity": affinity,
        "provenance": baseline._provenance(project, godot, affinity),
        "route": {
            "profile": baseline.PROFILE,
            "mode": baseline.MODE,
            "fresh_storage_per_run": True,
            "procedural_generation_workers": args.procedural_generation_workers,
            "meshing_workers": args.meshing_workers,
            "collision_radius_chunks": args.collision_radius,
            "collision_prediction_distance": args.collision_prediction,
            "focus_settle_frames": 6,
            "run_order": list(policies),
        },
        "contract": {
            "changes_residency_or_lod_topology": False,
            "changes_collision_or_visual_roles": False,
            "support_points": "player position and two metres below",
            "focus_point": "physics ray hit under the cursor",
            "update_policy": "100 ms maximum cadence plus key changes",
        },
        "checks": {
            "disabled_policy_inert": disabled_is_inert,
            "enabled_policy_matched_existing_demand": enabled_is_effective,
        },
        "disabled": disabled,
        "enabled": enabled,
        "enabled_minus_disabled": {
            key: _difference(disabled, enabled, key) for key in comparison_keys
        },
        "claim_boundary": (
            "One paired diagnostic run can prove policy activation and expose a "
            "directional result; it cannot establish a stable performance win."
        ),
    }
    output_path = pathlib.Path(args.output).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print(
        "WT_FOREGROUND_PRIORITY_AB_RESULT "
        f"status={output['status']} "
        f"matched={enabled_priority['foreground_priority_matched_keys']} "
        f"changed={enabled_priority['foreground_priority_changed_priorities']} "
        f"visual_delta_ms={output['enabled_minus_disabled']['relocation_to_visual_ready_ms']} "
        f"collision_delta_ms={output['enabled_minus_disabled']['relocation_to_collision_ready_ms']}"
    )
    print(f"WT_FOREGROUND_PRIORITY_AB_OUTPUT {output_path}")
    return 0 if implementation_valid else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
