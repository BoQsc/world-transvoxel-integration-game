# CPU-B3F Relocation Destination Readiness

This diagnostic repeated the accepted CPU terrain route three times with fresh
storage, an autonomous long flight, a relocated carve, and a second relocation
followed by construction. The runtime remained capped at three logical CPUs.
No scheduling or terrain behavior changed.

## Result

- All three traces were complete, with no dropped downstream events, no implied
  native event loss, and zero blocked movement or flight frames.
- All six eventual LOD0 edit-center chunks were demanded before edit submission
  and had both render and collision sinks applied before the edit.
- First demand preceded edit submission by 1,357.0 to 2,107.1 ms. Full target
  readiness preceded edit submission by 70.3 to 915.0 ms.
- The dominant post-edit wait in all six cases was regional visibility staging,
  lasting 2,881.2 to 5,225.1 ms after edit replacements were ready.
- Published cohorts contained 428 to 462 replacements, of which only one to
  four were edit replacements. Every cohort had exact latest-drained-plan
  ownership, so the retained evidence does not classify the other members as
  stale or unnecessary.
- Every sampled dominant blocker was another replacement whose visual result
  was not ready. Peak blocked cohorts contained 468 to 546 replacements.
- Whole-trace CPU use averaged 1.37 to 1.68 logical cores. Saturated samples
  ranged from 2.5 to 9.7 percent. This does not support raw three-core
  saturation as the primary explanation for the multi-second publication wait.
- Severe isolated frames remain: one run classified a 6.8-second maximum as
  native meshing, while two runs classified 12.0-second and 6.9-second maxima
  as native storage. These are unresolved and are not normalized away.

## Decision

Reject late destination demand as the explanation for delayed first edits in
this deterministic route. Do not reintroduce target prewarming and do not alter
scheduling based on this evidence.

The next diagnostic must follow the non-edit replacement that controls each
atomic publication: retain its demand origin and storage, sampling, meshing,
render, and collision timings, then explain why a still-required cohort of
hundreds is coupled to the edit publication. This should precede any attempt to
split, prioritize, or otherwise change regional publication behavior.

The raw traces and reports remain under
`.godot/world_transvoxel_captures/terrain_waterfall/relocation_readiness_repeat_*`
and are intentionally not versioned.

## Claim Boundary

Pre-edit readiness proves retained render and collision sink application for
the eventual LOD0 edit-center chunk. It does not prove every chunk touched by
the brush was ready, or that the entire regional publication cohort was ready.
Trace-on frame timing is diagnostic rather than a release-performance baseline.
