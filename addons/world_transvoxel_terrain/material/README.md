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

Do not use `XZ`-only atlas mapping for production terrain. It smears or stretches
textures on steep dug walls, tunnel corners, and vertical excavation surfaces.
The human artifact marker `20260715T012849_001_human` in the integration game
captured this failure mode: local topology probes were open-gap-free, while the
visible issue was a melted vertical texture streak on a dug surface.

Material V1 must preserve this distinction:

- flat color / material-ID views isolate geometry and brush defects;
- textured production views validate mapping, mipmaps, atlas sampling, and
  triplanar behavior;
- if an artifact is visible only in textured mode, treat it first as material
  mapping until geometry probes prove otherwise.

Human artifact analysis must keep material classes separate. When a marked point
is open-gap-free but still looks melted or streaked, inspect the same pose in
flat color, material-tint, and textured triplanar modes before changing
meshing. A texture-only artifact is not evidence of nonmanifold terrain.
