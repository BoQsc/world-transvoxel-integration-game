#!/usr/bin/env python3
"""Run and retain the deterministic moving-road GPU terrain stress trace."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import time

import psutil


DEFAULT_GODOT = pathlib.Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine"
    r"\godot.windows.opt.tools.64.exe"
)
MARKER = "GPU_MOVING_ROAD_STRESS_COMPLETE"


def run(
    driver: str,
    godot: pathlib.Path,
    project: pathlib.Path,
    trace: bool,
    editing: bool,
    cpu_count: int,
    stage_timing: bool,
) -> int:
    capture = project / ".godot" / "world_transvoxel_captures" / "gpu_moving_road_stress"
    capture.mkdir(parents=True, exist_ok=True)
    result_path = capture / "result.json"
    suffix = ("_trace" if trace else "") + ("_no_edits" if not editing else "")
    if cpu_count > 0:
        suffix += f"_{cpu_count}cpu"
    if stage_timing:
        suffix += "_stage_timing"
    retained_path = capture / f"{driver}{suffix}.json"
    usage_path = capture / f"{driver}{suffix}_usage.json"
    log_path = capture / f"{driver}{suffix}.log"
    result_path.unlink(missing_ok=True)
    command = [
        str(godot), "--rendering-driver", driver, "--path", str(project),
        "--audio-driver", "Dummy", "--log-file", str(log_path),
        "--script", "res://tests/gpu_moving_road_stress.gd",
    ]
    host = psutil.Process()
    affinity = host.cpu_affinity()
    if cpu_count > 0:
        host.cpu_affinity(affinity[: min(cpu_count, len(affinity))])
    started = time.monotonic()
    samples: list[dict[str, float | int]] = []
    try:
        environment = os.environ.copy()
        environment["WT_GPU_MOVING_ROAD_TRACE"] = "1" if trace else "0"
        environment["WT_GPU_MOVING_ROAD_EDITING"] = "1" if editing else "0"
        environment["WT_GPU_MOVING_ROAD_STAGE_TIMING"] = "1" if stage_timing else "0"
        environment["WT_GPU_MOVING_ROAD_LIFECYCLE_HISTORY"] = "1" if trace else "0"
        child = subprocess.Popen(command, cwd=project, env=environment)
        process = psutil.Process(child.pid)
        process.cpu_percent(None)
        while child.poll() is None:
            if time.monotonic() - started > 300:
                child.kill()
                child.wait()
                raise TimeoutError(f"{driver} moving-road stress exceeded 300 seconds")
            try:
                memory = process.memory_info()
                samples.append({
                    "elapsed_seconds": time.monotonic() - started,
                    "rss_bytes": memory.rss,
                    "cpu_percent": process.cpu_percent(None),
                })
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
            time.sleep(0.05)
        code = child.returncode
    finally:
        host.cpu_affinity(affinity)
    output = log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""
    for line in output.splitlines():
        if (
            MARKER in line
            or "GPU_MOVING_ROAD_STRESS_FAIL" in line
            or "GPU_MOVING_ROAD_VIEWER_REJECTION_METRICS" in line
            or line.startswith(("ERROR:", "SCRIPT ERROR:"))
        ):
            print(f"[{driver}] {line}")
    usage = {
        "schema": "world_transvoxel.gpu_moving_road_usage.v1",
        "driver": driver,
        "causal_trace_enabled": trace,
        "editing_enabled": editing,
        "cpu_count_limit": cpu_count,
        "stage_timing_enabled": stage_timing,
        "wall_seconds": time.monotonic() - started,
        "rss_bytes_maximum": max((int(x["rss_bytes"]) for x in samples), default=0),
        "cpu_percent_maximum": max((float(x["cpu_percent"]) for x in samples), default=0.0),
        "samples": samples,
    }
    usage_path.write_text(json.dumps(usage, indent=2) + "\n", encoding="utf-8")
    if code != 0 or MARKER not in output or not result_path.exists():
        return code or 1
    shutil.copy2(result_path, retained_path)
    result = json.loads(retained_path.read_text(encoding="utf-8"))
    frames = result["frames"]
    seamless = result["seamlessness"]
    editing = result["editing"]
    print(
        f"[{driver}] GPU_MOVING_ROAD_RESULT "
        f"frame_p95_us={frames['p95_us']} frame_p99_us={frames['p99_us']} "
        f"coverage_gaps={seamless['visual_coverage_gap_frames']} "
        f"collision_pending={seamless['collision_pending_frames']} "
        f"edits={editing['commits']}/{editing['attempts']} "
        f"runtime_rejections={editing['runtime_rejections']} "
        f"rss_max={usage['rss_bytes_maximum']} evidence={retained_path}"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", type=pathlib.Path, default=DEFAULT_GODOT)
    parser.add_argument("--project", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument("--driver", choices=("vulkan", "d3d12", "both"), default="both")
    parser.add_argument("--trace", action="store_true", help="capture the high-overhead native causal trace")
    parser.add_argument("--no-edits", action="store_true", help="isolate streaming and LOD activation")
    parser.add_argument(
        "--cpu-count", type=int, default=0,
        help="Explicitly constrain the run to this many logical CPUs; zero uses all available CPUs.",
    )
    parser.add_argument(
        "--stage-timing", action="store_true",
        help="Enable high-overhead per-stage GPU diagnostics.",
    )
    args = parser.parse_args()
    drivers = ("vulkan", "d3d12") if args.driver == "both" else (args.driver,)
    for driver in drivers:
        if run(
            driver, args.godot.resolve(), args.project.resolve(), args.trace,
            not args.no_edits, args.cpu_count, args.stage_timing,
        ) != 0:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
