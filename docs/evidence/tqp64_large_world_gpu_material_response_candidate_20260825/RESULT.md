# TQP-64 Bounded Material Response Candidate

Status: `RETAINED_BOUNDED_MATERIAL_RESPONSE_PRODUCTION_BLOCKED`

Date: 2026-08-25

## Scope

This slice extends the default-off GPU-resident renderer from exact production
albedo mapping to the accepted terrain shader's roughness selection, current
geometric-normal behavior, a bounded Burley diffuse response, and the accepted
static-water shader's deep/edge Fresnel tint and rear-face response. It retains
CPU authority, zero geometry readback, the paged arena, compact world-space
drawing, conservative culling, and targeted CPU collision.

The claim is deliberately bounded. Raw compositor drawing does not participate
in Godot Forward+ scene lights, shadows, or environment response, and the water
path does not sample the opaque screen texture for refraction. Full terrain and
static-water material parity therefore remain false.

## Authority Finding

The accepted `wt_game_terrain_palette.gdshader` declares and samples a normal
texture helper, but its production fragment does not write `NORMAL_MAP` or
otherwise apply that sampled normal. The authoritative current behavior is the
geometric mesh normal. The GPU path preserves that behavior; it does not invent
a normal perturbation and does not claim normal-map parity.

Changing the accepted CPU shader to apply normal maps is a separate visual and
material-authority decision requiring its own CPU/GPU comparison and human
review.

## Focused Qualification

Vulkan and D3D12 pass the lifecycle and bounded visual fixtures with:

- exact accepted terrain and static-water shader source hashes;
- a 368-byte terrain payload, five terrain textures, and a 48-byte water
  payload;
- exact albedo and roughness selection;
- exact accepted geometric-normal behavior and bounded Burley response;
- water deep/edge Fresnel tint and rear-face response;
- a visibly changed water capture compared with the terrain-only capture;
- simultaneous LOD0/LOD1/LOD2 terrain inventory (`16 / 4 / 1`), zero overlap,
  zero geometry readback, and CPU collision authority.

The unchanged diagnostic renderer remains byte-identical on Vulkan and D3D12
with SHA `b4f424159ca782f3ed0f27ef2144cf391bc19398a1024675db68ca9627823ed8`.

## Matched Large-World Result

The fresh Vulkan comparison uses the deterministic G23 2,048 x 256 x 2,048
route, production texture arrays, relocation, flight, carve, construction, and
at most three logical CPUs.

| Measurement | CPU-only | GPU resident | Change |
| --- | ---: | ---: | ---: |
| Frame p95 | 21.90 ms | 33.15 ms | +51.39% |
| Frame p99 | 33.20 ms | 39.68 ms | +19.50% |
| Route wall time | 53.34 s | 79.85 s | +49.71% |
| Maximum RSS | 1.74 GB | 1.75 GB | +0.14% |
| Mean process CPU | 158.93% | 156.13% | -1.76% |
| Mean GPU utilization | 23.03% | 19.86% | -13.76% |
| Mean GPU board power | 29.16 W | 26.97 W | -7.50% |

GPU telemetry is board-global, not process-attributed, and the candidate runs
substantially longer. Lower board means do not override the frame and wall-time
failures.

## Runtime Facts

- Production albedo, roughness, accepted normal response, bounded Burley
  response, and water Fresnel tint remain stable throughout the measurement.
- Full terrain Forward+ parity, water refraction, and full water material parity
  remain false.
- Maximum terrain inventory is 33 LOD0 plus 31 LOD3; LOD1 and LOD2 are absent.
- Maximum water inventory is 11 LOD3 surfaces.
- Maximum resident chunk coverage remains 17.16%, below the 95% gate.
- Downstream genuine resident rejection remains zero; 203 obsolete generations
  are classified as superseded work.
- Native admission rejects 513 reservations and 2,108 captured requests at the
  fixed residency boundary. Final queued requests and reservations return to
  zero.
- The shared arena reaches 76 allocated slots, 75 active surfaces, and
  443,686,480 bytes.
- 196,743 visibility tests cull 121,535 surfaces and submit 75,208 compact
  commands while avoiding 805,784,120 source-cell command records.
- Geometry readback, CPU chunk finalization, and ArrayMesh upload remain zero.

## Decision

Retain the exact roughness mapping, accepted geometric-normal response, bounded
Burley response, static-water payload, Fresnel/deep-edge response, explicit
response telemetry, and terrain-before-water draw ordering.

Do not promote the backend. It fails full Forward+ terrain response, water
refraction, complete LOD inventory, 95% coverage, native admission, frame-p95,
and wall-time gates. It still starts from completed CPU mesh input.

The next bounded architecture step is GPU-first field evaluation and regular
and transition Transvoxel extraction. Full material integration remains a
release gate and must be revisited through a standard Godot render integration
path; reproducing the entire Forward+ renderer inside the addon is not an
acceptable shortcut. Complete large-world residency and LOD0-through-LOD3
coverage follows the GPU-first handoff. Vulkan must pass before a D3D12
large-world run or promotion.

Machine-readable evidence: [qualification.json](qualification.json).
