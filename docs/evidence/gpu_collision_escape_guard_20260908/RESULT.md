# Collision-pending escape guard correction

Game checkpoint based on native authority
`ddcc35a10cb48fb4305df997835b006db089731b`.

The production player previously set its complete velocity to zero whenever any
chunk overlapping the destination capsule lacked current LOD0 collision
readiness. A delayed collision replacement could therefore form an artificial
player cage inside a large excavation even though the runtime was still making
progress or retained an applied ancestor collision shape.

Collision readiness now reports strict current-LOD readiness separately from
movement safety. Applied LOD0 shapes, resolved empty LOD0 payloads, and retained
ancestor collision are movement-safe coverage. When strict readiness is pending
with coverage, normal motion continues. When no physical coverage exists,
horizontal and upward escape continue while only downward velocity is clamped
to zero to prevent a fall through unloaded terrain. The controller no longer
counts or reports these frames as blocked movement.

The playtest overlay now says `TERRAIN COLLISION UPDATING` and explicitly reports
`MOVEMENT AVAILABLE`; the detailed readiness snapshot retains pending chunks,
coverage source, retained ancestor LODs, and whether downward motion was
constrained.

Verification:

- The player collision footprint smoke passed capsule boundary coverage,
  retained-ancestor classification, horizontal escape, upward escape, and the
  complete pending-controller path.
- Interaction collision demand and playtest diagnostics smokes passed.
- Vulkan and D3D12 collision continuity each retained support for 600 physics
  frames with partial block mask `0xa0`.
- Vulkan and D3D12 rapid-edit smokes each passed 12 edits with zero mixed
  revisions and zero copy fallbacks.
- A nine-command large-excavation diagnostic found that every accepted edit's
  collision work settled with zero collision backlog and no staged collision
  resources. It also exposed a separate queued-edit issue: one of nine commands
  was accepted by submission and later rejected because its base revision had
  become stale. That rapid-submission defect remains the next correctness task.
