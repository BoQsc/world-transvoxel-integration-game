# Source Layout Placeholder

Substantial implementation has not started.

When implementation begins, keep source ownership separated by subsystem:

- public API adapters;
- runtime terrain root and profile binding;
- generation profiles and offline hooks;
- streaming policy above `world-transvoxel`;
- edit operation policy;
- save/load and journal integration;
- material and texture policy;
- collision readiness policy;
- debug/status surfaces;
- addon-local smoke tests.

Do not create a single large mixed-purpose terrain source file.

A1 now uses explicit subsystem directories next to this placeholder. Keep this
`src/` directory empty unless a later native/build layout contract assigns it a
specific purpose.
