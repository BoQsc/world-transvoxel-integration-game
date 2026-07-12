# World Transvoxel Production Integration Game

This repository is the current human-playable production integration game for
the World Transvoxel addon stack.

Current Terrain 1.0 candidate status is recorded in
[TERRAIN_1_0_CANDIDATE.md](TERRAIN_1_0_CANDIDATE.md). The current candidate is
the runtime source at commit `0050ed8ea01300394988442e5f19e7577575a3fe`,
validated by the focused autonomous readiness suite. Human acceptance is not
complete: a small sky-colored pixel artifact was reproduced during manual
digging and is now tracked by the human artifact marker (`~`, then `M`).

Read [GODOT_SETUP.md](GODOT_SETUP.md) before changing textures, import settings,
addons, scenes, or human visual tests. Godot-specific generated import state is
part of the runtime contract, and stale import cache can make visual testing
misleading.

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

## Godot asset import gate

Full Godot setup rules are in [GODOT_SETUP.md](GODOT_SETUP.md).

Godot runtime assets are not fully defined by the tracked source texture alone.
Texture import settings live in tracked `*.import` files, while Godot consumes
generated cache artifacts under `.godot/imported`. After changing or adding
textures, refresh and verify that cache before trusting a game run or visual
capture:

```console
python tools/godot_import_assets.py
```

The production integration quality gate runs this import step automatically
before launching profiles or visual captures. This is required for settings such
as mipmaps to actually reach the runtime `.ctex` texture.

## Runtime features

- first-person player with `FirstPersonCamera`;
- fullscreen normal play by default;
- crosshair UI only; telemetry and profile selector are hidden during normal
  human play;
- mouse-look, WASD movement, jump, and terrain edit input path;
- human lighting controls for daylight, low-angle, overcast, and a local
  inspection-light field with multiple colored lights placed over terrain;
- telemetry overlay and profile selector for autonomous proof;
- default human profile is flat terrain; the mountainous 2K profile is explicit
  inspection coverage;
- compact 2K terrain through `WtGameWorld` with native LOD3 coarse coverage,
  capped radius-1 near-detail refinement, and no fake full-map visual in human
  play;
- sharp deterministic mountain stress terrain inside the current procedural
  vertical budget, with tall ridges, spire-like peaks, steep slopes, and the
  human spawn placed above terrain and snapped to collision before input is
  enabled;
- production terrain material texture pipeline installed through the native
  render material override, so newly streamed chunks do not flash with the
  engine default material;
- normal human play uses the sand texture at
  `res://assets/terrain_textures/coast_sand_01_diff_1k.jpg` and keeps
  material-ID tinting off by default;
- spawn floor raycast sanity before automated handoff;
- terrain interaction proof requires a real camera raycast hit against terrain
  collision, accepted edit submission, backend `edit_committed`, and zero
  `edit_failed` events;
- visual smoke includes an edited-boundary watertightness probe that audits the
  rendered mesh for open edges and mixed triangle winding after a multi-operation
  deformation batch.

## Profile setup

The default human profile is `flat_baseline`. It is intentionally the safe,
flat terrain option for normal launch.

The mountainous inspection profile is `g19_compact_2k_on_demand`, a
deterministic compact 2K map with 128 by 128 chunks, 2048 by 2048 block
coverage, and `viewer_maximum_lod=3`. The profile uses `radius_chunks=8` for
full native coarse coverage across the 2K map and
`runtime_lod_refinement_radius_chunks=1` so near detail does not force the
entire visible world to refine. It is intentionally a stress profile: it is not
the default terrain style, and it exists to inspect Transvoxel seams, lighting,
materials, and edit replacement behavior on tall, sharper terrain.

The flat baseline profile remains available for proof automation:

```gdscript
game_world.configure_game_world(
	&"g19_compact_2k_on_demand",
	generation_profile,
	storage_profile,
	[Vector3(1032.0, 52.0, 1032.0)],
	8,
	32,
	Vector3(1032.0, 52.0, 1032.0),
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
- `~`, then `L`: cycle global lighting preset
- `~`, then `K`: toggle local terrain inspection lights near/above the player
  plus static colored terrain lights over the mountain/flat inspection area
- `~`, then `M`: mark a currently visible terrain artifact; this saves a
  screenshot, exact camera/raycast/edit context, sky-pixel counts around the
  crosshair, isolated/pinhole-like sky-pixel ray diagnostics, and normal plus
  high-precision local mesh watertightness probes under
  `.godot/world_transvoxel_captures/human_artifact_marks/`
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
resource counts, viewer updates, edit replacements, edit submission/accept/
commit/failure counts, and the collision activation/deactivation settings.
Human play hides the telemetry UI by default; autonomous proof keeps it
available for validation.

## Troubleshooting

| Problem | Check |
| --- | --- |
| GDExtension missing | Rebuild or recopy `world_transvoxel`; `world_transvoxel.gdextension` must point at real Windows debug/release libraries. |
| Terrain invisible | Verify generation and storage profiles, then confirm `viewer_maximum_lod=3`, `radius_chunks=8`, and sufficient runtime capacities for compact 2K. |
| Player falls or spawns badly | Run the autonomous proof and check `spawn_floor_hit=1` and `spawn_above_floor=1`. |
| Edits do not commit | Inspect `game_world.get_last_edit_summary()`, `edit_commit_count`, `edit_failure_count`, and the terrain edit journal under `res://build/<game>/<profile>/`. |
| Clicks appear to do nothing | Confirm the player interaction summary reports `ray_hit=true`; visible render chunks are not enough if collision coverage is stale or too narrow. |
| White/default chunks flash while moving | Confirm the material summary reports `native_render_material_override=true`; the old recursive-only material scan is not sufficient for human play. |
| Debug UI visible during human play | Confirm you are running this integration game main scene, not an older validation playtest scene. |

## Automated proof

Run:

```console
python tools/p2_production_integration_game_quality.py --skip-build
```

The proof first refreshes/verifies the Godot import cache, then launches this
project through `project.godot`, validates both standard profiles, submits
terrain edits through player input methods, verifies repeated committed edits,
proves a camera raycast interaction against terrain collision, verifies storage
journals, requires gameplay-settled streaming for the compact LOD profile, keeps
strict cold-idle for the flat baseline, proves the spawn floor, and proves the
Terrain 1.0 presentation marker fields.

For terrain presentation smoke, run:

```console
python tools/p2_production_integration_game_quality.py --skip-build --visual-smoke
```

This also captures the real compact human-play profile from ground,
high-oblique, top-down, and edited-boundary watertightness views under
`.godot/world_transvoxel_captures/terrain_1_0_visual_smoke/` and rejects
regressions where the fake full-map visual is enabled, native material override
is missing, visible native terrain coverage falls below the expected compact 2K
profile thresholds, or the edited rendered mesh reports open edges / mixed
triangle winding.

For the movement/edit LOD gate, run:

```console
python tools/p2_production_integration_game_quality.py --skip-build --lod-movement-gate
```

This exercises deterministic edit batches, real player interaction edits, and
close/mid/far viewer movement on the compact and flat profiles. It fails on
permanent authoritative edit loss, settled open rendered edges, or transient
movement-triggered LOD crack probes. The gameworld keeps a low steady render /
collision apply budget of 8 and uses a short viewer-movement burst budget of 128
for 30 frames to avoid exposing partial LOD replacement sets while the player is
moving.

For the edit-during-load persistence gate, run:

```console
python tools/p2_production_integration_game_quality.py --skip-build --edit-during-load-gate
```

This moves away from the edit target, returns while the target zone is still
streaming, submits deterministic edit batches before visual readiness, then
checks authoritative samples after late load completion and after reload. It
fails on restored/lost edits, missing authoritative samples, open rendered gaps,
or nonmanifold rendered edges.

For the broader manifold stress gate, run:

```console
python tools/p2_production_integration_game_quality.py --skip-build --manifold-stress-gate
```

This submits 128 deterministic mixed edit operations, checks interim movement
while edits are still accumulating, then verifies close/mid/far/return movement
and reload persistence on the compact and flat profiles. It fails on changed
authoritative samples, missing carved-air samples, transient or settled open
rendered gaps, nonmanifold rendered edges, zero-edge triangles, or unknown
degenerate geometry.

For explicit deformation inspection captures, run Godot directly with the
mountain profile and an `edit_*` capture mode. These modes submit a real
multi-operation terrain edit batch, wait for world revision and streaming
settlement, then capture the result:

```console
"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --path C:\Users\Windows10_new\Documents\github_repositories\world-transvoxel-integration-game -- --p2-profile g19_compact_2k_on_demand --human-lighting-preset 3 --human-visual-capture .godot/world_transvoxel_captures/interaction/edit_near.png --human-visual-capture-mode edit_near --human-visual-capture-wait-frames 180

"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --path C:\Users\Windows10_new\Documents\github_repositories\world-transvoxel-integration-game -- --p2-profile g19_compact_2k_on_demand --human-lighting-preset 3 --human-visual-capture .godot/world_transvoxel_captures/interaction/edit_far.png --human-visual-capture-mode edit_far --human-visual-capture-wait-frames 180
```
