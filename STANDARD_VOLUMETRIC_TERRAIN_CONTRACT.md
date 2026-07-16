# Standard volumetric terrain contract

Status: current Terrain 1.0 standard boundary.

This project uses Transvoxel for smooth voxel terrain LOD. The authoritative
terrain is a signed density/material volume. It is not a heightmap mesh, and it
is not a surface-only cache.

## Research basis

The official Transvoxel description defines the algorithm as seamless stitching
between triangle meshes generated from voxel data at different resolutions. It
also states that voxel terrain removes the topographical limitations of
elevation terrain and can represent caves, overhangs, and arches:

- https://transvoxel.org/
- https://transvoxel.org/Lengyel-VoxelTerrain.pdf
- https://github.com/EricLengyel/Transvoxel

Lengyel's dissertation distinguishes height fields from voxel maps: height
fields are elevation over a two-dimensional grid, while voxel terrain is a
scalar function over a three-dimensional grid where the zero set is the terrain
surface. That is the standard this repository follows.

## Standard model

The terrain source of truth is:

- a bounded 3D grid of density samples;
- material samples associated with the same volume;
- chunk/page keys that include X, Y, Z, and LOD;
- derived render and collision meshes generated from those samples.

The surface is the zero crossing of the density field. Render meshes, collision
meshes, transition meshes, screenshots, and debug probes are derived data. They
must never become the authoritative terrain state.

## Current implementation boundary

The current standard profiles expose:

- `WtTerrainProfile.horizontal_cells`;
- `WtTerrainProfile.vertical_cells`;
- `WtTerrainProfile.vertical_origin_cell`;
- `WtTerrainProfile.plus_y_is_up`;
- `WtTerrainProfile.finite_closed_boundary`;
- `WtTerrainGenerationProfile.world_chunk_count_y`;
- `WtTerrainGenerationProfile.world_chunk_origin_y`;
- `WtTerrainGenerationProfile.supports_underground_volume`;
- `WtTerrainGenerationProfile.underground_model`;
- `WtTerrainGenerationProfile.material_strata_model`;
- `WtTerrainGenerationProfile.underground_depth_bands`.

The current deterministic and flat generation sources are allowed to derive the
initial surface from a simple height function, but they must still produce a
full signed volume:

- density is positive above the surface and negative below it;
- underground samples are real solid samples, not a visual cap;
- edits mutate authoritative density/material samples;
- LOD, render, collision, save/reload, and revisit behavior must be derived
  from the edited samples.

The current standard material IDs and underground depth bands are defined in
[STANDARD_MATERIAL_STRATA_CONTRACT.md](STANDARD_MATERIAL_STRATA_CONTRACT.md).
That document controls material meanings such as shallow surface fill,
mid-depth rock, and deep stone. Shaders and textures may present those IDs
differently, but they do not redefine the authoritative material samples.

This means flat terrain is still volumetric terrain. It is the default baseline
because it is the simplest way to prove edits, collision, reload, and LOD
behavior without hiding problems behind procedural mountains.

## Non-negotiable rules

- Do not add a heightmap-only terrain path.
- Do not store only a surface mesh and treat it as editable terrain.
- Do not hide terrain correctness problems with presentation fallbacks.
- Do not make caves, overhangs, or tunnels depend on debug-only capping.
- Do not make LOD replacement restore or reshape edited authoritative samples.
- Do not treat current procedural generation as the full terrain standard; it is
  only one source for initial density/material samples.

## Deeper underground

The current public profiles are finite reference volumes. Deeper underground is
a profile/runtime expansion, not a different terrain type.

The current deep standard proof profile is `g20_deep_2k_256_on_demand`:

- horizontal coverage: `2048 x 2048` cells;
- vertical coverage: `256` cells;
- vertical origin: `-128` cells (`world_chunk_origin_y=-8`);
- native procedural chunk coverage: `128 x 16 x 128` LOD0 chunks;
- native procedural/catalog page ceiling: `524288` pages;
- proven page count for this profile: about `299520` procedural pages across
  LOD0 through LOD3;
- current role: standard deeper-underground proof and stress profile, not the
  default player terrain style.

The rolling-hills cave inspection profile is
`g21_rolling_hills_cave_2k_256_on_demand`:

- horizontal coverage: `2048 x 2048` cells;
- vertical coverage: `256` cells;
- vertical origin: `-128` cells (`world_chunk_origin_y=-8`);
- native procedural preset: `rolling_hills_cave`;
- terrain role: map-shape inspection profile with gentler rolling terrain and
  a real density-volume cave/chamber;
- current proof boundary: autonomous sample checks verify material strata,
  cave air, surrounding cave solid, and normal rolling-hill solid; the full
  post-edit Terrain 1.0 production gameplay proof is not yet passed for this
  profile because post-edit streaming settle can remain pending.

Before claiming a deeper world, the implementation must prove:

- increased vertical page/chunk coverage;
- downward and diagonal tunnel edits inside the expanded volume;
- close/mid/far/return LOD behavior after underground edits;
- save/reload/revisit persistence of underground edits;
- material queries at multiple depths;
- no visible sky leaks or rectangular unloaded patches after initial readiness.

## Explicit non-goals for the current standard

These are valid future systems, but not part of the current Terrain 1.0
volumetric standard:

- general/production natural cave generation beyond the bounded g21 inspection
  preset;
- ore veins;
- collapse/stability simulation;
- octahedron-specific mining;
- water/lava simulation;
- vegetation;
- block buildings;
- planet-scale coordinate systems.

They must be added later on top of the same density/material volume contract.

## Required gate behavior

Autonomous terrain qualification must fail if a standard profile loses the
volumetric contract fields. At minimum, it must verify:

- positive horizontal and vertical terrain dimensions;
- correct vertical origin and expanded vertical-cell reporting for deep
  profiles;
- plus-Y-up semantics;
- finite closed boundary semantics for the current bounded reference world;
- `supports_underground_volume == true`;
- a named underground model and depth/material contract;
- the standard material palette and shallow/mid/deep depth-band material IDs;
- unchanged edit persistence and LOD gates.

Human playtesting is useful for noticing visual failures, but human acceptance
does not replace these contract checks.
