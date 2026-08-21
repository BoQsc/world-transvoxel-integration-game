#!/usr/bin/env python3
"""Define and validate the binary-only World Transvoxel runtime artifact."""

from __future__ import annotations

import hashlib
from pathlib import Path, PurePosixPath


STATIC_RUNTIME_PATHS = (
    PurePosixPath("LICENSE_SCOPE.md"),
    PurePosixPath("OPERATING_LIMITS.md"),
    PurePosixPath("PUBLIC_API.md"),
    PurePosixPath("README.md"),
    PurePosixPath("thirdparty/transvoxel_mit/LICENSE"),
    PurePosixPath("thirdparty/transvoxel_mit/UPSTREAM.md"),
    PurePosixPath("world_transvoxel.gdextension"),
    PurePosixPath("world_transvoxel.gdextension.uid"),
)

GENERATED_RUNTIME_PATHS = (
    PurePosixPath("bin/world_transvoxel.windows.template_debug.x86_64.dll"),
    PurePosixPath("bin/world_transvoxel.windows.template_release.x86_64.dll"),
)

RUNTIME_PATHS = STATIC_RUNTIME_PATHS + GENERATED_RUNTIME_PATHS
NATIVE_SOURCE_SUFFIXES = {".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp"}


def canonical_bytes(path: Path) -> bytes:
    content = path.read_bytes()
    if b"\0" in content:
        return content
    try:
        content.decode("utf-8")
    except UnicodeDecodeError:
        return content
    return content.replace(b"\r\n", b"\n")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def artifact_digest(root: Path) -> str:
    value = hashlib.sha256()
    for relative in sorted(RUNTIME_PATHS):
        path = root / Path(relative)
        if not path.is_file():
            raise RuntimeError(f"runtime artifact file is missing: {path}")
        value.update(relative.as_posix().encode("utf-8"))
        value.update(b"\0")
        value.update(canonical_bytes(path))
        value.update(b"\0")
    return value.hexdigest()


def files(root: Path) -> dict[PurePosixPath, Path]:
    result: dict[PurePosixPath, Path] = {}
    for relative in RUNTIME_PATHS:
        path = root / Path(relative)
        if not path.is_file():
            raise RuntimeError(f"runtime artifact file is missing: {path}")
        result[relative] = path
    return result


def validate_binary_consumer_layout(root: Path) -> None:
    actual = {
        PurePosixPath(path.relative_to(root).as_posix())
        for path in root.rglob("*")
        if path.is_file() and "__pycache__" not in path.parts
    }
    expected = set(RUNTIME_PATHS)
    missing = sorted(path.as_posix() for path in expected - actual)
    extra = sorted(path.as_posix() for path in actual - expected)
    native_source = sorted(
        path.as_posix()
        for path in actual
        if path.suffix.lower() in NATIVE_SOURCE_SUFFIXES
    )
    if missing or extra or native_source:
        raise RuntimeError(
            "invalid World Transvoxel runtime artifact layout: "
            f"missing={missing!r} extra={extra!r} native_source={native_source!r}"
        )
