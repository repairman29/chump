#!/usr/bin/env bash
# test-role-card-emit-and-query.sh — INFRA-2017 smoke test
#
# Emits 3 role_card events from ONE session_id under 3 different aliases
# (simulating a curator role-switching within a shell over a session), then
# asserts role-card-query.sh dedupes by session_id and returns exactly 1
# entry with all 3 aliases present. The role-switch dedup logic is
# time-independent (it scans the ambient tail, not a wall-clock window), so
# this test issues the 3 emits back-to-back rather than literally sleeping
# 60s between them — the AC's "over 60 seconds" describes the real-world
# curator shift this simulates, not a required test runtime.
#
# Exit 0 = all assertions pass. Exit 1 = at least one failure.

set -uo pipefail

PASS=0
FAIL=0
_FAILURES=()

pass() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); _FAILURES+=("$1"); printf '[FAIL] %s\n' "$1"; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export CHUMP_AMBIENT_LOG="$TMPDIR_TEST/ambient.jsonl"
export CHUMP_REPO="$TMPDIR_TEST"
export CHUMP_SESSION_ID="test-role-card-session-$$"
mkdir -p "$TMPDIR_TEST/.chump-locks"

EMIT="$REPO_ROOT/scripts/coord/role-card-emit.sh"
QUERY="$REPO_ROOT/scripts/dev/role-card-query.sh"

if [[ ! -x "$EMIT" ]]; then
    fail "role-card-emit.sh exists and is executable"
else
    pass "role-card-emit.sh exists and is executable"
fi

if [[ ! -x "$QUERY" ]]; then
    fail "role-card-query.sh exists and is executable"
else
    pass "role-card-query.sh exists and is executable"
fi

bash "$EMIT" --role curator-opus-target --lane EFFECTIVE --claim INFRA-2017 --wake-mode event-driven >/dev/null 2>&1
bash "$EMIT" --role curator-opus-ci-audit --lane CREDIBLE --wake-mode cron >/dev/null 2>&1
bash "$EMIT" --role curator-opus-shepherd --lane RESILIENT --wake-mode event-driven >/dev/null 2>&1

EMIT_COUNT="$(grep -c '"kind":"role_card"' "$CHUMP_AMBIENT_LOG" 2>/dev/null || echo 0)"
if [[ "$EMIT_COUNT" -eq 3 ]]; then
    pass "3 role_card events emitted to ambient.jsonl"
else
    fail "3 role_card events emitted to ambient.jsonl (got $EMIT_COUNT)"
fi

QUERY_OUT="$(bash "$QUERY" --session "$CHUMP_SESSION_ID" 2>/dev/null)"
QUERY_LINES="$(printf '%s\n' "$QUERY_OUT" | grep -c . || true)"

if [[ "$QUERY_LINES" -eq 1 ]]; then
    pass "role-card-query returns exactly 1 entry for the session (deduped)"
else
    fail "role-card-query returns exactly 1 entry for the session (got $QUERY_LINES)"
fi

ALIAS_COUNT="$(printf '%s' "$QUERY_OUT" | python3 -c 'import sys, json; print(len(json.loads(sys.stdin.read()).get("aliases", [])))' 2>/dev/null || echo 0)"
if [[ "$ALIAS_COUNT" -eq 3 ]]; then
    pass "returned role-card has aliases=3-tuple"
else
    fail "returned role-card has aliases=3-tuple (got $ALIAS_COUNT)"
fi

for role in curator-opus-target curator-opus-ci-audit curator-opus-shepherd; do
    if printf '%s' "$QUERY_OUT" | grep -q "\"$role\""; then
        pass "aliases includes $role"
    else
        fail "aliases includes $role"
    fi
done

if printf '%s' "$QUERY_OUT" | grep -q '"session_id": "'"$CHUMP_SESSION_ID"'"'; then
    pass "role-card session_id matches CHUMP_SESSION_ID (not alias name)"
else
    fail "role-card session_id matches CHUMP_SESSION_ID (not alias name)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    echo "Failures:"
    for f in "${_FAILURES[@]}"; do
        echo "  - $f"
    done
    exit 1
fi

exit 0
