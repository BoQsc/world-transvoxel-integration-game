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
    parser.add_argument("--gpu-stage-timing", action="store_true")
    parser.add_argument("--gpu-lifecycle-history", action="store_true")
    parser.add_argument("--gpu-interaction-collision-demand", action="store_true")
    parser.add_argument(
        "--meshing-workers", type=int, choices=range(0, 9), default=None,
        help="Override launcher policy (default: GPU 1, CPU 0).",
    )
    parser.add_argument(
        "--foreground-priority", choices=("auto", "enabled", "disabled"),
        default="auto",
    )
    parser.add_argument(
        "--foreground-priority-focus-settle-frames", type=int, default=0,
        choices=range(0, 61), metavar="0..60",
    )
    parser.add_argument(
        "--godot", type=pathlib.Path,
        default=pathlib.Path(
            r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine"
            r"\godot.windows.opt.tools.64.exe"
        ),
    )
    args = parser.parse_args()
    meshing_workers = args.meshing_workers
    if meshing_workers is None:
        meshing_workers = 1 if args.backend == "gpu" else 0
    if args.publication_probe and (args.no_probe or args.backend != "gpu"):
        parser.error("publication inspection requires GPU with the readiness probe")
    if args.gpu_stage_timing and args.backend != "gpu":
        parser.error("GPU stage timing requires the GPU backend")
    if args.gpu_lifecycle_history and args.backend != "gpu":
        parser.error("GPU lifecycle history requires the GPU backend")
    if args.gpu_interaction_collision_demand and args.backend != "gpu":
        parser.error("GPU interaction collision demand requires the GPU backend")
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
        if args.gpu_stage_timing:
            extra.append("--gpu-stage-timing")
        if args.gpu_lifecycle_history:
            extra.append("--gpu-lifecycle-history")
        if args.gpu_interaction_collision_demand:
            extra.append("--gpu-interaction-collision-demand")
        if args.foreground_priority != "auto":
            extra.extend(["--foreground-priority", args.foreground_priority])
        if args.foreground_priority_focus_settle_frames > 0:
            extra.extend([
                "--foreground-priority-focus-settle-frames",
                str(args.foreground_priority_focus_settle_frames),
            ])
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
            args.godot, project, capture, 1, 2, 24.0, 2, meshing_workers,
            causal_trace_path=trace, stem_prefix=args.backend,
            extra_args=extra, retain_incomplete_measurement=True,
        )
        payload = {
            "baseline": result, "execution": execution, "pin": pin,
            "actual_runtime_artifact_sha256": actual_artifact_digest,
            "runtime_artifact_matches_pin": actual_artifact_digest == pin["runtime_artifact"]["digest_sha256"],
            "affinity": affinity, "godot_version": version,
            "requested_meshing_workers": meshing_workers,
            "observed_meshing_workers": result.get(
                "authority_runtime_metrics_end", {}
            ).get("mesh_worker_count"),
            "diagnostic_only_not_performance_baseline": (
                not args.no_probe
                or args.native_trace
                or args.gpu_stage_timing
                or args.gpu_lifecycle_history
            ),
        }
        payload["worker_configuration_matches_requested"] = (
            payload["observed_meshing_workers"] == meshing_workers
        )
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        if not payload["worker_configuration_matches_requested"]:
            print("ERROR: runtime meshing worker count differs from requested configuration")
            return 1
        print(json.dumps({
            "output": str(output), "complete": result["measurement_complete"],
            "movement": result["movement"], "edit_accepted": result["edit"]["interaction_accepted"],
        }, indent=2))
        return 0 if result.get("ok") is True else 1
    finally:
        process.cpu_affinity(previous_affinity)


if __name__ == "__main__":
    raise SystemExit(main())
