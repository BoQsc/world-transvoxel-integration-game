#!/usr/bin/env python3
"""Produce the fail-closed independent CPU-B3 exhaustion decision."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
EVIDENCE_DIR = ROOT / "docs" / "evidence" / "cpu_b3_regional_publication_20260813"
OUTPUT_PATH = EVIDENCE_DIR / "exhaustion_review.json"
HUMAN_TAG = "human-accepted-cpu-b3-candidate-2026-08-13"
HUMAN_COMMIT = "bf59a98f51ada8cd9ef6fe1a71100984b87046c0"
AUTHORITY_COMMIT = "a8bba838a8860ba30bdb79887ad66ba17028ad18"
CANDIDATE_COMMIT = "eb8a69c19801bb3e52837e3c565159827b560d3d"
EVIDENCE_LINE_ENDINGS = {
    "qualification.json": "lf",
    "selected_trace_off.json": "crlf",
    "selected_causal_pair.json": "crlf",
    "rejected_viewer_regional_trace_off.json": "crlf",
    "rejected_viewer_regional_causal_pair.json": "crlf",
    "human_review.json": "lf",
}


def load_object(name: str) -> dict[str, Any]:
    value = json.loads((EVIDENCE_DIR / name).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{name} does not contain a JSON object")
    return value


def sha256(name: str) -> str:
    data = (EVIDENCE_DIR / name).read_bytes()
    lf_data = data.replace(b"\r\n", b"\n")
    # Four generated reports were retained from their original Windows CRLF
    # bytes, while review documents were retained as LF. Reconstruct that
    # explicit historical policy after Git checks the same text out either way.
    canonical = (
        lf_data.replace(b"\n", b"\r\n")
        if EVIDENCE_LINE_ENDINGS[name] == "crlf"
        else lf_data
    )
    return hashlib.sha256(canonical).hexdigest()


def tagged_commit(tag: str) -> str:
    result = subprocess.run(
        ["git", "rev-list", "-n", "1", tag],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def build_report() -> dict[str, Any]:
    qualification = load_object("qualification.json")
    selected = load_object("selected_trace_off.json")
    causal = load_object("selected_causal_pair.json")
    rejected = load_object("rejected_viewer_regional_trace_off.json")
    rejected_causal = load_object("rejected_viewer_regional_causal_pair.json")
    human = load_object("human_review.json")
    failures: list[str] = []

    expect(tagged_commit(HUMAN_TAG) == HUMAN_COMMIT, "human candidate tag changed", failures)
    expect(
        qualification.get("schema") == "world_transvoxel.cpu_b3_qualification.v1"
        and qualification.get("status") == "ACCEPTED_CORRECTNESS_HOTFIX",
        "CPU-B3 qualification identity changed",
        failures,
    )
    expect(
        qualification.get("authority", {}).get("commit") == AUTHORITY_COMMIT
        and qualification.get("authority", {}).get("fallback") is False,
        "CPU-B3 authority pin or fallback policy changed",
        failures,
    )
    expect(
        qualification.get("integration", {}).get("candidate_commit") == CANDIDATE_COMMIT,
        "CPU-B3 integration candidate changed",
        failures,
    )
    expect(
        selected.get("status") == "MEASURED_TARGET_MISS"
        and selected.get("correctness_status") == "RETAINED_FROM_PINNED_REVIEWED_BASELINE"
        and selected.get("run_count") == 3,
        "selected trace-off evidence changed",
        failures,
    )
    required_target_failures = {
        "blocked_movement_frames",
        "collision_ready_wait",
        "physics_target_wait",
        "visual_ready_wait",
    }
    expect(
        required_target_failures.issubset(set(selected.get("observed_target_failures", []))),
        "selected target misses are incomplete",
        failures,
    )
    selected_change = qualification.get("selected_change", {})
    medians = selected_change.get("trace_off_medians", {})
    causal_observation = selected_change.get("causal_observation", {})
    expect(
        medians.get("relocation_to_visual_ready_ms") == 3822.632
        and medians.get("relocation_to_collision_ready_ms") == 3822.632
        and medians.get("maximum_scheduler_queued_jobs") == 774
        and medians.get("maximum_pending_chunk_replacements") == 783
        and medians.get("average_active_cores") == 1.4513778952139094,
        "selected CPU-B3 medians changed",
        failures,
    )
    expect(
        causal_observation.get("post_sink_wait_ms") == 1988.3341
        and causal_observation.get("publication_component_replacements") == 267
        and causal_observation.get("publication_component_retirements") == 31
        and causal_observation.get("coverage_priority_requests") == 207,
        "selected CPU-B3 publication-component evidence changed",
        failures,
    )
    expect(
        causal.get("status") == "PASS"
        and causal.get("causal_attribution", {}).get("complete") is True
        and causal.get("causal_attribution", {}).get("classification")
        == "GLOBAL_VISIBILITY_STAGING_BARRIER_AFTER_RELOCATION",
        "selected causal attribution changed",
        failures,
    )
    not_authoritative = set(causal.get("claim_boundaries", {}).get("not_authoritative_for", []))
    expect(
        "complete attribution of flight frame-time spikes" in not_authoritative,
        "flight attribution claim boundary changed",
        failures,
    )
    limitations = human.get("known_limitations", [])
    limitation_ids = [item.get("id") for item in limitations]
    expect(
        human.get("status") == "ACCEPTED_WITH_KNOWN_LIMITATIONS"
        and human.get("tested_package", {}).get("authority_commit") == AUTHORITY_COMMIT
        and human.get("tested_package", {}).get("candidate_commit") == CANDIDATE_COMMIT
        and limitation_ids
        == [
            "TEMPORARY_LOD_SEE_THROUGH_SLICE",
            "RESIDUAL_FLIGHT_RESPONSIVENESS",
            "RELOCATION_FIRST_EDIT_DELAY",
        ]
        and all(item.get("release_blocking") is True for item in limitations),
        "human review identity or release blockers changed",
        failures,
    )
    expect(
        qualification.get("rejected_experiment", {}).get("reverted") is True
        and rejected.get("status") == "MEASURED_TARGET_MISS"
        and rejected_causal.get("status") == "FAIL",
        "rejected viewer-region experiment boundary changed",
        failures,
    )

    evidence_files = [
        "qualification.json",
        "selected_trace_off.json",
        "selected_causal_pair.json",
        "rejected_viewer_regional_trace_off.json",
        "rejected_viewer_regional_causal_pair.json",
        "human_review.json",
    ]
    review_complete = not failures
    return {
        "schema": "world_transvoxel.cpu_b3_exhaustion_review.v1",
        "review_status": "COMPLETE" if review_complete else "INVALID_EVIDENCE",
        "decision": (
            "NOT_EXHAUSTED_ADDITIONAL_CPU_ATTRIBUTION_AND_REMEDIATION_REQUIRED"
            if review_complete
            else "UNDECIDED_EVIDENCE_INCONSISTENT"
        ),
        "milestone": "CPU-B3",
        "date": "2026-08-13",
        "implementation_changed": False,
        "cpu_b3_pass": False,
        "tqp58_eligible": False,
        "frozen_candidate": {
            "human_tag": HUMAN_TAG,
            "human_commit": HUMAN_COMMIT,
            "candidate_commit": CANDIDATE_COMMIT,
            "authority_commit": AUTHORITY_COMMIT,
            "logical_cpu_affinity": [0, 1, 2],
            "fallback": False,
        },
        "source_evidence": [
            {"path": f"docs/evidence/cpu_b3_regional_publication_20260813/{name}", "sha256": sha256(name)}
            for name in evidence_files
        ],
        "exit_criteria": {
            "correctness_authority_retained": True,
            "trace_off_performance_target_pass": False,
            "release_blocking_human_limitations_absent": False,
            "all_material_bottlenecks_causally_attributed": False,
            "all_trace_supported_standard_cpu_remedies_exhausted": False,
            "independent_gpu_eligibility_established": False,
        },
        "material_findings": [
            {
                "id": "TEMPORARY_LOD_SEE_THROUGH_SLICE",
                "state": "UNATTRIBUTED_RELEASE_BLOCKER",
                "basis": "Human review observed a temporary opening, but no retained causal trace or geometry/residency classification covers the event.",
                "required_next": "Capture the opening with an exact marker and bounded trace, then distinguish missing geometry from residency, retirement, visibility, or publication ordering before changing policy.",
            },
            {
                "id": "FLIGHT_RESPONSIVENESS",
                "state": "PARTIALLY_ATTRIBUTED_RELEASE_BLOCKER",
                "basis": "Collision-gated movement rejection is attributed during relocation backlog, but retained evidence explicitly excludes complete attribution of flight frame-time spikes.",
                "required_next": "Run a focused trace-off/trace-on flight capture that separates input latency, frame hitches, collision readiness, demand admission, and queue growth.",
            },
            {
                "id": "RELOCATION_FIRST_EDIT_DELAY",
                "state": "ATTRIBUTED_REMEDY_CLASS_NOT_EXHAUSTED",
                "basis": "The selected edit completes both sinks before a 1988.3341 ms wait for a 267-replacement/31-retirement publication component; the broad viewer-region remedy was rejected, but component scope and superseded-plan handling have not been exhausted by one-variable evidence.",
                "required_next": "Audit exact component membership and superseded viewer-plan ownership, then test at most one bounded trace-proven lifecycle remedy without independently publishing ordinary viewer regions.",
            },
            {
                "id": "CPU_CAPACITY_BASIS",
                "state": "NO_SATURATION_OR_EXHAUSTION_PROOF",
                "basis": "The retained candidate averages 1.451 active cores while median maximum scheduler queue and pending replacements are 774 and 783. This indicates dependency, admission, or waiting behavior; it does not prove useful CPU parallelism is exhausted.",
                "required_next": "Attribute queue wait and worker-idle intervals before changing worker count or selecting a GPU backend.",
            },
        ],
        "rejected_shortcuts": [
            "declare CPU exhausted because performance targets remain missed",
            "treat human acceptance with known limitations as production acceptance",
            "repeat the reverted broad viewer-region publication experiment",
            "increase workers beyond the three-logical-CPU boundary",
            "select GPU architecture before the remaining defects are attributed",
        ],
        "ordered_next_work": [
            "CPU-B3A temporary LOD opening causal capture and classification",
            "CPU-B3B flight frame-time and movement responsiveness attribution",
            "CPU-B3C exact regional publication-component ownership audit",
            "CPU-B3D at most one newly trace-proven standard CPU remedy with full A/B correctness and human regression",
            "CPU-B3E repeat independent exhaustion review",
        ],
        "claim_boundaries": [
            "This is a completed independent review with a NOT_EXHAUSTED decision, not an incomplete review.",
            "The result does not revoke the retained correctness hotfix or human candidate acceptance.",
            "The result does not qualify production temporal seamlessness or performance.",
            "CPU-B3 remains in progress, TQP-58 remains blocked, and no GPU architecture is selected.",
        ],
        "consistency_failures": failures,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="Compare with the retained report without writing it.")
    args = parser.parse_args(argv)
    report = build_report()
    rendered = json.dumps(report, indent=2) + "\n"
    if args.check:
        if not OUTPUT_PATH.is_file() or OUTPUT_PATH.read_text(encoding="utf-8") != rendered:
            print("WT_CPU_B3_EXHAUSTION_REVIEW_FAIL retained report differs", file=sys.stderr)
            return 1
    else:
        OUTPUT_PATH.write_text(rendered, encoding="utf-8")
    if report["review_status"] != "COMPLETE":
        for failure in report["consistency_failures"]:
            print("WT_CPU_B3_EXHAUSTION_REVIEW_FAIL " + failure, file=sys.stderr)
        return 1
    print(
        "WT_CPU_B3_EXHAUSTION_REVIEW_PASS "
        f"decision={report['decision']} tqp58_eligible=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
