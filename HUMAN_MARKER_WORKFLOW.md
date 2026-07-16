# Human Marker Workflow

This project uses human markers for issues that depend on exact player/camera
position, such as cave entrance LOD popping, material boundary shifts, or small
visible holes.

The marker workflow is intentionally narrow:

1. Launch the normal human playtest.
2. Move to the exact point where the issue is visible.
3. Press `Tilde+M`.
4. Repeat at nearby useful points, for example close, mid, far, and return.
5. Replay those exact points with `tools/inspect_human_marker_path.py`.

The marker replay captures each point twice:

- immediate: directly after moving the replay camera/player to the marker;
- settled: after a fixed wait, so loading/transient replacement can be separated
  from stable LOD/material behavior.

Default cave inspection command:

```sh
python tools/inspect_human_marker_path.py --latest 3
```

Launch at the latest marked point interactively:

```sh
python tools/run_human_playtest.py --inspect-latest-marker
```

Launch at a specific marker interactively:

```sh
python tools/run_human_playtest.py --inspect-marker path/to/marker.json
```

Markers are stored under:

```text
.godot/world_transvoxel_captures/human_artifact_marks/
```

Sequence reports are stored under:

```text
.godot/world_transvoxel_captures/human_artifact_marks/sequences/
```

Do not treat a visual issue as fixed until the exact human marker path is
replayed and the immediate/settled captures support the claim.
