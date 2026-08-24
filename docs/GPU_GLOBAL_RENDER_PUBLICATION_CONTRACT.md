# GPU Global Render Publication Contract

Status: `BOUNDED_GLOBAL_VIEWPORT_PROOF_QUALIFIED`

Schema: `world_transvoxel.terrain.gpu_global_render_publication.v1`

This contract freezes the first TQP-64 proof that computes Transvoxel output
and draws it into a live Godot viewport using resources owned by Godot's global
RenderingDevice. It is default-off and is not connected to production terrain
chunk replacement.

## Authority Boundary

- CPU world state, edits, revisions, desired-set planning, persistence, and
  targeted collision remain authoritative.
- The proof obtains lookup tables from the pinned native `world-transvoxel`
  backend. Copied tables and fallback meshing are forbidden.
- GPU failure is explicit. It cannot invoke CPU meshing, native CPU chunk
  finalization, or ArrayMesh upload.
- Every request carries surface, page, LOD, generation, source revision, world
  revision, transition mask, field mode, and sample-count identity plus a
  positive publication sequence.
- Queue capacity is three and the retained execution ceiling is three logical
  CPUs.

## Publication Order

The publication key is `(surface, page_x, page_y, page_z, lod)`. A newer
accepted sequence immediately supersedes older queued work for that key.
Freshness is checked on the render thread before resource creation and again
immediately before the entry can become resident. This second check prevents a
new revision arriving during GPU allocation from exposing the older mesh.

A complete newer entry replaces the prior resident entry atomically in the
effect's render-thread-owned inventory. Failed or stale work is freed and does
not replace a valid resident entry. A non-increasing sequence is rejected.

## Global Resources

`WtTerrainGpuGlobalRenderEffect` is a `CompositorEffect` using the
pre-transparent callback. All RenderingDevice allocation, compute dispatch,
device-local index copy, framebuffer creation, indexed indirect drawing, and
retirement occur on the render thread and on the same global device.

Each resident proof entry owns the 21-buffer meshing inventory. Compute writes
the three vertex buffers, local index storage, and indexed indirect commands.
Godot 4.7 still requires a device-local copy from index storage into an index
buffer; no geometry crosses to CPU memory. The compositor draw consumes the
GPU-written vertex data and indirect commands directly.

The proof shader reads the stable leading matrix fields of Godot 4.7's scene
data UBO and uses reverse-Z depth comparison. Its colors are diagnostic. They
do not claim production terrain material parity.

## Qualified Proof

The retained LOD1 sphere contains 4,352 cells: 4,096 regular and 256 positive-Z
transition cells. The test submits sequences 1 and 2 before the first render
callback, observes sequence 1 skipped as stale, publishes sequence 2, then
publishes sequence 3 and retires sequence 2. A later sequence-2 request is
rejected.

Vulkan and D3D12 each retain:

- two applied publications, one stale queued skip, one resident supersession,
  and one rejected stale submission;
- one resident entry after supersession;
- zero geometry readback, CPU meshing, CPU finalization, and ArrayMesh upload;
- CPU collision authority unchanged;
- 27,312 visible foreground pixels and image SHA-256
  `b4f424159ca782f3ed0f27ef2144cf391bc19398a1024675db68ca9627823ed8`;
- zero warnings and zero errors.

The viewport image readback belongs only to the test harness. The publication
effect reports zero render-target and geometry readback.

## Excluded Claims

This proof does not replace production terrain chunks, execute the production
large-world route, evaluate the production procedural field on GPU, reproduce
production terrain or water materials, coordinate chunk unload/resize/device
loss, demonstrate performance or power benefit, or complete TQP-64.

The next stage must connect this default-off mechanism to exact accepted
production chunk identities, add bounded resident retirement and recovery,
retain CPU targeted collision, and measure the same large-world relocation and
edit route against the frozen CPU baseline before any backend promotion.

Evidence: [TQP-64 global render publication proof](evidence/tqp64_gpu_global_render_publication_20260824/RESULT.md).
