#!/usr/bin/env python3
"""Run the World Transvoxel production integration game proof.

This wrapper intentionally launches the real Godot project. It does not run
legacy validation scenes and it does not build or rewrite addons.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys


DEFAULT_PROFILES = ("g19_compact_2k_on_demand", "flat_baseline")
WINDOWS_STEAM_GODOT = pathlib.Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
)


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[1]


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


def run_profile(godot: pathlib.Path, project: pathlib.Path, profile: str) -> None:
    cmd = [
        str(godot),
        "--headless",
        "--path",
        str(project),
        "--",
        "--p2-autonomous",
        "--p2-profile",
        profile,
    ]
    print("running:", " ".join(cmd), flush=True)
    completed = subprocess.run(cmd, text=True, capture_output=True)
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        raise subprocess.CalledProcessError(completed.returncode, cmd)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", help="Path to a Godot 4 executable.")
    parser.add_argument(
        "--project",
        default=str(repo_root()),
        help="Path to the integration game project directory.",
    )
    parser.add_argument(
        "--profile",
        action="append",
        choices=DEFAULT_PROFILES,
        help="Profile to run. May be passed more than once. Defaults to both.",
    )
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Accepted for compatibility; this proof never builds.",
    )
    args = parser.parse_args(argv)

    godot = find_godot(args.godot)
    project = pathlib.Path(args.project).resolve()
    profiles = tuple(args.profile) if args.profile else DEFAULT_PROFILES
    for profile in profiles:
        run_profile(godot, project, profile)
    print("WT_PRODUCTION_INTEGRATION_GAME_QUALITY_PASS profiles=%d" % len(profiles))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
