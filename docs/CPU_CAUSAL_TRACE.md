# CPU Causal Terrain Trace

CPU-B2 adds an opt-in, bounded diagnostic path to the accepted CPU baseline.
It does not alter terrain scheduling or qualify a performance improvement.

The authority extension records ordered native events for viewer plans, chunk
demand, edits, storage, sampling, meshing, publication, and render/collision
sink application. Each applicable event carries chunk, LOD, generation, and
cause identity. `scripts/wt_cpu_causal_trace.gd` drains that native ring and
correlates it with player input, movement acceptance, physics-frame duration,
queue snapshots, target-chunk state, deterministic phases, and human markers.

The JSON schema is `world_transvoxel.cpu_causal_trace.v2`. Its `native` object
is authoritative for terrain pipeline order. The top-level `events` array is
the Godot-side observation stream. Both are rolling, bounded buffers and expose
retention and drop counters. A missing native API, invalid native read, or
unrecoverable source sequence gap invalidates deterministic CPU-B2 evidence;
there is no aggregate-only fallback.

Tracing is disabled unless `--cpu-causal-trace-output PATH` is supplied. Human
playtests can enable it through `tools/run_human_playtest.py --cpu-causal-trace`.
Tilde+M writes a marker snapshot immediately, before screenshot and terrain
probe collection. Final conclusions require same-build, same-route,
same-affinity trace-off and trace-on runs with observer overhead reported.
