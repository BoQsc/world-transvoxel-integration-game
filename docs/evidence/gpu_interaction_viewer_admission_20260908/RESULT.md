# GPU interaction viewer admission

The GPU candidate enabled persistent, player, predictive, and aim-focus visual
viewers while the four-biome profile configured native capacity for only two.
`start_world()` discarded the failed player-viewer return, so the later roles
and foreground lease could be absent without failing startup.

This checkpoint derives the required visual-viewer capacity from the enabled
roles, fails startup when initial player demand is rejected, and refreshes the
aim-focus viewer when camera aim changes without player translation. The focus
position now comes from the same tool-target query used by foreground priority.

Validation:

- Godot 4.7.2 headless project parse: pass.
- `tests/production_gameworld_runtime_smoke.gd`: pass.
- `tools/validate_terrain_dependency_boundary.py`: pass at native `6e18342`.
- Guarded Vulkan autonomous waterfall with a 3 GiB RSS limit: completed;
  maximum RSS 2,215,239,680 bytes.
- Final trace records 8 player, 8 predictive, and 8 focus visual-viewer updates.

This exposes the next structural blocker rather than passing the performance
gate. The first relocated carve published collision in 63.37 ms, but its visual
change joined 228 replacements and completed in 16,541.18 ms. Focus demand must
be represented as exact bounded topology refinement instead of a radius-one
viewer that expands a broad region.
