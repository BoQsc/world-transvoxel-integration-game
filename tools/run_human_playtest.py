#!/usr/bin/env python3
"""Launch the integration game's current human terrain playtest.

This is the single entrypoint for manual terrain inspection. It intentionally
does not run validation gates or visual-capture automation.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
from typing import Any


WINDOWS_STEAM_GODOT = pathlib.Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
)
LATEST_HUMAN_PROFILE = "g22_rolling_hills_cave_roads_2k_256_on_demand"
LATEST_HUMAN_MATERIAL = "production_texture_array"


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[1]


def marker_root(project: pathlib.Path) -> pathlib.Path:
    return project / ".godot" / "world_transvoxel_captures" / "human_artifact_marks"


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

    command = [
        str(godot),
        "--path",
        str(project),
        "--",
        "--p2-profile",
        args.profile,
        "--human-material-mode",
        args.material,
    ]
    if args.windowed:
        command.append("--human-windowed")
    if args.preserve_storage:
        command.append("--human-preserve-storage")
    if args.lighting_preset is not None:
        command.extend(["--human-lighting-preset", str(args.lighting_preset)])
    if args.preset:
        command.extend(["--human-playtest-preset", args.preset])
    if inspect_marker is not None:
        command.extend(["--human-artifact-inspect-marker", str(inspect_marker)])
    return command


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
    args = parser.parse_args(argv)
    if args.latest:
        args.profile = LATEST_HUMAN_PROFILE
        args.material = LATEST_HUMAN_MATERIAL

    command = build_command(args)
    print(" ".join(command), flush=True)
    if args.print_only:
        return 0
    return subprocess.call(command, cwd=pathlib.Path(args.project).resolve())


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
