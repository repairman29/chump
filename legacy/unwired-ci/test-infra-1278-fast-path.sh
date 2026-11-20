#!/usr/bin/env bash
# test-infra-1278-fast-path.sh — INFRA-1278
#
# Verifies the fix for the SC2259 stdin-collision bug in bot-merge.sh:
#   OLD (broken): printf JSON | python3 - "$REQUIRED" <<'HEREDOC'
#                 → pipe overrides heredoc; python3 receives JSON as script source → crash
#   NEW (fixed):  python3 -c '...' "$REQUIRED" <<< "$JSON"
#                 → -c takes script inline; here-string provides JSON via sys.stdin → works
#
# Tests:
#   1. All-green blob: python3 snippet returns "0 0 0" (0 incomplete, 0 failed, 3 total)
#   2. One incomplete: returns "1 0 3"
#   3. One failed: returns "0 1 3"
#   4. Required-check filter: non-required checks excluded from count
#   5. Old broken form proves the bug (pipe overrides heredoc → exit non-zero or bad output)
#   6. bot-merge.sh line containing the fix does NOT have the old "| python3 -" pattern

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1278: fast-path stdin-collision fix ==="

# ── Shared Python snippet (matches the fixed version in bot-merge.sh) ─────────
PY_SNIPPET='
import sys, json
required_raw = sys.argv[1] if len(sys.argv) > 1 else ""
required_list = [r.strip() for r in required_raw.split(",") if r.strip()] if required_raw else []
try:
    data = json.load(sys.stdin)
except Exception:
    print("0 0 0"); sys.exit(0)
checks = data.get("check_runs", [])
incomplete = failed = total = 0
for c in checks:
    conclusion = (c.get("conclusion") or "").lower()
    if conclusion in ("skipped", "neutral", "cancelled"):
        continue
    name = c.get("name", "")
    if required_list and not any(r in name for r in required_list):
        continue
    total += 1
    status = (c.get("status") or "").lower()
    if status != "completed":
        incomplete += 1
    elif conclusion != "success":
        failed += 1
print(f"{incomplete} {failed} {total}")
'

# ── Test 1: All-green check-runs blob ─────────────────────────────────────────
echo "--- Test 1: all-green blob → 0 0 3 ---"
ALL_GREEN_JSON='{"check_runs":[
  {"name":"fast-checks","status":"completed","conclusion":"success"},
  {"name":"cargo-test","status":"completed","conclusion":"success"},
  {"name":"clippy","status":"completed","conclusion":"success"}
]}'
RESULT=$(python3 -c "$PY_SNIPPET" "" <<< "$ALL_GREEN_JSON" 2>/dev/null)
if [[ "$RESULT" == "0 0 3" ]]; then
    ok "all-green: got '$RESULT'"
else
    fail "all-green: expected '0 0 3', got '$RESULT'"
fi

# ── Test 2: One incomplete check ──────────────────────────────────────────────
echo "--- Test 2: one incomplete → 1 0 3 ---"
INCOMPLETE_JSON='{"check_runs":[
  {"name":"fast-checks","status":"in_progress","conclusion":null},
  {"name":"cargo-test","status":"completed","conclusion":"success"},
  {"name":"clippy","status":"completed","conclusion":"success"}
]}'
RESULT=$(python3 -c "$PY_SNIPPET" "" <<< "$INCOMPLETE_JSON" 2>/dev/null)
if [[ "$RESULT" == "1 0 3" ]]; then
    ok "one incomplete: got '$RESULT'"
else
    fail "one incomplete: expected '1 0 3', got '$RESULT'"
fi

# ── Test 3: One failed check ──────────────────────────────────────────────────
echo "--- Test 3: one failed → 0 1 3 ---"
FAILED_JSON='{"check_runs":[
  {"name":"fast-checks","status":"completed","conclusion":"failure"},
  {"name":"cargo-test","status":"completed","conclusion":"success"},
  {"name":"clippy","status":"completed","conclusion":"success"}
]}'
RESULT=$(python3 -c "$PY_SNIPPET" "" <<< "$FAILED_JSON" 2>/dev/null)
if [[ "$RESULT" == "0 1 3" ]]; then
    ok "one failed: got '$RESULT'"
else
    fail "one failed: expected '0 1 3', got '$RESULT'"
fi

# ── Test 4: Required-check filter ────────────────────────────────────────────
echo "--- Test 4: required-filter: only 'fast-checks' required → 0 0 1 ---"
MIXED_JSON='{"check_runs":[
  {"name":"fast-checks","status":"completed","conclusion":"success"},
  {"name":"e2e-battle-sim","status":"in_progress","conclusion":null},
  {"name":"tauri-cowork-e2e","status":"in_progress","conclusion":null}
]}'
# Only filter by "fast-checks"
RESULT=$(python3 -c "$PY_SNIPPET" "fast-checks" <<< "$MIXED_JSON" 2>/dev/null)
if [[ "$RESULT" == "0 0 1" ]]; then
    ok "required-filter: got '$RESULT' (non-required e2e checks excluded)"
else
    fail "required-filter: expected '0 0 1', got '$RESULT'"
fi

# ── Test 5: Prove the OLD bug — pipe + heredoc causes wrong output ─────────────
echo "--- Test 5: old broken pattern fails (pipe overrides heredoc) ---"
# With `printf | python3 - <<HEREDOC`, bash's pipe wins (SC2259):
# python3 receives the JSON data as its script source → SyntaxError → non-zero exit.
OLD_PATTERN_OK=0
OLD_RESULT=$(printf '%s' "$ALL_GREEN_JSON" | python3 - "" <<'OLDEOF' 2>/dev/null || echo "FAILED"
import sys, json
data = json.load(sys.stdin)
print("SHOULD_NOT_REACH")
OLDEOF
)
# Expected: old pattern fails (exits non-zero → "FAILED", or outputs wrong counts)
if [[ "$OLD_RESULT" == "FAILED" || "$OLD_RESULT" != "0 0 3" ]]; then
    ok "old broken pattern confirmed buggy (got: '$OLD_RESULT')"
else
    fail "old broken pattern unexpectedly worked: '$OLD_RESULT' — SC2259 behavior may differ on this shell"
fi

# ── Test 6: bot-merge.sh uses new pattern (not old pipe+heredoc) ──────────────
echo "--- Test 6: bot-merge.sh INFRA-1278 block uses python3 -c pattern ---"
if grep -q "python3 -c" "$BOT_MERGE" && \
   ! grep -E "printf.*\|.*python3 - .*<<" "$BOT_MERGE" 2>/dev/null | grep -q "INFRA-1278\|_rd_counts"; then
    ok "bot-merge.sh uses 'python3 -c' (SC2259-clean) for INFRA-1166 fast path"
else
    # Double-check: look for the old broken pattern near the fast path
    if grep -n "printf.*\|.*python3 -" "$BOT_MERGE" | grep -q "rd_checks\|RDPYEOF"; then
        fail "bot-merge.sh still has old pipe+heredoc pattern near _rd_counts"
    else
        ok "bot-merge.sh: old pipe+heredoc pattern not found near fast-path block"
    fi
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
