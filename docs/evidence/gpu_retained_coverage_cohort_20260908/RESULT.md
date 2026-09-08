# GPU retained-coverage cohort checkpoint

Native authority: `9c2137cfe236e0b163e1e59bcc41eda7141f037c`

The bounded Vulkan startup reproduction previously stopped with three prepared
LOD2 replacements, 40 visual retirements, empty native queues, and 7,392 cohort
retries. Added failure telemetry showed that the selected new replacements did
not geometrically cover four LOD0 retirements pulled into the cohort by the
unsafe LOD2-to-LOD0 face rule. All selected keys were authoritative. Existing
active coarse terrain covered that volume but was absent from the proof.

Native publication now admits current, exact-generation retained GPU leaves
which overlap such retirement volume into the immutable cohort. They require no
capture or activation. Stale, retiring, transition-mismatched, and nonvisual
leaves cannot satisfy coverage. Failure reports now include selected keys,
geometric coverage, and authority failures.

Verification:

- Debug and release builds passed.
- Seven focused native debug and release regressions passed, including the new
  retained unsafe-face coverage case, publication policy, application,
  streaming, LOD streaming, lifecycle, edit replacement, and GPU shadow.
- Guarded Vulkan startup probe passed with zero native pending replacements and
  retirements, zero pending activation retries, zero rejected chunks, 34 trace
  events, no dropped events, and peak RSS 761,573,376 bytes.
- Vulkan and D3D12 full-quality edit smoke passed: LOD0 activated one displayed
  frame after commit and was controller-visible by frame two.
- Vulkan and D3D12 rapid-edit smoke passed 12 edits each across 61 checked
  frames with zero mixed revisions and zero pending retirements.

Repository validation still reports the existing source-file hard-limit debt in
nine files. This checkpoint introduces no artifact-layout or runtime-pin error.
It closes the reproduced startup publication deadlock; it does not establish the
full instant-edit qualification target.
