#!/usr/bin/env python3
"""Run the bounded walking/collision probe and retain CPU/GPU observations."""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import statistics
import subprocess
import sys
import threading
import time
from typing import Any

import psutil

import run_human_playtest


PROFILE = "g23_four_biomes_lakes_mountains_roads_2k_256_on_demand"
SAMPLE_SECONDS = 0.5


def _gpu_sample() -> dict[str, Any]:
    executable = shutil.which("nvidia-smi")
    if not executable:
        return {"available": False, "reason": "nvidia_smi_unavailable"}
    command = [
        executable,
        "--query-gpu=utilization.gpu,power.draw,pstate",
        "--format=csv,noheader,nounits",
    ]
    try:
        result = subprocess.run(
            command, text=True, capture_output=True, timeout=5, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"available": False, "reason": type(exc).__name__}
    if result.returncode != 0 or not result.stdout.strip():
        return {
            "available": False,
            "reason": result.stderr.strip() or f"exit_{result.returncode}",
        }
    fields = [value.strip() for value in result.stdout.splitlines()[0].split(",")]
    if len(fields) < 3:
        return {"available": False, "reason": "unexpected_output"}
    try:
        utilization = float(fields[0])
        power = float(fields[1])
    except ValueError:
        return {"available": False, "reason": "non_numeric_output"}
    return {
        "available": True,
        "board_global_utilization_percent": utilization,
        "board_power_watts": power,
        "pstate": fields[2],
    }


def _phase_summary(samples: list[dict[str, Any]], phase: str) -> dict[str, Any]:
    selected = [sample for sample in samples if sample["phase"] == phase]
    if not selected:
        return {"sample_count": 0}

    def values(key: str) -> list[float]:
        return [float(sample[key]) for sample in selected if sample.get(key) is not None]

    def distribution(items: list[float]) -> dict[str, float | int]:
        if not items:
            return {"count": 0}
        ordered = sorted(items)
        p95_index = max(0, min(len(ordered) - 1, int(len(ordered) * 0.95) - 1))
        return {
            "count": len(ordered),
            "mean": statistics.fmean(ordered),
            "p95": ordered[p95_index],
            "maximum": ordered[-1],
        }

    return {
        "sample_count": len(selected),
        "godot_process_cpu_percent": distribution(values("process_cpu_percent")),
        "active_logical_cores": distribution(values("active_logical_cores")),
        "system_cpu_percent": distribution(values("system_cpu_percent")),
        "gpu_board_global_utilization_percent": distribution(
            values("gpu_board_global_utilization_percent")
        ),
        "gpu_board_power_watts": distribution(values("gpu_board_power_watts")),
        "rss_bytes": distribution(values("rss_bytes")),
    }


def _read_output(
    stream: Any, lines: list[str], phase_state: dict[str, str]
) -> None:
    for line in iter(stream.readline, ""):
        lines.append(line)
        print(line, end="", flush=True)
        marker = "WT_GROUND_TRAVERSAL_PHASE phase="
        if marker in line:
            phase_state["value"] = line.split(marker, 1)[1].strip().split()[0]
    stream.close()


def _write_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run(args: argparse.Namespace) -> int:
    project = pathlib.Path(args.project).resolve()
    result_path = pathlib.Path(args.output).resolve()
    usage_path = pathlib.Path(args.usage_output).resolve()
    godot = run_human_playtest.find_godot(args.godot)
    command = [
        str(godot),
        "--path",
        str(project),
    ]
    if args.headless:
        command.append("--headless")
    command.extend(
        [
            "--",
            "--p2-profile",
            PROFILE,
            "--human-material-mode",
            "production_texture_array",
            "--procedural-generation-workers",
            "2",
            "--ground-traversal-probe",
            "--ground-traversal-probe-output",
            str(result_path),
        ]
    )
    if args.windowed:
        command.append("--human-windowed")
    print(" ".join(command), flush=True)
    if args.print_only:
        return 0
    for path in (result_path, usage_path):
        if path.is_file():
            path.unlink()

    launcher = psutil.Process()
    available_affinity = launcher.cpu_affinity()
    affinity = available_affinity[:3]
    if not affinity:
        raise RuntimeError("ground traversal probe requires at least one logical CPU")
    launcher.cpu_affinity(affinity)
    try:
        process = subprocess.Popen(
            command,
            cwd=project,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    finally:
        launcher.cpu_affinity(available_affinity)

    measured = psutil.Process(process.pid)
    measured.cpu_percent(None)
    psutil.cpu_percent(None)
    lines: list[str] = []
    phase_state = {"value": "startup"}
    reader = threading.Thread(
        target=_read_output,
        args=(process.stdout, lines, phase_state),
        daemon=True,
    )
    reader.start()
    started = time.perf_counter()
    samples: list[dict[str, Any]] = []
    while process.poll() is None:
        time.sleep(SAMPLE_SECONDS)
        try:
            memory = measured.memory_info()
            process_cpu = measured.cpu_percent(None)
            thread_count = measured.num_threads()
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            break
        gpu = _gpu_sample()
        samples.append(
            {
                "elapsed_seconds": time.perf_counter() - started,
                "phase": phase_state["value"],
                "process_cpu_percent": process_cpu,
                "active_logical_cores": process_cpu / 100.0,
                "system_cpu_percent": psutil.cpu_percent(None),
                "rss_bytes": int(memory.rss),
                "thread_count": thread_count,
                "gpu_board_global_utilization_percent": (
                    gpu.get("board_global_utilization_percent")
                    if gpu.get("available")
                    else None
                ),
                "gpu_board_power_watts": (
                    gpu.get("board_power_watts") if gpu.get("available") else None
                ),
                "gpu_pstate": gpu.get("pstate"),
                "gpu_sample_available": bool(gpu.get("available", False)),
            }
        )
    return_code = process.wait()
    reader.join(timeout=5)
    wall_seconds = time.perf_counter() - started
    result = None
    if result_path.is_file():
        result = json.loads(result_path.read_text(encoding="utf-8"))
    payload = {
        "schema": "world_transvoxel.ground_traversal_usage.v1",
        "command": command,
        "logical_cpu_affinity": affinity,
        "sample_interval_seconds": SAMPLE_SECONDS,
        "wall_seconds": wall_seconds,
        "exit_code": return_code,
        "gpu_scope": "board_global_not_process_attributed",
        "phases": {
            phase: _phase_summary(samples, phase)
            for phase in ("startup", "relocation", "settling", "static", "moving")
        },
        "samples": samples,
        "probe_result": result,
    }
    _write_json(usage_path, payload)
    print(
        "WT_GROUND_TRAVERSAL_USAGE "
        f"exit={return_code} result={result_path} usage={usage_path}",
        flush=True,
    )
    return return_code


def main(argv: list[str]) -> int:
    project = run_human_playtest.repo_root()
    default_root = (
        project / ".godot" / "world_transvoxel_captures" / "ground_traversal"
    )
    parser = argparse.ArgumentParser(
        description="Run the average-speed ground collision traversal probe."
    )
    parser.add_argument("--project", default=str(project))
    parser.add_argument("--godot")
    parser.add_argument("--output", default=str(default_root / "latest.json"))
    parser.add_argument(
        "--usage-output", default=str(default_root / "latest_usage.json")
    )
    parser.add_argument("--windowed", action="store_true")
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--print-only", action="store_true")
    return run(parser.parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
