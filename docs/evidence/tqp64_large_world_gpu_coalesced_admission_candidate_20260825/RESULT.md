# TQP-64 Bounded Admission And Queue-Coalescing Candidate

Status: `ARCHITECTURE_BLOCKED_INTERMEDIATE_QUALIFIED`

Date: 2026-08-25

## Qualified Scope

- Native capture capacity is reserved before CPU meshing records a candidate.
- Reservations preserve complete authoritative job identity and are released
  after rejection, cancellation, handoff, or completion.
- Higher-authority and higher-priority queued work can replace lower-value
  complete work; in-flight work remains immutable.
- Priority dequeue coalesces obsolete global revisions and older generations
  of the selected chunk before native packing.
- Focused Vulkan production-lifecycle and relocation tests pass with zero final
  reservation leakage, zero geometry readback, and CPU collision authority.
- The paged shared arena, native v2 packed-input contract, exact publication,
  CPU visual recovery, and default-off runtime boundary remain unchanged.

## Large-World Comparison

The retained G23 2,048 x 256 x 2,048 route uses Vulkan, production materials,
two procedural workers, and a three-logical-CPU process limit. The CPU baseline
was captured immediately before the candidate-only admission/dequeue changes;
the CPU-disabled route is unchanged by those changes.

| Measurement | CPU-only | GPU resident | Change |
| --- | ---: | ---: | ---: |
| Frame p95 | 23.69 ms | 62.81 ms | +165.06% |
| Frame p99 | 33.23 ms | 64.75 ms | +94.85% |
| Route wall time | 63.53 s | 69.63 s | +9.61% |
| Maximum RSS | 1.683 GB | 1.782 GB | +5.87% |
| Mean process CPU | retained | retained | +2.92% |

Board-global GPU telemetry is retained but is not process-attributed and does
not decide promotion.

## Bounded-Work Evidence

- Reservation attempts: 3,036; admission rejections: 579.
- Captured requests: 2,520; late native-capacity rejections: zero.
- Priority dequeues: 22; dequeue-time supersessions: 60.
- Native-packed and prepared requests: 278; GDScript-packed requests: zero.
- Packed native input: 397,450,688 bytes.
- Shared arena: 16 pages, 64 peak slots, and 214 slot reuses.
- Final queued and in-flight requests: zero; final reserved slots: zero.
- Activated/final active chunks: 64/64; maximum GPU coverage: 17.16%.
- Candidate chunk rejections: 214.

## Blocking Facts

- Frame p95 is 165.06% above CPU, outside the 10% gate.
- Maximum GPU chunk coverage is 17.16%, below the 95% gate.
- Candidate rejection is nonzero and production material parity is absent.
- Candidate inputs still originate from completed CPU meshing.
- The global renderer submits per-cell indirect command records for every
  active resident entry without visibility culling or compacted draw counts.

Trace correlation records a 19.86 ms p95 across frames without active resident
rendering and a 63.99 ms p95 across frames with all 64 resident chunks. A common
chunk exposes 32,768 cell command records, so the current 64-chunk path can
present roughly two million indirect records per frame even when most cells
emit no geometry. This identifies downstream draw submission as the immediate
architecture blocker; it does not invalidate Transvoxel tables or CPU terrain
authority.

## Decision

Retain pre-mesh reservation, priority admission, queue coalescing, the shared
arena, native packing, exact lifecycle, and CPU recovery boundary. Do not
promote the candidate. Next, bound draw work with compact or counted indirect
submission and visibility culling; then establish production camera/material
parity; then replace CPU-mesh capture with GPU-first field and Transvoxel work.
D3D12 large-world measurement remains deferred until Vulkan passes.

Machine-readable evidence: [qualification.json](qualification.json).
