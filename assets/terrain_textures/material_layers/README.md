# Material layer texture slots

Drop human-supplied terrain albedo textures here.

Bundled reference textures are tracked in
[`THIRD_PARTY_TEXTURES.md`](THIRD_PARTY_TEXTURES.md).

## Standard material IDs

These are real terrain material IDs, not debug colors. If a texture is missing,
the production shader uses a subdued placeholder color so the layer remains
visible and testable.

| Material ID | Slot name | Current role | Placeholder appearance |
| --- | --- | --- | --- |
| 1 | `stone_albedo` or `deep_stone_albedo` | deep underground stone | dark gray |
| 2 | `grass_albedo` | grass surface biome | muted green |
| 3 | `gravel_albedo` | gravel surface/strata material | gray |
| 4 | `sand_albedo` | sand surface, shallow underground, and player fill | light brown |
| 5 | `snow_albedo` | snow surface biome | off-white |
| 7 | `rock_albedo` or `mid_rock_albedo` | mid-depth rock | medium gray |
| 8 | `ore_albedo` or `ore_patch_albedo` | ore patch proof material | brown/orange |

Surface biome IDs `2`, `3`, `4`, and `5` are rendered through a world-space
smooth biome blend in production material mode. That is intentional: a hard
per-vertex surface material ID can move when terrain LOD changes, so visible
surface biome borders must be derived from stable world coordinates instead of
from one endpoint chosen by the mesh extractor.

Underground IDs `1`, `7`, and `8` remain direct material layers. The concentric
bands seen while digging are therefore material strata being exposed by the cut,
not a debug overlay. If they look too diagnostic, replace the placeholders with
authored textures here. If the same hard rings remain visually wrong after real
textures, the material classifier/strata policy needs adjustment rather than
hiding the colors.

## Current expected files

- `grass_albedo.png` / `.jpg` / `.jpeg` / `.webp`
- `sand_albedo.png` / `.jpg` / `.jpeg` / `.webp`
- `gravel_albedo.png` / `.jpg` / `.jpeg` / `.webp`
- `snow_albedo.png` / `.jpg` / `.jpeg` / `.webp`
- optional: `stone_albedo`, `rock_albedo`, `ore_albedo`

Missing layers use deterministic subdued placeholders.
