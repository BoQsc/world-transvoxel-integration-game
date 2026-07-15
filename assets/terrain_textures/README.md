# Terrain textures

Normal production terrain uses authored texture-array layers when files are
available, otherwise it falls back to subdued deterministic placeholders.

Preferred location:

```text
assets/terrain_textures/material_layers/
```

Preferred albedo names:

- `grass_albedo`
- `sand_albedo`
- `gravel_albedo`
- `snow_albedo`
- `stone_albedo` or `deep_stone_albedo`
- `rock_albedo` or `mid_rock_albedo`
- `ore_albedo` or `ore_patch_albedo`

Supported extensions are `.png`, `.jpg`, `.jpeg`, and `.webp`.

The existing `coast_sand_01_diff_1k.jpg` is accepted as the sand layer until a
standard `material_layers/sand_albedo.*` file is supplied.

Albedo-only textures are acceptable for this stage. Normal/roughness authored
slots are intentionally deferred until the albedo biome/material behavior is
stable.
