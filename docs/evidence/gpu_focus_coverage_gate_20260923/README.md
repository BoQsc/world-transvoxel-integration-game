# Foreground visual coverage gate (2026-09-23)

Native `a0c283f` changes interaction-topology refreshes to wait for an active
leaf covering each focus key before refining. A ready sibling in the same
coarse root is not sufficient. The production LOD streaming test, including a
new partially ready sibling case, passed in debug and release.

One Vulkan fast-stage probe used `python tools/run_gpu_tunnel_collision_gate.py
--driver vulkan --wait-frames 0 --launch-grace-seconds 15 --memory-limit-gib 3
--fast-stage-gate`. It failed at the 10-second terrain-runtime deadline. Peak
process-tree RSS was 1,125,920,768 bytes. The startup snapshot had 43 active
records and 54 queued jobs, versus 126 and 215 in the preceding diagnostic
run. These counts are single-run observations, not proof of a stable speedup.

The player-local LOD0 record was collision-only. The local LOD3 root remained
visually required but had no staged or active render generation. The local LOD1
record was absent, whereas it had been demanded without coverage in the prior
run. This confirms the cold coarse root is retained as intended, but does not
establish visible startup coverage. No local GPU activation group was present.
The route had not reached any tunnel edit. Raw evidence remains in
`.godot/world_transvoxel_captures/gpu_tunnel_collision_gate/`.

Next decision: trace that exact LOD3 root through storage, native meshing,
GPU capture, and activation. Preserve the coverage gate; do not substitute an
unready LOD1/LOD0 cut for the missing root. A complete visible coarse floor and
the existing collision/transition/frame-time gates remain required.
