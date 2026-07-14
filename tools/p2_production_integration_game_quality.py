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
TUNNEL_VISUAL_SKY_FREE_LABELS = {
    "g19_compact_2k_on_demand": (
        "descending_crawl_02",
        "descending_crawl_03",
        "descending_crawl_04",
        "descending_crawl_05",
        "descending_crawl_06",
    ),
    "flat_baseline": (
        "descending_crawl_05",
        "descending_crawl_06",
    ),
}
TUNNEL_VISUAL_CENTER_MARGIN_RATIO = 0.20
TUNNEL_VISUAL_WHOLE_IMAGE_SKY_TOLERANCE = 16
DEFAULT_VISUAL_MODES = ("ground", "high_oblique", "topdown", "watertight_boundary_near")
VISUAL_MODE_CHOICES = DEFAULT_VISUAL_MODES + (
    "small_edit_near",
    "small_edit_mid",
    "small_edit_far",
    "edit_near",
    "edit_far",
    "edit_aerial",
    "edit_during_load_oracle",
    "edit_manifold_stress_gate",
    "edit_lod_movement_gate",
    "edit_multisite_lod_gate",
    "edit_tunnel_gate",
    "edit_tunnel_crawl_gate",
    "edit_tunnel_transient_crawl_gate",
    "edit_tunnel_upward_lod_gate",
    "streaming_fly_gap_gate",
    "post_edit_streaming_fly_gap_gate",
)
VISUAL_SUMMARY_PREFIX = "WT_HUMAN_VISUAL_CAPTURE_SUMMARY "
WINDOWS_STEAM_GODOT = pathlib.Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
)
DEFAULT_CAPTURE_ROOT_NAME = "world_transvoxel_captures"


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[1]


def default_capture_dir(project: pathlib.Path, gate_name: str) -> pathlib.Path:
    return project / ".godot" / DEFAULT_CAPTURE_ROOT_NAME / gate_name


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
        "viewer_radius_chunks": 10,
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
    mode = str(summary.get("mode", ""))
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
        acceptance = summary.get("watertightness_acceptance")
        if isinstance(acceptance, dict) and acceptance.get("accepted_for_mode") is not True:
            raise RuntimeError(f"watertightness probe was not accepted for mode: {acceptance!r}")
        allow_safe_near_zero_slivers = mode in {
            "edit_near",
            "edit_during_load_oracle",
            "edit_manifold_stress_gate",
            "edit_tunnel_gate",
            "edit_tunnel_crawl_gate",
            "edit_tunnel_transient_crawl_gate",
        }
        allow_chunk_face_only_orientation = mode in {
            "edit_lod_movement_gate",
            "edit_multisite_lod_gate",
        }
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
        if int(watertightness.get("nonmanifold_edges", -1)) != 0:
            raise RuntimeError(f"watertightness probe found nonmanifold edges: {watertightness!r}")
        orientation_conflicts = int(watertightness.get("orientation_conflict_edges", -1))
        orientation_chunk_face = int(watertightness.get("orientation_conflict_chunk_face_edges", 0))
        orientation_interior = int(watertightness.get("orientation_conflict_interior_edges", 0))
        orientation_unknown = int(watertightness.get("orientation_conflict_unknown_edges", 0))
        if orientation_conflicts != 0:
            if (
                not allow_chunk_face_only_orientation
                or orientation_interior != 0
                or orientation_unknown != 0
                or orientation_conflicts != orientation_chunk_face
            ):
                raise RuntimeError(f"watertightness probe found orientation conflicts: {watertightness!r}")
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
        if int(watertightness.get("triangles_in_region", 0)) <= 0:
            raise RuntimeError(f"watertightness probe did not inspect rendered triangles: {watertightness!r}")
    if summary.get("mode") in {"streaming_fly_gap_gate", "post_edit_streaming_fly_gap_gate"}:
        validate_streaming_fly_summary(summary)


def validate_streaming_fly_summary(summary: dict[str, object]) -> None:
    streaming_fly = summary.get("streaming_fly")
    if not isinstance(streaming_fly, dict):
        raise RuntimeError(f"streaming fly summary missing: {summary!r}")
    if streaming_fly.get("enabled") is not True or streaming_fly.get("ok") is not True:
        raise RuntimeError(f"streaming fly gap gate failed: {streaming_fly!r}")
    if int(streaming_fly.get("sample_count", 0)) < 16:
        raise RuntimeError(f"streaming fly gap gate sampled too little: {streaming_fly!r}")
    if int(streaming_fly.get("failure_count", -1)) != 0:
        raise RuntimeError(f"streaming fly gap gate reported failures: {streaming_fly!r}")
    print(
        "WT_STREAMING_FLY_GAP_GATE_PROFILE_PASS profile=%s samples=%d max_pending=%d max_jobs=%d"
        % (
            summary.get("profile"),
            int(streaming_fly.get("sample_count", 0)),
            int(streaming_fly.get("max_pending_chunk_retirements", 0)),
            int(streaming_fly.get("max_scheduler_queued_jobs", 0)),
        )
    )


def run_lod_movement_gate(
    godot: pathlib.Path,
    project: pathlib.Path,
    profile: str,
    output_dir: pathlib.Path,
    wait_frames: int,
) -> pathlib.Path:
    effective_wait_frames = max(wait_frames, 600)
    capture, summary = run_visual_capture_summary(
        godot,
        project,
        "edit_lod_movement_gate",
        output_dir,
        effective_wait_frames,
        profile=profile,
        capture_stem=f"terrain_1_0_{profile}_edit_lod_movement_gate",
        extra_args=("--p2-lod-movement-gap-only-probe",),
    )
    validate_lod_movement_summary(summary, profile)
    return capture


def run_multisite_lod_gate(
    godot: pathlib.Path,
    project: pathlib.Path,
    profile: str,
    output_dir: pathlib.Path,
    wait_frames: int,
) -> pathlib.Path:
    effective_wait_frames = max(wait_frames, 600)
    capture, summary = run_visual_capture_summary(
        godot,
        project,
        "edit_multisite_lod_gate",
        output_dir,
        effective_wait_frames,
        profile=profile,
        capture_stem=f"terrain_1_0_{profile}_edit_multisite_lod_gate",
        extra_args=("--p2-lod-movement-gap-only-probe",),
    )
    validate_multisite_lod_summary(summary, profile)
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


def run_manifold_stress_gate(
    godot: pathlib.Path,
    project: pathlib.Path,
    profile: str,
    output_dir: pathlib.Path,
    wait_frames: int,
) -> pathlib.Path:
    capture, summary = run_visual_capture_summary(
        godot,
        project,
        "edit_manifold_stress_gate",
        output_dir,
        wait_frames,
        profile=profile,
        capture_stem=f"terrain_1_0_{profile}_edit_manifold_stress_gate",
    )
    validate_manifold_stress_summary(summary, profile)
    return capture


def run_tunnel_gate(
    godot: pathlib.Path,
    project: pathlib.Path,
    profile: str,
    output_dir: pathlib.Path,
    wait_frames: int,
) -> pathlib.Path:
    capture, summary = run_visual_capture_summary(
        godot,
        project,
        "edit_tunnel_gate",
        output_dir,
        wait_frames,
        profile=profile,
        capture_stem=f"terrain_1_0_{profile}_edit_tunnel_gate",
    )
    validate_tunnel_summary(summary, profile)
    return capture


def run_tunnel_crawl_gate(
    godot: pathlib.Path,
    project: pathlib.Path,
    profile: str,
    output_dir: pathlib.Path,
    wait_frames: int,
) -> pathlib.Path:
    capture_stem = f"terrain_1_0_{profile}_edit_tunnel_crawl_gate"
    capture, summary = run_visual_capture_summary(
        godot,
        project,
        "edit_tunnel_crawl_gate",
        output_dir,
        wait_frames,
        profile=profile,
        capture_stem=capture_stem,
    )
    validate_tunnel_crawl_summary(summary, profile)
    validate_tunnel_step_captures(
        output_dir,
        f"{capture_stem}_step_*.png",
        "tunnel crawl",
    )
    return capture


def run_tunnel_upward_lod_gate(
    godot: pathlib.Path,
    project: pathlib.Path,
    profile: str,
    output_dir: pathlib.Path,
    wait_frames: int,
) -> pathlib.Path:
    capture_stem = f"terrain_1_0_{profile}_edit_tunnel_upward_lod_gate"
    effective_wait_frames = max(wait_frames, 600)
    capture, summary = run_visual_capture_summary(
        godot,
        project,
        "edit_tunnel_upward_lod_gate",
        output_dir,
        effective_wait_frames,
        profile=profile,
        capture_stem=capture_stem,
    )
    validate_tunnel_upward_lod_summary(summary, profile)
    validate_tunnel_step_captures(
        output_dir,
        f"{capture_stem}_step_*.png",
        "tunnel upward LOD",
        minimum_count=6,
    )
    return capture


def run_tunnel_transient_crawl_gate(
    godot: pathlib.Path,
    project: pathlib.Path,
    profile: str,
    output_dir: pathlib.Path,
    wait_frames: int,
) -> pathlib.Path:
    capture_stem = f"terrain_1_0_{profile}_edit_tunnel_transient_crawl_gate"
    capture, summary = run_visual_capture_summary(
        godot,
        project,
        "edit_tunnel_transient_crawl_gate",
        output_dir,
        wait_frames,
        profile=profile,
        capture_stem=capture_stem,
    )
    validate_tunnel_transient_crawl_summary(summary, profile)
    validate_tunnel_step_captures(
        output_dir,
        f"{capture_stem}_step_transient_*.png",
        "tunnel transient crawl",
    )
    return capture


def run_tunnel_visual_artifact_gate(
    godot: pathlib.Path,
    project: pathlib.Path,
    profile: str,
    output_dir: pathlib.Path,
    wait_frames: int,
) -> pathlib.Path:
    capture_stem = f"terrain_1_0_{profile}_edit_tunnel_visual_artifact_gate"
    capture, summary = run_visual_capture_summary(
        godot,
        project,
        "edit_tunnel_transient_crawl_gate",
        output_dir,
        wait_frames,
        profile=profile,
        capture_stem=capture_stem,
    )
    validate_tunnel_transient_crawl_summary(summary, profile)
    validate_tunnel_step_captures(
        output_dir,
        f"{capture_stem}_step_transient_*.png",
        "tunnel visual artifact",
    )
    analyses = validate_tunnel_visual_artifact_captures(
        profile,
        output_dir,
        capture_stem,
    )
    print(
        "WT_TUNNEL_VISUAL_ARTIFACT_GATE_PROFILE_PASS "
        "profile=%s analyzed=%d max_center_sky=%d max_sky=%d"
        % (
            profile,
            len(analyses),
            max(int(analysis["center_sky_pixels"]) for analysis in analyses),
            max(int(analysis["sky_pixels"]) for analysis in analyses),
        )
    )
    return capture


def validate_tunnel_step_captures(
    output_dir: pathlib.Path,
    glob_pattern: str,
    context: str,
    minimum_count: int = 16,
) -> list[pathlib.Path]:
    step_captures = sorted(output_dir.glob(glob_pattern))
    if len(step_captures) < minimum_count:
        raise RuntimeError(
            f"{context} expected at least {minimum_count} step captures, got "
            f"{len(step_captures)} in {output_dir}"
        )
    for step_capture in step_captures:
        if step_capture.stat().st_size < 10_000:
            raise RuntimeError(f"{context} step capture too small: {step_capture}")
    return step_captures


def validate_tunnel_visual_artifact_captures(
    profile: str,
    output_dir: pathlib.Path,
    capture_stem: str,
) -> list[dict[str, object]]:
    try:
        from PIL import Image
    except ImportError as exc:
        raise RuntimeError(
            "Pillow is required for --tunnel-visual-artifact-gate image analysis."
        ) from exc

    labels = TUNNEL_VISUAL_SKY_FREE_LABELS.get(profile)
    if not labels:
        raise RuntimeError(f"tunnel visual artifact labels missing for profile {profile!r}")
    analyses: list[dict[str, object]] = []
    for label in labels:
        image_path = output_dir / f"{capture_stem}_step_transient_{label}_frame_01.png"
        analysis = analyze_tunnel_sky_pixels(Image, image_path)
        analyses.append(analysis)
        center_sky_pixels = int(analysis["center_sky_pixels"])
        sky_pixels = int(analysis["sky_pixels"])
        if center_sky_pixels != 0:
            raise RuntimeError(
                "tunnel visual artifact gate found central sky-colored pixels "
                f"in {label}: {analysis!r}"
            )
        if sky_pixels > TUNNEL_VISUAL_WHOLE_IMAGE_SKY_TOLERANCE:
            raise RuntimeError(
                "tunnel visual artifact gate found unexpected sky-colored pixels "
                f"in {label}: {analysis!r}"
            )
    return analyses


def analyze_tunnel_sky_pixels(image_module: object, image_path: pathlib.Path) -> dict[str, object]:
    if not image_path.is_file() or image_path.stat().st_size < 10_000:
        raise RuntimeError(f"tunnel visual artifact image missing or too small: {image_path}")
    with image_module.open(image_path) as image:
        rgb_image = image.convert("RGB")
        width, height = rgb_image.size
        margin = TUNNEL_VISUAL_CENTER_MARGIN_RATIO
        center_left = int(width * margin)
        center_right = int(width * (1.0 - margin))
        center_top = int(height * margin)
        center_bottom = int(height * (1.0 - margin))
        sky_pixels = 0
        center_sky_pixels = 0
        sky_examples: list[tuple[int, int, tuple[int, int, int]]] = []
        center_examples: list[tuple[int, int, tuple[int, int, int]]] = []
        for index, pixel in enumerate(rgb_image.getdata()):
            if not is_tunnel_sky_pixel(pixel):
                continue
            x = index % width
            y = index // width
            sky_pixels += 1
            if len(sky_examples) < 8:
                sky_examples.append((x, y, pixel))
            if center_left <= x < center_right and center_top <= y < center_bottom:
                center_sky_pixels += 1
                if len(center_examples) < 8:
                    center_examples.append((x, y, pixel))
    return {
        "path": str(image_path),
        "width": width,
        "height": height,
        "sky_pixels": sky_pixels,
        "center_sky_pixels": center_sky_pixels,
        "sky_examples": sky_examples,
        "center_examples": center_examples,
    }


def is_tunnel_sky_pixel(pixel: tuple[int, int, int]) -> bool:
    red, green, blue = pixel
    return (
        blue >= 165
        and green >= 115
        and red <= 180
        and blue >= red + 25
        and blue >= green + 5
    )


def validate_open_gap_digest(digest: dict[str, object], context: str) -> None:
    if digest.get("ok") is not True:
        raise RuntimeError(f"{context} probe failed: {digest!r}")
    boundary_edges = int(digest.get("boundary_edges", -1))
    chunk_face_boundary_edges = int(digest.get("chunk_face_boundary_edges", 0))
    if int(digest.get("interior_boundary_edges", boundary_edges)) != 0:
        raise RuntimeError(f"{context} interior open edge: {digest!r}")
    if int(digest.get("unknown_boundary_edges", 0)) != 0:
        raise RuntimeError(f"{context} unknown open edge: {digest!r}")
    if boundary_edges != chunk_face_boundary_edges:
        raise RuntimeError(f"{context} unexpected boundary edge: {digest!r}")
    if int(digest.get("nonmanifold_edges", -1)) != 0:
        raise RuntimeError(f"{context} nonmanifold edge: {digest!r}")
    if int(digest.get("orientation_conflict_edges", -1)) != 0:
        raise RuntimeError(f"{context} orientation conflict: {digest!r}")
    if int(digest.get("zero_area_unknown_triangles", 0)) != 0:
        raise RuntimeError(f"{context} unknown zero-area triangle: {digest!r}")
    if int(digest.get("zero_edge_triangles", 0)) != 0:
        raise RuntimeError(f"{context} zero-edge triangle: {digest!r}")
    if int(digest.get("repeated_point_key_interior_triangles", 0)) != 0:
        raise RuntimeError(f"{context} interior repeated-point triangle: {digest!r}")
    if int(digest.get("repeated_point_key_unknown_triangles", 0)) != 0:
        raise RuntimeError(f"{context} unknown repeated-point triangle: {digest!r}")
    if int(digest.get("triangles_in_region", 0)) <= 0:
        raise RuntimeError(f"{context} sampled no triangles: {digest!r}")


def validate_edited_exact_region(
    exact_region: object,
    context: str,
    required_active_retention_viewers: int = 1,
) -> None:
    if not isinstance(exact_region, dict):
        raise RuntimeError(f"{context} edited exact-region summary missing: {exact_region!r}")
    if exact_region.get("ok") is not True:
        raise RuntimeError(f"{context} edited exact-region contract failed: {exact_region!r}")
    if exact_region.get("applies") is not True:
        raise RuntimeError(f"{context} edited exact-region contract not applied: {exact_region!r}")
    if float(exact_region.get("declared_radius", 0.0)) <= 0.0:
        raise RuntimeError(f"{context} edited exact-region radius invalid: {exact_region!r}")
    if int(exact_region.get("edit_commit_count", 0)) <= 0:
        raise RuntimeError(f"{context} edited exact-region has no committed edits: {exact_region!r}")
    if int(exact_region.get("retention_active_viewers", 0)) < required_active_retention_viewers:
        raise RuntimeError(
            f"{context} edited exact-region retained too few active viewers: {exact_region!r}"
        )
    if int(exact_region.get("retention_fallbacks", -1)) != 0:
        raise RuntimeError(f"{context} edited exact-region retention fallback: {exact_region!r}")
    if int(exact_region.get("pending_chunk_retirements", -1)) != 0:
        raise RuntimeError(f"{context} edited exact-region pending retirements: {exact_region!r}")
    if int(exact_region.get("pending_chunk_replacements", -1)) != 0:
        raise RuntimeError(f"{context} edited exact-region pending replacements: {exact_region!r}")


def validate_tunnel_summary(
    summary: dict[str, object],
    profile: str,
) -> None:
    if summary.get("profile") != profile:
        raise RuntimeError(f"tunnel gate profile mismatch: {summary!r}")
    if summary.get("mode") != "edit_tunnel_gate":
        raise RuntimeError(f"tunnel gate mode mismatch: {summary!r}")
    tunnel = summary.get("tunnel")
    if not isinstance(tunnel, dict):
        raise RuntimeError(f"tunnel gate summary missing: {summary!r}")
    if tunnel.get("enabled") is not True or tunnel.get("ok") is not True:
        raise RuntimeError(f"tunnel gate failed: {tunnel!r}")
    if int(tunnel.get("operation_count", 0)) < 96:
        raise RuntimeError(f"tunnel gate did not exercise enough edits: {tunnel!r}")
    if int(tunnel.get("sample_count", 0)) <= 0:
        raise RuntimeError(f"tunnel gate sampled no authoritative points: {tunnel!r}")
    if int(tunnel.get("air_sample_count", 0)) <= 0:
        raise RuntimeError(f"tunnel gate sampled no carved air: {tunnel!r}")
    if int(tunnel.get("density_mismatches", -1)) != 0:
        raise RuntimeError(f"tunnel gate density mismatch: {tunnel!r}")
    if int(tunnel.get("material_mismatches", -1)) != 0:
        raise RuntimeError(f"tunnel gate material mismatch: {tunnel!r}")
    if float(tunnel.get("max_abs_density_delta", -1.0)) != 0.0:
        raise RuntimeError(f"tunnel gate density delta: {tunnel!r}")
    probe_summaries = tunnel.get("probe_summaries")
    if not isinstance(probe_summaries, list) or len(probe_summaries) < 6:
        raise RuntimeError(f"tunnel gate probe summaries missing: {tunnel!r}")
    expected_labels = {
        "entry",
        "middle",
        "exit",
        "descending_entry",
        "descending_middle",
        "descending_deep",
    }
    labels: set[str] = set()
    for probe in probe_summaries:
        if not isinstance(probe, dict):
            raise RuntimeError(f"tunnel gate probe malformed: {probe!r}")
        label = str(probe.get("label", ""))
        labels.add(label)
        validate_open_gap_digest(probe, f"tunnel gate {label}")
        if int(probe.get("lod0_triangles_in_region", 0)) <= 0:
            raise RuntimeError(f"tunnel gate lost LOD0 edited detail at {label}: {probe!r}")
    if labels != expected_labels:
        raise RuntimeError(
            f"tunnel gate labels expected {sorted(expected_labels)}, "
            f"got {sorted(labels)}: {tunnel!r}"
        )
    validate_edited_exact_region(tunnel.get("edited_exact_region"), "tunnel gate")
    print(
        "WT_TUNNEL_GATE_PROFILE_PASS profile=%s operations=%d probes=%d"
        % (
            profile,
            int(tunnel.get("operation_count", 0)),
            len(probe_summaries),
        )
    )


def validate_tunnel_crawl_summary(
    summary: dict[str, object],
    profile: str,
) -> None:
    if summary.get("profile") != profile:
        raise RuntimeError(f"tunnel crawl gate profile mismatch: {summary!r}")
    if summary.get("mode") != "edit_tunnel_crawl_gate":
        raise RuntimeError(f"tunnel crawl gate mode mismatch: {summary!r}")
    tunnel = summary.get("tunnel")
    if not isinstance(tunnel, dict):
        raise RuntimeError(f"tunnel crawl gate summary missing: {summary!r}")
    if tunnel.get("enabled") is not True or tunnel.get("ok") is not True:
        raise RuntimeError(f"tunnel crawl gate failed: {tunnel!r}")
    if tunnel.get("gate_mode") != "edit_tunnel_crawl_gate":
        raise RuntimeError(f"tunnel crawl gate mode missing from tunnel summary: {tunnel!r}")
    if int(tunnel.get("operation_count", 0)) < 96:
        raise RuntimeError(f"tunnel crawl did not exercise enough edits: {tunnel!r}")
    if int(tunnel.get("sample_count", 0)) <= 0:
        raise RuntimeError(f"tunnel crawl sampled no authoritative points: {tunnel!r}")
    if int(tunnel.get("air_sample_count", 0)) <= 0:
        raise RuntimeError(f"tunnel crawl sampled no carved air: {tunnel!r}")
    if int(tunnel.get("density_mismatches", -1)) != 0:
        raise RuntimeError(f"tunnel crawl density mismatch: {tunnel!r}")
    if int(tunnel.get("material_mismatches", -1)) != 0:
        raise RuntimeError(f"tunnel crawl material mismatch: {tunnel!r}")
    if float(tunnel.get("max_abs_density_delta", -1.0)) != 0.0:
        raise RuntimeError(f"tunnel crawl density delta: {tunnel!r}")
    probe_summaries = tunnel.get("probe_summaries")
    if not isinstance(probe_summaries, list) or len(probe_summaries) < 16:
        raise RuntimeError(f"tunnel crawl probe summaries missing: {tunnel!r}")
    expected_labels = {
        *(f"main_crawl_{index:02d}" for index in range(9)),
        *(f"descending_crawl_{index:02d}" for index in range(7)),
    }
    labels: set[str] = set()
    for probe in probe_summaries:
        if not isinstance(probe, dict):
            raise RuntimeError(f"tunnel crawl probe malformed: {probe!r}")
        label = str(probe.get("label", ""))
        labels.add(label)
        validate_open_gap_digest(probe, f"tunnel crawl {label}")
        if int(probe.get("lod0_triangles_in_region", 0)) <= 0:
            raise RuntimeError(f"tunnel crawl lost LOD0 edited detail at {label}: {probe!r}")
    if labels != expected_labels:
        raise RuntimeError(
            f"tunnel crawl labels expected {sorted(expected_labels)}, "
            f"got {sorted(labels)}: {tunnel!r}"
        )
    validate_edited_exact_region(tunnel.get("edited_exact_region"), "tunnel crawl")
    print(
        "WT_TUNNEL_CRAWL_GATE_PROFILE_PASS profile=%s operations=%d probes=%d"
        % (
            profile,
            int(tunnel.get("operation_count", 0)),
            len(probe_summaries),
        )
    )


def validate_tunnel_upward_lod_summary(
    summary: dict[str, object],
    profile: str,
) -> None:
    if summary.get("profile") != profile:
        raise RuntimeError(f"tunnel upward LOD profile mismatch: {summary!r}")
    if summary.get("mode") != "edit_tunnel_upward_lod_gate":
        raise RuntimeError(f"tunnel upward LOD mode mismatch: {summary!r}")
    tunnel = summary.get("tunnel")
    if not isinstance(tunnel, dict):
        raise RuntimeError(f"tunnel upward LOD summary missing: {summary!r}")
    if tunnel.get("enabled") is not True or tunnel.get("ok") is not True:
        raise RuntimeError(f"tunnel upward LOD failed: {tunnel!r}")
    if tunnel.get("gate_mode") != "edit_tunnel_upward_lod_gate":
        raise RuntimeError(
            f"tunnel upward LOD mode missing from tunnel summary: {tunnel!r}"
        )
    if int(tunnel.get("operation_count", 0)) < 96:
        raise RuntimeError(f"tunnel upward LOD did not exercise enough edits: {tunnel!r}")
    if int(tunnel.get("sample_count", 0)) <= 0:
        raise RuntimeError(f"tunnel upward LOD sampled no authoritative points: {tunnel!r}")
    if int(tunnel.get("air_sample_count", 0)) <= 0:
        raise RuntimeError(f"tunnel upward LOD sampled no carved air: {tunnel!r}")
    if int(tunnel.get("density_mismatches", -1)) != 0:
        raise RuntimeError(f"tunnel upward LOD density mismatch: {tunnel!r}")
    if int(tunnel.get("material_mismatches", -1)) != 0:
        raise RuntimeError(f"tunnel upward LOD material mismatch: {tunnel!r}")
    if float(tunnel.get("max_abs_density_delta", -1.0)) != 0.0:
        raise RuntimeError(f"tunnel upward LOD density delta: {tunnel!r}")
    probe_summaries = tunnel.get("probe_summaries")
    expected_labels = {
        "close_descending",
        "surface_oblique",
        "upward_low",
        "upward_mid",
        "upward_high",
        "deep_return",
    }
    if not isinstance(probe_summaries, list) or len(probe_summaries) < len(expected_labels):
        raise RuntimeError(f"tunnel upward LOD probe summaries missing: {tunnel!r}")
    labels: set[str] = set()
    for probe in probe_summaries:
        if not isinstance(probe, dict):
            raise RuntimeError(f"tunnel upward LOD probe malformed: {probe!r}")
        label = str(probe.get("label", ""))
        labels.add(label)
        validate_open_gap_digest(probe, f"tunnel upward LOD {label}")
        if int(probe.get("lod0_triangles_in_region", 0)) <= 0:
            raise RuntimeError(
                f"tunnel upward LOD lost local edit detail at {label}: {probe!r}"
            )
    if labels != expected_labels:
        raise RuntimeError(
            f"tunnel upward LOD labels expected {sorted(expected_labels)}, "
            f"got {sorted(labels)}: {tunnel!r}"
        )
    if int(summary.get("edit_lod_retention_active_viewers", 0)) <= 0:
        raise RuntimeError(f"tunnel upward LOD had no active edit retention viewers: {summary!r}")
    if int(summary.get("edit_lod_retention_fallbacks", 0)) != 0:
        raise RuntimeError(f"tunnel upward LOD edit retention fell back: {summary!r}")
    validate_edited_exact_region(tunnel.get("edited_exact_region"), "tunnel upward LOD")
    print(
        "WT_TUNNEL_UPWARD_LOD_GATE_PROFILE_PASS profile=%s operations=%d probes=%d"
        % (
            profile,
            int(tunnel.get("operation_count", 0)),
            len(probe_summaries),
        )
    )


def validate_tunnel_transient_crawl_summary(
    summary: dict[str, object],
    profile: str,
) -> None:
    if summary.get("profile") != profile:
        raise RuntimeError(f"tunnel transient crawl profile mismatch: {summary!r}")
    if summary.get("mode") != "edit_tunnel_transient_crawl_gate":
        raise RuntimeError(f"tunnel transient crawl mode mismatch: {summary!r}")
    tunnel = summary.get("tunnel")
    if not isinstance(tunnel, dict):
        raise RuntimeError(f"tunnel transient crawl summary missing: {summary!r}")
    if tunnel.get("enabled") is not True or tunnel.get("ok") is not True:
        raise RuntimeError(f"tunnel transient crawl failed: {tunnel!r}")
    if tunnel.get("gate_mode") != "edit_tunnel_transient_crawl_gate":
        raise RuntimeError(
            f"tunnel transient crawl mode missing from tunnel summary: {tunnel!r}"
        )
    if int(tunnel.get("operation_count", 0)) < 96:
        raise RuntimeError(f"tunnel transient crawl did not exercise enough edits: {tunnel!r}")
    if int(tunnel.get("sample_count", 0)) <= 0:
        raise RuntimeError(f"tunnel transient crawl sampled no authoritative points: {tunnel!r}")
    if int(tunnel.get("air_sample_count", 0)) <= 0:
        raise RuntimeError(f"tunnel transient crawl sampled no carved air: {tunnel!r}")
    if int(tunnel.get("density_mismatches", -1)) != 0:
        raise RuntimeError(f"tunnel transient crawl density mismatch: {tunnel!r}")
    if int(tunnel.get("material_mismatches", -1)) != 0:
        raise RuntimeError(f"tunnel transient crawl material mismatch: {tunnel!r}")
    if float(tunnel.get("max_abs_density_delta", -1.0)) != 0.0:
        raise RuntimeError(f"tunnel transient crawl density delta: {tunnel!r}")
    expected_frames = [0, 1, 3, 8, 16, 32]
    if tunnel.get("transient_probe_frames") != expected_frames:
        raise RuntimeError(
            f"tunnel transient crawl frames expected {expected_frames}, "
            f"got {tunnel.get('transient_probe_frames')!r}: {tunnel!r}"
        )
    validate_edited_exact_region(tunnel.get("edited_exact_region"), "tunnel transient crawl")
    transient_summaries = tunnel.get("transient_probe_summaries")
    if not isinstance(transient_summaries, list) or len(transient_summaries) < 16:
        raise RuntimeError(f"tunnel transient crawl probe summaries missing: {tunnel!r}")
    expected_labels = {
        *(f"main_crawl_{index:02d}" for index in range(9)),
        *(f"descending_crawl_{index:02d}" for index in range(7)),
    }
    labels: set[str] = set()
    total_frame_probes = 0
    for step in transient_summaries:
        if not isinstance(step, dict):
            raise RuntimeError(f"tunnel transient crawl step malformed: {step!r}")
        if step.get("ok") is not True:
            raise RuntimeError(f"tunnel transient crawl step failed: {step!r}")
        label = str(step.get("label", ""))
        labels.add(label)
        if step.get("capture_saved") is not True:
            raise RuntimeError(f"tunnel transient crawl step capture missing: {step!r}")
        frame_probes = step.get("frame_probes")
        if not isinstance(frame_probes, list) or len(frame_probes) != len(expected_frames):
            raise RuntimeError(f"tunnel transient crawl frame probes missing: {step!r}")
        frames = [int(probe.get("frame", -1)) for probe in frame_probes if isinstance(probe, dict)]
        if frames != expected_frames:
            raise RuntimeError(
                f"tunnel transient crawl frames for {label} expected {expected_frames}, "
                f"got {frames}: {step!r}"
            )
        for probe in frame_probes:
            if not isinstance(probe, dict):
                raise RuntimeError(f"tunnel transient crawl probe malformed: {probe!r}")
            validate_open_gap_digest(
                probe,
                f"tunnel transient crawl {label} frame={int(probe.get('frame', -1))}",
            )
            total_frame_probes += 1
    if labels != expected_labels:
        raise RuntimeError(
            f"tunnel transient crawl labels expected {sorted(expected_labels)}, "
            f"got {sorted(labels)}: {tunnel!r}"
        )
    print(
        "WT_TUNNEL_TRANSIENT_CRAWL_GATE_PROFILE_PASS profile=%s operations=%d steps=%d frame_probes=%d"
        % (
            profile,
            int(tunnel.get("operation_count", 0)),
            len(transient_summaries),
            total_frame_probes,
        )
    )


def validate_manifold_stress_summary(
    summary: dict[str, object],
    profile: str,
) -> None:
    if summary.get("profile") != profile:
        raise RuntimeError(f"manifold stress profile mismatch: {summary!r}")
    if summary.get("mode") != "edit_manifold_stress_gate":
        raise RuntimeError(f"manifold stress mode mismatch: {summary!r}")
    stress = summary.get("manifold_stress")
    if not isinstance(stress, dict):
        raise RuntimeError(f"manifold stress summary missing: {summary!r}")
    if stress.get("enabled") is not True or stress.get("ok") is not True:
        raise RuntimeError(f"manifold stress gate failed: {stress!r}")
    if int(stress.get("operation_count", 0)) < 128:
        raise RuntimeError(f"manifold stress did not exercise enough edits: {stress!r}")
    if int(stress.get("baseline_sample_count", 0)) <= 0:
        raise RuntimeError(f"manifold stress sampled no authoritative points: {stress!r}")
    if int(stress.get("baseline_air_sample_count", 0)) <= 0:
        raise RuntimeError(f"manifold stress sampled no carved air: {stress!r}")
    required_modes = {"carve", "construct", "fill", "paint"}
    mode_counts = stress.get("mode_counts")
    if not isinstance(mode_counts, dict) or not required_modes.issubset(set(mode_counts)):
        raise RuntimeError(f"manifold stress did not exercise all edit modes: {stress!r}")
    for mode in required_modes:
        if int(mode_counts.get(mode, 0)) <= 0:
            raise RuntimeError(f"manifold stress edit mode {mode} missing: {stress!r}")
    interim_summaries = stress.get("interim_summaries")
    if not isinstance(interim_summaries, list) or len(interim_summaries) < 4:
        raise RuntimeError(f"manifold stress interim checks missing: {stress!r}")
    persistence_summaries = stress.get("persistence_summaries")
    if not isinstance(persistence_summaries, list) or len(persistence_summaries) < 5:
        raise RuntimeError(f"manifold stress movement persistence missing: {stress!r}")
    for collection_name in ("interim_summaries", "persistence_summaries"):
        collection = stress.get(collection_name)
        if not isinstance(collection, list):
            raise RuntimeError(f"manifold stress {collection_name} malformed: {stress!r}")
        for entry in collection:
            if not isinstance(entry, dict):
                raise RuntimeError(f"manifold stress persistence entry malformed: {entry!r}")
            if int(entry.get("sample_count", 0)) <= 0:
                raise RuntimeError(f"manifold stress sampled no points: {entry!r}")
            if int(entry.get("density_mismatches", -1)) != 0:
                raise RuntimeError(f"manifold stress density mismatch: {entry!r}")
            if int(entry.get("material_mismatches", -1)) != 0:
                raise RuntimeError(f"manifold stress material mismatch: {entry!r}")
            if float(entry.get("max_abs_density_delta", -1.0)) != 0.0:
                raise RuntimeError(f"manifold stress density delta: {entry!r}")
    transitions = stress.get("transition_summaries")
    if not isinstance(transitions, list) or len(transitions) < 9:
        raise RuntimeError(f"manifold stress transition checks missing: {stress!r}")
    for transition in transitions:
        if not isinstance(transition, dict):
            raise RuntimeError(f"manifold stress transition malformed: {transition!r}")
        if transition.get("ok") is not True:
            raise RuntimeError(f"manifold stress transition failed: {transition!r}")
        boundary_edges = int(transition.get("boundary_edges", -1))
        chunk_face_boundary_edges = int(transition.get("chunk_face_boundary_edges", 0))
        if int(transition.get("interior_boundary_edges", boundary_edges)) != 0:
            raise RuntimeError(f"manifold stress interior open edge: {transition!r}")
        if int(transition.get("unknown_boundary_edges", 0)) != 0:
            raise RuntimeError(f"manifold stress unknown open edge: {transition!r}")
        if boundary_edges != chunk_face_boundary_edges:
            raise RuntimeError(f"manifold stress unexpected boundary edge: {transition!r}")
        if int(transition.get("nonmanifold_edges", -1)) != 0:
            raise RuntimeError(f"manifold stress nonmanifold edge: {transition!r}")
        if int(transition.get("orientation_conflict_edges", -1)) != 0:
            raise RuntimeError(f"manifold stress orientation conflict: {transition!r}")
        if int(transition.get("zero_area_unknown_triangles", 0)) != 0:
            raise RuntimeError(f"manifold stress unknown zero-area triangles: {transition!r}")
        if int(transition.get("zero_edge_triangles", 0)) != 0:
            raise RuntimeError(f"manifold stress zero-edge triangles: {transition!r}")
        if int(transition.get("repeated_point_key_interior_triangles", 0)) != 0:
            raise RuntimeError(f"manifold stress repeated-point interior triangles: {transition!r}")
        if int(transition.get("repeated_point_key_unknown_triangles", 0)) != 0:
            raise RuntimeError(f"manifold stress repeated-point unknown triangles: {transition!r}")
        if int(transition.get("transient_probe_failure_count", -1)) != 0:
            raise RuntimeError(f"manifold stress transient probe failure: {transition!r}")
        if int(transition.get("triangles_in_region", 0)) <= 0:
            raise RuntimeError(f"manifold stress sampled no triangles: {transition!r}")
    reload_persistence = stress.get("reload_persistence")
    if not isinstance(reload_persistence, dict) or reload_persistence.get("ok") is not True:
        raise RuntimeError(f"manifold stress reload persistence failed: {stress!r}")
    if int(reload_persistence.get("density_mismatches", -1)) != 0:
        raise RuntimeError(f"manifold stress reload density mismatch: {reload_persistence!r}")
    if int(reload_persistence.get("material_mismatches", -1)) != 0:
        raise RuntimeError(f"manifold stress reload material mismatch: {reload_persistence!r}")
    if int(reload_persistence.get("missing_after", -1)) != 0:
        raise RuntimeError(f"manifold stress reload missing samples: {reload_persistence!r}")
    print(
        "WT_MANIFOLD_STRESS_GATE_PROFILE_PASS profile=%s operations=%d transitions=%d"
        % (
            profile,
            int(stress.get("operation_count", 0)),
            len(transitions),
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
        if int(transition.get("settled_nonmanifold_edges", -1)) != 0:
            raise RuntimeError(f"LOD movement settled nonmanifold edges detected: {transition!r}")
        if int(transition.get("settled_orientation_conflict_interior_edges", 0)) != 0:
            raise RuntimeError(
                f"LOD movement settled interior orientation conflicts detected: {transition!r}"
            )
        if int(transition.get("settled_orientation_conflict_unknown_edges", 0)) != 0:
            raise RuntimeError(
                f"LOD movement settled unknown orientation conflicts detected: {transition!r}"
            )
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
    validate_edited_exact_region(
        lod_movement.get("edited_exact_region"),
        "LOD movement",
    )
    print(
        "WT_LOD_MOVEMENT_GATE_PROFILE_PASS profile=%s operations=%d transient_probe_failures=%d"
        % (
            profile,
            int(lod_movement.get("total_operation_count", 0)),
            transient_failures,
        )
    )


def validate_multisite_lod_summary(
    summary: dict[str, object],
    profile: str,
) -> None:
    if summary.get("profile") != profile:
        raise RuntimeError(f"multi-site LOD profile mismatch: {summary!r}")
    if summary.get("mode") != "edit_multisite_lod_gate":
        raise RuntimeError(f"multi-site LOD mode mismatch: {summary!r}")
    multi = summary.get("multisite_lod")
    if not isinstance(multi, dict):
        raise RuntimeError(f"multi-site LOD summary missing: {summary!r}")
    if multi.get("enabled") is not True or multi.get("ok") is not True:
        raise RuntimeError(f"multi-site LOD gate failed: {multi!r}")
    if int(multi.get("site_count", 0)) != 2:
        raise RuntimeError(f"multi-site LOD did not exercise two sites: {multi!r}")
    if int(multi.get("operation_count", 0)) < 96:
        raise RuntimeError(f"multi-site LOD edited too little: {multi!r}")
    if int(multi.get("density_mismatches", -1)) != 0:
        raise RuntimeError(f"multi-site LOD density mismatch: {multi!r}")
    if int(multi.get("material_mismatches", -1)) != 0:
        raise RuntimeError(f"multi-site LOD material mismatch: {multi!r}")
    if float(multi.get("max_abs_density_delta", -1.0)) != 0.0:
        raise RuntimeError(f"multi-site LOD density delta: {multi!r}")
    if int(multi.get("retention_fallbacks", -1)) != 0:
        raise RuntimeError(f"multi-site LOD retention fallback occurred: {multi!r}")
    validate_edited_exact_region(
        multi.get("edited_exact_region"),
        "multi-site LOD",
        required_active_retention_viewers=2,
    )
    expected_sites = {"site_a", "site_b"}
    observed_sites: set[str] = set()
    transitions = multi.get("transition_summaries", [])
    if not isinstance(transitions, list) or len(transitions) < 6:
        raise RuntimeError(f"multi-site LOD transition coverage too small: {multi!r}")
    for transition in transitions:
        if not isinstance(transition, dict):
            raise RuntimeError(f"multi-site LOD transition malformed: {multi!r}")
        if transition.get("ok") is not True:
            raise RuntimeError(f"multi-site LOD transition failed: {transition!r}")
        observed_sites.add(str(transition.get("site", "")))
        boundary_edges = int(transition.get("settled_boundary_edges", -1))
        chunk_face_boundary_edges = int(transition.get("settled_chunk_face_boundary_edges", 0))
        if int(transition.get("settled_interior_boundary_edges", boundary_edges)) != 0:
            raise RuntimeError(f"multi-site LOD settled crack detected: {transition!r}")
        if int(transition.get("settled_unknown_boundary_edges", 0)) != 0:
            raise RuntimeError(f"multi-site LOD settled unknown boundary detected: {transition!r}")
        if boundary_edges != chunk_face_boundary_edges:
            raise RuntimeError(f"multi-site LOD unexpected boundary detected: {transition!r}")
        if int(transition.get("settled_nonmanifold_edges", -1)) != 0:
            raise RuntimeError(f"multi-site LOD nonmanifold edges detected: {transition!r}")
        if int(transition.get("settled_orientation_conflict_interior_edges", 0)) != 0:
            raise RuntimeError(
                f"multi-site LOD interior orientation conflicts detected: {transition!r}"
            )
        if int(transition.get("settled_orientation_conflict_unknown_edges", 0)) != 0:
            raise RuntimeError(
                f"multi-site LOD unknown orientation conflicts detected: {transition!r}"
            )
        if int(transition.get("settled_zero_area_interior_triangles", 0)) != 0:
            raise RuntimeError(f"multi-site LOD interior zero-area triangles detected: {transition!r}")
        if int(transition.get("settled_zero_area_unknown_triangles", 0)) != 0:
            raise RuntimeError(f"multi-site LOD unknown zero-area triangles detected: {transition!r}")
        if int(transition.get("settled_repeated_point_key_interior_triangles", 0)) != 0:
            raise RuntimeError(f"multi-site LOD interior repeated-point triangles detected: {transition!r}")
        if int(transition.get("settled_repeated_point_key_unknown_triangles", 0)) != 0:
            raise RuntimeError(f"multi-site LOD unknown repeated-point triangles detected: {transition!r}")
        if int(transition.get("settled_zero_edge_triangles", 0)) != 0:
            raise RuntimeError(f"multi-site LOD zero-edge triangles detected: {transition!r}")
        if int(transition.get("settled_triangles_in_region", 0)) <= 0:
            raise RuntimeError(f"multi-site LOD sampled no triangles: {transition!r}")
        if int(transition.get("transient_probe_failure_count", -1)) != 0:
            raise RuntimeError(f"multi-site LOD transient probe failure: {transition!r}")
    if observed_sites != expected_sites:
        raise RuntimeError(
            f"multi-site LOD sites expected {sorted(expected_sites)}, "
            f"got {sorted(observed_sites)}: {multi!r}"
        )
    print(
        "WT_MULTISITE_LOD_GATE_PROFILE_PASS profile=%s operations=%d transitions=%d"
        % (profile, int(multi.get("operation_count", 0)), len(transitions))
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
        "--multisite-lod-gate",
        action="store_true",
        help=(
            "Exercise edits at two far-apart sites and revisit both under LOD "
            "movement to catch cross-site edit retention/replacement failures."
        ),
    )
    parser.add_argument(
        "--multisite-lod-profile",
        action="append",
        choices=LOD_MOVEMENT_GATE_PROFILES,
        help=(
            "Profile to use for --multisite-lod-gate. May be passed more than once. "
            "Defaults to compact and flat profiles."
        ),
    )
    parser.add_argument(
        "--multisite-lod-output-dir",
        default=None,
        help="Directory for multi-site LOD gate PNG captures.",
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
    parser.add_argument(
        "--manifold-stress-gate",
        action="store_true",
        help=(
            "Exercise many mixed edits, movement, transient probes, settled probes, "
            "and reload persistence to catch open/nonmanifold terrain regressions."
        ),
    )
    parser.add_argument(
        "--manifold-stress-profile",
        action="append",
        choices=LOD_MOVEMENT_GATE_PROFILES,
        help=(
            "Profile to use for --manifold-stress-gate. May be passed more than once. "
            "Defaults to compact and flat profiles."
        ),
    )
    parser.add_argument(
        "--manifold-stress-output-dir",
        default=None,
        help="Directory for manifold stress gate PNG captures.",
    )
    parser.add_argument(
        "--tunnel-gate",
        action="store_true",
        help=(
            "Carve a tunnel/cavity, inspect it from entry/middle/exit, and verify "
            "that edited terrain has no open, nonmanifold, or orientation-conflicted gaps."
        ),
    )
    parser.add_argument(
        "--tunnel-profile",
        action="append",
        choices=LOD_MOVEMENT_GATE_PROFILES,
        help=(
            "Profile to use for --tunnel-gate. May be passed more than once. "
            "Defaults to compact and flat profiles."
        ),
    )
    parser.add_argument(
        "--tunnel-output-dir",
        default=None,
        help="Directory for tunnel gate PNG captures.",
    )
    parser.add_argument(
        "--tunnel-crawl-gate",
        action="store_true",
        help=(
            "Carve the tunnel/cavity, move the actual viewer through close centerline "
            "crawl positions, save per-step screenshots, and verify each position has "
            "no open, nonmanifold, or orientation-conflicted gaps."
        ),
    )
    parser.add_argument(
        "--tunnel-crawl-profile",
        action="append",
        choices=LOD_MOVEMENT_GATE_PROFILES,
        help=(
            "Profile to use for --tunnel-crawl-gate. May be passed more than once. "
            "Defaults to compact and flat profiles."
        ),
    )
    parser.add_argument(
        "--tunnel-crawl-output-dir",
        default=None,
        help="Directory for tunnel crawl gate PNG captures.",
    )
    parser.add_argument(
        "--tunnel-transient-crawl-gate",
        action="store_true",
        help=(
            "Carve the tunnel/cavity, move the actual viewer through close crawl "
            "positions, and probe frames 0/1/3/8/16/32 after each movement to "
            "catch transient open, nonmanifold, or orientation-conflicted gaps."
        ),
    )
    parser.add_argument(
        "--tunnel-transient-crawl-profile",
        action="append",
        choices=LOD_MOVEMENT_GATE_PROFILES,
        help=(
            "Profile to use for --tunnel-transient-crawl-gate. May be passed more "
            "than once. Defaults to compact and flat profiles."
        ),
    )
    parser.add_argument(
        "--tunnel-transient-crawl-output-dir",
        default=None,
        help="Directory for tunnel transient crawl gate PNG captures.",
    )
    parser.add_argument(
        "--tunnel-upward-lod-gate",
        action="store_true",
        help=(
            "Carve the descending tunnel, inspect it from close/surface/upward "
            "camera distances, and verify visible edited detail is retained "
            "instead of falling back to coarse LOD."
        ),
    )
    parser.add_argument(
        "--tunnel-upward-lod-profile",
        action="append",
        choices=LOD_MOVEMENT_GATE_PROFILES,
        help=(
            "Profile to use for --tunnel-upward-lod-gate. May be passed more "
            "than once. Defaults to compact and flat profiles."
        ),
    )
    parser.add_argument(
        "--tunnel-upward-lod-output-dir",
        default=None,
        help="Directory for tunnel upward LOD gate PNG captures.",
    )
    parser.add_argument(
        "--tunnel-visual-artifact-gate",
        action="store_true",
        help=(
            "Run the transient tunnel crawl and image-analyze deep closed-tunnel "
            "captures for unexpected sky-colored pixels."
        ),
    )
    parser.add_argument(
        "--tunnel-visual-artifact-profile",
        action="append",
        choices=LOD_MOVEMENT_GATE_PROFILES,
        help=(
            "Profile to use for --tunnel-visual-artifact-gate. May be passed more "
            "than once. Defaults to compact and flat profiles."
        ),
    )
    parser.add_argument(
        "--tunnel-visual-artifact-output-dir",
        default=None,
        help="Directory for tunnel visual artifact gate PNG captures.",
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
            default_capture_dir(project, "terrain_1_0_visual_smoke")
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
            else default_capture_dir(project, "terrain_1_0_lod_movement_gate")
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
    if args.multisite_lod_gate:
        multisite_lod_profiles = (
            tuple(args.multisite_lod_profile)
            if args.multisite_lod_profile
            else LOD_MOVEMENT_GATE_PROFILES
        )
        output_dir = (
            pathlib.Path(args.multisite_lod_output_dir).resolve()
            if args.multisite_lod_output_dir
            else default_capture_dir(project, "terrain_1_0_multisite_lod_gate")
        )
        captures = [
            run_multisite_lod_gate(
                godot,
                project,
                profile,
                output_dir,
                args.visual_wait_frames,
            )
            for profile in multisite_lod_profiles
        ]
        print(
            "WT_PRODUCTION_INTEGRATION_GAME_MULTISITE_LOD_GATE_PASS captures=%d dir=%s"
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
            else default_capture_dir(project, "terrain_1_0_edit_during_load_gate")
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
    if args.manifold_stress_gate:
        manifold_stress_profiles = (
            tuple(args.manifold_stress_profile)
            if args.manifold_stress_profile
            else LOD_MOVEMENT_GATE_PROFILES
        )
        output_dir = (
            pathlib.Path(args.manifold_stress_output_dir).resolve()
            if args.manifold_stress_output_dir
            else default_capture_dir(project, "terrain_1_0_manifold_stress_gate")
        )
        captures = [
            run_manifold_stress_gate(
                godot,
                project,
                profile,
                output_dir,
                args.visual_wait_frames,
            )
            for profile in manifold_stress_profiles
        ]
        print(
            "WT_PRODUCTION_INTEGRATION_GAME_MANIFOLD_STRESS_GATE_PASS captures=%d dir=%s"
            % (len(captures), output_dir)
        )
    if args.tunnel_gate:
        tunnel_profiles = (
            tuple(args.tunnel_profile)
            if args.tunnel_profile
            else LOD_MOVEMENT_GATE_PROFILES
        )
        output_dir = (
            pathlib.Path(args.tunnel_output_dir).resolve()
            if args.tunnel_output_dir
            else default_capture_dir(project, "terrain_1_0_tunnel_gate")
        )
        captures = [
            run_tunnel_gate(
                godot,
                project,
                profile,
                output_dir,
                args.visual_wait_frames,
            )
            for profile in tunnel_profiles
        ]
        print(
            "WT_PRODUCTION_INTEGRATION_GAME_TUNNEL_GATE_PASS captures=%d dir=%s"
            % (len(captures), output_dir)
        )
    if args.tunnel_crawl_gate:
        tunnel_crawl_profiles = (
            tuple(args.tunnel_crawl_profile)
            if args.tunnel_crawl_profile
            else LOD_MOVEMENT_GATE_PROFILES
        )
        output_dir = (
            pathlib.Path(args.tunnel_crawl_output_dir).resolve()
            if args.tunnel_crawl_output_dir
            else default_capture_dir(project, "terrain_1_0_tunnel_crawl_gate")
        )
        captures = [
            run_tunnel_crawl_gate(
                godot,
                project,
                profile,
                output_dir,
                args.visual_wait_frames,
            )
            for profile in tunnel_crawl_profiles
        ]
        print(
            "WT_PRODUCTION_INTEGRATION_GAME_TUNNEL_CRAWL_GATE_PASS captures=%d dir=%s"
            % (len(captures), output_dir)
        )
    if args.tunnel_transient_crawl_gate:
        tunnel_transient_crawl_profiles = (
            tuple(args.tunnel_transient_crawl_profile)
            if args.tunnel_transient_crawl_profile
            else LOD_MOVEMENT_GATE_PROFILES
        )
        output_dir = (
            pathlib.Path(args.tunnel_transient_crawl_output_dir).resolve()
            if args.tunnel_transient_crawl_output_dir
            else default_capture_dir(project, "terrain_1_0_tunnel_transient_crawl_gate")
        )
        captures = [
            run_tunnel_transient_crawl_gate(
                godot,
                project,
                profile,
                output_dir,
                args.visual_wait_frames,
            )
            for profile in tunnel_transient_crawl_profiles
        ]
        print(
            "WT_PRODUCTION_INTEGRATION_GAME_TUNNEL_TRANSIENT_CRAWL_GATE_PASS captures=%d dir=%s"
            % (len(captures), output_dir)
        )
    if args.tunnel_upward_lod_gate:
        tunnel_upward_lod_profiles = (
            tuple(args.tunnel_upward_lod_profile)
            if args.tunnel_upward_lod_profile
            else LOD_MOVEMENT_GATE_PROFILES
        )
        output_dir = (
            pathlib.Path(args.tunnel_upward_lod_output_dir).resolve()
            if args.tunnel_upward_lod_output_dir
            else default_capture_dir(project, "terrain_1_0_tunnel_upward_lod_gate")
        )
        captures = [
            run_tunnel_upward_lod_gate(
                godot,
                project,
                profile,
                output_dir,
                args.visual_wait_frames,
            )
            for profile in tunnel_upward_lod_profiles
        ]
        print(
            "WT_PRODUCTION_INTEGRATION_GAME_TUNNEL_UPWARD_LOD_GATE_PASS captures=%d dir=%s"
            % (len(captures), output_dir)
        )
    if args.tunnel_visual_artifact_gate:
        tunnel_visual_artifact_profiles = (
            tuple(args.tunnel_visual_artifact_profile)
            if args.tunnel_visual_artifact_profile
            else LOD_MOVEMENT_GATE_PROFILES
        )
        output_dir = (
            pathlib.Path(args.tunnel_visual_artifact_output_dir).resolve()
            if args.tunnel_visual_artifact_output_dir
            else default_capture_dir(project, "terrain_1_0_tunnel_visual_artifact_gate")
        )
        captures = [
            run_tunnel_visual_artifact_gate(
                godot,
                project,
                profile,
                output_dir,
                args.visual_wait_frames,
            )
            for profile in tunnel_visual_artifact_profiles
        ]
        print(
            "WT_PRODUCTION_INTEGRATION_GAME_TUNNEL_VISUAL_ARTIFACT_GATE_PASS captures=%d dir=%s"
            % (len(captures), output_dir)
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
