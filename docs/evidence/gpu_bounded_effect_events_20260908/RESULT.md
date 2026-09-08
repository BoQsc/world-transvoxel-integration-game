# Bounded GPU effect-event consumption

A Vulkan stage-timed route proved that the controller drained an unbounded render-thread event backlog for up to 953.007 ms in one callback. The retained change processes at most 32 events or 2 ms of admitted work per frame and routes incremental-edit events through a priority queue. Events remain ordered within each lane and are never discarded.

## Evidence

- Paired Vulkan event-drain maximum: 953.007 ms -> 27.564 ms.
- Paired route frame maximum: 3756.493 ms -> 2422.791 ms; p99: 88.715 ms -> 59.866 ms.
- Paired route blocked movement: 37 -> 0 frames.
- Bounded route processed 5943 events across 1694 callbacks, stopped on its budget 493 times, and never exceeded 32 events in one callback.
- Focused Vulkan: submit max 406 us, first draw max 26.528 ms, observed readiness max 58.128 ms, cached approach 84.092 ms.
- Focused D3D12 retry: submit max 393 us, first draw max 31.154 ms, observed readiness max 59.665 ms, cached approach 83.895 ms.
- O(1) keyed FIFO follow-up: event-drain maximum 18.316 ms; 5016 events consumed with the same 32-event bound.
- A second route exposed independent native visibility-staging instability: 34 blocked movement frames and 5.569/9.822 s relocated edits. This is retained as the next blocker, not counted as a pass.
- Event fairness/loss smoke and Godot editor parse pass.

The remaining route maximum is 2422.791 ms and is attributed to native storage/frontend publication. Activation retry still reaches 115.791 ms. This checkpoint does not satisfy the final frame-time or relocated-edit latency contracts.
