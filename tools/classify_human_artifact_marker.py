#!/usr/bin/env python3
"""Classify one human artifact marker across terrain material modes.

This tool wraps the existing Godot marker replay path. It does not invent a
separate renderer or topology check; it reuses the integration game's marker
capture code, then summarizes whether the marked pose is a hard terrain
topology/render problem or a material/mesh-quality warning.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import time
from typing import Any

import godot_import_assets
import p2_production_integration_game_quality as p2_quality


DEFAULT_MODES = (
    "sand_triplanar",
    "flat_clean",
    "material_tint",
    "production_atlas",
)
PASS_MARKER = "WT_HUMAN_ARTIFACT_MATERIAL_CLASSIFICATION_PASS"


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[1]


def marker_root(project: pathlib.Path) -> pathlib.Path:
    return project / ".godot" / "world_transvoxel_captures" / "human_artifact_marks"


def classification_root(project: pathlib.Path) -> pathlib.Path:
    return project / ".godot" / "world_transvoxel_captures" / "human_artifact_classifications"


def load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def run_marker_replay(
    godot: pathlib.Path,
    project: pathlib.Path,
    marker: pathlib.Path,
    profile: str,
    material_mode: str,
) -> tuple[pathlib.Path, dict[str, Any]]:
    root = marker_root(project)
    root.mkdir(parents=True, exist_ok=True)
    start_time = time.time()
    cmd = [
        str(godot),
        "--path",
        str(project),
        "--",
        "--p2-profile",
        profile,
        "--human-windowed",
        "--human-material-mode",
        material_mode,
        "--human-artifact-replay-marker",
        str(marker),
    ]
    print("replaying:", " ".join(cmd), flush=True)
    completed = subprocess.run(cmd, cwd=project, text=True, capture_output=True)
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        raise subprocess.CalledProcessError(completed.returncode, cmd)
    return latest_replay_marker_for_mode(root, material_mode, start_time)


def latest_replay_marker_for_mode(
    root: pathlib.Path,
    material_mode: str,
    start_time: float,
) -> tuple[pathlib.Path, dict[str, Any]]:
    candidates = sorted(root.glob("*.json"), key=lambda path: path.stat().st_mtime, reverse=True)
    for path in candidates:
        if path.stat().st_mtime + 0.25 < start_time:
            continue
        try:
            data = load_json(path)
        except json.JSONDecodeError:
            continue
        presentation = data.get("presentation", {})
        if data.get("source") == "replay" and presentation.get("human_material_mode") == material_mode:
            return path, data
    raise RuntimeError(f"no replay marker found for material mode {material_mode!r}")


def summarize_marker(path: pathlib.Path, data: dict[str, Any]) -> dict[str, Any]:
    screen = data.get("screen_sky_pixels", {})
    presentation = data.get("presentation", {})
    screenshot_path = pathlib.Path(str(data.get("screenshot_path", "")))
    hard_problem_count = int(data.get("problematic_probe_count", 0)) + int(
        data.get("problematic_precise_probe_count", 0)
    )
    return {
        "json_path": str(path),
        "screenshot_path": str(screenshot_path),
        "screenshot_exists": screenshot_path.is_file(),
        "source": data.get("source"),
        "profile": data.get("profile"),
        "material_mode": presentation.get("human_material_mode"),
        "visual_mode": presentation.get("visual_mode"),
        "clean_texture_enabled": bool(presentation.get("clean_texture_enabled", False)),
        "clean_triplanar_enabled": bool(presentation.get("clean_triplanar_enabled", False)),
        "hard_problem_count": hard_problem_count,
        "problematic_probe_count": int(data.get("problematic_probe_count", 0)),
        "problematic_precise_probe_count": int(data.get("problematic_precise_probe_count", 0)),
        "mesh_quality_warning_precise_probe_count": int(
            data.get("mesh_quality_warning_precise_probe_count", 0)
        ),
        "center_sky_pixels": int(screen.get("center_sky_pixels", 0)),
        "crosshair_sky_pixels": int(screen.get("crosshair_sky_pixels", 0)),
        "isolated_center_sky_pixels": int(screen.get("isolated_center_sky_pixels", 0)),
        "isolated_crosshair_sky_pixels": int(screen.get("isolated_crosshair_sky_pixels", 0)),
        "whole_sky_pixels": int(screen.get("whole_sky_pixels", 0)),
    }


def classify(results: list[dict[str, Any]]) -> dict[str, Any]:
    hard_modes = [result["material_mode"] for result in results if int(result["hard_problem_count"]) > 0]
    missing_screenshots = [
        result["material_mode"] for result in results if not bool(result["screenshot_exists"])
    ]
    warning_count = sum(int(result["mesh_quality_warning_precise_probe_count"]) for result in results)
    textured_warnings = [
        result["material_mode"]
        for result in results
        if bool(result["clean_texture_enabled"])
        and int(result["mesh_quality_warning_precise_probe_count"]) > 0
    ]
    flat_result = next((result for result in results if result["material_mode"] == "flat_clean"), {})
    classification = "open_gap_free"
    if hard_modes:
        classification = "hard_topology_or_render_problem"
    elif warning_count > 0:
        classification = "open_gap_free_with_mesh_quality_warning"
    if textured_warnings and int(flat_result.get("hard_problem_count", 0)) == 0:
        classification = "material_texture_over_open_gap_free_geometry_with_quality_warning"
    return {
        "classification": classification,
        "hard_problem_modes": hard_modes,
        "missing_screenshot_modes": missing_screenshots,
        "mesh_quality_warning_total": warning_count,
        "textured_warning_modes": textured_warnings,
        "passed": not hard_modes and not missing_screenshots,
    }


def write_summary(
    project: pathlib.Path,
    source_marker: pathlib.Path,
    profile: str,
    results: list[dict[str, Any]],
    classification: dict[str, Any],
) -> pathlib.Path:
    output_dir = classification_root(project)
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"{source_marker.stem}_material_classification.json"
    payload = {
        "source_marker": str(source_marker),
        "profile": profile,
        "modes": [result["material_mode"] for result in results],
        "result_count": len(results),
        "results": results,
        **classification,
    }
    output_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return output_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", help="Path to a Godot 4 executable.")
    parser.add_argument("--project", default=str(repo_root()), help="Integration game project root.")
    parser.add_argument("--marker", required=True, help="Human artifact marker JSON to replay.")
    parser.add_argument(
        "--profile",
        default=p2_quality.DEEP_PROFILE,
        choices=p2_quality.PROFILE_CHOICES,
        help="Terrain profile used for marker replay.",
    )
    parser.add_argument(
        "--mode",
        action="append",
        choices=DEFAULT_MODES,
        help="Material mode to replay. Defaults to all diagnostic modes.",
    )
    parser.add_argument(
        "--skip-import",
        action="store_true",
        help="Skip Godot import-cache refresh before replay.",
    )
    args = parser.parse_args()

    project = pathlib.Path(args.project).resolve()
    marker = pathlib.Path(args.marker).resolve()
    if not marker.is_file():
        raise FileNotFoundError(f"marker does not exist: {marker}")
    godot = p2_quality.find_godot(args.godot)
    if not args.skip_import:
        godot_import_assets.run_godot_import(godot, project)
        godot_import_assets.verify_imports(project)
        print(
            "WT_GODOT_IMPORT_ASSETS_PASS required_imports=%d"
            % len(godot_import_assets.REQUIRED_TEXTURE_IMPORTS)
        )

    modes = tuple(args.mode) if args.mode else DEFAULT_MODES
    results: list[dict[str, Any]] = []
    for mode in modes:
        path, data = run_marker_replay(godot, project, marker, args.profile, mode)
        results.append(summarize_marker(path, data))

    classification = classify(results)
    summary_path = write_summary(project, marker, args.profile, results, classification)
    if not bool(classification["passed"]):
        raise RuntimeError(f"human artifact material classification failed: {summary_path}")
    print(
        "%s marker=%s profile=%s modes=%d classification=%s mesh_quality_warnings=%d summary=%s"
        % (
            PASS_MARKER,
            marker.name,
            args.profile,
            len(results),
            classification["classification"],
            int(classification["mesh_quality_warning_total"]),
            summary_path,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
