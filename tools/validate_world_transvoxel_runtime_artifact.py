#!/usr/bin/env python3
"""Validate the exact binary World Transvoxel dependency used by this game."""

from __future__ import annotations

import json
from pathlib import Path

import world_transvoxel_runtime_artifact as runtime_artifact


PIN_NAME = "WORLD_TRANSVOXEL_RUNTIME_PIN.json"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def validate(project: Path) -> dict[str, object]:
    pin = json.loads((project / PIN_NAME).read_text(encoding="utf-8"))
    authority = pin.get("authority", {})
    artifact = pin.get("runtime_artifact", {})
    require(
        pin.get("schema") == "world_transvoxel.integration.runtime_pin.v1",
        "runtime pin schema is unsupported",
    )
    require(pin.get("status") == "ACTIVE", "runtime pin is not active")
    require(isinstance(authority, dict), "authority pin is malformed")
    require(isinstance(artifact, dict), "runtime artifact pin is malformed")
    require(
        authority.get("repository") == "world-transvoxel"
        and authority.get("fallback") is False,
        "runtime authority must be world-transvoxel without a fallback",
    )
    require(
        artifact.get("layout") == "binary_consumer_v1"
        and artifact.get("native_source_included") is False,
        "runtime artifact is not declared as binary-only",
    )

    addon_root = project / "addons" / "world_transvoxel"
    runtime_artifact.validate_binary_consumer_layout(addon_root)
    expected_paths = [path.as_posix() for path in runtime_artifact.RUNTIME_PATHS]
    require(artifact.get("files") == expected_paths, "runtime artifact path pin drifted")
    actual_digest = runtime_artifact.artifact_digest(addon_root)
    require(
        actual_digest == artifact.get("digest_sha256"),
        "runtime artifact digest drifted",
    )

    binaries = artifact.get("binaries", [])
    require(isinstance(binaries, list), "runtime binary pin is malformed")
    expected_binary_paths = {
        path.as_posix() for path in runtime_artifact.GENERATED_RUNTIME_PATHS
    }
    actual_binary_paths: set[str] = set()
    for item in binaries:
        require(isinstance(item, dict), "runtime binary entry is malformed")
        relative = str(item.get("path", ""))
        actual_binary_paths.add(relative)
        path = addon_root / relative
        require(path.is_file(), f"runtime binary is missing: {relative}")
        require(path.stat().st_size == int(item.get("bytes", 0)), f"size drift: {relative}")
        require(
            runtime_artifact.sha256(path) == item.get("sha256"),
            f"digest drift: {relative}",
        )
    require(actual_binary_paths == expected_binary_paths, "runtime binary set drifted")

    descriptor = (addon_root / "world_transvoxel.gdextension").read_text(
        encoding="utf-8"
    )
    for relative in expected_binary_paths:
        require(Path(relative).name in descriptor, f"descriptor does not reference {relative}")
    return pin


def main() -> None:
    project = Path(__file__).resolve().parents[1]
    pin = validate(project)
    authority = pin["authority"]
    artifact = pin["runtime_artifact"]
    print(
        "WT_RUNTIME_ARTIFACT_PASS "
        f"authority={str(authority['commit'])[:8]} "
        f"files={len(artifact['files'])} "
        f"digest={artifact['digest_sha256']} native_source=0 fallback=0"
    )


if __name__ == "__main__":
    main()
