# Visual

No runtime visual helper is currently installed here. Future overview or
far-field rendering must consume authoritative geometry and state exposed by
`world-transvoxel`; it must not synthesize a second terrain surface.

Terrain correctness paths must render native Transvoxel terrain only. Do not add
full-map/backdrop presentation fallbacks here to hide streaming, LOD, or edit
artifacts; fix the native terrain path instead.
