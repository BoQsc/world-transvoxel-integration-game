# GPU coverage handoff pin — 2026-09-23

The game now pins native `a400a01babd72f3331510f6a7fb7625e09f832f7`.
The authority package digest is
`d4d2d8e25a925dd9ce9c7fda7de20039e669903196335dd41d8e63fea7294804`.
Debug and release DLLs were rebuilt and synchronized from that commit.
`validate_world_transvoxel_runtime_artifact.py` and
`validate_terrain_dependency_boundary.py` passed.

The native change retains active GPU coverage while a same-generation
transition-mask replacement is pending, and rejects absent active coverage as
proof of an empty chunk in the same-layout edit shortcut. The GPU candidate
remains opt-in and unqualified: this pin does not establish hole-free gameplay,
instant edits, or acceptable frame time. The next gate must exercise moving
visual coverage and edited transitions in-engine before performance tuning.
