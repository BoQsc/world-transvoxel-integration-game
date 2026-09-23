# GPU atlas edit scheduling checkpoint (incomplete)

Native authority `009815f59ba09975bb2d63c4cfe1e71ce44d8227` registers the
validated coarse atlas as external visible cover for edit scheduling. An edited
atlas root now gets foreground priority and independent visual publication;
LOD0 edit collision remains separately authoritative. The game pins the exact
debug and release DLLs. The CPU renderer remains the default.

The bounded Vulkan `base_coverage_edit_probe` used the same single 4 m carve
at `(300, 40, 307)` on the fresh g23 world. Both runs scheduled five edit
replacements. Before this change, one coarse visual replacement was deferred;
the journal reached revision 1 in 42-57 ms, but the local visible LOD3 mesh
still reported revision 0 at 3.97-4.14 seconds. With this change, deferred
visual replacements were zero and local LOD3 and LOD0 both reported revision 1
by the 613 ms sample (frame 20). The process exited within 12 seconds at 727
MiB peak RSS. The standard human startup gate was left intact; only the
dedicated probe bypasses local dynamic visual readiness to exercise an edit
against the retained atlas.

Native debug/release `test_wt_m5_edit_replacement` and production lifecycle
tests passed. The Godot native atlas upload test, runtime artifact validator,
and dependency-boundary validator passed. This is a scheduler correctness
improvement, **not** the two-frame edit contract: the probe samples still show
hundreds of milliseconds of old visual coverage, and its ground screenshot
does not prove the carve's final shape. Burst edits, movement collision,
Vulkan/D3D12 parity, frame time, and soak remain unqualified. A bounded
GPU-resident edited-brick path is still required for near-instant visuals.
