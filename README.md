# World Transvoxel Production Integration Game

This repository is the P2 production integration game proof for the World
Transvoxel addon stack.

It imports:

- `world_transvoxel`
- `world_transvoxel_terrain`
- `world_transvoxel_gameworld`

It intentionally does not copy validation-game tests, tools, scenes, or runtime
internals. The game opens through `project.godot` and runs `res://scenes/main.tscn`.

## Runtime features

- first-person player with `FirstPersonCamera`;
- crosshair UI;
- terrain edit input path;
- telemetry overlay and profile selector for autonomous proof;
- hidden telemetry/profile selector during normal human play;
- fullscreen project default plus runtime fullscreen for human launch;
- profile selector with `flat_baseline` and `g19_compact_2k_on_demand`;
- compact 2K terrain through `WtGameWorld` with `viewer_maximum_lod=1`;
- production terrain material texture pipeline on active render meshes;
- compact 2K full-map terrain presentation covering 2048 by 2048 blocks;
- local detail exclusion in the full-map visual so playable collision/detail
  chunks are not covered by a non-collision overview mesh;
- spawn floor raycast sanity before automated handoff.

## Automated proof

Run from `world-transvoxel-validation-game`:

```console
python tools/p2_production_integration_game_quality.py --skip-build
```

The proof launches this project through `project.godot`, validates both standard
profiles, submits terrain edits through player input methods, verifies storage
journals, requires cold idle, proves the spawn floor, and proves the Terrain 1.0
presentation marker fields.
