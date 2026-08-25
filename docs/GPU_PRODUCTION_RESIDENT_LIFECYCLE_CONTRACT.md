# GPU Production Resident Lifecycle Contract

Status: `BOUNDED_LIFECYCLE_QUALIFIED_LARGE_WORLD_ARCHITECTURE_REJECTED`

Schema: `world_transvoxel.terrain.gpu_production_resident_lifecycle.v1`

This contract records the default-off TQP-64 candidate that connects GPU
resident render resources to accepted production terrain identities. It
qualifies the ownership and recovery lifecycle in bounded tests. It does not
qualify the current per-chunk allocation architecture for a large world.

## Authority Boundary

- CPU world state, edits, desired-set planning, revisions, transition masks,
  persistence, and collision remain authoritative.
- The native backend captures a request only after accepting its exact surface,
  page, LOD, generation, source revision, world revision, and transition mask.
- Native request validation consumes that immutable handoff. A separate,
  repeatable readiness query waits for the matching CPU visual generation and
  transition-mask state without occupying the bounded request queue.
- GPU publication cannot silently invoke CPU meshing, CPU chunk finalization,
  geometry readback, or ArrayMesh upload.
- Terrain and static-water surfaces belonging to one chunk identity activate
  as one complete set. A partial or stale set never replaces valid CPU render.
- CPU collision remains active and versioned independently of GPU visibility.

## Lifecycle Order

1. Native authority admits and captures an exact accepted generation.
2. The controller validates and consumes the immutable request handoff.
3. The global render effect prepares all required surfaces while inactive.
4. The controller polls exact CPU publication readiness with a bounded wait.
5. Only a complete identity and surface set becomes visible atomically; the
   matching CPU visual is hidden while collision remains available.
6. Superseded, undesired, stale, or failed entries retire on the render thread.
7. Retirement, shutdown, or explicit recovery restores the CPU visual for the
   exact generation before GPU ownership is released.

Readiness polling is bounded to 180 frames and retried every three frames. An
expiry rejects only that GPU candidate. It does not alter CPU authority.

## Qualified Bounded Evidence

The one-chunk lifecycle test covers initial terrain publication, a construction
replacement, a two-surface terrain/static-water replacement, collision
retention, and shutdown recovery. The four-by-four relocation test covers
multi-chunk activation, desired-set movement, retirement, replacement, and CPU
restore. Vulkan and D3D12 pass both tests serially with zero geometry readback,
CPU finalization, or ArrayMesh upload.

These results qualify the lifecycle state machine and fail-closed behavior only.
They do not establish production material parity, large-world coverage,
responsiveness, memory efficiency, frame pacing, or power benefit.

## Large-World Rejection

The accepted G23 2,048 x 256 x 2,048 route completed with an intact trace and
the three-logical-CPU limit, but the current implementation reached only 5.90%
maximum GPU chunk coverage. It allocated and dispatched a separate 21-buffer
inventory for each prepared surface while the CPU still performed authoritative
meshing. Native capacity rejected 3,147 captures and the candidate rejected 462
chunk groups as they became stale.

Compared with the paired CPU run, frame p95 increased from 21.88 ms to 453.60
ms, maximum RSS increased from 1.55 GB to 2.96 GB, and route time increased
from 56.55 seconds to 101.06 seconds. Production material parity was also not
implemented. The architecture therefore fails every production-promotion gate.

## Required Replacement Architecture

Do not increase capacities or tune queue order to promote this implementation.
The next candidate must amortize rendering resources through a bounded pooled or
batched GPU arena, eliminate per-surface render-thread allocation, and perform
field evaluation and Transvoxel extraction on the GPU instead of duplicating
the authoritative CPU meshing cost. It must preserve this exact lifecycle and
CPU recovery contract, then rerun Vulkan before spending time on a second
large-world backend.

Evidence: [TQP-64 large-world GPU resident candidate](evidence/tqp64_large_world_gpu_resident_candidate_20260825/RESULT.md).
