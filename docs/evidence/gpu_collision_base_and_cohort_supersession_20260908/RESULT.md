# Collision base and committed-cohort supersession checkpoint

Native authority: `1d10d7862395b7a24bfb841c48c3a481e1dc79fd`

Runtime artifact digest: `345f949f73b8c1c464839942642878fca9f9f5a081d33f9208922ca64133f6f7`

## Correctness result

- Finite procedural edge parents now refine through their declared in-world children. The moving visual viewer commits revision 13 at the outbound endpoint and revision 25 after returning on both APIs.
- A collision key without a cached complete shape receives one full authoritative CPU collision base before later edits use block patches. Before this change the outbound route never settled and recorded 7 outbound / 20 final physics-sink failures. Both retained runs record zero sink failures, zero pending chunk retirements, and resolve every collision target.
- A GPU activation cohort superseded after native atomic commit stays alive until every rendering-device activation callback arrives. The previous D3D12 route failed closed with `GPU activation cohort lost a committed chunk`; the retained D3D12 and Vulkan routes both complete.
- The focused state-machine smoke now reproduces supersession between native commit and callback completion. It verifies that both cohort members remain addressable, activate together, and only then enter normal retirement.
- Both routes retain zero geometry readback and production material parity.

## Retained route measurements

| API | Edits | Cold outbound settle | Cached return settle | Collision-pending frames | Visual-gap frames | Frame p95 | Frame p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Vulkan | 11/12 | 32 frames / 935.156 ms | 2 frames / 73.897 ms | 34 | 19 | 34.182 ms | 100.986 ms |
| D3D12 | 11/12 | 43 frames / 1182.876 ms | 2 frames / 69.628 ms | 31 | 16 | 31.058 ms | 81.197 ms |

The checkpoint fixes the permanent collision-pending trap and the committed-cohort lifetime race. It does not meet the instant-terrain contract: uncached movement still takes roughly one second, one of twelve overlapping edits is rejected, collision has pending frames, visual coverage gaps remain, and frame-time gates fail.

## Verification

- Native Debug and Release `test_wt_production_streaming`: pass.
- Native Debug and Release `test_wt_production_lod_streaming`: pass.
- `python tools/run_gpu_activation_retry_fairness_smoke.py`: pass, including `committed_cohort_supersession=1`.
- `python tools/run_gpu_moving_road_stress.py --driver vulkan`: completes with all visual and collision targets resolved.
- `python tools/run_gpu_moving_road_stress.py --driver d3d12`: completes with all visual and collision targets resolved.

Raw retained reports are beside this file: `vulkan.json`, `vulkan_usage.json`, `d3d12.json`, and `d3d12_usage.json`.

## Next checkpoint

Coalesce moving-shell visual plans to the latest viewer revision, prewarm the velocity-projected interaction shell, and eliminate overlapping edit base-revision rejection. Measure each removal against cold outbound latency, collision-pending frames, edit acceptance, and terrain-attributed frame time.
