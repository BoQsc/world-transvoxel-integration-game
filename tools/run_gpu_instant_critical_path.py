#!/usr/bin/env python3
"""Run the deterministic GPU hot-edit and cold-approach trace."""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys

import psutil


DEFAULT_GODOT = pathlib.Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine"
    r"\godot.windows.opt.tools.64.exe"
)
PASS_MARKER = "GPU_INSTANT_CRITICAL_PATH_SMOKE_PASS"


def run_profile(
    godot: pathlib.Path,
    project: pathlib.Path,
    driver: str,
    trace: bool,
    layout: str,
) -> int:
    capture = project / ".godot" / "world_transvoxel_captures" / "gpu_instant_critical_path"
    result = capture / "result.json"
    label = "trace_on" if trace else "trace_off"
    retained = capture / f"{driver}_{layout}_{label}.json"
    log = capture / f"{driver}_{layout}_{label}.log"
    capture.mkdir(parents=True, exist_ok=True)
    result.unlink(missing_ok=True)
    process = psutil.Process()
    available = process.cpu_affinity()
    process.cpu_affinity(available[:3])
    command = [
        str(godot), "--rendering-driver", driver, "--path", str(project),
        "--audio-driver", "Dummy", "--log-file", str(log),
        "--script", "res://tests/gpu_instant_critical_path_smoke.gd",
    ]
    if not trace:
        command.extend(["--", "--gpu-critical-path-trace-off"])
    if layout == "single_brick":
        if "--" not in command:
            command.append("--")
        command.append("--gpu-critical-path-single-brick")
    try:
        code = subprocess.run(command, cwd=project, timeout=300, check=False).returncode
    finally:
        process.cpu_affinity(available)
    output = log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""
    relevant = [line for line in output.splitlines() if "GPU_INSTANT_CRITICAL_PATH" in line or line.startswith(("ERROR:", "SCRIPT ERROR:"))]
    for line in relevant:
        print(f"[{driver}/{layout}/{label}] {line}")
    if code != 0 or not result.exists() or not any(PASS_MARKER in line for line in relevant):
        return code or 1
    shutil.copy2(result, retained)
    payload = json.loads(retained.read_text(encoding="utf-8"))
    submissions = sorted(int(edit["submission_us"]) for edit in payload["hot_edits"])
    ready = sorted(int(edit["ready_us"]) for edit in payload["hot_edits"])
    first_draw = sorted(
        int(edit["visual_first_draw_us"])
        for edit in payload["hot_edits"]
        if int(edit["visual_first_draw_us"]) >= 0
    )
    first_draw_summary = str(max(first_draw)) if first_draw else "n/a"
    print(
        f"[{driver}/{layout}/{label}] GPU_INSTANT_CRITICAL_PATH_RESULT "
        f"submit_max_us={max(submissions)} hot_first_draw_max_us={first_draw_summary} "
        f"hot_observed_ready_max_us={max(ready)} "
        f"warm_settle_us={payload['cold_warm_settle_us']} "
        f"cold_ready_us={payload['cold_approach_ready_us']} "
        f"queues={payload['maximum_queues']} "
        f"evidence={retained}"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", type=pathlib.Path, default=DEFAULT_GODOT)
    parser.add_argument("--project", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument("--driver", choices=("vulkan", "d3d12", "both"), default="both")
    parser.add_argument("--trace", choices=("on", "off", "both"), default="both")
    parser.add_argument(
        "--layout", choices=("cross_brick", "single_brick", "both"),
        default="cross_brick",
    )
    args = parser.parse_args()
    drivers = ("vulkan", "d3d12") if args.driver == "both" else (args.driver,)
    traces = (True, False) if args.trace == "both" else (args.trace == "on",)
    layouts = ("cross_brick", "single_brick") if args.layout == "both" else (args.layout,)
    for driver in drivers:
        for layout in layouts:
            for trace in traces:
                if run_profile(
                    args.godot.resolve(), args.project.resolve(), driver, trace, layout
                ) != 0:
                    return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
