# TQP-64 GPU Resident Resource Proof

Status: `PASS_BOUNDED_LOCAL_DEVICE_PROOF`

On 2026-08-24, Godot 4.7.2 rendered one exact native LOD1 fixture containing
4,352 cells using compute-written vertex data and 4,352 GPU-written indexed
indirect commands. Vulkan and D3D12 both produced 29,496 foreground pixels,
45.0073% coverage, and the identical image SHA-256
`8c8e39b3480a9674472074bab1169d68e602e20eca9b09160137cd9785439a32`.

The proof used the retained NVIDIA GeForce GTX 1060 with Max-Q Design profile
and at most three logical CPUs. Both retained logs contain zero warnings and
zero errors.

## Qualified Boundary

- geometry readback: 0 bytes;
- final qualification target readback: 262,144 bytes;
- CPU meshing, native CPU finalization, and ArrayMesh upload: not used;
- compute and raster execution: same local RenderingDevice on the dedicated
  GPU worker;
- CPU collision authority: unchanged;
- production scene publication: not implemented.

Godot 4.7 does not accept an index-buffer RID as a compute storage uniform.
The compute-written index storage is therefore copied into a raster index
buffer using a device-local buffer copy. Vertex buffers and indirect commands
are consumed directly. No geometry crosses to CPU memory.

The original GPU differential service and matched-cell publication smokes also
pass on Vulkan and D3D12 after the resource inventory changed from 20 to 21
compute bindings.

Commands:

```text
python tools/run_gpu_resident_render_resource_smoke.py --driver both --skip-import
python tools/run_gpu_meshing_service_smoke.py --driver both --skip-import
python tools/run_gpu_meshing_live_publication_smoke.py --driver vulkan
python tools/run_gpu_meshing_live_publication_smoke.py --driver d3d12
```

This result qualifies the resident-resource contract, not TQP-64. The next
stage is global render-thread resource ownership and versioned live scene
publication without cell readback or ArrayMesh upload.
