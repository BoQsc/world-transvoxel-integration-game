#!/usr/bin/env python3
"""Capture the unchanged G23 movement/edit gate with optional readiness evidence."""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess

import psutil

import p0_runtime_baseline as baseline
import world_transvoxel_runtime_artifact as runtime_artifact


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=("cpu", "gpu"), default="gpu")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--native-trace", action="store_true")
    parser.add_argument("--no-probe", action="store_true")
    parser.add_argument("--publication-probe", action="store_true")
    parser.add_argument(
        "--godot", type=pathlib.Path,
        default=pathlib.Path(
            r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine"
            r"\godot.windows.opt.tools.64.exe"
        ),
    )
    args = parser.parse_args()
    if args.publication_probe and (args.no_probe or args.backend != "gpu"):
        parser.error("publication inspection requires GPU with the readiness probe")
    project = pathlib.Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    if output.exists():
        parser.error("output already exists; choose a new evidence file")
    process = psutil.Process()
    previous_affinity = process.cpu_affinity()
    affinity = previous_affinity[:3]
    process.cpu_affinity(affinity)
    try:
        version = subprocess.check_output(
            [str(args.godot), "--headless", "--version"], text=True, timeout=15,
        ).strip()
        numbers = version.split(".")
        if tuple(int(value) for value in numbers[:2]) < (4, 7):
            parser.error("Godot 4.7 or newer is required")
        extra = ["--human-material-mode", "production_texture_array"]
        if args.backend == "gpu":
            extra.append("--gpu-resident-render-candidate")
        if not args.no_probe:
            extra.append("--runtime-readiness-probe")
        if args.publication_probe:
            extra.append("--gpu-publication-probe")
        trace = output.with_name(output.stem + "_native.json") if args.native_trace else None
        if trace is not None and trace.exists():
            parser.error("native trace already exists; choose a new output stem")
        # The existing runner stores its log paths relative to the project.
        capture = project / ".godot" / "world_transvoxel_captures" / output.stem
        if capture.exists():
            parser.error("capture directory already exists; choose a new output stem")
        pin = json.loads((project / "WORLD_TRANSVOXEL_RUNTIME_PIN.json").read_text())
        actual_artifact_digest = runtime_artifact.artifact_digest(project / "addons" / "world_transvoxel")
        result, execution = baseline._run_measurement(
            args.godot, project, capture, 1, 2, 24.0, 2, 0,
            causal_trace_path=trace, stem_prefix=args.backend,
            extra_args=extra, retain_incomplete_measurement=True,
        )
        payload = {
            "baseline": result, "execution": execution, "pin": pin,
            "actual_runtime_artifact_sha256": actual_artifact_digest,
            "runtime_artifact_matches_pin": actual_artifact_digest == pin["runtime_artifact"]["digest_sha256"],
            "affinity": affinity, "godot_version": version,
            "diagnostic_only_not_performance_baseline": not args.no_probe or args.native_trace,
        }
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({
            "output": str(output), "complete": result["measurement_complete"],
            "movement": result["movement"], "edit_accepted": result["edit"]["interaction_accepted"],
        }, indent=2))
        return 0 if result.get("ok") is True else 1
    finally:
        process.cpu_affinity(previous_affinity)


if __name__ == "__main__":
    raise SystemExit(main())
