# GPU Collision Readiness Investigation

Status: `ADMISSION_FIX_VERIFIED_GAMEPLAY_STILL_REJECTED`.
CPU remains the default. This is not GPU completion, a speedup result, a new
human-accepted baseline, or a claim that CPU performance is satisfactory.

## What The Trace Establishes

The first blocked movement probes actual LOD0 support chunks, not a guessed
ray endpoint. In the complete native trace, the first block is at movement
frame 136 near `(351.35, 41.01, 351.18)`. Chunks `(22,2,21)`, `(21,2,22)`, and
`(22,2,22)` are present and **collision-required**, but have no applied collision.
The initial failure is not absent collision demand.

For `(22,2,22)`, generation 1301, native trace times are:

| Event | Seconds From Native Trace Start |
| --- | ---: |
| Demand accepted | 1.830201 |
| Sample job started | 2.117080 |
| Its page storage finished | 2.134845 |
| Mesh started | 2.958633 |
| Mesh finished | 2.966208 |
| Collision payload processed by frontend | 3.022924 |
| Collision sink applied | 12.503104 |

Mesh execution took 7.574 ms. Mesh finish to collision sink took 9,536.897 ms;
frontend receipt to collision sink took 9,480.181 ms. The other blocked chunk
`(21,2,22)`, generation 1321, finished meshing at 2.786153 s and reached the
collision sink at 16.411500 s. These are sink events, not claims about the exact
first physics frame that can use the collider.

The application defers nonempty collision while a staged visual replacement
is not ready. At the blocked snapshot, queued collision is zero but seven
collisions are deferred. GPU reports 51 prepared inactive chunks, with a visual
cohort waiting on other generations. These observations and the application
code locate a substantial delay **after meshing, at GPU visual publication**.
The globally last cohort wait is not necessarily the cohort of each support
chunk; the capture does not yet establish every dependency in that chain.

The relocated downward ray is also recorded with its actual traversed chunks.
Many local chunks are absent or pending after relocation. A failed ray endpoint
at `(562.6,-20.4,560)` is not an actual terrain hit. The CPU control acquires an
actual physics hit in `(35,2,35)` and accepts the edit. These results do not prove
all target misses have the same cause as the first movement block.

## Scoped Correction

Upstream `8e5102eabf4691969d4d5f6d11b1b1e5f9d4f331` removes a separate,
demonstrated dependency: collision-only meshing was required to reserve GPU
visual capture slots. Such chunks have no resident visual to publish.

The native regression fills both GPU capture slots and requests a nonempty
collision-only chunk. Before the fix it fails in synchronous and asynchronous
meshing. Afterward it publishes collision without a hidden render, without a
GPU capture, and without consuming the occupied reservation. Promoting the same
chunk to visual demand still waits for capacity, then resumes with pre-mesh GPU
input after the reservation is released. CPU collision extraction is retained.

This does not bypass a higher-priority visual job already at the scheduler
head, and it does not allow collision ahead of an unready required visual.
No publication boundary, player guard, collision radius, queue capacity, worker
count, observation window, terrain shader, or default backend was changed.
Native source stays in world-transvoxel; integration consumes its pinned DLLs.

## Gameplay Retest

Godot 4.7.2 Steam tools executable; GTX 1060 Max-Q; Vulkan; G23 2048 x 256 x
2048; production texture arrays; affinity `[0,1,2]`; generation workers 2;
meshing override 0; collision radius 2; prediction distance 24.

Readiness probe, causal tracing, stage timing, and lifecycle history are off in
the following runs. No build or other terrain test ran concurrently.

| Result | GPU Before | GPU After | CPU After |
| --- | ---: | ---: | ---: |
| Blocked movement / 1,020 steps | 574 | 611 | 5 |
| Maximum consecutive blocks | 100 | 142 | 5 |
| Post-draw p95 / p99, ms | 75.801 / 100.135 | 84.067 / 130.140 | 37.224 / 41.828 |
| Actual edit target acquired | No | No | Yes |
| Target wait, ms | 3,004.986 | 3,013.141 | 0 |
| Edit accepted | No | No | Yes |
| Visual/collision ready after commit, ms | Unmeasured | Unmeasured | 7,518.637 |
| Complete measurement | No | No | Yes |
| Acceptance | Fail | Fail | Fail |

There is **no demonstrated gameplay improvement**. The GPU results are incomplete
workloads, not speedup benchmarks. Each trace-off configuration was run once,
without thermal/power control; timing differences cannot establish a causal
regression or gain from this admission change. Exact pins, commands, durations,
and binary hashes are retained. New DLLs use the repository's documented SCons
build profile; do not assume binary-layout equivalence from their source diff.

Separate diagnostic captures also failed GPU movement/target acquisition. The
CPU diagnostic had zero movement blocks and an accepted edit, but took 6,309.839
ms after commit to publish the replacement. Probe-on timings are not performance
baselines. The native diagnostic retains all 58,938 events without dropped
events or consumer gaps; observer overhead is included in its metadata.

## Diagnostics And Verification

The optional probe records bounded support/ray inventories, current generations,
collision demand, applied/staged resource generations, viewer positions, and
pipeline/GPU counters. It samples at most 96 snapshots. Probe-off runs do not
instantiate it. Its support snapshot describes the last movement attempt, which
can precede an edit teleport; only `ray_inventory` describes the current ray.
An old causal-trace bug reported any non-null chunk snapshot as present. It now
uses `is_present()`, with a regression for absent native snapshots.

- Debug and release production streaming, M3 application, and GPU shadow pass.
- Readiness probe: face-aligned rays, negative coordinates, bounded capture,
  absent state, and coordinate serialization pass.
- Existing downstream activation-ordering smoke passes.
- Vulkan and D3D12 bounded resident lifecycle pass, including terrain/water
  publication, CPU collision authority, and no geometry readback.
- The CPU gameplay route remains operational but misses latency/frame targets.
- Runtime artifact synchronization and pin validation pass.

This turn does not repeat the full moving-LOD geometry qualification or human
review. The previous checkpoint's sampled geometry pass is not expanded into
new coverage. No power-efficiency or GPU hardware-limit claim is made.

## Reproduce And Continue

Run from the integration repository, using a new output name on each run:

```text
python tools/run_runtime_readiness_probe.py --backend gpu --native-trace --output .godot/gpu_readiness_new.json
python tools/run_runtime_readiness_probe.py --backend cpu --output .godot/cpu_readiness_new.json
python tools/run_runtime_readiness_probe.py --backend gpu --no-probe --output .godot/gpu_trace_off_new.json
```

The runner preserves failed measurements and returns failure when the unchanged
acceptance gate fails. `checkpoint.json` inventories retained files and hashes.
Large JSON/log evidence is gzip-compressed losslessly; `native_collision_timeline.json`
is an exact filtered excerpt for the three blocked chunk generations.

Next work is the GPU visual-publication dependency chain for those support
chunks: determine which required boundary members prevent activation, isolate
that chain in a deterministic regression, and reduce unnecessary dependencies
without weakening reciprocal LOD coverage or collision safety. Then repeat the
same route and actual edit. Do not respond by merely increasing workers,
changing priorities indiscriminately, extending waits, or removing the guard.
