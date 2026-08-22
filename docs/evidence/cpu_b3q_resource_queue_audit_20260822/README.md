# CPU-B3Q Resource and Queue Audit

This audit checks whether conventional CPU terrain resource ownership is
bounded and observable before final CPU qualification. All native tests ran in
debug and release under exact logical CPU affinity `[0, 1, 2]`.

The authority now exposes current entry residency, byte residency, entry
capacity, and byte capacity for encoded pages, decoded pages, mesh resources,
render resources, and collision resources. The production streaming fixture
populates each resource class and rejects any sample above its configured
ceiling.

The focused suites pass queue rejection, backpressure, cancellation,
invalidation, stale-result rejection, cache identity conflicts, targeted
collision activation, collision reactivation, replacement continuity,
collision publication priority, and publication coalescing. Real Godot smokes
also pass production render/collision startup and the authoritative bottom
boundary edit contract using the exact binary artifact consumed by the game.

No conventional cache, storage, collision, or queue correction is justified by
this audit. It does not claim that relocation/edit latency is acceptable, and
it does not select a GPU architecture. Two pre-existing source-size hard-limit
violations remain a final-freeze blocker and must be reconciled before the CPU
baseline is declared complete.

See `qualification.json` for exact identities, test hashes, and claim limits.
