# Loaded same-layout GPU edit cohort checkpoint

Authority commit: `3fc91f40041a204dcce0f366858b4147ca040ca7`

Runtime artifact digest: `c23fd564bfe3a8178d37640e900a284796df45bb7558936f77416a36b9b25ab3`

Loaded edit replacements now bypass unrelated global LOD retirements only when
every visual member of the edit revision already has the same active chunk key
and transition mask. Missing coverage, exact-key retirement, and boundary
changes retain the regional publication path. Native metrics count accepted
same-layout cohorts and chunks.

The focused rapid-edit probe keeps the edited pair resident while a second
viewer alternates between two regions. Vulkan and D3D12 each observed three
pending retirements, activated all 12 two-chunk edit revisions through the
same-layout path, and recorded zero mixed-revision frames. Both retained logs
also prove incremental GPU meshlet dispatch, zero copy fallback, and bounded
20-byte asynchronous summaries.

Native debug and release publication-policy, application, production-streaming,
edit-replacement, and LOD-streaming regressions passed. Deterministic hashes
remain `39db05c67fc2f4b8d8beaab2e7da927ae968efb3d75118bcd80c5523116d9b3b`
for production streaming and
`1a59569e2131a7aa07279004a8c2ce304278da658047c3aac8d56bb601ae87a3`
for production LOD streaming.

The full D3D12 relocation route remains outside this fast path because the two
edit destinations did not have active same-key LOD0 coverage before editing.
It completed flight, carve, and construction evidence but reported 1.171 s and
1.907 s relocated edit pipelines, 23 blocked movement frames, frame p95/p99 of
39.946/66.682 ms, and terminated with the existing Godot access violation after
writing a complete trace. This checkpoint therefore proves loaded edit
decoupling; it does not satisfy cold approach or instant-edit qualification.
