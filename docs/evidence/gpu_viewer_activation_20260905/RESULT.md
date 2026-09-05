# Automatic nearby GPU detail and mesh scheduling

Status: INCOMPLETE_NOT_QUALIFIED. Native authority is `65bc583d9ad29f2bf69f784aea10973ea459bba8`.
Runtime digest: `028f08fba94d5ad9afdbecc66d8cca7c26355487c5c674f0ff68981665a6c391`.

The GPU integration disabled autonomous background LOD activation. A bounded
four-by-four-by-four chunk test never reached LOD0 after 300 frames without an
edit on the previous configuration. Simply enabling all background activation
fixed that test but introduced 77 blocked movement frames on the gameplay route.

The retained policy enables native viewer activation for the viewer's center and
six face neighbors, independently of distant background refinement. Existing
target demand, generation readiness, balancing and atomic publication still
apply. Obsolete detail can coarsen, while direct edit refinement keeps its
content-first policy. The GPU launcher uses one asynchronous mesh worker, with
two procedural workers. CPU defaults and the world detail radius are unchanged.
Foreground priority updates now continue when visual movement updates coalesce.

## Bounded proofs

- No-edit viewer activation and two relocations: Vulkan 21/12/14 frames;
  D3D12 21/11/11. World revision remains zero.
- Twelve rapid cross-chunk edits: 61 checked frames and no mixed revisions on
  both drivers. This tests publication integrity, not a long gameplay soak.
- Retained coarse edit feedback: six frames after commit, then successful LOD0
  refinement, both drivers. This fixture explicitly disables viewer activation
  to preserve the coarse starting condition.
- Terrain/water production lifecycle, materials, shutdown and zero geometry
  readback: pass on both drivers.
- Seven native regression suites pass in debug and release; native default
  configuration also passes in both. The planner regression checks that bounded
  viewer activation coarsens obsolete detail without activating distant detail.
- The interaction-demand test verifies foreground priorities are updated during
  visual coalescing; 4,620 ray coverage samples also pass.

## Clean gameplay experiments

All use the unchanged 1,020-step route, three CPU affinity, and no diagnostic
capture. Compressed complete reports and `summary.json` retain failures.

| Policy | Commit | Collision | First visual | LOD0 | Blocked steps | p95 / p99 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| All background | 1 | 3 | 12 | 58 | 77 | 29.755 / 41.282 |
| All background, radius 1 | 3 | 4 | 12 | 76 | 35 | 31.247 / 43.124 |
| Bounded viewer, synchronous mesh | 1 | 3 | 11 | 68 | 39 | 26.254 / 36.484 |
| Bounded viewer, one mesh worker | 3 | 4 | 10 | 65 | 0 | 20.980 / 28.007 |
| Also one procedural worker | 5 | 4 | 17 | 96 | 4 | 22.956 / 34.380 |
| Final: two procedural workers, live priorities | 5 | 1 | 23 | 83 | 5 | 25.912 / 36.767 |

Collision/visual/LOD0 columns are frames after commit. These are different
configurations, not repeat measurements of a single final configuration. Removing
the visual coalescing gate also regressed to 155 blocked steps. Unrestricted
background activation, the radius reduction, gate removal, and procedural-worker
reduction were reverted. One asynchronous mesh worker is retained. The latest
configuration still fails frame-time, visual response and divergence limits.

## Remaining work

Automatic nearby detail no longer depends on digging. This is not evidence of
instant edits or sustained nonhalting gameplay. The exact detail delay and
performance variability remain unresolved; no hardware-limit claim is justified.
The next bounded investigation should separate priority-update cost, support
collision availability and GPU cohort closure during one cold edit and a burst
while LOD refinement is in flight. Avoid repeating the full route until a focused
experiment identifies a specific improvement. Rendering already uses compute
extraction; CPU collision authority remains in place.
