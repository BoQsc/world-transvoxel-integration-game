#!/usr/bin/env python3
"""Create a guarded Git checkpoint from all nonignored project changes."""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys


MAXIMUM_FILE_BYTES = 25 * 1024 * 1024
FORBIDDEN_PREFIXES = (".godot/", "artifacts/", "build/")


def git(root: pathlib.Path, *arguments: str, capture: bool = False) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE if capture else None,
        text=True,
    )
    return result.stdout if capture else ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-m", "--message", required=True)
    parser.add_argument(
        "--allow-large",
        action="store_true",
        help="Allow reviewed files larger than 25 MiB.",
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help="Stage only these reviewed paths; defaults to all nonignored changes.",
    )
    args = parser.parse_args()
    root = pathlib.Path(
        git(pathlib.Path.cwd(), "rev-parse", "--show-toplevel", capture=True).strip()
    )
    if git(root, "diff", "--cached", "--name-only", capture=True).strip():
        print("checkpoint refused: the index already contains staged changes", file=sys.stderr)
        return 2
    if args.paths:
        git(root, "add", "-A", "--", *args.paths)
    else:
        git(root, "add", "-A")
    staged = [
        pathlib.PurePosixPath(value).as_posix()
        for value in git(root, "diff", "--cached", "--name-only", capture=True).splitlines()
        if value
    ]
    if not staged:
        print("checkpoint skipped: no nonignored changes")
        return 0
    violations: list[str] = []
    for relative in staged:
        if relative.startswith(FORBIDDEN_PREFIXES):
            violations.append(f"generated path: {relative}")
            continue
        path = root / relative
        if path.is_file() and path.stat().st_size > MAXIMUM_FILE_BYTES \
                and not args.allow_large:
            violations.append(
                f"large file ({path.stat().st_size} bytes): {relative}"
            )
    if violations:
        git(root, "reset")
        print("checkpoint refused:\n" + "\n".join(violations), file=sys.stderr)
        return 2
    git(root, "diff", "--cached", "--check")
    git(root, "commit", "-m", args.message)
    print(git(root, "show", "--stat", "--oneline", "-1", capture=True), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
