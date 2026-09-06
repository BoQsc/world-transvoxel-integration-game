# GPU-resident dirty-meshlet publication checkpoint

Authority: `world-transvoxel` commit
`a83bd57e9e43a09ded26fc416b343ebfd4f3271b`.

Runtime artifact digest:
`14267d6a137e4bba372524c758bbb95d4f1f782ec7b26037bafa5d120d02c860`.

## Result

Checkpoint 2 is complete. Loaded edited page fields remain GPU resident, LOD0
regular cells are split into eight 8-cubed bricks, and an edit regenerates only
the intersecting brick set plus the required sample halo. Candidate geometry is
written into distinct bounded arena slots. One GPU workgroup validates and
switches the complete activation/retirement cohort. The prior generation stays
submitted until the asynchronous 20-byte candidate summary permits cleanup.

The ordinary immediate-activation path and retirement-only cohorts use the same
GPU activation state. Stale summaries account for transferred bytes and cannot
publish or retain orphan resources. Geometry and index data are never read back.

## Verification

- Native debug and release: seven established regression executables passed in
  each configuration (`production_streaming`, `production_lod_streaming`,
  `production_lifecycle`, `m5_edit_replacement`, `m3_application`,
  `publication_policy`, and `gpu_meshing_shadow`).
- Vulkan rapid edit: 12 edits, 61 checked frames, zero mixed revisions, 24
  incremental dispatches, 73,728 regenerated cells, final partial upload 7,840
  bytes.
- D3D12 rapid edit: the same edit, frame, revision, dispatch, regenerated-cell,
  and partial-upload results.
- Vulkan global publication: visible proof passed with 27,312 foreground pixels,
  stale generation rejection, supersession, culling, and atomic replacement.
- Vulkan production lifecycle: terrain and water publication, restoration,
  material parity, CPU collision authority, pre-mesh GPU fields, and zero
  geometry readback passed.
- Vulkan critical path: edit submission maximum 454 microseconds; traced hot
  combined readiness maximum 72,161 microseconds; cold readiness 167,502
  microseconds. `SURFACE_PREPARED` contains no synchronous GPU readback.
- Full-quality edit on Vulkan and D3D12: extraction-to-visibility is two render
  callbacks. Journal commit-to-visibility is four displayed frames because the
  native job reaches extraction at frame 2.

The retained trace is `vulkan_critical_path_trace.json` in this directory.

## Remaining measured blockers

Combined hot readiness is collision-bound; incremental authoritative collision
is checkpoint 3. Journal-to-dispatch scheduling consumes the first two displayed
frames; dedicated interaction lanes are checkpoint 4.

The pre-existing production visual-parity route still leaves its second viewer
plan pending with two unresolved hierarchy dependencies while storage, sampling,
meshing, and GPU queues are empty. Only two valid LOD3 chunks remain active. This
is a native interaction-streaming planner defect for checkpoint 4; it is
independent of checkpoint-2 extraction and publication, which are idle and
drained at the failure.
