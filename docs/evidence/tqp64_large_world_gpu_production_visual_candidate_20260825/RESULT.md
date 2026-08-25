# TQP-64 Production Albedo And LOD Resident Candidate

Status: `RETAINED_ALBEDO_CAMERA_LOD_SLICE_PRODUCTION_BLOCKED`

Date: 2026-08-25

## Scope

This slice connects the accepted game terrain material payload to the
default-off GPU-resident renderer. It retains CPU authority, native world-space
v3 input, compact one-command-per-surface rendering, conservative camera
culling, the paged shared arena, and targeted CPU collision.

The generated raw RD shader consumes the same production texture arrays,
generated/authored material weights, and world-space biome, depth, ore, and
road parameters as `wt_game_terrain_palette.gdshader`. It does not reproduce
the Godot Forward+ normal-map, roughness/PBR, shadow, or static-water response.
The qualified claim is therefore production terrain albedo/material mapping,
not complete production material parity.

## Focused Qualification

Vulkan and D3D12 pass the bounded lifecycle and visual fixtures with:

- the exact accepted production shader source and five texture resources;
- a 368-byte production parameter block;
- live Godot camera transforms at two distinct views;
- simultaneous resident LOD0, LOD1, and LOD2 inventory (`16 / 4 / 1`);
- zero LOD coverage overlap and zero geometry readback;
- exact stale-work classification: 52 supersessions and zero rejection;
- back-face culling with the authoritative counter-clockwise mesh winding.

Vulkan retains 56,188 overview foreground pixels and 232,537 near-view pixels.
The diagnostic global renderer remains byte-identical on both drivers with
SHA `b4f424159ca782f3ed0f27ef2144cf391bc19398a1024675db68ca9627823ed8`.

## Matched Large-World Result

The valid Vulkan comparison uses the same deterministic G23 2,048 x 256 x
2,048 relocation, flight, carve, and construction route, production texture
arrays, and at most three logical CPUs.

| Measurement | CPU-only | GPU resident | Change |
| --- | ---: | ---: | ---: |
| Frame p95 | 23.85 ms | 31.13 ms | +30.51% |
| Frame p99 | 33.18 ms | 35.23 ms | +6.15% |
| Route wall time | 56.74 s | 62.11 s | +9.45% |
| Maximum RSS | 1.68 GB | 1.71 GB | +1.84% |
| Mean process CPU | 149.20% | 169.12% | +13.35% |
| Mean GPU utilization | 21.51% | 22.22% | +3.28% |
| Mean GPU board power | 28.55 W | 27.75 W | -2.81% |

GPU telemetry is board-global and is not process-attributed.

## Runtime Facts

- Production terrain albedo/material mapping is stable; full terrain material
  and static-water parity remain false.
- Maximum GPU terrain inventory is 64 chunks: 33 LOD0 and 31 LOD3. LOD1 and
  LOD2 are not represented in the large-world resident set.
- Maximum GPU chunk coverage is 17.16%, below the 95% gate.
- Candidate rejection and late arena-capacity rejection are zero.
- Expected stale application work is reported separately as 213 supersessions.
- Native admission remains saturated: 570 capture reservations and 2,367
  captured requests are rejected under the fixed resident limit.
- The corrected two-surface allocation reaches 66 active surface slots and
  397,449,584 allocated arena bytes without preallocating its legal ceiling.
- 146,980 surface-view tests cull 81,014 surfaces and submit 65,966 compact
  commands while avoiding 601,964,114 source-cell command records.
- Geometry readback, CPU chunk finalization, and ArrayMesh upload remain zero.

## Corrections Found By The Fixture

The focused fixture rejected two downstream defects before this measurement:

1. normal stale LOD refinement was mislabeled as geometry rejection; the
   controller now preserves upstream `STALE*` semantics as supersession;
2. resident allocation counted chunks although a production chunk may contain
   terrain and static-water surfaces; the legal demand-allocated ceiling now
   accounts for two surfaces per resident chunk plus bounded pending work.

The fixture also caught clockwise raw-RD front-face state hiding valid
Transvoxel geometry. Counter-clockwise front faces now retain back-face culling.

## Decision

Retain the production payload bridge, generated shader-source check, exact
camera transform, LOD inventory telemetry, stale classification, winding fix,
and corrected two-surface allocation.

Do not promote the backend. It fails full terrain material parity, static-water
parity, LOD0-through-LOD3 large-world coverage, 95% chunk coverage, native
admission, and frame-p95 gates. It still captures completed CPU mesh input, so
the duplicate CPU-plus-GPU path remains architecturally incomplete.

The next strict work is bounded full terrain material response and static-water
response, followed by GPU-first field evaluation and regular/transition
extraction. Large-world coverage must be solved without merely raising
capacities, and Vulkan must pass before a D3D12 large-world run is admitted.

Machine-readable evidence: [qualification.json](qualification.json).
