# Predictive interaction shell checkpoint

Native authority: `8661e46ea4a4ccce481f3f294f69d7b3f5f9623d`

Runtime artifact digest:
`ae81a7503100d01b0719738e341d8f5075358090b78a5f817d889606bfa803ef`.

Player support points and the complete tool-focus ray now produce bounded LOD0
interaction shells. Lease construction admits every exact center before adding
nearest Manhattan halo layers and stops at the native 64-key limit. A single
target receives its complete 27-key neighborhood; a 96-unit tool ray retains
all seven traversed chunk centers while filling the remaining lease with nearby
keys.

The deterministic cached-approach route warms all 27 target-shell pages and
fails on any reserved-lane rejection or readiness above 100 ms.

| Driver | Traced readiness | Untraced readiness | Traced hot first draw |
| --- | ---: | ---: | ---: |
| Vulkan | 84.342 ms | 83.299 ms | 27.339 ms |
| D3D12 | 83.839 ms | 83.349 ms | 27.333 ms |

The previous Vulkan result was approximately 101 ms, so the shell removes one
displayed frame from that approach. Warm preparation itself remains
asynchronous and measured about 65–67 ms; it runs while the player approaches
the region rather than after interaction begins.

Vulkan and D3D12 rapid-edit routes pass with zero mixed revisions, 24
incremental dispatches, zero copy fallbacks, and 43 completed retirements.
Collision continuity passes for 600 support frames on both drivers. The
multi-chunk relocation route passes with zero geometry readback, and automatic
LOD relocation completes each step in five to six frames on both drivers. The
interaction-demand regression confirms the bounded 64-key shell retains the
entire aimed path.

The native addon, source trees, and binaries are unchanged from the preceding
fully qualified checkpoint. Exact traces, route logs, and the runtime pin are
retained beside this result.
