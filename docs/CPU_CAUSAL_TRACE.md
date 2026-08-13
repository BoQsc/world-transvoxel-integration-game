# CPU Causal Terrain Trace

CPU-B2 adds an opt-in, bounded diagnostic path to the accepted CPU baseline.
It does not alter terrain scheduling or qualify a performance improvement.

The authority extension records ordered native events for viewer plans, chunk
demand, edits, storage, sampling, meshing, publication, render/collision sink
application, replacement readiness, global visibility blockers, and staged
batch publication. Each applicable event carries chunk, LOD, generation, and
cause identity. `scripts/wt_cpu_causal_trace.gd` drains that native ring and
correlates it with player input, movement acceptance, physics-frame duration,
queue snapshots, target-chunk state, deterministic phases, and human markers.

The JSON schema is `world_transvoxel.cpu_causal_trace.v2`. Its `native` object
is authoritative for terrain pipeline order. The top-level `events` array is
the Godot-side observation stream. Both are rolling, bounded buffers and expose
retention and drop counters. A missing native API, invalid native read, or
unrecoverable source sequence gap invalidates deterministic CPU-B2 evidence;
there is no aggregate-only fallback. CPU-B2 also fails unless every edited
replacement reaches both sinks and the trace directly connects its delayed
activation to a larger relocation-wide visibility staging set.

Tracing is disabled unless `--cpu-causal-trace-output PATH` is supplied. Human
playtests can enable it through `tools/run_human_playtest.py --cpu-causal-trace`.
Tilde+M writes a marker snapshot immediately, before screenshot and terrain
probe collection. Final conclusions require same-build, same-route,
same-affinity trace-off and trace-on runs with observer overhead reported.
The qualifier retains a compact causal event slice beside its JSON report; the
full rolling trace remains a local diagnostic artifact because it is large.

## CPU-B2 retained result

The retained paired route at integration commit `dc61dff` passes CPU-B2. Four
edited replacement chunks completed storage, sampling, meshing, publication,
render sink, collision sink, and replacement readiness by `165.621 ms`. The
first blocker after that point still contained 679 chunk replacements and 2,571
chunk retirements. The visibility batch published 416 render and 120 collision
records at `10399.180 ms`, leaving `10233.587 ms` after the edited chunks had
already reached their sinks. The observed delayed edit is therefore attributed
to the conservative relocation-wide visibility staging barrier on this route.

All five traced movement rejections occurred through the production collision
readiness gate during the fast diagonal phase. Sampled rejected frames had
2,060-2,336 collision-required chunks not ready, 670-685 blocked replacements,
and 1,946-2,228 retirements. The largest movement-frame hitch was accepted, so
frame-time spikes remain separate and are not fully attributed by CPU-B2.

Tracing is materially intrusive: this pair observed 26.6% more wall time,
44.5% more process CPU time, 11.2% higher frame p99, and 57.2% higher maximum
frame time. It remains disabled by default and traced latency is not the
performance baseline. CPU-B3 must address one proven factor at a time and use
trace-off A/B measurements for performance decisions.
