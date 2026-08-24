# GPU Terrain Candidate

This directory owns the opt-in TQP-64 production-integration candidate. It is
not the default terrain backend and it does not change CPU world authority,
storage, edits, scheduling, publication, or collision ownership.

`WtTerrainGpuMeshingService` runs the qualified TQP-60 compute mesher on one
dedicated worker with a bounded request and completion queue. Compute
synchronization and readback remain off the Godot frame thread. Requests use
tables exported by the pinned native `world-transvoxel` backend; copied or
fallback lookup tables are forbidden.

This first slice qualifies production-addon ownership and native-finalizer
differential replay only. Live runtime admission, persistent shared buffers,
GPU-resident terrain rendering, versioned publication, targeted collision,
performance benefit, and release promotion remain TQP-64 work.
