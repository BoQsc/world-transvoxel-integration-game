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
stone, grass, gravel, sand, snow, rock, and ore. These layers are intentionally
simple test textures. They prove the material/biome pipeline and should be
replaced by real authored textures without changing the authoritative material
IDs.

Surface biome blending is carried by native vertex colors generated from
authoritative material IDs:

- red = grass;
- green = gravel;
- blue = sand;
- alpha = snow.

`UV2.x` remains the primary material ID. Vertex-color blending is therefore a
derived render channel, not a second terrain authority.

Every visible terrain triangle has some material ID, including the outdoor
surface. "Underground material" is therefore not a separate hidden terrain; it
is the same material field becoming visible after digging. Surface biomes and
underground strata may use different classifiers, but they must feed one
coherent material presentation path.

The production shader consumes those authoritative vertex-derived IDs and
weights directly. It must not reclassify the material from world position;
doing so would make paint and construction metadata disagree with what the
player sees. Coarser meshes may reduce texture detail, but material ownership
continues to come from the solid endpoint of each isosurface edge.

Underground ore follows the same rule. The procedural source stores ore as
authoritative material ID `8`, and the shader renders ID `8` as ore. Smooth
multi-material falloff is a later data-model feature (for example, stored
indices plus weights); it must not be simulated by replacing categorical
authority in the shader.
