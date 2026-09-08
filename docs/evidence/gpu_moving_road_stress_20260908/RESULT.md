# Moving-road GPU terrain stress baseline

Game checkpoint based on native authority
`ddcc35a10cb48fb4305df997835b006db089731b`. The installed debug/release DLL
artifact digest is
`c539b398037501cf3bf37d58e50807e114e7d5ca49db93ef74df27dfcfa28d92`.

This checkpoint adds a deterministic production-material route for the GPU
candidate. It moves the visual and collision viewers through twelve road
waypoints at a nominal 240 world units per second, submits alternating carve
and construct edits while moving, injects one eight-operation burst, stops at
the cold endpoint, and then traverses the same route in reverse. The host and
Godot process are limited to three logical processors. The runner samples RSS
and CPU use every 50 ms. The runtime trace records per-frame queues, active
jobs, replacements, GPU occupancy, resident bytes, visual coverage, collision
readiness, and per-target first-ready latency.

## Result

Both APIs accepted and committed all 12 edit batches with zero runtime
rejections and zero geometry readback. Production terrain material parity was
active in both runs.

| Measurement | Vulkan | D3D12 |
| --- | ---: | ---: |
| Frame p95 | 16.728 ms | 16.720 ms |
| Frame p99 | 17.053 ms | 16.922 ms |
| Outbound frame p99 | 16.745 ms | 16.827 ms |
| Visual coverage gap frames | 14 | 13 |
| Visual activation p99 | 11 frames | 9 frames |
| Unresolved visual targets | 0 | 0 |
| Collision-pending route frames | 11 | 13 |
| Collision activation p99 among resolved targets | 3 frames | 3 frames |
| Unresolved collision targets | 2 | 2 |
| Cold endpoint settle | >4.976 s | >4.978 s |
| Cached-return settle | 23.333 ms | 24.974 ms |
| Peak RSS | 518,348,800 bytes | 422,809,600 bytes |

The cold endpoint did not settle within the 300-frame observation window. At
the endpoint, scheduler, storage, mesh-worker, GPU request, and GPU in-flight
counts were all zero on both APIs. Despite that idle state, each run retained
32 pending chunk retirements, 10 collision-required-but-not-ready chunk
records, and one pending replacement. The next viewer update on the cached
return cleared all three classes in roughly 23-25 ms.

This isolates an event-driven progress defect. Completed work does not keep the
publication, collision-readiness, and retirement repair loop awake until it
reaches a fixed point. Increasing cache capacity or adding compute throughput
would leave that dependency intact. The next native checkpoint must make this
repair self-waking and bounded, then require the stationary cold endpoint to
reach zero pending replacements, retirements, and collision readiness debt
within 100 ms without another viewer update.

The route is intentionally a baseline and does not pass the final instant
terrain contract. It fails zero visual gaps, visual activation within two
frames, collision before the next frame, zero unresolved collision targets,
and the 16.667 ms p95 gate. It passes the 25 ms p99 gate in this three-core,
vsynced run.

## Reproduction and retained evidence

Run both APIs with:

```text
python tools/run_gpu_moving_road_stress.py --driver both
```

`baseline_summary.json` retains the compact measurements and hashes of the
full local traces. The full JSON traces remain under
`.godot/world_transvoxel_captures/gpu_moving_road_stress/` because each contains
about 1.4 MB of per-frame native metrics. The retained production-material
images provide visual parity evidence for the cold endpoint and cached return.
