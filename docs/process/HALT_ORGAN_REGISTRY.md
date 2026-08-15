# Halt-organ registry (RESILIENT-326)

**Standing rule (governance, P0):** no organ may halt or disable the fleet
(stop workers, zero autonomy, pause the conductor) without **(a)** a TESTED
auto-recovery path — a test that proves it un-halts on its own, not by hand —
and **(b)** a loud page to the operator when it halts. This doc is the
enumeration; `scripts/coord/halt-status.sh` is the board instrument that
surfaces any organ currently in a halted state; `scripts/ci/test-halt-organ-registry.sh`
is the CI gate that keeps this table honest (fails if an entry's script,
page-call, or recovery test goes missing).

Born from the 2026-08-14 back-pressure hysteresis dead-zone incident
(RESILIENT-324 evidence): the breaker halted the fleet for hours with no
working auto-recovery and no page that reached the board — a silent SPOF.
Any organ with that shape is the same incident waiting to recur under a
different name.

## The organs

| Organ | Halt trigger | Halt mechanism | Auto-recovery path | Recovery test | Page on halt |
|---|---|---|---|---|---|
| **back-pressure breaker** | `scripts/ops/back-pressure-controller.sh`: stuck-PR pile (BLOCKED/DIRTY) >= `HALT_AT` (default 6) | `systemctl disable --now chump-worker@N`, `AUTONOMY_LEVEL=0` | Fast resume at pile<=`RESUME_AT` (3); RESILIENT-324 stuck-clock escape force-resumes after `STUCK_ESCAPE_SECS` (default 30m) even inside the 4-5 hysteresis dead-zone | `scripts/ci/test-back-pressure-hysteresis.sh` | `notify_operator` (Discord DM) on halt, `scripts/coord/lib/notify-operator.sh` |
| **fleet kill-switch** (`AUTONOMY_LEVEL`) | Any writer of `~/.chump/AUTONOMY_LEVEL=0` — `scripts/ops/chumpbar-pause.sh` (operator-driven, ChumpBar menu), back-pressure breaker, operator | `chump claim` / `bot-merge` / `worker.sh` fail-closed when level is 0, missing, or corrupt | Not self-recovering by design — this is the deliberate human/breaker-owned dial, not a wedge. Callers that set it to 0 (back-pressure) own their own auto-resume (see row above); `chumpbar-pause.sh` is an explicit operator action, not a silent halt | `scripts/ci/test-fleet-kill-switch.sh` | N/A — kill-switch itself doesn't page; the *setter* (back-pressure breaker) pages. `chumpbar-pause.sh` is a deliberate operator action, so no page is needed (the operator already knows) |
| **waste-spike pause** (`.chump/fleet-paused` sentinel, waste path) | `scripts/coord/waste-spike-detector.sh`: waste rate > `CHUMP_WASTE_SPIKE_THRESHOLD` (default 30%) | Writes `.chump/fleet-paused`; worker/claim paths fail-closed while it exists | Auto-clears after 2 consecutive checks below `CHUMP_WASTE_RECOVERY_THRESHOLD` (default 20%); `src/fleet_self_rescue_conductor.rs` additionally clears a *stale* pause + kicks `ci-health-gate` if the fleet stays wedged, gated by an objection-window `-1` veto broadcast via `scripts/coord/broadcast.sh` | `scripts/ci/test-waste-spike-pause.sh`; `src/fleet_self_rescue_conductor.rs` unit tests `dial_zero_halts`, `wedge_via_pause_dryrun_does_not_act` | RESILIENT-326: `notify_operator` on pause (added — was silent-halt before this gap); conductor's un-pause action broadcasts via `broadcast.sh` |
| **ci-health-gate pause** (`.chump/fleet-paused` sentinel, SLO/jam path) | `scripts/coord/ci-health-gate.sh`: L1 SLO breach (`chump health --slo-check`) or pipeline jam (>= `CHUMP_CI_HEALTH_JAM_THRESHOLD`% BLOCKED PRs) | Writes `.chump/fleet-paused`; worker/claim paths fail-closed while it exists | Auto-clears after 2 consecutive clean runs (SLO pass + blocked_pct below `CHUMP_CI_HEALTH_JAM_RECOVERY`); kicks the recovery-daemon choir via `launchctl kickstart` once cleared | `scripts/ci/test-fleet-pause-autolift.sh`, `scripts/ci/test-ci-health-gate.sh`, `scripts/ci/test-slo-breach-gates.sh` | RESILIENT-326: `notify_operator` on pause (added — was silent-halt before this gap) |
| **farmer/worker-gate heartbeat** | `scripts/coord/farmer.sh` heartbeat stale (>120s) → `chump farmer status` RED → `chump claim`/`chump gap reserve` refuse new claims (RESILIENT-069) | Fail-closed gate keyed off heartbeat freshness, not an explicit halt call | `chump-farmer.timer` (30s cadence, RESILIENT-313) keeps the heartbeat fresh; a dead farmer is itself revived by the organ-watchdog (`scripts/ops/organ-watchdog.sh`, systemd `start-limit-hit` reset + restart) | `scripts/ci/test-farmer-stale-lease-heartbeat.sh`, `scripts/ci/test-farmer.sh`, `scripts/ci/test-farmer-drain-guard.sh` | `operator_page()` in `scripts/coord/farmer.sh` on `AUTH_DEAD` / `DAEMON_CRASH_LOOP` classes |

## Adding a new halt organ

Any new code path that can stop workers, zero `AUTONOMY_LEVEL`, or write a
pause sentinel MUST add a row to the table above in the same PR, with:

1. A script/module path for the halt trigger.
2. A **tested** auto-recovery path (not "an operator will notice") — the test
   must fail if the recovery logic is reverted.
3. A page call (`notify_operator`, `operator_page`, or `operator-recall.sh`)
   that fires on halt.

`scripts/ci/test-halt-organ-registry.sh` enforces (1)-(3) mechanically by
parsing this table and grepping the referenced files — it fails closed if a
row's script, recovery test, or page-call goes missing.
