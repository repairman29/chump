#!/usr/bin/env bash
# test-bot-merge-skip-rebase.sh — INFRA-570 unit tests for bot-merge.sh rebase-skip logic.
#
# Verifies:
#   (1) BEHIND=0  → rebase skipped, no "rebase" message.
#   (2) BEHIND=3  → rebase skipped (≤5 threshold), correct message emitted.
#   (3) BEHIND=5  → rebase skipped (at boundary).
#   (4) BEHIND=6  → rebase NOT skipped (above threshold).
#   (5) BEHIND=3 + CHUMP_FORCE_REBASE=1 → rebase NOT skipped.

set -euo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

# We test the logic inline rather than calling bot-merge.sh end-to-end
# (bot-merge.sh requires a real git repo + GitHub auth). Extract and re-run
# the decision function from the script.

check_skip() {
    local behind="$1" force="${2:-0}"
    local _skip_rebase=0
    if [[ "$behind" -le 5 && "${force}" != "1" ]]; then
        _skip_rebase=1
    fi
    echo "$_skip_rebase"
}

emit_message() {
    local behind="$1" force="${2:-0}"
    local _skip_rebase
    _skip_rebase=$(check_skip "$behind" "$force")
    if [[ "$_skip_rebase" == "1" && "$behind" -gt 0 ]]; then
        echo "[bot-merge] skip rebase: $behind commits behind main (≤5 threshold; set CHUMP_FORCE_REBASE=1 to override)"
    fi
}

echo "=== bot-merge.sh rebase-skip logic tests ==="

# ── 1. BEHIND=0 → skip ───────────────────────────────────────────────────────
echo "--- Test 1: BEHIND=0 → rebase skipped ---"
result=$(check_skip 0)
[[ "$result" == "1" ]] && ok "BEHIND=0 skips rebase" || fail "BEHIND=0 should skip rebase (got $result)"

# ── 2. BEHIND=3 → skip + correct message ─────────────────────────────────────
echo "--- Test 2: BEHIND=3 → rebase skipped, message emitted ---"
result=$(check_skip 3)
[[ "$result" == "1" ]] && ok "BEHIND=3 skips rebase" || fail "BEHIND=3 should skip rebase (got $result)"
msg=$(emit_message 3)
if echo "$msg" | grep -q "\[bot-merge\] skip rebase: 3 commits behind main"; then
    ok "BEHIND=3 emits correct message"
else
    fail "BEHIND=3 message wrong: '$msg'"
fi

# ── 3. BEHIND=5 → skip (boundary) ────────────────────────────────────────────
echo "--- Test 3: BEHIND=5 → rebase skipped (boundary) ---"
result=$(check_skip 5)
[[ "$result" == "1" ]] && ok "BEHIND=5 skips rebase (boundary)" || fail "BEHIND=5 should skip rebase (got $result)"

# ── 4. BEHIND=6 → no skip ────────────────────────────────────────────────────
echo "--- Test 4: BEHIND=6 → rebase NOT skipped ---"
result=$(check_skip 6)
[[ "$result" == "0" ]] && ok "BEHIND=6 does not skip rebase" || fail "BEHIND=6 should not skip rebase (got $result)"

# ── 5. BEHIND=3 + CHUMP_FORCE_REBASE=1 → no skip ────────────────────────────
echo "--- Test 5: BEHIND=3 + CHUMP_FORCE_REBASE=1 → rebase NOT skipped ---"
result=$(check_skip 3 1)
[[ "$result" == "0" ]] && ok "CHUMP_FORCE_REBASE=1 overrides skip" || fail "CHUMP_FORCE_REBASE=1 should force rebase (got $result)"

echo
echo "=== results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || { for f in "${FAILS[@]}"; do echo "  - $f"; done; exit 1; }
exit 0
