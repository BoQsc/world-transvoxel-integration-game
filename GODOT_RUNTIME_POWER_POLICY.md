# Godot runtime power policy notes

These notes are intended to transfer to future Godot projects that use
`world_transvoxel`, `world_transvoxel_terrain`, or `world_transvoxel_gameworld`.
They are not specific to one terrain profile.

## Observed behavior

- A stationary camera can use more GPU than a moving camera.
- Moving can reduce reported GPU usage because the runtime becomes CPU,
  streaming, or chunk-update bound. In that case the GPU is waiting for work, not
  necessarily doing less total terrain work.
- A focused but stationary Godot game can keep rendering a fully static terrain
  view at the active frame cap.
- A backgrounded or unfocused Godot window can still consume high GPU unless the
  project applies an explicit background policy.

Do not treat lower GPU usage while moving as proof that moving is cheaper. It may
mean the GPU is starved by CPU-side terrain, streaming, or LOD work.

## Standard policy

Every human-playable Godot terrain/world project should define a frame policy
instead of relying on the default renderer behavior:

- active foreground play: 60 FPS;
- focused but idle/stationary play: 30 FPS after a short delay with no player
  input, movement, or queued terrain work;
- unfocused/background execution: 15 FPS.

The project setting should include:

```text
run/max_fps=60
```

The main scene should also adjust `Engine.max_fps` at runtime based on focus and
idle state, because `run/max_fps` alone does not distinguish active play from an
idle or background window.

## Idle detection rules

Do not enter the focused-idle cap while any of these are true:

- recent keyboard, mouse, edit, or camera input happened;
- the player/camera is moving;
- terrain render work is queued;
- terrain collision work is queued;
- chunk retirement, replacement, fade, or streaming burst work is still active;
- a visual capture, autonomous proof, or benchmark intentionally needs stable
  active-frame behavior.

Idle throttling is a power policy, not a terrain correctness fix. It must not
hide streaming gaps, edit popping, material flashes, or mesh artifacts.

## Current implementation in this project

`scripts/main.gd` implements the current policy:

- `FOREGROUND_MAX_FPS = 60`;
- `IDLE_MAX_FPS = 30`;
- `BACKGROUND_MAX_FPS = 15`;
- focused-idle transition delay: roughly 1.2 seconds.

This should be copied or reimplemented in future gameworld projects unless a
project has a stronger platform-specific frame pacing system.

## Measurement guidance

When comparing GPU usage, test these states separately:

1. focused active movement;
2. focused stationary after at least two seconds;
3. focused stationary while terrain work is still queued;
4. unfocused/backgrounded;
5. minimized if the target platform treats minimized windows differently.

Record FPS, CPU usage, GPU usage, visible chunk count, and queued terrain work.
Without those, GPU percentage alone is ambiguous.
