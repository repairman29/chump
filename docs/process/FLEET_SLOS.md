# Fleet SLOs — explicit health targets

"Healthy" is not a vibe. This document defines per-layer targets so operator and
agents know exactly when to escalate. Every SLO maps to a measurement source so
the number can be re-verified without human judgement calls.

Check current vs. target: `chump health --slo-check`
(exits 0 when all SLOs pass; exits 1 when any SLO is breached).

---

## Layer 1 — Fleet Stability

These SLOs guard the baseline ability to run and ship at all.

| SLO ID | Target | Measurement source | Escalation |
|--------|--------|--------------------|------------|
| L1-SLO-1 | `silent_agent` events = 0 / week | `ambient.jsonl` 7d scan | Drop fleet to 2 workers; investigate picker/lease race |
| L1-SLO-2 | `orphan_claude` events = 0 / day | `ambient.jsonl` today scan | Kill orphans with `pkill -f 'claude -p'`; check launchd restarter |
| L1-SLO-3 | auto-restart success rate > 95 % | ratio of `auto_restart_ok` / (`auto_restart_ok` + `auto_restart_fail`) in `ambient.jsonl` 24h | File gap to repair launchd plist; check for syspolicyd block |

---

## Layer 2 — Fleet Productivity

These SLOs guard throughput and mission alignment.

| SLO ID | Target | Measurement source | Escalation |
|--------|--------|--------------------|------------|
| L2-SLO-1 | P50 ship-time < 30 min | median of `(closed_at − claimed_at)` across gaps shipped in last 24h (`chump gap list --status closed`) | Investigate bot-merge latency; check CI queue depth |
| L2-SLO-2 | Waste < 5 % of tokens | `chump waste-tally --since 7d --tokens` waste_token_pct field | File gap for dominant waste kind; reduce fleet size if systemic |
| L2-SLO-3 | P0 budget ≤ 5 (never > 5 for more than 1 h) | count of `priority:P0 status:open` in `chump gap list` | Run `chump gap audit-priorities`; demote inflation |
| L2-SLO-4 | Pillar balance ≥ 2 pickable in every pillar | `chump health --json` → `pillars_under_two` field | File 1–2 gaps for the starved pillar immediately |
| L2-SLO-5 | Ghost-gap count < 2 | `chump health --json` → `ghost_gaps` field | Run `chump gap ship <ID>` for each ghost or close manually |

---

## Layer 3 — Operator Experience

These SLOs guard the operator's trust and recall burden.

| SLO ID | Target | Measurement source | Escalation |
|--------|--------|--------------------|------------|
| L3-SLO-1 | Operator-recall events < 1 / week | `ambient.jsonl` 7d count of `kind=operator_recall` | Audit what triggered recall; add auto-recovery or better alerting |

---

## Layer 4 — Pipeline Health

These SLOs guard the CI pipeline from compounding jams.

| SLO ID | Target | Measurement source | Escalation | Recovery |
|--------|--------|--------------------|------------|----------|
| L4-SLO-1 | Pipeline jam | % BLOCKED PRs > 50% over 1h | auto-pause (ci-health-gate.sh) | < 30% BLOCKED for 2 consecutive 5-min runs |

---

## Layer 5 — Commitment Rot (RESILIENT-254)

Layers 1–4 all measure **flow** (ship-time, waste, restart success) or
**capacity** (P0 budget, pillar balance). None of them measure whether a
**promise is rotting** — an organ that stopped acting, a stated campaign
that stopped moving, a priority tier that quietly became a one-way door.
2026-08-08 surfaced four real instances in one session, none caught by any
SLO above: a curator dead 12 days with no alert (RESILIENT-246), MOP-BUCKET
at 0% with both children parked below the picker threshold, the factory
matrix's three missing chairs parked since 2026-08-05, and 153 P2 gaps where
P2 functionally means never.

This layer is **deliberately class-level, not per-gap due dates** — a
deadline on every gap is theatre. The unit is the organ, the outcome, the
priority tier, the class — never an individual gap's calendar date.

| SLO ID | Target | Measurement source | Escalation |
|--------|--------|--------------------|------------|
| L5-SLO-1 | Organ liveness: every curator role that has ever heartbeated stays < 96h stale | latest `kind=curator_heartbeat` per role in `ambient.jsonl` (roles: shepherd, target, handoff, ci-audit, decompose, md-links) | Restart the curator loop (`docs/process/CLAUDE_GOTCHAS.md`); if deliberately retired, express it via `CHUMP_SLO_PARKED_ROLES=<role>` so it stops paging |
| L5-SLO-2 | Outcome movement: an open outcome with open children ships a child gap within 21d | `outcomes` + `gaps.outcome_id` + `gaps.closed_at` (`chump outcome show <id>`) | Either the outcome is actually blocked (unblock the children) or it's parked on purpose — say so: `chump outcome park <id> --reason "..."` (never breaches once parked; `chump outcome unpark <id>` re-arms) |
| L5-SLO-3 | Priority tier is not a one-way door: 0 open P2 gaps older than 90d | `gaps` table, `priority='P2' AND status='open' AND created_at < now-90d` | Review the P2 backlog: promote what still matters, close what doesn't |
| L5-SLO-4 | A P1 gap unclaimed > 5d must say why: wrong, blocked, or mis-prioritized | `gaps` table, `priority='P1' AND status='open' AND created_at < now-5d` | Reprioritize, unblock, or record the verdict in the gap's `notes` |

Escalation for every row above is proportionate: a fleet-brief line and a
`docs/process/FLEET_SLOS.md` pointer, never an operator page. L5-SLO-1 and
L5-SLO-2 are the only two rows with an escalation-valve ("parked") — that's
intentional: an organ or outcome can be *deliberately* stood down, and a
breach that fires on a decision the operator already made would train the
operator to ignore this layer (the same failure mode this layer exists to
fix). L5-SLO-3 and L5-SLO-4 have no parking valve because they're
backlog-hygiene reviews, not individual on/off decisions — the response is
always "look at the list," never "silence the whole SLO."

---

## Measurement summary

```
chump health --slo-check        # all SLOs, exit 1 on breach
chump health --json             # raw data including ghost_gaps, pillars_starved
chump waste-tally --since 7d --tokens   # L2-SLO-2 source
chump gap list --status closed  # L2-SLO-1 source (ship-time)
chump gap audit-priorities      # L2-SLO-3 source (P0 count)
chump outcome show <id>         # L5-SLO-2 source (outcome + child movement)
chump outcome park <id> --reason "..."   # deliberately exempt an outcome from L5-SLO-2
chump fleet curator-status      # L5-SLO-1 source (per-role heartbeat/mutation view)
```

---

## SLO breach response ladder

1. **Single SLO breach** — file a gap tagged with the relevant pillar; operator informed via `fleet_health` event in `ambient.jsonl`.
2. **Two or more L1 breaches simultaneously** — drop fleet to 2 workers immediately; do not scale up until all L1 SLOs pass for 30 min.
3. **L2-SLO-2 waste > 30 %** — scale down to 2 workers; mandatory gap for dominant waste kind before scaling back up.
4. **Persistent L3-SLO-1 breach (> 2 events/week)** — operator review session required; file a `MISSION:` gap to address root cause.

---

## Relation to fleet scaling gate

The fleet scaling gate (documented in `CLAUDE.md`) uses a subset of these SLOs as
its criteria. This document is the authoritative source; the gate merely references
the relevant targets. If the gate and this document conflict, this document wins and
the gate must be updated.
