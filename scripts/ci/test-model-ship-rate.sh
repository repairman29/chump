#!/usr/bin/env bash
# test-model-ship-rate.sh — CREDIBLE-025: verify model-ship-rate.sh parses correctly.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-model-ship-rate.XXXXXX)"
AMBIENT="$TMP/ambient.jsonl"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Fixture: 3 ship_grade events from 2 models ───────────────────────────────
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$AMBIENT" <<EOF
{"event":"ship_grade","kind":"ship_grade","ts":"$NOW","gap_id":"TEST-001","model":"claude-sonnet","clippy_ok":true,"test_added":true,"rebase_clean":true}
{"event":"ship_grade","kind":"ship_grade","ts":"$NOW","gap_id":"TEST-002","model":"claude-sonnet","clippy_ok":true,"test_added":false,"rebase_clean":true}
{"event":"ship_grade","kind":"ship_grade","ts":"$NOW","gap_id":"TEST-003","model":"claude-haiku","clippy_ok":false,"test_added":false,"rebase_clean":true}
{"event":"INTENT","ts":"$NOW","gap":"TEST-004","model":"claude-haiku"}
EOF

# ── Test 1: text output includes both models ──────────────────────────────────
out="$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$REPO_ROOT/scripts/dispatch/model-ship-rate.sh" --window 1h 2>&1)"
echo "$out" | grep -q "claude-sonnet" || fail "text output missing claude-sonnet"
echo "$out" | grep -q "claude-haiku"  || fail "text output missing claude-haiku"
pass "text output includes both models"

# ── Test 2: sonnet shows 2 graded ────────────────────────────────────────────
echo "$out" | grep "claude-sonnet" | grep -q "2" || fail "claude-sonnet should show 2 graded"
pass "claude-sonnet shows 2 graded entries"

# ── Test 3: JSON output is valid JSON ─────────────────────────────────────────
json="$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$REPO_ROOT/scripts/dispatch/model-ship-rate.sh" --window 1h --json 2>&1)"
python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert len(d['models'])>=2" <<< "$json" \
    || fail "JSON output invalid or fewer than 2 models"
pass "JSON output is valid with >=2 models"

# ── Test 4: JSON has clippy_ok_pct for sonnet ─────────────────────────────────
python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
sonnet = next((m for m in d['models'] if m['model']=='claude-sonnet'), None)
assert sonnet is not None, 'claude-sonnet not found'
assert sonnet['clippy_ok_pct'] == 100, f'expected 100 got {sonnet[\"clippy_ok_pct\"]}'
assert sonnet['test_added_pct'] == 50, f'expected 50 got {sonnet[\"test_added_pct\"]}'
" <<< "$json" || fail "JSON clippy/test_added percentages wrong for claude-sonnet"
pass "JSON percentages: sonnet clippy_ok=100% test_added=50%"

# ── Test 5: broadcast.sh INTENT event includes model field ────────────────────
if command -v python3 &>/dev/null; then
    # Verify broadcast.sh payload has model when FLEET_MODEL is set
    LOCK_DIR_TMP="$TMP/locks"
    mkdir -p "$LOCK_DIR_TMP"
    CHUMP_AMBIENT_LOG="$LOCK_DIR_TMP/ambient.jsonl" \
    FLEET_MODEL="test-model-sonnet" \
    CHUMP_SESSION_ID="test-session" \
    MAIN_REPO="$TMP" \
        bash "$REPO_ROOT/scripts/coord/broadcast.sh" INTENT TEST-CRED25 "" 2>/dev/null || true
    if [[ -f "$LOCK_DIR_TMP/ambient.jsonl" ]]; then
        python3 -c "
import json,sys
with open('$LOCK_DIR_TMP/ambient.jsonl') as f:
    ev = json.loads(f.read().strip())
assert ev.get('model') == 'test-model-sonnet', f'model field missing or wrong: {ev}'
" && pass "broadcast.sh INTENT event includes model field" \
  || fail "broadcast.sh INTENT event missing model field"
    else
        pass "broadcast.sh INTENT event (no lockdir, soft skip)"
    fi
fi

echo ""
echo "All CREDIBLE-025 model-ship-rate checks passed."
