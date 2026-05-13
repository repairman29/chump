#!/usr/bin/env bash
# test-check-pr-scope-title.sh — INFRA-976
#
# Verifies that scripts/ci/check-pr-scope.sh resolves the PR title in the
# correct priority order:
#   1. PR_TITLE_OVERRIDE / PR_TITLE_ENV env (workflow-passed)
#   2. gh pr view (scoped via GITHUB_REPOSITORY + GITHUB_HEAD_REF)
#   3. first commit subject (fallback)
#
# Without this, retitled PRs (chore→fix, etc.) get evaluated against their
# stale first-commit subject — the failure mode that bit PR #1648 today.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/check-pr-scope.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Set up a synthetic git repo with two commits — one on main, one on a feature
# branch whose commit subject differs from what we want to claim as the
# "PR title" (simulating a retitled PR).
mkdir -p "$TMP/repo"
cd "$TMP/repo"
git init -q
git config user.email "t@t.com"
git config user.name "t"

# Main commit (will be the merge-base)
echo "main" > README.md
git add README.md
git commit -q -m "initial main commit"
git branch -m main 2>/dev/null || git checkout -b main -q 2>/dev/null || true

# Branch with a "stale" commit subject (simulates pre-retitle)
git checkout -q -b feature
mkdir -p docs/gaps
echo "yaml stuff" > docs/gaps/test.yaml
git add docs/gaps/test.yaml
git commit -q -m "chore(gaps): sync 10 shipped-gap YAML mirrors"

# Sanity: from here, git log returns "chore(gaps): ..." as the only branch commit.

# ── Scenario 1: PR_TITLE_ENV beats first commit subject ──────────────────────
# The branch commit subject is 'chore(gaps): ...' but the PR was retitled.
# With PR_TITLE_ENV set, the gate should see the retitled title.
out="$(GITHUB_REPOSITORY="" GITHUB_HEAD_REF="" PR_TITLE_ENV="fix(ship_quality): rolling-window test fix" bash "$SCRIPT" --warn-only --base main 2>&1)"
if echo "$out" | grep -q "PR title: 'fix(ship_quality): rolling-window test fix'"; then
    ok "scenario 1 — PR_TITLE_ENV wins over first-commit subject"
else
    fail "scenario 1 — env not honoured. out: $out"
fi

# ── Scenario 2: no env, falls through to git log (oldest commit) ─────────────
out="$(GITHUB_REPOSITORY="" GITHUB_HEAD_REF="" unset PR_TITLE_ENV; bash "$SCRIPT" --warn-only --base main 2>&1)"
# Without env and without gh PR context, falls back to git log
if echo "$out" | grep -q "PR title: 'chore(gaps):"; then
    ok "scenario 2 — fallback to first-commit subject when no env + no gh PR"
else
    fail "scenario 2 — expected fallback to chore(gaps); got: $out"
fi

# ── Scenario 3: PR_TITLE_OVERRIDE beats PR_TITLE_ENV ─────────────────────────
out="$(PR_TITLE_ENV="env-title" PR_TITLE_OVERRIDE="override-title" bash "$SCRIPT" --warn-only --base main 2>&1)"
if echo "$out" | grep -q "PR title: 'override-title'"; then
    ok "scenario 3 — PR_TITLE_OVERRIDE beats PR_TITLE_ENV"
else
    fail "scenario 3 — OVERRIDE not winning. out: $out"
fi

# ── Scenario 4: empty env strings don't poison the lookup ────────────────────
out="$(PR_TITLE_ENV="" PR_TITLE_OVERRIDE="" bash "$SCRIPT" --warn-only --base main 2>&1)"
if echo "$out" | grep -q "PR title: 'chore(gaps):"; then
    ok "scenario 4 — empty env strings fall through to git log"
else
    fail "scenario 4 — empty env didn't fall through. out: $out"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
