# GPU Live Boundary Mask Checkpoint

Status: `MOVING_LOD_PASS_GAMEPLAY_REJECTED`. CPU remains the default. These are
narrow publication corrections, not GPU completion or a human-accepted
baseline.

## Finding And Change

The first blocked support chunk in the unchanged G23 route was
`(22, 2, 21), LOD0`, frame 136 of normal outbound movement. Its GPU visual was
prepared, but the native selector required 280 replacements and 30 retirements,
with 53 unresolved boundary masks. This is a snapshot of that specific support
chunk's cohort, not the globally last activation wait from another chunk.

An application expectation resets its successor's visual mask to zero before
that mesh exists. The renderer may still have an active nonzero transition
mask. Comparing the live mesh against this unset zero introduced false boundary
dependencies. Upstream `d35419985feecc2392fb3556cf0a6fbaa9f98a0e` uses the
complete live mask while the candidate mask is unknown. A known candidate mask
still takes precedence. Reciprocal-face validation, overlap coverage, exact
generation checks for newly activated meshes, and collision guards remain.
No shaders, movement rules, scheduler priorities, worker counts, collision
budgets, or test limits changed.

The corrected moving-LOD route then exposed a separate stale handoff. Native
streaming correctly discarded a completed mesh when its transition mask no
longer matched the current LOD plan and queued a replacement, but it did not
tell the GPU controller that the old visual generation was obsolete. The
controller waited 180 frames for a CPU application placeholder that was
intentionally never published. Upstream
`7bfa83f68afa756972fc22ed24a6cad1e8ba3907` now explicitly supersedes that
exact visual generation. Superseded payloads cannot reach the render sink or
be marked externally prepared, and the next generation starts clean. This is
not a timeout increase and does not supersede collision state.

The live-mask native regression failed in all 12 positive/negative coordinate
and face combinations before correction, then passed in debug and release. It
also checks that a known incompatible successor does not bypass validation.
The stale-generation regression proves exact, idempotent supersession, no
render-sink publication, no external preparation, and clean successor state.
Production-streaming and GPU-shadow tests pass in both builds. The existing
streaming hash remains
`39db05c67fc2f4b8d8beaab2e7da927ae968efb3d75118bcd80c5523116d9b3b`.
This CPU hash is not an independent GPU geometry proof.

## Optional Inspection

`inspect_gpu_resident_publication(coordinate, lod)` records the actual selector
inputs and successful boundary lookups, selected keys, retirements, and mask
waits. It does not request priority, activate meshes, or read GPU buffers.
The existing 4,096-member selector cap still applies. A failed build is not a
complete graph. Normal gameplay does not call this diagnostic.

Run `python tools/run_runtime_readiness_probe.py --backend gpu
--publication-probe --output .godot/new_capture.json` for an explicit capture.
The probe takes at most one publication snapshot per route phase, within its
existing 96-sample bound. The runner now records the actual runtime artifact
digest separately from the declared pin, so an unpinned development DLL cannot
be mistaken for the pinned binary.

Both initial diagnostic captures preceded pin finalization and carry the old
declared pin in their raw JSON. Their actual synchronized artifact digests were
`764a7a8d70d5f8660b7f3e0c8b17989e1a36b8630d7685f0c9e02ddedb79e550`
(inspection only) and
`6175cd2ab7d4065caa5218eca1f9e36f33ca538182ab31bd39ea9cac341b5bc1`
(live-mask correction, before release DLL/document synchronization).
They are diagnostic evidence, not pinned performance baselines.

Those captures still selected a stale last-movement support key for the edit
phase after teleportation. Do not interpret that edit-phase publication graph
as the destination ray's dependency graph. The final probe filters edit-phase
selection to actual ray-intersected keys. Movement-phase graphs are unaffected.

## Results So Far

Godot 4.7.2 Steam, GTX 1060 Max-Q, Vulkan, G23, production materials,
affinity `[0, 1, 2]`, generation workers 2, meshing override 0.

| Diagnostic route | Before correction | After correction |
| --- | ---: | ---: |
| Blocked movement steps / 1,020 | 598 | 517 |
| Longest blocked run | 97 | 93 |
| Post-draw p95 / p99, ms | 81.334 / 99.800 | 81.296 / 102.238 |
| Relocated edit accepted | No | No |
| First support cohort members | 280 | 280 |
| First support unresolved masks | 53 | 51 |

The after-correction graph exercised 12 lookups where an unknown candidate
mask differed from a retained live mask. It did not eliminate the broad
dependency group. Capture overhead reached 31.403 ms before and 37.074 ms after.
These single, incomplete, instrumented routes do not prove a performance
improvement, a CPU/GPU speedup, or a hardware limit. Both fail acceptance.

Bounded production lifecycle passes on Vulkan and D3D12, including terrain,
water, CPU collision ownership, no geometry readback, and repeated inspection
with unchanged native metrics and results. Whole-world driver acceptance and
human visual acceptance are not established by that smoke test.

## Final Moving-LOD Result

The unchanged 25-sample moving-LOD route passes after both corrections:

- zero visual, coverage, geometry, or partial-GPU-geometry failures;
- zero fatal publication rejections and zero missing retirement records;
- maximum 304 non-retiring visual deficit / pending replacements;
- maximum 716 pending retirements and 246 scheduler jobs;
- final convergence in 320 frames / 20,954.072 ms;
- final 1,219 active, visual-ready, and fully-ready chunks with all queues,
  replacements, retirements, and staged render resources at zero.

The selected peak-sweep and low-slope frames were inspected at original
resolution. They show the generated dark road bands and hard material regions,
but no open terrain, sawtooth seam, or sky-through publication gap. Those
material boundaries are not treated as proof of visual quality.

## Probe-Off Gameplay Result

The final exact-pinned route ran with publication inspection disabled. Runtime
artifact `9229d38c27d046aab2b30095609b6b3f9fdb05aa85b30bddb5b9704bd7a43fa7`
matched its declaration. It still fails gameplay acceptance:

| Metric | Final result |
| --- | ---: |
| Blocked movement steps / 1,020 | 602 |
| Longest blocked run | 112 |
| Physics-signal p95 / p99, ms | 62.425 / 84.331 |
| Relocated collision-target wait | 3,025.871 ms, censored |
| Relocated edit accepted | No |
| Publication rejections / application wait expirations | 0 / 0 |

This separates the two corrected metadata defects from the remaining
throughput problem. It does not support a smooth-terrain, speedup, or GPU
completion claim.

## Remaining Work

The next blocker is timely production and retirement of coherent moving LOD
regions, followed by physical readiness at the relocation destination. The
recorded 280-member support cohort and the final route's 304 replacements / 716
retirements are the concrete next investigation targets. Separate necessary
reciprocal and coverage dependencies from avoidable cohort work using the
captured identities. Do not drop boundary members, relax collision readiness,
or permit unsupported movement to make timing pass. A completed, unchanged
movement/edit route is required before any claim of smooth GPU terrain or
speedup.
