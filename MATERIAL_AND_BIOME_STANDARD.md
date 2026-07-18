# Material and biome standard

Status: active Terrain 1.0 material/biome direction.

## Boundary

Transvoxel owns smooth voxel geometry and mixed-LOD seam stitching. It does not
define biome classification, material blending, texture projection, ore
placement, or gameplay mining rules. Those systems are project terrain-world
systems layered on top of the authoritative density/material volume.

## Authoritative material palette

The current standard palette is `world_transvoxel_material_palette_v1`.

| ID | Meaning | Primary use |
| --- | --- | --- |
| 1 | deep stone | stable deep underground |
| 2 | grass | surface biome |
| 3 | gravel | surface biome |
| 4 | sand / player fill | surface biome and default place material |
| 5 | snow | surface biome |
| 7 | mid rock | mid-depth strata and exposed rocky terrain |
| 8 | ore patch | deep underground material patch |
| 10 | asphalt | shallow solid road surface |

Material IDs are gameplay/storage state. They are persisted in terrain pages,
edit journals, and authoritative sample queries. Shaders may derive visual
presentation from them, but the shader is not the material authority.

## Current procedural classifier

The deterministic reference world uses:

- `standard_density_depth_material_strata_v1` for vertical strata;
- `deterministic_macro_surface_biomes_v1` for large surface biome regions;
- `deterministic_deep_ore_patches_v1` for underground ore patches.
- `deterministic_shallow_asphalt_corridors_v1` for the opt-in road profile.

Depth bands remain:

```text
deep>=8:1,mid>=3:7,shallow>=1:4
```

Ore patches are allowed only below the stable deep threshold so the existing
shallow/mid/deep terrain contract remains predictable.

## Rendering standard

Normal play must not render raw material IDs as tint bands. Raw material tint
is diagnostic only.

The production placeholder material path uses:

- world-space triplanar projection;
- a deterministic `Texture2DArray` material layer set with slots for stone,
  grass, gravel, sand, snow, rock, ore, and asphalt;
- mipmaps on generated placeholder material textures;
- four native `RGBA8_UNORM` custom vertex channels containing explicit weights
  for all eight solid materials, split into generated and authored ownership;
- continuous generated exterior-surface coverage derived from the exact
  declared source surface and surface orientation, so categorical source IDs
  cannot spill into cave walls, ceilings, or excavations;
- one native material override path, not duplicate skins or hidden fallback
  terrain.

Real biome textures must replace texture-array layers without changing the
authoritative material IDs. `Texture2DArray` is the default Godot material
binding because each layer keeps its own mipmap chain and avoids atlas padding
or manual atlas slicing artifacts. Surface biome blending uses stable native
mesh weights derived from the same material IDs; it is not a duplicate terrain
skin or a shader-only fake. If future authored textures need richer blends,
extend the authoritative material-weight/mask data explicitly rather than
hiding material discontinuities in a presentation-only pass.

## LOD rule

Material/biome rendering must be LOD-stable. A chunk changing from LOD0 to a
coarser LOD may lose texture detail, but it must not visibly invent, erase, or
move biome/material regions. Any future material blending or biome masks must
be generated from stable world-space rules and must be downsampled
deterministically.

Raw per-vertex material IDs are not acceptable as the final visible
presentation for sparse underground patches such as ore. The authoritative
volume may store ore as material ID `8`, but the production material must
derive a stable world-space/blended ore presentation so coarse LOD meshes do
not expose blocky per-triangle ore islands at cave entrances. This is a render
presentation rule only: material ID `8` remains the stored/gameplay authority.

That derivation must be provenance-aware. Base-source samples carry
`material_authored=false`; paint, construct, fill, and material-volume edits
set it to `true` and persist it with the page. The render sink converts the
material and provenance selected from the same solid isosurface endpoint into
separate generated and authored weight groups. A shader may evaluate the exact
declared procedural classifier only over generated coverage. Authored weights
are composited last and render the selected materials directly. This preserves
LOD-stable base ore without allowing a presentation rule to override authored
stone, ore, asphalt, or surface material.

The same rule applies to procedural roads. The road preset modifies the
authoritative density field with continuous, world-space graded corridors and
stores asphalt ID `10` only in the shallow top layer. Its matching shader
classifier reconstructs the exact source surface and reapplies asphalt through
the continuous road field only over generated exterior coverage. This prevents
a coarse material-10 vertex from turning a whole triangle into an asphalt
protrusion or painting a road under a cave ceiling. Painting or constructing
any material remains authoritative and bypasses this procedural presentation.

Generated surface, procedural ore, procedural road, and authored material are
one composed shader decision. Adding one presentation classifier must not
replace the other base-material rules. The integration quality proof enforces
the `generated_authored_eight_weight_layers_v1` payload before launching
Godot. Declared rolling-hills sources reconstruct their exact surface height
and smoothly retire generated surface coverage away from the exterior. The
orientation term rejects ceilings and strongly inward-facing surfaces. Neither
rule mutates or replaces stored material IDs, and authored material bypasses
all generated classifiers.

## Human test expectation

The current human playtest should show at least four surface biomes:

- grass;
- sand;
- gravel;
- snow.

Digging should expose underground strata and occasional ore-colored patches.
This first standard uses deterministic placeholder textures; final visual
approval waits for real supplied biome textures.
