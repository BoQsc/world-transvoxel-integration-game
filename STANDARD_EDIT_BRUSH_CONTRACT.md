# Standard edit brush contract

Status: current Terrain 1.0 standard boundary.

This project already uses a sphere as the default terrain edit brush. The
purpose of this contract is to make that behavior explicit and stable before
adding optional gameplay systems.

## Current standard

The standard player-facing edit brush is an SDF sphere.

- Left mouse submits `carve`.
- Right mouse submits `construct` / place.
- The game-world API path is `submit_sphere_edit(...)`.
- The edit operation records:
  - operation mode;
  - brush shape;
  - center;
  - radius;
  - material id;
  - density value / strength;
  - author id;
  - command id;
  - conservative affected AABB.
- The bridge exposes submitted operation dictionaries in
  `operation_summaries` on the last edit submission summary.

The default human playtest radius is currently `1.8`.

## Required behavior

Sphere edits must be deterministic. Given the same world state and the same
ordered edit sequence, authoritative density/material samples must match after:

- chunk reload;
- viewer movement;
- LOD movement;
- restart/reopen;
- compaction/rebake gates.

The default edit brush must not rely on visual mesh triangles. Authoritative
behavior is defined by voxel/SDF samples and edit journal order.

## Runtime responsiveness rule

Player edits are foreground gameplay operations. They must not silently
disappear behind terrain streaming, collision generation, sample queries,
snapshot work, or LOD replacement work.

The standard runtime must satisfy these rules before claiming production-ready
interactive terrain:

- a click must either submit an edit or record a concrete rejection reason;
- physics collision raycasts may be used as the first targeting path, but
  collision-only targeting is not sufficient because collision can lag behind
  visible terrain after fast viewer movement;
- when collision misses but visible terrain exists under the cursor, the runtime
  must provide a bounded fallback target path or an explicit unavailable reason;
- accepted edits must receive higher priority than background sample/snapshot
  operations;
- accepted edits must start the edit apply burst immediately, not only after the
  commit signal;
- UI or marker diagnostics must expose the last target source, acceptance state,
  and failure reason.

GPU acceleration may improve throughput later, but it is not allowed to be the
only answer to lost edit submissions. Queue priority, fallback targeting, and
explicit failure reporting are CPU/runtime correctness requirements.

## Non-goals for this milestone

This contract does not implement collapse, shaft stability, debris simulation,
octahedron mining, vegetation, water, or building blocks.

Those systems may depend on edit metadata later, but they are not part of the
current standard terrain milestone.

## Future compatibility rule

Future collapse or stability systems must operate on voxel/SDF support data,
not rendered mesh triangles and not a specific player brush shape.

The standard edit metadata is intentionally enough for later systems to know
what operation was submitted and what region may need analysis, without making
collapse or octahedron mining part of the current implementation.
