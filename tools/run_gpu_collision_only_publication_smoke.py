#!/usr/bin/env python3
"""Exercise GPU visual relocation while retaining explicitly requested local collision."""

from __future__ import annotations

import argparse
import pathlib
import subprocess

from run_gpu_resident_production_lifecycle_smoke import DEFAULT_GODOT, run_with_affinity


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=pathlib.Path, default=DEFAULT_GODOT)
    parser.add_argument("--driver", choices=("vulkan", "d3d12", "both"), default="both")
    parser.add_argument("--repeats", type=int, choices=range(1, 11), default=3)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    project = pathlib.Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    if output.exists():
        parser.error("choose a new output directory to retain previous evidence")
    version = subprocess.check_output(
        [str(args.godot), "--headless", "--version"], text=True, timeout=15,
    ).strip()
    if tuple(int(value) for value in version.split(".")[:2]) < (4, 7):
        parser.error("Godot 4.7 or newer is required")
    output.mkdir(parents=True)
    drivers = ("vulkan", "d3d12") if args.driver == "both" else (args.driver,)
    for driver in drivers:
        for iteration in range(1, args.repeats + 1):
            log = output / f"{driver}_{iteration}.log"
            code = run_with_affinity([
                str(args.godot), "--rendering-driver", driver, "--path", str(project),
                "--audio-driver", "Dummy", "--log-file", str(log),
                "--script", "res://tests/gpu_collision_only_publication_smoke.gd",
            ], project, 60)
            content = log.read_text(encoding="utf-8", errors="replace") if log.is_file() else ""
            passed = "GPU_COLLISION_ONLY_PUBLICATION_PASS" in content
            diagnostics = any(line.startswith(("ERROR:", "SCRIPT ERROR:", "WARNING:"))
                              for line in content.splitlines())
            print(f"{driver} iteration={iteration} exit={code} pass={passed} diagnostics={diagnostics}", flush=True)
            if code != 0 or not passed or diagnostics:
                return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
