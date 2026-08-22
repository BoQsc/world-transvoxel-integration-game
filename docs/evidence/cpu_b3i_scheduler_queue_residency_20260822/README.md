# CPU-B3I Scheduler Queue Residency

This qualification runs one bounded autonomous route against authority commit
`d1c6d9ea4011a27734d1887a530e8b345abeacc4`. The runtime adds disabled-by-default
scheduler events for exact job admission, effective priority, dequeue, queue
position, and page meshing ownership.

## Result

- The trace is complete. It covers two long flights, a relocated carve, and a
  second relocated construction on at most three logical CPUs.
- Both exact terminal publication controllers have complete scheduler paths.
  They are unrelated LOD1 viewer-demand generations, consistent with CPU-B3H.
- Priority is not lost. Both sample jobs were observed at interactive maximum
  priority (`2147483647`), and both mesh jobs inherited that same priority at
  admission and dequeue.
- The earlier `SCHEDULER_APPLIED_PAGE_RECORD_NOT_FOUND` result is an expected
  ownership boundary in these paths: the queued sample job accepted the
  priority before its page meshing ownership was established at dequeue.
- The carve controller spent 936.6 ms in the sample queue and 3,404.5 ms in the
  mesh queue. At mesh admission it had 294 jobs ahead, all at the same maximum
  priority.
- The construction controller spent 956.1 ms in the sample queue and 2,595.0
  ms in the mesh queue. At mesh admission it had 263 jobs ahead, all at the
  same maximum priority.
- Mesh queue residency was the dominant retained interval in both edit paths.
  Measured sample, storage, and mesh work totaled only 22.0 and 20.5 ms.
- Once each terminal member became visibility-ready, atomic publication
  followed within 89.8 and 95.7 ms.

## Decision

The delayed first edits in this route are not explained by lost scheduler
priority, missing page ownership, expensive generation work, or sustained CPU
capacity exhaustion. Broad visibility coverage promoted a large cohort to the
same maximum priority, leaving the exact edit-blocking mesh jobs behind 294 and
263 equal-priority jobs. The priority mechanism therefore works mechanically
but does not provide useful ordering inside the promoted cohort.

Do not weaken atomic publication or select GPU architecture from this trace.
The next standard CPU remediation candidate is a narrowly bounded ordering rule
inside the already-promoted visibility cohort, preserving correctness and the
three-logical-CPU limit. It should be implemented only as an isolated candidate
and accepted only if repeated trace-off and causal comparisons improve first
edit latency without regressions in movement, visibility, collision, or total
work.

## Performance Boundary

The process averaged 1.45 active logical cores across a three-core capacity and
was at capacity in 6.4% of samples. The report classified the result as
`CPU_PATH_NOT_EXHAUSTED_STANDARD_REMEDIATION_REMAINS`. Trace-on timing is
intrusive and is not a release performance baseline.

The raw trace and generated report remain under
`.godot/world_transvoxel_captures/terrain_waterfall/scheduler_queue_probe_*` and
are intentionally not versioned.

## Claim Boundary

Exact scheduler admission, priority observation, dequeue, queue position, and
page ownership are proven for the two terminal generations in this bounded
route. One trace does not prove that the same queue shape occurs on every route,
nor does it prove the best corrective ordering policy or its release-mode
performance effect.
