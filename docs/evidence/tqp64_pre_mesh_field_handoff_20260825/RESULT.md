# TQP-64 Pre-Mesh Field Handoff

Status: `RETAINED_ORDERING_BOUNDARY_PRODUCTION_BLOCKED`

Date: 2026-08-25

## Scope

The pinned `world-transvoxel` authority now creates GPU resident request v4
from immutable page-backed field inputs before CPU Transvoxel topology. The
request preserves exact chunk, LOD, generation, source/world revision,
transition masks, surface, and native-packed regular/transition inputs.

This is an ordering and ownership correction. CPU field sampling remains
active and the unchanged CPU visual/collision mesh still runs for authority,
readiness, recovery, and targeted collision. GPU density/material field
generation is not implemented. No performance promotion is claimed.

## Authority Evidence

- Authority commit: `a18cb6e296c84e7a537e2fb3de698c633445ea4b`.
- Runtime artifact digest:
  `db155e705f69f8376c89562c43664b8fc3d710c45682f4c5ba1158a69f6a114e`.
- Debug and release native tests capture all 4,864 cells for a LOD1 fixture
  with three transition faces before terrain-ready publication.
- The field-capture backend records zero CPU topology calls.
- Production lifecycle, streaming, and LOD hashes remain stable.

## Focused GPU Evidence

Vulkan and D3D12 production lifecycle fixtures each activate three chunk
generations, including two static-water surfaces, restore three CPU visuals,
retain CPU collision authority, and finish with four pre-mesh captures and no
reserved capture slots. Request telemetry reports:

- `input_stage=pre_mesh_field`;
- `cpu_topology_input_dependency=false`;
- `cpu_field_sampling=true`;
- `gpu_density_field_generation=false`;
- `gpu_transvoxel_extraction=true`.

Both drivers retain simultaneous LOD0/LOD1/LOD2 inventory (`16 / 4 / 1`), zero
coverage overlap, zero geometry readback, and exact lifecycle completion. The
Vulkan visual hashes remain:

- overview: `15e5cca3efb91b3987c0fedbe131aa997514ec61fdf8ffaec8dbc88d48682a4b`;
- near: `fe44900e4d7652979155ab8eb392ff48e97a82c2b012bab1c5f4529fd0d705aa`.

The Vulkan global-publication diagnostic remains 27,312 foreground pixels with
SHA `b4f424159ca782f3ed0f27ef2144cf391bc19398a1024675db68ca9627823ed8`.

## Decision

Retain request v4 and the pre-mesh field handoff. Do not promote the backend or
run a large-world performance comparison for this slice: it intentionally adds
a second CPU field traversal while preserving the CPU reference mesh. The next
bounded step is authoritative GPU density/material field generation, followed
by skipping CPU visual meshing for chunks that do not require targeted CPU
collision. Exact stale rejection, transition masks, shared residency, CPU
visual recovery, and CPU collision authority remain mandatory.

Machine-readable evidence: [qualification.json](qualification.json).
