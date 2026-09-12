#!/usr/bin/env python3
"""Exercise a newer request racing an already committed GPU activation."""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys


DEFAULT_GODOT = pathlib.Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine"
    r"\godot.windows.opt.tools.64.exe"
)
PASS_MARKER = "GPU_COMMITTED_ACTIVATION_SUPERSESSION_SMOKE_PASS"


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
    log_path = project / ".godot" / "gpu_committed_activation_supersession.log"
    command = [
        str(args.godot.resolve()),
        "--rendering-driver", args.driver,
        "--path", str(project),
        "--audio-driver", "Dummy",
        "--log-file", str(log_path),
        "--script", "res://tests/gpu_committed_activation_supersession_smoke.gd",
    ]
    result = subprocess.run(command, cwd=project, timeout=120, check=False)
    output = log_path.read_text(encoding="utf-8", errors="replace")
    relevant = [
        line for line in output.splitlines()
        if PASS_MARKER in line or line.startswith(("ERROR:", "SCRIPT ERROR:", "WARNING:"))
    ]
    for line in relevant:
        print(f"[{args.driver}] {line}")
    diagnostics = [line for line in relevant if line.startswith(("ERROR:", "SCRIPT ERROR:", "WARNING:"))]
    if result.returncode == 0 and not diagnostics and any(PASS_MARKER in line for line in relevant):
        return 0
    return result.returncode or 1


if __name__ == "__main__":
    sys.exit(main())
