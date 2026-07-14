# Terrain 1.0 candidate and release checklist

Status as of 2026-07-14:
`ACTIVE_RELEASE_CLOSURE_CHECKLIST_AFTER_SERVER_COMPATIBILITY_GATE`.

This file is the authoritative Terrain 1.0 release closure checklist for the
`world-transvoxel-integration-game` repository. Lower dated sections preserve
evidence/history, but this top checklist controls the release decision. If a
README, human-playtest note, or older evidence block conflicts with this
checklist, this checklist wins.

Documentation-only commits may point back to the last valid candidate evidence.
Terrain/runtime/source changes require a new candidate run and fresh pass
evidence before Terrain 1.0 can be called releasable.

## Release decision boundary

Terrain 1.0 is not a generic game-world release. It is the release candidate for
the terrain addon stack as exercised by this integration game.

Terrain 1.0 may be called ready only when all blocking rows below pass after the
latest terrain/runtime source change:

| Area | Required standard | Blocking gate / evidence |
| --- | --- | --- |
| Godot setup | Texture import settings and generated import cache are valid before visual testing. | `python tools/godot_import_assets.py` or any P2 proof that prints `WT_GODOT_IMPORT_ASSETS_PASS required_imports=1`. |
| Runtime launch | Real `project.godot`, real main scene, addon stack loaded, no stale validation scene. | P2 profile proof prints `WT_PRODUCTION_GAME_P2_PASS` for `flat_baseline`, `g19_compact_2k_on_demand`, and `g20_deep_2k_256_on_demand`. |
| Volumetric terrain | Terrain is authoritative signed density/material volume, not a heightmap-only mesh. | P2 proof prints `WT_STANDARD_VOLUME_CONTRACT_PASS` for all standard profiles. |
| Deeper underground profile | Standard deeper terrain expands native vertical chunk coverage instead of faking underground with caps or presentation meshes. | P2 proof prints `WT_STANDARD_VOLUME_CONTRACT_PASS` and `WT_PRODUCTION_GAME_P2_PASS` for `g20_deep_2k_256_on_demand` with `vertical_cells=256`. |
| Material strata | Terrain profile exposes standard material palette and authoritative shallow/mid/deep underground depth bands. | P2 proof prints `WT_STANDARD_MATERIAL_STRATA_CONTRACT_PASS` for all standard profiles. |
| Future server compatibility | Terrain authority remains compatible with future multiplayer/dedicated servers. | P2 proof prints `WT_STANDARD_MULTIPLAYER_SERVER_CONTRACT_PASS` for all standard profiles. |
| No presentation fallback | Native single-sided Transvoxel chunks only for terrain correctness. No full-map layer, duplicate terrain skin, or double-sided material used to hide holes. | Visual/topology gates below must pass without presentation fallback. |
| Player interaction | Player/camera/crosshair, raycast edit path, committed edit revision, storage journal, and no edit failures. | P2 proof fields: `player=1`, `camera=1`, `crosshair=1`, `interaction_raycast=1`, `storage_journal=1`, `edit_failures=0`. |
| Materials | Human terrain material uses native render material override and mipmapped imported texture cache. | P2 proof fields: `material=1`, `production_texture_active=1`, `native_render_material_override=1`; import gate passes. |
| Startup visibility | Human play must not expose partially loaded terrain after the loading cover disappears. | Startup visual readiness and P2 proof pass; human-visible unloaded rectangular patches after readiness are release blockers. |
| Streaming/fly continuity | Moving/flying compact terrain must not expose centered/lower terrain sky holes or clustered terrain-band pinholes. | Streaming fly gap gate passes. |
| Edited terrain LOD | Recent player edits must persist through close/mid/far/return movement without harsh restoration, lost edits, or incomplete retained edited regions under the standard profile budgets. | LOD movement and multi-site LOD gates pass with `edited_exact_region` summary and zero retention fallback. |
| Edit during load | Edits submitted while target terrain is still streaming must not be restored/lost after load completion or reload. | Edit-during-load gate passes. |
| Manifold / tunnel edits | Realistic small-radius/deep/diagonal tunnel edits must not produce open, nonmanifold, or visible sky-leak terrain under the standard gates. | Tunnel, tunnel-crawl, tunnel-transient-crawl, tunnel-upward-LOD, tunnel visual artifact, and manifold stress gates pass. |
| Human acceptance | Human playtest is final confirmation only, not the primary proof mechanism. | One normal fullscreen human playtest from `project.godot`, with any visible issue marked using `~`, then `M`. |

## Finite release command suite

Run this suite for release closure. Do not replace it with ad hoc screenshots or
random gate selection.

Baseline profiles:

```console
python tools/p2_production_integration_game_quality.py --skip-build --profile flat_baseline --profile g19_compact_2k_on_demand --profile g20_deep_2k_256_on_demand
```

General visual smoke:

```console
python tools/p2_production_integration_game_quality.py --skip-build --visual-smoke --visual-wait-frames 240
```

Compact streaming/fly continuity:

```console
python tools/p2_production_integration_game_quality.py --skip-build --profile g19_compact_2k_on_demand --visual-smoke --visual-mode streaming_fly_gap_gate --visual-output-dir .godot/world_transvoxel_captures/release_streaming_fly_gap_gate --visual-wait-frames 240
```

Edited terrain LOD:

```console
python tools/p2_production_integration_game_quality.py --skip-build --lod-movement-gate

python tools/p2_production_integration_game_quality.py --skip-build --multisite-lod-gate
```

Edit persistence during streaming:

```console
python tools/p2_production_integration_game_quality.py --skip-build --edit-during-load-gate
```

Manifold/tunnel/deformation stress:

```console
python tools/p2_production_integration_game_quality.py --skip-build --manifold-stress-gate

python tools/p2_production_integration_game_quality.py --skip-build --tunnel-gate

python tools/p2_production_integration_game_quality.py --skip-build --tunnel-crawl-gate

python tools/p2_production_integration_game_quality.py --skip-build --tunnel-transient-crawl-gate

python tools/p2_production_integration_game_quality.py --skip-build --tunnel-upward-lod-gate

python tools/p2_production_integration_game_quality.py --skip-build --tunnel-visual-artifact-gate
```

Final human confirmation:

```text
C:\Users\Windows10_new\Documents\github_repositories\world-transvoxel-integration-game\project.godot
```

Use default `flat_baseline` for normal play and
`--p2-profile g19_compact_2k_on_demand` for mountainous inspection. Mark visible
terrain artifacts with `~`, then `M`; every marked release-blocking artifact
must be fixed or converted into a targeted automated gate.

## Current recorded release evidence

Fresh 2026-07-14 profile proof after the server-compatibility standard:

```console
python tools/p2_production_integration_game_quality.py --godot "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --project . --profile flat_baseline
```

Observed pass markers:

- `WT_GODOT_IMPORT_ASSETS_PASS required_imports=1`
- `WT_STANDARD_VOLUME_CONTRACT_PASS profile=flat_baseline`
- `WT_STANDARD_MATERIAL_STRATA_CONTRACT_PASS profile=flat_baseline`
- `WT_STANDARD_MULTIPLAYER_SERVER_CONTRACT_PASS profile=flat_baseline`
- `WT_PRODUCTION_GAME_P2_PASS profile=flat_baseline`
- `WT_PRODUCTION_INTEGRATION_GAME_QUALITY_PASS profiles=1`

```console
python tools/p2_production_integration_game_quality.py --godot "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --project . --profile g19_compact_2k_on_demand
```

Observed pass markers:

- `WT_GODOT_IMPORT_ASSETS_PASS required_imports=1`
- `WT_STANDARD_VOLUME_CONTRACT_PASS profile=g19_compact_2k_on_demand`
- `WT_STANDARD_MATERIAL_STRATA_CONTRACT_PASS profile=g19_compact_2k_on_demand`
- `WT_STANDARD_MULTIPLAYER_SERVER_CONTRACT_PASS profile=g19_compact_2k_on_demand`
- `WT_PRODUCTION_GAME_P2_PASS profile=g19_compact_2k_on_demand`
- `WT_PRODUCTION_INTEGRATION_GAME_QUALITY_PASS profiles=1`

```console
python tools/p2_production_integration_game_quality.py --godot "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --project . --profile g20_deep_2k_256_on_demand
```

Observed pass markers:

- `WT_GODOT_IMPORT_ASSETS_PASS required_imports=1`
- `WT_STANDARD_VOLUME_CONTRACT_PASS profile=g20_deep_2k_256_on_demand horizontal_cells=2048 vertical_cells=256 vertical_origin_cell=-128`
- `WT_STANDARD_MATERIAL_STRATA_CONTRACT_PASS profile=g20_deep_2k_256_on_demand`
- `WT_STANDARD_MULTIPLAYER_SERVER_CONTRACT_PASS profile=g20_deep_2k_256_on_demand`
- `WT_PRODUCTION_GAME_P2_PASS profile=g20_deep_2k_256_on_demand`
- `WT_PRODUCTION_INTEGRATION_GAME_QUALITY_PASS profiles=1`

The remaining release command suite is finite and must be rerun before tagging
or announcing Terrain 1.0 if any terrain/runtime source changes occur.

## Accepted Terrain 1.0 non-goals

These are intentionally outside Terrain 1.0 and must not be allowed to block the
terrain release checklist:

- GPU/compute-shader terrain acceleration;
- water/lava;
- vegetation;
- block/building systems;
- biomes beyond the current material proof;
- multiplayer gameplay implementation;
- dedicated-server deployment;
- entity systems;
- collapse/stability simulation;
- ore/vein generation;
- unlimited full-resolution visibility of every edit from every distance;
- exact global map-editor multi-LOD baking.

These future systems must build on the same volumetric, server-compatible,
authoritative terrain state. They must not introduce a second terrain truth.

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
  triangles, interior/unknown boundary edges, and nonmanifold edges are hard
  failures;
- exact topology gates fail on orientation conflicts; movement/open-gap gates
  may record chunk-face-only orientation diagnostics only when there are no open
  edges, no nonmanifold edges, no interior/unknown orientation conflicts, and no
  pending replacement/retirement work;
- deleting matched connector slivers is forbidden because that experiment opened
  real cracks in edited terrain.

## 2026-07-14 edited exact-region gate reinforcement

The post-candidate validation was tightened to make the human-reported
"dug holes change after moving away and returning" failure mode explicit. The
movement, multi-site, tunnel, tunnel-crawl, transient-crawl, and upward-LOD
gates now require an `edited_exact_region` summary before passing:

- committed edits must exist in the test;
- the edited region must have active retained edit viewers;
- retention fallback must be zero;
- queued render/collision work must be zero;
- pending chunk replacements and retirements must be zero.

The reinforcement does not add any presentation fallback, double-sided material,
duplicate terrain layer, or hidden backdrop. It only prevents a gate from
passing while edited terrain is still in an incomplete or degraded LOD retention
state.

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

The authoritative boundary for these claims is the core contract:
`world-transvoxel/docs/contracts/PRODUCTION_EDITED_TERRAIN_LOD_CORRECTNESS_CONTRACT.md`.

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
- exact full-resolution visibility of every player or map edit from every
  distance without an explicit exact-global-edit-visibility profile or
  editor-baked multi-LOD validation gate;
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
