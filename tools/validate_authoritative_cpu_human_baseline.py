#!/usr/bin/env python3
"""Validate the retained CPU human-performance baseline and its claim boundaries."""

from __future__ import annotations

import hashlib
import json
import pathlib


ROOT = pathlib.Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "docs/evidence/authoritative_cpu_human_baseline_20260812"
REPORT = EVIDENCE / "baseline.json"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    digest.update(path.read_bytes())
    return digest.hexdigest()


def main() -> int:
    report = json.loads(REPORT.read_text(encoding="utf-8"))
    require(
        report.get("schema") == "world_transvoxel_authoritative_cpu_human_baseline_v1",
        "unexpected baseline schema",
    )
    require(report.get("status") == "MEASURED_TARGET_MISS", "target miss was lost")
    require(report.get("run_count") == 3, "baseline must retain exactly three runs")
    require(
        report.get("causal_attribution_status")
        == "UNRESOLVED_REQUIRES_REAL_TIME_PIPELINE_TRACE",
        "causal attribution was promoted without trace evidence",
    )
    require(
        report.get("optimization_status") == "BLOCKED_PENDING_CAUSAL_ATTRIBUTION",
        "optimization gate is not blocked",
    )
    require(
        report.get("tqp58_gpu_decision_status")
        == "BLOCKED_PENDING_CAUSAL_ATTRIBUTION",
        "GPU decision gate is not blocked",
    )
    provenance = report.get("provenance", {})
    require(provenance.get("logical_cpu_affinity") == [0, 1, 2], "CPU affinity changed")
    require(
        provenance.get("runtime_kind") == "godot_editor_debug",
        "runtime kind must remain explicit",
    )
    require(
        provenance.get("authority_commit")
        == "f30818b9ce0f0b3f9ddb75726db5522d97167404",
        "authority commit changed",
    )
    require(
        provenance.get("integration_commit")
        == "413eaa5c9c612bd0ee3bf939b233723d9d2a8080",
        "measurement source commit changed",
    )
    runs = report.get("runs", [])
    executions = report.get("executions", [])
    require(len(runs) == 3 and len(executions) == 3, "raw runs are incomplete")
    for index, (run, execution) in enumerate(zip(runs, executions), 1):
        require(execution.get("measurement_complete") is True, f"run {index} incomplete")
        require(
            execution.get("target_status") == "MEASURED_TARGET_MISS",
            f"run {index} target miss was lost",
        )
        require(run.get("measurement_complete") is True, f"run {index} route incomplete")
        require(run.get("edit", {}).get("interaction_accepted") is True, f"run {index} edit rejected")
        log_path = EVIDENCE / f"run_{index:02d}.stdout.log"
        require(log_path.is_file(), f"run {index} stdout log missing")
        require("WT_RUNTIME_BASELINE_SUMMARY " in log_path.read_text(encoding="utf-8"), f"run {index} raw summary missing")
    aggregates = report.get("aggregates", {})
    require(
        float(aggregates["relocation_to_visual_ready_ms"]["median"]) > 10_000.0,
        "retained delayed-readiness median is unexpectedly absent",
    )
    maximum_movement_frame_ms = max(
        float(phase["frame_time_ms"]["maximum"])
        for run in runs
        for phase in run["phases"]
        if phase.get("kind") == "movement"
    )
    require(
        maximum_movement_frame_ms > 33.3,
        "retained movement-phase hitch evidence is unexpectedly absent",
    )
    require(
        float(aggregates["maximum_consecutive_blocked_frames"]["maximum"]) >= 30.0,
        "retained movement-blocking evidence is unexpectedly absent",
    )
    manifest = {
        "baseline.json": sha256(REPORT),
        **{
            f"run_{index:02d}.stdout.log": sha256(EVIDENCE / f"run_{index:02d}.stdout.log")
            for index in range(1, 4)
        },
    }
    print(
        "WT_AUTHORITATIVE_CPU_HUMAN_BASELINE_PASS "
        f"status={report['status']} runs={len(runs)} files={len(manifest)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
