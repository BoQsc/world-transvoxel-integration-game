# TQP-64 GPU Publication Lifecycle

Status: `FOCUSED_LIFECYCLE_FIXES_GPU_GAMEPLAY_REJECTED`.

Authority: `18a892f02344481c73698c6a131da00e429a3fa4`.
Runtime artifact: `77bc4262b5e8615dcf4a04936d4a326aa3ee0f2c0d158cd51d33cfdd1399d63f`.
Normal-profile debug/release DLLs are built upstream. The integration remains a
binary consumer; no native implementation or fallback was copied here.

## Correctness Changes

1. Native lifecycle ownership distinguishes a pending frontend application record
   from an obsolete GPU generation. Removed generations no longer wait until
   timeout; current undelivered generations still wait.
2. Shared replacement queues contain both visual and collision-only records.
   GPU visual publication now excludes known collision-only candidates before
   coverage selection. Missing records are preserved, not silently discarded.
3. The native retry queue is also used to repair missing local collision topology.
   Such a repair must survive while collision demand remains, even when the key
   is absent from the visual LOD plan. The previous role check dropped it.
4. GPU interaction no longer scans CPU visual triangle arrays after a physics-ray
   miss. It reports `raycast_miss_gpu_collision_pending`. CPU-mode fallback is
   unchanged; required local Godot physics still legitimately uses CPU topology.

The interrupted mask-only publication shortcut was not retained. Its desired
zero masks did not establish compatibility with old geometry still on screen.
Strengthened reciprocal-face and retained-parent tests preserve atomic handover.
No terrain/water shader, transition table, collision guard, timeout, world size,
LOD radius, or default CPU backend was weakened to pass these tests.

## Isolated Evidence

- M3: the unsafe intermediate mask shortcut fails 13 assertions; the corrected
  implementation passes. This intermediate shortcut was not a committed baseline.
- Native debug/release: application, publication/coverage, and full production
  streaming regressions pass. The existing M5 wrapper fingerprint remains open;
  these results are not whole-suite certification.
- Native/frontend readiness smoke: two pending and two stale cases pass without
  compute or GPU geometry readback.
- The actual failing G23 startup snapshot selected collision-only
  `(18,-1,14)/LOD0` together with visual parent `(9,-1,7)/LOD1`. Coverage correctly
  rejected their overlap even with empty work queues. Filtering removes that stall.
- The isolated rendered relocation excludes seven collision-only candidates,
  preserves all required visual candidates, and checks final drain and coverage.
  A D3D12 run exposed two permanently unready collision-only records after all
  jobs finished. Correcting the retry role check passes three Vulkan and three
  D3D12 repetitions. This is a timing-sensitive regression, not a cross-hardware guarantee.
- The relocation fixture has capacity for both retained old and incoming visual
  inventories. A preliminary 96-slot fixture could not hold both; its capacity
  was corrected to 256 without changing production capacity or readiness rules.
- Bounded production terrain/water lifecycle passes Vulkan and D3D12. Local
  collision authority, zero geometry readback, material payloads, and recovery
  remain checked separately from gameplay performance.
- Player collision-footprint and dual-invoker guards pass.

## Rejected Ray-Demand Experiment

`--gpu-interaction-collision-demand` explicitly enables at most two local
radius-three collision viewers covering the existing 96-unit interaction ray.
They coalesce by chunk and retire when shortened or disabled. The helper passes
4,620 ray-coverage samples including negative coordinates and diagonal rays.

This option is **off by default**, including GPU mode. It did not make the
relocated edit ready and worsened frame-time tails. It is retained for explicit
diagnostic comparison, not promoted as a gameplay optimization. Default mode
adds no viewers or terrain polling through this helper.

The experiment-on pinned run recorded 524/1,020 blocked steps, longest block 169,
post-draw p95/p99 103.049/187.044 ms, and no physics target after 3,973.415 ms.
Earlier files in this checkpoint predate the explicit flag: their recorded
`interaction_collision_invoker.enabled=true` identifies the experimental setting.
Do not replay their command alone as though it represented today's default.

## Final Default Gameplay

Godot 4.7.2, GTX 1060 Max-Q, Vulkan, logical CPUs `[0,1,2]`, two procedural workers,
zero dedicated mesh workers. Readiness diagnostics and ray demand are off.
The route, waits, local collision radius, prediction, and submission limit are unchanged.
The report verifies that loaded binaries match the pin above.

| Measurement | Result |
| --- | ---: |
| Blocked movement steps | 478 / 1,020 |
| Longest consecutive block | 100 steps |
| Post-draw interval p50 / p95 / p99 | 23.838 / 44.868 / 77.785 ms |
| Physics-signal interval p95 / p99 | 37.413 / 72.037 ms |
| Relocated physics target | Missing after 180 frames / 3,017.537 ms |
| Edit accepted | No |
| GPU request rejections / application-wait expirations | 0 / 0 |
| Process wall / CPU time | 46.208 / 77.422 seconds |

The preceding pinned checkpoint reported 501 blocked steps and post-draw p95/p99
52.613/85.868 ms. These are single, incomplete, wall-time-sensitive runs with
different accepted movement, not a statistically established matched-workload
speedup. Neither is an accepted performance baseline. The missing target means
there is no measured edit-completion latency in this run.

## Remaining Work

TQP-64 remains active. GPU terrain is not release-ready, not proven faster than
CPU terrain, and not qualified for the power target. Do not request human
acceptance of this failed gameplay gate or attach a completed-GPU baseline label.

The retained diagnostic trace still shows hundreds of prepared candidates waiting
on publication groups, competing generation work, and expensive activation retries.
Those main/render-thread stage clocks are not GPU execution time and overlap;
they must not be added together. The next work is an isolated publication-to-
player-support/first-target latency reduction with unchanged retained-boundary
and physical-support checks, then the same diagnostics-off route. Increasing
timeouts, suppressing blocked movement, or expanding collision demand is not a fix.

## Moving-LOD Verification

The final instrumented run passes all 25 sampled views and the unchanged strict
final readiness check: 1,219 fully ready records, no pending replacements or
retirements, no queued jobs, and no GPU rejection. Final readiness takes 64 frames
/ 5,213.587 ms. This is sampled visual coverage, not exhaustive topology proof
or player collision acceptance; the flying camera is above the world volume.

The complete run takes 169.660 seconds. The test's synchronous screenshot analysis
accounts for 121.809 seconds, about five seconds per sample. These pauses are test
instrumentation, not GPU execution time or a gameplay benchmark. Phase timings
now identify that cost explicitly. Earlier experiment-on and default runs were
stopped by the separate 180-second runner guard after writing the last scheduled
image but without a summary; they remain `INCOMPLETE_RUNNER_TIMEOUT`, not passes
or demonstrated runtime deadlocks. Neither the runner guard nor the 240-frame
final readiness limit was increased for the completed run.

The exact binary pin and dependency boundary validators pass. Full logs, failed
trials, source hashes, and capture provenance are indexed in
`evidence_manifest.json`; the completed moving-route images are retained separately
as three representative views in `moving_lod_captures.zip`. The manifest records
hashes for the complete local 26-image run inventory.
