# CPU Causal Terrain Trace

CPU-B2 adds an opt-in, bounded diagnostic path to the accepted CPU baseline.
It does not alter terrain scheduling or qualify a performance improvement.

The authority extension records ordered native events for viewer plans, chunk
demand, edits, storage, sampling, meshing, publication, render/collision sink
application, explicit transition-mask meshing, replacement readiness, global
visibility blockers, and staged batch publication. Each applicable event
carries chunk, LOD, generation, and cause identity. Transition events use the
immutable mask in the page-meshing record, not the mutable current LOD plan.
`scripts/wt_cpu_causal_trace.gd` drains that native ring and correlates it with
player input, movement acceptance, physics-frame duration, queue snapshots,
target-chunk state, deterministic phases, and human markers.

The JSON schema is `world_transvoxel.cpu_causal_trace.v2`. Its `native` object
is authoritative for terrain pipeline order. The top-level `events` array is
the Godot-side observation stream. Both are rolling, bounded buffers and expose
retention and drop counters. A missing native API, invalid native read, or
unrecoverable source sequence gap invalidates deterministic CPU-B2 evidence;
there is no aggregate-only fallback. CPU-B2 also fails unless every edited
replacement reaches both sinks and the trace directly connects its delayed
activation to a larger relocation-wide visibility staging set. The v3 CPU-B2
qualification also requires explicit transition start, successful finish, and
completion-consumption events with exact chunk, LOD, generation, and mask
pairing; aggregate transition counters cannot satisfy this gate.

Tracing is disabled unless `--cpu-causal-trace-output PATH` is supplied. Human
playtests can enable it through `tools/run_human_playtest.py --cpu-causal-trace`.
Tilde+M writes a marker snapshot immediately, before screenshot and terrain
probe collection. Final conclusions require same-build, same-route,
same-affinity trace-off and trace-on runs with observer overhead reported.
The qualifier retains a compact causal event slice beside its JSON report; the
full rolling trace remains a local diagnostic artifact because it is large.

## CPU-B2 retained result

The retained paired route at integration commit `5c07dc6` and authority commit
`f7a583d` passes CPU-B2. It captured 296 explicit transition starts, 296
successful finishes, and 296 consumed completions across 24 nonzero masks,
with zero unmatched identities, invalid masks, trace-consumer gaps, or local
drops. This directly proves that transition-mask work traversed the measured
CPU route; it does not claim that event presence alone proves geometric
correctness.

Four
edited replacement chunks completed storage, sampling, meshing, publication,
render sink, collision sink, and replacement readiness by `250.586 ms`. The
first blocker after that point still contained 757 chunk replacements and 2,402
chunk retirements. The visibility batch published 415 render and 112 collision
records at `13182.573 ms`, leaving `12932.004 ms` after the edited chunks had
already reached their sinks. The observed delayed edit is therefore attributed
to the conservative relocation-wide visibility staging barrier on this route.

All 15 traced movement rejections occurred through the production collision
readiness gate during relocation backlog. Three rejected-frame snapshots
retained the required not-ready collision and blocked-replacement state. The
largest movement-frame hitch was `45.647 ms` and was accepted, so frame-time
spikes remain separate and are not fully attributed by CPU-B2.

Tracing is materially intrusive: this pair observed 26.0% more wall time and
21.0% more process CPU time. Frame p95, p99, and maximum were lower in the
traced half, demonstrating why this single pair cannot estimate universal
frame-time overhead. Tracing remains disabled by default, and traced latency is
not the performance baseline. Both halves remained measured target misses.
CPU-B3 must address one proven factor at a time and use trace-off A/B
measurements for performance decisions.

## CPU-B3 retained result

CPU-B3 authority commit `a8bba83` retains exact cross-LOD edit-region
publication and batches matching-generation coverage priority requests. Godot
4.7.1 debug and release atomicity tests observed zero mixed render/collision
ownership frames and the expected eight-replacement/one-retirement swap. The
production streaming and LOD hashes remain unchanged.

Three trace-off runs improved median relocation-to-exact-visibility readiness
from CPU-B1's `13206.199 ms` to `3822.632 ms`. This remains a measured target
miss. Median blocked frames were `11`, median maximum consecutive blocked frames
were `3`, and median frame p99 was `25.397 ms`.

One later experiment allowed ordinary viewer LOD swaps to use the same regional
release path. It was rejected and reverted. It reduced edit post-sink wait to
`5.807 ms`, but emitted 65 regional publications and 1,181 priority requests in
one trace. Its three trace-off runs regressed median readiness to `5101.907 ms`,
blocked frames to `236`, and maximum consecutive blocked frames to `63`.

The retained evidence is under
`docs/evidence/cpu_b3_regional_publication_20260813/`. CPU-B3 is not complete:
human regression review and an independent CPU exhaustion decision remain.
TQP-58 is still blocked, and no GPU architecture is selected.

The exact retained package subsequently received human regression status
`ACCEPTED_WITH_KNOWN_LIMITATIONS`. Extended flight, relocation, landing, and
post-relocation digging did not reveal a new rejection-level correctness
failure. The review did retain three release-blocking observations: a temporary
see-through LOD slice that corrected after several seconds, residual flight
responsiveness problems, and a smaller but noticeable first-edit delay after a
long relocation. This completes the human-review step only. It does not qualify
seamless temporal presentation, the CPU performance target, production release,
CPU exhaustion, or GPU eligibility.

## CPU-B3 independent exhaustion review

`tools/cpu_b3_exhaustion_review.py` independently verifies the tagged human
candidate, exact authority and package pins, retained source-report digests,
automated target misses, causal boundaries, rejected experiment, and human
release blockers. It changes no terrain implementation.

The retained review is complete with decision
`NOT_EXHAUSTED_ADDITIONAL_CPU_ATTRIBUTION_AND_REMEDIATION_REQUIRED`. This is not
an unfinished review and not a GPU selection. CPU exhaustion fails because the
temporary LOD opening lacks causal capture, flight frame-time variance remains
only partially attributed, the retained edit path still waits `1988.3341 ms`
after its sinks for a 267-replacement/31-retirement component, and the run does
not prove CPU saturation while averaging 1.451 active cores with large queues.

The fail-closed order is CPU-B3A temporary-opening capture, CPU-B3B flight
attribution, CPU-B3C exact component-ownership audit, CPU-B3D at most one newly
trace-proven standard remedy with full regressions, then CPU-B3E repeat
exhaustion review. CPU-B3 remains in progress and TQP-58 remains blocked.
