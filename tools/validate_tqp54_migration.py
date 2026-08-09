#!/usr/bin/env python3
"""Validate the TQP-54 downstream package and ownership contract."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess

import sync_tqp54_candidate as package_sync


ROOT = Path(__file__).resolve().parents[1]
PIN_PATH = ROOT / "TQP54_PACKAGE_PIN.json"
CONTRACT_PATH = ROOT / "TQP54_MIGRATION_CONTRACT.json"
EVIDENCE_PATH = ROOT / "docs" / "evidence" / "tqp54_migration_windows.json"
CANDIDATE_REPO = ROOT.parent / "world-transvoxel-terrain"
AUTHORITY_REPO = ROOT.parent / "world-transvoxel"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def load_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def git_value(repository: Path, revision: str) -> str:
    return subprocess.check_output(
        [
            "git",
            "-c",
            f"safe.directory={repository.as_posix()}",
            "-C",
            str(repository),
            "rev-parse",
            revision,
        ],
        text=True,
    ).strip()


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def combined_sources(roots: tuple[Path, ...]) -> str:
    parts: list[str] = []
    for root in roots:
        for pattern in ("*.gd", "*.gdshader", "*.py"):
            for path in root.rglob(pattern):
                parts.append(text(path))
    return "\n".join(parts)


def validate_package(
    label: str,
    source: Path,
    target: Path,
    pin: dict[str, object],
) -> None:
    missing, extra, changed = package_sync.differences(source, target)
    require(
        not missing and not extra and not changed,
        "%s package drift: missing=%d extra=%d changed=%d"
        % (label, len(missing), len(extra), len(changed)),
    )
    require(
        package_sync.package_digest(package_sync.source_package_files(source))
        == pin["package_digest_sha256"],
        "%s source package digest drifted" % label,
    )
    require(
        package_sync.package_digest(package_sync.package_files(target))
        == pin["package_digest_sha256"],
        "%s vendored package digest drifted" % label,
    )
    require(
        len(package_sync.source_package_files(source)) == int(pin["files"]),
        "%s source file count drifted" % label,
    )


def main() -> None:
    pin = load_json(PIN_PATH)
    contract = load_json(CONTRACT_PATH)
    evidence = load_json(EVIDENCE_PATH)
    require(pin.get("status") == "QUALIFIED", "package pin is not qualified")
    require(contract.get("status") == "QUALIFIED", "migration contract is not qualified")
    require(evidence.get("status") == "PASS", "retained migration evidence is not passing")
    require(
        contract.get("engine_policy", {}).get("minimum_version") == "4.7"
        and contract.get("engine_policy", {}).get("current_qualification_matrix") == ["4.7"],
        "Godot qualification policy must target only 4.7",
    )

    candidate = pin["candidate"]
    authority = pin["authority"]
    require(isinstance(candidate, dict), "candidate pin is malformed")
    require(isinstance(authority, dict), "authority pin is malformed")
    require(git_value(CANDIDATE_REPO, "HEAD") == candidate["commit"], "candidate commit drifted")
    require(
        git_value(CANDIDATE_REPO, "HEAD:addons/world_transvoxel_terrain")
        == candidate["addon_tree"],
        "candidate addon tree drifted",
    )
    require(git_value(AUTHORITY_REPO, "HEAD") == authority["commit"], "authority commit drifted")
    require(
        git_value(AUTHORITY_REPO, "HEAD:addons/world_transvoxel")
        == authority["addon_tree"],
        "authority addon tree drifted",
    )
    validate_package(
        "candidate",
        CANDIDATE_REPO / "addons" / "world_transvoxel_terrain",
        ROOT / "addons" / "world_transvoxel_terrain",
        candidate,
    )
    validate_package(
        "authority",
        AUTHORITY_REPO / "addons" / "world_transvoxel",
        ROOT / "addons" / "world_transvoxel",
        authority,
    )

    main_source = text(ROOT / "scripts" / "main.gd")
    quality_source = text(ROOT / "tools" / "p2_production_integration_game_quality.py")
    storage_source = text(
        ROOT
        / "addons"
        / "world_transvoxel_terrain"
        / "storage"
        / "wt_terrain_storage_profile.gd"
    )
    require(
        "addons/world_transvoxel_gameworld/material/wt_game_terrain_material_applicator.gd"
        in main_source,
        "main scene does not own game material presentation through gameworld",
    )
    require(
        "addons/world_transvoxel_gameworld/debug/wt_game_terrain_topology_probe.gd"
        in main_source,
        "main scene does not own deep topology diagnostics through gameworld",
    )
    require(
        "addons/world_transvoxel_gameworld/material/wt_game_terrain_palette.gdshader"
        in quality_source,
        "quality gate does not use the gameworld material shader",
    )
    require("timeout=timeout_seconds" in quality_source, "deep profile is not bounded")
    require(
        "get_effective_edit_journal_path" in storage_source
        and "persist_edits=false is unsupported" in storage_source,
        "candidate storage profile does not fail closed",
    )

    game_sources = combined_sources(
        (ROOT / "scripts", ROOT / "addons" / "world_transvoxel_gameworld")
    )
    candidate_sources = combined_sources((ROOT / "addons" / "world_transvoxel_terrain",))
    require("WorldTransvoxelTerrain" not in game_sources, "game bypasses WtTerrainWorld")
    for forbidden in ("REFERENCE_ROAD_SEGMENTS", "EXPANSIVE_ROAD_SEGMENTS", "collect_precise"):
        require(forbidden not in candidate_sources, "candidate contains game-specific token: %s" % forbidden)
    for required in ("REFERENCE_ROAD_SEGMENTS", "EXPANSIVE_ROAD_SEGMENTS", "collect_precise"):
        require(required in game_sources, "gameworld presentation/debug token missing: %s" % required)

    rules = contract.get("migration_rules", [])
    require(isinstance(rules, list) and len(rules) == 4, "migration rules are incomplete")
    require(
        [item.get("engine") for item in evidence.get("project_imports", [])] == ["4.7"]
        and [item.get("engine") for item in evidence.get("runtime_smokes", [])] == ["4.7"],
        "retained Godot 4.7 evidence is incomplete",
    )
    print(
        "WT_TQP54_MIGRATION_CONTRACT_PASS candidate_files=%d authority_files=%d engines=1 boundary=gameworld"
        % (int(candidate["files"]), int(authority["files"]))
    )


if __name__ == "__main__":
    main()
