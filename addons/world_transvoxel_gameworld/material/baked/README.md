The 24 PNGs in this directory are lossless, deterministic 512-pixel source
layers for the production terrain material. Four albedo layers incorporate the
authored textures in `assets/terrain_textures/material_layers`; the remaining
layers follow `wt_game_terrain_material_applicator.gd`'s procedural formulas.

Regenerate after changing any authored layer or texture formula:

```
godot --headless --path . --script res://tools/bake_game_terrain_material_arrays.gd
```

Then run `res://tools/verify_game_terrain_material_arrays.gd` the same way.
It compares every loaded layer, including generated mipmaps, byte for byte with
the current source. Runtime decoding and texture-array creation use native
Godot image operations instead of six million GDScript `set_pixel` calls.
