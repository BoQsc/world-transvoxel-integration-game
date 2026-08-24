#!/usr/bin/env python3
"""Run the bounded TQP-64 GPU meshing integration smoke on at most three CPUs."""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

import psutil


DEFAULT_GODOT = pathlib.Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine"
    r"\godot.windows.opt.tools.64.exe"
)


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


def import_project(godot: pathlib.Path, project: pathlib.Path) -> int:
    return run_with_affinity(
        [str(godot), "--headless", "--path", str(project), "--import"],
        project,
        120,
    )


def run_profile(godot: pathlib.Path, project: pathlib.Path, driver: str) -> int:
    log_root = project / ".godot" / "world_transvoxel_captures" / "gpu_meshing_service"
    log_root.mkdir(parents=True, exist_ok=True)
    log_path = log_root / f"{driver}.log"
    command = [
        str(godot),
        "--rendering-driver",
        driver,
        "--path",
        str(project),
        "--audio-driver",
        "Dummy",
        "--log-file",
        str(log_path),
        "--script",
        "res://tests/gpu_meshing_service_smoke.gd",
    ]
    exit_code = run_with_affinity(command, project, 90)
    log_text = log_path.read_text(encoding="utf-8", errors="replace") \
        if log_path.is_file() else ""
    relevant = [
        line for line in log_text.splitlines()
        if "GPU_MESHING_SERVICE" in line or line.startswith("ERROR:")
    ]
    for line in relevant:
        print(f"[{driver}] {line}")
    if exit_code == 0 and any("GPU_MESHING_SERVICE_SMOKE_PASS" in line for line in relevant):
        return 0
    if not relevant:
        print(f"[{driver}] no retained test result; inspect {log_path}", file=sys.stderr)
    return exit_code if exit_code != 0 else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", type=pathlib.Path, default=DEFAULT_GODOT)
    parser.add_argument(
        "--project",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1],
    )
    parser.add_argument("--driver", choices=("vulkan", "d3d12", "both"), default="both")
    parser.add_argument("--skip-import", action="store_true")
    args = parser.parse_args()
    godot = args.godot.resolve()
    project = args.project.resolve()
    if not godot.is_file():
        raise FileNotFoundError(f"Godot executable does not exist: {godot}")
    if not (project / "project.godot").is_file():
        raise FileNotFoundError(f"Godot project does not exist: {project}")
    if not args.skip_import and import_project(godot, project) != 0:
        return 1
    drivers = ("vulkan", "d3d12") if args.driver == "both" else (args.driver,)
    for driver in drivers:
        if run_profile(godot, project, driver) != 0:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
