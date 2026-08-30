# Reciprocal GPU Publication Checkpoint

Status: `SAMPLED_LOD_PASS_GAMEPLAY_REJECTED`. CPU remains the default.
This is not a release, a human-accepted baseline, or proof of GPU speedup.

## Implemented

Upstream `6f47d4e38ab3fb40ecc78a19fd89d8da65ad7669` now selects reciprocal
GPU boundary dependencies, not just overlapping replacements and dependencies
from coarse transitions toward fine chunks. Refining and coarsening require
compatible masks on both sides. Query and commit use the same native selector;
open viewer plans, missing members, incompatible masks, and capacity overflow
wait rather than publish a partial region. Authoritative overlap coverage and
retirements are retained. Native tests exercise six faces at positive and
negative coordinates, stale/retiring seeds, bounds, and compatible active
neighbors. The overlap-only control reproduces the missing dependency.

An already active neighbor with the required boundary mask does not need to
join an unrelated content-generation backlog. This only satisfies boundary
topology: exact generation/revision and prepared-surface checks remain required
for every newly activated member. The selector shares its hierarchy indexes
within each query. The downstream controller performs one fair activation retry
per frame instead of eight; it does not skip required members or remove guards.

The strict route then exposed a separate downstream lifetime race. A terrain
group was marked retiring before native requests were consumed in the same
frame. Its matching water request could still join the group after retirement
commands had been selected, leaving that water request stranded. The retained
failure identifies group `10:0:6:3:g2035:s190327:w0:t32`, terrain request 2148,
water request 2149, age 1789 frames, and only terrain retired. The controller now
rejects admission to retiring groups. A deterministic test asserts no GPU
submission, exact native rejection, and no mutation of the retiring group.
Bounded retiring-group and oldest-native-request diagnostics expose this state.

No player movement, collision budget, storage policy, default backend, geometry
tolerance, water shader, or observation timeout is changed in this checkpoint.
Native code remains only in world-transvoxel; integration consumes its DLLs.

## Verification

- Native application and GPU shadow tests pass in debug and release. Application
  coverage includes 1,000 stale cycles and 12 reciprocal-face configurations.
- The isolated downstream ordering smoke passes fairness, deduplication,
  in-flight exclusion, strict drain, spatial retirement, selected inventory,
  batched accounting, activation acknowledgment, optional history, retiring
  diagnostics, and late-water rejection.
- Bounded production lifecycle passes on Vulkan and D3D12: terrain/water
  activation, retirement/restoration, CPU collision ownership, zero geometry
  readback, and pre-mesh GPU input. These are not whole-world driver acceptance.
- The headless CPU production-runtime smoke passes with the same debug DLL:
  one render resource, one collision resource, and no debug-scene substitution.
- The Vulkan moving-LOD route passes all 25 samples and strict final drain.
  The previously failing `12_peak_sweep_f054` reports zero isolated environment
  sky pixels in its terrain band; no partial GPU entries occur. Final native
  active/ready counts and tracked/active GPU chunk counts are all 1,219, with
  zero pending replacements, retirements, native requests, or extractions.
- Final native validation rejections are **2**, not zero. Explicit rejection of
  stale/retiring requests is distinct from a rejected terrain chunk; final
  `rejected_chunks` is zero. All retained counters remain available for review.

The final drain takes 321 frames / 19,742.879 ms after movement. This is global
readiness, not edit latency, and it is not an acceptable instant-gameplay result.
Earlier identical routes intermittently drained before the admission fix; those
passes did not disprove the race. The deterministic regression is necessary.

The saved screenshots at samples 12 and 24 were inspected, alongside their
numeric results. Dark roads are not treated as holes. This is a sampled no-gap
test, not an exhaustive mesh-manifold proof, artwork approval, or a water-quality
sign-off. The generic CPU geometry probe is empty/not applicable to this GPU
route. Its false gap flag must not be reported as independent geometry proof.
The original exact failed geometry remains in the
[previous investigation](../tqp64_gpu_runtime_blockers_20260830/RESULT.md).

## Gameplay Still Fails

Godot 4.7.2 Steam tools executable, GTX 1060 Max-Q, Vulkan, G23 2048 x 256 x
2048, production texture arrays, affinity `[0, 1, 2]`, generation workers 2,
meshing override 0, collision radius 2, prediction distance 24. Causal tracing,
stage timing, and lifecycle history are off for the measured gameplay route.

| Metric | Result |
| --- | ---: |
| Post-draw interval p50 / p95 / p99 | 54.937 / 92.380 / 118.926 ms |
| Post-draw interval maximum | 347.243 ms |
| Movement blocked | 641 / 1,020 steps |
| Maximum consecutive blocked steps | 141 |
| Relocated target acquisition | No target within 180 frames / 3,018.225 ms |
| Accepted relocated edit | None |
| Measurement complete / process exit | False / 1 |

`frame_time_ms` p95 74.583 ms and p99 96.039 ms are physics-signal intervals,
not rendered frames. An earlier conversational update mistakenly presented them
as a performance improvement. Use `render_frame_interval_ms` above for post-draw
intervals; those are not GPU execution time or physical presentation latency.

The previous trace-off post-draw p95 was 86.920 ms and movement blocked 569
steps. This new run does **not** establish a performance improvement. Neither
GPU run completes the requested movement/edit workload, so no CPU/GPU speedup
ratio or successful GPU edit latency can be calculated. The failed target
position/chunk are ray-endpoint placeholders, not proof of missing terrain at
that location. No power, release-export gameplay, or hardware-limit claim is made.

## Evidence And Next Work

`checkpoint.json` retains the runtime pin, binary hashes, native test outputs,
raw-file hashes, exact stranded identities, final GPU counters, and drain timing.
`visual_acceptance_streaming_fly.json` retains all 25 sample results; selected
PNGs and raw logs are adjacent. `gameplay_result.json` retains the full rejected
measurement and exact command. The binaries were built from the source tree
now committed as `6f47d4e`; the debug DLL used by these Godot runs matches the
pin. The release DLL is built from the same tree but this is not an exported
release gameplay measurement.

Bounded downstream regressions can be repeated with
`python tools/run_gpu_activation_retry_fairness_smoke.py` and
`python tools/run_gpu_resident_production_lifecycle_smoke.py --driver both`.
The retained commands use the existing strict route limits, not longer waits.

Next, isolate the existing GPU player-support/target-readiness failure. Record
actual queried chunk identities, collision demand, generation, publication,
and queue age at the first blocked movement/failed ray, not just the end-of-ray
placeholder. Distinguish absent demand from a pending result before changing
scheduling. Preserve player support guards and targeted collision. Then remove
the measured bottleneck and complete the same trace-off movement plus carve
and construction workload before comparing CPU/GPU performance. Post-edit LOD,
water, cross-backend gameplay, power, and human acceptance remain open.
