"""Bounded visible GPU startup probe; terminates only the process it launches."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import pathlib
import shutil
import subprocess
import time

import psutil


@contextmanager
def temporary_debug_dll(project: pathlib.Path, candidate: pathlib.Path | None):
    if candidate is None:
        yield
        return
    target = project / "addons/world_transvoxel/bin/world_transvoxel.windows.template_debug.x86_64.dll"
    backup = project / ".godot/world_transvoxel_captures/base_coverage_probe/pinned_debug_backup.dll"
    if backup.exists():
        shutil.copy2(backup, target)
        backup.unlink()
    shutil.copy2(target, backup)
    try:
        shutil.copy2(candidate, target)
        yield
    finally:
        shutil.copy2(backup, target)
        backup.unlink()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", type=pathlib.Path, required=True)
    parser.add_argument("--seconds", type=float, default=15.0)
    parser.add_argument("--memory-gib", type=float, default=3.0)
    parser.add_argument("--mode", default="ground")
    parser.add_argument("--native-debug-dll", type=pathlib.Path)
    args = parser.parse_args()
    project = pathlib.Path(__file__).resolve().parents[1]
    out = project / ".godot" / "world_transvoxel_captures" / "base_coverage_probe"
    out.mkdir(parents=True, exist_ok=True)
    log_path = out / "godot.log"
    capture_path = out / f"{args.mode}.png"
    capture_path.unlink(missing_ok=True)
    command = [
        str(args.godot), "--path", str(project), "--",
        "--p2-profile", "g23_four_biomes_lakes_mountains_roads_2k_256_on_demand",
        "--human-material-mode", "production_texture_array",
        "--human-windowed", "--gpu-resident-render-candidate",
        "--human-visual-capture", str(capture_path),
        "--human-visual-capture-mode", args.mode,
        "--human-visual-capture-wait-frames", "1",
        "--human-visual-capture-timeout-frames", "90",
    ]
    started = time.monotonic()
    peak_rss = 0
    with temporary_debug_dll(project, args.native_debug_dll), log_path.open("wb") as log:
        process = subprocess.Popen(command, cwd=project, stdout=log, stderr=subprocess.STDOUT)
        measured = psutil.Process(process.pid)
        reason = "completed"
        while process.poll() is None:
            if time.monotonic() - started >= args.seconds:
                reason = "time_limit"
                break
            try:
                rss = measured.memory_info().rss
            except psutil.NoSuchProcess:
                break
            peak_rss = max(peak_rss, rss)
            if rss >= int(args.memory_gib * 1024**3):
                reason = "memory_limit"
                break
            time.sleep(0.25)
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
    lines = log_path.read_text(errors="replace").splitlines()
    markers = [line for line in lines if any(tag in line for tag in (
        "WT_BOOT_STAGE", "WT_GPU_INIT_STAGE", "WT_GPU_BASE_COVERAGE_READY",
        "WT_GPU_BASE_EDIT_PROBE",
        "GPU base coverage", "ERROR", "SCRIPT ERROR",
    ))]
    draw_selection = None
    if args.mode == "base_coverage_edit_probe":
        probe_lines = [line for line in lines if line.startswith("WT_GPU_BASE_EDIT_PROBE ")]
        if probe_lines:
            probe = json.loads(probe_lines[-1].split(" ", 1)[1])
            samples = probe.get("samples", [])
            active_lod0 = [sample for sample in samples if int(
                sample.get("active_lod_counts", {}).get("0", 0)
            ) > 0]
            selected_lod0 = [sample for sample in active_lod0 if int(
                sample.get("selected_lod_counts", {}).get("0", 0)
            ) > 0]
            draw_selection = {
                "ok": bool(selected_lod0),
                "active_lod0_samples": len(active_lod0),
                "selected_lod0_samples": len(selected_lod0),
                "last_active_lod_counts": samples[-1].get("active_lod_counts", {}) if samples else {},
                "last_selected_lod_counts": samples[-1].get("selected_lod_counts", {}) if samples else {},
            }
        else:
            draw_selection = {"ok": False, "error": "edit probe marker missing"}
    result = {
        "reason": reason,
        "elapsed_s": round(time.monotonic() - started, 2),
        "exit_code": process.returncode,
        "peak_rss_mib": round(peak_rss / 1024**2),
        "capture_exists": capture_path.is_file(),
        "capture_path": str(capture_path),
        "log_path": str(log_path),
        "markers": markers[-40:],
    }
    if draw_selection is not None:
        result["draw_selection"] = draw_selection
    print(json.dumps(result, indent=2))
    return 0 if reason == "completed" and capture_path.is_file() and (
        draw_selection is None or draw_selection["ok"]
    ) else 1


if __name__ == "__main__":
    raise SystemExit(main())
