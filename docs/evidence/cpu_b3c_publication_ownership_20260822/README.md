# CPU-B3C Publication Ownership Audit

Status: exact component attributed; remediation not selected

This retained run used the deterministic terrain-waterfall route under logical
CPU affinity `[0, 1, 2]`. It changes no terrain scheduling, publication,
collision, rendering, or edit behavior.

Authority commit `d89e3497c4c374bd6a116ba8cc9804b4b3f48494` adds trace-only
events for every replacement and retirement in a successfully published
regional cohort. Integration commit
`e66690f979457b2a6175438dcbe0aef5ea54201e` pins those binaries and audits
the exact membership.

The trace was complete, covered both required relocated edits, and had no
consumer gaps or local drops. The carve cohort contained all four edit
replacements plus 452 non-edit replacements and 129 retirements. The construct
cohort contained its one edit replacement plus 461 non-edit replacements and
184 retirements. Every sampled first blocker was a non-edit replacement waiting
for visual readiness. Neither edit window sustained the three-logical-CPU
capacity.

The non-edit members correlate with 14 accepted viewer-plan origins for carve
and 27 for construction. Many originated before the latest pre-edit plan, but
revision age is not proof of stale work: unchanged desired chunks can retain
their original generation across later plans. The front end already cancels
same-key replacements and retirements when later plan publications reverse
them.

This evidence rejects three shortcuts: bypassing atomic visibility staging,
canceling work only because its origin is older, and selecting a GPU backend
before standard CPU lifecycle remediation is exhausted. A future behavioral
experiment must first prove whether the broad cohort is current desired
ownership, then test one bounded standard remedy with trace-off performance and
full seam/collision regressions.
