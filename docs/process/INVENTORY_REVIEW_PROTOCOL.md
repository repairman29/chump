# Inventory Review Protocol

**Owner:** operator
**Filed:** 2026-05-31 as part of META-271 (review-first inventory pivot)
**Companion:** `src/inventory.rs`, `src/commands/inventory.rs`, `migrations/inventory_v1.sql`

## The doctrine in one sentence

> Auto-action is opt-in per finding class, never enabled by default.

## Why this protocol exists

The fleet inventory + tech-debt audit DB (META-271) is a microscope for
the substrate — it indexes every PR, every artifact, every shipped gap,
and runs 9 heuristic detectors over the result to surface tech debt
candidates. The first time the operator runs `chump inventory rebuild`
on a 5,000+ artifact / 3,000+ PR repo, the detectors will surface
**dozens of findings**. Many will be false positives because path
heuristics miss dynamic dispatch (env-var lookups, runtime-loaded
plugins, role-doc references, launchd-triggered daemons that wait on
legitimate-but-rare events).

**If the system auto-files gaps or auto-removes code based on those
first findings, it will cut working substrate.** That is what this
protocol prevents.

## The 4-tier model

| Tier | Name              | Effect of a detector finding                                         | Set by                                                                           |
|------|-------------------|----------------------------------------------------------------------|----------------------------------------------------------------------------------|
| 0    | SURFACE-ONLY      | Insert into `tech_debt_findings`; emit `kind=tech_debt_finding`; no gap, no action. | Default — every finding lands here. |
| 1    | REVIEW-PENDING    | Same as tier 0; operator has begun classifying findings in this class. | Implicit (operator running `chump inventory review` on tier-0 findings).        |
| 2    | AUTO-FILE         | Detector finding triggers a gap file (machinery deferred to INFRA-2374). | Operator explicit: `chump inventory promote <finding_class>`. Requires ≥10 reviewed AND ≥70% REAL_POSITIVE. |
| 3    | REMOVED           | **Not implemented and not planned.** Removal PRs always ship through normal review (META-270). | n/a                                                                              |

## Operator workflow

### Step 1 — Surface findings

```bash
chump inventory rebuild
chump inventory debt-report --tier 0
```

You will see DOZENS of findings. Many are false positives. That's fine —
the inventory is doing its job of *surfacing* candidates, not *deciding*
which are real.

### Step 2 — Classify (the slow, irreplaceable step)

```bash
chump inventory review-queue --limit 20         # oldest unreviewed first
chump inventory review <id> --classify REAL_POSITIVE --note "scripts/foo.sh has no callers; confirmed by grep"
chump inventory review <id> --classify FALSE_POSITIVE --note "loaded dynamically by scripts/dispatch/worker.sh via runtime env-var"
chump inventory review <id> --classify NEEDS_INVESTIGATION --note "checked grep but unsure — flagging for follow-up"
```

This is where the operator's judgment lives. The system cannot do this
step for you — it's the whole point.

### Step 3 — Inspect calibration

```bash
chump inventory class-stats
```

Sample output:

```
class                        tier   total    reviewed   RP%    eligible
orphan-artifact              0      47       12         83     yes
dormant-script               0      18       4          50     no
dead-rust-mod                0      6        2          100    no
...
```

A class becomes **eligible for promotion** when:
- `reviewed_count >= 10`, AND
- `real_positive_count / reviewed_count >= 0.70`

If a class's RP ratio sits below 70%, it stays at tier 0 — the detector
is too noisy for auto-filing to be net-positive. Either tune the detector
heuristic or accept that this finding class is human-review-only forever.

### Step 4 — Promote (operator explicit, one class at a time)

```bash
chump inventory promote orphan-artifact
```

If the class is below threshold, this **rejects** with a calibration
shortfall message. There is no `--force` flag. The operator must keep
reviewing until the class earns promotion.

When the class clears both gates, the row in `finding_class_tiers` flips
to `current_tier=2`. From that moment forward, *new findings in that
class* are eligible for tier-2 auto-file (when INFRA-2374 ships the
machinery). Findings that already exist at tier=0 are not retroactively
re-classified.

### Step 5 — Demote (escape hatch)

```bash
chump inventory demote orphan-artifact
```

Always succeeds. Returns the class to tier=0. Use this when you realize
post-promotion that a detector is firing noisily on a legitimate pattern.

## Hard rules baked into the schema

1. `tech_debt_findings.auto_fix_filed_gap_id` is **NULL** on every row
   written by detectors in META-271's PR scope. That column exists for
   INFRA-2374's tier-2 machinery to populate later; until then it's a
   contract guarantee that no detector has filed a gap.

2. `finding_class_tiers.current_tier` defaults to **0** for all 9 detector
   classes — seeded explicitly in the migration.

3. `chump inventory promote` rejects below `(PROMOTE_MIN_REVIEWED=10,
   PROMOTE_MIN_REAL_POSITIVE_RATIO=0.70)`. Tunable in
   `src/inventory.rs` if calibration data later justifies a different
   bar, but never bypassed at the call site.

4. Tier-3 (auto-remove, auto-PR-to-delete) is **not implemented and not
   planned**. The orchestrator (META-270) ships removal PRs through the
   normal review path — even for tech-debt removal.

## When to revisit this protocol

- If after 4 weeks of operator review, no class has hit tier 2: detectors
  are too noisy. Tune heuristics in `detect_*` fns, don't lower the bar.
- If a class hits tier 2 and INFRA-2374's tier-2 machinery is causing
  false-positive gap-files: demote immediately, re-investigate.
- If a new detector is added: it must seed at tier=0 in the migration
  (see INSERT block at bottom of `migrations/inventory_v1.sql`).

## Pointer to the umbrella

META-271 ships only the visibility surface (tiers 0 + 1 + 2 promote/demote
plumbing). The follow-up work:

- **INFRA-2369** — agent-awareness sync (per-curator finding-class views)
- **INFRA-2371** — SessionStart INVENTORY HEALTH digest
- **INFRA-2372** — backfill from full git log
- **INFRA-2374** — tier-2 auto-file machinery (the actual gap-filing layer,
  gated on operator-promote action)
