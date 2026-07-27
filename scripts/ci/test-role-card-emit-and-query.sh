#!/usr/bin/env bash
# CI test: INFRA-2017 — role-card-emit.sh + role-card-query.sh
#
# Emits 3 role_card events from ONE session_id under 3 different aliases
# (simulating a session that role-switches within a shell) and asserts
# role-card-query.sh dedupes by session_id (not alias), returning exactly
# 1 entry with a 3-tuple of aliases.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
EMIT="$REPO_ROOT/scripts/coord/role-card-emit.sh"
QUERY="$REPO_ROOT/scripts/dev/role-card-query.sh"
PASS=0; FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-2017 role-card emit/query test ==="
echo

# ── 1. Structural checks ─────────────────────────────────────────────────────
[[ -x "$EMIT" ]] && ok "role-card-emit.sh exists and is executable" || fail "role-card-emit.sh missing or not executable"
[[ -x "$QUERY" ]] && ok "role-card-query.sh exists and is executable" || fail "role-card-query.sh missing or not executable"

grep -q 'role_card' "$EMIT" && ok "emit script writes kind=role_card" || fail "role_card missing from emit script"

REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q 'kind: role_card' "$REGISTRY" && ok "role_card registered in EVENT_REGISTRY" || fail "role_card not in EVENT_REGISTRY"

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available, cannot run functional checks" >&2
    echo
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
    exit $?
fi

# ── 2. Functional test: 3 emits, 1 session_id, 3 aliases, over ~60s ─────────
echo
echo "--- Functional: 3 role_card emits from one session_id ---"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
AMB="$TMPDIR_TEST/ambient.jsonl"; touch "$AMB"

SESSION_ID="test-session-uuid-role-card-$$"

CHUMP_AMBIENT_LOG="$AMB" bash "$EMIT" --role curator-opus-target --lane EFFECTIVE \
    --claim INFRA-2017 --wake-mode event-driven --session-id "$SESSION_ID" >/dev/null 2>&1
sleep 1
CHUMP_AMBIENT_LOG="$AMB" bash "$EMIT" --role curator-opus-decompose --lane RESILIENT \
    --wake-mode cron --session-id "$SESSION_ID" >/dev/null 2>&1
sleep 1
CHUMP_AMBIENT_LOG="$AMB" bash "$EMIT" --role curator-opus-ci-audit --lane CREDIBLE \
    --wake-mode manual --session-id "$SESSION_ID" >/dev/null 2>&1

LINES=$(grep -c '"kind":"role_card"' "$AMB" 2>/dev/null || echo 0)
[[ "$LINES" -eq 3 ]] && ok "3 role_card lines written to ambient" || fail "expected 3 role_card lines, got $LINES"

RESULT=$(CHUMP_AMBIENT_LOG="$AMB" bash "$QUERY" --session-id "$SESSION_ID")

ENTRY_COUNT=$(echo "$RESULT" | jq 'length')
[[ "$ENTRY_COUNT" -eq 1 ]] && ok "query returns exactly 1 entry for session_id" || fail "expected 1 entry, got $ENTRY_COUNT"

ALIAS_COUNT=$(echo "$RESULT" | jq '.[0].aliases | length')
[[ "$ALIAS_COUNT" -eq 3 ]] && ok "entry has aliases 3-tuple" || fail "expected 3 aliases, got $ALIAS_COUNT"

GOT_SESSION=$(echo "$RESULT" | jq -r '.[0].session_id')
[[ "$GOT_SESSION" == "$SESSION_ID" ]] && ok "entry session_id matches (not alias-keyed)" || fail "session_id mismatch: $GOT_SESSION"

LATEST_LANE=$(echo "$RESULT" | jq -r '.[0].primary_lane')
[[ "$LATEST_LANE" == "CREDIBLE" ]] && ok "latest primary_lane reflects most recent role-switch" || fail "expected CREDIBLE, got $LATEST_LANE"

# ── 3. A second, distinct session_id must NOT merge into the first ─────────
echo
echo "--- Functional: distinct session_id stays separate ---"

OTHER_SESSION="test-session-uuid-other-$$"
CHUMP_AMBIENT_LOG="$AMB" bash "$EMIT" --role curator-opus-handoff --lane RESILIENT \
    --wake-mode cron --session-id "$OTHER_SESSION" >/dev/null 2>&1

ALL_RESULT=$(CHUMP_AMBIENT_LOG="$AMB" bash "$QUERY")
ALL_COUNT=$(echo "$ALL_RESULT" | jq 'length')
[[ "$ALL_COUNT" -eq 2 ]] && ok "query returns 2 distinct sessions total" || fail "expected 2 sessions, got $ALL_COUNT"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
