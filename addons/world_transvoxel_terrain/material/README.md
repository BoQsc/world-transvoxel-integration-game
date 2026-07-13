# Material Ownership

Material IDs, texture bindings, triplanar policy, palette resources, and debug
material views belong here.

Material policy must not be hardcoded inside runtime chunk ownership.

`WtTerrainMaterialApplicator` owns the temporary debug UV2 material application
path that validation games use to visualize streamed backend meshes. This keeps
mesh-material repair logic inside the addon boundary instead of inside a game
repository.

## Godot terrain culling policy

The default streamed terrain material must use `cull_disabled`.

This is a Godot presentation rule, not a native topology workaround. The native
backend is still validated by mesh/topology tests, while Godot rendering must
not expose protected LOD seam or near-coplanar interior slivers as sky-colored
single-pixel holes during movement, digging, or LOD replacement. Do not add
duplicate backstop geometry to hide this; the current standard is one native
mesh plus a terrain material that renders both sides.

`cull_back` is allowed only as a diagnostic or future performance experiment
after an equivalent no-sky-gap visual gate passes. It is not the default human
playtest or production validation material.
