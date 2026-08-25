# TQP-64 Compact World-Space GPU Resident Candidate

Status: `RETAINED_ARCHITECTURE_PRODUCTION_BLOCKED`

Date: 2026-08-25

## Scope

The default-off resident candidate was compared with CPU-only on the same
deterministic G23 2,048 x 256 x 2,048 relocation, flight, carve, and
construction route. Both fresh runs used Godot 4.7 Vulkan, production
texture-array mode, and at most three logical CPUs. CPU collision remained
authoritative.

This candidate retains the paged shared arena, native bounded admission, and
exact lifecycle. It adds:

- native v3 input in authoritative world position space;
- one GPU-written indirect command per resident surface instead of one per
  source cell;
- GPU-side compact index emission without geometry readback;
- conservative world-space AABB camera culling on the render thread.

The measurement is valid. Both routes completed, traces are intact, required
route coverage is present, and no trace events were dropped. A valid
measurement does not imply production promotion.

## Comparison

| Measurement | CPU-only | GPU resident | Change |
| --- | ---: | ---: | ---: |
| Frame p95 | 22.00 ms | 28.03 ms | +27.42% |
| Frame p99 | 33.21 ms | 33.24 ms | +0.11% |
| Route wall time | 51.13 s | 54.16 s | +5.93% |
| Maximum RSS | 1.63 GB | 1.57 GB | -3.44% |
| Mean process CPU | 159.73% | 174.13% | +9.02% |
| Mean GPU utilization | 23.49% | 21.44% | -8.71% |
| Mean GPU board power | 28.54 W | 27.51 W | -3.58% |

GPU telemetry is board-global and not process-attributed. The lower board
readings do not override the failed frame-p95 gate.

## Rendering Facts

- 99,942 resident surface-view tests were evaluated; 36,240 were culled.
- 63,702 compact indirect command records were submitted.
- 409,393,450 source-cell command records were avoided.
- The maximum visible compact inventory was 37 commands in one view.
- The maximum source-cell inventory avoided in one view was 208,859 records.
- Geometry readback, CPU chunk finalization, and `ArrayMesh` upload remain zero
  in the resident renderer.
- The exact global-publication image remains 27,312 foreground pixels with SHA
  `b4f424159ca782f3ed0f27ef2144cf391bc19398a1024675db68ca9627823ed8`.
- The nonzero multi-chunk relocation proof retains 9,107 foreground pixels
  with SHA `c694e37ab85ba685a35d7260a8b898609ec6d8dd08edcc2f7bcc61782dcaa38d`.

During qualification, telemetry exposed that prior resident inputs omitted the
CPU renderer's chunk-world instance offset. That run was invalidated. The
authority now adds `wt_chunk_bounds(key).minimum` while packing GPU positions
and bounds, and the request contract is versioned as world-space v3. Native
tests cover a nonzero LOD2 key, and production lifecycle/relocation tests
reject any non-world-space request.

## Lifecycle Facts

- Maximum active GPU chunks: 51; maximum coverage: 12.87%.
- Activated chunks: 52; retired chunks: 1.
- Native-packed requests: 2,648; prepared entries: 2,440.
- Shared-arena slot leases: 2,440; releases: 2,389; reuses: 2,373.
- Late resident arena-capacity rejections: zero.
- Native late capacity rejections: zero; capture reservation rejections: 663.
- Candidate chunk rejections: 2,540; application-wait expirations: 3.
- Final capture reservations: zero; fail-closed recovery events: zero.
- Production material parity: absent.

## Decision

Retain world-space native packing, compact one-command-per-surface emission,
conservative visibility culling, and their focused Vulkan regressions. These
fix concrete correctness and draw-submission defects and reduce the prior
per-cell rendering collapse.

Do not promote the production backend. It fails the p95-within-10% gate,
95%-coverage gate, zero-candidate-rejection gate, and production-material
parity gate. The request source also still records cells from completed CPU
meshing, so this is not a GPU-first terrain backend.

The next strict work is production material and camera/LOD visual parity,
followed by GPU-first field evaluation and regular/transition extraction.
Vulkan must pass the complete large-world gates before D3D12 large-world
execution or production promotion.

Machine-readable evidence: [qualification.json](qualification.json).
