# Visual

Reusable terrain visual helpers live here. These nodes may provide far-field or
overview rendering, but they must not replace native Transvoxel detail,
collision, editing, storage, or runtime telemetry.

Terrain correctness paths must render native Transvoxel terrain only. Do not add
full-map/backdrop presentation fallbacks here to hide streaming, LOD, or edit
artifacts; fix the native terrain path instead.
