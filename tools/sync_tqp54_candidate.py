#!/usr/bin/env python3
"""Synchronize downstream packages with their standalone authorities.

The terrain addon is synchronized as source. The native World Transvoxel
authority is synchronized as a strict binary runtime artifact; its C++ source
remains exclusively in the authority repository.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

import world_transvoxel_runtime_artifact as runtime_artifact


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


def repository_head(path: pathlib.Path) -> str:
    repository = containing_repository(path)
    return subprocess.check_output(
        ["git", "-C", str(repository), "rev-parse", "HEAD"],
        text=True,
    ).strip()


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


def authority_runtime_files(
    root: pathlib.Path,
) -> dict[pathlib.PurePosixPath, pathlib.Path]:
    return runtime_artifact.files(root)


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
    return selected_differences(source_package_files(source), target)


def selected_differences(
    source_files: dict[pathlib.PurePosixPath, pathlib.Path],
    target: pathlib.Path,
) -> tuple[list[str], list[str], list[str]]:
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
    synchronize_selected(source_package_files(source), target)


def synchronize_selected(
    source_files: dict[pathlib.PurePosixPath, pathlib.Path],
    target: pathlib.Path,
) -> None:
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
    parser.add_argument(
        "--package",
        choices=("authority", "candidate", "all"),
        default="authority",
        help="Package to synchronize; native authority runtime is the safe default.",
    )
    parser.add_argument(
        "--allow-unpinned-authority",
        action="store_true",
        help="Allow an intentional artifact refresh before updating the runtime pin.",
    )
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args(argv)
    packages = {
        "candidate": (
            args.candidate_source.resolve(),
            (repo_root() / "addons" / "world_transvoxel_terrain").resolve(),
            source_package_files,
        ),
        "authority": (
            args.authority_source.resolve(),
            (repo_root() / "addons" / "world_transvoxel").resolve(),
            authority_runtime_files,
        ),
    }
    package_results: dict[
        str, dict[pathlib.PurePosixPath, pathlib.Path]
    ] = {}
    for label, (source, target, select_files) in packages.items():
        if args.package != "all" and label != args.package:
            continue
        expected_target = (repo_root() / "addons" / target.name).resolve()
        if target != expected_target or target.parent != (repo_root() / "addons").resolve():
            raise RuntimeError("refusing unexpected %s target: %s" % (label, target))
        identity_file = "plugin.cfg" if label == "candidate" else "world_transvoxel.gdextension"
        if not source.is_dir() or not (source / identity_file).is_file():
            raise RuntimeError("%s source is not an addon: %s" % (label, source))
        if label == "authority" and not args.allow_unpinned_authority:
            pin = json.loads(
                (repo_root() / "WORLD_TRANSVOXEL_RUNTIME_PIN.json").read_text(
                    encoding="utf-8"
                )
            )
            expected_commit = str(pin.get("authority", {}).get("commit", ""))
            actual_commit = repository_head(source)
            if actual_commit != expected_commit:
                raise RuntimeError(
                    "authority source is not the active runtime pin: "
                    "%s != %s; pass --allow-unpinned-authority only for an "
                    "intentional refresh" % (actual_commit, expected_commit)
                )
        selected = select_files(source)
        if args.apply:
            synchronize_selected(selected, target)
        missing, extra, changed = selected_differences(selected, target)
        if missing or extra or changed:
            print("WT_AUTHORITY_PACKAGE_SYNC_FAIL package=%s missing=%d extra=%d changed=%d" % (
                label, len(missing), len(extra), len(changed)
            ))
            for category, values in (("missing", missing), ("extra", extra), ("changed", changed)):
                for value in values:
                    print("%s: %s" % (category, value))
            return 1
        package_results[label] = selected
    summaries = [
        "%s_files=%d %s_digest=%s" % (
            label,
            len(files),
            label,
            package_digest(files),
        )
        for label, files in sorted(package_results.items())
    ]
    print("WT_AUTHORITY_PACKAGE_SYNC_PASS " + " ".join(summaries))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
