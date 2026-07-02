# World Transvoxel Production Integration Game

This repository is the current human-playable production integration game for
the World Transvoxel addon stack.

It imports:

- `world_transvoxel`
- `world_transvoxel_terrain`
- `world_transvoxel_gameworld`

It intentionally does not copy internal validation scenes, tests, or tools. The
game opens through `project.godot` and runs `res://scenes/main.tscn`.

## Installation

Keep these three addons enabled in `project.godot`:

- `res://addons/world_transvoxel/plugin.cfg`
- `res://addons/world_transvoxel_terrain/plugin.cfg`
- `res://addons/world_transvoxel_gameworld/plugin.cfg`

Run the main scene from:

```text
C:\Users\Windows10_new\Documents\github_repositories\world-transvoxel-integration-game\project.godot
```

## Runtime features

- first-person player with `FirstPersonCamera`;
- fullscreen normal play by default;
- crosshair UI only; telemetry and profile selector are hidden during normal
  human play;
- mouse-look, WASD movement, jump, and terrain edit input path;
- telemetry overlay and profile selector for autonomous proof;
- profile selector with `flat_baseline` and `g19_compact_2k_on_demand`;
- compact 2K terrain through `WtGameWorld` with native LOD3 coarse coverage,
  capped radius-1 near-detail refinement, and no fake full-map visual in human
  play;
- production terrain material texture pipeline on active render meshes;
- spawn floor raycast sanity before automated handoff.

## Profile setup

The default human profile is `g19_compact_2k_on_demand`, a deterministic compact
2K map with 128 by 128 chunks, 2048 by 2048 block coverage, and
`viewer_maximum_lod=3`. The profile uses `radius_chunks=8` for full native
coarse coverage across the 2K map and `runtime_lod_refinement_radius_chunks=1`
so near detail does not force the entire visible world to refine.

The flat baseline profile remains available for proof automation:

```gdscript
game_world.configure_game_world(
	&"g19_compact_2k_on_demand",
	generation_profile,
	storage_profile,
	[Vector3(1032.0, 8.0, 1032.0)],
	8,
	32,
	Vector3(1032.0, 24.0, 1032.0),
	3
)
```

Use `WtTerrainGenerationProfile` and `WtTerrainStorageProfile` resources when
building your own game setup.

## Terrain editing

Normal play edits the terrain through the game-world addon boundary:

```gdscript
game_world.submit_sphere_edit(&"carve", hit_position, 1.8, -1, 1.0)
game_world.submit_sphere_edit(&"construct", hit_position, 1.8, 4, 1.0)
```

Controls:

- WASD: move
- Mouse: look
- Space: jump
- Left mouse: carve terrain at the crosshair hit
- Right mouse: place terrain at the crosshair hit
- `~`, then `F`: toggle fly mode for human terrain inspection
- Fly mode: WASD moves relative to camera, Space rises, Q/C descends, Shift flies faster
- Escape: release mouse
- Click after release: capture mouse again

## Storage

Generated runtime data goes under:

```text
res://build/<game>/<profile>/
```

The integration profile uses `res://build/p2-production-game/<profile>/` for
runtime edit journals and snapshots. Local `build/` data is ignored and should
not be committed.

## Telemetry

Use `game_world.get_game_world_summary()` for active records, render/collision
resource counts, viewer updates, and edit replacements. Human play hides the
telemetry UI by default; autonomous proof keeps it available for validation.

## Troubleshooting

| Problem | Check |
| --- | --- |
| GDExtension missing | Rebuild or recopy `world_transvoxel`; `world_transvoxel.gdextension` must point at real Windows debug/release libraries. |
| Terrain invisible | Verify generation and storage profiles, then confirm `viewer_maximum_lod=3`, `radius_chunks=8`, and sufficient runtime capacities for compact 2K. |
| Player falls or spawns badly | Run the autonomous proof and check `spawn_floor_hit=1` and `spawn_above_floor=1`. |
| Edits do not commit | Inspect `game_world.get_last_edit_summary()` and the terrain edit journal under `res://build/<game>/<profile>/`. |
| Debug UI visible during human play | Confirm you are running this integration game main scene, not an older validation playtest scene. |

## Automated proof

Run:

```console
python tools/p2_production_integration_game_quality.py --skip-build
```

The proof launches this project through `project.godot`, validates both standard
profiles, submits terrain edits through player input methods, verifies storage
journals, requires cold idle, proves the spawn floor, and proves the Terrain 1.0
presentation marker fields.
