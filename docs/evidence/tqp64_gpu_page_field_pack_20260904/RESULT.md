# TQP-64 GPU Page-Field Packing Checkpoint

Status: `BOUNDED_NATIVE_PACKING_IMPROVEMENT_EDIT_LATENCY_OPEN`.

This checkpoint replaces per-sample `std::vector::insert` calls in the native
page-field handoff with one bounded allocation and indexed writes. Immutable
Transvoxel table `PackedByteArray` values are initialized once and shared by
copy-on-write references instead of being rebuilt for every GPU request.

The shader buffer layout, sample order, shift-record references, authority
identity, atomic publication rules, CPU collision authority, CPU default, and
binary-only integration boundary are unchanged.

## Authority

- `world-transvoxel`: `808c4c79fb0ca9de89f60c98a62ef68d5bd98061`
- addon tree: `5cb25789f47a74436b64cb3dfd6ea51d97830d7e`
- native source tree: `9b6eb864e1cfcead27e94ad7fdb0e0ca07c2c35c`
- runtime artifact: `00c2650ce10122068b2f4ad96e4ca30bfef9343cfd36a47b3486498f7f40d967`
- Godot: Steam 4.7 or newer
- affinity: logical processors `0,1,2`
- procedural workers: `2`; CPU mesh workers: `0`

## Verification

Debug and release GPU meshing-shadow tests pass. They cover exact page-field
buffer sizes, material and density packing, surface-shift references, empty
terrain/water proofs, stale identity rejection, and zero CPU topology calls.
Debug and release production LOD streaming tests retain hash
`1a59569e2131a7aa07279004a8c2ce304278da658047c3aac8d56bb601ae87a3`.

Vulkan and D3D12 production lifecycle tests pass with identical terrain/water
material contracts, CPU collision authority, no geometry readback, and no CPU
field or topology dependency. Runtime artifact and dependency-boundary
validators pass.

## Clean Gate Comparison

All runs use the unchanged movement, relocation, and carve workload with
diagnostics disabled. Every run accepts all 1,020 movement frames, commits the
edit, publishes 1,004 surfaces, validates 1,000 surfaces, and reports no GPU
publication rejection.

| Metric | Restored control | Candidate 1 | Candidate 2 |
| --- | ---: | ---: | ---: |
| Maximum native mesh job | 67.302 ms | 50.120 ms | 55.752 ms |
| Physics-frame p95 | 20.260 ms | 18.793 ms | 21.058 ms |
| Maximum physics frame | 59.859 ms | 43.311 ms | 43.674 ms |
| Post-draw p95 | 28.679 ms | 27.261 ms | 29.880 ms |
| First edit-aware collision | 5 frames | 5 frames | 8 frames |
| First edit-aware visual | 21 frames | 22 frames | 25 frames |
| Exact LOD0 visual refinement | 92 frames | 102 frames | 112 frames |

Raw local result hashes:

- restored control: `4c4e2ebfcdcb68f8cc4b54ccb36495f6434414541cab8eacb4564eb2db8819bd`
- candidate 1: `29269559d703fb1b5a03eedf08b408c910a48e29bb6503f8bb3f176929ab475e`
- candidate 2: `ede720df991a30c74c02968ca4f4120e69b9d8389dcc39952941c634e932fc9b`

The reduced native maximum and maximum frame stall are consistent across both
candidate runs. Percentile and edit-readiness results remain noisy and do not
establish an end-to-end speedup. The change is retained for bounded allocation
behavior and lower worst-case preparation cost, not as a latency pass.

## Remaining Gate

The first edit-aware GPU visual remains a coarse LOD3 publication after 21-25
frames, while exact LOD0 refinement takes 92-112 frames. The next work must
reduce the authoritative reciprocal LOD cohort completion time without
weakening atomic seam publication, stale-result rejection, or retained visual
coverage.
