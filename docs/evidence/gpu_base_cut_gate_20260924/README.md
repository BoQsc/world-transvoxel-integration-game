# GPU edited-root draw gate (failed)

Game checkpoint parent: `035d803`; pinned native backend: `009815f`.
The candidate is still opt-in and unqualified for play.

`python tools/probe_gpu_base_startup.py --godot <godot.exe> --seconds 10 --memory-gib 3 --mode base_coverage_edit_probe`
completed in 8.72 seconds at 737 MiB peak RSS. The edit was in LOD0 chunk
`18:2:19`. At displayed frames 0, 1, and 2 its exact revision was not selected
for drawing. At frame 11, three LOD0 chunks were active, but the draw cut still
selected ten LOD3 chunks and no LOD0 chunks. The probe exits nonzero. Raw capture
and log remain under `.godot/world_transvoxel_captures/base_coverage_probe/`.

The LOD3 base atlas has one indirect draw per 128-cell root. The current cut
retains that whole root until its finer subtree is complete. A single edited
LOD0 leaf therefore cannot be shown while the rest of the root remains on the
base atlas. The next implementation must represent independently replaceable
child regions with exact Transvoxel transition ownership and atomically switch
their draws. The gate is exact edited-chunk LOD0 draw selection by frame 2,
with continuous coverage and no stale-revision publication. Collision and frame
time qualification remain separate failing gates.
