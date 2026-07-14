# API Ownership

Public adapters, stable names, and Resource registration belong here.

This directory must not own terrain generation, meshing, storage, streaming, or
edit recovery logic.

A2 adds placeholder public scripts for dependency status and terrain profile
loading only.

`WtTerrainProfile` summaries must include `horizontal_cells`, `vertical_cells`,
and `vertical_origin_cell`. The vertical origin is required for deeper bounded
volumes where underground terrain extends below Y=0; consumers must not infer
the terrain is heightmap-like or surface-only from a flat/procedural starting
surface.
