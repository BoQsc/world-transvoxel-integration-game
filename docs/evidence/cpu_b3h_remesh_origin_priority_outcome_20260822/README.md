# CPU-B3H Remesh Origin And Priority Outcome

This qualification runs one bounded autonomous route against authority commit
`0b9249ce0911932cf2c4553fabe8f4d93529556e`. The runtime adds disabled-by-default
causal events for transition-remesh generation creation, readiness-repair
generation creation, and every visibility-coverage priority outcome.

## Result

- The trace is complete. It covers two long flights, a relocated carve, and a
  second relocated construction on at most three logical CPUs.
- Both eventual LOD0 edit targets were fully render- and collision-ready 736.8
  and 867.8 ms before edit submission. Destination readiness was not the delay.
- Both edits committed in 4.2 to 6.5 ms, but their atomic visibility cohorts
  published after 4,091.9 and 3,696.0 ms.
- Each exact terminal publication controller was an unrelated LOD1 replacement
  created by viewer demand about 30 ms after edit submission.
- The route emitted 332 transition-remesh generation events and no
  readiness-repair generation events. Neither terminal controller was a
  transition remesh or readiness repair.
- Both terminal controllers received a coverage-priority request. Scheduler
  reprioritization succeeded, while the page runtime reported that it did not
  own the exact generation (`SCHEDULER_APPLIED_PAGE_RECORD_NOT_FOUND`).
- The dominant retained interval was dependency-ready to mesh-start: 2,667.2
  ms for the carve controller and 2,348.6 ms for the construction controller.
  Their measured sample, storage, and mesh work totaled only 14.7 and 11.3 ms.
- Once each terminal member became visibility-ready, atomic publication
  followed within 89.6 and 92.4 ms.

## Decision

The new instrumentation rules out transition-remesh and readiness-repair churn
as the direct cause in this route. It confirms that delayed first edits remain
coupled to unrelated viewer-demand members in the atomic visibility cohort. The
terminal generations reach scheduler reprioritization, but no page-runtime
record exists to receive the same priority, and most retained delay occurs
after dependencies are ready but before meshing starts.

Do not weaken atomic publication, alter priority policy, or select GPU
architecture from this trace. The next narrow diagnostic should retain the
exact scheduler queue insertion, effective priority, queue position or
ahead-of-work count, and scheduler-to-page meshing ownership handoff for these
terminal generations. That will distinguish expected bounded queue pressure
from a lost-priority or ownership-transfer defect before any behavior change.

## Performance Boundary

The process averaged 1.35 active logical cores across a three-core capacity and
was at capacity in 4.7% of samples. The trace also retained a 7.2-second frame
and a 65.3 ms frame-time p99. These values support further CPU ordering and
queue investigation, but trace-on timing is intrusive and is not a release
performance baseline.

The raw trace and generated report remain under
`.godot/world_transvoxel_captures/terrain_waterfall/remesh_origin_probe_*` and
are intentionally not versioned.

## Claim Boundary

The terminal controller is the exact cohort member with the final retained
visibility-readiness event before publication. Origin and priority outcome are
explicit authority events for the exact generation. The trace proves retained
causal ordering; it does not prove why the page runtime did not own the
generation or how much untraced release performance will improve after that is
resolved.
