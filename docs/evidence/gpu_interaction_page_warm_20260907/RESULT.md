# GPU interaction page warm integration

Native authority: `d29c0b4e`

Runtime artifact digest:
`13c5be7b7d456753aed01f3d35225d96d859d1837a0f199f83741c2339da3590`

The critical-path route issued an interaction-focus lease for cold LOD0 key
`{6,0,0,0}` before moving either viewer. Vulkan and D3D12 each admitted and
decoded the page in one displayed frame with no warm rejection:

| Driver | Warm settle | Requests | Admissions | Completions | Rejections | Viewer-to-ready |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Vulkan | 16.504 ms | 1 | 1 | 1 | 0 | 100.749 ms |
| D3D12 | 16.518 ms | 1 | 1 | 1 | 0 | 100.881 ms |

The route retained six journal, six dirty-page, seven collision-preparation,
and complete GPU capture/activation timeline events on both drivers. Maximum
edit submission was 370 microseconds on Vulkan and 332 microseconds on D3D12.
Geometry readback remained zero.

This proves the later cold approach no longer begins with target-page I/O or
decode. The roughly 101 ms remaining after viewer submission belongs to demand,
collision, GPU capture, and atomic activation; it remains the next checkpoint.
