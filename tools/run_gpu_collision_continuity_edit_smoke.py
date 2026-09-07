#!/usr/bin/env python3
"""Verify that a GPU-candidate density edit never drops nearby support."""

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
PASS_MARKER = "GPU_COLLISION_CONTINUITY_EDIT_SMOKE_PASS"


def main() -> int:
	parser = argparse.ArgumentParser()
	parser.add_argument("--godot", type=pathlib.Path, default=DEFAULT_GODOT)
	parser.add_argument(
		"--project", type=pathlib.Path,
		default=pathlib.Path(__file__).resolve().parents[1],
	)
	parser.add_argument("--driver", choices=("vulkan", "d3d12"), default="vulkan")
	args = parser.parse_args()
	project = args.project.resolve()
	log_path = project / ".godot" / "gpu_collision_continuity_edit_smoke.log"
	command = [
		str(args.godot.resolve()), "--rendering-driver", args.driver,
		"--path", str(project), "--audio-driver", "Dummy",
		"--log-file", str(log_path),
		"--script", "res://tests/gpu_collision_continuity_edit_smoke.gd",
	]
	process = psutil.Process()
	old_affinity = process.cpu_affinity()
	process.cpu_affinity(old_affinity[:3])
	try:
		result = subprocess.run(command, cwd=project, timeout=180, check=False)
	finally:
		process.cpu_affinity(old_affinity)
	output = log_path.read_text(encoding="utf-8", errors="replace")
	for line in output.splitlines():
		if PASS_MARKER in line or "GPU_COLLISION_CONTINUITY_EDIT_SMOKE_FAIL" in line \
				or line.startswith("SCRIPT ERROR:") or line.startswith("ERROR:"):
			print(f"[{args.driver}] {line}")
	return 0 if result.returncode == 0 and PASS_MARKER in output else 1


if __name__ == "__main__":
	raise SystemExit(main())
