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
- native vertex-color surface biome blend weights derived from authoritative
  material IDs (`R=grass`, `G=gravel`, `B=sand`, `A=snow`);
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
set it to `true`, persist it with the page, and propagate it to `UV2.y` from the
same solid isosurface endpoint as `UV2.x`. A shader may evaluate the exact
declared procedural classifier only when the flag is false. When it is true,
the selected material ID is rendered directly. This preserves LOD-stable base
ore without allowing a presentation rule to override authored stone or ore.

The same rule applies to procedural roads. The road preset modifies the
authoritative density field with continuous, world-space graded corridors and
stores asphalt ID `10` only in the shallow top layer. Its matching shader
classifier first reconstructs the exact procedural underlay and then reapplies
asphalt through the continuous road field while `material_authored=false`.
This prevents a coarse material-10 vertex from turning a whole triangle into
an asphalt protrusion. Painting or constructing any material remains
authoritative and suppresses this procedural reconstruction at that surface.

## Human test expectation

The current human playtest should show at least four surface biomes:

- grass;
- sand;
- gravel;
- snow.

Digging should expose underground strata and occasional ore-colored patches.
This first standard uses deterministic placeholder textures; final visual
approval waits for real supplied biome textures.
