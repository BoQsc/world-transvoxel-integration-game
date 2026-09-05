# Verified worker configuration and bounded activation retries

Status: INCOMPLETE_NOT_QUALIFIED. Native remains `674ecc3`; the runtime artifact
is unchanged. GPU remains opt-in. No hardware-limit conclusion is supported.

## Measurement correction

`run_runtime_readiness_probe.py` passed `--meshing-workers 0` and
`--procedural-generation-workers 2` unconditionally. These arguments overrode
launcher changes, including the earlier reports labelled as one mesh worker or
one procedural worker. The complete reports' `mesh_worker_count` confirms zero.
Earlier worker-benefit attribution was invalid; the original reports remain
available and their summaries now explicitly identify the actual configuration.

The runner now defaults to the launcher policy (GPU one mesh worker, CPU zero),
accepts an explicit override, records requested and observed worker counts, and
rejects a mismatch. The two verified runs below both observed one mesh worker.

## Change and focused evidence

Activation retries previously allowed only one cohort query per frame, even
when queries were inexpensive. They now permit up to four queries, with a
750-microsecond deadline checked before beginning another query. The first
query can exceed that deadline; it is not preempted. The existing sixteen-entry
inspection limit, collision priority, normal-lane fairness, generation checks,
atomic cohort commit, collision guards and GPU capture capacity are preserved.

A deterministic clock in the existing test subclass proves that a query costing
more than the budget stops the pass, half-budget queries stop after two, and
cheap queries can advance four. Existing fairness, stale cleanup, preparation,
regional commit and activation acknowledgement assertions remain enabled.
Disabling the deadline in a temporary negative control triggers the new failure;
restoring it passes. Rapid cross-chunk edits pass on Vulkan (76 checked frames)
and D3D12 (62), with zero mixed revisions. Production lifecycle/material checks
pass on both. Automatic LOD activation without edits passes at 23/13/15 frames
on Vulkan and 23/11/12 on D3D12 across the initial view and two relocations.

The cold coarse-edit fixture now records first observed stages once, without
dumping inventories. Before this queue change it measured about 100 ms on
Vulkan and 116 ms on D3D12, with 1–3 ms of mesh preparation. The changed policy
measured 116 ms on both. This isolated edit does not benefit from a larger retry
budget. Godot's asynchronous counter readback itself has a queued-frame delay:
[RenderingDevice documentation](https://docs.godotengine.org/en/4.6/classes/class_renderingdevice.html#class-renderingdevice-method-buffer-get-data-async).

A separate native experiment investigated collision repair's global idle guard.
The completed GPU-only chunk was already remeshed immediately on collision
promotion while unrelated work remained queued. The proposed repair change was
therefore unnecessary for that case and was not made. The temporary fixture
was removed, then the original native LOD suite was rebuilt and passed.

## Diagnostics-off gameplay observations

Same 1,020-step route, three CPUs, two procedural workers, unchanged thresholds.
These are single observations, not a statistically established speedup.

| Configuration | Mesh workers | First visual after commit | Exact LOD0 | Collision after commit | Target wait | Blocked steps | Physics p95 / p99 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Budgeted retries, old runner override | 0 | 11 | 79 | 5 | 31 | 47 | 37.482 / 56.465 |
| Original one-query limit, corrected runner | 1 | 13 | 80 | 4 | 31 | 44 | 38.990 / 51.463 |
| Budgeted retries, corrected runner | 1 | 10 | 89 | 7 | 0 | 7 | 38.603 / 56.855 |

The final run passes the existing movement and edit-latency thresholds but
fails both frame-time thresholds. Seven blocked steps and 89-frame exact detail
are not instant or nonhalting terrain. The queue change does not solve isolated
edit latency or prove sustained long-session performance. Compressed complete
reports, exact pin, summary and experiment patch are retained beside this file.
