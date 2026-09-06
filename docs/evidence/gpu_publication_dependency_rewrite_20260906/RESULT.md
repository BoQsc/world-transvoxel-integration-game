# Native publication dependency rewrite: integration result

Status: INCOMPLETE_NOT_QUALIFIED. User-authorized subsystem replacement began
after game checkpoint `6271af5`, with native baseline `674ecc3`.
Installed authority: `c1447defaef9987d8b79bc04331b34c1efe13449`.
Artifact digest: `97597fbe098dba4de5cb4f59ba4ece6ccca90f16cccea658cc3c443ded871fb5`.

## Replacement architecture

Native publication closure now uses immutable integer AABB indexes and directed
dependency traversal. Each selected replacement or retirement is expanded once.
The GPU session retains spatial indexes while exact membership is unchanged;
only changed membership invalidates its index. Readiness, generation tokens,
active content and transition masks are always read from current authoritative
state. Complete coverage, 2:1 boundaries, collision guards and atomic swaps are
preserved. The native charter documents this performance model.

The first prototype rebuilt indexes per query and made larger cases slower.
Retaining unchanged indexes fixed that structural cost. In the 4,096-retirement
fixture, median repeated-query time changed from 730.8 us to 68.5 us, with
identical selected chunks, retirements and seam waits. At 64 entries the results
were 67.8 us and 71.4 us; small cases show no established improvement. Warm
measurements exclude initial index construction. Both prototype and final
measurements are retained here.

## Correctness checks

- Independent integer all-pairs reference: 250 randomized layouts and coordinate
  limits; coverage: 180 partitions, three authority predicates, six mutations.
- Eight local queries among 4,096 retirements test 32 keys versus 32,768
  all-pairs checks. One hundred unchanged updates reuse indexes. Replacement
  and retirement invalidation are isolated. 128 changing mask/readiness states
  produce the same results with retained and fresh indexes.
- Seven native suites pass in debug and release. Full builds complete without
  compiler warnings; exact binary provenance validation passes.
- Twelve rapid cross-chunk edits: Vulkan 63 observed frames, D3D12 61, zero
  mixed visible revisions.
- Automatic detail with zero edits: Vulkan 21/12/15 frames, D3D12 21/12/14,
  across initial view and two relocations.
- Production terrain/water lifecycle, materials and shutdown restoration pass
  on both backends. Geometry remains GPU-resident; CPU collision authority stays.
- Cold coarse-edit feedback: Vulkan six frames (~116 ms), D3D12 five (~100 ms),
  followed by successful exact refinement. This isolated latency is not solved.

## Diagnostics-off gameplay

Same 1,020-step route, three CPU affinity, two procedural workers and one mesh
worker verified from runtime telemetry. One run per configuration, not a
statistically established improvement or long-session soak. Thresholds unchanged.

| Native | Commit frames | First visual after commit | Exact LOD0 | Collision after commit | Blocked steps | p95 / p99 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `674ecc3` | 4 | 10 | 89 | 7 | 7 | 38.603 / 56.855 |
| `c1447de` | 4 | 7 | 63 | 2 | 8 | 23.006 / 32.592 |

Both found the collision edit target without waiting. The rewrite run passes
the existing p99, movement, target and edit gates, but fails p95 (23.006 ms versus
20 ms). Eight blocked movement steps and 63-frame exact detail remain contrary
to the user's instant/nonhalting objective. No hardware limit is established.
The consumer remains an opt-in GPU candidate. Remaining work concerns initial
GPU completion/publication latency, exact-detail completion and sustained frame
cost, rather than changing terrain authority or pre-generating the world.
