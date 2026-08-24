# GPU Resident Render Resource Contract

Status: `BOUNDED_LOCAL_DEVICE_PROOF_QUALIFIED`

Schema: `world_transvoxel.terrain.gpu_resident_render_resource.v1`

This contract freezes the first render-consumable output of the TQP-64 GPU
meshing candidate. It is a same-device offscreen proof, not production scene
publication.

## Authority Boundary

- CPU world state, edits, revisions, desired-set planning, stale rejection,
  persistence, and targeted collision remain authoritative.
- GPU failure fails explicitly. It does not invoke CPU meshing as a fallback.
- Every request retains page, LOD, generation, source revision, world revision,
  transition mask, field mode, and sample-count identity.
- The proof runs on the existing dedicated GPU worker with at most three
  outstanding requests. Compute submission and synchronization do not run on
  the gameplay frame thread.

## Resident Resources

The candidate owns 21 persistent compute bindings:

- bindings 0-12: field, cell, table, and request identity inputs;
- bindings 13-15: compute-writable vertex position, normal, and material
  metadata buffers created as renderable vertex buffers;
- binding 16: reuse metadata;
- binding 17: compute-writable local index storage;
- bindings 18-19: cell and request identity outputs;
- binding 20: GPU-written indexed indirect commands.

Each indirect command is 20 bytes and contains `index_count`,
`instance_count`, `first_index`, `vertex_offset`, and `first_instance`. Empty or
failed cells receive a zero-instance command. Surface cells receive one indexed
draw with their exact output index count.

Godot 4.7 accepts storage-enabled vertex buffers in compute uniform sets, but
its GDScript RenderingDevice path does not accept an index-buffer RID as a
storage uniform. Binding 17 therefore remains a storage buffer and is copied
device-locally into one persistent raster index buffer before drawing. This is
a GPU buffer copy, not geometry readback, CPU remeshing, or ArrayMesh upload.
The direct vertex resources and GPU-written indirect resource are consumed
without copying.

## Qualified Proof

The offscreen proof performs this order on one local RenderingDevice:

1. update immutable request inputs;
2. dispatch the production regular and transition compute mesher;
3. copy only the generated index bytes into the raster index buffer on GPU;
4. execute indexed indirect draws from the GPU-written command buffer;
5. read back only the final RGBA8 qualification target.

The proof must report:

- zero geometry readback bytes;
- no CPU meshing or CPU chunk finalization;
- no ArrayMesh upload;
- positive bounded foreground coverage;
- deterministic image signature on every claimed backend;
- exact resident request identity and dedicated-worker execution;
- `production_scene_publication=false`.

The final color readback exists only to validate the proof. It is not part of a
production rendering path.

## Excluded Claims

A local RenderingDevice cannot publish these resources to Godot's global
screen renderer. This contract therefore does not claim live terrain
replacement, frame-time benefit, power benefit, material parity, device
recovery, or TQP-64 completion.

The subsequent
[global render publication contract](GPU_GLOBAL_RENDER_PUBLICATION_CONTRACT.md)
now allocates and consumes equivalent resources on Godot's global
RenderingDevice with render-thread ownership and exact sequence checks. It
remains a bounded viewport proof rather than production chunk replacement.

Evidence: [TQP-64 GPU resident resource proof](evidence/tqp64_gpu_resident_resource_20260824/RESULT.md).
