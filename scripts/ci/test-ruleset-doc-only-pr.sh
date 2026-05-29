#!/usr/bin/env bash
# test-ruleset-doc-only-pr.sh — INFRA-2191
#
# Guards the doc-only PR wedge fix: when branch protection (ruleset 15133729 on
# main) requires the `audit` check, doc/yaml-only PRs must still emit an `audit`
# check-run via the audit-stub job. Without this, the real `audit` job skips on
# doc-only diffs (its `if:` short-circuits) and no check-run is ever emitted,
# leaving the PR BLOCKED with 0 fails AND 0 pending forever (the 2026-05-29
# wedge that took down 6 PRs and required manual ruleset surgery).
#
# Static lint asserts:
#   (1) The audit-stub job's `name:` field is `audit` (NOT `audit-stub`) — so
#       its check-run satisfies the bare `audit` required-status-check.
#   (2) The real `audit` job and `audit-stub` are mutually exclusive on PR
#       events — exactly one runs and emits the `audit` context per PR.
#   (3) The `audit-required` rollup still references both jobs by job-key
#       (so its needs: chain didn't break when we renamed the stub's `name:`).
#   (4) The `test` rollup uses `if: always()` (it doesn't need a stub — it
#       fires unconditionally as long as one of its needs queues). Documents
#       why no `test-stub` is required in this fix.
#
# Run locally:
#   bash scripts/ci/test-ruleset-doc-only-pr.sh
#
# Exits non-zero on any assertion failure. Mirrored into preflight via
# scripts/ci/preflight-ci-parity-exceptions.txt entry.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-2191 ruleset doc-only-PR wedge guard ==="
echo

[[ -f "$CI_YML" ]] || { echo "FATAL: ci.yml not found at $CI_YML"; exit 2; }

# ──────────────────────────────────────────────────────────────────────────
# Assert 1: audit-stub job's `name:` is exactly `audit`
# ──────────────────────────────────────────────────────────────────────────
# The 4-space indent + `name:` line within the audit-stub block. We anchor
# on the job-key line `^  audit-stub:` and look at the next ~3 lines for
# `name:`.
audit_stub_name="$(awk '
  /^  audit-stub:$/ { in_block=1; next }
  in_block && /^    name:/ {
    sub(/^    name:[[:space:]]*/, "")
    sub(/[[:space:]]*#.*/, "")  # strip trailing inline comment
    print
    exit
  }
  in_block && /^  [a-z]/ && !/^    / { in_block=0 }
' "$CI_YML")"

if [[ "$audit_stub_name" == "audit" ]]; then
  ok "audit-stub.name == 'audit' (emits as required-check context)"
else
  fail "audit-stub.name is '$audit_stub_name', expected 'audit' (INFRA-2191: doc-only PRs need this exact name to satisfy ruleset)"
fi

# ──────────────────────────────────────────────────────────────────────────
# Assert 2: audit-stub fires when real audit skips (mutual exclusion on PR)
# ──────────────────────────────────────────────────────────────────────────
# Real audit `if:` must mention `docs_only != 'true'` (skip on docs-only).
# audit-stub `if:` must mention `docs_only == 'true'` OR `code != 'true'`
# AND `github.event_name == 'pull_request'` (fire on PR when audit skips).
real_audit_if="$(awk '
  /^  audit:$/ { in_block=1; next }
  in_block && /^    if:/ { in_if=1 }
  in_block && in_if {
    print
    if ($0 ~ /^    [a-z]/ && !/^    if:/) { in_if=0 }
  }
  in_block && /^  [a-z]/ && !/^    / && !/^  audit:/ { in_block=0 }
' "$CI_YML" | tr -d '\n')"

stub_audit_if="$(awk '
  /^  audit-stub:$/ { in_block=1; next }
  in_block && /^    if:/ { in_if=1 }
  in_block && in_if {
    print
    if ($0 ~ /^    [a-z]/ && !/^    if:/) { in_if=0 }
  }
  in_block && /^  [a-z]/ && !/^    / { in_block=0 }
' "$CI_YML" | tr -d '\n')"

if [[ "$real_audit_if" == *"docs_only"* && "$real_audit_if" == *"!= 'true'"* ]]; then
  ok "real audit.if skips on docs-only PRs (docs_only != 'true')"
else
  fail "real audit.if missing 'docs_only != true' skip clause; got: $real_audit_if"
fi

if [[ "$stub_audit_if" == *"pull_request"* ]] && \
   [[ "$stub_audit_if" == *"docs_only"* || "$stub_audit_if" == *"code"* ]]; then
  ok "audit-stub.if fires on PR events covering docs-only / no-code lane"
else
  fail "audit-stub.if missing PR + docs_only/code gating; got: $stub_audit_if"
fi

# ──────────────────────────────────────────────────────────────────────────
# Assert 3: audit-required still references both jobs by job-key
# ──────────────────────────────────────────────────────────────────────────
# Renaming audit-stub.name to `audit` MUST NOT break `needs: [audit, audit-stub]`
# in the audit-required rollup (needs: uses job-keys, not name:).
audit_required_needs="$(awk '
  /^  audit-required:$/ { in_block=1; next }
  in_block && /^    needs:/ { print; exit }
  in_block && /^  [a-z]/ && !/^    / { in_block=0 }
' "$CI_YML")"

if [[ "$audit_required_needs" == *"audit"* && "$audit_required_needs" == *"audit-stub"* ]]; then
  ok "audit-required needs: still includes both [audit, audit-stub] job-keys"
else
  fail "audit-required.needs broken — expected both 'audit' and 'audit-stub' job-keys; got: $audit_required_needs"
fi

# ──────────────────────────────────────────────────────────────────────────
# Assert 4: test rollup uses `if: always()` (no test-stub needed)
# ──────────────────────────────────────────────────────────────────────────
# The `test` job is itself a rollup with `if: always()` and `needs:` includes
# pr-hygiene (which runs on every PR regardless of path-filter). Therefore
# `test` always emits a check-run on every PR — no test-stub required.
# This assertion documents the architectural decision and guards against
# regression (e.g., someone replacing `if: always()` with a gated condition).
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
  fail "test rollup if: is '$test_if', expected 'always()' — without this, doc-only PRs may wedge on missing 'test' check (INFRA-2191)"
fi

# ──────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────
echo
echo "── INFRA-2191 result: $PASS passed, $FAIL failed ──"

if [[ $FAIL -gt 0 ]]; then
  echo
  echo "FAILED. The doc-only PR wedge fix has regressed."
  echo "Symptom in production: doc/yaml-only PRs sit BLOCKED with 0 fails 0 pending"
  echo "  because branch protection waits for an 'audit' check-run that never emits."
  echo "See docs/process/CLAUDE_GOTCHAS.md → 'doc-only PR wedge' for the recovery"
  echo "  procedure (manual ruleset surgery) and the architectural fix this test"
  echo "  guards (audit-stub emits as 'audit' via mutually-exclusive if: conditions)."
  exit 1
fi

echo "OK — audit-stub still emits as 'audit' on doc-only PRs; ruleset wedge guarded."
