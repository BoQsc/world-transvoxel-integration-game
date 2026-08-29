#!/usr/bin/env python3
"""Run a bounded production startup probe on at most three CPUs."""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys
import time

import psutil


DEFAULT_GODOT = pathlib.Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine"
    r"\godot.windows.opt.tools.64.exe"
)
DEFAULT_PROFILE = "g23_four_biomes_lakes_mountains_roads_2k_256_on_demand"


def terminate_tree(process: subprocess.Popen[bytes]) -> None:
    try:
        root = psutil.Process(process.pid)
    except psutil.NoSuchProcess:
        return
    children = root.children(recursive=True)
    for child in reversed(children):
        try:
            child.terminate()
        except psutil.NoSuchProcess:
            pass
    try:
        root.terminate()
    except psutil.NoSuchProcess:
        pass
    _, alive = psutil.wait_procs(children + [root], timeout=10.0)
    for remaining in alive:
        try:
            remaining.kill()
        except psutil.NoSuchProcess:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", type=pathlib.Path, default=DEFAULT_GODOT)
    parser.add_argument(
        "--project",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1],
    )
    parser.add_argument("--profile", default=DEFAULT_PROFILE)
    parser.add_argument("--driver", choices=("vulkan", "d3d12"), default="vulkan")
    parser.add_argument(
        "--mode",
        choices=("cpu", "gpu_resident"),
        default="gpu_resident",
    )
    parser.add_argument("--timeout-seconds", type=float, default=80.0)
    args = parser.parse_args()

    project = args.project.resolve()
    godot = args.godot.resolve()
    capture_root = project / ".godot" / "world_transvoxel_captures"
    capture_root.mkdir(parents=True, exist_ok=True)
    log_path = project / ".godot" / f"{args.mode}_startup_probe.log"
    trace_path = capture_root / f"{args.mode}_startup_probe.json"
    command = [
        str(godot),
        "--rendering-driver",
        args.driver,
        "--path",
        str(project),
        "--log-file",
        str(log_path),
        "--",
        "--p2-profile",
        args.profile,
        "--human-material-mode",
        "production_texture_array",
        "--human-windowed",
        "--procedural-generation-workers",
        "2",
        "--terrain-waterfall",
        "--terrain-waterfall-output",
        str(trace_path),
        "--terrain-waterfall-smoke",
    ]
    if args.mode == "gpu_resident":
        command.append("--gpu-resident-render-candidate")
    launcher = psutil.Process()
    original_affinity = launcher.cpu_affinity()
    launcher.cpu_affinity(original_affinity[:3])
    peak_rss_bytes = 0
    peak_private_bytes = 0
    try:
        process = subprocess.Popen(command, cwd=project)
        print(
            f"PRODUCTION_STARTUP_PROBE_PID {process.pid} mode={args.mode}",
            flush=True,
        )
        deadline = time.monotonic() + args.timeout_seconds
        while process.poll() is None and time.monotonic() < deadline:
            try:
                root = psutil.Process(process.pid)
                processes = [root, *root.children(recursive=True)]
                rss_bytes = 0
                private_bytes = 0
                for sampled in processes:
                    try:
                        memory = sampled.memory_full_info()
                    except (psutil.AccessDenied, psutil.NoSuchProcess):
                        continue
                    rss_bytes += memory.rss
                    private_bytes += getattr(memory, "private", 0)
                peak_rss_bytes = max(peak_rss_bytes, rss_bytes)
                peak_private_bytes = max(peak_private_bytes, private_bytes)
            except psutil.NoSuchProcess:
                pass
            time.sleep(0.1)
        if process.poll() is None:
            terminate_tree(process)
            exit_code = 124
        else:
            exit_code = process.returncode
    finally:
        launcher.cpu_affinity(original_affinity)
    print(
        "PRODUCTION_STARTUP_PROBE_EXIT "
        f"{exit_code} mode={args.mode} "
        f"peak_rss_bytes={peak_rss_bytes} "
        f"peak_private_bytes={peak_private_bytes} log={log_path}",
        flush=True,
    )
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
