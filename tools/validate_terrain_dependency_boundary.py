#!/usr/bin/env python3
"""Validate the accepted integration terrain dependency boundary."""

from __future__ import annotations

import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
ACCEPTED_AUTHORITY = "8acd7ca3d0ac794809abb113a2c88f7d22344f09"
COMPATIBILITY_BASE = "4f1fdb59e3c6200c8f823b99027b2d3f15563858"
RUNTIME_SCENE = (
    ROOT
    / "addons"
    / "world_transvoxel_terrain"
    / "runtime"
    / "wt_terrain_runtime_scene.tscn"
)
RUNTIME_SCRIPT = RUNTIME_SCENE.with_suffix(".gd")
GAME_WORLD = (
    ROOT
    / "addons"
    / "world_transvoxel_gameworld"
    / "wt_game_world_node.gd"
)
NATIVE_ROOT = ROOT / "addons" / "world_transvoxel"
NATIVE_SOURCE_SUFFIXES = {".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp"}
DIRECT_BACKEND_EXCEPTION_PATHS = {
    "addons/world_transvoxel_gameworld/material/wt_game_terrain_material_applicator.gd",
    "addons/world_transvoxel_gameworld/wt_game_world_node.gd",
    "addons/world_transvoxel_terrain/debug/wt_terrain_large_acceptance_presentation.gd",
    "addons/world_transvoxel_terrain/debug/wt_terrain_lod_audit.gd",
    "addons/world_transvoxel_terrain/debug/wt_terrain_mesh_stats.gd",
    "addons/world_transvoxel_terrain/material/wt_terrain_material_applicator.gd",
    "addons/world_transvoxel_terrain/runtime/wt_terrain_world.gd",
    "scripts/main.gd",
    "scripts/wt_cpu_b3a_lod_opening_capture.gd",
    "scripts/wt_production_player.gd",
}


def load_json(relative: str) -> dict:
    return json.loads((ROOT / relative).read_text(encoding="utf-8"))


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    runtime_pin = load_json("WORLD_TRANSVOXEL_RUNTIME_PIN.json")
    authority = runtime_pin.get("authority", {})
    artifact = runtime_pin.get("runtime_artifact", {})
    require(
        authority.get("commit") == ACCEPTED_AUTHORITY,
        "unexpected accepted authority revision",
    )
    require(authority.get("fallback") is False, "native fallback must remain disabled")
    require(
        artifact.get("native_source_included") is False,
        "runtime artifact must remain binary-only",
    )
    require(
        artifact.get("binary_build_commit") == ACCEPTED_AUTHORITY,
        "runtime binary does not match the accepted authority revision",
    )

    terrain_boundary = load_json(
        "addons/world_transvoxel_terrain/BOUNDARY_CONTRACT.json"
    )
    dependency = terrain_boundary.get("dependency", {})
    require(
        dependency.get("required_revision") == COMPATIBILITY_BASE,
        "terrain compatibility snapshot has an unexpected authority base",
    )
    require(
        dependency.get("fallback_mesher") is False,
        "terrain compatibility snapshot must not contain a fallback mesher",
    )

    require(RUNTIME_SCENE.is_file(), "production terrain runtime scene is missing")
    require(RUNTIME_SCRIPT.is_file(), "production terrain runtime script is missing")
    runtime_text = RUNTIME_SCRIPT.read_text(encoding="utf-8")
    for forbidden in ("/debug/", "DebugOverlay", "CanvasLayer", "ReferenceScene"):
        require(
            forbidden not in runtime_text,
            "production terrain runtime contains diagnostic dependency: %s" % forbidden,
        )

    game_world_text = GAME_WORLD.read_text(encoding="utf-8")
    require(
        "runtime/wt_terrain_runtime_scene.tscn" in game_world_text,
        "GameWorld does not instantiate the production terrain runtime scene",
    )
    require(
        "world_transvoxel_terrain/debug/" not in game_world_text,
        "GameWorld production path depends on a terrain debug scene",
    )
    require(
        '"start_runtime_world"' in game_world_text,
        "GameWorld does not start terrain through the production runtime contract",
    )

    native_sources = sorted(
        path.relative_to(ROOT).as_posix()
        for path in NATIVE_ROOT.rglob("*")
        if path.is_file() and path.suffix.lower() in NATIVE_SOURCE_SUFFIXES
    )
    require(
        not native_sources,
        "integration repository contains forbidden native source: %s"
        % ", ".join(native_sources),
    )

    direct_backend_paths = {
        path.relative_to(ROOT).as_posix()
        for parent in (ROOT / "addons", ROOT / "scripts")
        for path in parent.rglob("*.gd")
        if "get_backend_terrain" in path.read_text(encoding="utf-8")
    }
    unexpected_backend_paths = sorted(
        direct_backend_paths - DIRECT_BACKEND_EXCEPTION_PATHS
    )
    require(
        not unexpected_backend_paths,
        "unclassified direct native-backend access: %s"
        % ", ".join(unexpected_backend_paths),
    )

    sync_text = (ROOT / "tools" / "sync_tqp54_candidate.py").read_text(
        encoding="utf-8"
    )
    require(
        "--allow-candidate-refresh" in sync_text,
        "candidate synchronization lacks the explicit lineage guard",
    )

    documentation = (ROOT / "docs" / "TERRAIN_DEPENDENCY_BOUNDARY.md")
    require(documentation.is_file(), "dependency boundary document is missing")
    print(
        "WT_TERRAIN_DEPENDENCY_BOUNDARY_PASS "
        "authority=8acd7ca compatibility_base=4f1fdb5 "
        "runtime_scene=production native_source=0 fallback=false "
        "direct_backend_paths=%d" % len(direct_backend_paths)
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print("WT_TERRAIN_DEPENDENCY_BOUNDARY_FAIL %s" % error, file=sys.stderr)
        sys.exit(1)
