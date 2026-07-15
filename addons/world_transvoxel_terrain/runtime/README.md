# Runtime Ownership

Terrain root, profile binding, viewer binding, lifecycle, and high-level state
coordination belong here.

Runtime code may coordinate subsystem calls. It must not become a monolithic
chunk manager.

A2 adds `WtTerrainWorld` as a placeholder scene entry point with dependency
status reporting only.

A3 adds `WtWorldTransvoxelBridge`, a narrow `ClassDB` adapter that can read
official `world-transvoxel` identity/config status without starting terrain.

A4 phase 2 adds `WtTerrainEditBridge`, which maps terrain edit batches into
official `WorldTransvoxelEditTransaction` backend calls. Public
`WtTerrainWorld` lifecycle ownership remains the next A4 phase.

A4 phase 3 makes `WtTerrainWorld` own backend terrain/config instantiation,
start/stop, and edit-batch submission through the existing bridge classes.

A4 phase 4 adds public viewer update/removal, chunk query, runtime metrics, and
cold-idle summaries through `WtTerrainWorld`. `WtTerrainRuntimeAudit` owns the
focused cold-idle metric interpretation so the terrain-world node does not
become a monolithic runtime manager.

The downstream G46 terrain-addon API contract adds stable public aliases and
introspection on `WtTerrainWorld`: `start_world`, `stop_world`,
`is_world_running`, `get_world_state_name`, `get_world_revision`,
`get_world_source_revision`, `get_world_page_count`, profile summaries,
authoritative sample request methods/signals, storage snapshot request wrappers,
runtime telemetry, debug snapshot capture, `get_hot_path_boundary_summary`, and
`get_terrain_api_contract_summary`.

G48 uses `get_hot_path_boundary_summary` to lock the native hot-path boundary.
Generation, meshing, streaming, edit application, and storage stay in the
`world-transvoxel` native backend. Runtime GDScript may own bounded
lifecycle/profile/request wrappers, but it must not implement density volume
loops, mesh construction loops, page generation loops, source-file streaming
loops, or image/pixel terrain loops.

## Interactive edit responsiveness

Human/gameplay edits are foreground operations. Runtime code must not depend on
collision-only targeting because collision can be temporarily behind visible
terrain after fast viewer movement. The accepted standard path is:

1. try physics collision for the exact interactive target;
2. if collision misses, use a bounded visible-terrain target fallback or report a
   concrete reason;
3. submit the authoritative edit through the normal edit batch/journal path;
4. give accepted edits immediate apply-budget priority;
5. expose accepted/rejected/queued/applied state in summaries.

This fallback target may inspect rendered mesh only to choose the player's
intended point. It does not make rendered triangles authoritative. The committed
edit remains defined by the voxel/SDF edit transaction and backend journal.
