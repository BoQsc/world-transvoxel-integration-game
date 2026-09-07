# GPU stale storage cancellation checkpoint

This game pin consumes native commit
`2fc88ab3f5013075d0b6a15a55b18266a1f12f94` with runtime artifact digest
`3278230c03b3226d862123f0cd873f1f36912f0ca1c35e570c52e7af4b4dbd29`.

The focused D3D12 critical-path route passed. The D3D12 trace-on large route
reduced blocked movement from the preceding checkpoint's 196 frames to one.
The former multi-second page-storage wait was replaced by millisecond storage
segments, confirming that cancelled generations no longer monopolize the
reserved interaction storage lane.

The Vulkan trace-on large route completed but recorded 124 blocked movement
frames. Its retained paths now identify scheduler queue residency and visual
cohort staging as the dominant waits. Trace-on timing is diagnostic and is not
a release performance baseline. The GPU candidate remains opt-in and is not
promoted by this checkpoint.

Debug and release native storage, page-runtime, workload, streaming, and LOD
regressions passed. Shared page ownership, interaction warming, in-flight
immutability, collision authority, and configured capacity limits remain intact.
