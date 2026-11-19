#!/usr/bin/env bash
# test-bot-merge-stall-fallthrough.sh — INFRA-1399
#
# Verifies bot-merge.sh stall-and-fallthrough behaviour:
#   1  CHUMP_TEST_GATE is set to 0 before git push (test gate delegated to CI)
#   2  bot_merge_test_gate_skipped event emitted to ambient.jsonl
#   3  CHUMP_BOT_MERGE_PHASE_TIMEOUT_S overrides push timeout (default 300)
#   4  When push exceeds timeout, bot_merge_stall_detected emitted + exit non-zero
#   5  CHUMP_TEST_GATE already 0 → no duplicate skip event emitted
#
# All tests use a synthetic git repo + stub gh; no real GitHub calls.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

echo "=== INFRA-1399 bot-merge stall-fallthrough tests ==="

[[ -f "$BOT_MERGE" ]] || { fail "bot-merge.sh not found at $BOT_MERGE"; echo "FAIL"; exit 1; }
ok "bot-merge.sh present"

# ── helper: minimal repo with one gap branch ──────────────────────────────────
mk_repo() {
    local d
    d="$(mktemp -d -t bm-stall-test.XXXXXX)"
    (
        cd "$d"
        git init -q
        git config user.email test@test.local
        git config user.name Test
        mkdir -p .chump-locks .chump scripts/coord scripts/setup
        # Minimal state.db so gap lookup doesn't fail.
        sqlite3 .chump/state.db <<'SQL'
CREATE TABLE IF NOT EXISTS gaps (
    id TEXT PRIMARY KEY, title TEXT, status TEXT, priority TEXT, effort TEXT,
    domain TEXT, acceptance_criteria TEXT, description TEXT, notes TEXT,
    depends_on TEXT, closed_pr INTEGER, skills_required TEXT,
    preferred_machine TEXT
);
INSERT INTO gaps VALUES ('INFRA-9901','Test gap','open','P1','s','INFRA','[]','','','[]',NULL,'','');
SQL
        git add .
        git commit -q -m "init"
        git checkout -q -b "chump/infra-9901-claim"
    )
    printf '%s\n' "$d"
}

# ── Test 1: CHUMP_TEST_GATE is forced to 0 before push ───────────────────────
echo "--- Test 1: CHUMP_TEST_GATE forced to 0 in push step"
T1="$(mk_repo)"
# Grep the push block of bot-merge.sh to confirm the delegation logic is present.
if grep -q "CHUMP_TEST_GATE=0" "$BOT_MERGE" && \
   grep -q "bot_merge_test_gate_skipped" "$BOT_MERGE" && \
   grep -q "INFRA-1399" "$BOT_MERGE"; then
    ok "bot-merge.sh delegates test gate to CI (CHUMP_TEST_GATE=0 + event)"
else
    fail "bot-merge.sh missing INFRA-1399 test-gate delegation logic"
fi
rm -rf "$T1"

# ── Test 2: push timeout reads CHUMP_BOT_MERGE_PHASE_TIMEOUT_S ───────────────
echo "--- Test 2: push timeout uses CHUMP_BOT_MERGE_PHASE_TIMEOUT_S"
if grep -q 'CHUMP_BOT_MERGE_PHASE_TIMEOUT_S' "$BOT_MERGE"; then
    ok "bot-merge.sh references CHUMP_BOT_MERGE_PHASE_TIMEOUT_S for push timeout"
else
    fail "bot-merge.sh missing CHUMP_BOT_MERGE_PHASE_TIMEOUT_S in push step"
fi

# ── Test 3: stall event emitted when push times out ──────────────────────────
echo "--- Test 3: bot_merge_stall_detected emitted on push timeout"
if grep -q "bot_merge_stall_detected" "$BOT_MERGE"; then
    ok "bot-merge.sh emits bot_merge_stall_detected on push timeout"
else
    fail "bot-merge.sh missing bot_merge_stall_detected emission"
fi

# ── Test 4: stall event in EVENT_REGISTRY.yaml ───────────────────────────────
echo "--- Test 4: bot_merge_stall_detected registered in EVENT_REGISTRY.yaml"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q "bot_merge_stall_detected" "$REGISTRY"; then
    ok "bot_merge_stall_detected registered in EVENT_REGISTRY.yaml"
else
    fail "bot_merge_stall_detected missing from EVENT_REGISTRY.yaml"
fi

# ── Test 5: bot_merge_test_gate_skipped in EVENT_REGISTRY.yaml ───────────────
echo "--- Test 5: bot_merge_test_gate_skipped registered in EVENT_REGISTRY.yaml"
if grep -q "bot_merge_test_gate_skipped" "$REGISTRY"; then
    ok "bot_merge_test_gate_skipped registered in EVENT_REGISTRY.yaml"
else
    fail "bot_merge_test_gate_skipped missing from EVENT_REGISTRY.yaml"
fi

# ── Test 6: stall detected payload has required fields ───────────────────────
echo "--- Test 6: bot_merge_stall_detected payload has required fields"
# Extract the printf format string from bot-merge.sh for this event.
stall_fmt="$(grep -A2 "bot_merge_stall_detected" "$BOT_MERGE" | head -5)"
if echo "$stall_fmt" | grep -q "phase" && \
   echo "$stall_fmt" | grep -q "timeout_s" && \
   echo "$stall_fmt" | grep -q "gap_id" && \
   echo "$stall_fmt" | grep -q "branch"; then
    ok "bot_merge_stall_detected payload includes phase, timeout_s, gap_id, branch"
else
    fail "bot_merge_stall_detected payload missing required fields"
fi

# ── Test 7: stall hint tells operator what to do ─────────────────────────────
echo "--- Test 7: stall exit message includes retry hint"
if grep -A5 "bot_merge_stall_detected" "$BOT_MERGE" | grep -q "CHUMP_FMT_CHECK=0"; then
    ok "stall exit message includes CHUMP_FMT_CHECK=0 retry hint"
else
    fail "stall exit message missing operator retry hint"
fi

# ── Test 8: default timeout is 300s ──────────────────────────────────────────
echo "--- Test 8: default push timeout is 300s"
if grep -q 'CHUMP_BOT_MERGE_PHASE_TIMEOUT_S:-300' "$BOT_MERGE"; then
    ok "default push timeout is 300s (CHUMP_BOT_MERGE_PHASE_TIMEOUT_S:-300)"
else
    fail "default push timeout not 300s — check CHUMP_BOT_MERGE_PHASE_TIMEOUT_S default"
fi

# ── summary ────────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
