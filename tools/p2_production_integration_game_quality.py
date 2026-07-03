#!/usr/bin/env python3
"""Run the World Transvoxel production integration game proof.

This wrapper intentionally launches the real Godot project. It does not run
legacy validation scenes and it does not build or rewrite addons.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys


DEFAULT_PROFILES = ("g19_compact_2k_on_demand", "flat_baseline")
VISUAL_CAPTURE_PROFILE = "g19_compact_2k_on_demand"
DEFAULT_VISUAL_MODES = ("ground", "high_oblique", "topdown")
VISUAL_SUMMARY_PREFIX = "WT_HUMAN_VISUAL_CAPTURE_SUMMARY "
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


def run_visual_capture(
    godot: pathlib.Path,
    project: pathlib.Path,
    mode: str,
    output_dir: pathlib.Path,
    wait_frames: int,
) -> pathlib.Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    capture_path = output_dir / f"terrain_1_0_{mode}.png"
    cmd = [
        str(godot),
        "--path",
        str(project),
        "--",
        "--p2-profile",
        VISUAL_CAPTURE_PROFILE,
        "--human-visual-capture",
        str(capture_path),
        "--human-visual-capture-mode",
        mode,
        "--human-visual-capture-wait-frames",
        str(wait_frames),
    ]
    print("capturing:", " ".join(cmd), flush=True)
    completed = subprocess.run(cmd, text=True, capture_output=True)
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        raise subprocess.CalledProcessError(completed.returncode, cmd)

    summary = parse_visual_summary(completed.stdout, mode)
    validate_visual_summary(summary, capture_path)
    return capture_path


def parse_visual_summary(stdout: str, mode: str) -> dict[str, object]:
    for line in stdout.splitlines():
        if line.startswith(VISUAL_SUMMARY_PREFIX):
            payload = line[len(VISUAL_SUMMARY_PREFIX) :].strip()
            summary = json.loads(payload)
            if summary.get("mode") != mode:
                raise RuntimeError(
                    f"visual capture summary mode mismatch: {summary!r}"
                )
            return summary
    raise RuntimeError(f"visual capture summary missing for mode {mode}")


def validate_visual_summary(
    summary: dict[str, object],
    capture_path: pathlib.Path,
) -> None:
    if not capture_path.is_file() or capture_path.stat().st_size < 10_000:
        raise RuntimeError(f"visual capture was not written: {capture_path}")
    checks = {
        "profile": VISUAL_CAPTURE_PROFILE,
        "viewer_radius_chunks": 8,
        "viewer_maximum_lod": 3,
        "runtime_lod_refinement_radius_chunks": 1,
        "full_map_enabled": False,
        "native_render_material_override": True,
        "clean_material_variation_enabled": False,
    }
    for key, expected in checks.items():
        if summary.get(key) != expected:
            raise RuntimeError(
                f"visual capture field {key} expected {expected!r}, "
                f"got {summary.get(key)!r}: {summary!r}"
            )
    minimums = {
        "runtime_demand_capacity_per_viewer": 8192,
        "active_chunk_records": 64,
        "render_resources": 32,
        "materialized_instances": 32,
    }
    for key, minimum in minimums.items():
        value = int(summary.get(key, 0))
        if value < minimum:
            raise RuntimeError(
                f"visual capture field {key} expected >= {minimum}, "
                f"got {value}: {summary!r}"
            )


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
    parser.add_argument(
        "--visual-smoke",
        action="store_true",
        help="Also capture the real human-play profile from standard inspection views.",
    )
    parser.add_argument(
        "--visual-mode",
        action="append",
        choices=DEFAULT_VISUAL_MODES,
        help="Visual capture mode to run. May be passed more than once.",
    )
    parser.add_argument(
        "--visual-output-dir",
        default=None,
        help="Directory for visual-smoke PNG captures.",
    )
    parser.add_argument(
        "--visual-wait-frames",
        type=int,
        default=180,
        help="Frames to wait after moving the capture camera.",
    )
    args = parser.parse_args(argv)

    godot = find_godot(args.godot)
    project = pathlib.Path(args.project).resolve()
    profiles = tuple(args.profile) if args.profile else DEFAULT_PROFILES
    for profile in profiles:
        run_profile(godot, project, profile)
    print("WT_PRODUCTION_INTEGRATION_GAME_QUALITY_PASS profiles=%d" % len(profiles))
    if args.visual_smoke:
        modes = tuple(args.visual_mode) if args.visual_mode else DEFAULT_VISUAL_MODES
        output_dir = pathlib.Path(args.visual_output_dir).resolve() if args.visual_output_dir else (
            project / "build" / "captures" / "terrain_1_0_visual_smoke"
        )
        captures = [
            run_visual_capture(
                godot,
                project,
                mode,
                output_dir,
                args.visual_wait_frames,
            )
            for mode in modes
        ]
        print(
            "WT_PRODUCTION_INTEGRATION_GAME_VISUAL_SMOKE_PASS captures=%d dir=%s"
            % (len(captures), output_dir)
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
