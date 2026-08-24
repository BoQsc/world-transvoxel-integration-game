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
| Vulkan | 167 | 41 | 13 | 3 | 45 | 0 |
| D3D12 | 226 | 47 | 14 | 2 | 45 | 0 |

Both driver pairs have complete route and native traces, no dropped trace
events, no unknown completion, no identity mismatch, and no GPU publication.
The stale results are valid supersession outcomes under live relocation and
do not publish.

## Performance Observation

| Driver | Mode | Wall (s) | CPU mean (%) | Frame p95 (ms) | Frame p99 (ms) | Board GPU mean (%) | Board power mean (W) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Vulkan | CPU baseline | 66.96 | 150.5 | 24.45 | 33.23 | 20.9 | 26.9 |
| Vulkan | GPU shadow | 98.88 | 153.2 | 307.32 | 601.14 | 4.5 | 21.2 |
| D3D12 | CPU baseline | 80.40 | 127.9 | 31.10 | 39.24 | 28.9 | 17.5 |
| D3D12 | GPU shadow | 119.68 | 163.7 | 318.31 | 924.96 | 7.7 | 9.1 |

This is a negative performance result for the current shadow bridge, not a
GPU acceleration result. Its queue is deliberately limited to three requests;
it rejects 3,078 Vulkan and 3,303 D3D12 captures without delaying CPU
authority. Per-request readback and main-thread differential comparison make
this implementation suitable for validation only.

The NVIDIA readings are board-global and not attributed to the Godot process.
Trace-on frame timing is intrusive and is not the release performance baseline.

## Decision

Large-world live differential correctness is qualified for the retained
Vulkan and D3D12 scope. GPU publication is not qualified. The next production
slice must introduce batched persistent GPU resources, versioned publication,
and GPU-resident render consumption while preserving CPU world, edit,
revision, stale-result, and collision authority.

The compact machine-readable result is `qualification.json`. Raw traces,
reports, usage samples, and logs remain under
`.godot/world_transvoxel_captures/tqp64_gpu_shadow_qualification/` and are not
committed.
