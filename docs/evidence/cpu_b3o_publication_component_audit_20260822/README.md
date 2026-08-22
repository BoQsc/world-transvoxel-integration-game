# CPU-B3O Publication Component Audit

CPU-B3O answers whether the broad relocated-edit publication cohorts are
accidentally over-grouped by the current authority policy.

## Method

Integration commit `b7abf1d` extends the optional terrain-waterfall analyzer
to reconstruct the same bipartite graph used by `world-transvoxel`:

- a replacement and retirement are connected when their volumes overlap;
- they are also connected when they share a face and publication would expose
  an LOD difference greater than one;
- every retirement must be completely covered by non-overlapping replacements;
- one atomic region must contain exactly one connected component.

The analyzer has positive, disconnected-backlog, and unsafe-LOD-face unit
tests. It ran against an exact, lossless current-authority trace using logical
CPU affinity `[0, 1, 2]`. Authority commit `b57aba9` produced the consumed
runtime artifact.

## Result

| Edit | Replacements | Retirements | Graph nodes | Overlap edges | LOD-balance edges |
| --- | ---: | ---: | ---: | ---: | ---: |
| Carve | 428 | 125 | 553 | 923 | 545 |
| Construct | 462 | 185 | 647 | 1,123 | 610 |

Both regions are one connected component. Neither contains an isolated member,
overlapping replacement ownership, a replacement/retirement role conflict, or
an uncovered retirement. The result is
`MINIMAL_UNDER_AUTHORITY_COMPONENT_RULE` for both edits.

The current policy therefore does not justify splitting these cohorts by
simply removing members. Doing so would either leave old and new ownership
overlapping, retire terrain without complete replacement coverage, or expose a
neighbor LOD difference above one.

## Decision

The conditional cohort-correction milestone is not applicable. Atomic
publication remains unchanged. The next CPU candidate is a bounded unified
work-conserving executor because the large component is real and the traced
edit windows still do not sustain the available three-logical-CPU capacity.

This proof is deliberately narrow. It proves minimality under the current
balanced-LOD component rule, not that this rule is the only possible crack-free
architecture. A more elaborate multi-wave publication algorithm could be
studied later, but it is not a low-risk correction and is not selected here.

Raw trace, report, and usage captures remain under
`.godot/world_transvoxel_captures/terrain_waterfall/publication_component_current_*`
and are intentionally not versioned. Their hashes are retained in
`qualification.json`.
