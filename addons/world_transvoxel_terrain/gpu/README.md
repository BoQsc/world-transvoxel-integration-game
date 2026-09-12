# GPU Terrain Candidate

This directory owns the opt-in TQP-64 production-integration candidate. It is
not the default terrain backend and it does not change CPU world authority,
storage, edits, scheduling, publication, or collision ownership.

`WtTerrainGpuMeshingService` runs the qualified TQP-60 compute mesher on one
dedicated worker with a bounded request and completion queue. Compute
synchronization, readback, and exact CPU/GPU differential comparison remain off
the Godot frame thread. The service owns a persistent 20-buffer uniform set,
updates request inputs in place, and grows storage geometrically only when a
larger accepted batch requires it. Requests use tables exported by the pinned
native `world-transvoxel` backend; copied or fallback lookup tables are
forbidden.

`WtTerrainGpuMeshingShadowController` adds an opt-in live validation lane. The
native runtime captures exact accepted terrain and static-water cell inputs,
the service meshes and compares them against CPU authority on its worker, and
the controller returns the compact verdict with the unchanged native identity.
Queue capacity is three. One slot is reserved for fresher native work, and an
older queued capture can be superseded without revoking in-flight work.

The separate default-off matched-publication mode retains the exact native
source pages and CPU mesh authority. A worker match is parsed and finalized by
the native backend, compared exactly with the CPU render payload, and may then
replace the already-ready visual at the same generation. Stale pre-visual
candidates are skipped. Collision publication is never part of this route.

Persistent shadow resources and bounded matched-cell visual publication are
qualified on the retained large-world Vulkan and D3D12 routes. The publication
stage still reads cells back, reruns native finalization, and uploads a CPU
`ArrayMesh`.

The next default-off proof owns equivalent compute and raster resources on
Godot's global RenderingDevice from a pre-transparent render-thread callback.
It performs exact sequence rejection before allocation and before visibility,
supersedes one resident entry, and draws directly into a live viewport with no
geometry readback, CPU finalization, or ArrayMesh upload. Vulkan and D3D12
produce the same retained image signature. It is not connected to production
chunk replacement and uses a diagnostic material.

The production lifecycle now uses the same global device through a bounded
shared arena with four reusable surface slots per page. Native v4 resident
requests provide 13 prepacked buffers and never export the diagnostic
`cell_batch`; production GDScript packing must remain zero. Bounded Vulkan tests
qualify exact activation, retirement, relocation reuse, CPU visual recovery,
and unchanged CPU collision authority.

Published LOD1+ meshlets are compacted only after 120 render callbacks with no
queued or in-flight terrain dispatch. A 256-lane compute pass packs live
positions, normals, material metadata, and indices into exact resident buffers,
rewrites the 32 indirect commands, and copies validated meshlet status to a
stable visibility slot. The following cohort commit activates the exact buffers
and retires the extraction slot atomically. LOD0 remains in its page-backed
working set for incremental edits. Compaction never performs geometry readback
and yields whenever interactive or streaming work exists.

Once native code commits an activation cohort, each exact key, sequence, and
identity token is protected until the render callback activates or rejects the
whole cohort. A newer request may advance the key while that callback is
pending, but it cannot invalidate or reclaim the committed candidate. The
protection is bounded by resident capacity and is released on every activation,
rejection, retirement, free, and shutdown path.

The v4 request is captured from immutable page-backed field inputs before CPU
Transvoxel topology. It has no CPU-topology input dependency, but the current
candidate still performs CPU field sampling and the unchanged CPU reference
mesh. This is a qualified ownership boundary, not a performance promotion.

The large-world Vulkan candidate is still rejected. Native packing removes the
previous frame-time bottleneck, but CPU meshing still records every candidate
cell and floods a bounded resident route that reaches only 15.55% maximum GPU
chunk coverage. Production material parity and a demonstrated frame-pacing
benefit also remain open. The default CPU terrain stays authoritative.
