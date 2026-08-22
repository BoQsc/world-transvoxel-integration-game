# CPU-B3J Queue Composition Reconciliation

This qualification re-analyzes the complete CPU-B3I trace with analyzer commit
`9976c7c`. The analyzer reconstructs the exact scheduler queue at each terminal
mesh admission and correlates every job ahead with the final atomic publication
region.

## Result

- The carve terminal had 294 maximum-priority jobs ahead: 293 mesh jobs and one
  sample job. All 294 belonged to the same 428-replacement publication region.
- The construction terminal had 263 maximum-priority jobs ahead, all mesh jobs.
  All 263 belonged to the same 440-replacement publication region.
- Both reconstructions exactly match the queue's retained `jobs_ahead` and
  `same_priority_jobs_ahead` counts.
- Therefore the queue is not primarily blocked by older unrelated promoted
  cohorts. It is processing hundreds of meshes required by the same atomic
  publication.
- Changing FIFO order inside either equal-priority region cannot reduce the
  total work required before that region may publish. It would only cause a
  different required member to become the terminal controller.

## Authority Reconciliation

At authority commit `d1c6d9e`, `process_scheduler_jobs()` calls
`execute_mesh_job()` synchronously on the single runtime control thread. The
bounded loop dispatches at most four scheduler jobs per control iteration, but
mesh generation itself is serial. This explains why a region with hundreds of
ready mesh jobs can retain seconds of mesh queue residence while process-wide
use averages less than the allowed three logical CPUs.

The authority history contains two earlier parallel-meshing experiments:
`50d6670` and `f0d88fe`. Neither is part of accepted `main`. The first was held
after poor human frame pacing and later contained behind an opt-in default; the
second was built on a separate lineage and was not accepted. They are design
references, not code to restore wholesale.

## Decision

Reject `BOUNDED_EQUAL_PRIORITY_VISIBILITY_COHORT_ORDERING` before implementation.
It is structurally incapable of shortening these atomic publication paths.

The next CPU milestone is a fresh, opt-in bounded parallel-meshing candidate on
the current authority. It must preserve current exact-mask, edited terrain,
static water, cancellation, regional publication, and causal-trace behavior.
It must default to the accepted serial executor until deterministic equality,
stale-generation rejection, queue bounds, three-logical-CPU performance, and
human frame pacing all pass.

GPU architecture remains unselected. The current trace demonstrates unused CPU
capacity and a standard CPU parallelism opportunity that has not yet passed its
modern acceptance gates.

## Claim Boundary

Exact queue composition is proven for the two terminal generations in the
CPU-B3I route. The trace proves that equal-priority reordering is not a remedy
for those two atomic regions. It does not yet prove the throughput, frame pacing,
or correctness of a new parallel-meshing implementation.
