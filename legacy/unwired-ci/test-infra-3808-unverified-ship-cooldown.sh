#!/usr/bin/env bash
# test-infra-3768-unverified-ship-cooldown.sh — INFRA-3808
#
# "done doesn't stick": workers infinite-looped on gaps whose work is ALREADY on
# main, re-burning a full Sonnet cycle each pick (live: EFFECTIVE-478 re-picked
# ~every 5min for 2h). Two root causes, two layers verified here:
#
#  Layer 1 (cooldown): EFFECTIVE-441 added an unverified_ship cooldown, but its
#    printf used the '"'"'…'"'"' shell-quote-nesting idiom which COLLAPSED the
#    inner JSON quotes and wrote INVALID JSON ({gap_id:… unquoted). The picker's
#    cooled_down_gaps() json.load()s each file and silently `continue`s on a parse
#    error, so every cooldown was a NO-OP. This test asserts the write now emits
#    VALID JSON with quoted keys the picker can parse.
#
#  Layer 2 (auto-close): detect_already_satisfied.py captures the agent's explicit
#    "already shipped by PR #N" conclusion (3-factor: already-done + no-op + PR ref)
#    so the worker can close the gap `already_satisfied` instead of looping.
set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
DETECT="$REPO_ROOT/scripts/dispatch/detect_already_satisfied.py"

echo "=== INFRA-3808: unverified_ship cooldown + already-satisfied auto-close ==="

# ── Layer 1: the cooldown write must be VALID JSON ───────────────────────────
# The broken idiom must be gone from the unverified_ship path...
if grep -Eq "printf '\"'\"'\{\"gap_id\":\"%s\",\"until\":%d,\"agent\":\"%s\",\"ts\":\"%s\",\"reason\":\"unverified_ship\"" "$WORKER"; then
    fail "Layer 1: broken shell-quote-nesting printf idiom still present in unverified_ship cooldown"
else
    ok "Layer 1: broken printf idiom removed from unverified_ship cooldown"
fi

# ...and the clean single-quoted form must be present.
if grep -Fq "printf '{\"gap_id\":\"%s\",\"until\":%d,\"agent\":\"%s\",\"ts\":\"%s\",\"reason\":\"unverified_ship\"}\\n'" "$WORKER"; then
    ok "Layer 1: clean valid-JSON printf present for unverified_ship cooldown"
else
    fail "Layer 1: expected clean single-quoted printf for unverified_ship cooldown"
fi

# Prove the format string actually produces parseable JSON (simulate the write).
_json="$(printf '{"gap_id":"%s","until":%d,"agent":"%s","ts":"%s","reason":"unverified_ship"}\n' \
    "EFFECTIVE-478" "1787752214" "1" "2026-08-26T09:05:18Z")"
if printf '%s' "$_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["gap_id"]=="EFFECTIVE-478" and d["until"]==1787752214' 2>/dev/null; then
    ok "Layer 1: cooldown record parses as JSON the picker can read"
else
    fail "Layer 1: cooldown record does not parse as valid JSON"
fi

# ── Layer 2: detector 3-factor signal ────────────────────────────────────────
mk() { # write a one-line assistant-message JSONL log with the given text
    python3 - "$1" <<'PY'
import json, sys
print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":sys.argv[1]}]}},separators=(",",":")))
PY
}

t_pos="$(mktemp)"; mk "The gap is already shipped in PR #4251; worktree clean, nothing to ship. No PR." > "$t_pos"
if [ "$(python3 "$DETECT" "$t_pos" G 2>/dev/null)" = "4251" ]; then
    ok "Layer 2: 3-factor already-done + no-op + PR#  → closes on PR 4251"
else
    fail "Layer 2: failed to detect a clear already-satisfied conclusion"
fi

t_work="$(mktemp)"; mk "I built on the already-implemented helper and shipped it as PR #999. Tests green." > "$t_work"
if python3 "$DETECT" "$t_work" G >/dev/null 2>&1; then
    fail "Layer 2: FALSE POSITIVE — real work (no no-op phrase) was flagged already-satisfied"
else
    ok "Layer 2: real work (already-implemented helper but shipped) is NOT closed"
fi

t_nopr="$(mktemp)"; mk "Already implemented; worktree clean, nothing to ship. Could not find a PR number." > "$t_nopr"
if python3 "$DETECT" "$t_nopr" G >/dev/null 2>&1; then
    fail "Layer 2: FALSE POSITIVE — already-done without a PR number was closed (needs int for --closed-pr)"
else
    ok "Layer 2: already-done WITHOUT a PR reference is NOT auto-closed"
fi

t_bare="$(mktemp)"; mk "EFFECTIVE-483 was already shipped as **#4250** (merged). Nothing further to ship." > "$t_bare"
if [ "$(python3 "$DETECT" "$t_bare" G 2>/dev/null)" = "4250" ]; then
    ok "Layer 2: bare #NNNN + already-shipped + nothing-further  → closes on PR 4250"
else
    fail "Layer 2: missed already-done citing a bare #4250 (EFFECTIVE-483 regression)"
fi

t_wtclean="$(mktemp)"; mk "This work already shipped in PR #4248. Working tree clean; nothing left to commit or ship." > "$t_wtclean"
if [ "$(python3 "$DETECT" "$t_wtclean" G 2>/dev/null)" = "4248" ]; then
    ok "Layer 2: working-tree-clean no-op phrasing recognized  → closes on PR 4248"
else
    fail "Layer 2: missed already-done with working-tree-clean phrasing (CREDIBLE-336 regression)"
fi

rm -f "$t_pos" "$t_work" "$t_nopr" "$t_bare" "$t_wtclean"

echo ""
echo "=== INFRA-3808: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
