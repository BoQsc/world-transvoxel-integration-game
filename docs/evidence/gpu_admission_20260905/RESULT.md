# GPU admission investigation — 2026-09-05

Status: independent-work stall fixed; digging/construction latency remains open.

Authority `64b7b87` allows sampling and collision-only jobs to proceed when the
highest-priority visual mesh cannot reserve GPU capture slots. Blocked jobs stay
queued, retaining their priority, generation, and sequence. A full asynchronous
mesh queue similarly permits sampling. Filtered dequeue reports the actual
number of queued jobs ahead, rather than claiming it removed the queue head.

The runtime regression holds both GPU capture slots, promotes the blocked visual
job above independent collision work, and requires collision publication before
releasing the slots. It then requires the original visual generation to resume
without redundant remeshing. Removing the bypass fails in both 0/1 mesh-worker
configurations; restoring it passes. Seven native suites pass in debug/release.
Rapid edits retain atomic visible revisions on Vulkan/D3D12.

Final authority `61ff14a` contains the admission fix after reverting a larger
pipeline experiment. Both final DLLs are byte-identical to the measured `64b7b87`
build (combined artifact digest `781ae2d11256adf563b282674bffba92ad471cdb73a41a6a0ee8662e3d8dc0d4`).

| Run | Commit frames | Collision after commit | First visual after commit | Physics p95 ms |
| --- | ---: | ---: | ---: | ---: |
| gpu_delay_diagnostic_20260905 | 1 | 163 | 159 | 89.946 |
| gpu_admission_bypass_run1_20260905 | 5 | 1 | 57 | 17.755 |
| gpu_admission_bypass_run2_20260905 | 4 | 49 | 47 | 18.187 |
| gpu_pipeline32_run2_20260905 | 4 | 4 | 49 | 22.024 |

The diagnostic row is not performance evidence. Every clean run has zero blocked
movement steps, but none meets the full acceptance gate. Collision varies from
1 to 49 frames with the admission fix; first visual remains 47–57 frames. The
change fixes a demonstrated stall, not the entire reported delay.

The bounded 32-request experiment keeps eight submissions per frame but raises
scratch allocation from about 53 MB to 96 MB. Its first visual is still 49 frames,
and physics p95 rises to 22.024 ms. It is reverted in both repositories. The first
attempt failed startup because another native limit was still 16; it produced
no completed measurement and is not counted as performance evidence.

The diagnostic target prepares in three GPU frames after capture submission,
then waits for a 94-member refinement cohort. Existing same-key collision can
also wait for that visual swap. Preparing the interaction neighborhood before
the first edit, or separating edit-content publication from later refinement
without breaking seam and generation ownership, requires further design and
verification. Do not weaken atomic publication or raise queues again without
new evidence. CPU remains default; GPU is not qualified.

## Retained content before refinement

Final authority 14bb8f0 waits for the exact edited generation of an already
visible coarse chunk before starting synthetic edit refinement. Failed, cancelled,
superseded, or removed generations release the guard. The focused baked test
exposed a failed coarse remesh, explaining the earlier circular-wait attempts;
failed-generation recovery makes that test pass. --bounded-edit runs it alone.

The focused GPU test fails on the admission-only build because its first edited
coverage is LOD0. The final build shows edited LOD2 in six frames on Vulkan and
D3D12, then reaches LOD0. Rapid 12-edit atomicity tests pass on both renderers.
Seven native suites pass in debug/release; see content_first_native_tests.json.

| Run | Commit | Collision | First visual | Exact LOD0 | Divergence |
| --- | ---: | ---: | ---: | ---: | ---: |
| gpu_content_first_run1_20260905 | 5 | 1 | 29 | 75 | 28 |
| gpu_content_first_run2_20260905 | 5 | 5 | 25 | 85 | 20 |

All times above are frames. Both clean runs have zero blocked movement; physics
p95 is 19.113/19.887 ms. Visual response and divergence still fail the unchanged
gates. Early feedback improves, while exact refinement is slower; this is not
a completed GPU backend or a claim of consistently responsive rapid digging.
