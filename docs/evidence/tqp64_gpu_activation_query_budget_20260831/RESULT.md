# GPU Initial Activation Query Budget

Status: `TQP64_SAMPLED_GPU_LOD_PASS_GAMEPLAY_REJECTED_RELEASE_OPEN`.

This is an experimental implementation checkpoint, not an accepted GPU
performance baseline. CPU remains default; GPU remains opt-in. Parent integration
commit: `e771b77`. Native runtime remains `236045f80a2388d691c35a08fc614fef87c3d7d0`,
artifact SHA-256 `d96d92d8e951016631ae955132c6da6a72832480d54c0fa8a145814243752089`.
Godot 4.7.2 Steam, GTX 1060 Max-Q, affinity `[0,1,2]`, two procedural workers and
zero mesh workers. No native source or DLL changes belong to this checkpoint.

## What Changed

After preparing a GPU group, `_try_validate_group` previously queried the native
activation cohort immediately. Eight groups prepared in one frame could make
eight queries outside the existing one-attempt-per-frame retry budget, including
repeated queries for members of the same waiting region.

Newly prepared groups now join the existing deduplicated FIFO retry queue.
Initial and repeated controller activation attempts share its existing budget.
Native commit still recomputes and validates the authoritative cohort; this is
not a claim of at most one total native validation call per frame.

The focused regression fails before the fix with `unbudgeted_calls=8` and
passes afterward with `initial_budget=1`. It covers repeated preparation,
deduplication, older queued work receiving its turn, and a cancelled group not
consuming the next turn. The existing publication-ordering tests remain enabled.
The before/after logs are retained here.

The change is retained as budget enforcement on the experimental path, not as
a demonstrated improvement to the whole game. It does not change priority,
queue capacities, workers, LOD masks, cohort membership, collision safety,
movement guards, or timeouts. There is no CPU visual fallback.

## Diagnostics-Off Gameplay

The existing `run_runtime_readiness_probe.py --backend gpu --no-probe` route and
acceptance thresholds are unchanged. Each JSON retains its exact command,
native pin, execution result, and full measurement. All three runs below fail.

| Controller | Blocked Steps / 1,020 | Longest Block | Post-Draw p95 / p99 | First Target |
| --- | ---: | ---: | ---: | --- |
| Parent, initial queries unbudgeted | 504 | 132 | 86.713 / 120.033 ms | Missing after 2,999.088 ms |
| Shared budget, first run | 586 | 102 | 43.975 / 59.388 ms | Missing after 3,010.125 ms |
| Shared budget, repeat | 555 | 161 | 41.012 / 64.890 ms | Missing after 2,981.684 ms |

These are rendered post-draw intervals, not physics-signal intervals. The repeat
supports a narrower frame-pacing observation, not a qualified speedup: realized
movement differs, more movement steps were blocked, and the longest block was
worse in the repeat. Neither candidate run accepts an edit. Edit commit, visual,
and collision latency remain censored, not completed three-second edits.
The miss endpoint `(35,-2,35)` must not be treated as a proven terrain hit.

The parent measurement and CPU/default control remain in
`../tqp64_gpu_collision_promotion_20260831/`. The CPU control completes and accepts
its edit but still misses latency targets. There is no evidence here for a CPU
hardware limit, GPU/CPU performance parity, lower power, or smooth gameplay.

## Moving LOD And Lifecycle

The unchanged Vulkan `streaming_fly_gap_gate` passes all 25 sampled views and
the strict final drain. It ends with 1,219 fully ready chunks, zero pending
replacements/retirements, zero native validation rejections, zero controller
rejections, and zero failed GPU extractions. The capture command and complete
summary are retained in `moving_lod_command.json` and `moving_lod.json`.

Final readiness takes **368 frames / 21,347.841 ms** after movement. The earlier
indexed checkpoint drained in 14,494 ms on a different native pin; this is not
a controlled same-pin regression measurement, but it is not an improvement to
claim. Total capture wall time is 206.008 seconds.

The progress samples expose another remaining wait: from drain frame 120 to
360, native jobs and GPU extraction queues are empty and 1,219 GPU chunks stay
active, while pending activation retries decrease from 246 to 6, one per frame.
Native replacements and retirements remain pending until the final drain.
This is evidence to isolate stale retry/retirement cleanup, not proof that all
pending entries are stale or permission to discard authoritative coverage.
`last_activation_wait` is historical state, not necessarily the current blocker.

This visual gate does **not** prove full watertightness. The GPU CPU-topology
probe is disabled, no sample runs the geometry probe, and the raw
`watertightness.enabled=false, ok=true` is a skipped check. The 25 samples check
screen-gap candidates and publication/retained coverage. Representative project
captures are retained as `peak_sweep.png` and `low_slope.png`. Dark road-like
bands also occur in earlier captures and are not classified as holes from
colour alone. There is no new human acceptance.

Vulkan and D3D12 bounded production lifecycle tests both pass, including three
activated chunks, two water surfaces, CPU collision authority, and zero geometry
readback. These checks do not replace post-edit terrain/water or cross-backend
gameplay qualification. See `lifecycle.json` and `integration_checks.json`.

## Remaining Gates

1. Isolate and resolve destination generation-to-activation/collision waits and
   stale retry cleanup without removing required LOD or coverage dependencies.
2. Complete the unchanged movement and relocated digging/construction workload;
   improve both frame pacing and interaction readiness, not one at the other's
   expense.
3. Complete post-edit terrain/water geometry, Vulkan/D3D12 gameplay, matched
   performance/power comparison, and human acceptance.

The inherited M5 wrapper fingerprint mismatch is still open. The executable's
functional assertions pass, but the wrapper is not green. Its expected hash
is not changed here; see the parent checkpoint for both hashes and evidence.
Do not label this checkpoint as accepted or final GPU terrain.
