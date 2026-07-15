# Standard material strata contract

Status: current Terrain 1.0 material boundary.

The broader material/biome rules live in
`MATERIAL_AND_BIOME_STANDARD.md`. This file defines the lower-level
authoritative material strata contract.

This project treats material as authoritative voxel sample data, not as a
shader-only presentation choice. Render UVs, textures, tints, screenshots, and
debug overlays are derived from the material samples.

## Current standard palette

The current standard material palette is
`world_transvoxel_material_palette_v1`.

| ID | Meaning |
| --- | --- |
| 1 | Deep stone / stable deep underground material |
| 2 | Grass surface biome material |
| 3 | Gravel surface biome material |
| 4 | Shallow surface sand / default player-placed fill material |
| 5 | Snow surface biome material |
| 7 | Mid-depth rock material |
| 8 | Deep underground ore patch material |

These IDs are intentionally documented as IDs, not just colors. Games may bind
different textures to the IDs, but the terrain authority and edit journals must
preserve the IDs.

## Current procedural depth bands

The current deterministic and flat reference generators use
`standard_density_depth_material_strata_v1`:

```text
deep>=8:1,mid>=3:7,shallow>=1:4
```

Depth means `surface_y - sample_y` for the initial procedural source. This gives
the current minimum standard:

- solid samples at least 1 block below the surface use material `4`;
- solid samples at least 3 blocks below the surface use material `7`;
- solid samples at least 8 blocks below the surface use material `1`;
- near-surface and above-surface samples may carry surface material IDs
  `2`, `3`, `4`, `5`, or `7` so the mesher can derive the visible surface palette.
- deep underground samples may carry material `8` for deterministic ore patches.

The flat baseline uses the same material rules as the mountainous profile. It is
not a separate heightmap-only material path.

## Required behavior

- `WtTerrainGenerationProfile.get_contract_summary()` must expose the material
  model, palette version, standard material IDs, surface material IDs, and depth
  bands.
- Authoritative sample queries must return the expected shallow, mid, and deep
  material IDs for the standard profiles.
- Edits mutate density and material together. A construct/place edit using
  material `4` is player fill, not a separate hidden terrain layer.
- Rendering may use texture arrays, triplanar mapping, or clean human-playtest
  materials, but rendering must not become authoritative terrain state.
- Native render payloads may expose derived surface biome blend weights for
  visual smoothing. Those weights must be deterministic derivatives of
  authoritative material IDs; they must not replace the stored material field.
- Human playtest may expose material IDs through an explicit diagnostic view,
  but raw material-ID tinting must not be the default presentation because it
  can create contour-like bands across normal terrain surfaces. Production
  material work should use distinct material textures or controlled blends.
- Material and biome presentation must be LOD-stable. Moving the camera or
  switching chunk LODs must not make visible material regions appear, disappear,
  or change shape except as a controlled texture-detail reduction.
- Do not add duplicate terrain skins, double-sided materials, or full-map
  fallback layers to hide material or topology problems.

## Current non-goals

This contract does not yet claim a complete biome system, ore veins, material
blending, erosion, collapse simulation, vegetation, water/lava, or multiplayer
replication policy. Those systems must preserve this density/material authority
instead of replacing it with a presentation-only material model.

## Gate marker

The production integration proof must print:

```text
WT_STANDARD_MATERIAL_STRATA_CONTRACT_PASS
```

for every standard profile before a Terrain 1.0 candidate can claim material
strata support.
