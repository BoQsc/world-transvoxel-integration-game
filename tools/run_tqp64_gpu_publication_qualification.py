#!/usr/bin/env python3
"""Qualify matched GPU-cell visual publication on the retained large world."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Any

import run_tqp64_gpu_shadow_qualification as qualification


SCHEMA = "world_transvoxel.tqp64_gpu_publication_qualification.v1"


def parse_args(argv: list[str]) -> argparse.Namespace:
    default_project = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", default=str(default_project))
    parser.add_argument("--godot")
    parser.add_argument(
        "--drivers",
        nargs="+",
        choices=("vulkan", "d3d12"),
        default=("vulkan", "d3d12"),
    )
    parser.add_argument("--timeout-seconds", type=float, default=300.0)
    parser.add_argument("--output")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    project = pathlib.Path(args.project).resolve()
    raw_root = (
        project
        / ".godot"
        / "world_transvoxel_captures"
        / "tqp64_gpu_publication_qualification"
    )
    output = (
        pathlib.Path(args.output).resolve()
        if args.output
        else project
        / "docs"
        / "evidence"
        / "tqp64_large_world_gpu_publication_20260824"
        / "qualification.json"
    )
    runs: dict[str, Any] = {}
    passed = True
    for driver in dict.fromkeys(args.drivers):
        print(f"TQP64_PUBLICATION_START driver={driver}", flush=True)
        run = qualification.run_mode(
            project,
            raw_root,
            driver,
            "gpu_publication",
            args.godot,
            args.timeout_seconds,
        )
        runs[driver] = run
        passed = passed and run["passed"]
        print(
            f"TQP64_PUBLICATION_RESULT driver={driver} "
            f"passed={run['passed']} failures={run['failures']}",
            flush=True,
        )
    payload = {
        "schema": SCHEMA,
        "classification": (
            "PASS_BOUNDED_MATCHED_GPU_CELL_PUBLICATION"
            if passed
            else "FAIL_BOUNDED_MATCHED_GPU_CELL_PUBLICATION"
        ),
        "passed": passed,
        "profile": qualification.PROFILE,
        "material": qualification.MATERIAL,
        "logical_cpu_limit": 3,
        "drivers": list(runs),
        "runs": runs,
        "claim_boundary": {
            "default_enabled": False,
            "matched_gpu_cell_visual_replacement": True,
            "exact_cpu_authority_match_required": True,
            "cpu_world_authority": True,
            "cpu_collision_authority": True,
            "gpu_resident_render_publication": False,
            "cpu_array_mesh_upload_required": True,
            "performance_promotion": False,
            "production_backend_release": False,
        },
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(
        f"TQP64_PUBLICATION_QUALIFICATION classification={payload['classification']} "
        f"output={output}",
        flush=True,
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
