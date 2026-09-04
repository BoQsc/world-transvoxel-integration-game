# GPU edit refinement investigation, 2026-09-05

Status: CORRECTNESS_FIXED_GAMEPLAY_LATENCY_REJECTED.

Authority `4682850b8d1773fbff947e17008812117716da49` fixes external viewer updates
overwriting internal refresh retries and invalid intermediate maps during direct
multi-split refinement. The inherited refresh event classification now also has
a failing-before regression. Seven native suites pass in debug and release;
twelve oriented/negative-coordinate planner regressions fail before and pass
after. The established LOD-streaming hash is unchanged.

Both integration DLLs were built with the repository profile and three-job cap,
then pinned together. Artifact and source identities are included in each report.
All four archived reports have matching pins. Compressed reports reproduce the
SHA-256 values in `manifest.json` after decompression.

## Clean measurements

All use the unchanged 2K relocation/edit route with diagnostics disabled and
three-CPU affinity. These are individual measurements, not a statistical speedup
claim. Every row completes and accepts the edit, but fails acceptance.

| Metric | Exact checkpoint control | Corrected refinement 1 | Corrected refinement 2 |
| --- | ---: | ---: | ---: |
| Commit frames | 4 | 4 | 5 |
| Collision after commit | 3 | 59 | 5 |
| First visual after commit | 20 | 42 | 64 |
| Final LOD0 after commit | 97 | 42 | 64 |
| Visual/collision divergence | 17 | 17 | 59 |
| Blocked movement / 1,020 | 0 | 0 | 1 |
| Physics-frame p95 ms | 19.020 | 18.013 | 20.503 |
| Post-draw interval p95 ms | 25.262 | 26.915 | 28.347 |

The fixes remove rejected viewer events and enable direct refinement, but do
not improve first-edit feedback. Faster final detail is not sufficient when
first visual or collision acknowledgment becomes slower. GPU remains opt-in.

## Rerun and diagnostics

The first native trace was interrupted by the user. Its rerun was stopped after
Godot RSS reached roughly 9 GB. The trace repeats the entire GPU inventory per
event; an older trace is about 1.2 GB on disk. Neither stopped run has a complete
baseline result, and neither is evidence of a performance pass.

The replacement readiness/lifecycle capture completed. It is explicitly
diagnostic-only and misses frame and latency limits; its timings must not be
compared to diagnostics-off runs. It shows the edited LOD0 chunk at
`35:2:35`, generation 2493, prepared at controller frame 1094, then waiting for
a 94-member regional cohort selected at 1118 and acknowledged active at 1119.
See `edited_chunk_lifecycle.json`. Earlier samples show over 100 pending
replacements and mandatory boundary-mask work. The target itself being prepared
does not imply that its visible topology can safely publish independently.

A candidate that waited for the current coarse edit activation before starting
refinement failed the existing bounded hierarchical edit regression: the coarse
edit could itself depend on refinement. That candidate was discarded completely.
Do not repeat this wait without modeling the dependency cycle.

Vulkan and D3D12 production lifecycle smokes pass with CPU collision authority,
zero geometry readback, zero CPU topology/field input, and the established
terrain/water material contracts. Full gameplay, moving-LOD, power, and human
qualification remain open.

## Next bounded problem

Preserve prompt edit feedback while preparing the balanced refinement cohort.
Model the old visible generation, its edited replacement, and the new LOD cohort
as separate obligations; identify which collision and boundary dependencies are
actually required for each transaction. Use a minimal coarse-to-fine edit fixture
with reciprocal neighbors, collision-only LOD0, and a second edit arriving during
refinement. Require first visual and collision acknowledgment to satisfy the
existing 15-frame / 8-frame divergence limits before claiming success.

Do not add queue reservations based on the previous narrative: actual sampled
scheduler occupancy is dozens of jobs against thousands of slots, and the new
evidence demonstrates publication-cohort delay. Reservation remains an unproven
hypothesis. Do not weaken seam ownership, stale-generation checks, or retained
coverage, and do not replace a dependency with a fixed-frame delay.
