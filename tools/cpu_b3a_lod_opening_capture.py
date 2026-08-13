#!/usr/bin/env python3
"""Capture and classify a temporary LOD opening without image-only claims."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import platform
import subprocess
import sys
import time
from typing import Any

import psutil

import p2_production_integration_game_quality as integration_quality


PROFILE = "g23_four_biomes_lakes_mountains_roads_2k_256_on_demand"
MODE = "cpu_b3a_lod_opening_capture"
SUMMARY_PREFIX = "WT_CPU_B3A_LOD_OPENING_SUMMARY "
CAPTURE_SCHEMA = "world_transvoxel.cpu_b3a_lod_opening_capture.v1"
CLASSIFICATION_SCHEMA = "world_transvoxel.cpu_b3a_lod_opening_classification.v1"
REQUIRED_AFFINITY = [0, 1, 2]
ROAD_SURFACE_AND_SHOULDER_LIMIT_CELLS = 16.0
NATIVE_EVENT_WINDOW_US = 5_000_000
CHUNK_CELLS = 16


def _git(project: pathlib.Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", *args], cwd=project, text=True, capture_output=True, check=True
    )
    return completed.stdout.strip()


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _summary_from_stdout(stdout: str) -> dict[str, Any]:
    for line in stdout.splitlines():
        if not line.startswith(SUMMARY_PREFIX):
            continue
        value = json.loads(line[len(SUMMARY_PREFIX) :].strip())
        if isinstance(value, dict):
            return value
    raise RuntimeError("Godot output did not contain the CPU-B3A capture summary")


def _opening_event_elapsed_us(trace: dict[str, Any]) -> int | None:
    events = trace.get("events", [])
    if not isinstance(events, list):
        return None
    for event in events:
        if isinstance(event, dict) and event.get("kind") == "cpu_b3a_opening_confirmed":
            return int(event.get("elapsed_us", -1))
    return None


def _opening_hit_positions(capture: dict[str, Any]) -> list[dict[str, float]]:
    observation = capture.get("confirmed_observation", {})
    if not isinstance(observation, dict):
        return []
    output: list[dict[str, float]] = []
    for ray in observation.get("direct_opening_rays", []):
        if not isinstance(ray, dict):
            continue
        position = ray.get("hit_position")
        if not isinstance(position, dict):
            authoritative = ray.get("authoritative_ray", {})
            if isinstance(authoritative, dict):
                position = authoritative.get("surface_point")
        if isinstance(position, dict):
            output.append({axis: float(position.get(axis, 0.0)) for axis in "xyz"})
    return output


def _event_chunk_contains(event: dict[str, Any], position: dict[str, float]) -> bool:
    if event.get("has_chunk") is not True:
        return False
    lod = int(event.get("chunk_lod", -1))
    if lod < 0:
        return False
    extent = CHUNK_CELLS * (1 << lod)
    return all(
        int(event.get(f"chunk_{axis}", 0)) * extent <= position[axis]
        < (int(event.get(f"chunk_{axis}", 0)) + 1) * extent
        for axis in "xyz"
    )


def _overlapping_native_events(
    trace: dict[str, Any],
    positions: list[dict[str, float]],
    opening_elapsed_us: int,
) -> list[dict[str, Any]]:
    native = trace.get("native", {})
    events = native.get("events", []) if isinstance(native, dict) else []
    if not isinstance(events, list):
        return []
    output: list[dict[str, Any]] = []
    for event in events:
        if not isinstance(event, dict):
            continue
        elapsed_us = int(event.get("elapsed_ns", -1)) // 1000
        if abs(elapsed_us - opening_elapsed_us) > NATIVE_EVENT_WINDOW_US:
            continue
        if any(_event_chunk_contains(event, position) for position in positions):
            output.append(event)
    return output


def _state_classification(capture: dict[str, Any]) -> str:
    observation = capture.get("confirmed_observation", {})
    if not isinstance(observation, dict):
        return "UNATTRIBUTED"
    runtime = observation.get("runtime", {})
    if isinstance(runtime, dict) and int(runtime.get("pending_retirement_records_missing", 0)) > 0:
        return "RETIREMENT_COVERAGE_LOSS"
    states = observation.get("chunk_neighborhood", [])
    if not isinstance(states, list):
        return "UNATTRIBUTED"
    hit_states = [
        state
        for state in states
        if isinstance(state, dict) and state.get("contains_target_position") is True
    ]
    if any(
        state.get("visual_required") is True and state.get("visual_ready") is not True
        for state in hit_states
    ):
        return "RESIDENCY_OR_REPLACEMENT_READINESS"
    if any(
        state.get("visual_ready") is True
        and int(state.get("render_generation", 0)) != int(state.get("generation", 0))
        for state in hit_states
    ):
        return "PUBLICATION_ORDERING"
    if hit_states:
        return "VISIBILITY_COVERAGE"
    return "UNATTRIBUTED"


def classify_capture(
    capture: dict[str, Any], trace: dict[str, Any]
) -> dict[str, Any]:
    failures: list[str] = []
    if capture.get("schema") != CAPTURE_SCHEMA:
        failures.append("capture_schema")
    if capture.get("ok") is not True:
        failures.append("capture_structural_status")
    contract = capture.get("capture_contract", {})
    if not isinstance(contract, dict):
        failures.append("capture_contract")
        contract = {}
    if contract.get("screenshots_are_authority") is not False:
        failures.append("image_only_claim_boundary")
    exclusion = capture.get("route_exclusion", {})
    minimum_road_clearance = (
        float(exclusion.get("minimum_viewer_route_road_centerline_clearance_cells", 0.0))
        if isinstance(exclusion, dict)
        else 0.0
    )
    if minimum_road_clearance <= ROAD_SURFACE_AND_SHOULDER_LIMIT_CELLS:
        failures.append("road_clearance")
    native = trace.get("native", {})
    if not isinstance(native, dict) or native.get("complete") is not True:
        failures.append("native_trace_incomplete")
    if int(trace.get("dropped_event_count", -1)) != 0:
        failures.append("downstream_trace_dropped_events")

    direct_count = int(capture.get("direct_opening_count", 0))
    status = str(capture.get("status", ""))
    positions = _opening_hit_positions(capture)
    opening_elapsed_us = _opening_event_elapsed_us(trace)
    overlapping_events: list[dict[str, Any]] = []
    state_classification = "UNATTRIBUTED"
    milestone_status = "IN_PROGRESS_EVENT_NOT_REPRODUCED"
    result = "BOUNDED_ROAD_FILTERED_ROUTE_NO_EVENT"
    if direct_count > 0 or status == "CAUSAL_EVENT_CAPTURED":
        if direct_count != 1:
            failures.append("direct_opening_count")
        if not positions:
            failures.append("direct_opening_physics_positions")
        if opening_elapsed_us is None:
            failures.append("opening_trace_marker")
        else:
            overlapping_events = _overlapping_native_events(
                trace, positions, opening_elapsed_us
            )
        state_classification = _state_classification(capture)
        if state_classification == "UNATTRIBUTED":
            failures.append("chunk_state_attribution")
        lifecycle_kinds = sorted({str(event.get("kind")) for event in overlapping_events})
        if not lifecycle_kinds:
            failures.append("overlapping_native_chunk_lifecycle")
        milestone_status = (
            "COMPLETE_CAUSAL_CLASSIFICATION"
            if not failures
            else "IN_PROGRESS_CAPTURED_ATTRIBUTION_INCOMPLETE"
        )
        result = state_classification
    elif status != "BOUNDED_ROUTE_COMPLETE_NO_EVENT":
        failures.append("capture_status")

    post_event = capture.get("post_event", [])
    if direct_count > 0:
        frames = [int(item.get("frame", -1)) for item in post_event if isinstance(item, dict)]
        if frames != [0, 1, 3, 8, 16, 32, 60, 120, 240]:
            failures.append("bounded_post_event_window")

    return {
        "schema": CLASSIFICATION_SCHEMA,
        "valid": not failures,
        "milestone": "CPU-B3A",
        "milestone_status": milestone_status,
        "result": result,
        "direct_opening_count": direct_count,
        "state_classification": state_classification,
        "minimum_road_centerline_clearance_cells": minimum_road_clearance,
        "excluded_authored_road_ray_count": int(
            capture.get("excluded_authored_road_ray_count", 0)
        ),
        "rendered_road_clear_ray_count": int(
            capture.get("rendered_road_clear_ray_count", 0)
        ),
        "road_surface_and_shoulder_limit_cells": ROAD_SURFACE_AND_SHOULDER_LIMIT_CELLS,
        "opening_trace_elapsed_us": opening_elapsed_us,
        "opening_hit_positions": positions,
        "overlapping_native_event_count": len(overlapping_events),
        "overlapping_native_event_kinds": sorted(
            {str(event.get("kind")) for event in overlapping_events}
        ),
        "overlapping_native_events": overlapping_events,
        "post_event_frames": [
            int(item.get("frame", -1)) for item in post_event if isinstance(item, dict)
        ],
        "failures": failures,
        "claim_boundary": (
            "A road-filtered no-event run is a bounded reproduction attempt, not proof that the defect is absent."
            if direct_count == 0
            else "Classification requires same-ray collision/render evidence, chunk generations, and overlapping native lifecycle events; images are supporting evidence only."
        ),
    }


def _run_capture(
    project: pathlib.Path,
    godot: pathlib.Path,
    output_dir: pathlib.Path,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    output_dir.mkdir(parents=True, exist_ok=True)
    capture_path = output_dir / "cpu_b3a.png"
    trace_path = output_dir / "cpu_b3a_trace.json"
    stdout_path = output_dir / "cpu_b3a.stdout.log"
    stderr_path = output_dir / "cpu_b3a.stderr.log"
    command = [
        str(godot),
        "--path",
        str(project),
        "--",
        "--p2-profile",
        PROFILE,
        "--human-visual-capture",
        str(capture_path),
        "--human-visual-capture-mode",
        MODE,
        "--human-visual-capture-wait-frames",
        "180",
        "--human-material-mode",
        "production_texture_array",
        "--procedural-generation-workers",
        "2",
        "--cpu-causal-trace-output",
        str(trace_path),
    ]
    started = time.perf_counter()
    with stdout_path.open("w", encoding="utf-8") as stdout_stream, stderr_path.open(
        "w", encoding="utf-8"
    ) as stderr_stream:
        completed = subprocess.run(
            command,
            cwd=project,
            stdout=stdout_stream,
            stderr=stderr_stream,
            timeout=900,
            check=False,
        )
    wall_seconds = time.perf_counter() - started
    stdout = stdout_path.read_text(encoding="utf-8")
    capture = _summary_from_stdout(stdout)
    report_path = pathlib.Path(str(capture.get("report_path", "")))
    if not report_path.is_file():
        raise RuntimeError(f"CPU-B3A report was not retained: {report_path}")
    retained_capture = json.loads(report_path.read_text(encoding="utf-8"))
    if retained_capture != capture:
        raise RuntimeError("stdout summary differs from retained CPU-B3A report")
    if not trace_path.is_file():
        raise RuntimeError("CPU-B3A trace was not retained")
    trace = json.loads(trace_path.read_text(encoding="utf-8"))
    execution = {
        "command": command,
        "returncode": completed.returncode,
        "wall_seconds": wall_seconds,
        "stdout_path": str(stdout_path),
        "stderr_path": str(stderr_path),
        "capture_report_path": str(report_path),
        "trace_path": str(trace_path),
    }
    return capture, trace, execution


def _provenance(
    project: pathlib.Path,
    godot: pathlib.Path,
    affinity: list[int],
    capture: dict[str, Any],
    trace_path: pathlib.Path,
) -> dict[str, Any]:
    pin = json.loads((project / "AUTHORITY_HOTFIX_PIN.json").read_text(encoding="utf-8"))
    report_path = pathlib.Path(str(capture["report_path"]))
    return {
        "integration_commit": _git(project, "rev-parse", "HEAD"),
        "integration_tree": _git(project, "rev-parse", "HEAD^{tree}"),
        "integration_dirty": bool(_git(project, "status", "--short")),
        "authority_commit": pin["authority"]["commit"],
        "authority_addon_tree": pin["authority"]["addon_tree"],
        "godot_executable": str(godot),
        "godot_version": subprocess.run(
            [str(godot), "--version"], text=True, capture_output=True, check=True
        ).stdout.strip(),
        "platform": platform.platform(),
        "logical_cpu_affinity": affinity,
        "capture_report_sha256": _sha256(report_path),
        "causal_trace_sha256": _sha256(trace_path),
    }


def _self_test() -> None:
    position = {"x": 1201.0, "y": 41.0, "z": 1401.0}
    capture: dict[str, Any] = {
        "schema": CAPTURE_SCHEMA,
        "ok": True,
        "status": "CAUSAL_EVENT_CAPTURED",
        "direct_opening_count": 1,
        "capture_contract": {"screenshots_are_authority": False},
        "route_exclusion": {
            "minimum_viewer_route_road_centerline_clearance_cells": 132.94
        },
        "confirmed_observation": {
            "runtime": {"pending_retirement_records_missing": 0},
            "direct_opening_rays": [{"hit_position": position}],
            "chunk_neighborhood": [
                {
                    "contains_target_position": True,
                    "visual_required": True,
                    "visual_ready": True,
                    "generation": 7,
                    "render_generation": 7,
                }
            ],
        },
        "post_event": [{"frame": frame} for frame in [0, 1, 3, 8, 16, 32, 60, 120, 240]],
    }
    trace: dict[str, Any] = {
        "dropped_event_count": 0,
        "events": [{"kind": "cpu_b3a_opening_confirmed", "elapsed_us": 1_000_000}],
        "native": {
            "complete": True,
            "events": [
                {
                    "kind": "render_sink_applied",
                    "elapsed_ns": 1_000_000_000,
                    "has_chunk": True,
                    "chunk_x": 75,
                    "chunk_y": 2,
                    "chunk_z": 87,
                    "chunk_lod": 0,
                }
            ],
        },
    }
    result = classify_capture(capture, trace)
    if result["milestone_status"] != "COMPLETE_CAUSAL_CLASSIFICATION":
        raise RuntimeError(f"synthetic causal classification failed: {result!r}")
    capture["status"] = "BOUNDED_ROUTE_COMPLETE_NO_EVENT"
    capture["direct_opening_count"] = 0
    capture["confirmed_observation"] = {}
    capture["post_event"] = []
    no_event = classify_capture(capture, trace)
    if no_event["milestone_status"] != "IN_PROGRESS_EVENT_NOT_REPRODUCED":
        raise RuntimeError(f"synthetic no-event boundary failed: {no_event!r}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", help="Path to the Godot 4.7 executable.")
    parser.add_argument(
        "--output-dir",
        default=".godot/world_transvoxel_captures/cpu_b3a_lod_opening",
    )
    parser.add_argument("--allow-dirty", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        _self_test()
        print("WT_CPU_B3A_CLASSIFIER_SELF_TEST_PASS")
        return 0

    project = pathlib.Path(__file__).resolve().parents[1]
    affinity = psutil.Process().cpu_affinity()
    if affinity != REQUIRED_AFFINITY:
        raise RuntimeError(
            f"CPU-B3A requires exact affinity {REQUIRED_AFFINITY!r}, got {affinity!r}"
        )
    if not args.allow_dirty and _git(project, "status", "--short"):
        raise RuntimeError("CPU-B3A retained evidence requires a clean committed worktree")
    godot = integration_quality.find_godot(args.godot)
    output_dir = pathlib.Path(args.output_dir)
    if not output_dir.is_absolute():
        output_dir = project / output_dir
    capture, trace, execution = _run_capture(project, godot, output_dir)
    classification = classify_capture(capture, trace)
    trace_path = pathlib.Path(execution["trace_path"])
    result = {
        "schema": "world_transvoxel.cpu_b3a_lod_opening_evidence.v1",
        "capture": capture,
        "classification": classification,
        "execution": execution,
        "provenance": _provenance(project, godot, affinity, capture, trace_path),
    }
    output_path = output_dir / "classification.json"
    output_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(
        "WT_CPU_B3A_LOD_OPENING_RESULT "
        f"status={classification['milestone_status']} "
        f"result={classification['result']} "
        f"valid={classification['valid']} output={output_path}"
    )
    return 0 if classification["valid"] else 1


if __name__ == "__main__":
    sys.exit(main())
