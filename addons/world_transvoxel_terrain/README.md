# World Transvoxel Terrain Addon

This directory is the installable Godot addon boundary for
`world-transvoxel-terrain`.

Version: `1.0.0`. CPU Terrain Standard 1.0 is qualified through TQP-57 for
Windows x86-64, Godot 4.7, Forward+, and the pinned reference matrix. The addon
has public terrain/profile/runtime/edit/storage
resources, a bridge to the official `world-transvoxel` backend, terrain-world
lifecycle/edit submission, and a bounded reference runtime/cold-idle smoke
through `WtTerrainWorld`. It now also has the debug snapshot data contract for
the local reference scene plus an addon-local reference scene scaffold that can
run against the official backend fixture and render explicit debug overlay
sections. The downstream G46 validation gate locks the minimal public
`WtTerrainWorld` API for lifecycle, profile summaries, viewer streaming,
edit submission, authoritative sample queries, storage snapshot requests,
generation-aware render/collision/edit/query readiness, bounded request and
viewer behavior, telemetry, and debug snapshots. Its editor plugin adds a
Terrain authoring/inspection dock with safe draft undo/redo and repro export.
The A6 decision is
`approve_validation_game_repository`, meaning a
separate validation game repository may be created when the user explicitly asks
for it. The TQP-51 contract pins `world-transvoxel` as terrain authority and
forbids addon-local fallback meshers or synthetic terrain surfaces. Version
1.0.0 is production-scoped only to its declared matrix; GPU terrain,
non-Windows systems, arbitrary hardware, and game systems remain unqualified.

Allowed GDScript here is limited to editor glue, scene scaffolding, input
routing, debug UI, and small smoke-test harnesses. Terrain generation, meshing,
streaming policy, storage, edit recovery, and other hot paths must be native,
low-level addon code, binary tooling, shaders when justified, or Python offline
tooling.

The addon depends on exact `world-transvoxel` revision
`4f1fdb59e3c6200c8f823b99027b2d3f15563858` but does not vendor it or provide a
fallback. Install and enable that addon before this one.

The machine-readable ownership, threading, lifetime, failure, and unsupported
scope contract is `BOUNDARY_CONTRACT.json`.
