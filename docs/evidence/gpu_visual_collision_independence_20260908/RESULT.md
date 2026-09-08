# GPU visual/collision independence checkpoint

Native authority: `c47768d00c208a8657a70073d57770dc51e40683`

The bounded hot-edit trace showed that GPU execution was already fast: after a
capture reached the controller, D3D12 first draw followed in about 1.6 ms. The
miss occurred before capture submission. A late geometry-free GPU placeholder
was produced only after the shared CPU mesh job completed, and reconciliation
also required collision readiness. Depending on frame alignment, traced first
draw reached 34.4-45.4 ms.

An asynchronous job with a reserved immutable pre-mesh capture now publishes
its visual placeholder immediately after successful dispatch. GPU validation,
preparation, and activation can run while CPU collision extraction continues.
The completion placeholder is idempotent. Empty authoritative collision results
retain bounded generation tombstones after their physics bodies are removed, so
split completion can prove exact collision application without retaining empty
Godot resources. Runtime metrics report their count.

The critical-path audit now checks final application/render/collision generation
equality and zero pending replacement markers. It records coalesced cleanup
counts without assuming that the runtime must observe every superseded same-key
generation between rapid edits.

Verification:

- Debug and release native builds passed.
- Seven focused native regressions passed in both configurations.
- Vulkan traced hot edits: submission maximum 387 us, first-draw maximum
  18,964 us, cached approach 67,365 us.
- D3D12 traced hot edits: submission maximum 527 us, first-draw maximum
  19,144 us, cached approach 67,340 us.
- Vulkan and D3D12 full-quality LOD0 edit smoke passed within two displayed
  frames.
- Vulkan and D3D12 rapid-edit smoke passed 12 edits each with zero mixed
  revisions and zero pending retirements.

The collision-only relocation smoke did not reach its intended overlap setup
(`shared_peak=7`, no exclusions), so it supplied no verdict for this change and
is retained as a fixture-coverage failure. Hot collision-complete observation
remains about 50 ms; the next checkpoint must reduce CPU collision extraction
and physics-boundary latency. This checkpoint does not establish full instant
terrain qualification.
