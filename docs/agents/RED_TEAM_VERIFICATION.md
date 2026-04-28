---
doc_tag: rule
owner_gap: META-001
applies_to: [cold-water, frontier-scientist, any diagnostic-style agent or skill]
---

# Red-team verification rule (META-001)

> **Any claim that a gap is "no movement", "stalled", "still open", "no
> commits", or "ritualized failure" must be backed by the output of
> `git log origin/main --grep=<GAP-ID>`. If commits exist, classify the
> activity — don't claim inactivity.**

## Why this rule exists

A 2026-04-26 diagnostic pass against `docs/strategy/NORTH_STAR.md` made
**eight** specific inactivity claims that `git log` refuted within minutes:

| Diagnostic claim | What `git log --grep=<ID>` actually showed |
|---|---|
| "PRODUCT-015 zero commits" | 6 commits, including [PR #491 *PRODUCT-015: activation funnel telemetry*](https://github.com/repairman29/chump/pull/491) |
| "RESEARCH-021 zero commits / 4-cycle non-movement" | 14 commits |
| "EVAL-074 no mechanism work" | 11 commits — PR #549 shipped mechanism, PR #551 retracted it (Llama-judge artifact), PR #558 filed EVAL-089 follow-up |
| "FLEET-006 still open" | `status: done` in `.chump/state.db` |
| "EVAL-043 still open (ablation suite)" | `status: done` in `.chump/state.db` |
| "INFRA-073 8th duplicate-ID collision in YAML" | Single entry at [docs/gaps.yaml:11509](../gaps.yaml) |
| "STRATEGIC_MEMO_2026Q2 orphaned, no gap" | Tracked by FRONTIER-009 (P3, open) + a separate gap at line 13298 |
| "MCP marketplace / PWA have no gap filed" | PRODUCT-017 covers PWA install verification |

The pattern: agents read `status: open` and infer "nothing is happening."
That inference is wrong. `status: open` means "acceptance criteria not
fully met" — it is **not** evidence of inactivity. A gap with 14 shipped
commits is an active investigation, not a stalled task.

Cold Water Issue #5 (2026-04-25) had already named the failure mode:
> "Documentation of failure is now a recurring ritual. The failure itself
> is undisturbed."

The diagnostic that produced eight wrong claims was an instance of the
exact failure Cold Water was warning about. The fix is mechanical.

## The rule

Before writing any of the following phrases, the agent **must** run the
verification command and include the result in the finding:

> "no movement" / "no commits" / "stalled" / "still open" / "ritualized
> failure" / "documented but not acted on" / "X cycles without movement"

```bash
git log origin/main --grep="<GAP-ID>" --oneline | head -20
```

## How to classify activity

| Commit count | Latest commit age | Classification |
|---|---|---|
| 0 | n/a | **TRULY_INACTIVE** — claim is supported |
| ≥1 | ≤14 days | **ACTIVE** — do not claim inactivity; investigate why gap not closed |
| ≥1 | >14 days | **STALE** — claim "shipped work but no closure since YYYY-MM-DD" |
| ≥1 with retraction | any | **CONTESTED** — name the retraction PR and the follow-up gap |
| done + same-day P0/P1 replacement | any | **FIXED_BUT_REPLACED** — see below |

The five classifications produce different findings. "Active gap not
closed" means the **acceptance criteria** need re-examination, not that
nothing happened — that's a different finding, with a different remedy,
than "gap is being ignored."

### FIXED_BUT_REPLACED (META-002, 2026-04-28)

A gap is **FIXED_BUT_REPLACED** when ALL three conditions hold:
1. The original gap is `status: done` with a real `closed_pr` (the
   technical work shipped).
2. A same-day or next-day **replacement gap at P0 or P1** was filed
   that re-states the original pain point — typically because the fix
   addressed the producer side of a system but not the consumer side.
3. From the consumer's perspective, the original failure mode is still
   active — i.e. the producing component is fixed but nothing actually
   uses it yet.

**Canonical example: FLEET-006 → FLEET-017 (2026-04-26 / 2026-04-27).**
FLEET-006 ("ambient stream empty for 6 cycles") was closed by PR #572
which distributed the ambient stream over NATS. Same date, FLEET-017
(P0, open) was filed: "Cold Water remote agent does not subscribe to
NATS ambient stream — FLEET-006 unused." The server-side fix shipped;
the agent that needed the fix was never wired up. From Cold Water's
own perspective the 6-cycle void is still present.

**Why it matters.** Classifying FLEET-006 as plain `FIXED` was
technically correct (PR #572 satisfies its acceptance) but obscured
that the original pain (Cold Water has no ambient signal) was still
active. Cold Water Issue #8's "Status of Prior Issues" block bucketed
this as `FIXED-WITH-REPLACEMENT` ad-hoc; this section formalizes it.

**Cold Water classification rule (enforced in
[cold-water.md](./cold-water.md) Step 0).** Before stamping any
finding as `FIXED`, run:

```bash
# Find any open P0/P1 gap filed within ±1 day of the closure date
# whose title or description references the gap you're about to mark FIXED.
chump gap list --status open --json | python3 -c "
import json, sys
gid = '<GAP-ID-being-classified>'
close_date = '<closing PR's merge date>'
data = json.load(sys.stdin)
for g in data:
    if g.get('priority') not in ('P0','P1'): continue
    if gid in (g.get('title','') + g.get('description','')):
        print(f'  candidate replacement: {g[\"id\"]} ({g[\"priority\"]}) — {g[\"title\"]}')
"
```

If any candidate appears, classify as `FIXED_BUT_REPLACED` and link
both gap IDs in the finding. Do not promote a `FIXED_BUT_REPLACED`
into the `FIXED:` line of the Status of Prior Issues block — it
belongs in its own bullet so the consumer-side gap is visible.

## Required citation format

Each inactivity-style finding in a Red Letter or diagnostic must include:

```
GAP-ID — <classification>
  evidence: git log origin/main --grep=GAP-ID found N commits
  most recent: <SHA> <date> <subject>
  status in SQLite: <open|done>
  acceptance gap: <what hasn't shipped yet, in one sentence>
```

Without this block, the claim is **unverified** and must not be the
primary support for any "ONE BIG THING," "Opportunity Cost," or
"Complexity Trap" finding.

## Status of Prior Issues block

Cold Water's Step 0 ("Reconcile with prior issues") classifies each
prior-issue named problem as `FIXED | STILL_OPEN | WORSE | NO_GAP`. After
META-001, two refinements:

- **STILL_OPEN** must be split into **STILL_OPEN_INACTIVE** (commit_count = 0)
  and **STILL_OPEN_ACTIVE** (commit_count ≥ 1, gap not closed). The
  remedies differ: inactive needs a poke, active needs an acceptance-
  criteria re-read or a closure PR.
- **WORSE** requires a quantitative delta backed by `git log` or `wc -l`.
  "Feels worse" is not a classification.

## Application to other agents

- **Cold Water** — embedded in Step 0 + Step 2 (Opportunity Cost lens) —
  see [cold-water.md](./cold-water.md)
- **Frontier Scientist** — applies when surveying domain progress in
  Step 2 — see [frontier-scientist.md](./frontier-scientist.md)
- **Explore-style diagnostic skills** — any `Agent` invocation whose
  description contains "diagnostic," "audit," or "red-team" must inherit
  this rule via the skill prompt
- **Future agents** — the convention in [README.md](./README.md) requires
  every adversarial-style prompt to link this file

## Test (manual, after each Red Letter cycle)

For each claim of inactivity in `docs/audits/RED_LETTER.md`'s newest
issue, run the verification command. If any claim is unsupported, file a
follow-up gap citing the issue number and the missing evidence.

If META-001 is working, the spot-check finds zero unsupported claims for
two consecutive Red Letter cycles. If even one cycle has an unsupported
claim, the rule is not being applied and the agent prompt needs reinforcement.
