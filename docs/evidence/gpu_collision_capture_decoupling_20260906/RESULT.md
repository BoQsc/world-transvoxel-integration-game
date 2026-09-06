# GPU collision/capture decoupling

The game is pinned to native commit `e538c33f842afacae9ec413f6d2cb943289b4de5`.
The installed debug/release DLL digest is
`4ab139dba725170ba61635d1a5e5da205caaee2b69a962747253bfbba7dc979b`.

Focused validation passed on Vulkan and D3D12:

- rapid editing: 12 edits, 62/63 observed frames, zero mixed revisions;
- full-quality first edit: first visible edited surface is LOD0 after five
  frames on both backends, about 99.7 ms wall time;
- native saturation: collision is prepared before GPU capacity returns, the
  matching visual is captured once afterward, and a superseded deferred
  generation emits no stale result.

The bounded large-world route remains outside acceptance. It recorded 39
blocked movement frames, a longest blocked run of 13, frame p95/p99 of
26.549/34.417 ms, and LOD0 visual/collision readiness 106 frames after edit
commit. Physics target acquisition itself required zero wait frames. This
change resolves capture/collision coupling but does not resolve the dominant
large-world visual backlog or the five-frame GPU publication floor.
