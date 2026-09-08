# Dedicated incremental collision mesher checkpoint

Native authority: `ddcc35a10cb48fb4305df997835b006db089731b`

Partial LOD0 collision updates previously used the full render-oriented regular
mesher. That path repeatedly sampled neighboring density points to construct
render normals and deduplicated material vertices before physics could consume
the faces. The work was correct, but it added avoidable latency to every edit.

Incremental collision now has a dedicated regular-cell extractor. It samples
each selected 8-cubed block grid point once, derives a deterministic gradient
from each cell's eight scalar corners, and emits the canonical regular-cell
faces directly. It still runs the authoritative triangle finalizer, including
degeneracy removal, shared-edge validation, and component winding correction.
Visual meshing, transition topology, block ownership, generation cancellation,
capacity limits, and atomic collision publication are unchanged.

Native parity coverage expands the standard and collision-only indexed meshes
to face sequences and compares them for planar, crater, and sphere fields with
partial mask `0xa0` and full mask `0xff`. The focused test reports scalar sample
reduction from 6,647 to 4,913. A proposed shortcut that skipped the triangle
finalizer was rejected after exhaustive regular-case testing changed 56 of 254
cases.

## Causal result

Before this checkpoint, a representative edit trace measured about 4.3 ms for
journal commit, 9.3 ms for collision meshing, and 24.0 ms from edit submission
to the Godot collision sink. Safe final runs reduced collision meshing to about
6.9-8.7 ms while retaining exact finalized faces.

Final focused smoke results using the pinned DLLs:

- Vulkan: collision mesh started at 6,922 us, finished at 14,067 us, prepared
  at 14,139 us, and reached the collision sink at 21,691 us.
- D3D12: collision mesh started at 7,640 us, finished at 16,315 us, prepared at
  16,353 us, and reached the collision sink at 25,363 us.
- Both APIs retained untouched support for 600 physics frames with partial
  `dirty_block_mask=160` and one authoritative collision resource.
- Both APIs passed 12 rapid edits with zero mixed revisions. Vulkan used 24
  incremental dispatches and zero copy fallbacks; D3D12 used 24 incremental
  dispatches and zero copy fallbacks.

## Regression result

- Debug and release native builds passed.
- Debug and release passed the selected native regressions for chunk meshing,
  edit application, compaction, page meshing, edit replacement, production
  streaming, production LOD streaming, lifecycle, and fault-order determinism.
- After the final extractor cleanup, chunk-mesh parity and page-meshing runtime
  tests passed again in both configurations.
- Runtime artifact and terrain dependency-boundary validation passed for the
  exact binary pin recorded in `runtime_pin.json`.

This checkpoint removes render-only work from partial collision extraction. It
does not yet meet collision-before-next-physics: final end-to-end publication is
21.7 ms on Vulkan and 25.4 ms on D3D12. The measured critical path now points to
the synchronous journal commit (about 4.3 ms), remaining finalized extraction,
and frontend callback alignment. The next experiment should move durable journal
I/O off the interactive path while preserving an ordered, bounded,
memory-authoritative committed revision and unchanged replay format.
