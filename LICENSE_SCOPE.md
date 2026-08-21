# License Scope

Project-owned source code, scripts, scenes, shaders, tools, configuration, and
documentation in this repository are licensed under the Zero-Clause BSD license
(`0BSD`) in `LICENSE`, unless a file or directory explicitly states otherwise.

The repository also contains material under separate terms:

- The binary-only `addons/world_transvoxel/` runtime artifact incorporates the
  MIT-licensed Transvoxel implementation. Its copyright, permission, and
  provenance notices are retained under
  `addons/world_transvoxel/thirdparty/transvoxel_mit/`; native source remains in
  the standalone `world-transvoxel` authority repository.
- `addons/world_transvoxel/LICENSE_SCOPE.md` and
  `addons/world_transvoxel_terrain/LICENSE_SCOPE.md` define the license
  boundaries of those bundled addons.
- Third-party terrain textures identified in the
  `assets/terrain_textures/material_layers/THIRD_PARTY_TEXTURES.md` notice are
  CC0 / public domain. Other generated reference textures are identified in the
  same notice.
- Generated imported resources under `.godot/imported/` retain the licensing
  terms of the source assets from which they were produced.

The root 0BSD license does not replace or remove these third-party notices.
