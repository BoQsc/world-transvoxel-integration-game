# Material Ownership

Material IDs, texture bindings, triplanar policy, palette resources, and debug
material views belong here.

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
