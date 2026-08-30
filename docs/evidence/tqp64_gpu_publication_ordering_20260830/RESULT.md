# GPU Publication Ordering Checkpoint

Date: 2026-08-30. Godot 4.7.2 Steam, Windows/NVIDIA, at most three logical CPUs.
Upstream remains `c1b40a6720061436df0134587655060d74ae3b73`.
Integration parent: `92d74d846292f7b6934c87f71022fdcc58068b82`.
Status: ordering checkpoint passed; production GPU release remains open.

## Defects And Fixes

1. The activation-retry queue reinserted failed retries ahead of unvisited
   entries. An isolated 25-group test observed groups 0-7 repeated four times
   while groups 8-24 were never visited. Bounded round-robin processing now
   preserves fairness, cancellation, deduplication, and the eight-attempt limit.
2. The regional native-commit inventory admitted entries whose earlier GPU
   activation was still in flight. Native readiness could be committed for new
   members, followed by a downstream early return on the not-yet-visible
   retained member. The inventory now excludes in-flight activation groups.
   A scripted transaction regression verifies no new commit before the retained
   member activates, followed by exactly one commit/render submission afterward.
3. The autonomous route reported success after an edit committed even when its
   readiness wait expired. It now requires accepted and committed edits, target
   visual/collision readiness, native replacement/retirement drain, and GPU
   request/activation/lifecycle drain without rejection or recovery.

The dormant-cache experiment was removed. These fixes require no upstream
changes, recapture API, CPU-topology fallback, or extra resident cache policy.

## Final Verification

| Test | Vulkan | D3D12 |
| --- | --- | --- |
| Multi-chunk relocation/resource reuse | Pass | Pass |
| Production lifecycle and bounded terrain/water material contracts | Pass | Pass |
| Strict 2K flight, relocated carve, relocated construction | Pass | Pass |
| Final tracked/active chunks | 1758 / 1758 | 1709 / 1709 |
| Final resident/active surfaces, including water | 1841 / 1841 | 1792 / 1792 |
| Incomplete or prepared-inactive chunks | 0 | 0 |
| Native requests/replacements/retirements pending | 0 | 0 |
| GPU queued work, extraction, lifecycle commands, events | 0 | 0 |
| Rejections, unrouted events, recovery events | 0 | 0 |

The isolated ordering/drain regression also passed headlessly. The relocation
images have the same SHA-256 on both backends:
`c694e37ab85ba685a35d7260a8b898609ec6d8dd08edcc2f7bcc61782dcaa38d`.

Reproduction entry points:

```text
python tools/run_gpu_activation_retry_fairness_smoke.py
python tools/run_gpu_resident_multichunk_relocation_smoke.py --driver both
python tools/run_gpu_resident_production_lifecycle_smoke.py --driver both
python tools/run_human_playtest.py --latest --windowed --rendering-driver vulkan --gpu-resident-render-candidate --terrain-waterfall-autonomous
python tools/run_human_playtest.py --latest --windowed --rendering-driver d3d12 --gpu-resident-render-candidate --terrain-waterfall-autonomous
```

## Limits

- These are correctness/liveness runs with intrusive causal tracing, not a
  performance comparison. Trace durations were 50.04 s and 46.11 s, excluding
  startup. Driver routes differ because collision readiness affects distance
  traveled; their timings must not be compared as backend speedups.
- Global readiness still required hundreds of physics frames after each edit.
  This is not evidence of instantaneous digging/construction, nor a measurement
  of the first visible local update. Dedicated trace-off latency measurement is
  still required.
- The small lifecycle water fixture is not a whole-world lake-quality review.
  No new human visual approval or 60 FPS/16 W result is claimed.
- CPU authority and collision behavior were not modified. The normal backend
  remains CPU; GPU remains an explicit candidate.

[Machine-readable summary](qualification.json) retains final metrics, source
hashes, and local trace paths/hashes. Raw traces remain under the project's
`.godot/world_transvoxel_captures/` directory and are not committed to Git.
