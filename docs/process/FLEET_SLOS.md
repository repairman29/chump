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
| L2-SLO-6 | `bisect_quarantined` count ≤ 5 | gap store `count_bisect_quarantined()` (INFRA-2137 / INFRA-2142) | Release each with `chump gap requeue <ID>`; more than 5 waiting on operator review means the review loop, not the gaps, is the bottleneck |

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
| L4-SLO-1 (code) | paramedic heartbeat fresh (< 15 min gap) | `paramedic_heartbeat` in `ambient.jsonl`; only breaches when a leader was seen in the trailing hour (INFRA-1397 AC §7) | Restart `com.chump.paramedic`; the daemon may simply not be installed on this host |

> **Known ID collision, recorded rather than silently renamed (RESILIENT-254,
> 2026-08-09).** `src/fleet_health.rs` emits the paramedic check under the id
> `L4-SLO-1`, the same id this document already gave to the pipeline-jam SLO —
> which is enforced by `ci-health-gate.sh`, not by `--slo-check`. Renaming
> either would move an id that external consumers may key on, so the collision
> is documented here and left for a dedicated gap. Layer 5 deliberately starts
> its own numbering clean.

---

## Layer 5 — Commitment Aging (RESILIENT-254)

Layers 1–4 all measure **flow** (ship-time, waste, restart success, silent
agents) or **capacity** (P0 budget, pillar balance). None of them measures
whether a **promise is rotting**. On 2026-08-08 the fleet was shipping 16–28
PRs a day and still could not tell the operator that:

- the opus curator had been dead **12 days** — exiting 78 every 600 s
  (RESILIENT-246) — with no layer of the fleet saying so;
- MOP-BUCKET sat at 0 % with two open children and no shipped child;
- a priority tier had quietly become a place work goes to sit.

These SLOs guard **committed work that is aging with no progress**.

| SLO ID | Target | Measurement source | Escalation |
|--------|--------|--------------------|------------|
| L5-SLO-1 | every load-bearing organ acted inside its own grace window | `scripts/coord/daemon-expectations.yaml` → `load_bearing_organs:` × newest matching `evidence_kinds` in `.chump-locks/ambient.jsonl` | File a P1 RESILIENT gap naming the organ (`chump gap reserve --outcome RESILIENT-000`); read its launchd exit code with `launchctl print gui/$(id -u)/<label>`. If the organ is deliberately retired, park it in the registry instead |
| L5-SLO-2 | an open outcome with open children shipped a child within 14 d | gap store: newest `closed_at` across children in `done`/`closed`/`shipped`, vs. count of children still `open` | Adjudicate the OUTCOME, not its gaps: ship one child, re-scope it, or `chump outcome park <id> --reason "…"`. Never a page — it belongs in the fleet-brief and the next planning pass |
| L5-SLO-3 | no priority tier holds more than 5 gaps open past 45 d unadjudicated | gap store: `status='open'` gaps grouped by `priority`, counted past the age cutoff | Adjudicate the CLASS in one pass: demote it, mark it `blocked` with a named blocker, or refine it. Any of the three moves the gap out of `open` and clears the tier |

**Read the SLO IDs as classes, not queues.** L5-SLO-3 counts a *tier*;
L5-SLO-2 counts an *outcome*. No per-gap due dates exist anywhere in this
layer, and none may be added — a deadline on every gap is theatre, and the
2026-08-08 audit named that explicitly as the wrong fix.

### Deliberate parking (why this layer does not cry wolf)

A breach that fires for work parked **on purpose** trains the operator to skip
the whole layer, so parking is first-class and never breaches:

| What | How to park | Effect |
|------|-------------|--------|
| An organ | `parked: "<reason>"` on its entry in `daemon-expectations.yaml` | Reported as `parked` in the detail line; never breaches |
| An outcome | `chump outcome park <id> --reason "<why>"` (`unpark` reverses it) | `status='parked'`; L5-SLO-2 skips it entirely |
| An individual aged gap | move it out of `open`: demote, `blocked` with a blocker, or `wontfix` | Stops counting toward its tier's L5-SLO-3 budget |

The reason is **required** on both organ and outcome parking. Parking without a
stated why is indistinguishable from neglect, which is the thing this layer
exists to catch. The standing example is the ACG advisory track: parked on
purpose, and it must never page.

### What Layer 5 does NOT claim

Honest limits, so nobody reads a green L5 as more than it is:

- **L5-SLO-1 is skipped off the fleet host.** If `ambient.jsonl` holds zero
  events in the trailing 24 h, the checkout is a laptop, a CI runner or a fresh
  clone; organ liveness reports `no data` and does not breach. Total fleet
  death is therefore *not* caught here — that stays INFRA-2040's
  `silent_fleet_death` banner in the fleet-brief.
- **Liveness is measured from ambient, never from `launchctl`.** "Loaded" and
  "working" are different claims, and RESILIENT-246 is what the difference
  costs. Ambient rotation can make a live organ look silent (false BREACH), but
  never the reverse — the error only ever points at the loud side.
- **Evidence dated more than 5 min in the future is discarded.** Observed live
  on 2026-08-09: a `paramedic_heartbeat` carrying `ts=2026-08-22`. Trusting a
  skewed clock would make a dead organ look alive for twelve days.
- **An outcome with no children at all is out of scope.** That is a planning
  gap, not rot, and L5-SLO-2 says nothing about it.
- **A candidate SLO was dropped for lack of evidence.** RESILIENT-254 proposed
  "no priority tier is a one-way door — 153 P2s with no promotion path means P2
  means never". Measured 2026-08-09 against `.chump/state.db`: 193 open P2s,
  **214 P2 gaps shipped in the trailing 30 days** (more than P1's 180), and only
  8 open P2s older than 45 days. P2 is not a one-way door by exit rate; it is
  one only for the sediment at the bottom of the tier. L5-SLO-3 measures that
  sediment instead, because a check that can never fire is worse than no check.

### Relation to `daemon_silent`

`scripts/coord/daemon-silence-monitor.sh` already watches a `daemons:` list in
the same YAML file and emits `kind=daemon_silent`. It is a warning, not a gate:
it skips anything not currently LOADED, and nothing escalates on the event. The
curator was absent from that list entirely, which is the second half of why its
12-day death went unseen. L5-SLO-1 is the escalating half — not-loaded is a
breach, not an excuse — and it reads the same file so the two lists cannot drift
into separate registries.

---

## Measurement summary

```
chump health --slo-check        # all SLOs, exit 1 on breach
chump health --slo-check --layer L5   # Layer 5 only — fast path, used by the fleet-brief
chump health --json             # raw data including ghost_gaps, pillars_starved
chump waste-tally --since 7d --tokens   # L2-SLO-2 source
chump gap list --status closed  # L2-SLO-1 source (ship-time)
chump gap audit-priorities      # L2-SLO-3 source (P0 count)
chump outcome list              # L5-SLO-2 source (parked outcomes show status=parked)
```

`--layer L5` exists because a full `--slo-check` re-scans the whole ambient log
(~69k lines on the operator's host) through a helper that forks `date(1)` per
line, and takes minutes. The fleet-brief runs on every session start and cannot
afford that; the L5 path skips Layers 1–3 entirely.

---

## SLO breach response ladder

1. **Single SLO breach** — file a gap tagged with the relevant pillar; operator informed via `fleet_health` event in `ambient.jsonl`.
2. **Two or more L1 breaches simultaneously** — drop fleet to 2 workers immediately; do not scale up until all L1 SLOs pass for 30 min.
3. **L2-SLO-2 waste > 30 %** — scale down to 2 workers; mandatory gap for dominant waste kind before scaling back up.
4. **Persistent L3-SLO-1 breach (> 2 events/week)** — operator review session required; file a `MISSION:` gap to address root cause.
5. **L5-SLO-1 (organ silent)** — treat as L1-class: a load-bearing organ that stopped acting is a halt in slow motion. File the P1 immediately; do not scale the fleet up while an organ is dark, because more workers on unsteered work only rots more work in parallel.
6. **L5-SLO-2 / L5-SLO-3 (aging)** — never a page. They surface in the fleet-brief and are cleared in the next planning pass by adjudicating the class (ship, re-scope, park, demote, block, or refine). A rot breach that survives two consecutive planning passes is itself the signal — the commitment was never real.

---

## Relation to fleet scaling gate

The fleet scaling gate (documented in `CLAUDE.md`) uses a subset of these SLOs as
its criteria. This document is the authoritative source; the gate merely references
the relevant targets. If the gate and this document conflict, this document wins and
the gate must be updated.
