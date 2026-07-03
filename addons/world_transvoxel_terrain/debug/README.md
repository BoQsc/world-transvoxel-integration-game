# Debug Ownership

Debug overlays, status surfaces, counters, captures, and inspector helpers
belong here.

Debug features must not create hidden terrain work in normal runtime mode.

A5 phase 1 adds `WtTerrainDebugSnapshot`, a read-only status aggregation helper
for the later local reference scene and debug UI.

A5 phase 2 adds `wt_terrain_reference_scene.tscn` and
`WtTerrainReferenceScene`, a minimal addon-local scene scaffold with a
`WtTerrainWorld` child and debug status label.

A5 phase 3 makes the reference scene run its owned terrain world against the
official backend fixture and report live runtime status in the debug label.

A5 phase 4 adds `WtTerrainDebugOverlayFormatter`, which renders debug snapshot
categories into explicit overlay sections for the reference scene label.

`WtTerrainMeshStats` owns debug mesh counting for validation and integration
smoke tests. Game repositories should not carry their own backend mesh traversal
helper just to prove terrain has drawable mesh instances.

`WtTerrainWatertightnessProbe` owns rendered mesh edge/winding audits for
integration smoke tests. Game repositories may choose probe centers and edit
patterns, but the backend mesh traversal and edge counting should stay here.
