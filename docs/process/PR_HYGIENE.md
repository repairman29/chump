# PR Hygiene — required CI gates

This page documents the two PR-shape gates that became **required** (blocking)
CI checks via [CREDIBLE-042](../gaps/CREDIBLE-042.yaml) and
[CREDIBLE-043](../gaps/CREDIBLE-043.yaml). Both are wired through the
`pr-hygiene` job in [.github/workflows/ci.yml](../../.github/workflows/ci.yml)
and roll up into the already-required `test` check.

Validation that the gates actually fire: the CREDIBLE-050 force-fire harness
([scripts/ci/test-all-gates-force-fire.sh](../../scripts/ci/test-all-gates-force-fire.sh))
exercises both checkers against synthetic violating fixtures every CI run.

## CREDIBLE-026 — PR scope vs. title divergence

**Script:** [scripts/ci/check-pr-scope.sh](../../scripts/ci/check-pr-scope.sh)

**What it blocks:**

- A `chore(gaps):` or `docs(gaps):` titled PR that also touches `src/**`,
  non-CI `scripts/**`, or deletes test files. Gap-only commit prefixes
  imply gap-registry-only changes; sneaking source changes under them
  hides the real intent from reviewers.
- A "silent revert" pattern: PR deletes a file that was added or modified
  in another PR merged within the last 72 hours, and no commit in the
  current PR has a subject starting with `Revert`. (Lightweight proxy for
  the [PR #1444](https://github.com/repairman29/chump/pull/1444) silent
  META-044 revert.)

## CREDIBLE-027 — Mass deletion / scratch-commit guard

**Script:** [scripts/ci/check-mass-deletion.sh](../../scripts/ci/check-mass-deletion.sh)

**What it blocks:**

- Commit subjects equal to `first`, `init`, `wip`, or similar scratch-pad
  patterns. Anything titled `first` is almost always a stray push that
  should never make it past local.
- Net diff deleting > 100 lines from files not mentioned in the PR title
  or body. This is the gate that would have stopped
  [PR #1441](https://github.com/repairman29/chump/pull/1441)'s 378k-line
  wipe before merge.

## Bypassing

Both gates accept the repository-wide `cross-cutting-acknowledged` PR label
as an explicit "I know this PR violates a hygiene rule, here's why" bypass.
Apply sparingly and explain in the PR body.

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
