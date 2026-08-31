# TQP-64 Explicit Collision Locality

Date: 2026-08-31

Status: `COLLISION_LOCALITY_FIXED_GPU_QUALIFICATION_REJECTED`

## Retained Change

Authority: `world-transvoxel` `2a7a7873844eec72b4007cb67948198a1d3088ba`.
Runtime artifact: `8e6fb9ee8a377bd24213dadfa0bbd3f406049fe9038052952f4979f61bf0ad20`.
Both DLLs use the repository's normal build profile. Native source remains
upstream; this game consumes binaries and reference files only.

GPU visual chunks do not publish CPU render triangles. CPU topology remains
available for locally demanded Godot physics. Previously, visual retirement
could promote a formerly collidable, now visual-only chunk back to collision
demand and rebuild its cached regular collision triangles. With explicit local
collision viewers, that promotion is now skipped. Existing required collision
and the legacy broad visual-collision mode keep their prior safe handover.

Visual LOD selection, global coarse coverage, edit/cave retention, transition
masks, terrain/water shaders, atomic activation, player guards, and CPU-default
mode are unchanged. No GPU geometry readback or fallback was added. The API
documentation now distinguishes omitted CPU visual meshes from CPU triangles
still needed by local physics.

## Isolated Proof

The upstream `--collision-locality` regression moves physical demand first and
visual demand second. This leaves real cached CPU geometry in the outgoing
page, including under GPU rendering. Before the fix, the GPU case republished
512 collision triangles outside its explicit physical demand. After the fix it
publishes none there, while the new support page still supplies 512 triangles.

Zero and one mesh-worker variants pass in debug and release. CPU visuals with
explicit collision requests also avoid the unnecessary promotion. The legacy
broad-collision control still publishes its original 1,024 outgoing triangles.
The upstream evidence retains the failing-before and passing-after logs.

Additional passing checks: full native production-streaming regression,
publication/coverage oracle, M3 collision/application regression, player
footprint/dual-invoker guard smoke, GPU retry/admission fairness, Vulkan/D3D12
production terrain/water lifecycle, runtime artifact validation, and dependency
boundary validation. These are focused checks, not full-suite certification or
a new human acceptance. The inherited M5 wrapper fingerprint remains open.

## Diagnostics-Off Gameplay

Godot 4.7.2, NVIDIA GTX 1060 Max-Q, Vulkan, logical CPU affinity `[0, 1, 2]`, two
procedural workers and zero dedicated mesh workers. The route, timeouts, local
collision radius/prediction, and eight-submission controller limit are unchanged.

- Blocked movement: 501 / 1,020 steps; longest consecutive block: 123 steps.
- Post-draw interval p50/p95/p99: 26.243 / 52.613 / 85.868 ms.
- Physics-signal interval p95/p99: 42.161 / 74.543 ms, not rendered-frame timing.
- Relocated physics target: absent after 180 frames / 3,035.671 ms.
- Edit not accepted; measurement incomplete and existing acceptance rejected.
- Process wall time: 47.863 s; process CPU time: 75.891 s; average active cores:
  1.586. These cover the process run, not GPU power or isolated meshing time.

The preceding pinned run recorded 503 blocked steps and post-draw p95/p99 of
51.303/91.284 ms. These single incomplete runs do not establish a gameplay
speedup. The local collision defect is fixed; the larger prepared-geometry to
activation dependency is not. Do not reinterpret this as a completed GPU
baseline, collision-free GPU physics, or an accepted performance result.

## Moving LOD Coverage

The unchanged moving-LOD route saved all 25 views with zero sampled gap
failures. The peak-sweep and low-slope captures were also inspected; neither
shows an obvious opening. Authored road strips are not treated as holes.
Topology probing is disabled in this gate, so this is sampled coverage only.

The complete gate nevertheless **fails**. At final-wait frame 134, two
previously prepared and native-validated terrain requests had expired while
waiting for their CPU application record:

| Page / LOD | Generation | Transition mask | Result |
| --- | ---: | ---: | --- |
| (20, 1, 19) / 2 | 2030 | 1 | CPU-application wait expired |
| (20, 1, 18) / 2 | 2026 | 1 | CPU-application wait expired |

Both requests have source revision 190327 and world revision 0. The native
readiness error identifies a missing application record, not missing CPU render
triangles. The final summary reports 1,219 active/fully-ready records, zero
collision resources at this elevated camera, and zero pending native
replacements/retirements or scheduler jobs. Those counters do not erase the
two cumulative controller rejections. There is no successful final-drain time
for this run and no zero-error moving-LOD certification.

The previous artifact's retained route passed. This single failing run does not
establish whether the collision-locality change exposed a timing-dependent
lifecycle defect or caused a regression. That attribution remains open. The
missing-record lifecycle needs an isolated reproduction that distinguishes
cancelled generations from genuinely pending application work; extending the
timeout or suppressing the rejection is not a fix.

## Retained Evidence

`retained_evidence.zip` preserves the original gameplay report and stdout/stderr,
the moving-LOD runner stdout and 25-sample JSON, two inspected project captures,
and focused downstream test logs. The moving-LOD Python wrapper raised on
Godot's nonzero exit, so it did not return a successful parsed summary; the
game-written JSON and fatal-rejection stdout are retained instead. Its stderr
was displayed by the wrapper, not redirected into the retained stdout log.

`evidence_manifest.json` records each archived file's source, size and SHA-256,
plus the archive digest, exact authority pin, and explicit rejected outcomes.
The archive is checked against those original bytes before this checkpoint is
committed. Historical evidence is unchanged. No new human acceptance or release
label is attached to this candidate.
