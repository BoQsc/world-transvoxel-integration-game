# Incremental edited-page cache checkpoint

Native commit: `ad5ee686657ed2421b5067684032783fab875545`  
Runtime artifact: `f52703e9e4a7486698b160dc360a74491201a59199572860e11118f32cb94b8c`

The page-meshing runtime now retains bounded immutable edited pages and advances them by replaying only journal transactions newer than the cached revision. Revision-zero streaming does not populate the cache. Eviction reconstructs from immutable source pages plus the authoritative journal.

| Driver | Previous six-edit prepare | Current | Reduction | Submission max | First draw max | Cold ready |
|---|---:|---:|---:|---:|---:|---:|
| Vulkan | 4.8733 ms | 0.8729 ms | 82.1% | 416 us | 3980 us | 66839 us |
| D3D12 | 4.8392 ms | 0.8670 ms | 82.1% | 416 us | 7504 us | 67060 us |

The six-edit route used one 82,428-byte entry, performed one miss followed by five incremental updates, and recorded no eviction on both backends. The native differential test proves incremental and exact-revision cache outputs hash identically to a cold full journal replay.

Additional checks passed in debug and release: journal range replay, page meshing, production streaming, production LOD streaming, chunk meshing, GPU capture saturation, and stale-generation rejection. Vulkan and D3D12 rapid-edit checks each completed 12 edits with zero mixed revisions and zero copy fallbacks. Collision continuity passed three consecutive runs per backend while retaining player support and opening the mined surface.
