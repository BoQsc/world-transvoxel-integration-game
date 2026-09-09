#!/usr/bin/env python3
"""Exercise a real player mining beside its support on the production GPU path."""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

from run_human_playtest import find_godot, LATEST_HUMAN_MATERIAL, LATEST_HUMAN_PROFILE


MARKER = "GPU_STANDING_MINE_REGRESSION_PASS"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot")
    parser.add_argument("--project", default=str(pathlib.Path(__file__).resolve().parents[1]))
    parser.add_argument("--driver", choices=("vulkan", "d3d12", "both"), default="both")
    args = parser.parse_args()
    project = pathlib.Path(args.project).resolve()
    drivers = ("vulkan", "d3d12") if args.driver == "both" else (args.driver,)
    for driver in drivers:
        command = [
            str(find_godot(args.godot)), "--rendering-driver", driver,
            "--path", str(project), "--", "--p2-profile", LATEST_HUMAN_PROFILE,
            "--human-material-mode", LATEST_HUMAN_MATERIAL, "--human-windowed",
            "--gpu-resident-render-candidate", "--gpu-standing-mine-regression",
        ]
        result = subprocess.run(
            command, cwd=project, text=True, capture_output=True, timeout=180
        )
        output = result.stdout + result.stderr
        lines = [line for line in output.splitlines() if MARKER in line or "GPU_STANDING_MINE_REGRESSION_FAIL" in line]
        for line in lines:
            print(f"[{driver}] {line}")
        if result.returncode != 0 or not any(MARKER in line for line in lines):
            if not lines:
                print(output[-8000:], file=sys.stderr)
            return result.returncode or 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
