# Storage Ownership

World manifest, edit journal, save/load/reopen, migration, and persistence
boundary code belongs here.

Storage formats must be deterministic and versioned before game use.

Current A4 phase 1 resources:

- `WtTerrainStorageProfile` defines manifest, edit journal, and snapshot write
  targets;
- `WtTerrainRecoveryPolicy` defines manual recovery targets while automatic
  regeneration, smoothing, structural collapse, and fluid equilibrium remain
  disabled by default.

A4 phase 2 verifies the official backend writes and replays a native
`world.wtedit` journal through a temporary fixture. Production storage ownership
inside `WtTerrainWorld` remains a later A4 phase.

A4 phase 3 adds `object_root_path` so `WtTerrainWorld` can start the official
backend lifecycle from a storage profile. `allow_res_paths_for_test_fixtures` is
only for ignored temporary Godot fixtures; normal write paths remain `user://`.
