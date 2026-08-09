#!/usr/bin/env python3
"""Synchronize vendored terrain packages with their standalone authorities."""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import shutil
import subprocess
import sys


IGNORED_NAMES = {"__pycache__"}
IGNORED_SUFFIXES = {".pyc", ".pyo"}
GENERATED_RUNTIME_FILES = {
    "world_transvoxel": (
        "bin/world_transvoxel.windows.template_debug.x86_64.dll",
        "bin/world_transvoxel.windows.template_release.x86_64.dll",
    ),
}


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[1]


def default_source() -> pathlib.Path:
    return repo_root().parent / "world-transvoxel-terrain" / "addons" / "world_transvoxel_terrain"


def default_authority_source() -> pathlib.Path:
    return repo_root().parent / "world-transvoxel" / "addons" / "world_transvoxel"


def package_files(root: pathlib.Path) -> dict[pathlib.PurePosixPath, pathlib.Path]:
    result: dict[pathlib.PurePosixPath, pathlib.Path] = {}
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if any(part in IGNORED_NAMES for part in relative.parts):
            continue
        if path.is_file() and path.suffix not in IGNORED_SUFFIXES:
            result[pathlib.PurePosixPath(relative.as_posix())] = path
    return result


def containing_repository(path: pathlib.Path) -> pathlib.Path:
    for candidate in (path, *path.parents):
        if (candidate / ".git").exists():
            return candidate
    raise RuntimeError("Git repository not found for %s" % path)


def tracked_package_files(root: pathlib.Path) -> dict[pathlib.PurePosixPath, pathlib.Path]:
    repository_hint = containing_repository(root)
    repository = pathlib.Path(
        subprocess.check_output(
            [
                "git",
                "-c",
                "safe.directory=%s" % repository_hint.as_posix(),
                "-C",
                str(root),
                "rev-parse",
                "--show-toplevel",
            ],
            text=True,
        ).strip()
    )
    prefix = root.relative_to(repository).as_posix()
    output = subprocess.check_output(
        [
            "git",
            "-c",
            "safe.directory=%s" % repository.as_posix(),
            "-C",
            str(repository),
            "ls-files",
            "--",
            prefix,
        ],
        text=True,
    )
    result: dict[pathlib.PurePosixPath, pathlib.Path] = {}
    for line in output.splitlines():
        repository_relative = pathlib.PurePosixPath(line)
        package_relative = repository_relative.relative_to(prefix)
        path = repository / pathlib.Path(repository_relative)
        if path.is_file():
            result[package_relative] = path
    return result


def source_package_files(root: pathlib.Path) -> dict[pathlib.PurePosixPath, pathlib.Path]:
    result = tracked_package_files(root)
    for relative_text in GENERATED_RUNTIME_FILES.get(root.name, ()):
        relative = pathlib.PurePosixPath(relative_text)
        path = root / pathlib.Path(relative)
        if not path.is_file():
            raise RuntimeError("required generated runtime file is missing: %s" % path)
        result[relative] = path
    return result


def digest(path: pathlib.Path) -> str:
    value = hashlib.sha256()
    value.update(canonical_bytes(path))
    return value.hexdigest()


def canonical_bytes(path: pathlib.Path) -> bytes:
    content = path.read_bytes()
    if b"\0" in content:
        return content
    try:
        content.decode("utf-8")
    except UnicodeDecodeError:
        return content
    return content.replace(b"\r\n", b"\n")


def package_digest(files: dict[pathlib.PurePosixPath, pathlib.Path]) -> str:
    value = hashlib.sha256()
    for relative, path in sorted(files.items()):
        value.update(str(relative).encode("utf-8"))
        value.update(b"\0")
        value.update(canonical_bytes(path))
        value.update(b"\0")
    return value.hexdigest()


def differences(source: pathlib.Path, target: pathlib.Path) -> tuple[list[str], list[str], list[str]]:
    source_files = source_package_files(source)
    target_files = package_files(target)
    missing = sorted(str(path) for path in source_files.keys() - target_files.keys())
    extra = sorted(str(path) for path in target_files.keys() - source_files.keys())
    changed = sorted(
        str(path)
        for path in source_files.keys() & target_files.keys()
        if digest(source_files[path]) != digest(target_files[path])
    )
    return missing, extra, changed


def synchronize(source: pathlib.Path, target: pathlib.Path) -> None:
    source_files = source_package_files(source)
    target_files = package_files(target)
    for relative in sorted(target_files.keys() - source_files.keys()):
        target_files[relative].unlink()
    for relative, source_path in sorted(source_files.items()):
        target_path = target / pathlib.Path(relative)
        target_path.parent.mkdir(parents=True, exist_ok=True)
        if not target_path.exists() or digest(source_path) != digest(target_path):
            shutil.copy2(source_path, target_path)
    directories = sorted(
        (path for path in target.rglob("*") if path.is_dir()),
        key=lambda path: len(path.parts),
        reverse=True,
    )
    for directory in directories:
        try:
            directory.rmdir()
        except OSError:
            pass


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate-source", type=pathlib.Path, default=default_source())
    parser.add_argument("--authority-source", type=pathlib.Path, default=default_authority_source())
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args(argv)
    packages = {
        "candidate": (
            args.candidate_source.resolve(),
            (repo_root() / "addons" / "world_transvoxel_terrain").resolve(),
        ),
        "authority": (
            args.authority_source.resolve(),
            (repo_root() / "addons" / "world_transvoxel").resolve(),
        ),
    }
    for label, (source, target) in packages.items():
        expected_target = (repo_root() / "addons" / target.name).resolve()
        if target != expected_target or target.parent != (repo_root() / "addons").resolve():
            raise RuntimeError("refusing unexpected %s target: %s" % (label, target))
        if not source.is_dir() or not (source / "plugin.cfg").is_file():
            raise RuntimeError("%s source is not an addon: %s" % (label, source))
        if args.apply:
            synchronize(source, target)
        missing, extra, changed = differences(source, target)
        if missing or extra or changed:
            print("WT_TQP54_PACKAGE_SYNC_FAIL package=%s missing=%d extra=%d changed=%d" % (
                label, len(missing), len(extra), len(changed)
            ))
            for category, values in (("missing", missing), ("extra", extra), ("changed", changed)):
                for value in values:
                    print("%s: %s" % (category, value))
            return 1
    print("WT_TQP54_PACKAGE_SYNC_PASS candidate_files=%d authority_files=%d candidate_digest=%s authority_digest=%s" % (
        len(source_package_files(packages["candidate"][0])),
        len(source_package_files(packages["authority"][0])),
        package_digest(source_package_files(packages["candidate"][0])),
        package_digest(source_package_files(packages["authority"][0])),
    ))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
