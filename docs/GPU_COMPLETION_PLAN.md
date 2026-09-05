# GPU recovery checkpoint and completion plan

Status: **INCOMPLETE_NOT_QUALIFIED**, 2026-09-05. CPU remains the default.
This checkpoint preserves interrupted work; it does not promote the GPU backend.

## Update after the rerun

Latest authority `65bc583` adds bounded automatic viewer activation, fixing nearby
detail that only advanced after an edit. The GPU launcher uses one asynchronous
mesh worker and continues foreground priorities while visual updates coalesce.
The no-edit relocation, rapid-edit and lifecycle tests pass on Vulkan/D3D12.
The final clean gameplay run still takes 23 frames to first edit feedback and 83
to LOD0, with five blocked steps and frame-time misses. See the
[viewer activation experiments](evidence/gpu_viewer_activation_20260905/RESULT.md).
Instant editing and sustained nonhalting gameplay remain unqualified.

Previous authority `14bb8f0` separates retained coarse edit feedback from refinement.
It waits for the exact edited coarse generation, but releases the wait if that
generation fails, is cancelled/superseded, or leaves the plan. This handles the
baked coarse-page regression that blocked earlier attempts. The focused GPU test
shows coarse feedback in six frames and still reaches LOD0 on Vulkan/D3D12.
Two clean gameplay runs show first visual at 29/25 frames, collision at 1/5, and
zero blocked steps. Exact LOD0 takes 75/85 frames. The existing visual response
and divergence gates still fail. See the latest section of the admission evidence.

The [admission investigation](evidence/gpu_admission_20260905/RESULT.md) pins
`61ff14a` and fixes a demonstrated scheduler stall: GPU capture backpressure no
longer prevents independent sampling/collision work. The regression fails with
the bypass removed and passes with it restored. Clean visual delay is still
47–57 frames; GPU completion remains open. A 32-request pipeline experiment was
reverted after failing to improve latency and worsening frame time/memory.

The latest [rapid-edit fix](evidence/gpu_rapid_edit_20260905/RESULT.md) supersedes
the pin below with `2a5e22a`. Transient cross-chunk revision mismatch is reproduced
on the old candidate and fixed on Vulkan/D3D12. Retained matching seam masks no
longer let half of a pending edit publish independently. The final gameplay route
still misses visual/collision response limits (47/66 frames); GPU is not complete.
One-step refinement was measured and reverted. Preserve atomic edit publication
when addressing latency; do not recover response time by exposing mixed revisions.

The [edit refinement investigation](evidence/gpu_edit_refinement_20260905/RESULT.md)
supersedes the recovery artifact state below. Authority `4682850` and both rebuilt
DLLs now match the runtime pin. Two additional correctness defects are fixed,
native debug/release regressions and Vulkan/D3D12 lifecycle smokes pass. Clean
gameplay still fails: exact detail converges earlier, but first visual and
collision response can worsen. The actual next problem is the edit/refinement
publication dependency, not a demonstrated full scheduler queue. A coarse-visual
activation wait was tested and discarded because it can deadlock refinement.
The earlier recovery identity and candidate plan remain below as history; consult
the investigation before implementing the admission proposal.

## Recovery identity

- Integration parent: `090e394` (optimized page-field packing).
- Companion authority checkpoint: `4578e73` in `world-transvoxel`.
- Recorded runtime pin: `c967998aef5855545f7d841838e916c8430b606f`.
- The preserved **debug DLL does not match the pin**. The release DLL does match
  its pinned SHA-256. Both match the respective upstream working binaries, but
  that comparison does not prove which source produced the debug DLL.
- The native checkpoint preserves the refresh-event requeue classification fix.
  It has not been rebuilt or newly tested during this checkpoint task.
- The integration fixture now supplies `activation_required` for retained
  cohort members and preserves capacity-aware fairness assertions and useful
  failure diagnostics. The production retry capacity remains one.

[The evidence manifest](evidence/gpu_incomplete_checkpoint_20260905/manifest.json)
records actual and pinned binary hashes, checks, report hashes, and selected
measurements. Eleven complete raw JSON reports are archived alongside it as
gzip files; decompression must reproduce the manifest SHA-256.

Generated Godot caches/import sidecars remain outside this commit. Approximately
1.07 GB of older untracked evidence (826 files) remains on disk; its directory
inventory is in the manifest. It is not part of this Git recovery point.

## What is implemented, and what is still failing

The existing GPU path includes field evaluation, regular/transition meshing,
compact resident buffers, terrain/water rendering, and revision-aware atomic
publication. Native authority owns edits, desired sets, identities, and local
CPU collision. Completing GPU does not require moving physics or authority to
the GPU. Production latency, full parity, and release qualification remain open.

The most recent saved results are **diagnostic-only**, including the report
named `exact_control`. Earlier conversational descriptions of these runs as
clean performance controls were too strong. Later candidate reports also
explicitly report that their artifacts do not match the pin.

| Saved run | Pin matches | Commit frames | Collision after commit | First visual after commit | Exact LOD0 after commit | Blocked movement |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| direct LOD0 exact control | yes | 3 | 7 | 21 | 91 | 0/1,020 |
| two retries, repeat 2 | yes | 5 | 9 | 29 | 123 | 1/1,020 |
| isolated requeue fix, run 1 | no | 76 | 7 | 23 | 98 | 0/1,020 |
| isolated requeue fix, run 2 | no | 3 | 8 | 23 | 95 | 0/1,020 |

Every row fails the existing acceptance gate. First visual means the committed
revision is visible at an active LOD with GPU activation acknowledgment; it is
distinct from final LOD0 refinement. These observations help locate delays;
they do not establish a qualified speedup or stable performance distribution.

Checks performed for this recovery point:

- `python tools/run_gpu_activation_retry_fairness_smoke.py`: PASS, Godot 4.7.2,
  at most three CPUs.
- `python tools/validate_terrain_dependency_boundary.py`: PASS.
- `python tools/validate_world_transvoxel_runtime_artifact.py`: FAIL, artifact
  digest drift. This known failure is deliberately preserved, not masked by
  changing the hash to bless an unidentified build.
- Native rebuild/tests and full rendered gameplay qualification: not run.

## Completion sequence

### 1. Establish one reproducible source/binary pair

Add a focused native regression that fills the job queue, requeues
`RefreshEditLodRetention`, and verifies it retains its event classification and
direct-refinement semantics on retry. Include zero/one mesh-worker modes and a
normal viewer update interleaved with the retry. Select whether that correction
is retained based on correctness, separately from any performance claim.

Build debug and release from the exact committed source using at most three
build jobs and the existing build profile. Copy the two binaries and regenerate
all pin trees, sizes, and hashes together. Run native streaming, LOD staging,
edit-retention, collision continuity, and GPU meshing/publication regressions,
plus both integration validators. Only then run comparison workloads.

### 2. Address admission before trying another priority change

The source has an explicit all-batch admission preflight in
`wt_desired_set_runtime.cpp`: available job capacity must cover all added
demands plus role promotions requiring remesh. `WtStreamScheduler::request`
also rejects a full job queue. Raising a queued job's priority cannot create
free slots. This makes admission a concrete next hypothesis, not yet proof of
the entire latency cause or a proven fix.

Use one small deterministic saturation fixture to distinguish time waiting for
admission, native sampling/packing, GPU submission, GPU completion, cohort
readiness, activation acknowledgment, and collision publication. Record the
blocking member's key, LOD, revision, generation, and queue age. Reuse existing
optional tracing; keep it disabled in performance runs.

Preferred candidate: bounded admission reservation for committed-edit work,
with fair background progress. Size the reservation from the legal refinement
batch and transition dependencies, not an arbitrary larger queue. If reserving
space cannot fit every legal batch, design an incremental preparation phase
that keeps the desired/publication transaction atomic. Do not partially apply
the current delta just to bypass its capacity check.

Queued-background preemption is a second option only if cancellation/reissue
preserves generation identity, completion accounting, and progress. Executing
jobs, retained collision support, and sole visible coverage cannot be dropped.
Test repeated edits, cancellation, relocation, multiple viewers, small queue
capacities, and background starvation. Retain the smallest change that passes.

### 3. Prove end-to-end improvement on the same workload

Use the same 2,048 x 256 x 2,048 relocation-and-edit route, pinned binaries,
worker counts, three-CPU affinity, renderer, frame cap, and warmup. Alternate
control/candidate runs at least three times each; report every completed run
and all failures. Separate diagnostic traces from diagnostics-off measurements.

Keep the existing limits: commit, collision, and first visual within 15 frames;
visual/collision divergence at most 8 frames; physics-frame p95 at most 20 ms
and p99 at most 33.3 ms; physics target within 30 frames. Preserve the existing
movement thresholds (at most 20 blocked steps and 10 consecutive) and report
zero blocked steps as the desired result. Name post-draw timings separately;
they are not the physics-frame clock. Exact LOD0 latency remains a separate
reported outcome, never a substitute for first visible edit response.

### 4. Finish parity and lifecycle qualification

Run lifecycle, relocation, moving-LOD, terrain/water/material parity, carve and
construction, repeated edits, and strict final drain on Vulkan and D3D12.
Include rapid relocation and repeated edit/undo scenarios where supported,
transition boundaries, caves, empty surfaces, stale results, and memory pressure.
Require valid surface ownership, no holes or stale publication, no hidden CPU
visual fallback/readback, bounded residency, and correct targeted collision.
Run the CPU control to detect regressions in shared authority code.

### 5. Make release acceptance explicit

After the correctness and latency gates pass, run the supported hardware/API
soak and power checks and perform a human movement/digging/construction review.
Report GPU-board, CPU-package, and whole-system power only when each is actually
measured. Resolve or explicitly scope any remaining authority-suite failure,
including the older M5 wrapper fingerprint issue; do not claim the full suite
passes from a subset. Update the architecture status and release checklist from
that evidence. GPU remains opt-in until those gates are satisfied.

## Avoid repeating rejected work

Coverage-priority tier changes were tested and reverted upstream. Two activation
attempts per frame worsened the saved repeat. Edit-cohort priority runs produced
81 then 117 frames for LOD0 while delaying first visual; they also had mismatched
pins. Forcing retention refresh ahead of all viewer events did not establish an
improvement. These are not useful defaults to retry without new causal evidence.

The practical next implementation unit is **requeue regression plus bounded edit
admission**, followed by exact-binary measurement. Shader rewrites, broad priority
reshuffles, larger retry budgets, or relaxed acceptance thresholds do not follow
from the current evidence.
