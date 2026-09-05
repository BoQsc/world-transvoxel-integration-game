# GPU rapid edit publication fix — 2026-09-05

Status: cross-chunk rapid-edit regression fixed; GPU gameplay remains unqualified.

The user reported transient terrain shards while rapidly carving and constructing
with the GPU candidate launcher. A new bounded test reproduces a publication
defect on authority `6ea3e35`: after seven frames, two adjacent visible chunks
straddling the same brush have world revisions `[1, 0]`. See `before_vulkan.log`.

Matching transition masks previously allowed independent content replacement,
even when a neighboring edit replacement was still preparing. Authority `c29f1cb`
marks retained content incompatible while its edit generation is pending. The
existing reciprocal boundary closure then selects adjacent edited chunks in the
same atomic cohort. Unchanged neighbors do not expand that edit component.
Inspection exposes `edit_pending` and `active_content_current` for diagnosis.
Native regression covers either edited half becoming ready first, both with a
known candidate mask and with only an expectation. Generation, surface, mask,
retirement, and collision readiness checks remain in force.

Final exact debug/release build: `2a5e22aeefbdd57e56bab80e0ce1a5b8f67b3f88`.
The test performs 12 alternating carve/construction edits across x=16, submits
after commit without waiting for visuals, checks visible revisions every frame,
and requires final revision 12 on both chunks. Vulkan and D3D12 pass with zero
mixed revisions. This directly fixes the reproduced defect; it is not proof
that every possible terrain artifact has been eliminated. Captures are final
settled images, while the regression assertions cover intermediate frames.

Seven native suites pass in debug/release (see `native_tests.json`). Production
terrain/water lifecycle passes on Vulkan/D3D12 on `c29f1cb`; the final source
reverts only the separate refinement experiment. The dependency boundary passes.

The edit-only coarsening fix `e6a8119` stays. Progressive refinement `6ea3e35`
was tested and reverted by `2a5e22a`: it did not meet response limits and delayed
exact LOD0 convergence. No latency threshold has been relaxed. All reports below
are diagnostics-off, with matching artifact pins and three-CPU affinity.

| Run | Commit frames | Collision after commit | First visual | Exact LOD0 | Divergence | Physics p95 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| gpu_edit_only_cohort_run1_20260905 | 4 | 4 | 54 | 54 | 50 | 17.507 |
| gpu_progressive_refinement_20260905 | 5 | 4 | 50 | 118 | 46 | 22.944 |
| gpu_atomic_edit_cohort_20260905 | 4 | 89 | 40 | 88 | 49 | 17.26 |
| gpu_final_atomic_edit_20260905 | 4 | 66 | 47 | 47 | 19 | 18.19 |

The final route still misses acceptance; see the raw report and manifest for
every failure. CPU remains default and GPU remains opt-in. Remaining work is
edit/refinement latency, wider moving-LOD and rapid-edit coverage, and supported
hardware qualification. This commit makes no GPU completion claim.
