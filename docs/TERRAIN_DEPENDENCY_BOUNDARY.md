# Terrain Dependency Boundary

## Current Accepted Runtime

The production integration game currently uses this dependency chain:

```text
world-transvoxel-integration-game
  -> world_transvoxel_gameworld
  -> integration-owned world_transvoxel_terrain compatibility snapshot
  -> pinned binary world_transvoxel runtime at 8acd7ca3d0ac794809abb113a2c88f7d22344f09
```

`world-transvoxel` remains the sole native density, material, meshing,
publication, storage, and collision authority. This repository carries its
pinned runtime binary and public metadata, but no native C++ implementation and
no fallback terrain implementation.

The production `WtGameWorld` path instantiates
`runtime/wt_terrain_runtime_scene.tscn`. Terrain debug/reference scenes remain
available for diagnostics, but are not production dependencies.

## Why The Terrain Package Is A Compatibility Snapshot

The terrain package first integrated here requires authority revision
`4f1fdb59e3c6200c8f823b99027b2d3f15563858`. The accepted native runtime at
`8acd7ca3d0ac794809abb113a2c88f7d22344f09` descends from that revision.

The current standalone `world-transvoxel-terrain` release-candidate line pins
authority revision `269871299974c250379028d88b9a9c3086507f52`. That authority
line and the accepted `8acd7ca` line diverge after `4f1fdb5`; neither candidate
package can therefore be treated as a drop-in replacement for the other.

Consequently, the directory `addons/world_transvoxel_terrain` in this game is
an integration-owned compatibility snapshot. Its presence does not mean that
the latest standalone terrain repository is consumed here. This is temporary
and explicit technical debt, not duplicated native terrain authority.

## Allowed Changes

- Native terrain behavior is changed in `world-transvoxel`, built there, and
  brought here as an exact pinned binary runtime artifact.
- Integration-specific orchestration and presentation belong in
  `world_transvoxel_gameworld` or game scripts.
- Changes to the compatibility terrain snapshot must remain API adapters or
  runtime orchestration needed by the accepted native line.
- Diagnostic code may observe the backend, but it must not own native terrain
  lifecycle, edits, geometry, or storage.

Production exceptions that currently read the backend directly are limited to
bounded budget/configuration adapters, material override installation, player
mesh-ray presentation fallback, and explicitly named diagnostic capture code.
They do not replace terrain authority.

## Forbidden Changes

- Do not copy native C++ source into this repository.
- Do not add a fallback mesher, density authority, collision terrain, or hidden
  duplicate terrain surface.
- Do not instantiate a terrain `debug/` or reference scene from the production
  `WtGameWorld` path.
- Do not run an applying standalone-candidate package sync as routine upkeep.
- Do not claim that standalone terrain changes are active here merely because
  similarly named files exist in both repositories.

`tools/sync_tqp54_candidate.py` permits candidate comparison in dry-run mode,
but blocks applying a candidate refresh unless the exceptional
`--allow-candidate-refresh` flag is supplied.

## Reconciliation Procedure

Replacing this compatibility snapshot with the standalone terrain package is a
future migration, not a file synchronization task. It requires all of the
following:

1. Reconcile the divergent `world-transvoxel` authority lines and choose one
   promoted authority revision.
2. Build and pin exact debug/release native runtime artifacts from that
   revision.
3. Update the standalone terrain package to the same authority API and
   revision.
4. Perform an intentional candidate refresh and review every changed, added,
   and removed file.
5. Re-run package, import, migration, topology, LOD, edit, collision,
   performance, and human playtest qualification before changing the accepted
   baseline.

Until that sequence passes, this repository continues from its accepted
`8acd7ca` compatibility line.
