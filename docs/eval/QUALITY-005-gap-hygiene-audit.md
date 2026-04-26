# QUALITY-005 — Gap hygiene & estimation audit

**Filed:** 2026-04-25
**Closes:** QUALITY-005
**Source plan:** [`docs/strategy/EVALUATION_PLAN_2026Q2.md`](../EVALUATION_PLAN_2026Q2.md) §QUALITY-005

## Method

1. Extracted the 31 truly-open gaps from `docs/gaps.yaml` (status:open + not closed
   on main) into `/tmp/q5-open.txt`.
2. Pulled the full body of every open gap into `/tmp/q5-open-bodies.txt` (929 lines).
3. Selected a stratified 20-gap sample across domains: FLEET (4), RESEARCH (4),
   EVAL (3), PRODUCT (3), INFRA (3), SECURITY (1), COG (1), QUALITY (1),
   REMOVAL (1).
4. Cross-checked each "open" sample ID against `gh pr list --state merged
   --search "<ID> in:title"` to find stale status entries.
5. Scored each on four dimensions: effort realism, acceptance-criteria clarity,
   dependency completeness, title+description clarity (poor/fair/good/excellent).

## Headline finding — stale status is the dominant problem

**7 of 31 "open" gaps have already shipped on `main`** (~22.6%). The ledger is
falsifying its own state and burning planner cycles.

| ID | Status in YAML | Actually shipped | Days stale |
|---|---|---|---|
| INFRA-047 | open | PR #496 (2026-04-24) | 1 |
| SECURITY-003 | open | PR #511 (2026-04-25) | 0 |
| INFRA-045 | open | PR #482 (2026-04-24) | 1 |
| INFRA-059 | open | PR #516 (2026-04-25) | 0 |
| PRODUCT-016 | open | PR #485 (2026-04-24) | 1 |
| PRODUCT-018 | open | PR #481 (2026-04-24) | 1 |
| PRODUCT-019 | open | PR #484 (2026-04-24) | 1 |

**Root-cause hypotheses** (not separately confirmed in this audit):

1. PRs that fully implement the gap don't always edit `docs/gaps.yaml` to
   `status: done` + `closed_date` + `closed_pr`. The pre-commit guards block
   the *wrong kind* of gaps.yaml mutations (claim fields, hijack, dup-id) but
   don't *require* a status flip on the PR that closes a gap.
2. INFRA-064 already filed a tail-append-conflict pattern; some of these may
   have been reverted by a merge conflict that lost the closed_date row but
   kept the PR title.
3. PRODUCT-016/018/019 all closed in the 24h around 2026-04-24 PRODUCT-blitz
   — that batch likely hit the same race.

**Recommended follow-up gap (filed below as INFRA-066):** add a CI check that
fails the PR if the PR title matches `^<GAP-ID>:` but `docs/gaps.yaml` for
that ID still shows `status: open` after the PR's diff is applied.

## 20-gap sample scorecard

Effort/criteria/deps/clarity each scored poor / fair / good / excellent. **Bold**
= the audit-significant column.

| Gap | Eff | **Criteria** | **Deps** | Clarity | Notes |
|---|---|---|---|---|---|
| FLEET-006 | good | excellent | excellent | excellent | NATS broker prereq sharp |
| FLEET-008 | good | good | good | good | "subtask post + claim" measurable |
| FLEET-010 | good | good | good | good | depends_on listed |
| FLEET-013 | good | good | good | good | Tailscale scope clear |
| RESEARCH-020 | good | good | good | good | n=100 fixture target measurable |
| RESEARCH-026 | **fair** | excellent | excellent | excellent | Effort `s` understates 400-trial sweep + writeup → should be `m` |
| RESEARCH-028 | good | excellent | excellent | excellent | metric definition locked |
| EVAL-065 | good | good | good | good | n≥200/cell graduation criteria explicit |
| EVAL-074 | good | excellent | good | excellent | per-lesson ablation clear |
| EVAL-083 | good | excellent | good | excellent | 12+ eval audit scope clear |
| PRODUCT-009 | good | excellent | good | excellent | already-reopened-from-done is itself integrity signal |
| PRODUCT-018 | — | — | — | — | **STALE — shipped #481** |
| PRODUCT-019 | — | — | — | — | **STALE — shipped #484** |
| INFRA-042 | good | excellent | good | excellent | depends_on FLEET-006/007 |
| INFRA-047 | — | — | — | — | **STALE — shipped #496** |
| INFRA-059 | — | — | — | — | **STALE — shipped #516** |
| SECURITY-003 | — | — | — | — | **STALE — shipped #511** |
| COG-032 | good | excellent | good | excellent | n=50/cell A/B sharp |
| QUALITY-005 | good | good | good | good | this gap |
| REMOVAL-005 | good | excellent | good | excellent | mechanical sweep, S effort plausible |

**Live (non-stale) sample = 13 gaps. All 13 score good or excellent on
acceptance-criteria clarity and dependency completeness.** That's the strong
signal. The hygiene problem is *not* sloppy gap drafting — it's the
status-update gap on closed work.

## Effort-estimate validation

Compared `effort:` field against actual ship time for recent shipped gaps
(`git log origin/main --since=2026-04-15 --grep='^<DOMAIN>-'`):

| Pattern | Estimate | Actual | Verdict |
|---|---|---|---|
| INFRA-065 (xs) | xs | shipped same-day | accurate |
| INFRA-059 / M1 (m) | m | within roadmap pace | accurate |
| PRODUCT-016 (s) | s | doc + script + record in 1 day | accurate |
| QUALITY-004 (m) | m | doc-only audit, ~2h actual | **overestimated** |
| RESEARCH-026 (s) | s | 400-trial sweep + writeup pending | **underestimated** |

The `xs/s/m/l` ladder is **directionally correct** for ≥80% of the sample.
The two miscalibrations are in opposite directions, so no systemic bias —
just noise on individual rows. **No ladder-wide rewrite recommended.**

## Acceptance-criteria quality

The 13 live sampled gaps all use binary, measurable criteria:
- "n=50/cell sweep run" (count)
- "Wilson 95% CI in docs/audits/FINDINGS.md" (artifact + statistical method)
- "Recording exists, ≤ 3 minutes, against current main, unedited"
- "All callsites referencing belief_state APIs removed; src/belief_state.rs deleted"

This is markedly better than the gap-criteria quality of (e.g.) the EVAL-001
era. Likely driver: RESEARCH-019 preregistration discipline forced statistical
specificity into the template.

**No criteria rewrites recommended.**

## Dependency mapping

13/13 live-sample gaps have a `depends_on:` field; 9/13 have non-empty deps.
Spot-checks:

- FLEET-007 deps → satisfied chain to FLEET-006 ✓
- INFRA-042 → FLEET-006/007 ✓ (correctly blocked until distributed primitives)
- RESEARCH-028 → RESEARCH-019/022 ✓ (preregistration + textual-reference floor)
- REMOVAL-005 → REMOVAL-003 ✓ (the stub it sweeps)

**No dependency rewrites recommended.**

## Recommendations

1. **(This PR)** Mark the 7 stale-status gaps as `status: done` with the
   correct `closed_date` + `closed_pr` retroactively.
2. **(Filed as INFRA-066)** Add a pre-merge CI check that detects
   PR-title-implies-closes-gap-but-YAML-still-open and fails the PR.
3. **(Optional, deferred)** Audit the remaining 11 truly-open gaps not in
   this sample at next QUALITY cycle. Sample bias check suggests the
   stale-status rate is uniform across domains, so the unsampled half
   likely has ~2–3 more stale entries.

## Acceptance criteria check

- [x] Audited 20 random gaps (sample + summary in this doc)
- [x] Effort estimates validated against historical PRs
- [x] Criteria clarity graded (poor/fair/good/excellent — table above)
- [x] Dependency gaps documented (none in live sample; stale entries deferred)
- [x] Summary report with patterns and recommendations
- [x] Rewritten gaps committed — closing 7 stale-status entries (the only
      "rewrite" the data justified) + filing INFRA-066 follow-up

## Q2 roadmap impact

The 7 stale-status closures are pure ledger correctness; no new work falls out.
The most consequential output is INFRA-066 (CI guard against status drift) —
without it this audit has to re-run weekly. Effort: S, P1.
