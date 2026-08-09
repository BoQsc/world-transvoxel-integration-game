#!/usr/bin/env python3
"""Run the focused downstream migration proof on supported Godot engines."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT.parent / "world-transvoxel"
LIFECYCLE_FIXTURE = UPSTREAM / "build" / "production-lifecycle-fixture"
ARTIFACT_ROOT = ROOT / "artifacts" / "tqp54_migration"
FIXTURE_ROOT = ARTIFACT_ROOT / "project"
SCRIPT = "res://tests/tqp54_migration_smoke.gd"
MARKER = "WT_TQP54_MIGRATION_GODOT_PASS"
ENGINE_VERSIONS = ("4.6.3", "4.7")


def discover_engines(explicit: list[Path]) -> list[tuple[str, Path]]:
    if explicit:
        return [(path.stem, path.resolve()) for path in explicit]
    discovered: list[tuple[str, Path]] = []
    for version in ENGINE_VERSIONS:
        pattern = UPSTREAM / ".tools" / "godot" / version
        candidates = sorted(pattern.glob("Godot*_win64.exe"))
        if candidates:
            discovered.append((version, candidates[0].resolve()))
    if discovered:
        return discovered
    environment = os.environ.get("GODOT")
    if environment:
        return [("environment", Path(environment).resolve())]
    raise RuntimeError("No supported Godot executable found")


def prepare_fixture() -> None:
    if not (LIFECYCLE_FIXTURE / "streaming.wtworld").is_file():
        raise RuntimeError("world-transvoxel lifecycle fixture is missing")
    if FIXTURE_ROOT.exists():
        shutil.rmtree(FIXTURE_ROOT)
    for addon in (
        "world_transvoxel",
        "world_transvoxel_terrain",
        "world_transvoxel_gameworld",
    ):
        shutil.copytree(
            ROOT / "addons" / addon,
            FIXTURE_ROOT / "addons" / addon,
            ignore=shutil.ignore_patterns("__pycache__"),
        )
    shutil.copytree(
        LIFECYCLE_FIXTURE,
        FIXTURE_ROOT / "build" / "production-lifecycle-fixture",
        ignore=shutil.ignore_patterns("*.wtedit"),
    )
    (FIXTURE_ROOT / "tests").mkdir(parents=True, exist_ok=True)
    shutil.copy2(
        ROOT / "tests" / "tqp54_migration_smoke.gd",
        FIXTURE_ROOT / "tests",
    )
    (FIXTURE_ROOT / "project.godot").write_text(
        "\n".join(
            [
                "config_version=5",
                "",
                "[application]",
                'config/name="TQP-54 Migration Fixture"',
                'config/features=PackedStringArray("4.6", "Forward Plus")',
                "",
                "[editor_plugins]",
                'enabled=PackedStringArray("res://addons/world_transvoxel/plugin.cfg", "res://addons/world_transvoxel_terrain/plugin.cfg", "res://addons/world_transvoxel_gameworld/plugin.cfg")',
                "",
            ]
        ),
        encoding="utf-8",
    )


def has_error(output: str) -> bool:
    return (
        "SCRIPT ERROR:" in output
        or output.startswith("ERROR:")
        or "\nERROR:" in output
    )


def run_project_import(version: str, engine: Path) -> dict[str, str]:
    attempts: list[str] = []
    result: subprocess.CompletedProcess[str] | None = None
    for _attempt in range(2):
        result = subprocess.run(
            [str(engine), "--headless", "--path", str(ROOT), "--import"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            errors="replace",
            timeout=120,
        )
        attempts.append(result.stdout + result.stderr)
        if result.returncode == 0 and not has_error(attempts[-1]):
            break
    output = "\n".join(attempts)
    (ARTIFACT_ROOT / f"godot-{version}-project-import.log").write_text(
        output, encoding="utf-8"
    )
    if result is None or result.returncode != 0 or has_error(output):
        raise RuntimeError(
            "TQP-54 project import failed on Godot %s returncode=%d"
            % (version, result.returncode if result is not None else -1)
        )
    print("WT_TQP54_PROJECT_IMPORT_PASS engine=%s" % version)
    return {"engine": version, "status": "PASS"}


def run_engine(version: str, engine: Path) -> dict[str, str]:
    import_attempts: list[str] = []
    import_result: subprocess.CompletedProcess[str] | None = None
    extension_cache = FIXTURE_ROOT / ".godot" / "extension_list.cfg"
    for _attempt in range(2):
        import_result = subprocess.run(
            [str(engine), "--headless", "--path", str(FIXTURE_ROOT), "--import"],
            cwd=FIXTURE_ROOT,
            text=True,
            capture_output=True,
            errors="replace",
            timeout=120,
        )
        import_attempts.append(import_result.stdout + import_result.stderr)
        if import_result.returncode == 0 and not has_error(import_attempts[-1]):
            break
    import_output = "\n".join(import_attempts)
    (ARTIFACT_ROOT / f"godot-{version}-import.log").write_text(
        import_output, encoding="utf-8"
    )
    if (
        import_result is None
        or import_result.returncode != 0
        or has_error(import_output)
        or not extension_cache.is_file()
    ):
        raise RuntimeError(
            "TQP-54 import failed on Godot %s returncode=%d detected_error=%s"
            % (
                version,
                import_result.returncode if import_result is not None else -1,
                has_error(import_output),
            )
        )
    smoke_result = subprocess.run(
        [
            str(engine),
            "--headless",
            "--path",
            str(FIXTURE_ROOT),
            "--script",
            SCRIPT,
        ],
        cwd=FIXTURE_ROOT,
        text=True,
        capture_output=True,
        errors="replace",
        timeout=180,
    )
    smoke_output = smoke_result.stdout + smoke_result.stderr
    (ARTIFACT_ROOT / f"godot-{version}-smoke.log").write_text(
        smoke_output, encoding="utf-8"
    )
    print(smoke_output, end="" if smoke_output.endswith("\n") else "\n")
    if (
        smoke_result.returncode != 0
        or MARKER not in smoke_output
        or has_error(smoke_output)
    ):
        raise RuntimeError(f"TQP-54 migration smoke failed on Godot {version}")
    marker = next(
        line for line in smoke_output.splitlines() if line.startswith(MARKER)
    )
    return {"engine": version, "executable": str(engine), "marker": marker}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", type=Path, action="append", default=[])
    args = parser.parse_args()
    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    prepare_fixture()
    engines = discover_engines(args.godot)
    project_imports = [
        run_project_import(version, engine) for version, engine in engines
    ]
    results = [run_engine(version, engine) for version, engine in engines]
    report = ARTIFACT_ROOT / "tqp54_migration_report.json"
    report.write_text(
        json.dumps(
            {
                "schema": "world_transvoxel.tqp54_migration_evidence.v1",
                "status": "PASS",
                "project_imports": project_imports,
                "engines": results,
                "implementation": "exact_package_runtime_migration",
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(
        "WT_TQP54_MIGRATION_QUALIFICATION_PASS engines=%d report=%s"
        % (len(results), report.relative_to(ROOT).as_posix())
    )


if __name__ == "__main__":
    main()
