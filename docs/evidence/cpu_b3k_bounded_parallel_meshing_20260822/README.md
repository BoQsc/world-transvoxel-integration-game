# CPU-B3K Bounded Parallel Meshing

This qualification compares the accepted serial meshing path with opt-in one-
and two-worker paths from authority commit `5a2ed886`. All three runs used the
same deterministic relocation, carve, relocation, and construction route while
the process was restricted to three logical CPUs.

## Correctness Result

- All traces were complete and covered the required human route.
- Flight movement was accepted on every flight frame.
- Both edit destinations were fully render- and collision-ready before each
  edit was submitted.
- Carve and construction retained exact atomic publication membership.
- Authority tests proved byte-identical terrain and water output between the
  serial path and the two-worker path, paired worker start/finish events, and
  stale completion rejection after active cancellation.

The worker implementation is therefore retained as an opt-in diagnostic path.
It is not promoted to the production default.

## Performance Result

| Workers | Frame p99 | Carve | Construct | Average cores | Saturated |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 65.078 ms | 3761.663 ms | 3086.091 ms | 1.181 | 0.033 |
| 1 | 65.026 ms | 4618.665 ms | 4893.115 ms | 1.684 | 0.176 |
| 2 | 41.732 ms | 4577.526 ms | 4323.693 ms | 1.933 | 0.440 |

Two workers improved traced frame p99, but carve latency increased by 21.7%
and construction latency increased by 40.1% relative to serial. The edit
windows saturated the allowed CPU envelope for 76.5% and 94.1% of their
samples. One worker was also slower than serial.

The serial trace's terminal publication members waited in the authoritative
scheduler. With asynchronous workers, the carve terminal instead spent
2540.234 ms between mesh dequeue and worker start. The implementation admitted
terrain work into the worker queue faster than the workers could complete it,
moving the same backlog behind the scheduler's reprioritization boundary.
During the two-worker construction window, storage queueing became the terminal
2335.458 ms segment, showing contention inside the three-CPU envelope.

## Decision

Reject one- and two-worker meshing as production defaults. Keep
`meshing_worker_count = 0` as the accepted configuration and retain worker mode
only as an explicit experiment.

GPU architecture is review-eligible but remains unselected. Before that
decision, perform one narrow CPU audit: bound asynchronous mesh admission close
to actual worker capacity so interactive priority cannot be hidden in a large
second queue. The candidate must beat serial relocated-edit latency without
breaking exact publication, cancellation, frame pacing, or the three-CPU
limit. If it does not, stop CPU scheduling experiments and use this record for
the GPU architecture decision.

## Claim Boundary

Trace-on timing is intrusive and is valid for causal ordering and relative
candidate rejection, not as a release frame-rate baseline. The large raw traces
were intentionally not committed; `qualification.json` retains their hashes,
sizes, route results, and decision. Trace-off acceptance remains required for
any candidate that survives the causal audit.
