#!/usr/bin/env python3
"""Run the production GPU tunnel/collision gate with retained, bounded evidence."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys
import time

import psutil

from p2_production_integration_game_quality import (
    VISUAL_SUMMARY_PREFIX,
    find_godot,
    parse_visual_summary,
)
from run_human_playtest import LATEST_HUMAN_MATERIAL, LATEST_HUMAN_PROFILE


def terminate_tree(process: subprocess.Popen[str]) -> None:
    try:
        root = psutil.Process(process.pid)
        children = root.children(recursive=True)
        for child in children:
            child.terminate()
        root.terminate()
        _, alive = psutil.wait_procs([*children, root], timeout=8.0)
        for item in alive:
            item.kill()
    except psutil.Error:
        process.kill()


def tree_rss_bytes(pid: int) -> int:
    try:
        root = psutil.Process(pid)
        processes = [root, *root.children(recursive=True)]
    except psutil.Error:
        return 0
    total = 0
    for process in processes:
        try:
            total += process.memory_info().rss
        except psutil.Error:
            pass
    return total


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot")
    parser.add_argument("--project", default=str(pathlib.Path(__file__).resolve().parents[1]))
    parser.add_argument("--driver", choices=("vulkan", "d3d12"), default="vulkan")
    parser.add_argument("--wait-frames", type=int, default=600)
    parser.add_argument("--timeout-seconds", type=float, default=360.0)
    parser.add_argument(
        "--launch-grace-seconds",
        type=float,
        default=15.0,
        help="Bound engine launch separately before the runtime gate begins.",
    )
    parser.add_argument("--memory-limit-gib", type=float, default=6.0)
    parser.add_argument(
        "--fast-stage-gate",
        action="store_true",
        help="Skip offline persistence snapshots and gate immediate visual/collision behavior.",
    )
    args = parser.parse_args()
    # A fast-stage run is a dependency probe, not a soak. Once its immediate
    # coverage deadline is missed, additional minutes cannot make it pass.
    runtime_timeout = min(args.timeout_seconds, 10.0) if args.fast_stage_gate else args.timeout_seconds

    project = pathlib.Path(args.project).resolve()
    evidence_dir = project / ".godot" / "world_transvoxel_captures" / "gpu_tunnel_collision_gate"
    evidence_dir.mkdir(parents=True, exist_ok=True)
    log_path = evidence_dir / f"{args.driver}.log"
    summary_path = evidence_dir / f"{args.driver}.json"
    capture_path = evidence_dir / f"{args.driver}.png"
    command = [
        str(find_godot(args.godot)),
        "--rendering-driver", args.driver,
        "--path", str(project),
        "--",
        "--p2-profile", LATEST_HUMAN_PROFILE,
        "--human-material-mode", LATEST_HUMAN_MATERIAL,
        "--human-visual-capture", str(capture_path),
        "--human-visual-capture-mode", "edit_tunnel_transient_crawl_gate",
        "--human-visual-capture-wait-frames", str(args.wait_frames),
        "--gpu-resident-render-candidate",
    ]
    if args.fast_stage_gate:
        command.extend(("--tunnel-fast-stage-gate", "--gpu-stage-timing"))
    memory_limit = int(args.memory_limit_gib * 1024**3)
    started = time.monotonic()
    runtime_started: float | None = None
    peak_rss = 0
    termination_reason = ""
    with log_path.open("w", encoding="utf-8") as log:
        process_environment = os.environ.copy()
        if args.fast_stage_gate:
            process_environment["WT_VIEWER_ENQUEUE_TIMING"] = "1"
        process = subprocess.Popen(
            command,
            cwd=project,
            env=process_environment,
            text=True,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        while process.poll() is None:
            rss = tree_rss_bytes(process.pid)
            peak_rss = max(peak_rss, rss)
            elapsed = time.monotonic() - started
            if runtime_started is None and log_path.exists():
                try:
                    live_output = log_path.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    live_output = ""
                if "WT_BOOT_STAGE terrain_start_ready" in live_output:
                    runtime_started = time.monotonic()
            if rss >= memory_limit:
                termination_reason = "memory_limit_exceeded"
                terminate_tree(process)
                break
            if runtime_started is None and elapsed >= args.launch_grace_seconds:
                termination_reason = "launch_timeout"
                terminate_tree(process)
                break
            if runtime_started is not None and time.monotonic() - runtime_started >= runtime_timeout:
                termination_reason = "fast_stage_deadline" if args.fast_stage_gate else "runtime_timeout"
                terminate_tree(process)
                break
            time.sleep(0.25)
        return_code = process.wait()

    output = log_path.read_text(encoding="utf-8", errors="replace")
    summary: dict[str, object] = {}
    if VISUAL_SUMMARY_PREFIX in output:
        summary = parse_visual_summary(output, "edit_tunnel_transient_crawl_gate")
    evidence = {
        "schema": "world_transvoxel.gpu_tunnel_collision_gate.v1",
        "driver": args.driver,
        "return_code": return_code,
        "termination_reason": termination_reason,
        "elapsed_seconds": time.monotonic() - started,
        "runtime_elapsed_seconds": (
            time.monotonic() - runtime_started if runtime_started is not None else None
        ),
        "peak_process_tree_rss_bytes": peak_rss,
        "memory_limit_bytes": memory_limit,
        "log_path": str(log_path),
        "capture_path": str(capture_path),
        "summary": summary,
        "fast_stage_gate": args.fast_stage_gate,
        "runtime_timeout_seconds": runtime_timeout,
    }
    summary_path.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    tunnel = summary.get("tunnel", {}) if isinstance(summary, dict) else {}
    passed = return_code == 0 and isinstance(tunnel, dict) and tunnel.get("ok") is True
    marker = "GPU_TUNNEL_COLLISION_GATE_PASS" if passed else "GPU_TUNNEL_COLLISION_GATE_FAIL"
    print(
        f"{marker} driver={args.driver} return_code={return_code} "
        f"reason={termination_reason or 'none'} peak_rss_bytes={peak_rss} "
        f"tunnel_error={tunnel.get('error', 'none') if isinstance(tunnel, dict) else 'missing'} "
        f"evidence={summary_path} log={log_path}"
    )
    if not passed:
        failure_lines = [
            line for line in output.splitlines()
            if "FAIL" in line or "ERROR:" in line or "collision passage blocked" in line
        ]
        for line in failure_lines[-12:]:
            print(line[-2000:], file=sys.stderr)
    return 0 if passed else (return_code or 1)


if __name__ == "__main__":
    raise SystemExit(main())
