# Visual

Reusable terrain visual helpers live here. These nodes may provide far-field or
overview rendering, but they must not replace native Transvoxel detail,
collision, editing, storage, or runtime telemetry.

`wt_terrain_full_map_visual.gd` is the current deterministic-reference full-map
visual baseline. It covers the complete 2048 by 2048 compact procedural terrain
footprint while local native Transvoxel chunks remain the editable/collision
detail layer.
