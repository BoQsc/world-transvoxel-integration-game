# CPU-B3P Shared Work Budget Outcome

The opt-in shared two-slot CPU work budget was tested in a disposable
integration worktree against the accepted serial-meshing configuration. Both
configurations ran the same 2 km production route under exact logical CPU
affinity `[0, 1, 2]` with Godot 4.7.2.

The limiter itself behaved correctly: the candidate reported capacity two,
maximum active work two, and roughly five thousand grants per run. Median
relocation readiness improved by 20.1%, but that gain did not translate into a
better player-facing baseline. Median blocked movement rose from 4.5 to 17
frames, maximum mesh work more than doubled from 68.6 ms to 142.1 ms, and
collision apply deadline overruns rose from 150 to 260.5. Frame p95 changed by
less than one percent.

The candidate is rejected. Authority commit `afd0771` was reverted by
`90db7e5`; the accepted configuration remains two storage workers, serial
meshing, and no shared CPU work budget. No candidate integration wiring is part
of the accepted game.

See `qualification.json` for the paired measurements and claim boundary.
