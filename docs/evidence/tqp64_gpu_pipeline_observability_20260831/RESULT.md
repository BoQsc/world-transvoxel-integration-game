# TQP-64 GPU Pipeline Observability Checkpoint

Date: 2026-08-31

Status: `CONTROLLER_DRAIN_IMPROVED_GAMEPLAY_REJECTED`

## Scope

- Exact native authority pin: `world-transvoxel` `236045f80a2388d691c35a08fc614fef87c3d7d0`.
- Godot 4.7.2, Vulkan and D3D12 lifecycle coverage, at most three logical CPUs.
- CPU remains the default and owns world, storage, edits, publication policy,
  and collision.
- GPU resident rendering remains explicit opt-in and performs zero production
  geometry readback.

## Implemented

- Stale activation seeds are discarded before spending the single live native
  activation-query attempt for the frame.
- Pending activation groups are scanned once and reused by supersession and
  retry processing.
- Production texture RIDs are cached and invalidated when source textures
  change.
- ESC diagnostics expose actual native collision shapes, chunk LOD bounds, GPU
  publication stages, live queue/timing HUD, and JSON snapshots.
- Disabled diagnostics do not query terrain state, time pipeline stages, or
  create wireframes.

## Results

The sampled moving-LOD fixture passes all 25 views and reaches 1,219 active,
fully ready records with zero queued work, replacements, or retirements. Its
final drain improves from the preceding 21,348 ms / 368-frame checkpoint to
5,896.080 ms / 110 frames. The capture reports zero native validation or
controller rejection. Topology probing was disabled, so this is not exhaustive
watertightness certification.

The diagnostics-off GPU movement/edit gate remains rejected:

- movement blocked: `583 / 1,020` frames;
- longest consecutive block: `161` frames;
- physics-signal p95/p99: `44.032 / 69.307 ms`;
- relocated physics target: absent after `180` frames / `2,987.787 ms`;
- edit: not accepted because no authoritative target was available.

Correction: the `44.032 / 69.307 ms` values above were originally labelled as
post-draw timing but are physics-signal intervals. The actual post-draw p95/p99
for that run are `54.896 / 111.895 ms`. Physics catch-up can emit several signals
between rendered frames; its percentiles must not be used as rendered-frame
percentiles. The raw measurements were not changed.

The unchanged CPU control has zero blocked movement frames but still reaches
relocated visual/collision readiness only after `403` frames / `6,802.333 ms`.
It also remains outside the latency contract.

## Diagnosis

A traced destination chunk was sampled, meshed, and delivered to downstream
publication in tens of milliseconds. It then waited behind an atomic publication
component containing hundreds of replacements and retirements. This rules out a
simple missing GPU dispatch as the dominant remaining delay. The next work must
reduce that authoritative residency/publication dependency with proof that
retained coverage, LOD transition compatibility, and collision ordering remain
correct.

This checkpoint is not a completed GPU terrain implementation, accepted
performance baseline, or release candidate. No priority shuffle, timeout
increase, CPU visual bridge, fallback terrain, or weakened correctness guard was
retained.

## Visual Evidence

- `debug_collision.png`: real `WT_Collision_*` triangle shapes and generation
  state.
- `debug_lod.png`: resident LOD bounds.
- `debug_pipeline.png`: extraction, prepare, cohort, activation, active, and
  retirement state.

The captures are diagnostics and are not performance measurements.

## Submission Sweep and Final Retained State

The controller now admits up to eight native requests per frame while retaining
the original sixteen in-flight slots. CPU default, worker limits, collision
guards, publication membership, and timeouts remain unchanged. This is a bounded
controller improvement, not a resolution of the large publication dependency.

These are individual diagnostics-off runs on the same pinned artifact, not a
statistically qualified speedup or equivalent completed CPU/GPU workloads:

| Submissions/frame | Movement blocked / 1,020 | Longest block | Post-draw p95/p99 ms | Final moving-LOD drain |
| --- | ---: | ---: | ---: | ---: |
| 4 | 583 | 161 | 54.896 / 111.895 | 5.896 s / 110 frames |
| 8, retained | 503 | 106 | 51.303 / 91.284 | 5.074 s / 65 frames |
| 16 | 491 | 101 | 57.719 / 100.675 | 4.308 s / 60 frames |

Eight is the provisional throughput/frame-tail compromise. Both new moving-LOD
runs pass their 25 sampled views and strict final readiness check. The retained
run ends with 1,219 active/fully-ready records and no pending replacements.
The retained gameplay run still has no physics target after 180 frames /
2,995.925 ms and does not accept its edit. All three gameplay runs fail the
existing acceptance contract. Post-draw timings are wall-clock intervals between
`frame_post_draw` signals, not display-present measurements or GPU-only times.

Two 32-slot trials were removed:

- The first used the pinned 16-slot debug DLL with a 32-slot downstream window;
  it was not an end-to-end 32-slot test.
- The second used 32 slots throughout but its native build omitted the normal
  `build_profile=build_profiles/world_transvoxel.json`. It recorded 531 blocked
  steps and post-draw p95/p99 of 70.851/153.921 ms. Capacity and build configuration
  both changed, so this is a rejected combined experiment, not proof about the
  effect of capacity alone.

After reverting the experiment, rebuilding debug/release with the correct
profile reproduced the original artifact digest exactly:
`d96d92d8e951016631ae955132c6da6a72832480d54c0fa8a145814243752089`.
Upstream source is unchanged and the integration artifacts match it. No binary
pin was changed to accept the experimental builds.

`submission_sweep.json` retains both explicitly named timing clocks, acceptance
failures, build qualifications, and raw-file hashes. `submission_sweep_raw.zip`
preserves the five original gameplay reports and the two moving-LOD logs/data.
The baseline aggregator now emits v2 with distinct `physics_signal_interval_*`
and `frame_post_draw_interval_*` fields. It rejects unsupported/missing timing
contracts and incomplete runs instead of labelling them a completed baseline.
Earlier v1 reports remain historical; their `frame_p95_ms` is not a post-draw
measurement.

Final regression checks: retry/admission fairness, Vulkan/D3D12 production
lifecycle, reporting unit tests, binary artifact validation, and authority
package synchronization pass. This does not close the inherited M5 wrapper
fingerprint discrepancy or any gameplay acceptance failure.

## Remaining Publication Work

Inspection of native `wt_build_gpu_chunk_publication_cohort` confirms that
replacement/retirement coverage and reciprocal transition masks can connect a
large set of chunks. Collision cannot be exposed early while its matching visual
generation is still waiting for activation. Relaxing that rule would exchange
the delay for invisible or stale support.

The current native selector does not receive a generation-bound empty-surface
proof. The renderer's empty-entry count is therefore not sufficient authority
to prune dependencies. Any empty-space reduction must prove both terrain and
water empty for the exact source revision/generation/transition footprint,
retain parent/child coverage, and pass boundary/edit regressions. Otherwise the
larger fix is incremental LOD publication with masks valid against the retained
visible neighborhood, rather than only the final desired plan. Neither change
was implemented in this checkpoint. This is the next structural blocker, not
evidence that GPU computation is inherently too slow.
