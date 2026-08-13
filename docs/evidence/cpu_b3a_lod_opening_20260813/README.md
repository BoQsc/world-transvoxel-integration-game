# CPU-B3A Temporary LOD Opening Capture

Status: `IN_PROGRESS_EVENT_NOT_REPRODUCED`.

The clean integration commit `ca9ce0f` ran the G23 capture under Godot 4.7.1
with exact logical CPU affinity `[0, 1, 2]` and authority commit `a8bba838`.
The fixed viewer route stayed at least 132.94 cells from every authored road
centerline. Because distant road geometry remained visible, every candidate ray
was also compared with the authoritative G23 road segments and excluded within
32 cells of a centerline.

The capture sampled 528 route frames at a four-frame cadence. Thirty-two frames
contained near-black candidate pixels. All 64 sampled candidate rays landed in
the authored-road exclusion, and no road-clear opening was reproduced. The
native trace retained 72,723 events without consumer gaps, local drops, or
downstream drops. The 65,536-event native source ring wrapped 7,187 events only
after the observer had drained them into its complete 131,072-event local buffer.

This does not close CPU-B3A. The prior human temporary-opening observation
remains an unattributed release blocker. The reusable observer now requires a
road-clear background pixel, absence of a front-facing render triangle,
collision or an authoritative air-to-solid density crossing, exact chunk state,
and overlapping native lifecycle events. Screenshots and aggregate queue counts
cannot establish the defect by themselves.

The synchronous observer averaged 83.25 ms per sampled frame, so this run is not
a performance baseline. See `result.json` for the exact claim boundaries and
artifact hashes.
