#!/usr/bin/env bash
# test-bot-merge-exit-phases.sh — RESILIENT-011: bot-merge.sh exit codes per phase
#
# Verifies that _bm_fail calls in bot-merge.sh use the canonical exit code table:
#   10=preflight  11=rebase  12=fmt  13=clippy  14=test  15=push  16=pr-create
#
# Tests:
#   1. _bm_fail function emits kind=bot_merge_phase_failure to ambient.jsonl
#   2. Each phase uses its canonical exit code (static grep on script)
#   3. fmt phase uses exit 12 (newly added by RESILIENT-011)
#   4. Canonical exit codes are documented in the _bm_fail header comment

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# ── Test 1: _bm_fail emits kind=bot_merge_phase_failure ───────────────────────
grep -q 'kind.*bot_merge_phase_failure' "$BOT_MERGE" \
    || fail "Test 1: _bm_fail must emit kind=bot_merge_phase_failure (RESILIENT-011)"
pass "Test 1: _bm_fail emits kind=bot_merge_phase_failure"

# ── Test 2: canonical exit code table is documented in header comment ──────────
grep -q '12.*fmt-fail\|12 — fmt' "$BOT_MERGE" \
    || fail "Test 2: exit code 12 (fmt-fail) not documented in _bm_fail header"
grep -q '13.*clippy-fail\|13 — clippy' "$BOT_MERGE" \
    || fail "Test 2: exit code 13 (clippy-fail) not documented in _bm_fail header"
grep -q '14.*test-fail\|14 — test' "$BOT_MERGE" \
    || fail "Test 2: exit code 14 (test-fail) not documented in _bm_fail header"
grep -q '15.*push-fail\|15 — push' "$BOT_MERGE" \
    || fail "Test 2: exit code 15 (push-fail) not documented in _bm_fail header"
grep -q '16.*pr-create-fail\|16 — pr-create' "$BOT_MERGE" \
    || fail "Test 2: exit code 16 (pr-create-fail) not documented in _bm_fail header"
pass "Test 2: all canonical exit codes documented in _bm_fail header"

# ── Test 3: each phase calls _bm_fail with its canonical code ─────────────────
grep -q '_bm_fail "preflight" 10' "$BOT_MERGE" \
    || fail "Test 3: preflight phase must use exit code 10"
grep -q '_bm_fail "rebase" 11' "$BOT_MERGE" \
    || fail "Test 3: rebase phase must use exit code 11"
grep -q '_bm_fail "fmt" 12' "$BOT_MERGE" \
    || fail "Test 3: fmt phase must use exit code 12 (RESILIENT-011 addition)"
grep -q '_bm_fail "clippy" 13' "$BOT_MERGE" \
    || fail "Test 3: clippy phase must use exit code 13"
grep -q '_bm_fail "test" 14' "$BOT_MERGE" \
    || fail "Test 3: test phase must use exit code 14"
grep -q '_bm_fail "push" 15' "$BOT_MERGE" \
    || fail "Test 3: push phase must use exit code 15"
grep -q '_bm_fail "pr-create" 16' "$BOT_MERGE" \
    || fail "Test 3: pr-create phase must use exit code 16"
pass "Test 3: all 7 phases use their canonical exit codes"

# ── Test 4: no phase uses old/conflicting exit codes ──────────────────────────
# Old code had clippy=12, test=13, push=14, pr-create=15 — verify none remain.
# Exclude comments and the doc table (which mention the OLD numbers in context).
if grep -n '_bm_fail "clippy" 12\|_bm_fail "test" 13\|_bm_fail "push" 14\|_bm_fail "pr-create" 15' "$BOT_MERGE" | grep -v "^.*#"; then
    fail "Test 4: stale exit codes found (clippy=12, test=13, push=14, or pr-create=15) — update to RESILIENT-011 table"
fi
pass "Test 4: no stale pre-RESILIENT-011 exit codes remain"

# ── Test 5: _bm_fail actually invokes kind=bot_merge_phase_failure ─────────────
TMP="$(mktemp -d -t test-bm-exit-phases.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

AMBIENT="$TMP/ambient.jsonl"
(
    export CHUMP_AMBIENT_LOG="$AMBIENT"
    export GAP_IDS="TEST-001"
    export BRANCH="test-branch"
    # INFRA-1241: source lib/ambient-write.sh so _bm_fail can emit the phase-failure
    # ambient event in this test subshell (moved out of bot-merge.sh by INFRA-1241).
    source "$REPO_ROOT/scripts/coord/lib/ambient-write.sh" 2>/dev/null || true
    # Source only the _bm_fail function (skip everything else that requires git)
    eval "$(grep -A 12 '^_bm_fail()' "$BOT_MERGE" | head -13)"
    _bm_fail "test" 14 "synthetic test failure" 2>/dev/null || true
) || true  # exits non-zero; capture ambient output

if [[ -f "$AMBIENT" ]]; then
    python3 -c "
import json, sys
line = open('$AMBIENT').read().strip()
ev = json.loads(line)
assert ev.get('kind') == 'bot_merge_phase_failure', f'wrong kind: {ev.get(\"kind\")}'
assert ev.get('step') == 'test', f'wrong step: {ev.get(\"step\")}'
assert ev.get('exit_code') == 14, f'wrong exit_code: {ev.get(\"exit_code\")}'
print('ambient_ok')
" | grep -q "ambient_ok" \
        || fail "Test 5: ambient event has wrong kind/step/exit_code"
    pass "Test 5: _bm_fail emits correct bot_merge_phase_failure event to ambient.jsonl"
else
    fail "Test 5: ambient.jsonl not written by _bm_fail"
fi

echo ""
echo "All RESILIENT-011 bot-merge exit-phase checks passed (5/5)."
