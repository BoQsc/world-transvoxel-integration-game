# Queued GPU Collision Promotion

Status: `TQP64_GAMEPLAY_REJECTED_RELEASE_OPEN`.

Upstream runtime: `236045f80a2388d691c35a08fc614fef87c3d7d0`.
Runtime artifact SHA-256:
`d96d92d8e951016631ae955132c6da6a72832480d54c0fa8a145814243752089`.
Godot 4.7.2 Steam, GTX 1060 Max-Q, affinity `[0,1,2]`.
CPU remains default; GPU remains opt-in. This is not an accepted GPU baseline.

## Retained Change

Upstream `3616e5c` fixes redundant work during role promotion. A mesh job that
is still waiting in `AwaitingMesh` has not captured its visual/collision roles.
It now retains its generation and consumes the updated roles when dequeued.
Executing and completed visual-only generations still require a successor.
An owner that cannot prove the job is still waiting keeps the conservative
remesh behavior. Publication no longer creates a second successor when one is
already being prepared for the collision role.

The focused real runtime regression runs with zero and one mesh workers. It
requires one mesh job, no redundant remesh, and both render and nonempty CPU
collision payloads for the original generation. It does not assert that the
payloads have already become visible or usable by the physics server.

Upstream `236045f` adds collision-required/ready state to the GPU readiness
query. This is visibility into authoritative state, not a scheduling change.
Integration consumes only the pinned DLLs and references, with no native source
copy or fallback. Its GPU controller and fairness test are unchanged from
`fbfdab7` after the trial below was withdrawn.

## Rejected Scheduling Trial

An uncommitted controller trial gave collision-required prepared groups up to
three activation retries before a normal FIFO turn, still at one retry per
frame. It passed its isolated bounded-fairness test but did not establish an
end-to-end benefit. It was removed, not shipped. The original FIFO controller
was restored exactly and its regression rerun.

| Diagnostics-Off Route | Blocked Steps | Longest Block | Post-Draw p95 / p99 | Edit Accepted |
| --- | ---: | ---: | ---: | --- |
| Prior indexed checkpoint | 544 / 1,020 | 105 | 75.175 / 102.769 ms | No |
| Rejected priority trial | 567 / 1,020 | 161 | 78.203 / 108.124 ms | No |
| Retained promotion fix, original FIFO | 504 / 1,020 | 132 | 86.713 / 120.033 ms | No |

These are single incomplete routes with differing realized movement, not
repeated performance samples or a qualified speedup. The retained fix removes
proven redundant work; it has not fixed gameplay. Its first physics target was
still missing after 180 frames / 2,999.088 ms. No edit was accepted, so commit,
visual, and collision edit latency remain censored, not successful three-second
edits. Physics-signal intervals must not be reported as rendered frame time.

`gameplay_diagnostics_off.json` retains the final GPU measurement.
`rejected_priority_diagnostics_off.json` retains the withdrawn trial.
Both match the same native runtime artifact. That digest identifies the native
package, not the differing uncommitted controller used by the rejected trial.

The CPU/default control is `cpu_diagnostics_off.json`. It completes the route
and accepts the edit, with 32 blocked steps and a longest block of 11. It still
fails the existing displacement, movement-block, first-target, visual-ready,
and collision-ready latency targets. This does not establish CPU perfection,
GPU performance parity, or a hardware limit. Neither route gets human approval
from these automated checks.

## Remaining Wait

`promotion_chunk_trace.json` and `rejected_priority_chunk_trace.json` preserve
bounded exact native events for ray-crossed chunk `(35,2,35), LOD0`, relevant
readiness samples, frontend phase markers, source hashes, and clock origins.
There was no physics hit; this is a selected ray-crossed candidate, not a proven
hit location. The generic miss endpoint `(35,-2,35)` is not the surface chunk.
Full lossless traces stay locally in `.godot/`; the excerpts retain their hashes.

In the retained promotion-fix trace, generation 2977 meshes in 6.821 ms and
queues both render and collision payloads at native time 24.473 seconds.
The placeholder reaches the render sink at 24.481 seconds, but the sampled
chunk still waits for visible GPU activation and usable collision. Producing
payloads does not mean their publication dependency has completed.

In the rejected-priority trace, generation 3163 finishes storage in 3.281 ms
at native time 23.808 seconds. Its mesh job is queued at 24.327 seconds with
141 equal-priority jobs ahead and has no mesh-start event before capture ends.
The final activation backlog is 440 groups. The collision-priority retry queue
drains to one entry, but the target still does not become available. Retrying a
chosen seed sooner is not enough when its required members have not finished.

Source inspection shows that `wt_build_gpu_chunk_publication_cohort` expands
through reciprocal boundary dependencies and retained-coverage replacements.
Missing or incompatible active geometry extends the required set. The native
query raises missing members to a shared coverage priority, so a critical
member can still wait behind many equally prioritized jobs. This identifies
the observed queue and publication dependency; it does not prove a safe way to
remove those dependencies or a permanent deadlock.

A CPU visual bridge was considered but not implemented. Collision-required
GPU chunks already generate CPU topology, but using it as visible geometry
would require additional publication and replacement semantics. It has not
been shown to eliminate the same LOD-region dependency. No fallback, bypass,
extra worker, larger queue, weaker collision guard, or longer timeout is added.

## Validation And Limits

Focused native results, engine lifecycle logs, and package checks are retained
alongside this note. Debug/release application, publication-policy and coverage,
GPU shadow, production streaming, and queued-promotion tests pass. The streaming
fingerprint remains `39db05c67fc2f4b8d8beaab2e7da927ae968efb3d75118bcd80c5523116d9b3b`.
Vulkan/D3D12 lifecycle, original FIFO fairness, runtime artifact, dependency
boundary, and authority-only sync checks pass. See `native_tests.json` and
`integration_checks.json` for the commands and complete outputs.

The M5 workload executable's functional assertions pass,
but the existing wrapper expects hash
`b758a78f2da5582081a579ea74de5bec0d33901a334001a395f3a462dbf27d44`
and observes
`9a0be4aec3838643ec6159076b6b942334b4cfd6238a65366859e0b5cc9cf828`.
The wrapper is not green. Its expectation is not rewritten as part of this
checkpoint. The synthetic fixture uses a null meshing owner, for which this
change preserves the prior conservative remesh decision.

No new moving-LOD visual sweep, post-edit water qualification, complete GPU
edit result, power result, or human acceptance is claimed here. Earlier sampled
LOD evidence is historical, including its unresolved native rejection, not a
new certification of this pin.

## Next

Stay in TQP-64. Resolve the destination generation-to-activation dependency
using the retained trace and focused reproductions, without another unproven
priority shuffle. A successful unchanged movement/edit route is still the
immediate gate. Then rerun post-edit terrain/water and moving-LOD checks,
Vulkan/D3D12 gameplay, performance/power comparison, and human acceptance.
Reconcile the M5 fingerprint separately before claiming the complete authority
suite passes. Do not label this checkpoint as final or accepted GPU terrain.
