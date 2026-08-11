# Authority 789aea6 Replacement Qualification

Status: **REJECTED**

Date: 2026-08-11

This qualification tested an isolated integration-game worktree with only
`addons/world_transvoxel` replaced by authority commit
`789aea6e83a793552e260d187f90b2dd44395401`. The production terrain package,
game-world addon, scenes, scripts, profiles, and current real integration-game
checkout remained unchanged.

## Decision

Do not update the integration-game authority pin from
`4f1fdb59e3c6200c8f823b99027b2d3f15563858` to `789aea6`.

The candidate passes the cold edit-during-load correctness oracle, including
authoritative density/material persistence and local watertightness. It does not
pass the existing multi-site edited-terrain LOD gate under the required
three-logical-CPU limit.

## Thin Unchanged Surface Classification

The reported thin unchanged terrain over a newly dug hole is the previous
render generation kept visible while a staged replacement is incomplete. This
continuity policy prevents a skybox hole. It is not a second density field, a
duplicate texture layer, a Transvoxel lookup-table defect, or evidence that the
terrain package changed the integration game's source terrain.

The visual result is still unacceptable when it lasts long enough to be seen.
The defect is replacement latency caused by the CPU streaming, edit-retention,
page-loading, meshing, and publication path.

## Results

| Gate | Result | Relevant evidence |
| --- | --- | --- |
| Godot 4.7.1 import | PASS | Candidate loaded with no terrain-package or game-world changes. |
| g23 edit-during-load oracle | PASS | 64 operations, 8 committed batches, zero density/material persistence mismatches, zero local watertightness defects. |
| g19 multi-site edited-terrain LOD gate | FAIL | Existing gate stopped after site A edit 15 with a staged replacement lacking render/collision readiness. |
| Extended diagnostic run | FAIL | Site B retained two edit regions, grew to 1,593 active records, and still had 8 blocked replacements after a 30-second real-time floor. |
| Current real integration pin | PRESERVED | No addon files or pin records changed. |

The extended diagnostic was instrumentation in the disposable worktree only; it
is not a replacement acceptance gate. It exposed the failure mechanism:

- edit-retention zones increased from one to two;
- active records increased from 963 to 1,593;
- eight replacement chunks remained blocked;
- scheduler/storage work was still active at the deadline;
- the candidate had no mesh or page failures;
- pending priority publications showed that replacement payload delivery was
  progressing rather than silently losing authoritative terrain data.

## Boundary

This result does not justify hiding the old mesh early, clearing terrain, adding
a fallback mesh, reducing correctness requirements, or changing Transvoxel
tables. Those responses would conceal the latency or introduce visible holes.

The next authority work must establish a bounded edited-region residency policy
and a foreground replacement-latency gate. It must prove that a player can move
to a distant resident site and dig without waiting seconds for visual and
collision replacement, while persistence and LOD correctness remain intact.

Raw machine evidence and the structured decision are retained under
`docs/evidence/authority_789aea6/`.
