# GPU coarse-coverage capture reservation — 2026-09-23

Native authority: `7a5b6f6ad1601dde72b02d29c73d843c2b234d42`.

The 16-slot GPU field-capture queue now reserves four slots for player-visible
coverage and four for committed edits. Background capture is limited to eight.
The same bounds apply to direct captures and pre-mesh reservations. This does
not relax generation matching, publication, or collision authority.

Debug and release native builds passed. Debug and release
`test_wt_gpu_meshing_shadow`, `test_wt_production_streaming`, and
`test_wt_production_lod_streaming` passed. Runtime artifact and dependency
boundary validators passed against the pinned native commit.

The bounded 10-second Vulkan stage gate **failed** with
`fast_stage_deadline`; peak process-tree RSS was 1,065,992,192 bytes. The
player-local coarse root `(2, 0, 2) LOD3` finished storage at 178.56 ms,
entered the mesh queue at 178.61 ms, started meshing at 507.42 ms, and queued
publication at 507.50 ms. Frontend publication was not consumed until
8,084.58 ms, and local GPU visual coverage was still inactive in the sampled
frames. A previous diagnostic run had the same root waiting until 7,285.79 ms
to dequeue, but the runs are not a controlled percentile comparison.

This checkpoint proves bounded capture-class admission in native tests and
shows faster root mesh admission in one gameplay gate. It does **not** pass
startup visibility or prove the cause of the remaining frontend stall. The
next experiment must locate the 7.6-second publication-to-frontend gap before
further capacity or priority changes.

Reproduce with
`python tools/run_gpu_tunnel_collision_gate.py --driver vulkan --wait-frames 0 --launch-grace-seconds 15 --memory-limit-gib 3 --fast-stage-gate`.
The generated log and JSON summary are under
`.godot/world_transvoxel_captures/gpu_tunnel_collision_gate/`.
