# GPU Runtime Blockers: 2026-08-30

Status: `GPU_GEOMETRY_AND_GAMEPLAY_PERFORMANCE_REJECTED`. This is a development checkpoint,
not a release, a human-accepted baseline, or proof of GPU speedup.

Historical result: the later
[reciprocal publication checkpoint](../tqp64_gpu_reciprocal_publication_20260830/RESULT.md)
adds an isolated native regression and reciprocal boundary fix, then passes
the 25-sample Vulkan route and strict final drain. It also fixes a separately
identified late-water retirement race. Gameplay performance remains rejected.
The failed geometry and measurements below are preserved, not reclassified.

## Scope

Godot 4.7.2 Steam, GTX 1060 Max-Q, Vulkan, three logical CPUs `[0, 1, 2]`,
G23 2048 x 256 x 2048, production texture-array materials, generation workers
2, meshing worker override 0 (existing default), collision radius 2 and
prediction distance 24. Runs use the existing runtime baseline route and the
tools/editor executable. Causal tracing and geometry/image readback probes are
off during the measured route. Stage timing is enabled only in diagnostic runs.

## Findings And Changes

1. The earlier moving-LOD hole was reproduced with exact resident geometry and
   lifecycle identities. Upstream commits `479deb0`, `579ed5e`, and `0a9b3c9`
   reject stale transition masks, expose regional retirements, and gate coarse
   transition publication on required finer-face dependencies. The current
   integration runtime is pinned to `0a9b3c9`.
2. A D3D12 fixed-coordinate regression measured X `1249.000122070313` instead
   of `1249`, caused by weighted interpolation of equal endpoint coordinates.
   GPU edge interpolation now copies fixed components exactly. The assertion
   remains exact, not tolerance-expanded.
3. Native retirement records contain coordinates and LOD, not generation or
   transition mask. The downstream lookup incorrectly required the latter and
   could classify GPU retirements as CPU-only. A per-cohort spatial index now
   resolves unique active identities; ambiguity fails closed. Exact identities
   and publication sequences still reach the atomic render-thread transaction.
4. Each activated/retired surface rebuilt the full diagnostic LOD inventory
   while holding the shared renderer lock. Rebuild it once per lifecycle batch,
   with the scan outside the shared lock. No activation, retirement, or identity
   validation is skipped. The isolated 64-entry test verifies one rebuild for
   activation and one for retirement with exact counts.
5. Activation packed every resident inventory even after the authority selected
   a smaller cohort. It now resolves only selected members through the existing
   identity map. Native commit still recomputes and validates membership;
   missing and in-flight members cause a wait, not a partial commit.
6. Lifecycle history is now opt-in (`--gpu-lifecycle-history` or the explicit
   debug setter); disabling it clears the history and bypasses event collection.
   The moving-LOD capture enables it deliberately. The bounded test checks the
   disabled path, 512-event limit, snapshot isolation, and disable/reset behavior.

## Measurements

The old `frame_time_ms` field measures physics-signal intervals. Catch-up
physics ticks make it unsuitable as a rendered-FPS distribution. The new
`render_frame_interval_ms` measures wall time between `frame_post_draw` signals,
not physical display presentation or GPU execution time. Both fields are kept.

| Run | Post-draw p95 | Post-draw p99 | Maximum | Movement blocked | Edit |
| --- | ---: | ---: | ---: | ---: | --- |
| CPU reference, tracing off | 36.123 ms | 41.055 ms | 64.676 ms | 0/1020 | Exact render/collision readiness 7.074 s after relocation |
| GPU before batching/spatial fix, stage timing on | 251.258 ms | 836.284 ms | 1435.012 ms | Failed | No target within observation window |
| GPU batching/spatial fix, tracing off | 129.670 ms | 204.624 ms | 354.888 ms | 520/1020 | No target within observation window |
| GPU selected-cohort inventory, tracing off | 107.399 ms | 165.096 ms | 215.649 ms | 587/1020 | No target within observation window |
| GPU final, stage timing and lifecycle history off | 86.920 ms | 118.940 ms | 225.957 ms | 569/1020 | No target within observation window |

These are short, individual runs, not statistically qualified gains. Movement
blocking changes the achieved camera path, and the GPU run never submits a
successful edit, so **no CPU/GPU speedup ratio or GPU edit latency is valid**.
CPU also misses the existing frame-tail and edit-readiness targets. No wattage,
energy/frame, release-export, D3D12 gameplay, or human acceptance claim is made.
The earlier "tracing off" rows mean causal/stage tracing off; they still collected
the newly added bounded lifecycle history. Only the final row disables that
history as well (zero retained events verified). The final maximum is higher
than the preceding run, and memory rises from about 809 MB to 1,080 MB; these
individual runs do not justify claiming every performance metric improved.
`measurements.json` retains six runs, commands, acceptance failures, frame/phase
summaries, process statistics, timing aggregates, and hashes of the original
results/logs. The failed-target `edit_position` and `target_chunk` are ray-endpoint
placeholders, not evidence that terrain exists at Y = -20 or in chunk Y = -2.

The first stage diagnostic observed controller activation retries up to
3.641 s and effect-event handling up to 1.670 s. A subsequent breakdown measured
retirement lookup work up to 327.772 ms per cohort. Native cohort query/commit
maxima in that breakdown were 8.424/16.258 ms. These explain concrete software
costs, not a fundamental GPU or Transvoxel limitation. Timings include startup;
nested stage totals must not be added together. Render-thread dispatch/draw
measurements are CPU submission durations, not GPU execution durations.

## Validation Truth

- A pre-final-correction 25-sample moving-LOD route passed, including the old
  failing ridge sample, and drained all final replacements/retirements. This is
  a sampled no-gap result, not a proof of whole-world watertightness.
- The final geometry/publication rerun failed at `12_peak_sweep_f054`: 12
  earlier samples pass (including ridge 06), then the capture and confirmation
  contain isolated sky pixels. The route stops after 13 samples. The later
  optional-history-only change does not constitute a new passing visual run.
- Vulkan/D3D12 atomic publication retained image SHA-256
  `28b91dc7ebbbb271dd53cb92e90bd75cc96b78e78b09d76c7e15ae03555369fd`.
- Vulkan/D3D12 meshing passed, including exact fixed coordinates on all three
  axes over 1,512 cells / 6,048 vertices with positive and negative origins.
- The activation-retry smoke passed spatial retirement, selected-only inventory,
  in-flight exclusion, batched accounting, exact-generation acknowledgment, and
  opt-in history checks. The artifact validator passes upstream pin `0a9b3c9`
  with no duplicated native sources and no fallback.
- The runtime edit measurement now requires a GPU activation acknowledgment in
  addition to native render-generation readiness. This is not photon/display
  latency. Failed target acquisition remains failed; no timeout was extended.
- Incomplete runs can be retained explicitly by the Python runner as
  `MEASUREMENT_INCOMPLETE`; default strict validation is unchanged.

## Exact Remaining Seam

`peak_sweep_failure.json` preserves the failed sample, exact resident geometry,
camera, pixel rays, coverage inventory, and lifecycle records. The two original
screenshots are retained separately. Broad dark roads in those images are not
used as proof of holes.

Run `python docs/evidence/tqp64_gpu_runtime_blockers_20260830/reproduce_saved_seam.py`.
It independently intersects the saved ray against all 2,413 triangles exported
for that ray, with no intersection. At shared face Z = 896 the ray crosses
`(1210.732127, 32.368383, 896)` between these actual mesh edges:

- Fine LOD2 `(18, 0, 14)`, generation 1352, mask 0: Y = 32.367182.
- Coarse LOD3 `(9, 0, 6)`, generation 1262, mask 1: Y = 32.397995.

The 0.030813-unit opening is a real coarse/fine boundary mismatch in the captured
active set. Coarse mask 1 contains no positive-Z transition (bit 32). Lifecycle
history records the old coarse neighbor active at frame 449, the fine replacement
active at frame 573, and the overlapping old coarse `(9, 0, 7)` retired at frame
574. The neighbor's required transition was not part of that observed swap.

This proves an incompatible published boundary, not a flaw in the Transvoxel
paper or a GPU hardware limitation. The exact missing dependency in native
cohort selection versus downstream transaction handling still needs an isolated
regression and fix. Do not revert the retirement correction to mask the crack
with overlapping geometry. The current generic CPU geometry probe reports
not-applicable for GPU geometry; its false gap flag is not a watertightness pass.

## Next, In Order

1. Reproduce the captured fine-replacement/coarse-neighbor boundary in a small
   publication test, and make the required transition change part of the same
   authoritative transaction. Verify both refining and coarsening without
   depending on overlapping retained meshes to cover cracks.
2. Isolate GPU player-support and targeted-collision readiness during ordinary
   movement, including the exact missing collision chunk after relocation.
   Distinguish collision demand absence from generation/publication backlog.
   Do not hide the failure by removing the support guard, extending timeouts,
   adding broad always-on collision, or forcing the player through terrain.
3. Use the opt-in `--gpu-stage-timing` aggregates to isolate the remaining
   activation/native/frame-thread costs; preserve authoritative cohort ordering.
4. Complete the same trace-off CPU/GPU movement and carve/construction workload
   successfully before comparing performance. Repeat to bound run-to-run noise.
5. Complete post-edit LOD and terrain/water visual gates, cross-backend gameplay,
   power measurement, and human validation before any default-backend change.

There is not enough evidence for an honest completion-date estimate. The backend
is implemented, but reliable gameplay and smooth frame delivery remain open.
