# TQP-64 GPU Global Render Publication Proof

Status: `PASS_BOUNDED_GLOBAL_VIEWPORT_PROOF`

On 2026-08-24, Godot 4.7.2 rendered one exact native LOD1 fixture into a live
viewport through a pre-transparent `CompositorEffect`. Compute, resident
resources, device-local index copy, and indexed indirect drawing all used
Godot's global RenderingDevice on the render thread.

The 4,352-cell fixture contains 4,096 regular cells and 256 positive-Z
transition cells. Vulkan and D3D12 each produced 27,312 foreground pixels and
the identical image SHA-256
`b4f424159ca782f3ed0f27ef2144cf391bc19398a1024675db68ca9627823ed8`.
Both retained logs contain zero warnings and zero errors.

## Version Proof

- sequences 1 and 2 were queued for one exact surface/page/LOD key;
- sequence 1 was skipped before allocation because sequence 2 was newer;
- sequence 2 became resident and visible;
- sequence 3 replaced sequence 2 and freed its global resources;
- a later sequence-2 request was rejected;
- freshness is also rechecked after allocation and before visibility.

The final counters on each backend are two applied publications, one queued
stale skip, one resident supersession, one rejected stale request, and one
resident entry.

## Claim Boundary

- geometry and publication-path render-target readback: 0 bytes;
- CPU meshing, native CPU finalization, and ArrayMesh upload: not used;
- CPU collision authority: unchanged;
- fallback: forbidden and unused;
- production chunk replacement: not connected;
- production material parity: not claimed;
- large-world responsiveness, performance, power, recovery, and release: not
  qualified.

The final viewport capture is read back only by the qualification harness. It
is not part of the publication effect.

Commands:

```text
python tools/run_gpu_global_render_publication_smoke.py --driver both --skip-import
python tools/run_gpu_resident_render_resource_smoke.py --driver both --skip-import
python tools/run_gpu_meshing_service_smoke.py
python tools/run_gpu_meshing_live_shadow_smoke.py --driver vulkan
python tools/run_gpu_meshing_live_shadow_smoke.py --driver d3d12
python tools/run_gpu_meshing_live_publication_smoke.py --driver vulkan
python tools/run_gpu_meshing_live_publication_smoke.py --driver d3d12
python -m pytest -q
```

This qualifies global render-thread ownership and versioned live viewport
publication only. TQP-64 remains incomplete.
