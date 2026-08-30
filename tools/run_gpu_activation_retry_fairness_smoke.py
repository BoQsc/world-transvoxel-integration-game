#!/usr/bin/env python3
"""Run the isolated GPU publication ordering regression on at most three CPUs."""

from __future__ import annotations

import argparse
import pathlib
import subprocess

import psutil


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--godot", type=pathlib.Path,
        default=pathlib.Path(
            r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine"
            r"\godot.windows.opt.tools.64.exe"
        ),
    )
    args = parser.parse_args()
    project = pathlib.Path(__file__).resolve().parents[1]
    log = project / ".godot" / "gpu_activation_ordering_smoke.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    process = psutil.Process()
    affinity = process.cpu_affinity()
    process.cpu_affinity(affinity[:3])
    try:
        result = subprocess.run(
            [str(args.godot), "--headless", "--path", str(project),
             "--log-file", str(log), "--script",
             "res://tests/gpu_activation_retry_fairness_smoke.gd"],
            cwd=project, timeout=30, check=False,
        )
    finally:
        process.cpu_affinity(affinity)
    output = log.read_text(encoding="utf-8", errors="replace")
    print(output, end="")
    failed = any(line.startswith(("ERROR:", "SCRIPT ERROR:", "WARNING:"))
                 for line in output.splitlines())
    passed = "GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_PASS" in output
    return 0 if result.returncode == 0 and passed and not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
