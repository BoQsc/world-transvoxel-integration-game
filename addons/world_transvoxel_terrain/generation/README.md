# Generation Ownership

Generation profiles, deterministic source selection, offline-generation hooks,
and flat/reference profile definitions belong here.

Hot generation execution must not be implemented in GDScript.

A2 adds `WtTerrainGenerationProfile` as metadata only; it does not generate
density or meshes.

`WtTerrainGenerationProfile` also exposes the standard material strata contract:
palette version, stable material IDs, surface material IDs, and
`deep>=8:1,mid>=3:7,shallow>=1:4` underground depth bands. The authoritative
contract is
[../../../STANDARD_MATERIAL_STRATA_CONTRACT.md](../../../STANDARD_MATERIAL_STRATA_CONTRACT.md).
