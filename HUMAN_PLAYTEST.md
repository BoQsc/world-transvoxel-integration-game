# Current human playtest

Open and run:

```text
C:\Users\Windows10_new\Documents\github_repositories\world-transvoxel-integration-game\project.godot
```

This is the current `world-transvoxel-integration-game` scene using the addon
stack directly. It is not the old validation playtest scene.

Read `GODOT_SETUP.md` before changing textures, import settings, addons, scenes,
or human visual tests. The Godot import cache is part of the runtime setup and
must not be treated as optional.

Expected baseline:

- addon stack: `world_transvoxel` + `world_transvoxel_terrain` + `world_transvoxel_gameworld`
- default profile: `flat_baseline`
- mountainous inspection profile: `g19_compact_2k_on_demand`
- mountain map: 2048 by 2048 blocks
- mountain runtime LOD: `viewer_maximum_lod=3`, `viewer_radius_chunks=8`, near-detail refinement radius 1
- mountain terrain: intentionally sharp/tall stress terrain with ridges,
  spire-like peaks, and steep slopes for seam, lighting, material, and edit
  inspection
- no fake full-map visual in normal human play
- fullscreen by default
- crosshair only by default; no debug telemetry UI unless running autonomous proof
- sand-textured clean terrain presentation using `assets/terrain_textures/coast_sand_01_diff_1k.jpg`
- the sand texture import is mipmapped for distance viewing, and the clean human material is intentionally rough/non-specular so terrain does not produce shiny lighting streaks
- clean human view keeps material IDs internal; material-ID tinting is off by default
- terrain is viewer-streamed: chunks are generated/loaded/meshed around the active player/camera and unloaded outside the active coverage. This is expected for the large-world runtime; edits persist through the journal/storage path instead of requiring the entire 2048×2048 map to stay rendered at once.
- player starts above the current higher-relief terrain and is snapped to the collision floor before input is enabled
- mouse-look, WASD movement, jump, fly inspection, terrain edit input, and lighting controls are present

Controls:

- WASD: move
- Mouse: look
- Space: jump
- Left mouse: carve terrain
- Right mouse: place terrain
- `~`, then `F`: toggle fly mode for terrain inspection
- `~`, then `L`: cycle global lighting preset
- `~`, then `K`: toggle local terrain inspection lights near/above the player
  and static colored lights over the terrain
- Fly mode: WASD moves relative to camera, Space rises, Q/C descends, Shift flies faster
- Escape: release mouse
- Click after release: capture mouse again

Current source commits are recorded in `CURRENT_PLAYTEST_FRESHNESS.json`.

Godot import cache rule:

Tracked `*.import` files are the source of truth for texture import settings, but
Godot uses generated files in `.godot/imported` at runtime. After changing or
adding textures, refresh and verify the Godot import cache before trusting visual
tests:

```console
python tools/godot_import_assets.py
```

The production integration quality gate runs this import step automatically
before launching the game profiles or visual captures.

Automated proof before asking for human review:

```console
python tools/p2_production_integration_game_quality.py --skip-build --visual-smoke
```

To launch the mountainous inspection profile directly from a terminal:

```console
"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --path C:\Users\Windows10_new\Documents\github_repositories\world-transvoxel-integration-game -- --p2-profile g19_compact_2k_on_demand
```

Automated near/far deformation captures:

```console
"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --path C:\Users\Windows10_new\Documents\github_repositories\world-transvoxel-integration-game -- --p2-profile g19_compact_2k_on_demand --human-lighting-preset 3 --human-visual-capture build/captures/interaction/edit_near.png --human-visual-capture-mode edit_near --human-visual-capture-wait-frames 180

"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --path C:\Users\Windows10_new\Documents\github_repositories\world-transvoxel-integration-game -- --p2-profile g19_compact_2k_on_demand --human-lighting-preset 3 --human-visual-capture build/captures/interaction/edit_far.png --human-visual-capture-mode edit_far --human-visual-capture-wait-frames 180
```
