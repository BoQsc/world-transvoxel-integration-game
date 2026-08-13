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
