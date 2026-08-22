# CPU-B3E Bounded Relocation Prewarm Rejection

This A/B experiment replaced the rejected broad viewer-plan prewarm with an
explicit relocation request capped at 16 records. The API was disabled by
default and was called only by the deterministic terrain-waterfall route.

## Result

- Both the feature-off control and feature-on candidate completed the long
  flight, relocated carve, and relocated construction route with complete
  traces, exact desired ownership, and zero blocked movement frames.
- Two accepted relocation requests produced two attempts, one batch, 16
  records, and no coalescing. The bounded-work contract held.
- The first request produced no priority batch. The second batch was emitted
  about 53.7 ms after edit submission, so it was not pre-edit warming.
- Candidate frame p99 increased from 33.15823 ms to 63.42854 ms and trace-on
  hitches increased from 9 to 34.
- Carve completion fell from 4871.2972 ms to 4242.2395 ms and construction
  completion fell from 4913.5745 ms to 4032.3858 ms. These single-run changes
  cannot be attributed to pre-edit warming because its causal-order condition
  failed.

## Decision

Reject the candidate. Bounded work alone is insufficient: the operation must
occur before the edit it is intended to help and must not regress frame-time
stability. Authority commit `b5da1f3e9fcd301401963fd17449747ef385ca10`
was reverted by `91f3056`. Integration commit `7f6ba78` was reverted by
`653953e`, restoring the accepted `72cfb30` runtime artifact.

Do not reintroduce this API unchanged. A future relocation experiment must
derive its target from current relocation demand early enough to precede the
edit, retain the 16-record bound, preserve zero blocked movement and exact
ownership, and keep frame p99 within 10 percent of a same-build control.

The local control and candidate traces remain under
`.godot/world_transvoxel_captures/terrain_waterfall/bounded_relocation_prewarm_*`
and are intentionally not versioned.
