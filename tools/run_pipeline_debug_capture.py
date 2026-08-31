#!/usr/bin/env python3
"""Capture optional live collision/LOD/GPU views from one real G23 world."""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import time

import psutil
from PIL import Image, ImageStat


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--godot", type=pathlib.Path, default=pathlib.Path(
        r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
    ))
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        parser.error("output already exists; select a new directory")
    project = pathlib.Path(__file__).resolve().parents[1]
    command = [str(args.godot), "--path", str(project), "--rendering-driver", "vulkan",
        "--audio-driver", "Dummy", "--log-file", str(output / "visual.log"), "--",
        "--p2-profile", "g23_four_biomes_lakes_mountains_roads_2k_256_on_demand",
        "--human-visual-capture", str(output / "visual.png"),
        "--human-visual-capture-mode", "pipeline_debug",
        "--human-visual-capture-wait-frames", "180",
        "--human-material-mode", "production_texture_array", "--gpu-resident-render-candidate",
        "--procedural-generation-workers", "2", "--meshing-workers", "0"]
    output.mkdir(parents=True)
    process = psutil.Process()
    previous = process.cpu_affinity()
    affinity = previous[:3]
    process.cpu_affinity(affinity)
    started = time.monotonic()
    try:
        with (output / "stdout.log").open("w") as stdout, (output / "stderr.log").open("w") as stderr:
            result = subprocess.run(command, cwd=project, stdout=stdout, stderr=stderr, timeout=200)
    finally:
        process.cpu_affinity(previous)
    log = (output / "visual.log").read_text(encoding="utf-8", errors="replace")
    marker = "WT_PIPELINE_DEBUG_CAPTURE "
    records = [json.loads(line.split(marker, 1)[1]) for line in log.splitlines() if marker in line]
    errors = [line for line in log.splitlines() if line.startswith(("ERROR:", "SCRIPT ERROR:", "WARNING:"))]
    captures = []
    for mode in ("collision", "lod", "pipeline", "menu", "off"):
        path = output / f"debug_{mode}.png"
        if not path.exists():
            continue
        with Image.open(path) as image:
            captures.append({"mode": mode, "size": list(image.size),
                "nonblank": max(ImageStat.Stat(image.convert("RGB")).stddev) > 10})
    ok = result.returncode == 0 and not errors and bool(records) and records[-1].get("ok") \
        and len(captures) == 5 and all(item["nonblank"] for item in captures)
    report = {"ok": bool(ok), "diagnostic_only_not_performance_baseline": True,
        "command": command, "affinity": affinity, "returncode": result.returncode,
        "wall_seconds": time.monotonic() - started, "captures": captures, "errors": errors}
    (output / "command.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
