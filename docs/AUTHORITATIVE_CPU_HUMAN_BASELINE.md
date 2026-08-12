# Authoritative CPU Human Baseline

This baseline freezes the reviewed CPU terrain behavior before any further
performance work. It covers the two human-observed symptoms:

- flight stutter during normal and fast traversal;
- delayed first visible and collidable edit after relocation.

It is a measurement milestone, not an optimization and not a new terrain
implementation. A completed run is retained when it misses performance targets.
Structural failures, incomplete routes, rejected edits, missing measurements,
and incorrect configuration still fail closed.

## Frozen Configuration

- Godot 4.7 editor/debug runtime on Windows x86-64, Forward+ Vulkan;
- profile `g23_four_biomes_lakes_mountains_roads_2k_256_on_demand`;
- production texture-array presentation;
- exact logical CPU affinity `[0, 1, 2]`;
- two procedural generation workers;
- collision invoker radius two chunks and 24 m prediction;
- authority and binary identity from `AUTHORITY_HOTFIX_PIN.json`;
- fresh storage for every run.

The deterministic route exercises normal diagonal flight, normal return,
fast X and Z traversal, fast diagonal traversal, stops, a fixed relocation to
`(560, 74, 560)`, collision-target acquisition, one carve, authority commit,
exact render publication, and exact collision publication.

## Retained Measurements

Three runs are required. Each run retains:

- frame p50/p95/p99/maximum and threshold counts for every route phase;
- blocked movement frames and longest blocked run;
- target acquisition, authority commit, visible readiness, collision readiness,
  and total relocation-to-readiness latency;
- scheduler, replacement, retirement, staging, render, and collision maxima;
- sample, mesh, and collision-application maximum durations;
- wall time, process CPU time, active-core equivalent, and peak process-tree RSS;
- exact commands, stdout, stderr, renderer device, commits, trees, binary hashes,
  CPU affinity, and available power-source metadata.

CPU-package watts, whole-system watts, and release-export performance are not
inferred from this editor/debug baseline.

## Decision Rules

`MEASURED_TARGET_MISS` is valid baseline evidence. It does not revoke the
separately qualified correctness baseline, and it must not be rewritten as a
performance pass.

No terrain runtime, scheduler, queue, storage, meshing, publication, collision,
LOD, or interaction behavior may be changed while capturing this baseline.

After the baseline is retained, the next milestone is a real-time causal trace
covering input, movement, demand, storage, sampling, meshing, transition work,
render publication, collision publication, queue state, worker time, main-thread
time, and freeze intervals. Optimization is blocked until that trace attributes
the measured delay or stutter. Every later change requires one-variable A/B
comparison against this baseline plus full correctness and human regression
review.

The GPU architecture decision is also blocked until causal attribution is
complete. A GPU backend must not be selected merely because this CPU baseline
misses a target.

## Command

Run from this repository with the Steam Godot 4.7 executable available:

```text
python -c "import psutil,runpy,sys; psutil.Process().cpu_affinity([0,1,2]); sys.path.insert(0,'tools'); sys.argv=['tools/p0_runtime_baseline.py']; runpy.run_path('tools/p0_runtime_baseline.py',run_name='__main__')"
```

The retained report belongs under
`docs/evidence/authoritative_cpu_human_baseline_20260812/`.
