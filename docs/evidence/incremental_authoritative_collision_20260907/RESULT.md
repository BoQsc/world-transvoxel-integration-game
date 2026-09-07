# Incremental authoritative collision checkpoint

Native authority: 98b380501475b7c82b97b347e14aa3738a9b2444

This checkpoint partitions LOD0 collision into eight independently replaceable 8-cubed cell blocks, reserves one mesh worker for interactive collision patches, publishes incremental patches without waiting for GPU visual capacity, and tracks queued collision publication per generation. Non-density revisions preserve installed collision shapes.

## Regression result

- The production lifecycle generation storm fell from 3,610 scheduler jobs / 1,805 mesh completions to 4 scheduler jobs / 2 mesh completions for the same two edits.
- Vulkan and D3D12 production lifecycle routes pass with CPU collision authority and zero geometry readback.
- Vulkan and D3D12 rapid-edit routes pass: 12 edits, 61 checked frames, zero mixed revisions, 24 incremental surface dispatches, 73,728 regenerated cells, and 13,616 bytes in the final upload.
- Native debug no-argument regressions pass after excluding the two benchmark executables that require arguments; the corrected edit-replacement regression passes separately. Ten focused release regressions pass.

## Critical-path traces

| Driver | Layout | Submit max | Hot ready max | Cold ready |
|---|---:|---:|---:|---:|
| Vulkan | cross brick | 334 us | 75,767 us | 151,012 us |
| Vulkan | single brick | 320 us | 75,808 us | 150,713 us |
| D3D12 | cross brick | 344 us | 74,795 us | 150,710 us |
| D3D12 | single brick | 346 us | 75,403 us | 150,842 us |

All four traced routes completed six edits with matching journal commits, dirty-page admissions, collision preparation and collision sink publication. The submission contract is met. Hot visual readiness remains about 75 ms and therefore does not yet meet the final two-displayed-frame contract; interaction-first streaming and publication scheduling remain the next checkpoint.
