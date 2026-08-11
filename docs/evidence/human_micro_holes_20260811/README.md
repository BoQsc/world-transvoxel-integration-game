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

The strongest captured geometric signal is an LOD0 chunk-face mismatch between
owner chunk `(55, 1, 57)` and neighbor `(55, 1, 58)` on the `z = 928` plane:

- exact edge match: false
- owner unique edges: 17
- neighbor unique edges: 16
- missing neighbor edge: `8820000,203569|8821428,200000`

Sky-pixel rays found both physics and render geometry at the affected wall, but
reported back-facing render triangles and no front-facing triangle. The broad
and precise topology probes both reported zero problematic probes, so those
existing probes do not cover this visible defect class.

The last recorded interaction was carve attempt 99 at
`(888.15710, 14.68991, 922.74603)` with radius `1.8`. The copied edit journal
contains 96 committed revisions and permits exact replay from the marked state.

Do not classify the root cause yet. Candidate scopes include chunk-boundary
surface ownership, triangle winding/render culling, edit remeshing, and the
authority meshing implementation. The evidence does not implicate the
Transvoxel paper or tables by itself.

## Files

- `marker.json`: complete marker diagnostics and scene/runtime state
- `marker.png`: exact human screenshot captured by the marker
- `world.wtedit`: copied edit journal for replay

## SHA-256

- `marker.json`: `486A9978A8AC0AD89B5ABCEBAA20468148FDC4698DEE526D56D3C22B2B009C7B`
- `marker.png`: `3FBE588B81841BF62824C2C5A5E9C94AA04CA94C164E3209225B841BDC74C0EF`
- `world.wtedit`: `955415E06376D2095A706B707D2AE34E47A7EE748FECEAA2BD7582C811977354`
