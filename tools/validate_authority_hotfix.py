#!/usr/bin/env python3
"""Validate the active authority hotfix package independently of TQP-54."""

from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile

import sync_tqp54_candidate as package_sync


ROOT = Path(__file__).resolve().parents[1]
PIN_PATH = ROOT / "AUTHORITY_HOTFIX_PIN.json"
TQP54_PIN_PATH = ROOT / "TQP54_PACKAGE_PIN.json"
AUTHORITY_REPO = ROOT.parent / "world-transvoxel"
TARGET = ROOT / "addons" / "world_transvoxel"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def canonical_content(content: bytes) -> bytes:
    if b"\0" in content:
        return content
    try:
        content.decode("utf-8")
    except UnicodeDecodeError:
        return content
    return content.replace(b"\r\n", b"\n")


def package_digest(files: dict[PurePosixPath, bytes]) -> str:
    value = hashlib.sha256()
    for relative, content in sorted(files.items()):
        value.update(relative.as_posix().encode("utf-8"))
        value.update(b"\0")
        value.update(canonical_content(content))
        value.update(b"\0")
    return value.hexdigest()


def git_value(revision: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(AUTHORITY_REPO), "rev-parse", revision],
        text=True,
    ).strip()


def authority_snapshot(revision: str) -> dict[PurePosixPath, bytes]:
    package_root = PurePosixPath("addons/world_transvoxel")
    archive = subprocess.check_output(
        [
            "git",
            "-C",
            str(AUTHORITY_REPO),
            "archive",
            "--format=tar",
            revision,
            package_root.as_posix(),
        ]
    )
    result: dict[PurePosixPath, bytes] = {}
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as package:
        for member in package.getmembers():
            if not member.isfile():
                continue
            stream = package.extractfile(member)
            require(stream is not None, f"unreadable package member: {member.name}")
            relative = PurePosixPath(member.name).relative_to(package_root)
            result[relative] = stream.read()
    return result


def target_snapshot() -> dict[PurePosixPath, bytes]:
    return {
        relative: path.read_bytes()
        for relative, path in package_sync.package_files(TARGET).items()
    }


def main() -> None:
    pin = json.loads(PIN_PATH.read_text(encoding="utf-8"))
    tqp54_pin = json.loads(TQP54_PIN_PATH.read_text(encoding="utf-8"))
    authority = pin.get("authority", {})
    evidence_path = ROOT / str(pin.get("evidence", ""))
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    require(pin.get("status") == "ACTIVE_CORRECTNESS_HOTFIX", "hotfix is inactive")
    require(
        pin.get("base_tqp54_pin") == tqp54_pin.get("authority", {}).get("commit"),
        "hotfix base does not match the retained TQP-54 authority pin",
    )
    revision = str(authority.get("commit", ""))
    require(git_value(revision) == revision, "hotfix authority commit is unavailable")
    require(
        git_value(f"{revision}:addons/world_transvoxel")
        == authority.get("addon_tree"),
        "hotfix authority tree drifted",
    )
    source = authority_snapshot(revision)
    target = target_snapshot()
    generated_runtime = authority.get("generated_runtime", [])
    require(isinstance(generated_runtime, list), "generated runtime pin is malformed")
    for item in generated_runtime:
        require(isinstance(item, dict), "generated runtime entry is malformed")
        relative = PurePosixPath(str(item.get("path", "")))
        require(relative in target, f"generated runtime file is missing: {relative}")
        content = target[relative]
        require(len(content) == int(item.get("bytes", 0)), f"size drift: {relative}")
        require(
            hashlib.sha256(content).hexdigest() == item.get("sha256"),
            f"digest drift: {relative}",
        )
        source[relative] = content
    missing = source.keys() - target.keys()
    extra = target.keys() - source.keys()
    changed = {
        path
        for path in source.keys() & target.keys()
        if canonical_content(source[path]) != canonical_content(target[path])
    }
    require(
        not missing and not extra and not changed,
        "hotfix package drift: missing=%d extra=%d changed=%d"
        % (len(missing), len(extra), len(changed)),
    )
    expected_digest = str(authority.get("package_digest_sha256", ""))
    require(package_digest(source) == expected_digest, "hotfix source digest drifted")
    require(package_digest(target) == expected_digest, "hotfix target digest drifted")
    require(len(source) == int(authority.get("files", 0)), "hotfix file count drifted")
    require(
        evidence.get("status") == "ACCEPTED_CORRECTNESS_HOTFIX"
        and evidence.get("authority", {}).get("commit") == revision,
        "hotfix qualification evidence does not match the pin",
    )
    require(
        authority.get("fallback", False) is False,
        "authority hotfix must not introduce a fallback",
    )
    print(
        "WT_AUTHORITY_HOTFIX_PASS commit=%s files=%d performance_claim=0"
        % (revision[:8], len(source))
    )


if __name__ == "__main__":
    main()
