# GPU Publication Query Checkpoint

Status: `MOVING_LOD_PASS_GAMEPLAY_REJECTED`. TQP-64 remains open and GPU remains
opt-in. This is not a smooth-terrain, speedup, power, or human-accepted baseline.

## What Changed

Upstream `611208274b4fd3faedf823071904446f779afc01` delays Godot dictionary
construction until a GPU activation cohort is fully ready. Previously each
query serialized already-ready members, then discarded that partial inventory
if another member was waiting. Native records are retained during validation;
the returned complete identities and activation flags are unchanged.

All generation, reciprocal-mask, authoritative-coverage, readiness, and priority
checks still run. Cohort membership, collision policy, worker counts, queue
budgets, timeouts, shaders, and movement guards are unchanged. CPU stays default.

The first trial replaced the unsafe-retirement scan with neighboring hierarchy
queries. It matched every saved cohort but did not demonstrate a timing benefit,
so it was removed. Production selector code is unchanged. Retained median query
times in `selector_before.json` and `selector_rejected_index.json` were:

| Cohort members | Original, ms | Rejected trial, ms |
| --- | ---: | ---: |
| 280 | 1.698 | 2.361 |
| 106 | 0.743 | 1.245 |
| 263 | 2.185 | 3.239 |
| 327 | 3.931 | 6.324 |

These are isolated development measurements, not calibrated performance limits.
Upstream now retains eight lossless selector fixtures, a replay executable, and
an independent integer all-pairs oracle. The M3 runner checks all eight exact
replacement/retirement/mask-wait sets in debug and release. The replay corpus is
`tests/fixtures/gpu_publication_cohorts_20260830.json` in `world-transvoxel`;
its original source capture hash is preserved. It is not geometry or a full
runtime snapshot.

## Measurements

Godot 4.7.2 Steam, GTX 1060 Max-Q, Vulkan, G23 production materials, affinity
`[0, 1, 2]`, two generation workers, meshing override zero. The existing route,
limits, and acceptance thresholds were not changed.

The optional `--gpu-stage-timing` runner switch exposes the controller's existing
timings. Both timing runs disabled the readiness/publication probes. They are
diagnostic-only; stage timers include nested work and must not be summed as
independent costs.

| Diagnostic measurement | Before | After |
| --- | ---: | ---: |
| Native cohort query calls | 3,282 | 3,133 |
| Cumulative native query time, s | 29.552 | 23.945 |
| Mean native query time, ms | 9.004 | 7.643 |
| Blocked movement steps / 1,020 | 621 | 593 |
| Longest blocked run | 112 | 108 |
| Post-draw p95 / p99, ms | 78.915 / 98.926 | 78.175 / 96.183 |
| Relocated edit accepted | No | No |

The work performed and path achieved differ because movement remains blocked.
These single incomplete runs do not isolate a causal speedup or prove better
gameplay. They do identify substantial remaining CPU publication-query work.
The API change removes discarded serialization by construction; the entire
observed timing difference must not be attributed to it.

The before timing run matched the previous runtime pin. The after timing run
preceded pin finalization: its declared pin is old, actual artifact digest is
`7f599e53a07b1a43c8b8e5e2dec982d108da33d99781efc13261ee3e6d7d1ab0`,
and the debug DLL is the final `c9c7bd74...` build. The release DLL was rebuilt
afterward. Final synchronized artifact:
`22394a2dac566596a9579642639d57b8747f31b3b8d54da941cd1ed0a9ef95e5`.

## Verification

- Debug/release publication oracle: 250 random and 30 coordinate-limit cases.
- Debug/release eight captured selector replays: exact outputs.
- Debug/release M3 application, GPU shadow, and production streaming: pass.
- Streaming hash unchanged:
  `39db05c67fc2f4b8d8beaab2e7da927ae968efb3d75118bcd80c5523116d9b3b`.
- Vulkan/D3D12 bounded lifecycle: pass, including exact live-cohort identity and
  retained activation flag, empty stale response, water, CPU collision authority,
  and zero geometry readback. These checks are not whole-world qualification.
- Activation fairness smoke and binary/dependency boundary: pass.
- Moving-LOD gate: 25 samples, zero reported visual/coverage/geometry/partial
  GPU failures; maximum 303 replacements, 718 retirements, 246 jobs. Final drain
  304 frames / 19,196.278 ms; all 1,219 chunks ready and all publication queues zero.

The retained peak-sweep and low-slope pictures were inspected at original
resolution. They show hard material boundaries and dark procedural roads, with
no visible open seam in these views. This is not material-quality acceptance.

The final exact-pinned run disabled stage timing and both readiness probes. It
still fails gameplay acceptance: 544/1,020 movement steps blocked, longest block
172 steps, post-draw p95/p99 76.639/97.665 ms. Physics-signal p95/p99 is separately
62.757/78.275 ms. No target was available after 3,007.569 ms; the edit was not
accepted, so edit latency is censored, not zero. Publication rejection and
application wait expiration are both zero. Compared with the preceding 602
blocked steps / longest 112, fewer blocked steps but a longer maximum stall is
not a qualified movement improvement.

## Next

The GPU geometry path is operating, but timely publication and destination
physical readiness remain unresolved. Isolate the remaining native query cost
into selection, authoritative coverage, record/sink readiness, and priority
handling before changing dependency evaluation. Preserve every required member
and avoid repeated unchanged work only with an explicit invalidation contract.
Then re-run the unchanged movement/edit gate. Do not remove movement guards,
extend waits, or call an unaccepted edit a performance success. Post-edit
geometry, cross-backend gameplay, power, and human acceptance remain release
gates; this checkpoint does not justify asking the user to accept GPU gameplay.
