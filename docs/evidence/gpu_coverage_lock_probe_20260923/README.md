# GPU initial-coverage lock probe (2026-09-23)

The GPU candidate still fails the short Vulkan tunnel gate. This run was a
focused test of whether native viewer submission stalls on the runtime input
mutex; it was not a terrain-performance qualification.

Command: `python tools/run_gpu_tunnel_collision_gate.py --driver vulkan --wait-frames 0 --launch-grace-seconds 15 --memory-limit-gib 3 --fast-stage-gate`

Result: `fast_stage_deadline` after 10 seconds of terrain runtime (15.7 seconds
total including engine launch and termination); peak process-tree RSS was
1,026,113,536 bytes. The opt-in `WT_VIEWER_ENQUEUE_TIMING` probe reported no
input-mutex acquisition wait of at least 5 ms. The startup snapshot had 174
active records, 207 queued jobs, one pending replacement, and no active local
GPU coverage; local collision was ready. The inspected activation seed was
stale (`GPU resident cohort seed is no longer pending publication`), but that
seed was not identified as the missing player-local visual, so it is not yet a
proven cause of the local hole.

The route had reached its first cold camera relocation and had not reached any
tunnel edit. Its deadline began at terrain startup, so this run does not measure
10 seconds of relocated-region loading or rapid editing. The retained raw log
and JSON are under `.godot/world_transvoxel_captures/gpu_tunnel_collision_gate/`.

Next experiment: instrument the exact local visual generation and its native
job/capture/publication timestamps, plus a per-frame callback heartbeat.
Separate the startup-coverage probe from the cold-approach/edit route. Reject
the coverage design if a visible region lacks a complete coarse floor; do not
relax the LOD0, transition, collision, or frame-time acceptance gates.
