# GPU Architecture Decision

Status: `SELECTED_CANDIDATE_ARCHITECTURE_NOT_IMPLEMENTED`

TQP-58 selects a bounded GPU candidate for field evaluation and Transvoxel
mesh extraction. It does not replace the authoritative CPU implementation and
does not qualify a production GPU backend.

## Decision

Keep CPU ownership of world state, storage, edit transactions, revisions,
desired-set planning, immutable transition masks, stale-result rejection,
atomic publication, persistence, and targeted collision policy. Move only the
following measured work into the first GPU candidate:

1. density, gradient, and material field evaluation for requested pages;
2. regular-cell and transition-cell mesh extraction;
3. GPU-resident candidate mesh buffers and render consumption.

Every GPU result must carry exact page key, LOD, generation, source revision,
world revision, and transition mask. The CPU validates that identity before
atomic publication. There is no silent fallback: CPU reference mode remains an
explicit selectable backend, and GPU failure must be reported.

Collision stays CPU-generated and viewer-targeted for the first candidate.
GPU collision readback is deferred until versioned readback can beat the CPU
path without delaying publication or weakening collision correctness.

## Alternatives

- **Continue changing CPU scheduling:** rejected as the next phase. Focused
  cache, storage, collision, queue, priority, admission, worker, and shared-work
  candidates are either accepted as bounded or measured and rejected. The
  remaining material cost is serial mesh/visibility backlog.
- **GPU field and meshing candidate with CPU control:** selected. It targets the
  measured work while preserving the qualified authority boundary.
- **Full GPU terrain authority:** rejected for this phase. Moving edits,
  persistence, publication ownership, or collision authority would multiply
  determinism, synchronization, readback, server, and recovery risks before the
  narrow candidate is proven.

## Required Qualification

The candidate may advance only through the existing ordered milestones:

1. TQP-59: analytical and CPU-differential field evaluation;
2. TQP-60: regular and transition GPU meshing candidate;
3. TQP-61: shared CPU/GPU differential corpus;
4. TQP-62: residency, synchronization, stale rejection, publication, and
   targeted collision-readback decision;
5. TQP-63: cross-hardware, driver, API, memory, thermal, and power matrix;
6. TQP-64: separately reviewed production backend release.

The differential corpus must cover all regular cases, transition orientations
and masks, materials including water, edits, bounds, seams, negative controls,
and deterministic or explicitly tolerance-bounded output. Promotion also
requires a material frame-pacing, relocation-readiness, throughput, or energy
benefit against the frozen CPU baseline with zero stale publication and zero
render/collision ownership divergence.

GPU-board watts, CPU-package watts, and whole-system watts remain separate
measurements. The initial efficiency comparison must record GPU board power and
work per frame where available; it must not infer CPU or whole-system power.
