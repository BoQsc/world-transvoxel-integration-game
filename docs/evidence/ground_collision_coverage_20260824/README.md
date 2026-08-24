# Ground Collision Coverage Qualification

Date: 2026-08-24

This qualification targets average-speed player traversal over the authored
road. It checks actual route completion, guard intervention, missing floor
rays, and foot penetration while the large terrain LOD plan moves.

## Diagnosis

Before the authority correction, exact LOD0 support chunks were logically
ready and had current staged collision payloads, but no same-key physical
collision node. Their current render generation was already visible while the
collision payload remained tied to a larger regional visual publication. A
diagnostic run stopped three times for 613 frames total; individual recovery
times were 166 to 225 frames.

The authority now permits a new required collision shape to become physical
when it has no previous same-key shape and either its matching visual
generation is live or the chunk is collision-only. Existing same-key collision
replacements remain synchronized with staged render replacement. Outgoing
coarse collision remains until normal coverage-safe retirement.

## Result

Four consecutive rendered traversals completed 192.12 meters at 8 m/s with:

- zero blocked frames;
- zero missing-floor frames;
- zero detected penetration;
- exact three-logical-CPU process affinity and two generation workers.

The guard remains enabled as a correctness assertion, but it did not intervene
in any accepted run. GPU utilization and power values in `qualification.json`
are NVIDIA board-global observations and are not attributed solely to Godot.

This result qualifies the reproduced road traversal defect. It does not claim
that every terrain route, edit sequence, or hardware configuration is proven.
