# TQP-64 Large-World GPU Resident Candidate

Status: `ARCHITECTURE_REJECTED`

Date: 2026-08-25

## Scope

The default-off production resident candidate was compared with CPU-only on the
same deterministic G23 2,048 x 256 x 2,048 relocation, flight, carve, and
construction route. Both runs used Vulkan, the production texture-array mode,
and a three-logical-CPU process limit. The CPU collision path remained
authoritative.

The measurement is valid: both routes completed, traces are intact, required
human-route coverage is present, and no local or native trace events were
dropped. A valid measurement does not imply promotion.

## Comparison

| Measurement | CPU-only | GPU resident candidate | Change |
| --- | ---: | ---: | ---: |
| Frame p95 | 21.88 ms | 453.60 ms | +1,972.73% |
| Frame p99 | 33.21 ms | 521.52 ms | +1,470.53% |
| Route wall time | 56.55 s | 101.06 s | +78.72% |
| Maximum RSS | 1.55 GB | 2.96 GB | +91.54% |
| Mean process CPU | 153.36% | 156.15% | +1.82% |
| Mean GPU utilization | 22.16% | 3.34% | -84.94% |
| Mean GPU board power | 28.37 W | 22.61 W | -20.32% |

GPU telemetry is board-global and is not process-attributed. The lower GPU
utilization and board power do not represent useful acceleration: the route is
substantially slower and the candidate performs only a small fraction of the
required terrain work.

## Lifecycle Facts

- Maximum active GPU chunks: 22.
- Maximum GPU chunk coverage: 5.90%.
- Activated chunks: 22; retired chunks: 8.
- Prepared surfaces: 494; submitted surfaces: 497; validated surfaces: 424.
- Candidate chunk rejections: 462.
- Native captures: 519; native capacity rejections: 3,147.
- Readiness attempts: 705; waits: 269; ready: 38; stale: 398.
- Geometry readback: zero.
- Fail-closed recovery events: zero.
- Production material parity: absent.

The exact request handoff is successfully decoupled from repeatable CPU visual
readiness, and bounded lifecycle tests separately prove atomic terrain/water
activation, retirement, collision retention, and CPU restore on Vulkan and
D3D12.

## Decision

Reject the current per-chunk resident publication architecture for production.
It fails all promotion gates: material parity, 95% chunk coverage, zero
candidate rejection, zero native capacity rejection, p95 within 10%, RSS within
25%, and route time within 25%.

Do not treat higher queue or resident capacities as a correction. The next
candidate needs pooled or batched GPU storage and true GPU field/mesh generation
while retaining the qualified CPU authority and lifecycle boundaries.

Machine-readable evidence: [qualification.json](qualification.json).
