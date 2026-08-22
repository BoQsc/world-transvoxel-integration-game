# CPU-B3D Regional Prewarm Rejection

This A/B experiment tested proactive regional visibility prioritization after a
frontend viewer plan drained. It preserved the desired set and atomic regional
publication rule, but it promoted every unfinished member of every complete
publication region to interactive-edit priority.

## Result

- Carve visibility waiting fell from 2987.3597 ms to 784.7132 ms, while total
  carve completion fell from 4541.5981 ms to 4128.0099 ms.
- Construction visibility waiting fell from 4289.3048 ms to 1424.0058 ms, but
  total construction completion increased from 4384.9491 ms to 4605.2606 ms.
- Blocked flight frames increased from 0 to 150 and trace-on hitches increased
  from 8 to 15. Frame p99 was effectively unchanged at 33.24904 ms.
- The route issued 260 prewarm batches containing 2283 requests. This is not a
  bounded relocation prewarm operation.
- The carve publication retained exact latest-drained-plan ownership evidence.
  The construction publication did not retain its desired snapshot, so that
  candidate run cannot make the same exact-ownership claim as the baseline.

## Decision

Reject the candidate. Faster post-edit publication does not justify movement
blocking, repeated broad interactive-priority traffic, or weaker diagnostic
evidence. Authority commit `095afe05eeb4361ebc65877e519b711247f12e18` was
reverted by `72cfb30`; the integration project remains pinned to the qualified
CPU-B3C authority and runtime artifacts.

Do not repeat this design by triggering broad interactive priority at every
drained viewer plan. Any future scheduling experiment must be independently
bounded, must not borrow interactive-edit priority for a whole visibility
region, and must pass zero-blocked-movement and exact-ownership gates.

The local candidate trace and report remain under
`.godot/world_transvoxel_captures/terrain_waterfall/regional_prewarm_candidate_*`
and are intentionally not versioned.
