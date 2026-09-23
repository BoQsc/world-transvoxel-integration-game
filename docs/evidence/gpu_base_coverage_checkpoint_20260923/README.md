# GPU base coverage checkpoint (incomplete)

Native authority: `439c14d7` in `world-transvoxel`. The game pins the exact
debug/release DLLs and complete g23 LOD3 atlas. The GPU renderer uploads the
atlas before admitting player viewers, keeps it visible while finer coverage
streams, and cuts a base root only when a complete, balanced dynamic replacement
is ready. The CPU renderer remains the default.

Bounded Godot 4.7.2 Vulkan probe on a GTX 1060 Max-Q:

- `python tools/probe_gpu_base_startup.py --godot <godot.exe> --seconds 12 --memory-gib 3`
  captured a continuous ground view and exited in 12.06 s; peak process RSS
  was 776 MiB. The later run with the top-down base mode exited in 11.84 s at
  754 MiB peak RSS and captured the four-biome terrain without a visible void.
- The ordinary `topdown` mode did **not** converge within the 15-second bound.
  That mode waits for dynamic LOD readiness, so this remains a failed dynamic
  readiness gate; it was not extended to conceal the delay.
- `tests/gpu_base_coverage_cut_smoke.gd`, runtime artifact validation, terrain
  dependency boundary validation, and `git diff --check` passed.

These observations prove neither rapid edits nor collision correctness. The
atlas represents the pristine world revision; edited roots still need an
authoritative same-revision replacement path before this candidate is safe for
interactive play. LOD0 latency, movement waits, frame time, and power remain
unqualified. The GPU launcher remains opt-in.
