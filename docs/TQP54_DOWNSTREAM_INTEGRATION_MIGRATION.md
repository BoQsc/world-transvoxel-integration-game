# TQP-54 Downstream Integration Migration

Status: qualified on Godot 4.7.

Godot 4.7 is the minimum and sole current qualification target. Older engine
results are historical evidence, not a compatibility requirement.

The integration game consumes exact pinned copies of `world-transvoxel` and
`world-transvoxel-terrain`. Gameplay reaches native authority through
`WtTerrainWorld`; there is no game-owned mesher, density fallback, or direct
native terrain lifecycle.

The package manifest is Git-tracked addon content plus the explicitly
allowlisted Windows debug/release x86-64 runtime DLLs. Ignored object files,
static libraries, backups, and other working-tree artifacts are excluded. The
manifest digest normalizes text line endings and hashes binary payloads exactly.

## Ownership after migration

- `world_transvoxel` owns density/material state, Transvoxel meshing, native
  scheduling, collision payloads, storage, and authoritative sample queries.
- `world_transvoxel_terrain` owns the production API, profiles, bounded
  orchestration, generic materials, readiness, and generic diagnostics.
- `world_transvoxel_gameworld` owns roads/biome texture presentation, water
  presentation, and the deep topology classifier used by game QA.
- `scripts/main.gd` owns profile selection, player workflow, and assertions
  over authoritative samples. It does not reproduce terrain field evaluation.

## Configuration migration

| Previous configuration | TQP-54 result |
| --- | --- |
| Candidate or native addon copied independently | Replace both with the exact pins in `TQP54_PACKAGE_PIN.json`. |
| Game material paths under `world_transvoxel_terrain` | Moved to `world_transvoxel_gameworld/material`. |
| Deep game topology probe under `world_transvoxel_terrain` | Moved to `world_transvoxel_gameworld/debug`. |
| Presentation decisions from descriptive generation-summary fields | Use `procedural_preset_id`; verify terrain behavior with native sample queries. |
| Custom `edit_journal_path` | Rejected. Native authority owns `<object_root_path>/world.wtedit`. |
| `persist_edits=false` | Rejected. The current native authority always journals committed edits. |

Native world, chunk, and edit-journal formats did not change. The migration
smoke commits an edit, verifies render and collision readiness, stops, reopens,
and verifies the authoritative sample and revision were replayed.

## Gates

Run the quick deterministic migration qualification:

```console
python -B tools/validate_tqp54_migration.py
python -B tools/tqp54_migration_smoke.py
```

`tools/p2_production_integration_game_quality.py` remains the deeper gameplay
suite. Each autonomous profile now has a hard 1,800-second default timeout; it
is not the normal edit-loop check. A TQP-54 diagnostic attempt exceeded 900
seconds before this bound was added and is retained as a timeout observation,
not passing evidence.

TQP-54 qualifies package identity, project import, representative runtime
integration, persistence compatibility, and failure behavior. It does not claim
final game acceptance, arbitrary-path seamlessness, or Terrain 1.0 release.
