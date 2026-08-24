# TQP-64 Large-World GPU Shadow Qualification

Date: 2026-08-24

Status: `PASS_LARGE_WORLD_SHADOW_VALIDATION`

## Scope

The paired qualification runs CPU-only and validation-only GPU shadow modes
on Vulkan and D3D12 using the G23 2,048 x 256 x 2,048 terrain profile. Every
run uses at most three logical CPUs and executes the same deterministic route:
ascent, two long relocation flights, live LOD changes, relocated carve, and
relocated construction.

The shadow cannot publish geometry. CPU rendering and targeted CPU collision
remain authoritative throughout all runs.

## Correctness

| Driver | Terrain matches | Transition matches | Carve-window matches | Construct-window matches | Stale | Mismatch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Vulkan | 74 | 3 | 7 | 11 | 39 | 0 |
| D3D12 | 102 | 3 | 6 | 17 | 79 | 0 |

Both driver pairs have complete route and native traces, no dropped trace
events, no unknown completion, no identity mismatch, and no GPU publication.
The stale results are valid supersession outcomes under live relocation and
do not publish. The native queue also supersedes 11 older queued Vulkan
captures and 19 older queued D3D12 captures so relocated work remains fresh
without increasing its three-request bound.

The GPU service uses 20 persistent buffers. Both drivers require two bounded
geometric capacity generations; Vulkan then reuses them for 111 dispatches and
D3D12 for 179. All 113 Vulkan and 181 D3D12 worker comparisons are clean.
Topology and integer metadata are exact. Vertices use an explicit float32
scale-aware bound, and normals use an absolute `1e-5` bound.

## Performance Observation

| Driver | Mode | Wall (s) | CPU mean (%) | Frame p95 (ms) | Frame p99 (ms) | Board GPU mean (%) | Board power mean (W) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Vulkan | CPU baseline | 65.92 | 145.8 | 26.82 | 33.33 | 20.1 | 28.2 |
| Vulkan | GPU shadow | 93.26 | 118.5 | 31.80 | 150.42 | 7.7 | 26.2 |
| D3D12 | CPU baseline | 72.28 | 140.0 | 29.14 | 34.42 | 30.1 | 19.6 |
| D3D12 | GPU shadow | 92.52 | 167.3 | 34.60 | 157.40 | 18.7 | 13.9 |

This qualifies the persistent validation architecture, not GPU acceleration.
Compared with the earlier per-request allocation/main-thread comparison run,
shadow p95 falls from 307-318 ms to 28-34 ms. The queue remains limited to
three requests and rejects 2,764 Vulkan and 2,716 D3D12 captures without
delaying CPU authority. Full geometry readback still produces 150-157 ms p99
and 28-41% longer route wall time, so this implementation remains suitable for
validation only.

The NVIDIA readings are board-global and not attributed to the Godot process.
Trace-on frame timing is intrusive and is not the release performance baseline.

## Decision

Large-world live differential correctness and persistent shadow resources are
qualified for the retained Vulkan and D3D12 scope. GPU publication is not
qualified. The next production slice must introduce versioned GPU publication
and GPU-resident render consumption while preserving CPU world, edit,
revision, stale-result, and collision authority.

The compact machine-readable result is `qualification.json`. Raw traces,
reports, usage samples, and logs remain under
`.godot/world_transvoxel_captures/tqp64_gpu_shadow_qualification/` and are not
committed.
