#!/usr/bin/env python3
"""Build a deterministic live-edit replay fixture from a preserved marker bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
from typing import Any


SCHEMA = "wt_human_edit_live_replay_v1"


def load_json(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object: {path}")
    return value


def resource_path(path: pathlib.Path, project: pathlib.Path) -> str:
    return "res://" + path.resolve().relative_to(project.resolve()).as_posix()


def mismatched_seams(marker: dict[str, Any]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for diagnostic in marker.get("render_seam_diagnostics", []):
        if not isinstance(diagnostic, dict):
            continue
        comparison = diagnostic.get("edge_comparison", {})
        if not isinstance(comparison, dict) or comparison.get("exact_match") is not False:
            continue
        output.append(
            {
                "owner": diagnostic["owner"],
                "neighbor": diagnostic["neighbor"],
                "lod": diagnostic["lod"],
                "face": diagnostic["face"],
                "focus": diagnostic["hit_position"],
                "window_radius": 32.0,
                "recorded_edge_comparison": comparison,
            }
        )
    if not output:
        raise ValueError("marker has no mismatched render seam to replay")
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--storage-tool", type=pathlib.Path, required=True)
    parser.add_argument("--journal", type=pathlib.Path, required=True)
    parser.add_argument("--marker", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--author-id", type=int, default=56056)
    args = parser.parse_args()

    project = pathlib.Path(__file__).resolve().parents[1]
    journal = args.journal.resolve()
    marker_path = args.marker.resolve()
    marker = load_json(marker_path)
    completed = subprocess.run(
        [str(args.storage_tool.resolve()), "dump", str(journal)],
        check=True,
        text=True,
        capture_output=True,
    )
    dump = json.loads(completed.stdout)
    transactions = dump.get("transactions", [])
    if dump.get("type") != "wtedit_dump" or not isinstance(transactions, list):
        raise ValueError("native storage tool did not return a journal dump")
    if not transactions:
        raise ValueError("journal dump contains no transactions")
    for transaction in transactions:
        transaction["author_id"] = args.author_id
        for command in transaction.get("commands", []):
            command.setdefault("smooth_radius", 0.0)

    journal_hash = hashlib.sha256(journal.read_bytes()).hexdigest()
    fixture = {
        "schema": SCHEMA,
        "source_marker": resource_path(marker_path, project),
        "source_journal": resource_path(journal, project),
        "journal_sha256": journal_hash,
        "profile": marker["profile"],
        "source_revision": transactions[0]["source_revision"],
        "initial_world_revision": transactions[0]["base_revision"],
        "final_world_revision": transactions[-1]["committed_revision"],
        "transaction_count": len(transactions),
        "command_count": sum(len(item.get("commands", [])) for item in transactions),
        "targeted_seams": mismatched_seams(marker),
        "transactions": transactions,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(fixture, indent=2) + "\n", encoding="utf-8")
    print(
        "WT_HUMAN_EDIT_REPLAY_FIXTURE_BUILT "
        f"transactions={fixture['transaction_count']} "
        f"commands={fixture['command_count']} "
        f"journal_sha256={journal_hash} output={args.output.resolve()}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
