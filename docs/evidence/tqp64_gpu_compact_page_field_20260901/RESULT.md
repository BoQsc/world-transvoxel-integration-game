# TQP-64 Compact GPU Page-Field Handoff

Status: accepted implementation checkpoint, production gameplay gate still open

## Authority

- Upstream commit: `d0497ff51845d90b4ab39ffbf4fe43bf7ee6b02b`
- Runtime artifact: `d1ab0767d90b53c4e717907914d3841f897640c788e4cf1793ee80d6b3e77220`
- Debug DLL: `42ae8c406f17f01ff6f27fba39b106d0eb472c161be6a65a04d7fef314f03917`
- Release DLL: `0acef09177808e4b823e44936c1b89ee4a7bca4baae9faf47d3163a4fda65fa3`

The native producer now omits buffers for uniformly signed page fields. Nonempty
page fields use two scalar density values and two scalar material values per
lattice sample. Explicit diagnostic cell input retains its existing four-value
layout. CPU visual topology remains absent in GPU resident mode; targeted CPU
collision authority is unchanged.

## Correctness Gates

- Native debug and release `test_wt_gpu_meshing_shadow`: PASS.
- `gpu_activation_retry_fairness_smoke.gd`: PASS.
- `gpu_resident_production_lifecycle_smoke.gd`: PASS.
- `gpu_resident_multichunk_relocation_smoke.gd`: PASS with 12 activations,
  8 retirements, 4 active chunks, zero geometry readback, and 9,107 foreground
  pixels.
- `gpu_global_render_publication_smoke.gd`: PASS with stale and superseded
  replacement coverage, compact indirect drawing, and 27,312 foreground pixels.
- Runtime artifact and terrain dependency boundary validators: PASS.

## Three-Core Diagnostic

Local diagnostic: `.godot/gpu_compact_input_20260901.json`.

The same 2K relocation/edit route was confined to logical CPUs 0-2. Compared
with the earlier collision-lane trace, native packed input fell from 1,742.9 MiB
to 316.6 MiB. Wall time fell from 50.47 s to 46.54 s, process CPU time from
78.66 s to 75.61 s, and the longest blocked movement run from 82 to 66 frames.
The edit target still had no collision after the 181-frame observation window;
its relocation lower bound was 2,980 ms.

The prior `.godot/gpu_empty_elision_20260901.json` process loaded an older debug
DLL, so it did not measure empty-page elision. It must not be used to isolate
the compact-layout contribution. The accepted measurement combines empty-page
elision and compact nonempty sample packing.

## Remaining Dependency

This checkpoint does not qualify production gameplay. At the end of the route,
the native scheduler still held 500 jobs and the exact publication plan held
537 pending replacements. The target collision generation remains gated by the
matching visual activation cohort. The next architectural target is hierarchical
coarse-first publication and bounded refinement, preserving exact masks, atomic
surface activation, and collision/visual generation agreement.
