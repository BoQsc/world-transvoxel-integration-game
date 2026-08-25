# GPU Architecture Decision

Status: `TQP64_PRODUCTION_ALBEDO_CAMERA_LOD_SLICE_QUALIFIED_BACKEND_BLOCKED`

TQP-58 selected a bounded GPU candidate for field evaluation and Transvoxel
mesh extraction. TQP-59 through TQP-63 subsequently qualified the bounded
field, cell meshing, shared differential, residency/publication, and retained
Windows NVIDIA Vulkan/D3D12 profiles in the Terrain Lab. Those results do not
replace the authoritative CPU implementation or qualify a production GPU
backend. TQP-64 is now active.

## TQP-64 Integration Status

The production terrain addon now owns an opt-in
`WtTerrainGpuMeshingService`. It runs the qualified compute mesher on one
dedicated worker, admits at most three outstanding requests, consumes lookup
tables exported by the pinned native backend, reports unsupported or saturated
states explicitly, and never falls back to CPU meshing. Compute submission,
synchronization, and readback do not execute on the Godot frame thread.

The service now retains one 21-buffer uniform-set inventory across requests,
grows those buffers geometrically only when required, and updates request
inputs in place. Exact differential comparison also runs on the dedicated
worker and returns a compact verdict instead of copying full GPU cell results
back to the frame thread. Topology, indices, materials, reuse metadata, and
identity remain exact. Vertex comparison uses a bounded float32 scale-aware
tolerance; normals retain the absolute `1e-5` bound. This validation service
does not publish GPU render resources.

The retained integration smoke captures one real native LOD1 chunk containing
4,352 cells (4,096 regular and 256 transition), meshes every captured cell on
the GPU, compares geometry and metadata against CPU authority, and sends the
GPU cell payload through the unchanged native chunk finalizer. Vulkan and
D3D12 both pass on the retained GTX 1060 Max-Q profile with zero cell mismatch
and exact finalized chunk geometry. Bounded saturation and deterministic
repeat controls also pass.

The second slice connects the candidate to accepted live terrain work as an
opt-in shadow validator. The native authority captures immutable regular and
transition inputs only after its existing generation/revision acceptance,
including terrain and static-water surfaces. The addon meshes those captures
on its dedicated GPU worker, compares all geometry and metadata against CPU
authority, and returns the exact identity for native stale validation. A live
construct remesh, volumetric static water, and a deliberately superseded result
pass on both Vulkan and D3D12.

The retained large-world qualification runs the accepted G23 2,048 x 256 x
2,048 profile through the same deterministic two-leg relocation route in
CPU-only and shadow modes. Vulkan and D3D12 both complete long flight, LOD
transition work, relocated carve, and relocated construction with complete
traces. Vulkan records 74 matched terrain results including 3 transition
results; D3D12 records 102 including 3 transitions. Both drivers record
positive terrain matches in each relocated edit window and zero geometry,
unknown-request, or identity mismatch. The native bounded queue supersedes 11
older Vulkan captures and 19 older D3D12 captures so fresh relocated work is
validated without increasing capacity or revoking in-flight work.

Persistent resources materially reduce the intrusive shadow cost measured by
the earlier diagnostic. Vulkan trace-on frame p95 is 31.80 ms versus 26.82 ms
for its paired CPU run; D3D12 is 34.60 ms versus 29.14 ms. The old per-request
allocation and frame-thread comparison run measured 307-318 ms p95. However,
shadow p99 remains 150-157 ms and route wall time remains 28-41% higher because
all candidate geometry is still read back for validation. This rejects
performance promotion while qualifying the persistent validation architecture.
Board-global telemetry is not process-attributed, and trace-on timing is not a
release performance baseline.

A bounded slice qualifies a versioned
[GPU resident render-resource contract](GPU_RESIDENT_RENDER_RESOURCE_CONTRACT.md).
One exact 4,352-cell LOD1 fixture is compute-meshed and rasterized on the same
local RenderingDevice with GPU-written indexed indirect commands, zero geometry
readback, no CPU chunk finalization, and no ArrayMesh upload. Vulkan and D3D12
produce the identical retained raster signature. Godot 4.7 requires one
device-local storage-to-index-buffer copy because index-buffer RIDs are not
accepted as compute storage uniforms; vertices and indirect commands remain
directly consumed.

The following bounded
[global render publication contract](GPU_GLOBAL_RENDER_PUBLICATION_CONTRACT.md)
now proves the next ownership boundary. A pre-transparent `CompositorEffect`
allocates and consumes the 21-buffer mesh inventory on Godot's global
RenderingDevice, performs exact sequence checks before allocation and again
before visibility, retires a superseded resident entry, and draws into a live
viewport. No geometry readback, CPU finalization, or ArrayMesh upload occurs.
Vulkan and D3D12 produce the identical retained image signature.

The default-off production
[resident lifecycle](GPU_PRODUCTION_RESIDENT_LIFECYCLE_CONTRACT.md) now connects
that mechanism to exact accepted chunk identities. Bounded Vulkan and D3D12
tests qualify atomic terrain/static-water activation, replacement, retirement,
CPU collision retention, and CPU visual recovery. Native request handoff is
consumed separately from repeatable exact-generation readiness polling, so
waiting for CPU publication does not occupy the bounded capture queue.

The first large-world use of that lifecycle is rejected. Its per-surface
21-buffer allocation and dispatch occur on the render thread while CPU meshing
still runs. On the accepted G23 route it reached only 5.90% maximum GPU chunk
coverage, recorded 3,147 native capacity rejections and 462 candidate chunk
rejections, raised frame p95 from 21.88 ms to 453.60 ms, and raised maximum RSS
from 1.55 GB to 2.96 GB. It has no production material parity. The measurement
is valid, but every production-promotion gate fails.

The retained replacement slice removes that per-surface resource model. A
bounded global arena owns 21 shared buffers per four-slot page, dispatches with
per-slot offsets, and reuses retired slots. Bounded Vulkan tests retain the
exact global and resident raster hashes, prove outward-and-return relocation,
and record five slot reuses across two pages. The production native request is
also versioned to v2 and returns 13 prepacked input buffers instead of thousands
of per-cell Godot Dictionaries. Production GDScript packing is asserted to stay
at zero.

On the retained large-world Vulkan route, this reduces candidate frame p95 from
the earlier 389 ms arena/GDScript-packing run to 29.40 ms and wall time from
90.23 to 58.04 seconds. Against the paired CPU run, p95 is 11.48% higher, p99
is 2.88% higher, RSS is 0.55% higher, and wall time is 13.80% lower. This is a
material correction, not production qualification: maximum GPU chunk coverage
is 15.55%, the candidate rejects 2,565 chunks, native capture rejects 612
requests, and production material parity is absent. The Vulkan promotion gate
therefore fails and the D3D12 large-world rerun is intentionally deferred.

The default runtime therefore remains CPU-only. TQP-64 stays active and blocked
on bounded draw submission and visibility, production camera/material parity,
and GPU-first field/Transvoxel request generation. It must retain the
now-qualified shared arena, production lifecycle, admission/coalescing rules,
and CPU recovery contract.

### Bounded Admission And Coalescing

The next retained intermediate reserves bounded native capture capacity before
CPU meshing records a candidate. Reservations carry the complete authoritative
job identity. A newer world/source revision, a newer generation of the same
chunk, or higher scheduler priority may replace lower-value queued work before
handoff. Dequeue uses the same ordering and removes queued obsolete global
revisions and same-chunk generations. Unused and cancelled reservations are
released; focused lifecycle and relocation tests finish with zero reservation
leaks and zero late native-capacity rejection.

On the retained 2,048 x 256 x 2,048 Vulkan route, 3,036 reservation attempts
produce 2,520 captures. Native packing and GPU preparation fall to 278 exact
requests, 60 queued obsolete requests are coalesced, and the shared arena
reuses 214 slots. Maximum coverage improves to 17.16%, but 214 candidate
chunks are still rejected. Against the fresh CPU baseline captured immediately
before these candidate-only scheduling changes, frame p95 rises from 23.69 ms
to 62.81 ms (+165.06%), p99 rises 94.85%, wall time rises 9.61%, and maximum
RSS rises 5.87%. The admission mechanism is retained because it prevents
unbounded duplicate handoff; the production backend remains rejected.

Trace correlation isolates the next blocker. Frames without active GPU
resident rendering have a 19.86 ms p95; frames with all 64 resident chunks have
a 63.99 ms p95. The global renderer currently iterates every active entry and
submits one indexed indirect command record per source cell, without visibility
culling or compacted draw counts. At 32,768 cells per common chunk, 64 active
chunks can expose roughly two million command records per frame even when most
cells emit no geometry. This is a downstream render-submission architecture
problem, not evidence against the Transvoxel tables or CPU authority.

### Compact World-Space Follow-Up

The retained renderer now atomically compacts emitted indices into one
GPU-written indirect command per resident surface and conservatively culls
world-space surface bounds before submission. The native v3 request adds the
CPU renderer's chunk-world offset to packed positions and bounds; earlier local
resident placement evidence is invalid. Focused Vulkan publication retains the
exact image signature, and nonzero multi-chunk relocation passes in world
space.

The fresh large-world route tests 99,942 surfaces, culls 36,240, submits 63,702
compact commands, and avoids 409,393,450 source-cell records. Late resident
capacity rejection is zero. This removes the immediate per-cell submission
collapse, but does not promote the backend: p95 is 28.03 ms versus 22.00 ms CPU
(+27.42%), maximum coverage is 12.87%, 2,540 candidate chunks are rejected,
and production material parity is absent.

The next retained slice establishes production camera transforms, terrain
albedo/material mapping, and bounded LOD0/1/2 rendering. Full normal/PBR and
static-water material parity remain open before production promotion.

### Production Albedo, Camera, And LOD Follow-Up

The resident renderer now consumes the accepted game terrain texture arrays,
generated/authored material weights, and world-space biome, depth, ore, and
road parameters through a generated raw-RD shader. The generator pins the CPU
shader source hash. Focused Vulkan and D3D12 fixtures retain live Godot camera
transforms, simultaneous LOD0/1/2 inventory (`16 / 4 / 1`), zero coverage
overlap, exact albedo mapping, and zero geometry readback. The fixture also
corrects raw-RD front-face winding, stale-work classification, and a
chunk-versus-two-surface allocation error.

This is not full production material parity. The compositor does not reproduce
Godot Forward+ normal mapping, roughness/PBR, shadows, or static-water response.
Those gates remain explicitly false.

The matched large-world Vulkan route records stable production albedo mapping,
zero downstream rejection, and 17.16% maximum GPU chunk coverage. Frame p95 is
31.13 ms versus 23.85 ms CPU (+30.51%); wall time is +9.45% and RSS is +1.84%.
The active terrain set contains LOD0 and LOD3 but no LOD1/2. Native bounded
admission rejects 570 reservations and 2,367 captured requests, while 213
normal stale applications are reported separately as supersessions.

The backend remains blocked on full terrain/static-water material response,
large-world LOD and coverage completeness, native admission, frame p95, and
GPU-first field/Transvoxel generation. Raising capacities alone is not an
acceptable resolution.

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

The candidate advances only through the existing ordered milestones:

1. TQP-59: analytical and CPU-differential field evaluation (`qualified`);
2. TQP-60: regular and transition GPU meshing candidate (`qualified`);
3. TQP-61: shared CPU/GPU differential corpus (`qualified`);
4. TQP-62: residency, synchronization, stale rejection, publication, and
   targeted collision-readback decision (`qualified`, bounded candidate);
5. TQP-63: supported driver/API/memory/thermal/power matrix (`qualified` for
   the retained Windows NVIDIA GTX 1060 Max-Q Vulkan and D3D12 scope);
6. TQP-64: separately reviewed production backend release (`active`).

The differential corpus must cover all regular cases, transition orientations
and masks, materials including water, edits, bounds, seams, negative controls,
and deterministic or explicitly tolerance-bounded output. Promotion also
requires a material frame-pacing, relocation-readiness, throughput, or energy
benefit against the frozen CPU baseline with zero stale publication and zero
render/collision ownership divergence.

GPU-board watts, CPU-package watts, and whole-system watts remain separate
measurements. The initial efficiency comparison must record GPU board power and
work per frame where available; it must not infer CPU or whole-system power.
