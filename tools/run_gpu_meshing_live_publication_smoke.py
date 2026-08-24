#!/usr/bin/env python3
"""Run opt-in matched GPU-cell render publication on at most three CPUs."""

from __future__ import annotations

import argparse
import pathlib
import subprocess

import psutil


DEFAULT_GODOT = pathlib.Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine"
    r"\godot.windows.opt.tools.64.exe"
)
MARKER = "GPU_MESHING_LIVE_PUBLICATION_SMOKE_PASS"


def run_with_affinity(command: list[str], cwd: pathlib.Path, timeout: int) -> int:
    launcher = psutil.Process()
    available = launcher.cpu_affinity()
    affinity = available[:3]
    if not affinity:
        raise RuntimeError("no logical CPU is available")
    launcher.cpu_affinity(affinity)
    try:
        return subprocess.run(command, cwd=cwd, timeout=timeout, check=False).returncode
    finally:
        launcher.cpu_affinity(available)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", type=pathlib.Path, default=DEFAULT_GODOT)
    parser.add_argument(
        "--project",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1],
    )
    parser.add_argument("--driver", choices=("vulkan", "d3d12"), default="vulkan")
    args = parser.parse_args()
    project = args.project.resolve()
    log_root = (
        project
        / ".godot"
        / "world_transvoxel_captures"
        / "gpu_meshing_live_publication"
    )
    log_root.mkdir(parents=True, exist_ok=True)
    log_path = log_root / f"{args.driver}.log"
    command = [
        str(args.godot.resolve()),
        "--rendering-driver",
        args.driver,
        "--path",
        str(project),
        "--audio-driver",
        "Dummy",
        "--log-file",
        str(log_path),
        "--script",
        "res://tests/gpu_meshing_live_publication_smoke.gd",
    ]
    exit_code = run_with_affinity(command, project, 120)
    log_text = (
        log_path.read_text(encoding="utf-8", errors="replace")
        if log_path.is_file()
        else ""
    )
    relevant = [
        line
        for line in log_text.splitlines()
        if "GPU_MESHING_LIVE_PUBLICATION" in line or line.startswith("ERROR:")
    ]
    for line in relevant:
        print(line)
    return 0 if exit_code == 0 and any(MARKER in line for line in relevant) else 1


if __name__ == "__main__":
    raise SystemExit(main())
