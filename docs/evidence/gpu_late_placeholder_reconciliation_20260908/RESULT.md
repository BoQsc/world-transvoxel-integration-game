# Late GPU edit-placeholder reconciliation checkpoint

This game pin consumes native commit
`6e18342a4f54fe27992446601a0cba046895725c`.

The guarded gameplay route exposed a permanent wait when an incremental GPU
capture reached the frontend before its CPU application record. Placeholder
application previously ran only during the initial pop. Readiness retries now
reconcile the exact key and generation after collision becomes ready, then
re-read application state. A waiting interaction request also no longer blocks
the native capture queue; its identity and readiness reason are retained in
controller status.

Before the repair, the autonomous Vulkan route stopped after carve with one
deferred interaction request and eleven native captures queued. The repair ran
the full flight, carve, relocation, and construction route, ending with both
queues at zero and peak RSS of 1.99 GB under the 3 GiB guard. Both Vulkan and
D3D12 full-quality edits remain visible within two render callbacks after
commit. Both 12-edit rapid regressions retain zero mixed revisions and zero
incremental-copy fallbacks. Seven native regressions pass in debug and release.

The route is still unqualified. Native edit sampling and meshing complete in
tens of milliseconds, but carve publishes only one of four correlated LOD0 GPU
chunks and construction publishes two of four. The corresponding visual waits
reach 13.6 and 31.0 seconds while 153-190 regional replacements are pending.
The next checkpoint must detach complete edited LOD0 cohorts from that regional
publication backlog without weakening atomic coverage.
