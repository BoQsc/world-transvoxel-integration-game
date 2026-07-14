# World Transvoxel Terrain Addon

This directory is the installable Godot addon boundary for
`world-transvoxel-terrain`.

Current status: A6 complete. The addon has public terrain/profile/edit/storage
resources, a bridge to the official `world-transvoxel` backend, terrain-world
lifecycle/edit submission, and a bounded reference runtime/cold-idle smoke
through `WtTerrainWorld`. It now also has the debug snapshot data contract for
the local reference scene plus an addon-local reference scene scaffold that can
run against the official backend fixture and render explicit debug overlay
sections. The downstream G46 validation gate locks the minimal public
`WtTerrainWorld` API for lifecycle, profile summaries, viewer streaming,
edit submission, authoritative sample queries, storage snapshot requests,
telemetry, and debug snapshots. The A6 decision is
`approve_validation_game_repository`, meaning a
separate validation game repository may be created when the user explicitly asks
for it. It is not yet a production-ready terrain package.

Allowed GDScript here is limited to editor glue, scene scaffolding, input
routing, debug UI, and small smoke-test harnesses. Terrain generation, meshing,
streaming policy, storage, edit recovery, and other hot paths must be native,
low-level addon code, binary tooling, shaders when justified, or Python offline
tooling.

The addon depends on `world-transvoxel` but does not vendor it.

## Critical vertical-volume boundary

Terrain profiles are bounded signed 3D volumes, not heightmaps. Public profile
summaries must report `horizontal_cells`, `vertical_cells`, and
`vertical_origin_cell`. Generation profiles must expose native procedural
vertical coverage through `world_chunk_count_y` and `world_chunk_origin_y`.

The current deeper-underground standard profile proven by this integration game
is `g20_deep_2k_256_on_demand`: `2048 x 2048` horizontal cells, `256` vertical
cells, vertical origin `-128`, and native `128 x 16 x 128` LOD0 procedural
chunks. It is a larger bounded reference volume for underground/tunnel proof,
not a cap, duplicate mesh, or presentation fallback.
