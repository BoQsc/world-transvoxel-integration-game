# Godot setup rules

This repository is a Godot project, not only a source-code repository. Some
runtime behavior depends on Godot-generated cache files, project settings,
enabled plugins, and imported resources. These rules are part of the project
contract.

## Required project entry point

Open this project through:

```text
C:\Users\Windows10_new\Documents\github_repositories\world-transvoxel-integration-game\project.godot
```

The main scene is:

```text
res://scenes/main.tscn
```

Normal human play should show fullscreen terrain with only the crosshair by
default. The project-wide Godot foreground frame cap is 60 FPS, and the main
scene throttles unfocused/background execution to 15 FPS. Debug telemetry should
only appear in autonomous proof paths.

## Required addons

Keep these addons enabled in `project.godot`:

- `res://addons/world_transvoxel/plugin.cfg`
- `res://addons/world_transvoxel_terrain/plugin.cfg`
- `res://addons/world_transvoxel_gameworld/plugin.cfg`

If Godot reports a missing GDExtension dynamic library, the `world_transvoxel`
addon binary is missing or stale. Do not debug terrain visuals until the
GDExtension loads cleanly.

## Asset import cache is not optional

Godot does not render directly from source texture files alone. For imported
assets, Godot uses this chain:

```text
source asset -> tracked .import file -> generated .godot/imported artifact -> runtime
```

Example:

```text
assets/terrain_textures/coast_sand_01_diff_1k.jpg
assets/terrain_textures/coast_sand_01_diff_1k.jpg.import
.godot/imported/coast_sand_01_diff_1k...ctex
```

The `.import` file is tracked and contains the intended settings. The
`.godot/imported` file is generated and ignored, but Godot uses it at runtime.
That means editing the `.import` file is not enough by itself. The import cache
must be refreshed before visual testing.

Run this after adding or changing textures, texture import settings, or other
Godot-imported assets:

```console
python tools/godot_import_assets.py
```

This runs Godot in import mode and verifies the required imported artifacts.

For a cheaper check that does not re-run Godot:

```console
python tools/godot_import_assets.py --verify-only
```

`--verify-only` is only valid if the cache was already refreshed.

## Quality gate

Before trusting a game run, human visual review, screenshot capture, or terrain
material change, run:

```console
python tools/p2_production_integration_game_quality.py --skip-build --visual-smoke
```

This quality gate first refreshes/verifies the Godot import cache, then launches
the actual integration game profiles and visual captures. The default visual
captures include an edited-boundary watertightness probe; it fails if the
rendered terrain mesh reports open edges or mixed triangle winding after the edit
batch.

## Current human terrain texture contract

The current human terrain presentation uses:

```text
res://assets/terrain_textures/coast_sand_01_diff_1k.jpg
```

Required import/material expectations:

- the sand texture import must generate mipmaps;
- human clean terrain must be matte enough for visual inspection;
- capture summaries must report `clean_roughness=1.0`;
- capture summaries must report `clean_specular=0.0`.

If these are wrong, visual conclusions about shimmer, glare, distance texture
quality, or terrain lighting are not reliable.

## Generated files

These are local generated outputs and should not be treated as source:

- `.godot/`
- `build/`
- `artifacts/`

Validation capture images are useful proof artifacts, but they should not be
written into normal `res://build` paths. Default automated captures go under:

```text
.godot/world_transvoxel_captures/
```

The import gate also writes `build/captures/.gdignore` so old generated capture
folders are not imported by Godot.

## Practical workflow

Use this sequence for Godot-facing changes:

1. Edit source files, scripts, shaders, scenes, or tracked `*.import` files.
2. Run `python tools/godot_import_assets.py` if imported assets may be affected.
3. Run `python tools/p2_production_integration_game_quality.py --skip-build --visual-smoke`.
4. Inspect captures only after the import/quality gates pass.
5. Commit only tracked source/config/doc/tool changes.

Running the game directly is useful for human playtesting, but it is not a
replacement for the import/quality gate.
