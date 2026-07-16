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
- player-driven viewer updates use a 4 m movement threshold in the current
  profiles; this keeps LOD movement deltas smaller during fly inspection while
  avoiding excessive viewer churn
- mountain terrain: intentionally sharp/tall stress terrain with ridges,
  spire-like peaks, and steep slopes for seam, lighting, material, and edit
  inspection
- compact human/visual runs are native Transvoxel terrain only. There is no
  full-map/backdrop backing layer for terrain-correctness review; visible native
  terrain gaps, edit artifacts, or LOD/streaming holes must be fixed in the
  terrain path.
- fullscreen by default
- active play is capped to 60 FPS, focused idle play throttles to 30 FPS, and
  background/unfocused execution throttles to 15 FPS. See
  `GODOT_RUNTIME_POWER_POLICY.md`; this policy should be copied into future
  Godot terrain/gameworld projects.
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
- `~`, then `M`: mark a visible terrain artifact at the current camera view;
  this saves screenshot/JSON diagnostics under
  `.godot/world_transvoxel_captures/human_artifact_marks/`
  including isolated sky-pixel counts, exact screen-pixel rays for pinhole-like
  sky leaks, CPU render-ray classification against visible render meshes,
  normal mesh probes, and high-precision seam probes.
- Fly mode: WASD moves relative to camera, Space rises, Q/C descends, Shift flies faster
- Escape: release mouse
- Click after release: capture mouse again

Current source commits are recorded in `CURRENT_PLAYTEST_FRESHNESS.json`.
Current Terrain 1.0 release closure is controlled by
`TERRAIN_1_0_CANDIDATE.md`. Use that file as the authoritative checklist before
asking for final human verification.

## Visual artifact terminology

Use these names when reporting terrain problems:

- Pinhole sky leak: tiny sky-colored pixels visible through nearby terrain,
  especially inside dug tunnels or holes. This is a mesh visibility/manifold
  symptom and should be marked with `~`, then `M`.
- Transient streaming/LOD gap: larger terrain pieces vanish or reveal sky for a
  frame or short moment while moving or flying. This is a streaming continuity
  symptom, not automatically proof that the generated mesh is nonmanifold. Do
  not hide it with a full-map/backdrop layer or double-sided terrain material. If
  it appears, run the streaming-fly gate and promote the path into a targeted
  native fix.
- Edited-LOD popping: a dug or placed shape changes harshly or disappears when
  the camera moves away and returns. This is an edit-retention/LOD-continuity
  symptom.

Edited-LOD retention is a serious budgeted limitation, not a solved-for-all-time
promise. The current runtime prevents the known fallback path where all recent
edit-retention viewers were dropped under planner pressure, but it still cannot
keep unlimited edited terrain high-detail from every distance. If many edits are
spread over a wide area, or if a profile chooses tight active chunk/viewer/LOD
budgets, distant edited shapes may simplify until a viewer moves close again.
Report harsh changes, transient sky gaps, or pinhole sky leaks with `~`, then
`M`; those marks are the required bridge from human observation to a targeted
automated gate.

Before requesting another human playtest, run the current automated gate set:

```console
python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand --visual-smoke --visual-mode edit_near --visual-wait-frames 180

python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand --tunnel-upward-lod-gate --tunnel-upward-lod-profile g19_compact_2k_on_demand --visual-wait-frames 720

python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand --visual-smoke --visual-mode streaming_fly_gap_gate --visual-wait-frames 240
```

Passing these gates means the known edited-near topology probe, tunnel/upward
LOD persistence probes, and autonomous streaming-fly screenshot detector passed.
The screenshot detector fails on centered/lower terrain holes and clustered
isolated terrain-band sky pixels; it intentionally ignores isolated
single-pixel horizon/edge noise. Passing these gates does not mean future camera
paths are impossible to break; if a human sees a new issue, mark it with `~`,
then `M` so the exact view can become a new targeted gate.

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
"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --path C:\Users\Windows10_new\Documents\github_repositories\world-transvoxel-integration-game -- --p2-profile g19_compact_2k_on_demand --human-lighting-preset 3 --human-visual-capture .godot/world_transvoxel_captures/interaction/edit_near.png --human-visual-capture-mode edit_near --human-visual-capture-wait-frames 180

"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --path C:\Users\Windows10_new\Documents\github_repositories\world-transvoxel-integration-game -- --p2-profile g19_compact_2k_on_demand --human-lighting-preset 3 --human-visual-capture .godot/world_transvoxel_captures/interaction/edit_far.png --human-visual-capture-mode edit_far --human-visual-capture-wait-frames 180
```
