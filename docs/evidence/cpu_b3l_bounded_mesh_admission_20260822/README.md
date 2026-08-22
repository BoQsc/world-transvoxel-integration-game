# CPU-B3L Bounded Mesh Admission

This qualification applies an admission bound to the opt-in two-worker path
from CPU-B3K. At most two prepared meshes may wait behind the two active
workers; additional meshes remain in the authoritative scheduler where
cancellation and reprioritization still apply.

## Correctness Result

- The complete causal trace retained 123,952 native events with no local drops.
- The worker waiting queue never exceeded two jobs.
- Maximum active worker count was exactly two.
- All 5,246 mesh start/finish events were attributed to the meshing role.
- Flight had no blocked frames, both destinations were fully ready before edit
  submission, and publication membership remained exact.
- The scheduler, page meshing, streaming, lifecycle, LOD, and causal-trace
  debug/release gates retained their locked hashes.

## Performance Result

The bound removed the hidden worker backlog but did not qualify the two-worker
path. Against the CPU-B3K serial trace:

| Metric | Serial | Bounded two-worker |
| --- | ---: | ---: |
| Frame p99 | 65.078 ms | 65.182 ms |
| Carve | 3761.663 ms | 3695.697 ms |
| Construct | 3086.091 ms | 5275.971 ms |
| Average active cores | 1.181 | 1.226 |
| Saturated sample fraction | 0.033 | 0.004 |

Carve returned to approximately serial latency, but construction regressed by
70.9% and frame p99 lost the earlier unbounded worker improvement. This
candidate is rejected.

## Head-Of-Line Finding

The construction terminal member's mesh entered the scheduler with 313
equal-priority jobs ahead. Exact reconstruction identified 152 mesh jobs and
161 sample jobs, all in the same atomic publication region. Its sample phase
spent 1791.762 ms between priority observation and dequeue, followed by
1931.350 ms in the mesh scheduler queue.

The worker bound exposed a standard mixed-executor head-of-line problem. When
the mesh waiting queue is full, the runtime control thread stops at the first
mesh even though later sample jobs could run on that thread and prepare storage
and mesh dependencies. This is not evidence for splitting atomic publication
or weakening priority. It is evidence for work-conserving dispatch by stage
under separate executor capacity.

## Decision

Reject admission bounding alone as a production configuration. Keep serial
meshing as the default. Perform one final CPU candidate: when mesh admission is
full, dequeue the highest-priority sample job while leaving meshes in scheduler
order. The candidate must remain bounded, preserve exact queue trace data, and
beat serial edit latency without harming frame p99. If it fails, end CPU
scheduler experiments and proceed to the GPU architecture decision using
CPU-B3K through CPU-B3L as the baseline.

## Claim Boundary

Trace-on timing is intrusive and supports causal attribution and relative
candidate rejection, not release performance acceptance. Raw traces are not
committed; `qualification.json` retains their identities and the decisive
measurements.
