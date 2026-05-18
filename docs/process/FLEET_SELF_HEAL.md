# Fleet self-heal — INFRA-1595 (Wave 0b)

> The autonomy outer loop. Catches gaps that the inner loops missed and
> dispatches fixes without operator intervention.

## Overview

Three inner loops already protect the fleet:

| Loop                | Scope                    | Daemon                  |
| ------------------- | ------------------------ | ----------------------- |
| paramedic           | Stuck PRs (per-PR rules) | `com.chump.paramedic`   |
| pr-rebase watchdog  | PRs behind main          | `com.chump.pr-rebase`   |
| chump-fleet-bootstrap | Daemon install on fresh machine | one-shot at setup |

But three failure modes still required operator detective work:

1. **Paramedic dies and doesn't get restarted** — launchd usually catches
   this via `KeepAlive`, but the plist itself can drift if a developer
   reboots without re-running bootstrap.
2. **Bootstrap missed a daemon** — bootstrap is a one-shot; if a new
   daemon is added to the manifest later, machines installed earlier
   never pick it up.
3. **A PR escapes paramedic's per-rule scope** — e.g. an `BLOCKED` PR
   that's been sitting for 45 min with no progress markers and no
   matching paramedic rule.

`chump fleet doctor --heal` is the outer loop that watches for all three
and acts on each.

## The loop

```
every 5 minutes (via com.chump.self-doctor launchd plist):
  for daemon in REQUIRED_DAEMONS:
    if not launchctl_loaded(daemon.label):
      run daemon.install_script    # idempotent re-install
      emit self_doctor_healed { action: daemon_installed, daemon }

  stuck_prs = gh pr list (DIRTY | BLOCKED) where updated_at < now - 30min
  for (pr, gap_id) in stuck_prs:
    if recent_dispatches_10min >= CHUMP_SELF_DOCTOR_BUDGET (default 3):
      emit self_doctor_budget_exceeded
      write .chump-locks/operator-action-needed.json
      break
    spawn `chump --execute-gap <gap_id>` (detached)
    log to .chump-locks/self-doctor-dispatch.log
    emit self_doctor_healed { action: pr_dispatched, pr, gap_id }

  if nothing happened:
    emit self_doctor_tick { status: idle }
```

## What gets healed

| Failure                       | Action                                       |
| ----------------------------- | -------------------------------------------- |
| Missing/unloaded daemon       | Run its `install-*.sh` script (idempotent)   |
| PR DIRTY/BLOCKED > 30 min     | Spawn `chump --execute-gap <gap_id>`         |

## What does NOT get healed

- **PRs without a parseable gap-id in the title** — we can't dispatch
  without one. (Most chump PR titles follow `feat(INFRA-NNNN): …` so
  this is rare; when it happens, operator surfaces the PR manually.)
- **PRs that paramedic has already declined** — out of scope for the
  outer loop; if paramedic decided not to act, self-doctor doesn't
  second-guess.
- **Daemons NOT in `REQUIRED_DAEMONS`** — adding a new daemon requires
  a one-line edit in `src/fleet_self_doctor.rs` AND an entry in
  `scripts/setup/bootstrap-manifest.yaml`. This is intentional: every
  daemon-add gets a code-review touchpoint.

## Circuit breaker

`CHUMP_SELF_DOCTOR_BUDGET` (default 3) caps subagent spawns per 10-minute
window. When tripped:

1. Doctor stops dispatching this cycle.
2. Emits `self_doctor_budget_exceeded` with `{budget, recent, pending}`.
3. Writes `.chump-locks/operator-action-needed.json` with the dispatch
   log path + pending stuck-PR list.

The next cycle (5 min later) re-evaluates the rolling window; older
dispatches fall out and the doctor can resume.

**Why a budget?** Without it, a misbehaving outer loop could dispatch
50 subagents in a flap and burn the daily Anthropic quota in minutes.
3 dispatches per 10 min is enough to clear a real backlog without
hiding a bug behind throughput.

## Operator-page contract

When the budget trips, `.chump-locks/operator-action-needed.json`:

```json
{
  "ts": "2026-05-16T12:34:56Z",
  "source": "fleet_self_doctor",
  "reason": "self_doctor_budget_exceeded",
  "budget": 3,
  "used": 5,
  "window_secs": 600,
  "pending": [
    {"pr": 2096, "gap_id": "INFRA-1499"},
    {"pr": 2102, "gap_id": "INFRA-1531"}
  ],
  "action": "Self-doctor hit budget (5/3) in 600s window. Review .chump-locks/self-doctor-dispatch.log + stuck PRs manually."
}
```

Consumed by the PWA operator dashboard (and `chump health --slo-check`
will flag a non-empty file as an SLO breach in a follow-up).

## Opt-in (Wave 0b ships default-OFF)

Heal mode is **opt-in** via env:

```bash
export CHUMP_FLEET_SELF_DOCTOR_HEAL=true
# or:
launchctl setenv CHUMP_FLEET_SELF_DOCTOR_HEAL true
launchctl kickstart -k gui/$(id -u)/com.chump.self-doctor
```

Without that env, `chump fleet doctor --heal` exits 0 with a refusal
message and emits no actions. Diagnose-only mode (`chump fleet doctor`
with no flags) still emits `self_doctor_tick` so cadence is observable.

After INFRA-1541's 50-PR observation phase shows the loop behaves, a
follow-up will flip the default to ON.

## Files

- `src/fleet_self_doctor.rs` — heal loop, daemon registry, stuck-PR
  discovery, circuit breaker.
- `src/main.rs` `fleet doctor` arm — CLI binding.
- `scripts/setup/com.chump.self-doctor.plist` — launchd timer (300s).
- `scripts/setup/install-self-doctor.sh` — idempotent installer.
- `scripts/setup/bootstrap-manifest.yaml` — `self-doctor-launchd` entry
  so `chump-fleet-bootstrap.sh --check` verifies it.
- `scripts/ci/test-self-doctor-heal.sh` — CLI smoke test (Rust unit
  tests in `src/fleet_self_doctor.rs::tests` cover the heal logic).
- `docs/observability/EVENT_REGISTRY.yaml` — 4 event-kind entries.

## Related

- INFRA-1427 — `chump fleet doctor --strict` (diagnose layer; this
  module extends it with heal).
- INFRA-1594 — bootstrap completeness check (catches missing daemons
  at setup time; self-doctor catches them in-flight).
- INFRA-1410 — PR-stuck SLO + auto-respawn (paramedic-tier).
- INFRA-1375 — paramedic (per-PR rule engine).
- INFRA-1541 — 50-PR AC-coverage observation phase (gates default-on flip).
- See [`docs/ROADMAP_WAVES.md`](../ROADMAP_WAVES.md) Wave 0b for context.
