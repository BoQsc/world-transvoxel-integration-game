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

import godot_import_assets


DEFAULT_PROFILES = ("g19_compact_2k_on_demand", "flat_baseline")
VISUAL_CAPTURE_PROFILE = "g19_compact_2k_on_demand"
LOD_MOVEMENT_GATE_PROFILES = ("g19_compact_2k_on_demand", "flat_baseline")
DEFAULT_VISUAL_MODES = ("ground", "high_oblique", "topdown", "watertight_boundary_near")
VISUAL_MODE_CHOICES = DEFAULT_VISUAL_MODES + (
    "small_edit_near",
    "small_edit_mid",
    "small_edit_far",
    "edit_near",
    "edit_far",
    "edit_aerial",
    "edit_during_load_oracle",
    "edit_lod_movement_gate",
)
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


def run_visual_capture_summary(
    godot: pathlib.Path,
    project: pathlib.Path,
    mode: str,
    output_dir: pathlib.Path,
    wait_frames: int,
    profile: str = VISUAL_CAPTURE_PROFILE,
    capture_stem: str | None = None,
    extra_args: tuple[str, ...] = (),
) -> tuple[pathlib.Path, dict[str, object]]:
    output_dir.mkdir(parents=True, exist_ok=True)
    if capture_stem is None:
        capture_stem = f"terrain_1_0_{mode}"
    capture_path = output_dir / f"{capture_stem}.png"
    cmd = [
        str(godot),
        "--path",
        str(project),
        "--",
        "--p2-profile",
        profile,
        "--human-visual-capture",
        str(capture_path),
        "--human-visual-capture-mode",
        mode,
        "--human-visual-capture-wait-frames",
        str(wait_frames),
    ]
    cmd.extend(extra_args)
    print("capturing:", " ".join(cmd), flush=True)
    completed = subprocess.run(cmd, text=True, capture_output=True)
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        raise subprocess.CalledProcessError(completed.returncode, cmd)

    summary = parse_visual_summary(completed.stdout, mode)
    validate_visual_summary(summary, capture_path, profile)
    return capture_path, summary


def run_visual_capture(
    godot: pathlib.Path,
    project: pathlib.Path,
    mode: str,
    output_dir: pathlib.Path,
    wait_frames: int,
    profile: str = VISUAL_CAPTURE_PROFILE,
    capture_stem: str | None = None,
) -> pathlib.Path:
    capture_path, _summary = run_visual_capture_summary(
        godot,
        project,
        mode,
        output_dir,
        wait_frames,
        profile,
        capture_stem,
    )
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
    expected_profile: str = VISUAL_CAPTURE_PROFILE,
) -> None:
    if not capture_path.is_file() or capture_path.stat().st_size < 10_000:
        raise RuntimeError(f"visual capture was not written: {capture_path}")
    checks = {
        "profile": expected_profile,
        "viewer_radius_chunks": 8,
        "viewer_maximum_lod": 3,
        "runtime_lod_refinement_radius_chunks": 1,
        "runtime_render_apply_budget": 8,
        "runtime_collision_apply_budget": 8,
        "runtime_streaming_burst_render_apply_budget": 128,
        "runtime_streaming_burst_collision_apply_budget": 128,
        "runtime_streaming_burst_frames": 30,
        "runtime_collision_activation_distance": 192.0,
        "runtime_collision_deactivation_distance": 256.0,
        "edit_failure_count": 0,
        "full_map_enabled": False,
        "native_render_material_override": True,
        "clean_material_variation_enabled": False,
        "clean_roughness": 1.0,
        "clean_specular": 0.0,
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
    watertightness = summary.get("watertightness")
    if not isinstance(watertightness, dict):
        raise RuntimeError(f"visual capture missing watertightness summary: {summary!r}")
    if watertightness.get("enabled"):
        mode = str(summary.get("mode", ""))
        allow_safe_near_zero_slivers = mode == "edit_during_load_oracle"
        boundary_edges = int(watertightness.get("boundary_edges", -1))
        chunk_face_boundary_edges = int(watertightness.get("chunk_face_boundary_edges", 0))
        interior_boundary_edges = int(
            watertightness.get("interior_boundary_edges", boundary_edges)
        )
        unknown_boundary_edges = int(watertightness.get("unknown_boundary_edges", 0))
        if interior_boundary_edges != 0 or unknown_boundary_edges != 0:
            raise RuntimeError(f"watertightness probe found open rendered edges: {watertightness!r}")
        if boundary_edges != chunk_face_boundary_edges:
            raise RuntimeError(f"watertightness probe found unexpected boundary edges: {watertightness!r}")
        if int(watertightness.get("nonmanifold_interior_edges", 0)) != 0:
            raise RuntimeError(f"watertightness probe found interior nonmanifold edges: {watertightness!r}")
        if int(watertightness.get("nonmanifold_unknown_edges", 0)) != 0:
            raise RuntimeError(f"watertightness probe found unknown nonmanifold edges: {watertightness!r}")
        if (
            int(watertightness.get("zero_area_interior_triangles", 0)) != 0
            and not allow_safe_near_zero_slivers
        ):
            raise RuntimeError(f"watertightness probe found interior zero-area triangles: {watertightness!r}")
        if int(watertightness.get("zero_area_unknown_triangles", 0)) != 0:
            raise RuntimeError(f"watertightness probe found unknown zero-area triangles: {watertightness!r}")
        if int(watertightness.get("repeated_point_key_interior_triangles", 0)) != 0:
            raise RuntimeError(f"watertightness probe found interior repeated-point triangles: {watertightness!r}")
        if int(watertightness.get("repeated_point_key_unknown_triangles", 0)) != 0:
            raise RuntimeError(f"watertightness probe found unknown repeated-point triangles: {watertightness!r}")
        if int(watertightness.get("zero_edge_triangles", 0)) != 0:
            raise RuntimeError(f"watertightness probe found zero-edge triangles: {watertightness!r}")
        if watertightness.get("winding_mixed") is True:
            raise RuntimeError(f"watertightness probe found mixed winding: {watertightness!r}")
        if int(watertightness.get("triangles_in_region", 0)) <= 0:
            raise RuntimeError(f"watertightness probe did not inspect rendered triangles: {watertightness!r}")


def run_lod_movement_gate(
    godot: pathlib.Path,
    project: pathlib.Path,
    profile: str,
    output_dir: pathlib.Path,
    wait_frames: int,
) -> pathlib.Path:
    capture, summary = run_visual_capture_summary(
        godot,
        project,
        "edit_lod_movement_gate",
        output_dir,
        wait_frames,
        profile=profile,
        capture_stem=f"terrain_1_0_{profile}_edit_lod_movement_gate",
        extra_args=("--p2-lod-movement-gap-only-probe",),
    )
    validate_lod_movement_summary(summary, profile)
    return capture


def run_edit_during_load_gate(
    godot: pathlib.Path,
    project: pathlib.Path,
    profile: str,
    output_dir: pathlib.Path,
    wait_frames: int,
) -> pathlib.Path:
    capture, summary = run_visual_capture_summary(
        godot,
        project,
        "edit_during_load_oracle",
        output_dir,
        wait_frames,
        profile=profile,
        capture_stem=f"terrain_1_0_{profile}_edit_during_load_oracle",
    )
    validate_edit_during_load_summary(summary, profile)
    return capture


def validate_edit_during_load_summary(
    summary: dict[str, object],
    profile: str,
) -> None:
    if summary.get("profile") != profile:
        raise RuntimeError(f"edit-during-load profile mismatch: {summary!r}")
    if summary.get("mode") != "edit_during_load_oracle":
        raise RuntimeError(f"edit-during-load mode mismatch: {summary!r}")
    oracle = summary.get("edit_during_load")
    if not isinstance(oracle, dict):
        raise RuntimeError(f"edit-during-load summary missing: {summary!r}")
    if oracle.get("enabled") is not True or oracle.get("ok") is not True:
        raise RuntimeError(f"edit-during-load oracle failed: {oracle!r}")
    if int(oracle.get("operation_count", 0)) < 64:
        raise RuntimeError(f"edit-during-load did not exercise enough edits: {oracle!r}")
    if int(oracle.get("streaming_batches", 0)) <= 0:
        raise RuntimeError(f"edit-during-load submitted no edit batch while streaming: {oracle!r}")
    if int(oracle.get("after_commit_sample_count", 0)) <= 0:
        raise RuntimeError(f"edit-during-load sampled no authoritative points: {oracle!r}")
    if int(oracle.get("after_commit_air_sample_count", 0)) <= 0:
        raise RuntimeError(f"edit-during-load sampled no carved air: {oracle!r}")
    for key in ("after_load_persistence", "after_reload_persistence"):
        persistence = oracle.get(key)
        if not isinstance(persistence, dict):
            raise RuntimeError(f"edit-during-load {key} missing: {oracle!r}")
        if persistence.get("ok") is not True:
            raise RuntimeError(f"edit-during-load {key} failed: {persistence!r}")
        if int(persistence.get("density_mismatches", -1)) != 0:
            raise RuntimeError(f"edit-during-load density mismatch in {key}: {persistence!r}")
        if int(persistence.get("material_mismatches", -1)) != 0:
            raise RuntimeError(f"edit-during-load material mismatch in {key}: {persistence!r}")
        if int(persistence.get("missing_after", -1)) != 0:
            raise RuntimeError(f"edit-during-load missing samples in {key}: {persistence!r}")
        if float(persistence.get("max_abs_density_delta", -1.0)) != 0.0:
            raise RuntimeError(f"edit-during-load density delta in {key}: {persistence!r}")
    print(
        "WT_EDIT_DURING_LOAD_GATE_PROFILE_PASS profile=%s operations=%d streaming_batches=%d"
        % (
            profile,
            int(oracle.get("operation_count", 0)),
            int(oracle.get("streaming_batches", 0)),
        )
    )


def validate_lod_movement_summary(
    summary: dict[str, object],
    profile: str,
) -> None:
    if summary.get("profile") != profile:
        raise RuntimeError(f"LOD movement profile mismatch: {summary!r}")
    if summary.get("mode") != "edit_lod_movement_gate":
        raise RuntimeError(f"LOD movement mode mismatch: {summary!r}")
    lod_movement = summary.get("lod_movement")
    if not isinstance(lod_movement, dict):
        raise RuntimeError(f"LOD movement summary missing: {summary!r}")
    if lod_movement.get("enabled") is not True or lod_movement.get("ok") is not True:
        raise RuntimeError(f"LOD movement gate failed: {lod_movement!r}")
    if int(lod_movement.get("direct_operation_count", 0)) < 128:
        raise RuntimeError(f"LOD movement direct edits were not exercised: {lod_movement!r}")
    if int(lod_movement.get("interaction_operation_count", 0)) < 4:
        raise RuntimeError(f"LOD movement player interactions were not exercised: {lod_movement!r}")
    if int(lod_movement.get("density_mismatches", -1)) != 0:
        raise RuntimeError(f"LOD movement changed authoritative densities: {lod_movement!r}")
    if int(lod_movement.get("material_mismatches", -1)) != 0:
        raise RuntimeError(f"LOD movement changed authoritative materials: {lod_movement!r}")
    if float(lod_movement.get("max_abs_density_delta", -1.0)) != 0.0:
        raise RuntimeError(f"LOD movement density delta was nonzero: {lod_movement!r}")
    expected_labels = {"close", "mid", "far", "return_close"}
    persistence_labels: set[str] = set()
    for persistence in lod_movement.get("persistence_summaries", []):
        if not isinstance(persistence, dict):
            raise RuntimeError(f"LOD movement persistence summary malformed: {lod_movement!r}")
        label = str(persistence.get("label", ""))
        persistence_labels.add(label)
        if int(persistence.get("density_mismatches", -1)) != 0:
            raise RuntimeError(f"LOD movement persistence density mismatch: {persistence!r}")
        if int(persistence.get("material_mismatches", -1)) != 0:
            raise RuntimeError(f"LOD movement persistence material mismatch: {persistence!r}")
        if float(persistence.get("max_abs_density_delta", -1.0)) != 0.0:
            raise RuntimeError(f"LOD movement persistence density delta: {persistence!r}")
        if int(persistence.get("sample_count", 0)) <= 0:
            raise RuntimeError(f"LOD movement persistence sampled no points: {persistence!r}")
    if persistence_labels != expected_labels:
        raise RuntimeError(
            f"LOD movement persistence labels expected {sorted(expected_labels)}, "
            f"got {sorted(persistence_labels)}: {lod_movement!r}"
        )
    transition_labels: set[str] = set()
    transient_failures = 0
    for transition in lod_movement.get("transition_summaries", []):
        if not isinstance(transition, dict):
            raise RuntimeError(f"LOD movement transition summary malformed: {lod_movement!r}")
        label = str(transition.get("label", ""))
        transition_labels.add(label)
        if transition.get("ok") is not True:
            raise RuntimeError(f"LOD movement transition failed: {transition!r}")
        settled_boundary_edges = int(transition.get("settled_boundary_edges", -1))
        settled_chunk_face_boundary_edges = int(
            transition.get("settled_chunk_face_boundary_edges", 0)
        )
        if int(transition.get("settled_interior_boundary_edges", settled_boundary_edges)) != 0:
            raise RuntimeError(f"LOD movement settled crack detected: {transition!r}")
        if int(transition.get("settled_unknown_boundary_edges", 0)) != 0:
            raise RuntimeError(f"LOD movement settled unknown boundary detected: {transition!r}")
        if settled_boundary_edges != settled_chunk_face_boundary_edges:
            raise RuntimeError(f"LOD movement settled unexpected boundary detected: {transition!r}")
        if int(transition.get("settled_nonmanifold_interior_edges", 0)) != 0:
            raise RuntimeError(f"LOD movement settled interior nonmanifold edges detected: {transition!r}")
        if int(transition.get("settled_nonmanifold_unknown_edges", 0)) != 0:
            raise RuntimeError(f"LOD movement settled unknown nonmanifold edges detected: {transition!r}")
        if int(transition.get("settled_zero_area_interior_triangles", 0)) != 0:
            raise RuntimeError(f"LOD movement settled interior zero-area triangles detected: {transition!r}")
        if int(transition.get("settled_zero_area_unknown_triangles", 0)) != 0:
            raise RuntimeError(f"LOD movement settled unknown zero-area triangles detected: {transition!r}")
        if int(transition.get("settled_repeated_point_key_interior_triangles", 0)) != 0:
            raise RuntimeError(f"LOD movement settled interior repeated-point triangles detected: {transition!r}")
        if int(transition.get("settled_repeated_point_key_unknown_triangles", 0)) != 0:
            raise RuntimeError(f"LOD movement settled unknown repeated-point triangles detected: {transition!r}")
        if int(transition.get("settled_zero_edge_triangles", 0)) != 0:
            raise RuntimeError(f"LOD movement settled zero-edge triangles detected: {transition!r}")
        if int(transition.get("settled_triangles_in_region", 0)) <= 0:
            raise RuntimeError(f"LOD movement transition sampled no triangles: {transition!r}")
        transient_failures += int(transition.get("transient_probe_failure_count", 0))
    if transition_labels != expected_labels:
        raise RuntimeError(
            f"LOD movement transition labels expected {sorted(expected_labels)}, "
            f"got {sorted(transition_labels)}: {lod_movement!r}"
        )
    if transient_failures != 0:
        raise RuntimeError(
            f"LOD movement transient crack probes must stay clean, "
            f"got {transient_failures}: {lod_movement!r}"
        )
    print(
        "WT_LOD_MOVEMENT_GATE_PROFILE_PASS profile=%s operations=%d transient_probe_failures=%d"
        % (
            profile,
            int(lod_movement.get("total_operation_count", 0)),
            transient_failures,
        )
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
        choices=VISUAL_MODE_CHOICES,
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
    parser.add_argument(
        "--lod-movement-gate",
        action="store_true",
        help=(
            "Exercise edits, real interaction input, and close/mid/far movement "
            "to catch permanent edit loss or settled LOD cracks."
        ),
    )
    parser.add_argument(
        "--lod-movement-profile",
        action="append",
        choices=LOD_MOVEMENT_GATE_PROFILES,
        help=(
            "Profile to use for --lod-movement-gate. May be passed more than once. "
            "Defaults to compact and flat profiles."
        ),
    )
    parser.add_argument(
        "--lod-movement-output-dir",
        default=None,
        help="Directory for LOD movement gate PNG captures.",
    )
    parser.add_argument(
        "--edit-during-load-gate",
        action="store_true",
        help=(
            "Exercise edits submitted while the target zone is still streaming, "
            "then verify persistence after load completion and reload."
        ),
    )
    parser.add_argument(
        "--edit-during-load-profile",
        action="append",
        choices=LOD_MOVEMENT_GATE_PROFILES,
        help=(
            "Profile to use for --edit-during-load-gate. May be passed more than once. "
            "Defaults to compact and flat profiles."
        ),
    )
    parser.add_argument(
        "--edit-during-load-output-dir",
        default=None,
        help="Directory for edit-during-load gate PNG captures.",
    )
    args = parser.parse_args(argv)

    godot = find_godot(args.godot)
    project = pathlib.Path(args.project).resolve()
    godot_import_assets.run_godot_import(godot, project)
    godot_import_assets.verify_imports(project)
    print("WT_GODOT_IMPORT_ASSETS_PASS required_imports=%d" % len(godot_import_assets.REQUIRED_TEXTURE_IMPORTS))
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
    if args.lod_movement_gate:
        lod_profiles = (
            tuple(args.lod_movement_profile)
            if args.lod_movement_profile
            else LOD_MOVEMENT_GATE_PROFILES
        )
        output_dir = (
            pathlib.Path(args.lod_movement_output_dir).resolve()
            if args.lod_movement_output_dir
            else project / "build" / "captures" / "terrain_1_0_lod_movement_gate"
        )
        captures = [
            run_lod_movement_gate(
                godot,
                project,
                profile,
                output_dir,
                args.visual_wait_frames,
            )
            for profile in lod_profiles
        ]
        print(
            "WT_PRODUCTION_INTEGRATION_GAME_LOD_MOVEMENT_GATE_PASS captures=%d dir=%s"
            % (len(captures), output_dir)
        )
    if args.edit_during_load_gate:
        edit_during_load_profiles = (
            tuple(args.edit_during_load_profile)
            if args.edit_during_load_profile
            else LOD_MOVEMENT_GATE_PROFILES
        )
        output_dir = (
            pathlib.Path(args.edit_during_load_output_dir).resolve()
            if args.edit_during_load_output_dir
            else project / "build" / "captures" / "terrain_1_0_edit_during_load_gate"
        )
        captures = [
            run_edit_during_load_gate(
                godot,
                project,
                profile,
                output_dir,
                args.visual_wait_frames,
            )
            for profile in edit_during_load_profiles
        ]
        print(
            "WT_PRODUCTION_INTEGRATION_GAME_EDIT_DURING_LOAD_GATE_PASS captures=%d dir=%s"
            % (len(captures), output_dir)
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
