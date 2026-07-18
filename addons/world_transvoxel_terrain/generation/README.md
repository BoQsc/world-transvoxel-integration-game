# Generation Ownership

Generation profiles, deterministic source selection, offline-generation hooks,
and flat/reference profile definitions belong here.

Hot generation execution must not be implemented in GDScript.

The native `rolling_hills_cave` and `rolling_hills_cave_roads` presets share a
world-distance cave field. Its surface entrance is a road-aligned descending
capsule portal joined to underground chambers with compact smooth density
operations. This prevents zero-thickness hard-CSG lips from becoming skinny
triangles at mixed LODs. Geometry changes to this field require a new source
revision; they are not compatible with stored pages or edit journals from an
older procedural revision.

A2 adds `WtTerrainGenerationProfile` as metadata only; it does not generate
density or meshes.

`WtTerrainGenerationProfile` also exposes the standard material strata contract:
palette version, stable material IDs, surface material IDs, and
`deep>=8:1,mid>=3:7,shallow>=1:4` underground depth bands. The authoritative
contract is
[../../../STANDARD_MATERIAL_STRATA_CONTRACT.md](../../../STANDARD_MATERIAL_STRATA_CONTRACT.md).

The opt-in `rolling_hills_cave_roads` preset adds
`deterministic_shallow_asphalt_corridors_v1`. Road centerlines are evaluated by
the native procedural source as continuous graded density corridors. They are
not replayed edit stamps, and the existing `rolling_hills_cave` preset remains
unchanged.

The isolated `four_biomes_lakes_caves_roads` preset is the g23 world-composition
playtest. Its native source owns four categorical surface regions without
cross-region material mixing, three material-ID `9` lake volumes, three compact
surface-connected caves, detailed rolling terrain and snow mountains, and one
connected 18-segment asphalt graph. The production shader mirrors the same
world-coordinate height, region, and road fields solely for LOD-stable visual
weights; native density and material samples remain authoritative.

Vertical volume shape is part of generation ownership. Profiles expose
`world_chunk_count_y` and `world_chunk_origin_y`; downstream runtime bridges
must forward those values to native procedural startup when available. The
standard deep proof profile uses `world_chunk_count_y=16` and
`world_chunk_origin_y=-8`, producing 256 vertical cells from `-128` through
`127` for real underground/tunnel testing.
