# Material Ownership

Material IDs, texture bindings, triplanar policy, palette resources, and debug
material views belong here.

The addon-facing material ID meanings and current procedural depth bands are
defined in
[../../../STANDARD_MATERIAL_STRATA_CONTRACT.md](../../../STANDARD_MATERIAL_STRATA_CONTRACT.md).
Shaders may present those IDs differently, but they do not redefine terrain
authority.

Material policy must not be hardcoded inside runtime chunk ownership.

`WtTerrainMaterialApplicator` owns the temporary debug UV2 material application
path that validation games use to visualize streamed backend meshes. This keeps
mesh-material repair logic inside the addon boundary instead of inside a game
repository.

## Godot terrain culling policy

The default streamed terrain material uses `cull_back`.

This is intentional. Normal human play and terrain-correctness gates must render
the native Transvoxel mesh as single-sided terrain so missing faces, bad winding,
near-zero slivers, LOD cracks, and streaming gaps remain visible during testing.
Do not add duplicate backstop geometry or double-sided terrain rendering to hide
native mesh defects.

`cull_disabled` is allowed only as a diagnostic or game-specific presentation
experiment after the same scene passes the single-sided visual/topology gates. It
is not the default human playtest or production validation material.

## Production terrain texture mapping policy

Production terrain textures must use world-space triplanar projection on native
Transvoxel terrain.

Do not use `XZ`-only UV mapping for production terrain. It smears or stretches
textures on steep dug walls, tunnel corners, and vertical excavation surfaces.
The human artifact marker `20260715T012849_001_human` in the integration game
captured this failure mode: local topology probes were open-gap-free, while the
visible issue was a melted vertical texture streak on a dug surface.

Material V1 must preserve this distinction:

- flat color / material-ID views isolate geometry and brush defects;
- textured production views validate mapping, mipmaps, texture-array sampling, and
  triplanar behavior;
- if an artifact is visible only in textured mode, treat it first as material
  mapping until geometry probes prove otherwise.

Human artifact analysis must keep material classes separate. When a marked point
is open-gap-free but still looks melted or streaked, inspect the same pose in
flat color, material-tint, and textured triplanar modes before changing
meshing. A texture-only artifact is not evidence of nonmanifold terrain.

## Human material modes

Normal human playtest uses the textured production/triplanar material path by
default. Raw material-ID tinting is intentionally not the default because it can
turn normal surface strata into contour-like visual bands across the whole
terrain.

Use `material_tint` only as a diagnostic material-ID view. It is expected to
look less natural, but should make material mistakes obvious. Future production
material work should bind distinct material textures or controlled blends rather
than globally tinting one sand texture across every surface.

The current production placeholder texture array has deterministic layers for
stone, grass, gravel, sand, snow, rock, ore, and asphalt. These layers are intentionally
simple test textures. They prove the material/biome pipeline and should be
replaced by real authored textures without changing the authoritative material
IDs.

Production material blending is carried by four native custom vertex channels
generated from authoritative material IDs and provenance:

- `CUSTOM0.rgba` = generated stone, grass, gravel, sand;
- `CUSTOM1.rgba` = generated snow, mid rock, ore, asphalt;
- `CUSTOM2.rgba` = authored stone, grass, gravel, sand;
- `CUSTOM3.rgba` = authored snow, mid rock, ore, asphalt.

Each channel is `RGBA8_UNORM`. A mesh vertex sets one component to one and the
GPU interpolates the explicit weights across the triangle. This removes the
provoking-vertex behavior of a flat categorical material ID while adding only
16 bytes per vertex. `COLOR` and `UV2` remain compatibility channels for
external consumers, but the production terrain shader does not use them to
choose a triangle-wide material. These render channels are derived data, not
second terrain authorities.

Legacy pages that predate this channel are treated conservatively as authored.
This keeps their categorical material visible instead of guessing that an old
compacted edit was procedural. Rebake the base and replay edits into schema 1.2
to recover source/edit provenance and the LOD-stable procedural presentation.

Every visible terrain triangle has some material ID, including the outdoor
surface. "Underground material" is therefore not a separate hidden terrain; it
is the same material field becoming visible after digging. Surface biomes and
underground strata may use different classifiers, but they must feed one
coherent material presentation path.

The production shader consumes explicit vertex-derived material weights. Four
`RGBA8_UNORM` custom channels cover all eight solid palette entries: `CUSTOM0`
and `CUSTOM1` contain generated weights, while `CUSTOM2` and `CUSTOM3` contain
authored weights. The channels preserve the material/provenance selected from
the solid endpoint of each isosurface edge and interpolate it across the
triangle. No flat material varying or provoking vertex chooses the appearance
of a whole triangle.

Generated and authored coverage are evaluated separately. Painting stone
suppresses procedural ore, placing ore remains ore, and authored construction
is composited after every generated classifier. For a known deterministic
base-source model, generated coverage may use the same world-space classifier
as the source to derive continuous presentation. This is restricted to an
exact declared model; arbitrary generators are never reclassified by this
shader.

For declared rolling-hills cave sources, the shader reconstructs the exact
source height and smoothly limits generated surface-biome coverage by distance
from that exterior and by surface orientation. This prevents snow, sand,
gravel, or grass from spilling into exposed cave walls and ceilings, including
triangles whose vertices all originated in the shallow source band. Authored
materials bypass this generated-surface rule. The boundary is therefore
continuous in world space instead of exposing mesh triangulation.

Underground ore uses that restricted path for
`deterministic_deep_ore_patches_v1`. The stored IDs remain authoritative for
queries and gameplay, while the matching continuous world-space function
presents their boundary independently of mesh LOD. This prevents sparse ore
from turning into per-triangle islands when coarse sampling changes. A future
general multi-material volume may store richer indices plus weights, but must
preserve the same generated/authored ownership rule.

The road profile uses the same restricted presentation path for
`deterministic_shallow_asphalt_corridors_v1`. The native source owns road
density and material ID `10`; the shader evaluates the identical world-space
centerlines, grades, and base-surface classifier. For generated terrain it
reapplies the continuous asphalt corridor only over reconstructed exterior
coverage, which keeps shoulders stable across LODs and prevents a road underlay
inside the cave. The shader is never the road authority, and the independent
authored weight group prevents it from painting over terrain edits.
