# Standard multiplayer and dedicated-server contract

Status: active future-compatibility standard. Multiplayer gameplay is not
implemented or claimed by this integration game yet.

This project is the human-playable reference for the World Transvoxel addon
stack. It must not make terrain decisions that block future multiplayer,
persistent worlds, or large dedicated servers.

## Research basis

Godot's official high-level multiplayer documentation recommends
server-authoritative gameplay-critical logic, validating RPC arguments before
applying state, avoiding trust in client-reported values, and rate limiting
frequently triggered actions:

- https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html#secure-multiplayer-design

Godot dedicated servers are expected to run through `--headless` or a dedicated
server export, and dedicated server exports can strip client-only visual
resources while preserving project references:

- https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html
- https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html

The core addon standard is:

- `world-transvoxel/docs/contracts/PRODUCTION_MULTIPLAYER_SERVER_COMPATIBILITY_CONTRACT.md`

## Standard authority rule

The server owns terrain authority:

- density samples;
- material samples;
- source revision;
- world revision;
- edit journals;
- snapshots/compactions;
- validation of edit commands and viewer-interest requests.

Clients own presentation:

- camera/player input intent;
- local render meshes;
- local collision presentation;
- materials, lighting, and UI;
- local screenshots and artifact marks.

Client presentation may be useful evidence, but it is never terrain truth. If a
client mesh disagrees with authoritative samples or committed revisions, the
client mesh is wrong.

## Current single-process implementation boundary

The current game runs single-process local play, but it must preserve the
future split:

- `world_transvoxel` owns native terrain authority primitives;
- `world_transvoxel_terrain` exposes the stable terrain/world API wrapper;
- `world_transvoxel_gameworld` submits player/game intent into the terrain
  boundary and reports summaries;
- `scripts/main.gd` is a reference game scene and proof harness, not a server
  authority implementation.

The current reference can simulate server-compatible behavior only by checking
that the public terrain world exposes:

- world source and world revisions;
- viewer-interest update/removal with monotonic viewer revisions;
- edit submission and commit/failure signals;
- authoritative sample queries;
- world snapshot and migration requests;
- bounded runtime metrics and cold-idle/settlement summaries.

## Required behavior for future multiplayer

Future multiplayer work must use this sequence:

1. Client sends intent, not terrain truth.
2. Server validates peer, bounds, revision, shape, material, rate limits, and
   budgets.
3. Server commits accepted edits as ordered transactions.
4. Server publishes committed world revisions or snapshot/page state.
5. Clients rebuild render/collision presentation from authoritative samples.

Stale client revisions must be rejected or explicitly rebased. They must not be
applied silently.

## Dedicated-server requirements

Any future `world_transvoxel_gameworld` server mode must start without requiring:

- fullscreen/window setup;
- player camera;
- crosshair or human HUD;
- texture import cache for terrain authority;
- render material override;
- GPU compute or render resources.

Those systems can exist on clients and local playtests. They cannot be required
for terrain authority, persistence, or validation.

## Large-server requirements

The standard terrain/gameworld path must preserve:

- bounded active chunk/page sets;
- explicit capacities and rejections;
- event-driven edit invalidation;
- no full-world hot-path scans;
- source/world revision tagging on derived work;
- deterministic stale-result rejection;
- durable journal/snapshot recovery;
- multi-viewer interest as streaming demand, not terrain existence.

Unloaded client terrain is not lost world state. The server must retain or be
able to reconstruct the authoritative state for edited regions according to
storage and retention policy.

## Non-negotiable rules

- Do not synchronize terrain by trusting client meshes.
- Do not save or replicate visual LOD state as authoritative terrain.
- Do not hide network or LOD correctness problems with presentation fallbacks.
- Do not require GPU/render resources for server terrain correctness.
- Do not accept unvalidated terrain edits from clients.
- Do not claim multiplayer/dedicated-server readiness until explicit gates are
  implemented and passed.

## Required current gate marker

The P2 production integration proof must print:

```text
WT_STANDARD_MULTIPLAYER_SERVER_CONTRACT_PASS
```

That marker means only that the current runtime still exposes the authority
primitives required by this contract. It does not mean multiplayer netcode,
anti-cheat, matchmaking, sharding, or dedicated-server deployment is complete.
