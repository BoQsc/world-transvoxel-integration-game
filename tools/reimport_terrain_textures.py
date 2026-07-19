#!/usr/bin/env python3
"""Force a normal Godot reimport of every authored terrain texture."""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

import godot_import_assets


TERRAIN_TEXTURE_ROOT = pathlib.Path("assets/terrain_textures")
TEXTURE_EXTENSIONS = frozenset({".png", ".jpg", ".jpeg", ".webp"})
GODOT_REIMPORT_SCENE = "res://tools/reimport_terrain_textures.tscn"


def find_terrain_textures(project: pathlib.Path) -> list[pathlib.Path]:
    texture_root = project / TERRAIN_TEXTURE_ROOT
    if not texture_root.is_dir():
        raise FileNotFoundError(f"Terrain texture directory does not exist: {texture_root}")
    return sorted(
        path
        for path in texture_root.rglob("*")
        if path.is_file() and path.suffix.lower() in TEXTURE_EXTENSIONS
    )


def verify_terrain_imports(
    project: pathlib.Path, textures: list[pathlib.Path]
) -> None:
    failures: list[str] = []
    for texture in textures:
        import_path = pathlib.Path(f"{texture}.import")
        relative_texture = texture.relative_to(project)
        if not import_path.is_file():
            failures.append(f"missing import metadata: {relative_texture}.import")
            continue

        parsed = godot_import_assets.parse_import_file(import_path)
        dest_files = parsed.get("dest_files")
        if not isinstance(dest_files, list) or not dest_files:
            failures.append(f"no imported artifacts declared: {relative_texture}.import")
            continue

        required_mtime = max(texture.stat().st_mtime, import_path.stat().st_mtime)
        for dest_value in dest_files:
            try:
                dest_path = godot_import_assets.res_path_to_file(project, dest_value)
            except RuntimeError as error:
                failures.append(f"{relative_texture}.import: {error}")
                continue
            if not dest_path.is_file():
                failures.append(f"missing imported artifact: {dest_path}")
            elif dest_path.stat().st_mtime + 0.5 < required_mtime:
                failures.append(f"stale imported artifact: {dest_path}")

    if failures:
        raise RuntimeError("\n".join(failures))


def run_explicit_reimport(
    godot: pathlib.Path, project: pathlib.Path, textures: list[pathlib.Path]
) -> None:
    resource_paths = [
        "res://" + texture.relative_to(project).as_posix() for texture in textures
    ]
    cmd = [
        str(godot),
        "--headless",
        "--editor",
        "--path",
        str(project),
        GODOT_REIMPORT_SCENE,
        "--",
        *resource_paths,
    ]
    print("reimporting:", " ".join(cmd), flush=True)
    completed = subprocess.run(cmd, cwd=project, text=True)
    if completed.returncode != 0:
        raise subprocess.CalledProcessError(completed.returncode, cmd)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Force Godot to reimport assets/terrain_textures recursively."
    )
    parser.add_argument("--godot", help="Path to a Godot 4 executable.")
    parser.add_argument(
        "--project",
        default=str(godot_import_assets.repo_root()),
        help="Path to the integration game project directory.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List the textures that would be reimported without changing anything.",
    )
    args = parser.parse_args(argv)

    project = pathlib.Path(args.project).resolve()
    textures = find_terrain_textures(project)
    if not textures:
        raise RuntimeError(f"No terrain textures found under {project / TERRAIN_TEXTURE_ROOT}")

    for texture in textures:
        print(texture.relative_to(project))
    if args.dry_run:
        print(f"WT_TERRAIN_TEXTURE_REIMPORT_DRY_RUN textures={len(textures)}")
        return 0

    godot = godot_import_assets.find_godot(args.godot)
    run_explicit_reimport(godot, project, textures)
    godot_import_assets.verify_imports(project)
    verify_terrain_imports(project, textures)
    print(f"WT_TERRAIN_TEXTURE_REIMPORT_PASS textures={len(textures)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
