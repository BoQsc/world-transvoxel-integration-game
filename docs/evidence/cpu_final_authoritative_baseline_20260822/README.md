# Final Authoritative CPU Terrain Baseline

This record closes CPU-B3 on the retained three-logical-CPU host. Correctness,
ownership, resource bounds, source structure, integration, and causal
attribution pass. Player-facing performance remains a measured target miss.

## Exact Identity

- native authority: `b35491948e126f6f660f64ad89532acbc50895bc`;
- integration trace-off measurement: `eceaa8759a84be66b33e2b571720374ab3ddc35f`;
- integration causal measurement: `9518d303f895845efce8afea04e763f24dea695c`;
- Godot: `4.7.2`, Windows x86-64, Forward+ Vulkan;
- logical CPU affinity: `[0, 1, 2]`;
- procedural generation workers: `2`;
- accepted runtime meshing workers: `0`;
- fallback terrain implementation: none.

The exact authority addon tree is
`52d2d3f0c29f587fb4fe23489a15f74f1de478f6`; its native source tree is
`6b6f20cbc8559cb54b8e5b8a3e3c41cd0a9fe303`. The consumed runtime artifact
digest is `79f692d7b971b1c050ab603f8ee9fb569df5ed328b8dc93222c554324a1c3e9e`.

## Correctness And Resource Result

All 62 current native executables pass in debug and release under the exact
CPU affinity. All ten Godot integration smokes pass. The source validator has
no hard-limit failures. Debug/release deterministic hashes agree, transition
lifecycles are complete, render/collision ownership does not diverge, caches
remain within entry and byte ceilings, and storage queues are not implicated
in the measured relocation hitch.

## Trace-Off Performance Result

Three fresh-storage runs report `MEASURED_TARGET_MISS`:

- frame p95 median: `32.691 ms`;
- frame p99 median: `38.660 ms`;
- relocation visual/collision readiness median: `8692.049 ms`;
- blocked movement frames: median `8`, maximum `25`;
- maximum consecutive blocked frames: median `4`, maximum `7`;
- maximum mesh job median: `72.5803 ms`;
- maximum scheduler queue: median `745`, maximum `752`;
- maximum pending replacements: median `739`, maximum `756`;
- average active-core equivalents: median `1.5344`;
- peak process-tree RSS: median `846192640` bytes.

The trace-off aggregate SHA-256 is
`7ae733dcd437466e40f14b690b0ca4ff9196af716cba3bf455c8693b1fd350a3`.

## Causal Result

The lossless causal run retained `138608` native events with zero source
overwrite, local drops, consumer gaps, downstream drops, missing required event
kinds, invalid transition masks, or unsuccessful transition chains.

Edited required chunks reached their last sink by `1474.252 ms`; the final edit
replacement was ready by `1506.8255 ms`. The first visibility batch did not
publish until `7772.796 ms`, leaving `6298.544 ms` after sink completion. The
classification is `GLOBAL_VISIBILITY_STAGING_BARRIER_AFTER_RELOCATION`.

Movement rejection is separately classified as
`COLLISION_READINESS_GATE_DURING_RELOCATION_BACKLOG`. At the largest movement
frame, movement was accepted while `619` replacements, `1967` required but
not-ready collision chunks, `1760` retirements, and `601` scheduler jobs were
pending. Storage queued requests were zero.

This establishes a conservative global visibility/replacement/collision
backlog fed by serial CPU meshing as the material remaining bottleneck. It does
not establish a Transvoxel topology defect or a storage, edit transaction,
cache ownership, collision ownership, or publication-order defect.

## Qualification Boundary

The CPU implementation is frozen as the correctness reference and comparison
baseline. This is not a Terrain 1.0 performance pass, a sustained 60 FPS claim,
a 16 W claim, or a claim that every future CPU optimization is impossible.
Repeated human playtests accepted the preceding behavior with known temporal
limitations; the exact final artifact changed diagnostics and source structure,
not terrain behavior. No new human visual review is claimed for this record.

The evidence is sufficient to close CPU-B3 and admit TQP-58. It does not by
itself promote a GPU backend.
