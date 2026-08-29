#!/usr/bin/env python3
"""Compare bounded CPU and resident-GPU static-water presentation on three CPUs."""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

import psutil
from PIL import Image


DEFAULT_GODOT = pathlib.Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine"
    r"\godot.windows.opt.tools.64.exe"
)
TEST_SCRIPT = "res://tests/gpu_resident_production_lifecycle_smoke.gd"
GPU_MARKER = "GPU_RESIDENT_PRODUCTION_LIFECYCLE_SMOKE_PASS"
CPU_MARKER = "GPU_RESIDENT_PRODUCTION_LIFECYCLE_CPU_REFERENCE_PASS"
PASS_MARKER = "GPU_RESIDENT_WATER_VISUAL_PARITY_SMOKE_PASS"


def run_with_affinity(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
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
            timeout=120,
            check=False,
        )
    finally:
        launcher.cpu_affinity(available)


def run_fixture(
    godot: pathlib.Path, project: pathlib.Path, driver: str, cpu_reference: bool
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
    marker = GPU_MARKER
    if cpu_reference:
        command.extend(["--", "--cpu-reference"])
        marker = CPU_MARKER
    completed = run_with_affinity(command, project)
    output = completed.stdout + completed.stderr
    if completed.returncode != 0 or marker not in output:
        print(output, file=sys.stderr)
        raise RuntimeError(
            f"{driver} {'CPU' if cpu_reference else 'GPU'} water fixture failed"
        )


def compare_images(project: pathlib.Path, driver: str) -> dict[str, float | int]:
    root = (
        project
        / ".godot"
        / "world_transvoxel_captures"
        / "gpu_resident_production_lifecycle"
    )
    paths = {
        "cpu_before": root / f"{driver}_cpu_terrain_only.png",
        "cpu_after": root / f"{driver}_cpu_static_water.png",
        "gpu_before": root / f"{driver}_terrain_only.png",
        "gpu_after": root / f"{driver}_static_water.png",
    }
    for path in paths.values():
        if not path.is_file():
            raise RuntimeError(f"water visual fixture did not write {path}")
    images = {name: Image.open(path).convert("RGB") for name, path in paths.items()}
    sizes = {image.size for image in images.values()}
    if len(sizes) != 1:
        raise RuntimeError(f"water visual fixture sizes differ: {sizes}")

    cpu_before = list(images["cpu_before"].getdata())
    cpu_after = list(images["cpu_after"].getdata())
    gpu_before = list(images["gpu_before"].getdata())
    gpu_after = list(images["gpu_after"].getdata())
    changed_pixels = 0
    mask_mismatches = 0
    exact_pixels = 0
    maximum_channel_errors: list[int] = []
    for cpu_before_pixel, cpu_after_pixel, gpu_before_pixel, gpu_after_pixel in zip(
        cpu_before, cpu_after, gpu_before, gpu_after, strict=True
    ):
        cpu_changed = cpu_before_pixel != cpu_after_pixel
        gpu_changed = gpu_before_pixel != gpu_after_pixel
        if cpu_changed != gpu_changed:
            mask_mismatches += 1
        if not cpu_changed:
            continue
        changed_pixels += 1
        channel_error = max(
            abs(cpu_after_pixel[channel] - gpu_after_pixel[channel])
            for channel in range(3)
        )
        maximum_channel_errors.append(channel_error)
        if channel_error == 0:
            exact_pixels += 1
    if changed_pixels == 0:
        raise RuntimeError("water fixture did not change any CPU reference pixels")
    maximum_channel_errors.sort()
    p95_index = min(
        len(maximum_channel_errors) - 1,
        int(0.95 * len(maximum_channel_errors)),
    )
    result: dict[str, float | int] = {
        "changed_pixels": changed_pixels,
        "mask_mismatches": mask_mismatches,
        "exact_ratio": exact_pixels / changed_pixels,
        "p95_channel_error": maximum_channel_errors[p95_index],
        "maximum_channel_error": maximum_channel_errors[-1],
    }
    if (
        changed_pixels < 1000
        or mask_mismatches != 0
        or float(result["exact_ratio"]) < 0.90
        or int(result["p95_channel_error"]) > 20
    ):
        raise RuntimeError(f"{driver} CPU/GPU water presentation differs: {result}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", type=pathlib.Path, default=DEFAULT_GODOT)
    parser.add_argument(
        "--project",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1],
    )
    parser.add_argument("--driver", choices=("vulkan", "d3d12", "both"), default="both")
    args = parser.parse_args()
    project = args.project.resolve()
    drivers = ("vulkan", "d3d12") if args.driver == "both" else (args.driver,)
    for driver in drivers:
        run_fixture(args.godot.resolve(), project, driver, True)
        run_fixture(args.godot.resolve(), project, driver, False)
        result = compare_images(project, driver)
        print(
            f"[{driver}] {PASS_MARKER} changed={result['changed_pixels']} "
            f"mask_mismatches={result['mask_mismatches']} "
            f"exact_ratio={result['exact_ratio']:.4f} "
            f"p95_error={result['p95_channel_error']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
