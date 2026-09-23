# Production terrain material startup checkpoint — 2026-09-23

The short Vulkan gate exposed a synchronous startup stall after spawn
stabilization. The first production material apply generated up to 24
512-pixel layers with per-pixel GDScript loops, taking 7.31–8.50 seconds in
instrumented runs. During that work, queued native terrain publications could
not reach the frontend.

The production material now reads 24 checked-in lossless PNG layers and builds
the same mipmapped Godot texture arrays with native image operations. A source
baker and a parity verifier are included. The verifier regenerated all three
eight-layer arrays from the authored/procedural source and confirmed exact
image-byte parity after runtime loading, including mipmaps. Its baked load
times were 70 ms (albedo), 96 ms (normal), and 37 ms (roughness/ORM) in a
headless run. Procedural construction remains a fallback for other resolutions
or missing baked assets.

In the next bounded Vulkan gate, first material apply took 567 ms (5,660 to
6,227 ms) and startup reached the local visual-readiness loop. A later gate
reached 28 committed edits before failing on
`local_exact_gpu_publication_not_ready`; the GPU candidate is still
unqualified. These separate runs show the eliminated material stall, not a
controlled latency percentile. The generated gate log and summary remain under
`.godot/world_transvoxel_captures/gpu_tunnel_collision_gate/`.

Reproduce parity with `godot --headless --path . --script
res://tools/verify_game_terrain_material_arrays.gd`. Reproduce the short gate
with `python tools/run_gpu_tunnel_collision_gate.py --driver vulkan
--wait-frames 0 --launch-grace-seconds 15 --memory-limit-gib 3
--fast-stage-gate`.
