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

## Measurement summary

```
chump health --slo-check        # all SLOs, exit 1 on breach
chump health --json             # raw data including ghost_gaps, pillars_starved
chump waste-tally --since 7d --tokens   # L2-SLO-2 source
chump gap list --status closed  # L2-SLO-1 source (ship-time)
chump gap audit-priorities      # L2-SLO-3 source (P0 count)
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
