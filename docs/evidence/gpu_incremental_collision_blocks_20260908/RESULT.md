# Incremental collision-block continuity checkpoint

Native authority: `860a98b2105052862b03d131402ff8d1db5e8ec3`

The runtime previously generated an LOD0 collision mesh for only the dirty
8-cubed blocks, then labeled and cached it as a complete eight-block payload.
Godot consequently replaced untouched block shapes with empty shapes. A local
dig could therefore remove player support elsewhere in the same chunk.

Incremental collision preparation now retains the exact dirty-block mask. The
Godot sink replaces only those shapes, and a partial construction can extend an
authoritative empty-generation tombstone. When the previous complete payload is
still cached, the runtime merges the patch into a complete new cached
generation; an evicted base is never replaced with an incomplete cache entry.
Edit replay also applies each command once to a temporary page and adopts it
only after finite-result validation, preserving atomic SDF semantics without a
duplicate full-page evaluation.

The focused route was changed from a boundary-centered `0xff` edit to a true
partial `0xa0` edit. It ray-checks an untouched support block on every physics
frame and reports native causal timings.

Verification:

- Debug and release native builds passed.
- Ten focused native regressions passed in both configurations, including edit
  application, compaction, page meshing, replacement, production streaming,
  production LOD, lifecycle, and fault-order determinism.
- Vulkan partial-block continuity passed with `dirty_block_mask=160`, unchanged
  support, one collision resource, and collision sink application at 21,747 us.
- D3D12 partial-block continuity passed with `dirty_block_mask=160`, unchanged
  support, one collision resource, and collision sink application at 22,450 us.
- Vulkan and D3D12 rapid-edit tests passed 12 edits with zero mixed revisions.
- Vulkan and D3D12 full-quality tests activated edited LOD0 one displayed frame
  after commit and were controller-visible by frame two.
- Quiet reruns of the traced critical route passed: Vulkan submission maximum
  472 us, first draw maximum 19,776 us, cached approach 67,285 us; D3D12
  submission maximum 444 us, first draw maximum 30,128 us, cached approach
  67,312 us.

This checkpoint resolves the observed collision disappearance and makes partial
collision work measurable. It does not satisfy collision-before-next-physics:
the focused sink event remains about 22 ms and the broad route's coarse
ready-state observation remains 50-58 ms. The next checkpoint must replace the
full render-mesh collision extraction path with a dedicated collision-face
extractor and tighten physics-boundary delivery.
