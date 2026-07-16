#!/usr/bin/env python3
"""Replay exact human-marked positions as an ordered inspection path.

Human workflow:
1. Launch the playtest.
2. Press Tilde+P at each exact point that shows a terrain/LOD/material issue.
3. Run this script. It replays those marked camera/player poses in order and
   captures each point twice: immediately after movement, then after a settle wait.

This script is intentionally narrow. It does not run broad validation gates and
does not invent synthetic camera positions.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import time
from typing import Any

import run_human_playtest


DEFAULT_PROFILE = "g21_rolling_hills_cave_2k_256_on_demand"
DEFAULT_MATERIAL = "production_texture_array"
PASS_MARKER = "WT_HUMAN_ARTIFACT_MARKER_SEQUENCE_PASS"
PATH_POINT_SOURCE = "path_point"


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[1]


def marker_root(project: pathlib.Path) -> pathlib.Path:
    return project / ".godot" / "world_transvoxel_captures" / "human_artifact_marks"


def sequence_root(project: pathlib.Path) -> pathlib.Path:
    return project / ".godot" / "world_transvoxel_captures" / "human_artifact_marker_sequences"


def load_json(path: pathlib.Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def path_point_markers(project: pathlib.Path) -> list[pathlib.Path]:
    root = marker_root(project)
    candidates = sorted(root.glob("*.json"), key=lambda path: path.stat().st_mtime)
    result: list[pathlib.Path] = []
    for path in candidates:
        data = load_json(path)
        if data and data.get("source") == PATH_POINT_SOURCE:
            result.append(path)
    return result


def selected_markers(project: pathlib.Path, marker_args: list[str], latest: int) -> list[pathlib.Path]:
    if marker_args:
        markers = [pathlib.Path(value).resolve() for value in marker_args]
        missing = [path for path in markers if not path.is_file()]
        if missing:
            raise FileNotFoundError(f"marker JSON does not exist: {missing[0]}")
        return markers
    markers = path_point_markers(project)
    if not markers:
        raise FileNotFoundError(
            f"no path-point marker JSON files found under {marker_root(project)}; "
            "launch the playtest and press Tilde+P at each test position"
        )
    count = max(1, latest)
    return markers[-count:]


def infer_profile(markers: list[pathlib.Path], explicit_profile: str | None) -> str:
    if explicit_profile:
        return explicit_profile
    profiles: list[str] = []
    for marker in markers:
        data = load_json(marker)
        profile = str(data.get("profile", "")) if data else ""
        if profile and profile not in profiles:
            profiles.append(profile)
    if len(profiles) == 1:
        return profiles[0]
    return DEFAULT_PROFILE


def write_sequence_file(
    project: pathlib.Path,
    markers: list[pathlib.Path],
    wait_frames: int,
) -> pathlib.Path:
    root = sequence_root(project)
    root.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%S")
    path = root / f"{stamp}_marker_sequence.json"
    payload = {
        "created_by": "tools/inspect_human_marker_path.py",
        "wait_frames": wait_frames,
        "markers": [str(marker) for marker in markers],
    }
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return path


def build_command(args: argparse.Namespace, sequence_file: pathlib.Path, profile: str) -> list[str]:
    godot = run_human_playtest.find_godot(args.godot)
    return [
        str(godot),
        "--path",
        str(args.project),
        "--",
        "--p2-profile",
        profile,
        "--human-windowed",
        "--human-material-mode",
        args.material,
        "--human-artifact-marker-sequence-file",
        str(sequence_file),
        "--human-artifact-marker-sequence-wait-frames",
        str(args.wait_frames),
    ]


def latest_sequence_result(project: pathlib.Path, start_time: float) -> pathlib.Path | None:
    root = marker_root(project) / "sequences"
    if not root.exists():
        return None
    candidates = sorted(root.glob("*_sequence_result.json"), key=lambda path: path.stat().st_mtime, reverse=True)
    for path in candidates:
        if path.stat().st_mtime + 0.25 >= start_time:
            return path
    return None


def result_path_from_output(output: str) -> str:
    match = re.search(rf"{PASS_MARKER}\s+(\{{.*\}})", output)
    if not match:
        return ""
    try:
        data = json.loads(match.group(1))
    except ValueError:
        return ""
    return str(data.get("result_path", ""))


def run_sequence(args: argparse.Namespace, command: list[str]) -> pathlib.Path | None:
    start_time = time.time()
    print(" ".join(command), flush=True)
    if args.print_only:
        return None
    completed = subprocess.run(
        command,
        cwd=args.project,
        text=True,
        capture_output=True,
    )
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        raise subprocess.CalledProcessError(completed.returncode, command)
    output_path = result_path_from_output(completed.stdout)
    if output_path:
        return pathlib.Path(output_path)
    return latest_sequence_result(args.project, start_time)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Replay exact Tilde+P path-point marker positions as a focused inspection path."
    )
    parser.add_argument("--godot", help="Path to a Godot 4 executable.")
    parser.add_argument(
        "--project",
        type=pathlib.Path,
        default=repo_root(),
        help="Path to the integration game project directory.",
    )
    parser.add_argument(
        "--profile",
        help="Terrain profile. Defaults to the marker profile when all markers agree.",
    )
    parser.add_argument(
        "--material",
        default=DEFAULT_MATERIAL,
        help="Human material mode to use for replay.",
    )
    parser.add_argument(
        "--marker",
        action="append",
        default=[],
        help="Specific marker JSON path. Repeat to build an ordered path.",
    )
    parser.add_argument(
        "--latest",
        type=int,
        default=3,
        help="Use the latest N human markers when --marker is not supplied.",
    )
    parser.add_argument(
        "--wait-frames",
        type=int,
        default=180,
        help="Frames to wait before the settled capture at each marker.",
    )
    parser.add_argument(
        "--print-only",
        action="store_true",
        help="Print the Godot command without launching it.",
    )
    args = parser.parse_args(argv)
    args.project = args.project.resolve()
    if not (args.project / "project.godot").is_file():
        raise FileNotFoundError(f"project.godot not found under {args.project}")

    markers = selected_markers(args.project, args.marker, args.latest)
    profile = infer_profile(markers, args.profile)
    sequence_file = write_sequence_file(args.project, markers, args.wait_frames)
    command = build_command(args, sequence_file, profile)
    result = run_sequence(args, command)
    print(f"sequence_file={sequence_file}")
    print("markers=")
    for marker in markers:
        print(f"  {marker}")
    if result is not None:
        print(f"result={result}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
