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
- telemetry overlay;
- profile selector with `flat_baseline` and `g19_compact_2k_on_demand`;
- compact 2K terrain through `WtGameWorld`.

## Automated proof

Run from `world-transvoxel-validation-game`:

```console
python tools/p2_production_integration_game_quality.py --skip-build
```

The proof launches this project through `project.godot`, validates both standard
profiles, submits terrain edits through player input methods, verifies storage
journals, and requires cold idle.
