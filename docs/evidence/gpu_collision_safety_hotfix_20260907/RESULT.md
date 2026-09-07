# GPU collision safety hotfix

Native authority: `6e17ae5a26c2a873bf712ca735e9632580b26354`

The incremental dirty-block collision publication introduced at `98b3805` was
not safe for player use. A dirty-block mesh could replace an installed block
without complete ownership-halo geometry, and a complete empty payload could
remove installed support before its matching visual generation activated.

This checkpoint restores complete CPU LOD0 collision extraction for density
edits and stages every full replacement, including empty replacements, until
the matching GPU visual activation. The eight-block sink layout remains, but
partial collision publication is disabled until its extraction contract is
proven with ownership halos.

## Verification

- Native debug and release builds pass `test_wt_m3_application`; release also
  passes `test_wt_m5_page_meshing_runtime` and `test_wt_production_streaming`.
- The new Vulkan and D3D12 collision-continuity smoke keeps an unmodified player
  support ray valid and retains at least one collision resource throughout a
  boundary-straddling carve and replacement.
- Vulkan and D3D12 rapid-edit smokes pass 12 edits with zero mixed revisions.
- Vulkan and D3D12 production lifecycle smokes pass with CPU collision authority
  and zero geometry readback.
- The full `g23` runtime-baseline route retained collision resources, had zero
  collision sink failures, found its physics edit target immediately, and
  completed the collision generation. It still failed the performance gates:
  collision readiness was 243 frames / 4.16 seconds after commit, with 29
  blocked movement frames. This safety checkpoint does not qualify instant
  editing.

The small continuity route also passed against the prior DLL, so it is retained
as a forward safety invariant rather than claimed as a reproduction of the
reported human-playtest fall. The unsafe state transition is proven directly by
the native application test: an empty replacement now remains deferred until
matching visual activation.
