#!/usr/bin/env bash
# test-ruleset-doc-only-pr.sh — INFRA-2191 (updated META-261 2026-05-31)
#
# Guards the doc-only PR wedge fix. Original INFRA-2191 fix used an `audit-stub`
# job to emit an `audit` check-run on doc-only PRs. META-261 (2026-05-31)
# collapsed the stub/required pattern: the `audit-required` aggregator now maps
# SKIPPED → exit 0 directly, so no stub is needed.
#
# Wedge scenario: branch protection requires `audit-required`. On doc-only PRs
# the real `audit` job is skipped (docs_only == 'true'). Without the aggregator
# mapping skipped → success, the `audit-required` check-run would never emit
# SUCCESS, leaving the PR BLOCKED with 0 fails 0 pending forever.
#
# Static lint asserts (post META-261):
#   (1) audit-stub job is ABSENT (deleted by META-261).
#   (2) audit-required job exists with `if: always()`.
#   (3) audit-required maps the real `audit` SKIPPED result → exit 0.
#   (4) audit-required needs only `audit` (no stub dep).
#   (5) The `test` rollup uses `if: always()` (no test-stub needed).
#
# Run locally:
#   bash scripts/ci/test-ruleset-doc-only-pr.sh
#
# Exits non-zero on any assertion failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-2191 / META-261 ruleset doc-only-PR wedge guard ==="
echo

[[ -f "$CI_YML" ]] || { echo "FATAL: ci.yml not found at $CI_YML"; exit 2; }

# ──────────────────────────────────────────────────────────────────────────
# Assert 1: audit-stub job must be ABSENT (META-261 deleted it)
# ──────────────────────────────────────────────────────────────────────────
if grep -q "^  audit-stub:" "$CI_YML"; then
  fail "audit-stub job still present — META-261 requires it to be deleted"
else
  ok "audit-stub: absent (correctly deleted by META-261)"
fi

# ──────────────────────────────────────────────────────────────────────────
# Assert 2: audit-required uses if: always()
# ──────────────────────────────────────────────────────────────────────────
audit_required_if="$(awk '
  /^  audit-required:$/ { in_block=1; next }
  in_block && /^    if:/ {
    sub(/^    if:[[:space:]]*/, "")
    print
    exit
  }
  in_block && /^  [a-z]/ && !/^    / { in_block=0 }
' "$CI_YML")"

if [[ "$audit_required_if" == "always()" ]]; then
  ok "audit-required uses 'if: always()' — always emits a check-run"
else
  fail "audit-required.if is '$audit_required_if', expected 'always()'"
fi

# ──────────────────────────────────────────────────────────────────────────
# Assert 3: audit-required maps SKIPPED → exit 0 (SKIPPED-as-pass)
# ──────────────────────────────────────────────────────────────────────────
# The aggregator step must contain logic like:
#   if [ "$result" = "skipped" ]; then ... exit 0
# Extract the audit-required job block using line number anchoring.
audit_req_start=$(grep -n "^  audit-required:" "$CI_YML" | head -1 | cut -d: -f1)
if [[ -z "$audit_req_start" ]]; then
  fail "audit-required job not found in ci.yml"
else
  # Read from the job start line; stop at the next top-level job (^  <word>:)
  # Use tail+grep rather than awk range to avoid the end-anchor overlap issue.
  if tail -n +"$audit_req_start" "$CI_YML" | \
     awk 'NR>1 && /^  [a-z][a-z0-9_-]+:$/{exit} {print}' | \
     grep -q "skipped"; then
    ok "audit-required maps SKIPPED → PASS (doc-only PRs unblocked)"
  else
    fail "audit-required missing 'skipped' → PASS mapping — doc-only PRs will wedge"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────
# Assert 4: audit-required needs only `audit` (no stub dependency)
# ──────────────────────────────────────────────────────────────────────────
audit_required_needs="$(awk '
  /^  audit-required:$/ { in_block=1; next }
  in_block && /^    needs:/ { print; exit }
  in_block && /^  [a-z]/ && !/^    / { in_block=0 }
' "$CI_YML")"

if echo "$audit_required_needs" | grep -q "audit" && \
   ! echo "$audit_required_needs" | grep -q "audit-stub"; then
  ok "audit-required.needs: [audit] only — no stub dependency"
else
  fail "audit-required.needs wrong; got: $audit_required_needs"
fi

# ──────────────────────────────────────────────────────────────────────────
# Assert 5: test rollup uses `if: always()` (no test-stub needed)
# ──────────────────────────────────────────────────────────────────────────
test_if="$(awk '
  /^  test:$/ { in_block=1; next }
  in_block && /^    if:/ {
    sub(/^    if:[[:space:]]*/, "")
    print
    exit
  }
  in_block && /^  [a-z]/ && !/^    / { in_block=0 }
' "$CI_YML")"

if [[ "$test_if" == "always()" ]]; then
  ok "test rollup uses 'if: always()' — fires on every PR (no test-stub needed)"
else
  fail "test rollup if: is '$test_if', expected 'always()'"
fi

# ──────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────
echo
echo "── INFRA-2191/META-261 result: $PASS passed, $FAIL failed ──"

if [[ $FAIL -gt 0 ]]; then
  echo
  echo "FAILED. The doc-only PR wedge guard has regressed."
  echo "Symptom: doc/yaml-only PRs sit BLOCKED with 0 fails 0 pending because"
  echo "  audit-required does not emit SUCCESS when audit is skipped."
  echo "Fix: ensure audit-required has if: always() and maps skipped → exit 0."
  exit 1
fi

echo "OK — audit-required handles skipped audit (doc-only PRs unblocked via META-261 pattern)."
