# CPU Human Baseline Evidence, 2026-08-12

Status: `MEASURED_TARGET_MISS`.

This is the first retained baseline of the reviewed exact-mask integration state
for the two human-observed symptoms. It is not evidence that terrain correctness
failed, and it does not attribute either symptom to a specific pipeline stage.

## Identity

- integration measurement commit: `413eaa5c9c612bd0ee3bf939b233723d9d2a8080`;
- authority commit: `f30818b9ce0f0b3f9ddb75726db5522d97167404`;
- Godot: `4.7.1.stable.steam.a13da4feb`, editor/debug, Forward+ Vulkan;
- GPU: NVIDIA GeForce GTX 1060 with Max-Q Design;
- logical CPU affinity: `[0, 1, 2]`;
- profile: `g23_four_biomes_lakes_mountains_roads_2k_256_on_demand`;
- repetitions: three, each with fresh storage.

## Results

All three routes and edits completed. All three runs missed at least one declared
performance target.

| Measurement | Run 1 | Run 2 | Run 3 | Median |
|---|---:|---:|---:|---:|
| Full-route frame p99 | 23.236 ms | 18.686 ms | 23.162 ms | 23.162 ms |
| Full-route worst frame | 100.428 ms | 29.598 ms | 73.305 ms | 73.305 ms |
| Blocked movement frames | 8 | 52 | 11 | 11 |
| Longest blocked movement run | 4 | 30 | 6 | 6 |
| Authority commit | 49.914 ms | 66.661 ms | 33.330 ms | 49.914 ms |
| Relocation to exact visual readiness | 14,532.785 ms | 316.719 ms | 13,206.199 ms | 13,206.199 ms |
| Relocation to exact collision readiness | 14,532.785 ms | 316.719 ms | 13,206.199 ms | 13,206.199 ms |
| Maximum scheduler queue | 762 | 723 | 795 | 762 |
| Maximum pending replacements | 757 | 723 | 799 | 757 |
| Process CPU time | 85.219 s | 65.312 s | 84.500 s | 84.500 s |
| Active-core equivalent | 1.393 | 1.410 | 1.333 | 1.393 |
| Peak process-tree RSS | 829.5 MiB | 787.4 MiB | 825.4 MiB | 825.4 MiB |

Movement-phase worst frames reached `40.329 ms`; the larger full-route maxima
occurred outside a movement phase. This distinction must be retained. The
flight symptom is supported most strongly by intermittent movement rejection,
including one 30-frame consecutive blocked run, not by treating every full-route
hitch as a flight hitch.

The authority edit commit itself remained between `33.330 ms` and `66.661 ms`.
The very large and highly variable delay occurred between commit and exact
render/collision publication. This narrows the next investigation to downstream
work but does not identify storage, sampling, meshing, scheduling, staging,
render publication, collision publication, or main-thread contention as the
cause.

## Decision

- Correctness remains governed by the separately retained exact-mask authority
  and human-review evidence.
- This report is the comparison baseline for the current Godot editor/debug
  human-equivalent scenario under three logical CPUs.
- Optimization is blocked until a real-time causal terrain-pipeline trace exists.
- TQP-58 GPU architecture selection is blocked until that trace is understood.
- CPU-package and whole-system watts remain unavailable; AC power was present,
  but no trusted watt sensor was available.

`baseline.json` contains all raw summaries and aggregate values. The three
`run_*.stdout.log` files retain the original Godot summaries.
