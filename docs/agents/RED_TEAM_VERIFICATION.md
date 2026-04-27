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

The four classifications produce different findings. "Active gap not
closed" means the **acceptance criteria** need re-examination, not that
nothing happened — that's a different finding, with a different remedy,
than "gap is being ignored."

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
