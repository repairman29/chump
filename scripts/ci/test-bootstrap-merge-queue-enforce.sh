#!/usr/bin/env bash
# test-bootstrap-merge-queue-enforce.sh — CI smoke test for INFRA-1518
# Rust-First-Bypass: shell test for a shell-only lib (merge_queue_enforce in
#   scripts/setup/lib/merge-queue-enforce.sh); no state mutation, < 120 LOC.
#
# Scenarios:
#   1. install mode, disabled  → PUT fires, exits 0
#   2. install mode, enabled   → no-op (no PUT call recorded), exits 0
#   3. check mode, disabled    → exits 1, no PUT call recorded
#   4. check mode, enabled     → exits 0, no PUT call recorded
#
# Stubs `gh` as a shell function so no real GitHub call is ever made.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/setup/lib/merge-queue-enforce.sh"

PASS=0; FAIL=0; declare -a FAILURES=()
pass() { echo "  ✓ $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  ✗ $1"; FAIL=$(( FAIL + 1 )); FAILURES+=("$1"); }

[[ -f "$LIB" ]] || { echo "FATAL: lib missing at $LIB" >&2; exit 2; }

CALL_LOG="$(mktemp)"
trap 'rm -f "$CALL_LOG"' EXIT

# gh stub: records every invocation to CALL_LOG, controlled via ENABLED_STATE.
ENABLED_STATE="false"
gh() {
    echo "$*" >> "$CALL_LOG"
    if [[ "$1" == "api" && "$2" != --method* ]]; then
        # read path: repos/.../branches/main/protection — apply --jq like the
        # real `gh` would, since merge_queue_enforce relies on gh doing that.
        local body
        if [[ "$ENABLED_STATE" == "true" ]]; then
            body='{"required_pull_request_reviews":{"merge_queue":{"enabled":true}}}'
        else
            body='{"required_pull_request_reviews":{}}'
        fi
        echo "$body" | jq -r '.required_pull_request_reviews.merge_queue.enabled // false'
        return 0
    fi
    if [[ "$1" == "api" && "$2" == "--method" ]]; then
        # write path: PUT
        cat >/dev/null   # drain --input -
        echo '{}'
        return 0
    fi
    return 0
}

# shellcheck source=lib/merge-queue-enforce.sh
source "$LIB"

# ── Scenario 1: install mode, disabled → PUT fires, exit 0 ───────────────────
: > "$CALL_LOG"
ENABLED_STATE="false"
if merge_queue_enforce "install" "test-owner/test-repo"; then
    if grep -q -- "--method PUT" "$CALL_LOG"; then
        pass "install+disabled: PUT fired, exit 0"
    else
        fail "install+disabled: expected PUT call, none recorded"
    fi
else
    fail "install+disabled: expected exit 0, got non-zero"
fi

# ── Scenario 2: install mode, already enabled → no-op, exit 0 ────────────────
: > "$CALL_LOG"
ENABLED_STATE="true"
if merge_queue_enforce "install" "test-owner/test-repo"; then
    if grep -q -- "--method PUT" "$CALL_LOG"; then
        fail "install+enabled: expected no PUT call, but one was recorded"
    else
        pass "install+enabled: no-op, exit 0"
    fi
else
    fail "install+enabled: expected exit 0, got non-zero"
fi

# ── Scenario 3: check mode, disabled → exit 1, no PUT ─────────────────────────
: > "$CALL_LOG"
ENABLED_STATE="false"
if merge_queue_enforce "check" "test-owner/test-repo"; then
    fail "check+disabled: expected exit 1, got exit 0"
else
    if grep -q -- "--method PUT" "$CALL_LOG"; then
        fail "check+disabled: expected no PUT call in check mode, but one was recorded"
    else
        pass "check+disabled: exit 1, no PUT"
    fi
fi

# ── Scenario 4: check mode, already enabled → exit 0, no PUT ─────────────────
: > "$CALL_LOG"
ENABLED_STATE="true"
if merge_queue_enforce "check" "test-owner/test-repo"; then
    if grep -q -- "--method PUT" "$CALL_LOG"; then
        fail "check+enabled: expected no PUT call, but one was recorded"
    else
        pass "check+enabled: exit 0, no PUT"
    fi
else
    fail "check+enabled: expected exit 0, got non-zero"
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILURES[@]}"; do echo "  FAILED: $f" >&2; done
    exit 1
fi
exit 0
