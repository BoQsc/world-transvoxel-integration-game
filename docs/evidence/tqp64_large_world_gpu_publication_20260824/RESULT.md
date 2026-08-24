# TQP-64 Bounded GPU-Cell Publication Qualification

Date: 2026-08-24

Status: `PASS_BOUNDED_MATCHED_GPU_CELL_PUBLICATION`

## Scope

The default-off publication candidate ran the existing deterministic ascent,
long-flight, relocation, carve, and construction route on the 2,048 x 256 x
2,048 G23 world. Vulkan and D3D12 runs were limited to three logical CPUs.

This stage publishes only a visual candidate that passes worker differential,
native cell replay/finalization, exact CPU-authority mesh/render equality, and
current application-generation checks. CPU world and collision authority are
unchanged.

## Results

| Driver | Matches | Transition matches | Visuals submitted/applied | Stale pre-visual skips | Stale applied | Rejections |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Vulkan | 120 | 12 | 107 / 107 | 13 | 0 | 0 |
| D3D12 | 104 | 14 | 89 / 89 | 15 | 0 | 0 |

Both routes covered relocated carve and construction. Vulkan observed 19 and
15 terrain matches in those edit windows; D3D12 observed 6 and 13. There were no
GPU mismatch, identity mismatch, native finalization rejection, application
queue rejection, or stale candidate application events.

The 13 Vulkan and 15 D3D12 stale pre-visual skips are expected
bounded-streaming outcomes: exact matched work arrived before its CPU visual
was ready and was discarded without publication. Native and controller
counters agree.

## Claim Boundary

This does not complete TQP-64. GPU cells are read back, finalized on CPU, and
uploaded through Godot `ArrayMesh`. The run does not demonstrate GPU-resident
rendering, zero-readback publication, performance improvement, recovery,
migration, packaging, or backend release readiness. Trace timing is intrusive;
board telemetry is global and not process-attributed.

The compact retained evidence is `qualification.json`. Raw traces, reports,
usage samples, and logs remain under
`.godot/world_transvoxel_captures/tqp64_gpu_publication_qualification/` and are
not committed.
