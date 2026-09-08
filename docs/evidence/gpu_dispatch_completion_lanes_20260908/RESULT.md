# GPU dispatch-completion lane checkpoint

This game pin consumes native commit
`9fdc8e40ef36ae4150e18e34a5e22794a06a0d93`. Native GPU request identities
now preserve the scheduler's interaction-priority classification.

GPU extraction writes a separate 16-byte slot, ticket, generation, and marker
token after its mesh writes. Completion of that token releases dispatch-lane
capacity only. Candidate slots remain provisional; old coverage and the
existing 20-byte cohort validation summary still own atomic activation and
reclamation.

The render frontend reserves eight outstanding dispatch tokens for interaction
work and permits four for background work. Its two admission queues are also
independent. Supersession removes both the extraction summary and completion
token without publishing the stale candidate.

The deliberate Vulkan and D3D12 saturation regression queued twelve background
and four interaction candidates before one render callback. Both backends
observed a background peak of four, an interaction peak of four, at least eight
background deferrals, zero interaction deferrals, zero invalid tokens, complete
token drainage, and complete candidate reclamation. Both produced the same
27,312-pixel proof image digest.

Full-quality Vulkan and D3D12 edits retained LOD0-first output and visibility
within two render callbacks after commit. The 12-edit rapid regressions retained
zero mixed revisions, 24 incremental dispatches, and zero copy fallbacks.
Production lifecycle passed on both backends with CPU collision authority and
zero geometry readback. Seven native authority, streaming, collision, and GPU
capture regressions passed in debug and release.

The native interaction marker corrected the temporary cached-approach
regression from about 100.05 ms to 83.3 ms on both backends. The focused route's
separate detached-replacement audit remains timing-sensitive (`4-5/6` detached)
even though GPU active/incomplete counts are `8/0`; this checkpoint does not
claim the final instant-edit or gameplay qualification gates.
