#!/usr/bin/env python3
"""Launch the integration game's current human terrain playtest.

This is the single entrypoint for manual terrain inspection. It intentionally
does not run validation gates or visual-capture automation.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import statistics
import subprocess
import sys
import time
from typing import Any

import psutil


WINDOWS_STEAM_GODOT = pathlib.Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
)
LATEST_HUMAN_PROFILE = "g23_four_biomes_lakes_mountains_roads_2k_256_on_demand"
LATEST_HUMAN_MATERIAL = "production_texture_array"
WATERFALL_SAMPLE_INTERVAL_SECONDS = 0.25
WATERFALL_GPU_SAMPLE_INTERVAL_SECONDS = 0.5


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[1]


def marker_root(project: pathlib.Path) -> pathlib.Path:
    return project / ".godot" / "world_transvoxel_captures" / "human_artifact_marks"


def failure_report_path(project: pathlib.Path) -> pathlib.Path:
    return (
        project / ".godot" / "world_transvoxel_captures"
        / "startup_failure" / "latest.json"
    )


def print_failure_self_report(project: pathlib.Path) -> None:
    path = failure_report_path(project)
    payload = load_json(path) if path.is_file() else None
    if not payload:
        return
    summary = payload.get("summary", {})
    first_blocked = (
        f"{summary.get('first_blocked_replacement_key_x', 0)}:"
        f"{summary.get('first_blocked_replacement_key_y', 0)}:"
        f"{summary.get('first_blocked_replacement_key_z', 0)}:"
        f"lod{summary.get('first_blocked_replacement_key_lod', 0)}"
    )
    print(
        "WT_TERRAIN_FAILURE "
        f"cause={payload.get('primary_blocker', 'unknown')} "
        f"elapsed_ms={payload.get('elapsed_msec', 0)} "
        f"visual={summary.get('render_resources', 0)} "
        f"collision={summary.get('collision_resources', 0)} "
        f"gpu_active={summary.get('gpu_resident_active_chunks', 0)} "
        f"gpu_tracked={summary.get('gpu_resident_tracked_chunks', 0)} "
        f"pending={summary.get('pending_chunk_replacements', 0)} "
        f"blocked={summary.get('blocked_pending_chunk_replacements', 0)} "
        f"first_blocked={first_blocked} "
        f"scheduler={summary.get('scheduler_queued_jobs', 0)} "
        f"storage={summary.get('storage_queued_requests', 0)}/"
        f"{summary.get('storage_in_flight_requests', 0)} "
        f"mesh={summary.get('mesh_worker_queued_jobs', 0)} "
        f"report={path}",
        flush=True,
    )


def load_json(path: pathlib.Path) -> dict[str, Any] | None:
    try:
        import json

        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def latest_human_marker(project: pathlib.Path) -> pathlib.Path:
    root = marker_root(project)
    candidates = sorted(root.glob("*.json"), key=lambda path: path.stat().st_mtime, reverse=True)
    for path in candidates:
        data = load_json(path)
        if data and data.get("source") == "human":
            return path
    raise FileNotFoundError(f"no human marker JSON files found under {root}")


def find_godot(explicit: str | None) -> pathlib.Path:
    if explicit:
        candidate = pathlib.Path(explicit)
        if candidate.exists():
            return candidate
        raise FileNotFoundError(f"Godot executable does not exist: {candidate}")

    env_value = os.environ.get("GODOT4_BIN") or os.environ.get("GODOT_BIN")
    if env_value:
        candidate = pathlib.Path(env_value)
        if candidate.exists():
            return candidate

    if WINDOWS_STEAM_GODOT.exists():
        return WINDOWS_STEAM_GODOT

    for name in ("godot4", "godot"):
        found = shutil.which(name)
        if found:
            return pathlib.Path(found)

    raise FileNotFoundError(
        "Godot 4 executable not found. Pass --godot or set GODOT4_BIN."
    )


def build_command(args: argparse.Namespace) -> list[str]:
    godot = find_godot(args.godot)
    project = pathlib.Path(args.project).resolve()
    if not (project / "project.godot").is_file():
        raise FileNotFoundError(f"project.godot not found under {project}")
    if args.inspect_marker and args.inspect_latest_marker:
        raise ValueError("use either --inspect-marker or --inspect-latest-marker, not both")
    inspect_marker: pathlib.Path | None = None
    if args.inspect_marker:
        inspect_marker = pathlib.Path(args.inspect_marker).resolve()
        if not inspect_marker.is_file():
            raise FileNotFoundError(f"marker JSON does not exist: {inspect_marker}")
    elif args.inspect_latest_marker:
        inspect_marker = latest_human_marker(project)

    command = [str(godot)]
    if args.rendering_driver:
        command.extend(["--rendering-driver", args.rendering_driver])
    command.extend([
        "--path",
        str(project),
        "--",
        "--p2-profile",
        args.profile,
        "--human-material-mode",
        args.material,
    ])
    if args.windowed:
        command.append("--human-windowed")
    if args.preserve_storage:
        command.append("--human-preserve-storage")
    if args.lighting_preset is not None:
        command.extend(["--human-lighting-preset", str(args.lighting_preset)])
    if args.preset:
        command.extend(["--human-playtest-preset", args.preset])
    if args.procedural_generation_workers is not None:
        command.extend([
            "--procedural-generation-workers",
            str(args.procedural_generation_workers),
        ])
    if args.meshing_workers is not None:
        command.extend(["--meshing-workers", str(args.meshing_workers)])
    if args.gpu_meshing_shadow:
        command.append("--gpu-meshing-shadow")
    if args.gpu_meshing_publication_candidate:
        command.append("--gpu-meshing-publication-candidate")
    if args.gpu_resident_render_candidate:
        command.append("--gpu-resident-render-candidate")
    if args.gpu_stage_timing:
        command.append("--gpu-stage-timing")
    if getattr(args, "debug_view", None):
        command.extend(["--human-debug-view", args.debug_view])
    if inspect_marker is not None:
        command.extend(["--human-artifact-inspect-marker", str(inspect_marker)])
    if args.terrain_waterfall:
        command.extend(
            [
                "--terrain-waterfall",
                "--terrain-waterfall-output",
                str(args.terrain_waterfall_trace_path),
            ]
        )
        if args.terrain_waterfall_autonomous:
            command.append("--terrain-waterfall-autonomous-route")
    elif args.cpu_causal_trace:
        trace_path = (
            pathlib.Path(args.cpu_causal_trace_output).resolve()
            if args.cpu_causal_trace_output
            else project
            / ".godot"
            / "world_transvoxel_captures"
            / "cpu_causal_trace"
            / "latest_human_trace.json"
        )
        command.extend(["--cpu-causal-trace-output", str(trace_path)])
    return command


def waterfall_paths(
    project: pathlib.Path, args: argparse.Namespace
) -> dict[str, pathlib.Path]:
    root = project / ".godot" / "world_transvoxel_captures" / "terrain_waterfall"
    trace = (
        pathlib.Path(args.terrain_waterfall_output).resolve()
        if args.terrain_waterfall_output
        else root / "latest_human_trace.json"
    )
    report = (
        pathlib.Path(args.terrain_waterfall_report_output).resolve()
        if args.terrain_waterfall_report_output
        else root / "latest_human_report.json"
    )
    usage_stem = (
        f"{trace.stem[:-6]}_usage"
        if trace.stem.endswith("_trace")
        else f"{trace.stem}_usage"
    )
    usage = trace.with_name(f"{usage_stem}.json")
    summary = report.with_suffix(".txt")
    return {"trace": trace, "report": report, "usage": usage, "summary": summary}


def _write_usage_report(
    path: pathlib.Path,
    samples: list[dict[str, Any]],
    affinity: list[int],
    wall_seconds: float,
    exit_code: int,
    sampling_started_unix_seconds: float,
    sampling_ended_unix_seconds: float,
) -> None:
    cpu_values = [float(sample["process_cpu_percent"]) for sample in samples]
    rss_values = [int(sample["rss_bytes"]) for sample in samples]
    gpu_utilization = [
        float(sample["gpu_board_utilization_percent"])
        for sample in samples
        if sample.get("gpu_board_utilization_percent") is not None
    ]
    gpu_power = [
        float(sample["gpu_board_power_watts"])
        for sample in samples
        if sample.get("gpu_board_power_watts") is not None
    ]

    def distribution(values: list[float]) -> dict[str, float | int]:
        if not values:
            return {"count": 0, "mean": 0.0, "median": 0.0, "maximum": 0.0}
        return {
            "count": len(values),
            "mean": statistics.fmean(values),
            "median": statistics.median(values),
            "maximum": max(values),
        }

    payload = {
        "schema": "world_transvoxel.terrain_waterfall_usage.v1",
        "sample_interval_seconds": WATERFALL_SAMPLE_INTERVAL_SECONDS,
        "logical_cpu_affinity": affinity,
        "logical_cpu_capacity": len(affinity),
        "wall_seconds": wall_seconds,
        "sampling_started_unix_seconds": sampling_started_unix_seconds,
        "sampling_ended_unix_seconds": sampling_ended_unix_seconds,
        "exit_code": exit_code,
        "sample_count": len(samples),
        "process_cpu_percent_mean": (
            sum(cpu_values) / len(cpu_values) if cpu_values else 0.0
        ),
        "process_cpu_percent_maximum": max(cpu_values, default=0.0),
        "average_active_logical_cores": (
            sum(cpu_values) / (100.0 * len(cpu_values)) if cpu_values else 0.0
        ),
        "rss_bytes_maximum": max(rss_values, default=0),
        "gpu_board_telemetry_scope": "board_global_not_process_attributed",
        "gpu_board_utilization_percent": distribution(gpu_utilization),
        "gpu_board_power_watts": distribution(gpu_power),
        "samples": samples,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _waterfall_trace_paths(base: pathlib.Path) -> list[pathlib.Path]:
    candidates = [base]
    candidates.extend(sorted(base.parent.glob(f"{base.stem}_[0-9][0-9][0-9]{base.suffix}")))
    return [path for path in candidates if path.is_file()]


def _gpu_board_sample() -> dict[str, float | str] | None:
    executable = shutil.which("nvidia-smi")
    if executable is None:
        windows_candidate = pathlib.Path(r"C:\Windows\System32\nvidia-smi.exe")
        if not windows_candidate.is_file():
            return None
        executable = str(windows_candidate)
    try:
        result = subprocess.run(
            [
                executable,
                "--query-gpu=utilization.gpu,power.draw,pstate",
                "--format=csv,noheader,nounits",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=3.0,
        )
        first_line = result.stdout.strip().splitlines()[0]
        utilization, power, pstate = [part.strip() for part in first_line.split(",", 2)]
        return {
            "gpu_board_utilization_percent": float(utilization),
            "gpu_board_power_watts": float(power),
            "gpu_board_pstate": pstate,
        }
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return None


def run_waterfall_session(
    command: list[str], project: pathlib.Path, paths: dict[str, pathlib.Path]
) -> int:
    for path in [paths["trace"], paths["usage"], paths["report"], paths["summary"]]:
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.is_file():
            path.unlink()
    for path in paths["trace"].parent.glob(
        f"{paths['trace'].stem}_[0-9][0-9][0-9]{paths['trace'].suffix}"
    ):
        path.unlink()

    failure_path = failure_report_path(project)
    failure_path.unlink(missing_ok=True)

    launcher = psutil.Process()
    available_affinity = launcher.cpu_affinity()
    affinity = available_affinity[:3]
    if not affinity:
        raise RuntimeError("terrain waterfall requires at least one logical CPU")
    launcher.cpu_affinity(affinity)
    try:
        process = subprocess.Popen(command, cwd=project)
    finally:
        launcher.cpu_affinity(available_affinity)

    measured = psutil.Process(process.pid)
    measured.cpu_percent(None)
    samples: list[dict[str, Any]] = []
    sampling_started_unix_seconds = time.time()
    started = time.perf_counter()
    next_gpu_sample = 0.0
    failure_reported = False
    failure_seen_at: float | None = None
    while process.poll() is None:
        time.sleep(WATERFALL_SAMPLE_INTERVAL_SECONDS)
        try:
            memory = measured.memory_info()
            elapsed_seconds = time.perf_counter() - started
            sample: dict[str, Any] = {
                "elapsed_seconds": elapsed_seconds,
                "unix_time_seconds": time.time(),
                "process_cpu_percent": measured.cpu_percent(None),
                "rss_bytes": int(memory.rss),
                "thread_count": measured.num_threads(),
            }
            if elapsed_seconds >= next_gpu_sample:
                gpu_sample = _gpu_board_sample()
                if gpu_sample is not None:
                    sample.update(gpu_sample)
                next_gpu_sample = elapsed_seconds + WATERFALL_GPU_SAMPLE_INTERVAL_SECONDS
            samples.append(sample)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            break
        if failure_path.is_file():
            if not failure_reported:
                print_failure_self_report(project)
                failure_reported = True
                failure_seen_at = time.perf_counter()
            if (
                "--terrain-waterfall-autonomous-route" in command
                and failure_seen_at is not None
                and time.perf_counter() - failure_seen_at >= 5.0
            ):
                process.terminate()
    exit_code = process.wait()
    wall_seconds = time.perf_counter() - started
    _write_usage_report(
        paths["usage"], samples, affinity, wall_seconds, exit_code,
        sampling_started_unix_seconds, time.time(),
    )
    if not failure_reported:
        print_failure_self_report(project)

    trace_paths = _waterfall_trace_paths(paths["trace"])
    if trace_paths:
        import terrain_waterfall_report

        report = terrain_waterfall_report.build_session_report(
            trace_paths, paths["usage"]
        )
        terrain_waterfall_report.write_report(
            report, paths["report"], paths["summary"]
        )
        print(
            "WT_TERRAIN_WATERFALL_REPORT "
            f"decision={report['decision']['classification']} "
            f"output={paths['report']}",
            flush=True,
        )
    else:
        print(
            "WT_TERRAIN_WATERFALL_REPORT_MISSING_TRACE "
            f"expected={paths['trace']}",
            flush=True,
        )
    return exit_code


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Launch the current World Transvoxel human playtest."
    )
    parser.add_argument(
        "--latest",
        action="store_true",
        help=(
            "Launch the current standard human playtest preset. "
            f"Currently profile={LATEST_HUMAN_PROFILE}, material={LATEST_HUMAN_MATERIAL}."
        ),
    )
    parser.add_argument("--godot", help="Path to a Godot 4 executable.")
    parser.add_argument(
        "--project",
        default=str(repo_root()),
        help="Path to the integration game project directory.",
    )
    parser.add_argument(
        "--profile",
        default=LATEST_HUMAN_PROFILE,
        help="Terrain profile to launch.",
    )
    parser.add_argument(
        "--material",
        default=LATEST_HUMAN_MATERIAL,
        help="Human material mode to use.",
    )
    parser.add_argument(
        "--windowed",
        action="store_true",
        help="Run windowed. Default is the project's fullscreen human-test behavior.",
    )
    parser.add_argument(
        "--preserve-storage",
        action="store_true",
        help="Reuse existing human-playtest storage instead of starting fresh.",
    )
    parser.add_argument(
        "--lighting-preset",
        type=int,
        help="Optional human lighting preset index.",
    )
    parser.add_argument(
        "--preset",
        help="Optional human playtest preset, for example 'tunnel' or 'static_water_basin'.",
    )
    parser.add_argument(
        "--procedural-generation-workers",
        type=int,
        choices=range(1, 9),
        metavar="1..8",
        help="Override bounded procedural page-generation workers.",
    )
    parser.add_argument(
        "--meshing-workers",
        type=int,
        choices=range(0, 9),
        metavar="0..8",
        help="Override bounded authority meshing workers; normal profiles use 0.",
    )
    parser.add_argument(
        "--rendering-driver",
        choices=("vulkan", "d3d12"),
        help="Optional Godot rendering driver override for a qualification run.",
    )
    parser.add_argument(
        "--gpu-meshing-shadow",
        action="store_true",
        help=(
            "Enable validation-only GPU meshing shadow capture. CPU render and "
            "collision publication remain authoritative."
        ),
    )
    parser.add_argument(
        "--gpu-meshing-publication-candidate",
        action="store_true",
        help=(
            "Enable the default-off matched GPU-cell visual publication candidate. "
            "CPU world and collision authority remain unchanged."
        ),
    )
    parser.add_argument(
        "--gpu-resident-render-candidate",
        action="store_true",
        help=(
            "Enable default-off production chunk lifecycle publication through "
            "the resident GPU renderer. CPU collision remains authoritative and "
            "production material parity is not yet qualified."
        ),
    )
    parser.add_argument(
        "--gpu-stage-timing",
        action="store_true",
        help="Record opt-in GPU controller and render-effect stage timings.",
    )
    parser.add_argument(
        "--debug-view", choices=("collision", "lod", "pipeline", "all", "menu"),
        help="Start with optional live terrain diagnostics; also available in the ESC menu.",
    )
    parser.add_argument(
        "--inspect-marker",
        help="Launch at an exact marker JSON produced by Tilde+M.",
    )
    parser.add_argument(
        "--inspect-latest-marker",
        action="store_true",
        help="Launch at the latest human marker JSON produced by Tilde+M.",
    )
    parser.add_argument(
        "--print-only",
        action="store_true",
        help="Print the command without launching Godot.",
    )
    parser.add_argument(
        "--cpu-causal-trace",
        action="store_true",
        help="Enable the bounded CPU-B2 causal trace for this human session.",
    )
    parser.add_argument(
        "--cpu-causal-trace-output",
        help="Optional CPU-B2 trace JSON path; implies --cpu-causal-trace.",
    )
    parser.add_argument(
        "--terrain-waterfall",
        action="store_true",
        help=(
            "Enable the optional live terrain waterfall, retain its causal trace, "
            "sample process usage on at most three logical CPUs, and write a report."
        ),
    )
    parser.add_argument(
        "--terrain-waterfall-output",
        help="Optional raw terrain-waterfall trace JSON path.",
    )
    parser.add_argument(
        "--terrain-waterfall-report-output",
        help="Optional analyzed terrain-waterfall report JSON path.",
    )
    parser.add_argument(
        "--terrain-waterfall-autonomous",
        action="store_true",
        help=(
            "Run the deterministic two-leg flight, relocated carve, and relocated "
            "construction route, then close and analyze it."
        ),
    )
    args = parser.parse_args(argv)
    if args.cpu_causal_trace_output:
        args.cpu_causal_trace = True
    if args.latest:
        args.profile = LATEST_HUMAN_PROFILE
        args.material = LATEST_HUMAN_MATERIAL

    project = pathlib.Path(args.project).resolve()
    paths: dict[str, pathlib.Path] | None = None
    if args.terrain_waterfall_output or args.terrain_waterfall_report_output or \
            args.terrain_waterfall_autonomous:
        args.terrain_waterfall = True
    if args.terrain_waterfall:
        paths = waterfall_paths(project, args)
        args.terrain_waterfall_trace_path = paths["trace"]

    command = build_command(args)
    print(" ".join(command), flush=True)
    if args.print_only:
        return 0
    failure_path = failure_report_path(project)
    failure_path.unlink(missing_ok=True)
    if paths is not None:
        return run_waterfall_session(command, project, paths)
    exit_code = subprocess.call(command, cwd=project)
    print_failure_self_report(project)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
