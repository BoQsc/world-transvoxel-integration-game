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
- post-draw p95/p99: `44.032 / 69.307 ms`;
- relocated physics target: absent after `180` frames / `2,987.787 ms`;
- edit: not accepted because no authoritative target was available.

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
