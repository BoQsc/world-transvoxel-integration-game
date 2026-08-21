# Authoritative Bottom Boundary

Status: candidate pending human validation

The G23 production playtest remains a `2048 x 256 x 2048` volumetric world
covering Y `-128` through `128`. It now uses one 16-cell native bedrock band at
the bottom. The protected boundary top is Y `-112`.

This is not a visual cap, collision-only plane, synthetic fallback, or extra
terrain implementation. `world-transvoxel` owns the density and material
samples. Material ID `7` identifies bedrock, and all edit replay paths clip
carve, construction, paint, and restore operations at protected samples.

## Policy

- `OPEN`: no bottom boundary and zero thickness.
- `SEALED`: non-carvable native solid boundary retaining procedural material.
- `BEDROCK`: non-carvable native solid boundary using material ID `7`.

Policy and thickness are part of procedural geometry identity, snapshot
serialization, configuration hashing, and source-revision compatibility. A
terrain addon requesting a non-open policy fails startup when the native
authority lacks the boundary API. There is no fallback.

## Qualification

Native tests cover procedural sampling, direct and page edit clipping,
authoritative query, compacted snapshot reopen, and migrated snapshot reopen.
The terrain-addon Godot 4.7 contract test covers profile metadata, exact native
argument dispatch, invalid configuration rejection, and fail-closed behavior
against a legacy backend.

Exact authority and terrain-contract commits, addon trees, package hashes, and
runtime DLL hashes are recorded in `BOTTOM_BOUNDARY_PIN.json`.
