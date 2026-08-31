# Indexed GPU Publication Coverage

Status: `TQP64_GAMEPLAY_REJECTED_RELEASE_OPEN`.

Upstream: `d944150e444dcba83f742e3a6a803b5dc6a93e98`.
Runtime pin: `80e46b61ea719e1b3de52ffc01dff3eb1f84b76ec7d8e30ad4db40e6720927af`.
Godot 4.7.2 Steam, GTX 1060 Max-Q, affinity `[0,1,2]`, two generation
workers and zero mesh workers in live gates. CPU remains default; GPU opt-in.
No pushes or baseline-acceptance labels are part of this checkpoint.

## Change And Scope

The optional `--gpu-stage-timing` now separates native cohort selection,
coverage, member readiness, priority requests, and response construction.
It is off by default; nested stages must not be added to enclosing query time.

Authoritative coverage used all-pairs replacement overlap checks and recursive
full-list scans. It now uses the existing dyadic hierarchy index. Every
authoritative child must still be covered; overlaps, duplicate replacements,
and same-key retirement remain invalid. Unsorted input, negative coordinates,
sparse/clipped worlds, and child-coordinate overflow remain supported.
Selection, reciprocal masks, generations, atomic activation, collision
retirement, queue priorities, capacities, and movement guards are unchanged.

## Measured Improvement

`before_measurement.json` and `indexed_measurement.json` use the unchanged
runtime route with readiness, native trace, and stage timing enabled. They are
diagnostic runs, not comparable completed gameplay workloads. Their recorded
artifact mismatches are intentional development states before the final pin;
actual artifact hashes are retained. The indexed debug DLL is the final DLL;
only the release DLL and pin were finalized afterward.

| CPU Stage | Before | Indexed |
| --- | ---: | ---: |
| Coverage calls | 2,815 | 3,220 |
| Coverage total | 11,364.177 ms | 535.073 ms |
| Mean recorded coverage phase | 4.037 ms | 0.166 ms |
| Whole native query calls | 3,037 | 3,336 |
| Whole native query total | 23,849.349 ms | 12,930.397 ms |
| Mean whole query | 7.853 ms | 3.876 ms |

This is a demonstrated reduction in one CPU stage, not a CPU/GPU speedup or
smooth-gameplay claim. Selection remains costly: 10,547.051 ms in the indexed
run. Both runs still fail the first relocated edit.

Offline exact replay passes for eight retained selector snapshots. Four have
retirements requiring coverage. Debug indexed medians are 0.047-0.233 ms versus
0.189-2.007 ms for the separate all-pairs oracle; release medians are
0.043-0.218 ms versus 0.176-1.915 ms. See `replay_debug.json` and
`replay_release.json`. These are isolated CPU measurements, not frame times.

## Why The Edit Still Waits

The selected diagnostic chunk `(35,2,35), LOD0` intersects the real camera ray.
It is not the misleading miss-endpoint chunk `(35,-2,35)` reported by the
generic edit result. No physics hit was obtained, so it is not a proven hit
location. Both lossless native captures have zero dropped events.

In the indexed trace, generation 3371:

- Was demanded and promoted to collision priority.
- Loaded in 3.336 ms; the mesh job was queued at native time 23.374 s.
- Was promoted to maximum visibility-coverage priority with 110 equal-priority
  jobs ahead at 24.059 s.
- Started meshing at 25.301 s; meshing itself took 6.858 ms.
- Was replaced by transition generation 3810 at 25.319 s.
- That new generation had 427 equally promoted jobs ahead at 25.426 s and had
  not started sampling before the trace ended. No collision generation was
  published. The edit timed out after 3,025.015 ms and was never accepted.

The before trace shows the same class of transition-generation queue wait,
with 172 equal-priority jobs ahead. This is evidence of priority competition
and a superseded generation, not evidence that field generation or meshing
itself takes seconds. It does not yet prove the best corrective scheduling
policy or the precise reason for that transition-mask change.

The bounded exact excerpts are `before_chunk_trace.json` and
`indexed_chunk_trace.json`. They retain all events for the selected chunk,
readiness samples, phase markers, original source hashes, and clock origins.
The full native captures remain locally under `.godot/`; their hashes are in
the excerpts. Reproduce an excerpt with:

```text
python tools/summarize_gpu_relocation_trace.py --measurement .godot/gpu_query_stages_indexed_20260831.json --chunk 35 2 35 --output .godot/new_chunk_excerpt.json
```

## Validation

- Debug/release native publication oracle, coverage partitions, M3 application,
  GPU shadow, and production streaming pass (`native_tests.log`).
- Collision admission passes with zero and one mesh workers.
- Streaming hash remains
  `39db05c67fc2f4b8d8beaab2e7da927ae968efb3d75118bcd80c5523116d9b3b`.
- Vulkan and D3D12 production lifecycle checks pass. Timed and untimed ready
  cohort results match; disabled timing adds no timing dictionary.
- Activation retry fairness passes with no scheduling changes.
- Runtime artifact, dependency boundary, and authority-only sync checks pass.

The unchanged Vulkan moving-LOD route passes all 25 samples, with no sampled
visual, coverage, geometry-gap, or partial-GPU-geometry failures. Final drain
is 306 frames / 14,494.354 ms, reaching 1,219 fully ready chunks and zero queued
or pending publication work. This is still a long drain, not instant streaming.
Peak pending replacements/retirements are 304/718; peak scheduler queue is 253.
See `moving_lod.json`, `moving_lod_timing.json`, and `moving_lod_command.json`.

Two retained PNGs were inspected (peak sweep and low slope). They show coarse
terrain/material boundaries and the pending-geometry HUD. Dark surface bands
must not be classified as holes from screenshots alone. The pass above is from
the existing sampled geometry/coverage checks, not a visual-quality signoff.
The final aggregate native validation-rejection counter is **1**, despite zero
rejected controller chunks and zero failed extractions. This capture does not
retain its per-request reason; it is unclassified, not silently counted as zero
or assumed harmless. Preserve that question for per-request investigation.

The exact-pinned, diagnostics-off runtime gate still **fails**:

| Measurement | Result |
| --- | ---: |
| Blocked movement steps | 544 / 1,020 |
| Longest consecutive block | 105 steps |
| Render post-draw interval p95 / p99 | 75.175 / 102.769 ms |
| Physics-signal interval p95 / p99 | 60.501 / 78.283 ms |
| First edit target wait | 180 frames / 2,978.168 ms |
| Edit accepted | No |
| Application wait expirations / native validation rejections | 0 / 0 |

`gameplay_diagnostics_off.json` records the matching artifact, disabled probes,
and unchanged gates. Physics-signal timing is not rendered FPS. The missing
target censors edit commit/visual/collision latency; this is not a successful
three-second edit. Compared with the previous checkpoint, blocked-step count
is unchanged, the longest block is shorter, and rendered p99 is worse. No
overall gameplay improvement is qualified by this incomplete route.
None of these tests grants human acceptance.

## Next

Isolate the destination transition-generation change and broad coverage
promotion competing with player-critical collision work. Reproduce the ordering
in a focused test before changing it. Also reduce repeated selector work only
with exact-cohort equivalence. Do not weaken publication/collision safety, add
workers, or extend target waits to produce a pass. GPU completion still requires
an unchanged successful movement/edit route, post-edit terrain/water validation,
cross-backend gameplay, performance/power qualification, and human acceptance.
