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


def optional_float(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def optional_int(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def minimum_present(values: list[float | None]) -> float | None:
    present = [value for value in values if value is not None]
    if not present:
        return None
    return min(present)


def mesh_quality_warning_summary(data: dict[str, Any]) -> dict[str, Any]:
    warnings = data.get("mesh_quality_warning_precise_probes", [])
    if not isinstance(warnings, list):
        warnings = []

    labels: set[str] = set()
    radii: set[float] = set()
    owners: set[str] = set()
    lods: set[int] = set()
    minimum_areas: list[float | None] = []
    minimum_edges: list[float | None] = []
    zero_area_triangle_total = 0
    zero_area_probe_count = 0
    thin_triangle_warning_total = 0
    normal_agreement_positive_total = 0

    for warning in warnings:
        if not isinstance(warning, dict):
            continue
        label = warning.get("label")
        if label:
            labels.add(str(label))
        radius = optional_float(warning.get("radius"))
        if radius is not None:
            radii.add(radius)
        area = optional_float(warning.get("minimum_area_squared"))
        if area is not None and area > 0.0:
            minimum_areas.append(area)
        edge = optional_float(warning.get("minimum_edge_length_squared"))
        if edge is not None and edge > 0.0:
            minimum_edges.append(edge)
        zero_area_triangles = optional_int(warning.get("zero_area_triangles"))
        zero_area_triangle_total += zero_area_triangles
        if zero_area_triangles > 0:
            zero_area_probe_count += 1
        thin_triangle_warning_total += optional_int(
            warning.get("thin_triangle_warning_triangles")
        )
        normal_agreement_positive_total += optional_int(
            warning.get("normal_agreement_positive")
        )
        for example in warning.get("thin_triangle_warning_examples", []):
            if not isinstance(example, dict):
                continue
            owner = example.get("owner")
            if owner:
                owners.add(str(owner))
            lod = optional_int(example.get("lod"))
            if lod >= 0:
                lods.add(lod)

    return {
        "mesh_quality_warning_labels": sorted(labels),
        "mesh_quality_warning_radii": sorted(radii),
        "mesh_quality_warning_thin_triangle_owners": sorted(owners),
        "mesh_quality_warning_thin_triangle_lods": sorted(lods),
        "minimum_mesh_quality_warning_area_squared": minimum_present(minimum_areas),
        "minimum_mesh_quality_warning_edge_length_squared": minimum_present(minimum_edges),
        "mesh_quality_warning_zero_area_triangle_total": zero_area_triangle_total,
        "mesh_quality_warning_zero_area_probe_count": zero_area_probe_count,
        "mesh_quality_warning_thin_triangle_total": thin_triangle_warning_total,
        "mesh_quality_warning_normal_agreement_positive_total": normal_agreement_positive_total,
    }


def summarize_marker(path: pathlib.Path, data: dict[str, Any]) -> dict[str, Any]:
    screen = data.get("screen_sky_pixels", {})
    presentation = data.get("presentation", {})
    screenshot_path = pathlib.Path(str(data.get("screenshot_path", "")))
    hard_problem_count = int(data.get("problematic_probe_count", 0)) + int(
        data.get("problematic_precise_probe_count", 0)
    )
    warning_summary = mesh_quality_warning_summary(data)
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
        **warning_summary,
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
    warning_area_minimum = minimum_present(
        [
            optional_float(result.get("minimum_mesh_quality_warning_area_squared"))
            for result in results
        ]
    )
    warning_edge_minimum = minimum_present(
        [
            optional_float(result.get("minimum_mesh_quality_warning_edge_length_squared"))
            for result in results
        ]
    )
    warning_zero_area_total = sum(
        optional_int(result.get("mesh_quality_warning_zero_area_triangle_total"))
        for result in results
    )
    warning_thin_triangle_total = sum(
        optional_int(result.get("mesh_quality_warning_thin_triangle_total"))
        for result in results
    )
    warning_normal_agreement_positive_total = sum(
        optional_int(result.get("mesh_quality_warning_normal_agreement_positive_total"))
        for result in results
    )
    warning_labels = sorted(
        {
            label
            for result in results
            for label in result.get("mesh_quality_warning_labels", [])
        }
    )
    warning_radii = sorted(
        {
            optional_float(radius)
            for result in results
            for radius in result.get("mesh_quality_warning_radii", [])
            if optional_float(radius) is not None
        }
    )
    warning_thin_triangle_owners = sorted(
        {
            owner
            for result in results
            for owner in result.get("mesh_quality_warning_thin_triangle_owners", [])
        }
    )
    warning_thin_triangle_lods = sorted(
        {
            optional_int(lod)
            for result in results
            for lod in result.get("mesh_quality_warning_thin_triangle_lods", [])
            if optional_int(lod) >= 0
        }
    )
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
        "mesh_quality_warning_precise_probe_count": warning_count,
        "mesh_quality_warning_labels": warning_labels,
        "mesh_quality_warning_radii": warning_radii,
        "minimum_mesh_quality_warning_area_squared": warning_area_minimum,
        "minimum_mesh_quality_warning_edge_length_squared": warning_edge_minimum,
        "mesh_quality_warning_zero_area_triangle_total": warning_zero_area_total,
        "mesh_quality_warning_thin_triangle_total": warning_thin_triangle_total,
        "mesh_quality_warning_normal_agreement_positive_total": warning_normal_agreement_positive_total,
        "mesh_quality_warning_thin_triangle_owners": warning_thin_triangle_owners,
        "mesh_quality_warning_thin_triangle_lods": warning_thin_triangle_lods,
        "textured_warning_modes": textured_warnings,
        "passed": not hard_modes and not missing_screenshots,
    }


def enforce_mesh_quality_gate(
    classification: dict[str, Any],
    max_warnings: int,
) -> None:
    warning_total = int(classification["mesh_quality_warning_total"])
    if warning_total <= max_warnings:
        return
    raise RuntimeError(
        "human artifact mesh-quality gate failed: "
        f"warnings={warning_total} max_allowed={max_warnings}"
    )


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
    parser.add_argument(
        "--fail-on-mesh-quality-warning",
        action="store_true",
        help="Fail if any open-gap-free replay reports mesh-quality warnings.",
    )
    parser.add_argument(
        "--max-mesh-quality-warnings",
        type=int,
        default=0,
        help=(
            "Allowed mesh-quality warning count when "
            "--fail-on-mesh-quality-warning is used."
        ),
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
    if args.fail_on_mesh_quality_warning:
        enforce_mesh_quality_gate(classification, args.max_mesh_quality_warnings)
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
