# GPU visibility-priority isolation checkpoint

This game pin consumes native commit
1d01cc0500414210a50e11eadd3fc8b286568ccb with runtime artifact digest
67b6101b8146049c8d23b9a3dcae794187f448c22ef9afe6218cbe6714b306bd.

Regional visibility coverage now uses a priority below interaction focus and
never enters the committed-edit mesh lane. Promotion is monotonic, so exact
edit work already at the maximum keeps that priority. The focused native
production regression passed in debug and release, as did page-meshing and
workload regressions.

The Vulkan traced route queued zero unrelated maximum-priority jobs around both
relocated edits, versus 99 and 82 unique jobs at the preceding checkpoint.
Blocked movement fell from 124 to 28 frames and maximum relocated-edit pipeline
time fell from 4017.0 ms to 2533.3 ms. The D3D12 focused route retained a 442 us
maximum submission time, 28.5 ms maximum hot first draw, and 83.7 ms cold ready
time.

The remaining delay is a publication-graph dependency: one- and two-chunk edit
cohorts waited on broad regional LOD publications. This checkpoint isolates the
reserved lane but does not meet the final instant-edit gates.
