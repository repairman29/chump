#!/usr/bin/env bash
# test-bot-merge-verify-reaches.sh — regression test for CREDIBLE-215 AC4.
#
# CREDIBLE-215 requires the mechanical stub-detection check
# (`chump verify-reaches`) to run in the ship path early enough to save a
# CI round — i.e. before `gh pr create`, not after. This guards against a
# future edit silently dropping (or moving after pr-create) the call in
# scripts/coord/bot-merge.sh.
#
# Run:
#   ./scripts/ci/test-bot-merge-verify-reaches.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

[[ -f "$BOT_MERGE" ]] || { echo "FATAL: $BOT_MERGE not found"; exit 1; }

# 1. The call exists.
if grep -q 'chump verify-reaches --gap' "$BOT_MERGE"; then
    ok "bot-merge.sh calls chump verify-reaches"
else
    fail "bot-merge.sh does not call chump verify-reaches"
fi

# 2. It appears before "gh pr create" (line-number ordering), not after —
#    otherwise the advisory signal arrives too late to save a CI round.
_reaches_line=$(grep -n 'chump verify-reaches --gap' "$BOT_MERGE" | head -1 | cut -d: -f1 || true)
_prcreate_line=$(grep -n 'stage_start "gh pr create"' "$BOT_MERGE" | head -1 | cut -d: -f1 || true)
if [[ -n "$_reaches_line" && -n "$_prcreate_line" && "$_reaches_line" -lt "$_prcreate_line" ]]; then
    ok "verify-reaches call precedes gh pr create (line $_reaches_line < $_prcreate_line)"
else
    fail "verify-reaches call does not precede gh pr create (reaches=$_reaches_line, pr_create=$_prcreate_line)"
fi

# 3. It never gates the ship (advisory only) — no `_bm_fail` tied to it.
_reaches_block=$(sed -n "${_reaches_line:-1},+10p" "$BOT_MERGE" 2>/dev/null || true)
if echo "$_reaches_block" | grep -q '_bm_fail'; then
    fail "verify-reaches block calls _bm_fail — must stay advisory, never block the ship"
else
    ok "verify-reaches block is advisory only (no _bm_fail)"
fi

echo ""
echo "test-bot-merge-verify-reaches.sh: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    printf '  - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
