# CPU-B3N Transition and Allocation Baseline

CPU-B3N closes two authority defects without selecting GPU execution.

## Accepted authority changes

Authority commit `b57aba9b0ebf76da420391d8eacc1e1f6585c530`:

- restores every fine transition boundary segment while retaining the original
  deterministic M2 and M5 topology hashes;
- limits recursive constraint splitting to each original source-triangle
  boundary, so internal diagonals cannot cause unbounded resplitting;
- retains the documented mesh hard limits but reserves bounded initial
  capacities and allocates transition-face storage only for active faces;
- proves output geometry is independent of prior buffer capacity.

Debug and release reproduce M2 hash `f3ebfec883e2de19` and M5 transition hash
`1761e09383752d56`. The exhaustive LOD2 transition sweep passes all 729 mask
pairs with at most 153 transition indices. Resource cache, edit replacement,
production streaming, LOD streaming, and lifecycle gates retain their locked
hashes in both configurations.

## Focused CPU result

The release page-meshing fixture ran with process affinity `[0, 1, 2]`.

| Measurement | Frozen serial baseline | CPU-B3N |
| --- | ---: | ---: |
| Runs | 10 | 5 |
| Median | 24,143.571 ms | 18,186.360 ms |
| Minimum | 20,234.899 ms | 17,255.498 ms |
| Median change | - | -24.7% |

All five candidate runs passed the full page-meshing runtime contract. This is
a real conventional CPU improvement, but the fixture process RSS sample is too
small and coarse to support a production-memory claim.

## Downstream qualification

Integration commit `9ec3b42` consumes only the binary artifact from `b57aba9`.
The binary-only artifact validator, dependency boundary, Godot 4.7.2 import,
render/collision/edit/journal migration smoke, and protected bottom-boundary
edit smoke pass.

The autonomous three-CPU terrain-waterfall route covered 536.806 metres with
no blocked flight frames, then completed relocated carve and construction.
Trace integrity and publication ownership were exact. The run still found:

| Metric | Carve | Construct |
| --- | ---: | ---: |
| Relocated edit pipeline | 4,623.891 ms | 5,126.062 ms |
| Atomic publication | 428 replace / 125 retire | 462 replace / 185 retire |
| Terminal mesh scheduler wait | 3,273.904 ms | 3,477.649 ms |
| Edit-window average cores | 1.446 | 1.546 |

The destination chunk was fully render- and collision-ready before each edit.
Every retained publication member was still desired and fully ready at the
latest drained viewer plan. CPU-B3I/J already established that same-priority
jobs ahead belonged to the same publication region. CPU-B3N therefore does not
classify this as stale work, a failed priority update, or an allocation defect.

## Decision

CPU implementation is not complete and GPU architecture remains blocked. The
next gate must reconstruct the seam-connected publication graph and prove
whether the 428/462-member atomic cohorts are minimal for crack-free
publication or are over-grouped. Only after that proof may we either:

1. reduce the cohort using a correctness-preserving minimal component; or
2. retain it and test a bounded unified work-conserving CPU executor, not
   another mesh-only secondary queue.

If neither standard CPU architecture improves relocated edit latency and frame
pacing under the three-logical-CPU limit, the CPU implementation can be frozen
and the GPU architecture decision can begin.

Raw trace, report, and usage captures were intentionally not committed. Their
hashes and decisive values are retained in `qualification.json`.
