# Human Micro-Hole Marker Evidence

This evidence was captured with `Tilde+M` during human inspection of the
tagged correctness baseline:

- integration commit: `1a00c3233e87b63661b5a6c52185e7465e21937f`
- authority package: `841fd094c55858e3f4a4731666e1e5a39015cb21`
- profile: `g23_four_biomes_lakes_mountains_roads_2k_256_on_demand`
- marker: `20260811T190653_001_human`

The screenshot shows isolated sky-colored micro-pixels on an edited cave wall.
The marker recorded 24 isolated sky pixels, including 20 in its terrain band.
The camera was at `(883.87457, 20.57763, 928.19537)` and the player was in
walking mode.

The original capture appeared to report an LOD0 chunk-face mismatch between
owner chunk `(55, 1, 57)` and neighbor `(55, 1, 58)` on the `z = 928` plane:

- exact edge match: false
- owner unique edges: 17
- neighbor unique edges: 16
- missing neighbor edge: `8820000,203569|8821428,200000`

That result was a diagnostic false positive. The old check clipped triangles to
a four-cell window and compared only the first 32 sampled edge records. A full
shared-face comparison finds 30 unique edges on each chunk, exact 30/30 edge
agreement, one incident boundary edge per chunk, and opposite edge orientation
across every pair.

The original `front_like` and `back_like` labels were also reversed for Godot.
Godot renders clockwise triangles as front-facing, and the authority render
sink deliberately converts its indices to that winding. All six settled
sky-pixel rays hit Godot-front-facing render triangles at the same distance as
their physics hits.

The last recorded interaction was carve attempt 99 at
`(888.15710, 14.68991, 922.74603)` with radius `1.8`. The copied edit journal
contains 96 committed revisions and permits exact replay from the marked state.

## Resolution

The authority mesher and `WtRenderPayload` conversion reproduce the final edit
state without a missing edge or an exposed reverse-facing first hit. The visual
pixels came from projecting adjacent chunk meshes through separate model-view
transforms. Algebraically identical boundary positions could round to slightly
different clip-space positions, exposing isolated background pixels when the
camera viewed almost along the chunk plane.

The production terrain shader now reconstructs world position first and writes
clip-space `POSITION` from that shared world position. The exact 96-transaction
live replay settles at world revision 96 with:

- complete shared-face comparison: 30/30 exact
- settled isolated sky pixels: 0 (previously 6 in the deterministic replay)
- authoritative camera density: positive (camera is in air)
- native raw-mesh first-hit reversals: 0/6
- native render-payload first-hit reversals: 0/6

This was a downstream chunk-projection defect. It does not implicate the
Transvoxel paper, lookup tables, or final authority mesh generation.

## Files

- `marker.json`: complete marker diagnostics and scene/runtime state
- `marker.png`: exact human screenshot captured by the marker
- `world.wtedit`: copied edit journal for replay
- `live_edit_replay.json`: deterministic 96-transaction replay fixture

The replay is gated by `tools/test_human_micro_hole_live_replay.py`. It limits
Godot to three logical CPUs and requires both a complete settled seam match and
zero settled isolated sky pixels.

## SHA-256

- `marker.json`: `486A9978A8AC0AD89B5ABCEBAA20468148FDC4698DEE526D56D3C22B2B009C7B`
- `marker.png`: `3FBE588B81841BF62824C2C5A5E9C94AA04CA94C164E3209225B841BDC74C0EF`
- `world.wtedit`: `955415E06376D2095A706B707D2AE34E47A7EE748FECEAA2BD7582C811977354`
