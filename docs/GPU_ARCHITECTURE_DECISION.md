# GPU Architecture Decision

Status: `TQP64_LARGE_WORLD_SHADOW_QUALIFIED`

TQP-58 selected a bounded GPU candidate for field evaluation and Transvoxel
mesh extraction. TQP-59 through TQP-63 subsequently qualified the bounded
field, cell meshing, shared differential, residency/publication, and retained
Windows NVIDIA Vulkan/D3D12 profiles in the Terrain Lab. Those results do not
replace the authoritative CPU implementation or qualify a production GPU
backend. TQP-64 is now active.

## TQP-64 Integration Status

The production terrain addon now owns an opt-in
`WtTerrainGpuMeshingService`. It runs the qualified compute mesher on one
dedicated worker, admits at most three outstanding requests, consumes lookup
tables exported by the pinned native backend, reports unsupported or saturated
states explicitly, and never falls back to CPU meshing. Compute submission,
synchronization, and readback do not execute on the Godot frame thread.

The service now retains one 20-buffer uniform-set inventory across requests,
grows those buffers geometrically only when required, and updates request
inputs in place. Exact differential comparison also runs on the dedicated
worker and returns a compact verdict instead of copying full GPU cell results
back to the frame thread. Topology, indices, materials, reuse metadata, and
identity remain exact. Vertex comparison uses a bounded float32 scale-aware
tolerance; normals retain the absolute `1e-5` bound. There is still no GPU
render publication path.

The retained integration smoke captures one real native LOD1 chunk containing
4,352 cells (4,096 regular and 256 transition), meshes every captured cell on
the GPU, compares geometry and metadata against CPU authority, and sends the
GPU cell payload through the unchanged native chunk finalizer. Vulkan and
D3D12 both pass on the retained GTX 1060 Max-Q profile with zero cell mismatch
and exact finalized chunk geometry. Bounded saturation and deterministic
repeat controls also pass.

The second slice connects the candidate to accepted live terrain work as an
opt-in shadow validator. The native authority captures immutable regular and
transition inputs only after its existing generation/revision acceptance,
including terrain and static-water surfaces. The addon meshes those captures
on its dedicated GPU worker, compares all geometry and metadata against CPU
authority, and returns the exact identity for native stale validation. A live
construct remesh, volumetric static water, and a deliberately superseded result
pass on both Vulkan and D3D12.

The retained large-world qualification runs the accepted G23 2,048 x 256 x
2,048 profile through the same deterministic two-leg relocation route in
CPU-only and shadow modes. Vulkan and D3D12 both complete long flight, LOD
transition work, relocated carve, and relocated construction with complete
traces. Vulkan records 74 matched terrain results including 3 transition
results; D3D12 records 102 including 3 transitions. Both drivers record
positive terrain matches in each relocated edit window and zero geometry,
unknown-request, or identity mismatch. The native bounded queue supersedes 11
older Vulkan captures and 19 older D3D12 captures so fresh relocated work is
validated without increasing capacity or revoking in-flight work.

Persistent resources materially reduce the intrusive shadow cost measured by
the earlier diagnostic. Vulkan trace-on frame p95 is 31.80 ms versus 26.82 ms
for its paired CPU run; D3D12 is 34.60 ms versus 29.14 ms. The old per-request
allocation and frame-thread comparison run measured 307-318 ms p95. However,
shadow p99 remains 150-157 ms and route wall time remains 28-41% higher because
all candidate geometry is still read back for validation. This rejects
performance promotion while qualifying the persistent validation architecture.
Board-global telemetry is not process-attributed, and trace-on timing is not a
release performance baseline.

This remains deliberately disconnected from live GPU terrain publication. The
default runtime remains CPU-only, while shadow mode still publishes the normal
CPU render and targeted CPU collision resources. GPU-resident rendering,
versioned GPU publication, production GPU field evaluation, broader material
coverage, targeted collision coordination, device recovery, large-world
responsiveness benefit, performance and power benefit, and release packaging
remain TQP-64 work.

## Decision

Keep CPU ownership of world state, storage, edit transactions, revisions,
desired-set planning, immutable transition masks, stale-result rejection,
atomic publication, persistence, and targeted collision policy. Move only the
following measured work into the first GPU candidate:

1. density, gradient, and material field evaluation for requested pages;
2. regular-cell and transition-cell mesh extraction;
3. GPU-resident candidate mesh buffers and render consumption.

Every GPU result must carry exact page key, LOD, generation, source revision,
world revision, and transition mask. The CPU validates that identity before
atomic publication. There is no silent fallback: CPU reference mode remains an
explicit selectable backend, and GPU failure must be reported.

Collision stays CPU-generated and viewer-targeted for the first candidate.
GPU collision readback is deferred until versioned readback can beat the CPU
path without delaying publication or weakening collision correctness.

## Alternatives

- **Continue changing CPU scheduling:** rejected as the next phase. Focused
  cache, storage, collision, queue, priority, admission, worker, and shared-work
  candidates are either accepted as bounded or measured and rejected. The
  remaining material cost is serial mesh/visibility backlog.
- **GPU field and meshing candidate with CPU control:** selected. It targets the
  measured work while preserving the qualified authority boundary.
- **Full GPU terrain authority:** rejected for this phase. Moving edits,
  persistence, publication ownership, or collision authority would multiply
  determinism, synchronization, readback, server, and recovery risks before the
  narrow candidate is proven.

## Required Qualification

The candidate advances only through the existing ordered milestones:

1. TQP-59: analytical and CPU-differential field evaluation (`qualified`);
2. TQP-60: regular and transition GPU meshing candidate (`qualified`);
3. TQP-61: shared CPU/GPU differential corpus (`qualified`);
4. TQP-62: residency, synchronization, stale rejection, publication, and
   targeted collision-readback decision (`qualified`, bounded candidate);
5. TQP-63: supported driver/API/memory/thermal/power matrix (`qualified` for
   the retained Windows NVIDIA GTX 1060 Max-Q Vulkan and D3D12 scope);
6. TQP-64: separately reviewed production backend release (`active`).

The differential corpus must cover all regular cases, transition orientations
and masks, materials including water, edits, bounds, seams, negative controls,
and deterministic or explicitly tolerance-bounded output. Promotion also
requires a material frame-pacing, relocation-readiness, throughput, or energy
benefit against the frozen CPU baseline with zero stale publication and zero
render/collision ownership divergence.

GPU-board watts, CPU-package watts, and whole-system watts remain separate
measurements. The initial efficiency comparison must record GPU board power and
work per frame where available; it must not infer CPU or whole-system power.
