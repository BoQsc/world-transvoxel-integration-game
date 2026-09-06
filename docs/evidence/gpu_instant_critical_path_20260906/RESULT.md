# GPU instant critical-path checkpoint

The game is pinned to native commit
`6a4a102980ccba4d1fe60099af3aea616e36a15b`. The installed binary-only
artifact digest is
`9d43fb04b5c7086c6f224e1b7807074de3688ccf102729bcaae66060a4b3eecc`.

The deterministic route performs six alternating LOD0 construct/carve edits
in one loaded chunk, then moves both viewers to a cold LOD0 chunk. Trace-on and
trace-off runs use the same three-CPU affinity and runtime policy.

| Measurement | Vulkan | D3D12 |
| --- | ---: | ---: |
| trace-on edit submission maximum | 439 us | 476 us |
| trace-on hot readiness | 6-7 frames, 106.033 ms max | 6-7 frames, 106.507 ms max |
| trace-off edit submission maximum | 448 us | 640 us |
| trace-off hot readiness | 6 frames, 100.017 ms max | 6-8 frames, 132.830 ms max |
| trace-on cold LOD0 readiness | 184.173 ms | 184.144 ms |
| trace-on frame p95 / maximum | 16.713 / 16.796 ms | 16.734 / 18.638 ms |
| journal commit to collision prepared, median | 16.285 ms | 17.450 ms |
| collision prepared to sink applied, median | 65.357 ms | 62.970 ms |
| capture submitted to GPU dispatch, median | 0.490 ms | 0.472 ms |
| GPU dispatch to counter readback, median | 32.452 ms | 32.382 ms |
| readback to prepared, median | 0.190 ms | 0.320 ms |
| activation request to first draw, median | 0.450 ms | 0.490 ms |

Each traced backend records six journal commits, six dirty-page admissions,
seven collision preparations, eight collision sink applications, 18 GPU
captures/preparations/activations, and 12 first draws. No native or downstream
trace events were dropped.

The six edits regenerate 73,728 cells, transfer 1,909,296 packed native bytes
and 1,318,320 arena upload bytes, and read back 240 counter bytes with zero
geometry readback. This confirms that the present hot path still regenerates
and transfers whole chunk surfaces.

The checkpoint passes its observability contract but intentionally does not
claim instant editing. It isolates the next two structural targets:

1. GPU visibility is gated by the approximately 32 ms asynchronous counter
   readback even though activation-to-draw is below 1 ms.
2. Collision preparation finishes in roughly one frame, then waits about four
   more frames for sink publication.

Native debug/release builds and the causal trace, edit replacement, page
meshing, lifecycle, and production streaming suites pass. One release
production-streaming run reported its timing-sensitive runtime-metrics check;
an immediate identical rerun passed with the expected deterministic hash.
Vulkan/D3D12 full-quality edit and rapid-edit regressions pass with LOD0 first
feedback, zero mixed revisions, and the pre-instrumentation five-frame result
restored when tracing is disabled.
