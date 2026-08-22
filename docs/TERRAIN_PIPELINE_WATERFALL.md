# Terrain Pipeline Waterfall

The terrain pipeline waterfall is an optional human-session observer built on
the authoritative native CPU causal trace. Its purpose is to show what happens,
and in what order, while walking, flying, relocating, digging, and constructing.
It does not change terrain scheduling, queue budgets, visibility publication,
collision readiness, or edit behavior.

## Launch and controls

Run `Launch Terrain Waterfall Playtest.cmd` from the repository root. The
launcher uses the current trusted g23 human profile, limits the Godot process to
three logical CPUs, enables the live HUD, samples process CPU and memory every
250 ms, and writes an analyzed report after Godot closes.

`Launch Terrain Waterfall Autonomous.cmd` runs a deterministic observer route
through the same player movement gate: ascent, a long flight, relocated carve,
a second long flight, and relocated construction. It is useful for repeatable
ordering evidence. The interactive route remains necessary for human feel and
input-latency review.

Inside any normal human playtest, `Tilde+W` starts or stops an ad hoc waterfall
capture. When stopped, the native trace is finalized, the HUD becomes inert,
and terrain execution returns to the normal unobserved path. Starting it again
creates a numbered capture rather than overwriting the first one.

The standard `Launch Latest Human Playtest.cmd` remains trace-off. It pays no
native trace, polling, HUD processing, or process-sampling cost.

## Live HUD

The HUD samples the retained trace four times per second and shows:

- physics-frame time, observer cost, movement mode, and movement acceptance;
- viewer, scheduler, storage, page, render, collision, and visibility queues;
- the bound edit target's visual and collision readiness;
- the current evidence-based blocker classification;
- the latest ordered native lifecycle events with thread role and chunk key.

The HUD does not scan the full retained event ring. It asks the existing trace
for bounded tail slices, so visual observation cost remains explicit and is
included in the trace's observer summary.

## Retained outputs

The default output directory is:

`res://.godot/world_transvoxel_captures/terrain_waterfall/`

The launcher writes:

- `latest_human_trace.json`: full bounded downstream and native causal streams;
- `latest_human_usage.json`: process CPU, memory, thread count, and affinity;
- `latest_human_report.json`: machine-readable frame, edit, and stage analysis;
- `latest_human_report.txt`: concise human-readable findings and decision state.

For each edit, the report preserves authority, demand, storage, sampling,
meshing, transition meshing, publication, render sink, collision sink, and
visibility intervals. It reports relocation distance, preceding flight,
target-readiness latency, the dominant wait, and any retained staging blocker.
Wall-clock-aligned usage samples report CPU load and saturation for each edit's
exact request-to-publication window rather than relying only on session averages.
Worst movement frames are correlated with native events and sampled queue state.

## Required human route

A useful CPU-exhaustion capture must include all of the following in one or more
lossless traces:

1. Fly at least 128 world units through newly streamed terrain.
2. Land and dig in the relocated area.
3. Fly to another area and construct there.
4. Continue moving long enough to include normal flight and any observed stall.
5. Close Godot normally so the final trace and report are written.

Use `Tilde+M` during an anomaly when a visual artifact also needs the existing
marker, screenshot, and terrain-probe package. Images support the trace; they do
not replace event order as evidence.

## Decision boundary

The report can establish native lifecycle order, sampled movement rejection,
queue pressure, edit-stage waits, and process CPU use within the three-logical-
CPU envelope. It cannot establish release performance because tracing itself is
intrusive, and it cannot measure GPU watts or select a GPU architecture.

If a delay occurs without sustained CPU saturation, standard CPU ordering,
readiness, or publication remediation remains open. If a fully covered route is
lossless, remains delayed, and saturates the bounded CPU envelope, the result
may make a GPU review eligible, but a same-route trace-off comparison and one
stage-specific standard-remedy audit are still required before selection.
