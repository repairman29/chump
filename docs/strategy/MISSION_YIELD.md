---
doc_tag: canonical
owner_gap:
last_audited: 2026-05-16
---

# Mission Yield — the rule of X

> **What this is.** The single number chump optimizes for. Replaces "ship rate"
> as the headline metric, because ship rate counts treadmill-running and
> mission-aligned work equally. Mission Yield doesn't.
>
> **Why it exists.** 2026-05-16 retrospective: ~88 PRs shipped in one day; the
> operator could not say which 5 made the product better for the named
> customer. Velocity without yield is mass × velocity in random directions.
>
> **Who reads it.** Every session opens with current Mission Yield.
> The weekly digest is built around its delta.

## The formula

```
Mission Yield = (marcus + fleet_quality + dev_tool - reverts_7d) / (tokens_spent / 1M)
```

Window: weekly (Sun → Sat UTC).

### Numerator terms

Every merged PR is tagged at ship time with exactly one of:

| Tag | Definition | Yield contribution |
|---|---|---|
| **`marcus`** | Changes behavior the named customer persona (Persona-1, 2026-05-15 interview) would notice. Fan-out spec, per-gap budgets, conflict-resolving merges, team vector-space, cross-operator queue — any of the Marcus-arc milestones. | **+1** |
| **`fleet-quality`** | Changes the operator's experience of running chump's own fleet. CI gates, auto-merge, merge drivers, paramedic, observability the operator actually consumes. **Operator would notice this is gone within 24h.** | **+1** |
| **`dev-tool`** | New CLI subcommand or PWA panel that the operator uses in daily work. Fleet doctor, PR triage, whoworkson, cockpit cards. | **+1** |
| **`noise`** | Doesn't change any observable behavior. Gap-curation chores, retrigger empties, README polish, allowlist patches existing purely to unblock cascades, refactors with zero customer impact. Tagged honestly. | **0** |

### Reverts

A `reverts_7d` is any merged PR that gets reverted (via `chump gap revert` or
git revert) within 7 days of its ship. Counted with the SIGN OF THE ORIGINAL
TAG: a marcus PR that gets reverted subtracts 1 from the marcus count, not from
generic yield. **Reverts beyond the 7-day window** are tracked separately as
"late reverts" — they don't enter Mission Yield but they DO enter the weekly
digest's quality section.

### Denominator

`tokens_spent` is the total LLM token spend (input + output, all tiers) across
the fleet for the same week. Read from `cost_tracker.db`. Normalized to
megatokens so the number sits in human-readable range (typically 1-50 yield
per Mtok).

## What counts and what doesn't (the calibration)

### Counts as `marcus`
- A PR that ships any acceptance criterion of the Marcus-arc gaps (INFRA-1473, 1475, 1483, 1484, 1486, 1488, 1487, 1489, 1479, 1480, 1491)
- A PR that makes chump discoverable / installable / first-run-able by an external Marcus-shaped engineer (registry placement, browser parity, install-friction reduction)

### Counts as `fleet-quality`
- A PR that prevents a class of operator firefighting (audit cascades, runner offline, merge driver, auto-merge force-fire)
- A PR that improves the operator's day-to-day cockpit / fleet doctor / observability surface
- A PR that prevents a flake (test-isolation, retry-aware sandbox)
- A PR that closes a ghost-ship (delivered AC that prior PR claimed but didn't deliver)

### Counts as `dev-tool`
- A new `chump <subcommand>` operator uses interactively
- A new PWA route the operator visits in a typical session
- A new CI smoke test for a cockpit feature (it gates the feature, but the feature itself is what counts — only smoke tests for FEATURES THE OPERATOR USES count here)

### Counts as `noise`
- Bundle gap-filings ("chore(gaps): 12 gaps registered") — no behavior change
- README link fixes, doc typo PRs
- Allowlist patches for unregistered ambient kinds (these unblock cascades but the cascade itself shouldn't have existed)
- Empty-commit retriggers, force-push commits
- Roadmap planning PRs (yes including this one — see below)
- Refactors that pass `cargo test` identically to before
- Audit-fix PRs that exist purely because something we shipped broke audit

### Edge cases

- **Strategy/planning PRs**: noise UNLESS the document is operator-consumed within 7 days AND the document changes a decision. Today's `ROADMAP_50_PER_HOUR.md` is `fleet-quality` (it changed how Jeff sequenced work). Today's `ROADMAP_BACKLOG.md` is `fleet-quality` (it killed standalone cost-attribution gap). `OFFLINE_COMPLIANCE_RUBRIC.md` is `noise` (filed, not read).
- **Sub-task scaffolds** ("scaffold X module, sub-task 1 of 5"): noise. The scaffold doesn't ship a behavior; the final sub-task does. Sub-task 5 gets the chip.
- **Mission-tagged but doc-only**: still `noise`. Mission framing without behavior change is theater.
- **Gap-curation that's actually 1-line description fixes**: noise.

## How the chip-tag gets set

**At ship time** (NOT at filing time):
1. Operator (or critique-pass agent in Phase 3) reviews the PR via cockpit's PR action panel.
2. Taps ONE chip from `marcus | fleet-quality | dev-tool | noise`.
3. The chip writes:
   - GitHub PR label `mission-yield/<tag>`
   - Ambient event `kind=pr_chip_tagged` with `{pr, tag, operator, ts}`
   - State in `.chump/state.db`: `pr_chip_tag(pr_number INTEGER PRIMARY KEY, tag TEXT, set_by TEXT, set_at INTEGER)`

**No tag = no merge.** `chump gap ship` blocks if the PR's chip-tag isn't set.

**Overrides.** `--operator-override "reason"` is supported but logged. Every override goes into Sunday's digest with the reason. Repeated overrides on the same kind of work flag the chip-tag definitions for revision.

## Computing Mission Yield

```bash
chump cos digest --week              # last 7d
chump cos digest --since 2026-05-11  # custom window
chump cos digest --json              # machine-readable
```

Reads:
1. `.chump/state.db` for chip-tags + revert flags
2. `cost_tracker.db` for token spend
3. Git log for ship/revert timeline

Outputs:
```
Mission Yield (2026-05-11 → 2026-05-17): 13.6
  marcus:        2 (+2 vs prior week)
  fleet-quality: 57 (+45)
  dev-tool:      9 (+9)
  noise:         20 (-3)
  reverts (7d):  0
  tokens spent:  5.0 Mtok
  yield delta:   +9.8 vs prior week
```

## Targets (set 2026-05-16)

| Window | Target | Reason |
|---|---|---|
| **Today (2026-05-16 baseline)** | ~13-15 | Measured baseline from today's session |
| **Week of 2026-05-25** | ≥ 20 | Wave 1 lanes stable; less time on cascades |
| **Week of 2026-06-08** | ≥ 30 | Marcus M-A trust gate landed |
| **2026 Q3** | ≥ 50 | Marcus M-B canonical demo landed |
| **Floor (any week)** | ≥ 10 | Below this, pause and investigate before claiming new work |

Yield falling 30% week-over-week → drift detector fires (Phase 3 daemon, INFRA-NEW-tbd).

## Phases of operator dependence

| Phase | Window | Who sets chip-tags | Where the discipline lives |
|---|---|---|---|
| **Phase 1 — Instrumented** | Now → 2-3 weeks | Operator manually, at merge time via cockpit | CLI + dashboard tools |
| **Phase 2 — Encoded** | 2-3 weeks → 6 weeks | Agents propose tag at file time; operator confirms at ship time | Agent system prompts + filing/shipping gates |
| **Phase 3 — Autonomous** | 6+ weeks | Critique-pass agent assigns initial tag; operator vetoes outliers; bias-correction loop trains the critique | Critique-pass agent + drift detector daemon + usage telemetry |

**Phase 3 is research, not engineering.** It works only if the critique-pass agent can be bias-corrected to within ~10% of operator-truth over 4-6 weeks. We will know by ~2026-07-01 if it works.

## Dispute process

If you disagree with a chip:
1. `chump cos dispute <PR-#> --tag <new-tag> --reason "<short>"` rewrites the tag in state.db, logs the dispute to ambient with `kind=mission_yield_chip_disputed`, and shows it in next Sunday's digest.
2. If three disputes hit the same definition (e.g. "documentation PRs always tagged wrong"), the definition gets revisited in the digest's "calibration drift" section.
3. Operator's tag wins. Always.

## What this doc replaces

- The "pillar balance" framing as the headline metric. Pillars remain (per `CLAUDE.md` Mission Driver) but as a MIX CONSTRAINT (no single pillar > 30% of weekly merges), not as the optimization target.
- "Ships per hour" as the headline. Ships/hr is still tracked but only as a denominator-of-denominator (mass; yield is the vector).
- The "P0 budget = 5" gate. Still applied, but now informed by Mission Yield: a P0 gap whose chip-tag would be `noise` is wrong-priority.

## Cross-references

- [`docs/ROADMAP.md`](../ROADMAP.md) — top-level entry, links Mission Yield from "Today's bets"
- [`docs/strategy/ROADMAP_WAVES.md`](ROADMAP_WAVES.md) — ship-order; Mission Yield is what each wave is trying to MOVE
- [`docs/strategy/ROADMAP_MARCUS.md`](ROADMAP_MARCUS.md) — what counts as the `marcus` chip
- [`docs/process/COS_OPERATING_MODEL.md`](../process/COS_OPERATING_MODEL.md) — how the COS role uses this metric (TBD)
- [`docs/syntheses/cos-weekly-*.md`](../syntheses/) — weekly digests
