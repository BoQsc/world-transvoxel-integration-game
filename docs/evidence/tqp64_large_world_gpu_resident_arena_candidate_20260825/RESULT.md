# TQP-64 Shared-Arena And Native-Packing Candidate

Status: `ARCHITECTURE_BLOCKED_INTERMEDIATE_QUALIFIED`

Date: 2026-08-25

## Qualified Scope

- One 21-buffer global arena page serves four reusable resident surface slots.
- Compute dispatch and raster consumption retain exact per-slot identity and
  local indexed-draw coordinates.
- Outward-and-return relocation reuses retired slots; bounded Vulkan lifecycle,
  global viewport, resident resource, shadow, and matched-publication tests pass.
- Native v2 requests pack all 13 GPU inputs in C++; production GDScript packing
  remains zero and no diagnostic `cell_batch` is exported.
- CPU world, edits, revisions, publication checks, recovery, and collision stay
  authoritative. Geometry readback remains zero.

## Large-World Comparison

The retained G23 2,048 x 256 x 2,048 route uses Vulkan, production materials,
two procedural workers, and a three-logical-CPU process limit.

| Measurement | CPU-only | GPU resident | Change |
| --- | ---: | ---: | ---: |
| Frame p95 | 26.37 ms | 29.40 ms | +11.48% |
| Frame p99 | 33.24 ms | 34.20 ms | +2.88% |
| Route wall time | 67.33 s | 58.04 s | -13.80% |
| Maximum RSS | 1.70 GB | 1.71 GB | +0.55% |
| Mean process CPU | 143.89% | 165.25% | +14.84% |

Board-global GPU telemetry is retained but is not process-attributed and does
not decide promotion.

## Blocking Facts

- Maximum GPU chunk coverage: 15.55%, below the 95% gate.
- Candidate chunk rejections: 2,565.
- Native capacity rejections: 612.
- Resident capacity rejections: 2,361.
- Native-packed requests: 2,632; native packed bytes: 3,813,043,456.
- Production GDScript-packed requests and bytes: zero.
- Production material parity: absent.
- Frame p95 is 11.48% above CPU, narrowly outside the 10% gate.

The shared arena and native packing are retained improvements. They remove the
measured 17.16-second GDScript packing cost and collapse the prior candidate's
389 ms frame p95 to 29.40 ms. They do not qualify production because the route
still records GPU inputs during authoritative CPU meshing and floods bounded
resident admission with duplicated work.

## Decision

Keep the shared arena, native v2 input contract, exact lifecycle, and CPU
recovery boundary. Do not promote this candidate or increase capacities. The
next architecture must generate bounded GPU-first field/Transvoxel work and
achieve sustained coverage without duplicate CPU cell capture. D3D12
large-world measurement remains deferred because Vulkan does not pass.

Machine-readable evidence: [qualification.json](qualification.json).
