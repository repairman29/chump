---
name: duty-officer
description: Chump's standing duty-officer curator (RESILIENT-274) — the standing owner of fleet health that removes the operator as the incident-response single point of failure. Watches ambient health signals (ambient.jsonl kinds, ship-rate, disk, auth, wedges), looks each up in docs/process/PLAYBOOK_REGISTRY.yaml, and routes it T1 (executable auto-heal) -> T2 (agent-run runbook, REALITY_CHECK first) -> T3 (escalate, only novel/halt-class). Use to (1) run one full duty-officer tick, (2) route a single named signal manually, (3) check registry coverage, (4) emit a liveness heartbeat. **This skill is a thin wrapper over `scripts/coord/duty-officer-loop.sh`**. Examples that should trigger this skill: "run the duty-officer loop", "what would page the operator right now", "route this signal through the playbook registry", "is anyone on duty", "duty-officer heartbeat", "duty-officer status".
user-invocable: true
allowed-tools:
  - Bash
---

# /duty-officer — Standing Owner of Fleet Health

The Duty-Officer curator makes [`docs/design/DUTY_OFFICER.md`](../../docs/design/DUTY_OFFICER.md) real: a continuous loop that watches health signals and routes each one T1 (executable auto-heal) → T2 (agent-run runbook) → T3 (escalate), paging the operator ONLY at T3. The canonical surface is the harness-neutral shell CLI at `scripts/coord/duty-officer-loop.sh`. Any harness invokes the same script.

Arguments passed: `$ARGUMENTS`.

## Routing

Parse `$ARGUMENTS`:
- Empty / `tick` → scan the recent ambient window and route every kind that has a registry entry
- `route <signal>` → route one named signal manually (test/manual invocation)
- `heartbeat` → emit `kind=duty_officer_heartbeat` (liveness proof)
- `status` → print registry coverage summary
- `help` → print usage

```bash
scripts/coord/duty-officer-loop.sh ${ARGUMENTS:-tick}
```

Surface stdout verbatim. The script emits structured `kind=duty_officer_action` events — don't re-paraphrase the verdicts.

## What a tick does

1. Scans the last N ambient lines (`CHUMP_DUTY_OFFICER_WINDOW_N`, default 200) for kinds.
2. For each kind with an entry in [`docs/process/PLAYBOOK_REGISTRY.yaml`](../../../docs/process/PLAYBOOK_REGISTRY.yaml), routes it through `cmd_route`:
   - **tier 1** — the action already fired (a daemon/script); logs `verdict=healed`.
   - **tier 2** — if the entry declares a `false_positive_class`, runs the reality-check gate first; `REFUTED` → `verdict=refuted` (dropped, no action); confirmed → `verdict=runbook_needed` (an agent must run the matching playbook next).
   - **tier 3** — looks up the quiet gate (`scripts/coord/operator-escalation-registry.txt`); `suppress` → `verdict=suppressed`; otherwise `verdict=paged` and the operator is notified over the Discord substrate.
   - No registry entry → `verdict=unregistered`, defaults to page (novel = loud).

## After a tick: act on the verdicts

- `runbook_needed` → run the matching playbook doc from the registry's `action` field as a real runbook: diagnose, fix at the root cause, confirm the registry's `verify` outcome (not just exit 0).
- `unregistered` → once resolved, add a registry entry so the same signal doesn't page again next time. This is how registry coverage grows.
- `paged` → this went out over the T3 escalation path; do not also page a second time through a different channel.

## When to use each subcommand

- **Routine:** run `tick` on a recurring cadence (session-start, or looped via `/loop`).
- **Testing a new registry entry:** `route <signal>` to dry-run the tier/action/verify logic before it fires for real.
- **Liveness audit:** `heartbeat` — the orchestrator watches for a missing heartbeat as a "duty officer went dark" signal.
- **"What's covered right now?":** `status`.

## When NOT to use this

- For declared multi-curator trunk-red coordination (holding the incident-commander role, issuing cross-curator hold/resume) — that's `curator-opus-incident-commander`.
- For decomposing a routed finding into sub-gaps — that's `/decompose`.
- For general substrate health (disk, binary staleness, lease expiry) as a one-shot check — `/fleet-doctor`.
- For halt-class paging outside the registry — `/operator-recall`.

## Lane scope

The duty-officer curator owns continuous SIGNAL→TIER→ACTION routing only. It does not:
- Hold the incident-commander coordination role during an active declared incident
- Decompose findings into gaps itself
- Escalate at T1 or T2 — T3-only, novel/halt-class only
- Edit CLAUDE.md/AGENTS.md doctrine directly

## Cross-references

- [`.claude/agents/duty-officer.md`](../../agents/duty-officer.md) — full agent body with discipline + protocols
- [`docs/design/DUTY_OFFICER.md`](../../../docs/design/DUTY_OFFICER.md) — design doc (problem, tiers, registry format, per-business instantiation)
- [`docs/process/PLAYBOOK_REGISTRY.yaml`](../../../docs/process/PLAYBOOK_REGISTRY.yaml) — the signal→tier→action registry
- [`scripts/coord/duty-officer-loop.sh`](../../../scripts/coord/duty-officer-loop.sh) — canonical harness-neutral CLI
- [`scripts/ci/test-duty-officer-loop.sh`](../../../scripts/ci/test-duty-officer-loop.sh) — smoke test (20 assertions)
