# Local coarse correction reuse

Status: INCOMPLETE_NOT_QUALIFIED. Native authority `674ecc38462fd480a3ad8bb3c783f72a5f4f1794`.
Artifact digest `a8f49516eca360e2f8e25c739244bbff3627c1b67480f2f520d0a23479a3835a`.

Small edits previously rebuilt every coarse edge correction in each intersected
page. Edit replay now records the union of relevant command bounds, and the
rebuild reuses an original valid correction only outside that union plus a
one-unit finest-gradient halo. Missing/invalid corrections retain the full
rebuild path. Reuse does not change serialized formats, topology or authority.

The 24-case comparison spans LOD1–3, negative page coordinates, multiple edits,
density and material changes, and a gradient-only edit outside the chunk.
Complete serialized pages match full rebuilds byte for byte. Fine-field sample
calls drop from 68,390 to 3,204. Removing the gradient halo deliberately breaks
the comparison; restoring it passes. Both debug/release compaction tests pass.
The page-meshing runtime hash remains exactly
`aa1a828204ad38c1d476286553af5f65e779cc0eccfe777c88db44b31f49f45d`,
matching the pre-change executable in both configurations. Seven other native
regression suites also pass in debug and release.

## GPU checks and measured limitations

The small Vulkan coarse-edit fixture changed from six frames and 3,557 microseconds
of preparation through first feedback to five frames and 1,487 microseconds.
D3D12 takes six frames and 3,020 microseconds. These are bounded fixture results.
Automatic LOD relocation and twelve rapid cross-chunk edits pass on both drivers;
the rapid test checks 62 frames without mixed visible revisions.

The large clean route reduced maximum mesh preparation from about 54 ms in the
preceding report to 3.443 ms. End-to-end timing nevertheless failed: commit 2
frames, first visual 39 frames after commit, LOD0 and collision 127 frames,
27 blocked movement steps, physics p95/p99 33.395/48.511 ms. The compressed report
retains every failure. The preparation optimization is exact and reduces work;
this is not an overall gameplay speedup claim, hardware-limit diagnosis, or
qualification of instant/nonhalting terrain.

## Material initialization race found during validation

The production lifecycle test exposed a missing material payload on D3D12.
The controller tried synchronizing before materials were installed, then waited
30 frames to retry. A new first-activation assertion reproduces this failure.
Initialization now retries each frame until both production payloads have been
configured; later checks retain the normal interval. The strengthened complete
terrain/water lifecycle test passes on Vulkan and D3D12. This fix was made after
the large route measurement above; that report does not qualify the material fix's
performance. `material_initialization_before_d3d12.log` preserves the failing
assertion and the final lifecycle logs preserve passes.

## Next focused investigation

GPU publication currently waits for asynchronous counter readback before
compaction/validation and a host-authorized atomic activation. Godot documents
that readback callback delay follows the rendering device frame queue length:
[RenderingDevice.buffer_get_data_async](https://docs.godotengine.org/en/4.6/classes/class_renderingdevice.html#class-renderingdevice-method-buffer-get-data-async).
The code follows this path through `WtTerrainGpuResidentArena.finalize_readback`
and the render controller's activation cohorts. Profile one cold edit's queued,
dispatched, readback, prepared and activated stages before another full route.
Any earlier activation design must preserve failure checks, generation rejection,
atomic neighboring edits and retirement; synchronous readback would introduce
the blocking behavior the user explicitly wants eliminated. Collision remains
CPU authoritative; this experiment does not establish a need to move it to GPU.
