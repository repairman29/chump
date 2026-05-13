# PR Hygiene — required CI gates

This page documents the PR-shape gates that are **required** (blocking)
CI checks. All are wired through the `pr-hygiene` job in
[.github/workflows/ci.yml](../../.github/workflows/ci.yml) and roll up
into the already-required `test` check.

Validation that the gates actually fire: the CREDIBLE-050 force-fire harness
([scripts/ci/test-all-gates-force-fire.sh](../../scripts/ci/test-all-gates-force-fire.sh))
exercises both checkers against synthetic violating fixtures every CI run.

## CREDIBLE-026 — PR scope vs. title divergence

**Script:** [scripts/ci/check-pr-scope.sh](../../scripts/ci/check-pr-scope.sh)

**What it blocks (3 rules):**

- **Rule A** — A `chore(gaps):` or `docs(gaps):` titled PR that also touches `src/**`,
  non-CI `scripts/**`, or deletes test files. Gap-only commit prefixes
  imply gap-registry-only changes; sneaking source changes under them
  hides the real intent from reviewers.
- **Rule B** — A "silent revert" pattern: PR deletes a file that was added or modified
  in another PR merged within the last 72 hours, and no commit in the
  current PR has a subject starting with `Revert`. (Lightweight proxy for
  the [PR #1444](https://github.com/repairman29/chump/pull/1444) silent
  META-044 revert.)
- **Rule C** (CREDIBLE-041) — A PR title listing 2+ gap IDs separated by `,` or `+`
  (e.g. `feat(INFRA-1,INFRA-2): bundle`) where those IDs are not `depends_on`-linked
  in `.chump/state.db`. Catches PRs that bundle unrelated gaps under one title
  (pattern: [PR #1469](https://github.com/repairman29/chump/pull/1469)).
  Bypass: add the `intentional-bundle` PR label with rationale.

## CREDIBLE-027 — Mass deletion / scratch-commit guard

**Script:** [scripts/ci/check-mass-deletion.sh](../../scripts/ci/check-mass-deletion.sh)

**What it blocks (3 rules):**

- **Rule A** — Commit subjects equal to `first`, `init`, `wip`, or similar scratch-pad
  patterns. Anything titled `first` is almost always a stray push that
  should never make it past local.
- **Rule B** — Net diff deleting > 100 lines from files not mentioned in the PR title
  or body. This is the gate that would have stopped
  [PR #1441](https://github.com/repairman29/chump/pull/1441)'s 378k-line
  wipe before merge.
- **Rule C** (CREDIBLE-038) — PR title prefix is `chore(gaps):` or `docs:` but diff
  includes files outside the expected directory (`docs/gaps/` and `docs/` respectively).
  Pure AC additions (many `docs/gaps/*.yaml` files) correctly PASS. Bypass: `cross-cutting-acknowledged` label.

## Retroactive calibration (CREDIBLE-042)

Before flipping `pr-hygiene` to required, the checker was run against the
last 30 merged PRs (2026-05-13):

| Rule | Historical violations | False positives |
|---|---|---|
| A (chore/docs gaps purity) | 0 | 0 |
| B (silent revert) | 0 | 0 |
| C (no-bundle-PR) | 0 | 4 (gap refs in description text, not bundles) |
| Mass-deletion B (net del) | 0 | 0 |

**Finding:** gate is appropriately calibrated. No real violations in recent
history; Rule C false-positives from gap IDs in descriptions are handled
correctly when checking against `state.db` depends_on.

## Automated baseline (EVAL-124)

Automated FPR measurement via `scripts/ci/eval-gate-fpr-baseline.sh` run
2026-05-13 against 30 most-recently merged PRs:

| Gate | PRs | Fires | Fire rate |
|---|---|---|---|
| check-pr-scope.sh | 30 | 0 | 0.0% |
| check-mass-deletion.sh | 30 | 0 | 0.0% |

**Finding:** 0.0% fire rate across both gates on recent PRs — gates are
well-calibrated with zero FP. Full per-PR results in
[docs/eval/gate-fpr-baseline-2026-05.md](../eval/gate-fpr-baseline-2026-05.md).
Compare with CREDIBLE-048 production telemetry to detect calibration drift.

## Bypassing

| Rule | Bypass mechanism |
|---|---|
| CREDIBLE-026 Rule A (chore/docs purity) | `cross-cutting-acknowledged` PR label |
| CREDIBLE-026 Rule B (silent revert) | Add a `Revert: <reason>` commit, or label |
| CREDIBLE-026 Rule C (no-bundle) | `intentional-bundle` PR label |
| CREDIBLE-027 Rule A (vague title) | N/A — rename the commit |
| CREDIBLE-027 Rule B (mass deletion) | Mention paths in PR body, or label |
| CREDIBLE-027 Rule C (file-count-blast) | `cross-cutting-acknowledged` PR label |

There is no environment-variable bypass for these gates in CI. Local dev
runs can pass `--warn-only` to either script for triage, but CI invokes
them without that flag.

## When a gate fires

The check fails with a clear `[FAIL]` line naming the violation. Don't
disable the gate — change the PR:

- Wrong title? Rename the PR (or split the diff into multiple PRs).
- Mass deletion intentional? Mention the deleted paths in the PR body,
  or add the bypass label with rationale.
- Silent revert false-positive? Add a `Revert` commit subject explicitly,
  or label + rationale.
- Bundle false-positive (gaps are linked)? Ensure `depends_on` is set in
  `state.db`, or use `intentional-bundle` label.

## Required check wiring

`pr-hygiene` runs on every `pull_request` event (no path filter). It rolls
into the `test` required check: the `test` job lists `pr-hygiene` in its
`needs:` and its rollup script treats any result other than `success` as a
failure. **This is required, not advisory** — a PR cannot merge if
`pr-hygiene` fails.
