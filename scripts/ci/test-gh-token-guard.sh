#!/usr/bin/env bash
# scripts/ci/test-gh-token-guard.sh
# RESILIENT-018: smoke test for scripts/ci/lib/ci-guards.sh::check_gh_token_or_skip
#
#   1. GH_TOKEN/GITHUB_TOKEN unset -> guard exits 0, emits
#      kind=ci_gh_token_missing_skip to ambient.jsonl, no gh call made.
#   2. GH_TOKEN set -> guard returns (does not exit), caller proceeds.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/ci/lib/ci-guards.sh"

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== RESILIENT-018 ci-guards.sh smoke test ==="

if [[ ! -f "$LIB" ]]; then
  fail "lib not found at $LIB"
  exit 1
fi
ok "scripts/ci/lib/ci-guards.sh exists"

TMP_AMBIENT="$(mktemp "${TMPDIR:-/tmp}/ci-guards-ambient.XXXXXX.jsonl")"
trap 'rm -f "$TMP_AMBIENT"' EXIT

# ── Case 1: no token -> skip (exit 0) + ambient emit ─────────────────────────
echo
echo "[1. GH_TOKEN/GITHUB_TOKEN unset -> skip]"
OUT="$(
  env -u GH_TOKEN -u GITHUB_TOKEN \
    CHUMP_AMBIENT_LOG="$TMP_AMBIENT" \
    bash -c '
      source "'"$LIB"'"
      check_gh_token_or_skip "unit-test-workflow" "unit-test-job"
      echo "UNREACHABLE: gh call would happen here"
    ' 2>&1
)"
CODE=$?
if [[ $CODE -eq 0 ]]; then
  ok "guard exited 0 (skip, not fail) when token unset"
else
  fail "guard exited $CODE when token unset (expected 0)"
fi

if echo "$OUT" | grep -q "UNREACHABLE"; then
  fail "guard did not stop execution — gh call would have run without a token"
else
  ok "guard stopped execution before the gh-dependent call"
fi

if grep -q '"kind":"ci_gh_token_missing_skip"' "$TMP_AMBIENT" 2>/dev/null \
    && grep -q '"workflow_name":"unit-test-workflow"' "$TMP_AMBIENT" \
    && grep -q '"job_name":"unit-test-job"' "$TMP_AMBIENT"; then
  ok "ambient kind=ci_gh_token_missing_skip emitted with workflow_name+job_name"
else
  fail "ambient event missing or malformed: $(cat "$TMP_AMBIENT" 2>/dev/null)"
fi

# ── Case 2: token set -> no skip, caller proceeds ────────────────────────────
echo
echo "[2. GH_TOKEN set -> no skip]"
rm -f "$TMP_AMBIENT"
OUT="$(
  GH_TOKEN="fake-token-for-smoke-test" \
    CHUMP_AMBIENT_LOG="$TMP_AMBIENT" \
    bash -c '
      source "'"$LIB"'"
      check_gh_token_or_skip "unit-test-workflow" "unit-test-job"
      echo "REACHED: gh call would happen here"
    ' 2>&1
)"
CODE=$?
if [[ $CODE -eq 0 ]] && echo "$OUT" | grep -q "REACHED"; then
  ok "guard returned (did not exit) when GH_TOKEN set — caller proceeded"
else
  fail "guard blocked execution even though GH_TOKEN was set: $OUT"
fi

if [[ -s "$TMP_AMBIENT" ]]; then
  fail "guard emitted an ambient skip event even though GH_TOKEN was set"
else
  ok "no ambient skip event emitted when token present"
fi

echo
echo "=== Result: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
