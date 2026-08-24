# GPU Terrain Candidate

This directory owns the opt-in TQP-64 production-integration candidate. It is
not the default terrain backend and it does not change CPU world authority,
storage, edits, scheduling, publication, or collision ownership.

`WtTerrainGpuMeshingService` runs the qualified TQP-60 compute mesher on one
dedicated worker with a bounded request and completion queue. Compute
synchronization and readback remain off the Godot frame thread. Requests use
tables exported by the pinned native `world-transvoxel` backend; copied or
fallback lookup tables are forbidden.

`WtTerrainGpuMeshingShadowController` adds an opt-in live validation lane. The
native runtime captures exact accepted terrain and static-water cell inputs,
the service meshes them on the GPU, and the controller compares every result
against CPU authority before returning the unchanged native identity. Queue
capacity is three; superseded results are rejected as stale. CPU render and
collision publication remain unchanged and the GPU has no publication route.

Persistent shared buffers, GPU-resident terrain rendering, versioned GPU
publication, targeted collision coordination, measured performance benefit,
device recovery, large-world qualification, and release promotion remain
TQP-64 work.
