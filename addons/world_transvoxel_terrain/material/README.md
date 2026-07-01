# Material Ownership

Material IDs, texture bindings, triplanar policy, palette resources, and debug
material views belong here.

Material policy must not be hardcoded inside runtime chunk ownership.

`WtTerrainMaterialApplicator` owns the temporary debug UV2 material application
path that validation games use to visualize streamed backend meshes. This keeps
mesh-material repair logic inside the addon boundary instead of inside a game
repository.
