#!/usr/bin/env python3
"""Refresh and verify Godot asset imports for the integration game.

Godot texture import settings live in tracked ``*.import`` files, but the actual
runtime texture consumed by the engine is generated under ``.godot/imported``.
This tool makes that cache refresh an explicit project gate instead of a manual
editor side effect.
"""

from __future__ import annotations

import argparse
import ast
import os
import pathlib
import shutil
import subprocess
import sys


WINDOWS_STEAM_GODOT = pathlib.Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
)

REQUIRED_TEXTURE_IMPORTS = {
    "assets/terrain_textures/coast_sand_01_diff_1k.jpg.import": {
        "mipmaps/generate": "true",
        "compress/normal_map": "0",
    },
}


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


def run_godot_import(godot: pathlib.Path, project: pathlib.Path) -> None:
    cmd = [str(godot), "--headless", "--path", str(project), "--import"]
    print("importing:", " ".join(cmd), flush=True)
    completed = subprocess.run(cmd, cwd=project, text=True, capture_output=True)
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        raise subprocess.CalledProcessError(completed.returncode, cmd)


def parse_import_file(path: pathlib.Path) -> dict[str, object]:
    result: dict[str, object] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("[") or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key.strip()] = parse_import_value(value.strip())
    return result


def parse_import_value(value: str) -> object:
    if value == "true":
        return True
    if value == "false":
        return False
    if value.startswith("PackedStringArray("):
        return value
    try:
        return ast.literal_eval(value)
    except (SyntaxError, ValueError):
        return value


def res_path_to_file(project: pathlib.Path, value: object) -> pathlib.Path:
    if not isinstance(value, str) or not value.startswith("res://"):
        raise RuntimeError(f"expected res:// path, got {value!r}")
    return project / value.removeprefix("res://")


def verify_imports(project: pathlib.Path) -> None:
    failures: list[str] = []
    for relative, expected_flags in REQUIRED_TEXTURE_IMPORTS.items():
        import_path = project / relative
        if not import_path.is_file():
            failures.append(f"missing import file: {relative}")
            continue
        parsed = parse_import_file(import_path)
        for key, expected_text in expected_flags.items():
            expected_value = parse_import_value(expected_text)
            actual_value = parsed.get(key)
            if actual_value != expected_value:
                failures.append(
                    f"{relative}: {key} expected {expected_value!r}, got {actual_value!r}"
                )
        source_path = res_path_to_file(project, parsed.get("source_file"))
        if not source_path.is_file():
            failures.append(f"{relative}: missing source texture {source_path}")
            continue
        dest_files = parsed.get("dest_files")
        if not isinstance(dest_files, list) or not dest_files:
            failures.append(f"{relative}: no dest_files declared")
            continue
        required_mtime = max(import_path.stat().st_mtime, source_path.stat().st_mtime)
        for dest_value in dest_files:
            dest_path = res_path_to_file(project, dest_value)
            if not dest_path.is_file():
                failures.append(f"{relative}: imported artifact missing {dest_path}")
                continue
            if dest_path.stat().st_mtime + 0.5 < required_mtime:
                failures.append(
                    f"{relative}: imported artifact is stale {dest_path}; "
                    "run Godot --import"
                )
    if failures:
        raise RuntimeError("\n".join(failures))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", help="Path to a Godot 4 executable.")
    parser.add_argument(
        "--project",
        default=str(repo_root()),
        help="Path to the integration game project directory.",
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="Only verify current imported artifacts; do not run Godot --import.",
    )
    args = parser.parse_args(argv)

    project = pathlib.Path(args.project).resolve()
    if not args.verify_only:
        run_godot_import(find_godot(args.godot), project)
    verify_imports(project)
    print("WT_GODOT_IMPORT_ASSETS_PASS required_imports=%d" % len(REQUIRED_TEXTURE_IMPORTS))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
