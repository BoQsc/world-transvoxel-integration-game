# CPU-B3M Stage-Aware Dispatch

This qualification tested the final bounded CPU scheduler candidate after
CPU-B3L exposed mixed-stage head-of-line blocking. With two mesh workers and a
two-job mesh admission limit, the runtime control thread could dequeue the
highest-priority sample job when mesh admission was full.

## Correctness Result

- The complete causal trace retained 103,823 native events with no local or
  downstream drops.
- Maximum worker concurrency was two and the waiting queue never exceeded two
  jobs.
- Both edit destinations were fully ready before edit submission.
- The construction publication retained exact membership: 883 replacements
  and 328 retirements.
- The route recorded 181 blocked flight frames, all during the construction
  relocation.

The first blocked flight frame had 622 collision-required chunks not ready,
456 pending and blocked replacements, 364 scheduler jobs, 80 queued storage
requests, two active mesh workers, and two waiting mesh jobs. This is a direct
interaction regression, not a cosmetic timing difference.

## Performance Result

| Metric | Accepted serial baseline | Stage-aware two-worker candidate |
| --- | ---: | ---: |
| Frame p99 | 65.078 ms | 65.285 ms |
| Carve | 3761.663 ms | 413.847 ms |
| Construct | 3086.091 ms | 4661.738 ms |
| Flight distance | at least 536.005 m | 440.268 m |
| Blocked flight frames | 0 | 181 |
| Average active cores | 1.181 | 1.227 |
| Saturated sample fraction | 0.033 | 0.071 |

The fast carve does not qualify the candidate. Construction regressed by
51.1%, flight was blocked, and the second relocation reached only 159.220 m.
The route therefore diverged from the accepted comparison route before the
construction edit.

## Decision

Reject and revert stage-aware dispatch. The candidate authority commit
`d1e1d66efe2c6352e940a2913c7163f150ac6686` was reverted by
`a00d95fdeb474600909ee397784dc8ae894db5cf`. Rebuilding the revert produced the
same debug and release DLL hashes as the accepted bounded-admission authority
state, proving that the experimental behavior was removed.

Serial meshing (`meshing_worker_count = 0`) remains the authoritative default.
The bounded worker implementation remains opt-in for diagnostics only. CPU-B3K
through CPU-B3M are sufficient to stop scheduler-candidate churn: none of the
bounded CPU worker variants improved relocated edit latency and frame behavior
without a regression. The next milestone is a GPU architecture decision based
on the restored serial CPU baseline, not immediate GPU selection or
implementation.

## Claim Boundary

Tracing is intentionally intrusive. These results are authoritative for causal
ordering, bounded worker behavior, candidate rejection, and restoration. They
are not a trace-off release performance baseline. Raw captures are not
committed; `qualification.json` retains their identities and decisive values.
