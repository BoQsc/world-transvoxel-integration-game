# Terrain 1.0 candidate

Status as of 2026-07-12: `CANDIDATE_AFTER_STREAMING_FLY_VISUAL_STABILITY_FIX`.

This file records the current Terrain 1.0 candidate state for the
`world-transvoxel-integration-game` repository. Later documentation-only commits
may point back to this candidate state; terrain/runtime source changes require a
new candidate run and fresh pass evidence.

## Focused readiness suite

Command:

```console
python tools/p2_production_integration_game_quality.py --profile g19_compact_2k_on_demand --profile flat_baseline --tunnel-transient-crawl-gate --tunnel-visual-artifact-gate --visual-wait-frames 240
```

Result: passed with exit code 0.

Required pass markers observed:

- `WT_GODOT_IMPORT_ASSETS_PASS required_imports=1`
- `WT_PRODUCTION_GAME_P2_PASS profile=g19_compact_2k_on_demand`
- `WT_PRODUCTION_GAME_P2_PASS profile=flat_baseline`
- `WT_PRODUCTION_INTEGRATION_GAME_QUALITY_PASS profiles=2`
- `WT_TUNNEL_TRANSIENT_CRAWL_GATE_PROFILE_PASS profile=g19_compact_2k_on_demand operations=110 steps=16 frame_probes=96`
- `WT_TUNNEL_TRANSIENT_CRAWL_GATE_PROFILE_PASS profile=flat_baseline operations=98 steps=16 frame_probes=96`
- `WT_PRODUCTION_INTEGRATION_GAME_TUNNEL_TRANSIENT_CRAWL_GATE_PASS captures=2`
- `WT_TUNNEL_VISUAL_ARTIFACT_GATE_PROFILE_PASS profile=g19_compact_2k_on_demand analyzed=5 max_center_sky=0 max_sky=5`
- `WT_TUNNEL_VISUAL_ARTIFACT_GATE_PROFILE_PASS profile=flat_baseline analyzed=2 max_center_sky=0 max_sky=0`
- `WT_PRODUCTION_INTEGRATION_GAME_TUNNEL_VISUAL_ARTIFACT_GATE_PASS captures=2`

## Compact streaming/fly visual-stability follow-up

Human testing later exposed a different visual failure mode: while flying around
the compact mountain profile, local LOD/streaming movement could expose sky
through terrain. The root causes were:

- human fly mode previously moved the player directly and could allow invalid
  inside/below-terrain inspection views;
- compact human visual mode had no full 2K terrain fallback/backdrop under the
  native moving detail window;
- the full-map visual, when re-enabled, used a simplified height expression and
  one-sided culling, which could produce false sky cutouts on steep/grazing
  views.

Current fix boundary:

- human fly mode is collision-aware;
- autonomous native terrain proof remains full-map-free;
- compact human/visual mode enables an exact deterministic 2048 by 2048
  full-map LOD/backdrop using the same procedural height expression as the
  native source;
- only that full-map heightfield backdrop is cull-disabled. Native Transvoxel
  chunks remain single-sided, so this is not a workaround for native mesh
  nonmanifoldness.

Command:

```console
python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand --visual-smoke --visual-mode streaming_fly_gap_gate --visual-output-dir .godot/world_transvoxel_captures/streaming_fly_gap_gate_wrapper --visual-wait-frames 180
```

Result: passed with exit code 0.

Required pass markers observed:

- `WT_GODOT_IMPORT_ASSETS_PASS required_imports=1`
- `WT_PRODUCTION_GAME_P2_PASS profile=g19_compact_2k_on_demand`
- `WT_PRODUCTION_INTEGRATION_GAME_QUALITY_PASS profiles=1`
- `WT_STREAMING_FLY_GAP_GATE_PROFILE_PASS profile=g19_compact_2k_on_demand samples=28 max_pending=71 max_jobs=79`
- `WT_PRODUCTION_INTEGRATION_GAME_VISUAL_SMOKE_PASS captures=1`

Normal compact visual smoke was also rerun:

```console
python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand --visual-smoke --visual-output-dir .godot/world_transvoxel_captures/visual_smoke_compact --visual-wait-frames 180
```

Result: passed with exit code 0 and `full_map_enabled=true` in all compact
human visual capture summaries, while the autonomous native proof still reported
`full_map_visual=0`.

Capture output root:

```text
.godot/world_transvoxel_captures/
```

Generated captures are intentionally outside normal `res://build` paths and are
not imported as Godot resources.

## Candidate boundary

This candidate covers:

- production launch through this repository's `project.godot`;
- `flat_baseline` default terrain profile;
- `g19_compact_2k_on_demand` compact 2K mountainous inspection profile;
- native addon stack integration: `world_transvoxel`,
  `world_transvoxel_terrain`, and `world_transvoxel_gameworld`;
- player, camera, crosshair, terrain edit input, storage journal, and streaming
  readiness proof;
- terrain material import/runtime proof with mipmapped sand texture;
- compact human/visual full-map LOD/backdrop continuity during moving/flying
  inspection;
- tunnel/deformation persistence;
- transient tunnel crawl topology probes across frames 0/1/3/8/16/32;
- visual sky-pixel artifact gate for deep closed tunnel captures.

This candidate does not claim:

- GPU/compute-shader terrain acceleration;
- water, lava, vegetation, buildings, biomes, multiplayer, or entity systems;
- final human acceptance;
- final game production readiness outside this integration game scope.

## Required next confirmation

The next confirmation is one normal fullscreen human playtest from the real
integration game path:

```text
C:\Users\Windows10_new\Documents\github_repositories\world-transvoxel-integration-game\project.godot
```

Human review should check normal player movement, mouse capture, fly inspection,
dig/place interaction, terrain visuals, and whether any obvious terrain gaps,
loading flashes, or interaction stalls remain visible during normal play.

## Human-reproduced artifact follow-up

Earlier human testing reproduced small pixel-like sky-colored holes inside
manually dug terrain and later reproduced compact-profile terrain disappearing
while flying. The current autonomous follow-up covers the moving/flying compact
terrain case. The candidate is still not human-accepted until a normal fullscreen
playtest confirms no obvious terrain gaps, loading flashes, interaction stalls,
or recurring sky-colored pinholes remain.

Use `~`, then `M` during human play when the artifact is visible. The marker
saves:

- current screenshot;
- camera, player, raycast target, and last terrain edit context;
- sky-like pixel counts in the whole image, central image, and crosshair region;
- isolated/pinhole-like sky-pixel counts and screen-pixel rays, ignoring normal
  open-sky/horizon regions;
- CPU render-ray classification for isolated sky pixels, used to distinguish
  missing render geometry from backface/culling/material/raster cases;
- local mesh watertightness probes around the ray hit, last interaction,
  camera-forward samples, and player position.
- high-precision seam probes for the ray hit, last interaction, and isolated
  sky-pixel rays so subpixel chunk/LOD seam mismatches are not hidden by the
  coarse regular topology key.

Diagnostic files are written under:

```text
.godot/world_transvoxel_captures/human_artifact_marks/
```
