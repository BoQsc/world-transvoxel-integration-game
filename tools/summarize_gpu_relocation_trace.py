#!/usr/bin/env python3
"""Retain a bounded, exact chunk timeline from a GPU readiness measurement."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--measurement", type=Path, required=True)
    parser.add_argument("--chunk", type=int, nargs=3, required=True)
    parser.add_argument("--lod", type=int, default=0)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output already exists")
    measurement_bytes = args.measurement.read_bytes()
    measurement = json.loads(measurement_bytes)
    trace_path = args.measurement.with_name(args.measurement.stem + "_native.json")
    trace_bytes = trace_path.read_bytes()
    trace = json.loads(trace_bytes)
    native = trace["native"]
    baseline = measurement["baseline"]
    coordinate = dict(zip(("x", "y", "z"), args.chunk))
    target_events = [event for event in native["events"] if event.get("has_chunk")
                     and [event.get("chunk_" + axis) for axis in coordinate] == args.chunk
                     and event.get("chunk_lod") == args.lod]
    if not target_events:
        parser.error("trace contains no events for this chunk")
    samples = []
    for sample in baseline["readiness_probe"]["samples"]:
        if sample["label"] != "edit_target_wait":
            continue
        samples.append({
            **{name: sample[name] for name in ("label", "frame", "elapsed_us", "ray")},
            "states": [state for state in sample["states"]
                       if state["coordinate"] == coordinate and state["lod"] == args.lod],
        })
    report = {
        "schema": "world_transvoxel.gpu_relocation_chunk_trace.v1",
        "claim_boundary": "Exact recorded events for an explicitly selected ray-intersecting chunk; not a proven ray hit, complete edit latency, or gameplay acceptance. Native elapsed_ns, frontend elapsed_us, and readiness elapsed_us each retain their original clock origin.",
        "target": {"coordinate": coordinate, "lod": args.lod},
        "sources": {
            "measurement": {"path": str(args.measurement), "sha256": hashlib.sha256(measurement_bytes).hexdigest()},
            "trace": {"path": str(trace_path), "sha256": hashlib.sha256(trace_bytes).hexdigest()},
        },
        "native_capture": {key: value for key, value in native.items() if key != "events"},
        "native_events": target_events,
        "frontend_phases": [{key: event[key] for key in ("kind", "phase", "elapsed_us", "frame")}
                            for event in trace["events"] if event["kind"] == "phase_started"],
        "readiness_samples": samples,
        "stage_timing_usec": baseline["gpu_candidate_status"]["stage_timing_usec"],
        "edit": baseline["edit"],
        "movement": baseline["movement"],
        "render_frame_interval_ms": baseline["render_frame_interval_ms"],
        "execution": measurement["execution"],
        "actual_runtime_artifact_sha256": measurement["actual_runtime_artifact_sha256"],
        "runtime_artifact_matches_pin": measurement["runtime_artifact_matches_pin"],
        "affinity": measurement["affinity"],
        "godot_version": measurement["godot_version"],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(args.output), "events": len(target_events),
                      "native_complete": native["complete"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
