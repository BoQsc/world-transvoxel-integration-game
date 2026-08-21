# World Transvoxel Runtime Dependency

Status: active binary-consumer boundary

`world-transvoxel` is the sole authority for native C++ source, native tests,
build configuration, and generated native tools. This integration game does
not own or vendor a second native implementation.

The game consumes a strict runtime artifact containing:

- Godot debug and release GDExtension DLLs;
- the `.gdextension` descriptor and UID;
- public API and operating-limit documentation;
- the 0BSD license scope and required MIT license/provenance notices.

The artifact intentionally excludes `src/`, native third-party source,
build files, the native editor bake plugin, and source-checkout tooling. Baking,
storage migration, native compilation, and native unit tests run from the
standalone authority repository. The terrain and gameworld addons remain
separate downstream consumers.

`WORLD_TRANSVOXEL_RUNTIME_PIN.json` records the exact authority commit, native
source tree, binary build commit, artifact layout, artifact digest, and DLL
hashes. `tools/validate_world_transvoxel_runtime_artifact.py` rejects missing or
extra files, copied native source, an unpinned DLL, or any fallback authority.
`tests/runtime_artifact_bottom_boundary_smoke.gd` executes the real DLL and
proves that a protected bedrock sample rejects an overlapping edit while the
adjacent unprotected sample changes.

To refresh the dependency after an authoritative upstream build:

```text
python tools/sync_tqp54_candidate.py --authority-source <world-transvoxel>/addons/world_transvoxel --apply
```

After synchronization, update the runtime pin from the authoritative commit
and generated DLL hashes, then run the runtime-artifact validator and the real
Godot integration tests. Native behavior is changed only upstream.
An intentional refresh from a newer authority commit additionally requires
`--allow-unpinned-authority`; ordinary synchronization refuses any source that
does not match the current runtime pin.
