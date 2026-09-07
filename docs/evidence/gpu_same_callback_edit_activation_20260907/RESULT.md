# Same-callback loaded-edit activation checkpoint

Native authority: `208013cee5abf747263f5a04e6f202563177b914`

Runtime artifact digest:
`ae81a7503100d01b0719738e341d8f5075358090b78a5f817d889606bfa803ef`.

An exact one-chunk same-layout incremental edit now completes native
preparation, request validation, and activation before its render callback.
The render effect queues the corresponding activation behind extraction, so
the callback extracts, atomically validates, activates, and draws the candidate
without another main-thread round trip. All other cohort shapes continue on
the existing deferred regional path.

| Driver | Submission maximum | First draw maximum | Observed-ready maximum |
| --- | ---: | ---: | ---: |
| Vulkan | 463 us | 25.050 ms | 56.070 ms |
| D3D12 | 464 us | 28.269 ms | 57.099 ms |

Each traced backend recorded six same-callback precommits and a matching
render-thread first draw for every hot edit. Both first-draw maxima pass the
33.334 ms two-displayed-frame contract. Traced and untraced routes pass; the
untraced route intentionally reports no lifecycle timestamp.

Collision continuity passes for 600 frames on Vulkan and D3D12 with one active
collision resource and unchanged support height. Rapid two-chunk edits pass on
both drivers with zero mixed revisions, 12 same-layout cohorts covering 24
chunks, 24 incremental dispatches, zero copy fallbacks, and 43 completed
retirements. The route checks summary transfer bytes against successful
readback requests because discarded tickets complete with zero transferred
bytes by design.

The native debug and release builds pass the seven established regressions.
The exact traces and logs are retained beside this result.
