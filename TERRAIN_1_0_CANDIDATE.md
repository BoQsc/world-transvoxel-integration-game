# Terrain 1.0 candidate

Status as of 2026-07-13:
`CANDIDATE_AFTER_QUANTIZED_FINALIZER_AND_NATIVE_GAP_GATES`.

This file records the current Terrain 1.0 candidate state for the
`world-transvoxel-integration-game` repository. Later documentation-only commits
may point back to this candidate state; terrain/runtime source changes require a
new candidate run and fresh pass evidence.

## 2026-07-13 native topology/gap checkpoint

This checkpoint rejects presentation fallbacks. The current candidate uses
native single-sided Transvoxel chunks only; no full-map/backdrop layer,
double-sided terrain material, or duplicate hidden surface is allowed to satisfy
terrain-correctness gates.

Core addon evidence:

- release build passed with Zig 0.16.0;
- `test_wt_m2_chunk_mesh.template_release.x86_64.exe` passed with
  `M2_MESH_HASH 20a67f299820f5c3`;
- `test_wt_m3_application.template_release.x86_64.exe` passed;
- `test_wt_m5_page_meshing_runtime.template_release.x86_64.exe` passed with
  `human_boundary_repro=1`;
- `test_wt_production_lod_streaming.template_release.x86_64.exe` passed with
  `backend=MIT`.

Finalizer/topology boundary:

- edge ownership/orientation uses a 1/1024 world-unit quantized position key;
- exported vertex positions are not snapped by the finalizer;
- matched interior or chunk-face near-zero connector slivers are accepted only
  when probes report no open topology defect;
- unknown zero-area triangles, repeated-point-key triangles, zero-edge
  triangles, interior/unknown boundary edges, nonmanifold edges, and orientation
  conflicts are hard failures;
- deleting matched connector slivers is forbidden because that experiment opened
  real cracks in edited terrain.

Current integration evidence:

```console
python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand
```

Result: passed with `WT_PRODUCTION_INTEGRATION_GAME_QUALITY_PASS profiles=1`.

```console
python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand --visual-smoke --visual-mode edit_near --visual-output-dir .godot/world_transvoxel_captures/final_authoritative_edit_near --visual-wait-frames 180
```

Result: passed with `WT_PRODUCTION_INTEGRATION_GAME_VISUAL_SMOKE_PASS`.
The watertightness probe reported `boundary_edges=0`,
`interior_boundary_edges=0`, `unknown_boundary_edges=0`,
`nonmanifold_edges=0`, `orientation_conflict_edges=0`,
`repeated_point_key_triangles=0`, `unsafe_zero_area_triangles=0`,
`zero_area_unknown_triangles=0`, `zero_edge_triangles=0`, and
`safe_zero_area_interior_triangles=4`.

```console
python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand --tunnel-upward-lod-gate --tunnel-upward-lod-profile g19_compact_2k_on_demand --tunnel-upward-lod-output-dir .godot/world_transvoxel_captures/final_authoritative_tunnel_upward_lod --visual-wait-frames 720
```

Result: passed with `WT_TUNNEL_UPWARD_LOD_GATE_PROFILE_PASS
profile=g19_compact_2k_on_demand operations=110 probes=6`.
All six probes reported `boundary_edges=0`, `interior_boundary_edges=0`,
`nonmanifold_edges=0`, `orientation_conflict_edges=0`,
`repeated_point_key_triangles=0`, `zero_area_unknown_triangles=0`, and
`zero_edge_triangles=0`.

```console
python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand --visual-smoke --visual-mode streaming_fly_gap_gate --visual-output-dir .godot/world_transvoxel_captures/final_authoritative_streaming_fly --visual-wait-frames 240
```

Result: passed with `WT_STREAMING_FLY_GAP_GATE_PROFILE_PASS
profile=g19_compact_2k_on_demand samples=28 max_pending=53 max_jobs=66`.

The streaming screenshot detector is intentionally not a sky/horizon detector.
It fails on crosshair sky, lower-center holes, clustered isolated center/lower
sky pixels, or clustered isolated terrain-band sky pixels. It ignores isolated
single-pixel horizon/edge noise because that was observed as screenshot aliasing
noise, not native terrain loss. Any human-visible new path still must be marked
with `~`, then `M`, and promoted into a targeted gate.

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
- the streaming fly gate fails on centered/lower terrain holes and clustered
  isolated terrain-band sky pixels, while ignoring isolated single-pixel
  horizon/edge noise that was observed as screenshot aliasing rather than
  terrain loss.

Fresh follow-up evidence:

```console
python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand --tunnel-upward-lod-gate --tunnel-upward-lod-profile g19_compact_2k_on_demand --tunnel-upward-lod-output-dir .godot/world_transvoxel_captures/final_authoritative_tunnel_upward_lod --visual-wait-frames 720
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
python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand --visual-smoke --visual-mode streaming_fly_gap_gate --visual-output-dir .godot/world_transvoxel_captures/final_authoritative_streaming_fly --visual-wait-frames 240
```

Result: passed with exit code 0.

Observed pass markers:

- `WT_PRODUCTION_GAME_P2_PASS profile=g19_compact_2k_on_demand`
- `WT_STREAMING_FLY_GAP_GATE_PROFILE_PASS profile=g19_compact_2k_on_demand samples=28 max_pending=53 max_jobs=66`
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

## Superseded visual-stability notes

Earlier compact streaming/fly and `edit_near` follow-ups are superseded by the
native topology/gap checkpoint at the top of this file. The current authoritative
state is:

- compact ground, streaming/fly, tunnel/upward-LOD, and `edit_near` gates pass;
- terrain-correctness paths render native single-sided Transvoxel chunks only;
- matched near-zero connector slivers are accepted only under the explicit
  topology-probe boundary recorded above.

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

## Human-visible startup boundary

Normal human play must not expose partially loaded terrain as gameplay. The
integration scene may show a plain loading cover while the runtime reaches strict
visual readiness, but the cover must stay up until render/collision queues,
scheduled completions, pending replacements, pending retirements, staged render
resources, and render-fading resources are all idle and the active chunk records
are fully ready.

This boundary distinguishes acceptable startup loading from terrain failure:

- terrain hidden behind the loading cover is startup loading, not a gameplay
  seamlessness claim;
- visible terrain after the cover disappears must not contain unloaded rectangular
  patches, sky leaks, or missing LOD replacement chunks;
- visual gates that are not explicitly testing transient replacement behavior
  must start from a settled post-edit state so startup/edit replacement bursts
  are not confused with normal play.

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
