# TQP-64 Live GPU Meshing Shadow

Date: 2026-08-24

Status: `PASS_BOUNDED_SHADOW_ONLY`

Authority commit:
`091605bdda8ca5dbae978f5d470d4a76d561202f`

## Result

The production terrain addon can opt into a three-request live GPU meshing
shadow lane. Accepted CPU terrain and static-water mesh jobs provide immutable
cell batches and exact page/LOD/generation/revision/transition identity. The
dedicated GPU worker meshes each batch and the controller compares every cell
against the captured CPU backend result. Native completion rejects changed or
superseded identity and cannot publish GPU geometry.

Retained live smoke result on Godot 4.7.2, NVIDIA GTX 1060 Max-Q:

```text
GPU_MESHING_LIVE_SHADOW_SMOKE_PASS terrain=3 water=1 stale=1 cpu_render=1 cpu_collision=1 gpu_publish=0
```

The result passes with both Vulkan and D3D12. The existing 4,352-cell LOD1
service differential also passes on both drivers with no fallback, and the
CPU-only bottom-boundary integration smoke passes with shadow mode disabled.

Native regression results:

```text
M5_PAGE_MESHING_RUNTIME_PASS
PRODUCTION_STREAMING_PASS
PRODUCTION_LOD_STREAMING_PASS
GPU_MESHING_SHADOW_TEST_PASS capacity=2 stale=1 mismatched=1
```

## Boundary

This evidence qualifies live immutable handoff, bounded admission, terrain and
volumetric static-water differential matching, exact identity return, stale
rejection, and unchanged CPU render/collision authority. It does not qualify
GPU publication, GPU-resident render buffers, performance benefit,
large-terrain behavior, device recovery, or production release.
