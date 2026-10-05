# Halt-recovery governance (RESILIENT-326)

**Rule:** no organ may halt/disable the fleet (stop worker units, zero
`AUTONOMY_LEVEL`, pause the conductor) without (a) a **tested** auto-recovery
path back to running, and (b) a **loud page** to the operator at the moment
of halt. A halt with no proven un-halt is a latent multi-hour outage — see
the 2026-08-14 back-pressure incident (RESILIENT-324) and the
2026-08-15 disk-critical-reactor incident this gap fixed.

## Organs that can halt/disable the fleet

| Organ | Halt trigger | Auto-recovery | Loud page | Tested by |
|---|---|---|---|---|
| `scripts/ops/back-pressure-controller.sh` | stuck-PR pile >= `HALT_AT` (6): disables `chump-worker@N`, sets `AUTONOMY_LEVEL=0` | Fast resume at pile<=`RESUME_AT`; **RESILIENT-324 stuck-escape** forces resume after `STUCK_ESCAPE_SECS` (default 30m) even in the 4-5 hysteresis dead-zone | `notify_operator` on halt | `scripts/ci/test-back-pressure-hysteresis.sh` |
| `scripts/coord/disk-critical-reactor.sh` (`quiesce_and_reclaim`) | shared cargo target over `SHARED_TARGET_CAP_GB`: sets `AUTONOMY_LEVEL=0`, kills builds, boots out deploy daemons | **RESILIENT-326**: prior autonomy level saved and restored on *both* exit paths (reclaimed and aborted) — a stuck build can no longer strand the halt permanently | `operator-recall.sh --condition DISK_CRITICAL` fired at halt time (previously only fired as a last resort after a failed post-reap check) | `scripts/ci/test-disk-reactor-halt-recovery.sh` |
| `scripts/ops/organ-watchdog.sh` §3 (worker liveness) | doesn't itself halt — detects 0 active `chump-worker@{1,2}` for >= `WORKER_HALT_MIN_SECS` regardless of *which* organ caused it | N/A (detector, not an actor) — pairs with the *actor* organs above, whose own auto-recovery is what actually resumes | `operator-recall.sh --condition WORKER_HALT` | `scripts/ci/test-organ-watchdog.sh` |
| `scripts/ops/chumpbar-pause.sh` | explicit operator command (`chumpbar-pause.sh <node> pause`) sets `AUTONOMY_LEVEL=0` | N/A by design — an operator-issued pause is not a fault to auto-heal from; the operator issues the matching `resume` | N/A — the operator *is* the actor, no page needed for their own action | `scripts/ci/test-fleet-kill-switch.sh` (kill-switch contract) |

`chumpbar-pause.sh` is deliberately excluded from the auto-recovery
requirement: it is a direct, operator-initiated action, not an autonomous
organ deciding to halt production on its own judgment. The requirement in
this doc targets organs that make that call *without* a human in the loop at
the moment of the halt.

## Adding a new halt-capable organ

Before shipping any new code path that stops worker units, zeroes
`AUTONOMY_LEVEL`, or pauses the conductor without an operator issuing that
exact command in the moment:

1. Add a row to the table above.
2. Ship a CI test (`scripts/ci/test-*.sh` or `cargo test`) that drives the
   organ through halt -> auto-resume using its test hooks, and confirm it
   **fails on the pre-fix code** (regression-proof, not just happy-path).
3. Confirm the halt path calls `scripts/dispatch/operator-recall.sh` (or
   `scripts/coord/lib/notify-operator.sh`) at the moment of halt, not only as
   a fallback after a failed recovery attempt.
