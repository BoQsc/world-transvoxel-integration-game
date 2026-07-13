# Terrain 1.0 candidate

Status as of 2026-07-13:
`CANDIDATE_AFTER_EDIT_LOD_RETENTION_AND_STREAMING_VISUAL_FOLLOWUP`.

This file records the current Terrain 1.0 candidate state for the
`world-transvoxel-integration-game` repository. Later documentation-only commits
may point back to this candidate state; terrain/runtime source changes require a
new candidate run and fresh pass evidence.

## 2026-07-13 visual-continuity follow-up

Human testing distinguished three separate issues that must not be mixed:

- nearby dug-tunnel pinhole sky leaks are mesh/watertightness symptoms;
- large pieces flashing during flight are streaming/LOD visual-continuity
  symptoms;
- dug holes changing harshly at distance are edited-LOD-retention symptoms.

Current runtime/source changes in this candidate follow-up:

- recent edit LOD-retention zones remain active even when the player flies away,
  so recent dug/placed areas keep detailed LOD longer instead of immediately
  collapsing to coarse terrain;
- edit-retention fallback is budgeted and prioritized newest/visible first; this
  prevents the known all-retention fallback collapse, but it does not guarantee
  unlimited high-detail visibility of every edited region from every distance;
- newly created native render chunks are not faded in from transparent/sky when
  transition fading is enabled by a project;
- the integration profile keeps native render transition fading disabled
  (`runtime_render_transition_frames=0`) because fade/crossfade is an opt-in
  presentation feature, not the default terrain correctness path;
- the production/human profiles use a 4 m player-viewer update threshold so
  fast fly inspection creates smaller LOD movement deltas;
- the streaming fly gate now fails on isolated sky-colored pixels in the
  terrain band, not only near the crosshair/lower-center screen area.

Fresh follow-up evidence:

```console
python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand --tunnel-upward-lod-gate --tunnel-upward-lod-profile g19_compact_2k_on_demand --tunnel-upward-lod-output-dir .godot/world_transvoxel_captures/tunnel_upward_lod_after_transition_fix --visual-wait-frames 720
```

Result: passed with exit code 0.

Observed pass markers:

- `WT_PRODUCTION_GAME_P2_PASS profile=g19_compact_2k_on_demand`
- `WT_TUNNEL_UPWARD_LOD_GATE_PROFILE_PASS profile=g19_compact_2k_on_demand operations=110 probes=6`
- `WT_PRODUCTION_INTEGRATION_GAME_TUNNEL_UPWARD_LOD_GATE_PASS captures=1`

The generated summary reported `runtime_render_transition_frames=0`,
`edit_persistence.ok=true`, `tunnel.ok=true`, and `watertightness.ok=true` for
the probed edited tunnel/upward-LOD path.

```console
python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand --visual-smoke --visual-mode streaming_fly_gap_gate --visual-output-dir .godot/world_transvoxel_captures/streaming_fly_final --visual-wait-frames 240
```

Result: passed with exit code 0.

Observed pass markers:

- `WT_PRODUCTION_GAME_P2_PASS profile=g19_compact_2k_on_demand`
- `WT_STREAMING_FLY_GAP_GATE_PROFILE_PASS profile=g19_compact_2k_on_demand samples=28 max_pending=53 max_jobs=59`
- `WT_PRODUCTION_INTEGRATION_GAME_VISUAL_SMOKE_PASS captures=1`

Important boundary: this proves the current autonomous fly path did not detect
screen-space terrain-band sky leaks. It does not prove all possible human flight
paths are seamless. New human-visible paths must be captured with `~`, then `M`
and promoted into targeted gates.

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
- the native moving detail window still has visible streaming/LOD continuity
  cases that must be fixed in native terrain.

Current fix boundary:

- human fly mode is collision-aware;
- autonomous proof, normal human play, and terrain-correctness visual gates use
  native Transvoxel chunks only;
- native Transvoxel chunks remain single-sided, and any sky leak, open edge,
  zero-area triangle, harsh edited-LOD change, or transient streaming gap in
  native mode remains a real terrain issue.

Current native-only status:

- native compact ground capture passes;
- native compact streaming/fly capture passes;
- native compact edited `edit_near` capture still fails watertightness because
  the probe finds `zero_area_interior_triangles=4` after the edit batch. It does
  not report open interior boundary edges, nonmanifold edges, or orientation
  conflict edges in that capture, but the zero-area interior triangles keep the
  edited native mesh from being accepted as Terrain 1.0-ready.

Command:

```console
python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand --visual-smoke --visual-mode streaming_fly_gap_gate --visual-output-dir .godot/world_transvoxel_captures/streaming_fly_gap_gate_wrapper --visual-wait-frames 180
```

Result after removing presentation fallbacks: native-only compact streaming/fly
passed with exit code 0 in the latest local run.

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

Result after removing presentation fallbacks: native-only compact ground visual
passed, while native compact edited `edit_near` still fails on interior
near-zero-area triangles as noted above.

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
- compact human/visual native terrain continuity during moving/flying inspection;
- tunnel/deformation persistence;
- transient tunnel crawl topology probes across frames 0/1/3/8/16/32;
- visual sky-pixel artifact gate for deep closed tunnel captures.

This candidate does not claim:

- GPU/compute-shader terrain acceleration;
- water, lava, vegetation, buildings, biomes, multiplayer, or entity systems;
- unlimited high-detail visibility of every edited/mined region from every
  distance;
- seamless dynamic LOD for arbitrary future camera paths beyond the recorded
  gates;
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

Every new human-marked artifact path must either be explained as an intentional
profile/budget tradeoff or promoted into an automated targeted gate before the
same profile can be treated as accepted. This is especially important for edited
terrain: close-range manifold probes, persistence samples, and far-distance LOD
shape continuity are separate claims and must not be collapsed into one generic
"terrain works" statement.

Diagnostic files are written under:

```text
.godot/world_transvoxel_captures/human_artifact_marks/
```
