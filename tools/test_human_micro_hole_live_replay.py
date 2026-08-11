#!/usr/bin/env python3
"""Replay preserved human edits and gate settled seam and pixel correctness."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import pathlib
import subprocess
import sys
import time
from typing import Any

import p2_production_integration_game_quality as p2_quality


PASS_MARKER = "WT_HUMAN_MICRO_HOLE_LIVE_REPLAY_GATE_PASS"


def project_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[1]


def set_three_cpu_affinity(process: subprocess.Popen[str]) -> None:
    cpu_count = max(1, min(3, os.cpu_count() or 1))
    mask = (1 << cpu_count) - 1
    if sys.platform == "win32":
        process_set_information = 0x0200
        process_query_limited_information = 0x1000
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.OpenProcess(
            process_set_information | process_query_limited_information,
            False,
            process.pid,
        )
        if not handle:
            raise OSError("OpenProcess failed while limiting Godot CPU affinity")
        try:
            if not kernel32.SetProcessAffinityMask(handle, mask):
                raise OSError("SetProcessAffinityMask failed for Godot")
        finally:
            kernel32.CloseHandle(handle)
    elif hasattr(os, "sched_setaffinity"):
        os.sched_setaffinity(process.pid, set(range(cpu_count)))


def load_json(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object: {path}")
    return value


def newest_result(root: pathlib.Path, started_at: float) -> tuple[pathlib.Path, dict[str, Any]]:
    result_root = root / ".godot" / "world_transvoxel_captures" / "human_artifact_marks" / "live_replays"
    candidates = sorted(
        result_root.glob("*_live_replay_result.json"),
        key=lambda item: item.stat().st_mtime,
        reverse=True,
    )
    for path in candidates:
        if path.stat().st_mtime + 0.25 >= started_at:
            return path, load_json(path)
    raise RuntimeError(f"Godot produced no live replay result under {result_root}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", help="Path to a Godot 4 executable.")
    parser.add_argument("--project", type=pathlib.Path, default=project_root())
    parser.add_argument(
        "--fixture",
        default="res://docs/evidence/human_micro_holes_20260811/live_edit_replay.json",
    )
    parser.add_argument(
        "--expect-defect",
        action="store_true",
        help="Characterization mode: pass only when the preserved defect reproduces.",
    )
    args = parser.parse_args()

    root = args.project.resolve()
    godot = p2_quality.find_godot(args.godot)
    command = [
        str(godot),
        "--path",
        str(root),
        "--",
        "--human-windowed",
        "--human-material-mode",
        "production_texture_array",
        "--human-artifact-live-replay-fixture",
        args.fixture,
    ]
    print("live replay:", " ".join(command), flush=True)
    started_at = time.time()
    process = subprocess.Popen(
        command,
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    set_three_cpu_affinity(process)
    stdout, stderr = process.communicate()
    if stdout:
        print(stdout, end="")
    if stderr:
        print(stderr, end="", file=sys.stderr)
    try:
        result_path, result = newest_result(root, started_at)
    except RuntimeError as error:
        raise RuntimeError(
            f"{error}; Godot exit_code={process.returncode}"
        ) from error
    mismatch = bool(result.get("targeted_seam_mismatch", False))
    isolated_sky_pixels = int(result.get("settled_isolated_sky_pixels", -1))
    revision_ok = int(result.get("final_world_revision", -1)) == int(
        result.get("expected_final_world_revision", -2)
    )
    if args.expect_defect:
        defect_reproduced = mismatch or isolated_sky_pixels > 0
        if process.returncode != 2 or not defect_reproduced or not revision_ok:
            raise RuntimeError(f"preserved micro-hole defect did not reproduce: {result_path}")
        print(
            f"{PASS_MARKER} mode=expected_defect mismatch={int(mismatch)} "
            f"isolated_sky_pixels={isolated_sky_pixels} result={result_path}"
        )
        return 0
    if process.returncode != 0 or mismatch or isolated_sky_pixels != 0 or not revision_ok:
        raise RuntimeError(f"human micro-hole live replay gate failed: {result_path}")
    print(
        f"{PASS_MARKER} mode=regression mismatch=0 isolated_sky_pixels=0 "
        f"result={result_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
