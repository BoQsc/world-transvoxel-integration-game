# CPU-B3G Publication Blocker Critical Path

This qualification reanalyzes the three complete CPU-B3F traces. It follows
the exact member whose `visibility_replacement_ready` event occurred last in
each published regional cohort. No new runtime capture or scheduling change was
needed.

## Result

- All six terminal-controller paths are complete and belong to the exact
  latest-drained-plan publication cohort.
- Every terminal controller is a non-edit replacement. Four are LOD1 chunks
  and two are LOD2 chunks.
- Five controllers spent 2,182.2 to 5,055.2 ms waiting after dependencies were
  ready before meshing began.
- The remaining controller spent 2,652.2 ms between its coverage-priority
  request and pipeline start.
- Measured sample, storage, and mesh work totaled only 7.3 to 54.0 ms per
  terminal controller. Work duration is therefore not the dominant retained
  interval.
- After the terminal member became ready, regional publication followed within
  34.6 to 107.4 ms.
- Four controller generations entered through `ExpectChunk` without a retained
  `chunk_demand_accepted` event or priority-applied event. Authority inspection
  shows that transition-remesh and readiness-repair paths can create such
  generations, but the current trace does not distinguish those paths.
- Two controller generations came from viewer demand 27.6 and 43.1 ms after
  edit submission and retain successful priority application.
- Downstream first-blocker sampling included one member of a preceding cohort
  in every edit. The native terminal-controller result avoids that sampling
  ambiguity.

## Decision

The delayed first edit is not waiting for its destination chunk. It is coupled
to a broad atomic visibility cohort whose final unrelated member waits in the
scheduler before meshing; that member's own measured work is not the dominant
interval. Aggregate cohort work can still create the queue pressure. This is a
CPU scheduling/publication architecture issue that still has standard
remediation paths; it is not evidence for selecting GPU architecture.

Do not split atomic publication, change queue priority, or weaken seam coverage
yet. The next authority diagnostic should emit an explicit generation-origin
event for transition remesh and readiness repair, and an outcome event for
every coverage-priority application path. One bounded route can then determine
whether repair/remesh churn or same-priority cohort breadth creates the queue.

The reanalyzed reports remain under
`.godot/world_transvoxel_captures/terrain_waterfall/relocation_blocker_path_repeat_*`
and are intentionally not versioned.

## Claim Boundary

The terminal controller is the exact cohort member with the last retained
visibility-readiness event before publication. This proves the retained
readiness critical path, not which authority subsystem created an
`ExpectChunk` generation when no demand-origin event exists. Trace-on frame
timing remains diagnostic rather than a release-performance baseline.
