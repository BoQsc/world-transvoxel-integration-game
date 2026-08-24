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
`ArrayMesh`. GPU-resident terrain rendering, zero-readback production drawing,
measured performance benefit, device recovery, and release promotion remain
TQP-64 work.
