#!/usr/bin/env python3
"""Repeat the rendered ground traversal and retain a compact qualification."""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
from typing import Any


def _read_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _mean(summary: dict[str, Any], phase: str, metric: str) -> float | None:
    value = summary.get("phases", {}).get(phase, {}).get(metric, {}).get("mean")
    return float(value) if value is not None else None


def _write_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    project = pathlib.Path(__file__).resolve().parents[1]
    default_root = (
        project / ".godot" / "world_transvoxel_captures" /
        "ground_traversal" / "qualification"
    )
    parser = argparse.ArgumentParser(
        description="Run repeated rendered ground collision traversals."
    )
    parser.add_argument("--repeats", type=int, default=4)
    parser.add_argument("--output-dir", type=pathlib.Path, default=default_root)
    parser.add_argument("--godot")
    args = parser.parse_args(argv)
    if args.repeats < 1 or args.repeats > 20:
        parser.error("--repeats must be in 1..20")

    output_dir = args.output_dir.resolve()
    runs: list[dict[str, Any]] = []
    all_passed = True
    runner = project / "tools" / "run_ground_traversal_probe.py"
    for index in range(1, args.repeats + 1):
        result_path = output_dir / f"run_{index:02d}.json"
        usage_path = output_dir / f"run_{index:02d}_usage.json"
        command = [
            sys.executable,
            str(runner),
            "--project",
            str(project),
            "--output",
            str(result_path),
            "--usage-output",
            str(usage_path),
            "--windowed",
        ]
        if args.godot:
            command.extend(("--godot", args.godot))
        completed = subprocess.run(command, cwd=project, check=False)
        result = _read_json(result_path) if result_path.is_file() else {}
        usage = _read_json(usage_path) if usage_path.is_file() else {}
        passed = completed.returncode == 0 and result.get("status") == "PASS"
        all_passed = all_passed and passed
        runs.append({
            "run": index,
            "passed": passed,
            "exit_code": completed.returncode,
            "reason": result.get("reason", "missing_result"),
            "completed_route_distance": result.get("completed_route_distance"),
            "pretraversal_settle_frames": result.get("pretraversal_settle_frames"),
            "blocked_frames": result.get("blocked_frames"),
            "longest_blocked_run": result.get("longest_blocked_run"),
            "longest_missing_floor_run": result.get("longest_missing_floor_run"),
            "maximum_floor_penetration": result.get("maximum_floor_penetration"),
            "final_collision_resources": result.get("final_runtime", {}).get(
                "collision_resources"
            ),
            "static_cpu_cores_mean": _mean(
                usage, "static", "active_logical_cores"
            ),
            "moving_cpu_cores_mean": _mean(
                usage, "moving", "active_logical_cores"
            ),
            "static_gpu_board_utilization_mean": _mean(
                usage, "static", "gpu_board_global_utilization_percent"
            ),
            "moving_gpu_board_utilization_mean": _mean(
                usage, "moving", "gpu_board_global_utilization_percent"
            ),
            "static_gpu_board_watts_mean": _mean(
                usage, "static", "gpu_board_power_watts"
            ),
            "moving_gpu_board_watts_mean": _mean(
                usage, "moving", "gpu_board_power_watts"
            ),
            "result": str(result_path),
            "usage": str(usage_path),
        })
        if not passed:
            break

    pin = _read_json(project / "WORLD_TRANSVOXEL_RUNTIME_PIN.json")
    qualification = {
        "schema": "world_transvoxel.ground_traversal_qualification.v1",
        "status": "PASS" if all_passed and len(runs) == args.repeats else "FAIL",
        "requested_repeats": args.repeats,
        "completed_repeats": len(runs),
        "authority_commit": pin.get("authority", {}).get("commit"),
        "runtime_artifact_digest": pin.get("runtime_artifact", {}).get(
            "digest_sha256"
        ),
        "logical_cpu_limit": 3,
        "gpu_scope": "board_global_not_process_attributed",
        "acceptance": {
            "full_route_required": True,
            "maximum_blocked_frames": 2,
            "maximum_missing_floor_run": 2,
            "maximum_floor_penetration": 0.20,
        },
        "runs": runs,
    }
    qualification_path = output_dir / "qualification.json"
    _write_json(qualification_path, qualification)
    print(
        "WT_GROUND_TRAVERSAL_QUALIFICATION "
        f"status={qualification['status']} runs={len(runs)}/{args.repeats} "
        f"output={qualification_path}",
        flush=True,
    )
    return 0 if qualification["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
