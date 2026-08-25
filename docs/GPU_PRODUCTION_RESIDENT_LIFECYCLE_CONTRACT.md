# GPU Production Resident Lifecycle Contract

Status: `BOUNDED_LIFECYCLE_PRE_MESH_FIELD_HANDOFF_QUALIFIED_BACKEND_BLOCKED`

Schema: `world_transvoxel.terrain.gpu_production_resident_lifecycle.v1`

This contract records the default-off TQP-64 candidate that connects GPU
resident render resources to accepted production terrain identities. It
qualifies the ownership and recovery lifecycle in bounded tests. The retained
shared-arena and native-packing follow-up removes the rejected per-chunk
resource model, but it does not qualify a production GPU terrain backend.

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

These results qualify the lifecycle state machine and fail-closed behavior.
The later material fixtures separately qualify terrain albedo and roughness
mapping, accepted geometric-normal behavior, bounded Burley response, water
Fresnel tint, camera, and bounded LOD mapping. Full Forward+ lighting/shadows,
water refraction, large-world coverage, responsiveness, memory efficiency,
frame pacing, and power benefit remain open.

## Historical Per-Chunk Rejection

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

## Shared-Arena And Native-Packing Follow-Up

The retained Vulkan candidate replaces per-surface buffer inventories with a
bounded shared arena containing four reusable surface slots per page. Compute
dispatch uses explicit per-slot offsets; vertices and GPU-written indexed
indirect commands keep local draw coordinates. Outward-and-return relocation
passes with five slot reuses across two pages, while the exact retained global
and resident viewport hashes remain unchanged.

The native v2 resident request packs all 13 shader input buffers in C++ and no
longer exports the diagnostic `cell_batch`. The production effect reports 2,632
native-packed requests and zero GDScript-packed requests on the retained route.
Frame p95 falls to 29.40 ms, wall time to 58.04 seconds, and maximum RSS to
1.71 GB. Against the paired CPU run this is +11.48% p95, -13.80% wall time, and
+0.55% RSS.

The candidate remains blocked. Maximum GPU chunk coverage is 15.55%, candidate
rejections are 2,565, native capacity rejections are 612, and production
material parity is absent. Faster native handoff exposes the deeper duplicate
CPU-meshing and admission problem; it does not solve it.

## Bounded Admission And Coalescing Follow-Up

The retained native path now reserves capture capacity before CPU meshing can
record a GPU candidate. Reservations include exact chunk, LOD, generation,
source/world revision, transition mask, scheduler priority, and scheduler
sequence. Higher-authority or higher-priority work can evict only complete
queued work; in-flight work remains immutable. Dequeue applies the same order
and removes obsolete queued revisions and older same-chunk generations.

Focused Vulkan lifecycle and relocation tests pass with zero leaked
reservations and zero late native-capacity rejection. The latest large-world
route records 3,036 reservation attempts, 2,520 captures, 60 dequeue-time
supersessions, 278 native-packed/prepared requests, 214 arena slot reuses, and
17.16% maximum GPU coverage. Candidate rejections fall to 214, but frame p95
is 62.81 ms versus 23.69 ms CPU. This qualifies bounded request admission and
queue coalescing only; it does not qualify production performance.

## Required Replacement Architecture

Do not increase capacities to promote this implementation. Queue coalescing is
a retained correctness and bounded-work mechanism, not a promotion result. The
renderer now compacts emitted indices into one indirect command per surface,
uses authoritative world-space v3 requests, and conservatively culls non-visible
surface bounds. The fresh large-world route avoids 409,393,450 source-cell
records and has zero late resident-capacity rejection, but still misses the
p95, coverage, rejection, and production-material gates. The retained response
slice establishes production albedo/roughness mapping, accepted
geometric-normal behavior, bounded Burley response, and water Fresnel tint.
Full Forward+ scene response and water refraction remain open. CPU-mesh capture
must now be replaced with GPU-first field evaluation and Transvoxel extraction. It
must preserve the shared arena, exact lifecycle, admission rules, compact
rendering, and CPU recovery contract, then pass Vulkan before a second
large-world backend is measured.

## Pre-Mesh Field Handoff

Native resident request v4 is now produced before CPU Transvoxel topology. It
contains complete regular and transition field inputs and identifies its stage
as `pre_mesh_field`; request and metrics contracts also report
`cpu_topology_input_dependency=false`, `cpu_field_sampling=true`,
`gpu_density_field_generation=false`, and `gpu_transvoxel_extraction=true`.
The lifecycle still waits for the unchanged CPU reference publication before
atomic replacement, and CPU collision authority remains unchanged.

This qualifies request ordering and removes post-mesh CPU geometry from the GPU
input boundary. It does not qualify a production-performance backend because
field sampling and the CPU reference mesh are still duplicated. The next
replacement slice must generate the authoritative density/material field on
the GPU and skip CPU visual meshing where targeted collision is not required.

Evidence:

- [TQP-64 shared-arena and native-packing candidate](evidence/tqp64_large_world_gpu_resident_arena_candidate_20260825/RESULT.md)
- [TQP-64 bounded admission and queue-coalescing candidate](evidence/tqp64_large_world_gpu_coalesced_admission_candidate_20260825/RESULT.md)
- [TQP-64 compact world-space resident candidate](evidence/tqp64_large_world_gpu_resident_candidate_20260825/RESULT.md)
- [TQP-64 production albedo, camera, and LOD candidate](evidence/tqp64_large_world_gpu_production_visual_candidate_20260825/RESULT.md)
- [TQP-64 bounded material response candidate](evidence/tqp64_large_world_gpu_material_response_candidate_20260825/RESULT.md)
- [TQP-64 pre-mesh field handoff](evidence/tqp64_pre_mesh_field_handoff_20260825/RESULT.md)
