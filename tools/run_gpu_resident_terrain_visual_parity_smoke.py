#!/usr/bin/env python3
"""Compare bounded CPU and GPU-resident production terrain pixels."""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

import numpy as np
from PIL import Image
import psutil


DEFAULT_GODOT = pathlib.Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine"
    r"\godot.windows.opt.tools.64.exe"
)
TEST_SCRIPT = "res://tests/gpu_resident_production_lifecycle_smoke.gd"
CPU_MARKER = "GPU_RESIDENT_PRODUCTION_LIFECYCLE_CPU_REFERENCE_PASS"
GPU_MARKER = "GPU_RESIDENT_PRODUCTION_LIFECYCLE_SMOKE_PASS"


def run_with_affinity(
    command: list[str], cwd: pathlib.Path
) -> subprocess.CompletedProcess[str]:
    launcher = psutil.Process()
    available = launcher.cpu_affinity()
    affinity = available[:3]
    if not affinity:
        raise RuntimeError("no logical CPU is available")
    launcher.cpu_affinity(affinity)
    try:
        return subprocess.run(
            command,
            cwd=cwd,
            text=True,
            capture_output=True,
            timeout=180,
            check=False,
        )
    finally:
        launcher.cpu_affinity(available)


def run_fixture(
    godot: pathlib.Path,
    project: pathlib.Path,
    driver: str,
    cpu_reference: bool,
) -> None:
    command = [
        str(godot),
        "--rendering-driver",
        driver,
        "--path",
        str(project),
        "--audio-driver",
        "Dummy",
        "--script",
        TEST_SCRIPT,
    ]
    if cpu_reference:
        command.extend(["--", "--cpu-reference"])
    completed = run_with_affinity(command, project)
    marker = CPU_MARKER if cpu_reference else GPU_MARKER
    output = completed.stdout + "\n" + completed.stderr
    if completed.returncode != 0 or marker not in output:
        print(output, file=sys.stderr)
        raise RuntimeError(
            f"{driver} {'CPU' if cpu_reference else 'GPU'} fixture failed"
        )


def compare_terrain(project: pathlib.Path, driver: str) -> dict[str, float | int]:
    root = (
        project
        / ".godot"
        / "world_transvoxel_captures"
        / "gpu_resident_production_lifecycle"
    )
    cpu_path = root / f"{driver}_cpu_terrain_only.png"
    gpu_path = root / f"{driver}_terrain_only.png"
    cpu = np.asarray(Image.open(cpu_path).convert("RGB"), dtype=np.int16)
    gpu = np.asarray(Image.open(gpu_path).convert("RGB"), dtype=np.int16)
    if cpu.shape != gpu.shape:
        raise RuntimeError(f"terrain capture shape mismatch: {cpu.shape} != {gpu.shape}")
    error = np.abs(cpu - gpu)
    exact_ratio = float(np.all(error == 0, axis=2).mean())
    p99_error = float(np.percentile(error, 99))
    maximum_error = int(error.max())
    changed_pixels = int(np.any(error != 0, axis=2).sum())
    if exact_ratio < 0.99 or p99_error > 1.0 or maximum_error > 2:
        raise RuntimeError(
            "terrain visual parity failed: "
            f"exact_ratio={exact_ratio:.6f} p99_error={p99_error:g} "
            f"max_error={maximum_error} changed_pixels={changed_pixels}"
        )
    return {
        "exact_ratio": exact_ratio,
        "p99_error": p99_error,
        "maximum_error": maximum_error,
        "changed_pixels": changed_pixels,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", type=pathlib.Path, default=DEFAULT_GODOT)
    parser.add_argument(
        "--project",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1],
    )
    parser.add_argument(
        "--driver", choices=("vulkan", "d3d12", "both"), default="both"
    )
    args = parser.parse_args()
    godot = args.godot.resolve()
    project = args.project.resolve()
    drivers = ("vulkan", "d3d12") if args.driver == "both" else (args.driver,)
    for driver in drivers:
        run_fixture(godot, project, driver, True)
        run_fixture(godot, project, driver, False)
        metrics = compare_terrain(project, driver)
        print(
            f"[{driver}] GPU_RESIDENT_TERRAIN_VISUAL_PARITY_SMOKE_PASS "
            f"exact_ratio={metrics['exact_ratio']:.6f} "
            f"p99_error={metrics['p99_error']:g} "
            f"max_error={metrics['maximum_error']} "
            f"changed_pixels={metrics['changed_pixels']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
