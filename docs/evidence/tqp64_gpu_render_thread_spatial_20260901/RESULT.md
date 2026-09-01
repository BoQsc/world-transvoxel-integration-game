# TQP-64 GPU Render-Thread Spatial Checkpoint

Status: `RENDER_THREAD_WORK_REDUCED_GPU_GAMEPLAY_REJECTED`.

Authority remains upstream `18a892f`; native binaries and CPU collision authority
are unchanged from the preceding publication-lifecycle checkpoint.

## Change

- Camera transform inversion and projection lookup are computed once per view,
  not once per resident surface.
- Mono-view terrain push constants are built once when a resident entry is
  prepared, not rebuilt for every visible terrain draw every frame.
- Non-empty active entries are indexed into conservative 128-world-unit draw bins.
  A bin outside the camera frustum rejects its enclosed surfaces together; bins
  touching the frustum retain the original per-surface culling test.
- An oracle checks 26,480 randomized boxes over eight camera transforms and
  requires every visible member to have a visible enclosing bin.

This is render submission organization only. It does not alter geometry, LOD
plans, transition masks, publication cohorts, terrain materials, water ordering,
collision demand, player guards, or the default CPU backend.

## Measurements

On consecutive three-CPU diagnostic routes, render callback time falls from
4,187.551 to 3,026.417 microseconds per callback. Per-surface visibility tests
fall from 414,740 to 66,424; 246,156 bin tests conservatively reject 302,284
surfaces, and indirect draws fall from 49,725 to 39,058. Process CPU time falls
from 73.531 to 67.531 seconds. Different accepted movement means this is a
stage-level observation, not a matched-workload speedup claim.

The clean diagnostics-off run still fails: 485/1,020 blocked movement steps,
longest block 92, post-draw p50/p95/p99 23.366/51.329/84.498 ms, and no first
edit target after 3,006.038 ms. Compared with the preceding default run, CPU time
is slightly lower (75.984 vs 77.422 seconds), but wall time and frame tails do
not establish an end-to-end improvement.

An opt-in foreground-priority run now addresses all seven chunks along the
bounded 96-unit cursor ray. It still misses the first edit and is not enabled by
default. This rules out a simple priority-only fix; it does not justify broader
collision demand or weaker publication rules.

Vulkan and D3D12 production lifecycle smokes pass with local CPU physics and zero
visual geometry readback. The GPU backend remains unqualified. Publication-to-
player-support latency and frame tails are still the release blockers.
