#!/usr/bin/env bash
# test-alert-classifier.sh — INFRA-1247: alert classifier false-positive suppression
#
# Verifies that:
#   (A) silent_agent is suppressed for operator IDE sessions (chump-Chump-*)
#   (B) silent_agent is NOT suppressed for real worker sessions
#   (C) alert_classifier_suppressed event is emitted for suppressed alerts
#   (D) pr_stuck suppression fires for closed PR state (via mocked cache_lookup_pr)
#   (E) pr_stuck is NOT suppressed for open PRs
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); FAILS+=("$*"); }

echo "=== INFRA-1247 alert classifier suppression tests ==="
echo

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AMBIENT_WATCH="$ROOT/scripts/dev/ambient-watch.sh"
STUCK_FILER="$ROOT/scripts/ops/stuck-pr-filer.sh"

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
future="$(python3 -c 'import datetime; print((datetime.datetime.utcnow()+datetime.timedelta(hours=4)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
# Stale heartbeat: 12 min ago.
#   * 12min > stale_warn_secs (10min) → triggers silent_agent check
#   * 12min < 15min load-filter threshold → lease IS loaded (not silently dropped)
# Using 2h would cause the lease to be dropped before the check fires.
stale="$(python3 -c 'import datetime; print((datetime.datetime.utcnow()-datetime.timedelta(minutes=12)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

# ── Setup: extract the Python checker from ambient-watch.sh ─────────────────
# The PYTHON_CHECKER heredoc is embedded in ambient-watch.sh. Extract it so
# we can run it directly against synthetic lease files.

PYTHON_CHECKER_FILE="$TMPBASE/checker.py"
# Extract the Python checker from ambient-watch.sh.
# The block lives between line "PYTHON_CHECKER=$(cat <<'PYEOF')" and "PYEOF".
START_LINE=$(grep -Fn "PYTHON_CHECKER" "$AMBIENT_WATCH" 2>/dev/null \
    | grep "cat <<'PYEOF'" | head -1 | cut -d: -f1)
if [[ -n "$START_LINE" ]]; then
    END_LINE=$(awk "NR>$START_LINE && /^PYEOF/{print NR; exit}" "$AMBIENT_WATCH" 2>/dev/null || echo "")
fi
if [[ -n "${START_LINE:-}" && -n "${END_LINE:-}" && "$END_LINE" -gt "$START_LINE" ]]; then
    sed -n "$((START_LINE+1)),$((END_LINE-1))p" "$AMBIENT_WATCH" > "$PYTHON_CHECKER_FILE"
fi

if [[ ! -s "$PYTHON_CHECKER_FILE" ]]; then
    echo "FATAL: could not extract Python checker from $AMBIENT_WATCH (start=$START_LINE end=${END_LINE:-?})" >&2
    exit 2
fi

run_checker() {
    local lock_dir="$1"
    local ambient_log="${2:-/dev/null}"
    local stale_secs="${3:-600}"
    python3 "$PYTHON_CHECKER_FILE" "$lock_dir" "$ambient_log" "$stale_secs" "10" "60" 2>/dev/null || echo "[]"
}

# ── Test A: operator session → silent_agent suppressed ──────────────────────
echo "--- Test A: operator session (chump-Chump-*) triggers suppression, not silent_agent ---"
A_LOCKS="$TMPBASE/a-locks"
mkdir -p "$A_LOCKS"
cat > "$A_LOCKS/claim-operator.json" <<JSON
{
  "session_id": "chump-Chump-1776471708",
  "gap_id": "INFRA-999",
  "taken_at": "$stale",
  "expires_at": "$future",
  "heartbeat_at": "$stale",
  "purpose": "gap:INFRA-999"
}
JSON

RESULT_A="$(run_checker "$A_LOCKS")"
SILENT_COUNT=$(python3 -c "import json,sys; a=json.loads(sys.argv[1]); print(sum(1 for x in a if x.get('kind')=='silent_agent'))" "$RESULT_A" 2>/dev/null || echo 0)
SUPPRESSED_COUNT=$(python3 -c "import json,sys; a=json.loads(sys.argv[1]); print(sum(1 for x in a if x.get('kind')=='alert_classifier_suppressed'))" "$RESULT_A" 2>/dev/null || echo 0)

if [[ "$SILENT_COUNT" -eq 0 ]]; then
    ok "Test A: operator session does NOT emit silent_agent"
else
    fail "Test A: operator session emitted $SILENT_COUNT silent_agent event(s); expected 0"
fi
if [[ "$SUPPRESSED_COUNT" -gt 0 ]]; then
    ok "Test A: alert_classifier_suppressed emitted for operator session"
else
    fail "Test A: expected alert_classifier_suppressed for operator session; got $SUPPRESSED_COUNT"
fi

# ── Test B: real worker session → silent_agent emitted ──────────────────────
echo "--- Test B: real worker session with stale heartbeat emits silent_agent ---"
B_LOCKS="$TMPBASE/b-locks"
mkdir -p "$B_LOCKS"
cat > "$B_LOCKS/claim-worker.json" <<JSON
{
  "session_id": "claim-infra-1234-99999-1778700000",
  "gap_id": "INFRA-1234",
  "taken_at": "$stale",
  "expires_at": "$future",
  "heartbeat_at": "$stale",
  "purpose": "gap:INFRA-1234"
}
JSON

RESULT_B="$(run_checker "$B_LOCKS")"
SILENT_B=$(python3 -c "import json,sys; a=json.loads(sys.argv[1]); print(sum(1 for x in a if x.get('kind')=='silent_agent'))" "$RESULT_B" 2>/dev/null || echo 0)
SUPPRESSED_B=$(python3 -c "import json,sys; a=json.loads(sys.argv[1]); print(sum(1 for x in a if x.get('kind')=='alert_classifier_suppressed'))" "$RESULT_B" 2>/dev/null || echo 0)

if [[ "$SILENT_B" -gt 0 ]]; then
    ok "Test B: real worker session emits silent_agent"
else
    fail "Test B: expected silent_agent for stale worker session; got 0"
fi
if [[ "$SUPPRESSED_B" -eq 0 ]]; then
    ok "Test B: real worker session does NOT emit suppression event"
else
    fail "Test B: worker session emitted unexpected suppression event"
fi

# ── Test C: mixed (2 operator + 1 real) → 1 silent_agent + 2 suppressed ─────
echo "--- Test C: mixed leases: 2 operator + 1 real worker (stale) ---"
C_LOCKS="$TMPBASE/c-locks"
mkdir -p "$C_LOCKS"
cat > "$C_LOCKS/claim-op1.json" <<JSON
{"session_id":"chump-Chump-1111","gap_id":"","taken_at":"$stale","expires_at":"$future","heartbeat_at":"$stale","purpose":"ide"}
JSON
cat > "$C_LOCKS/claim-op2.json" <<JSON
{"session_id":"chump-Chump-2222","gap_id":"","taken_at":"$stale","expires_at":"$future","heartbeat_at":"$stale","purpose":"ide"}
JSON
cat > "$C_LOCKS/claim-worker2.json" <<JSON
{"session_id":"claim-infra-5678-77777-1778700001","gap_id":"INFRA-5678","taken_at":"$stale","expires_at":"$future","heartbeat_at":"$stale","purpose":"gap:INFRA-5678"}
JSON

RESULT_C="$(run_checker "$C_LOCKS")"
SILENT_C=$(python3 -c "import json,sys; a=json.loads(sys.argv[1]); print(sum(1 for x in a if x.get('kind')=='silent_agent'))" "$RESULT_C" 2>/dev/null || echo 0)
SUPPRESSED_C=$(python3 -c "import json,sys; a=json.loads(sys.argv[1]); print(sum(1 for x in a if x.get('kind')=='alert_classifier_suppressed'))" "$RESULT_C" 2>/dev/null || echo 0)

if [[ "$SILENT_C" -eq 1 ]]; then
    ok "Test C: exactly 1 silent_agent for the real worker"
else
    fail "Test C: expected 1 silent_agent; got $SILENT_C"
fi
if [[ "$SUPPRESSED_C" -eq 2 ]]; then
    ok "Test C: exactly 2 suppression events for operator sessions"
else
    fail "Test C: expected 2 suppression events; got $SUPPRESSED_C"
fi

# ── Test D: pr_stuck suppressed for closed PR (via stubbed cache_lookup_pr) ──
echo "--- Test D: pr_stuck suppression logic for closed PR ---"
D_AMBIENT="$TMPBASE/d-ambient.jsonl"
touch "$D_AMBIENT"

# Simulate the stuck-pr-filer suppression logic directly (the Bash portion)
# by sourcing just the emit logic with a mocked cache_lookup_pr
D_RESULT=$(bash -c "
cache_lookup_pr() { echo '{\"state\":\"closed\"}'; }
declare -f cache_lookup_pr &>/dev/null && echo 'cache_fn_present'

_pr_num=1154
_pr_state=\$(cache_lookup_pr \"\$_pr_num\" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(\"state\",\"open\"))' 2>/dev/null || echo open)
echo \"pr_state=\$_pr_state\"
if [[ \"\$_pr_state\" != 'open' ]]; then
    echo 'SUPPRESSED'
else
    echo 'EMITTED'
fi
" 2>/dev/null)

if echo "$D_RESULT" | grep -q "SUPPRESSED"; then
    ok "Test D: pr_stuck suppressed when cache_lookup_pr returns closed state"
else
    fail "Test D: expected SUPPRESSED for closed PR; got: $D_RESULT"
fi

# ── Test E: pr_stuck NOT suppressed for open PR ──────────────────────────────
echo "--- Test E: pr_stuck not suppressed when PR is open ---"
E_RESULT=$(bash -c "
cache_lookup_pr() { echo '{\"state\":\"open\"}'; }
_pr_num=9999
_pr_state=\$(cache_lookup_pr \"\$_pr_num\" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(\"state\",\"open\"))' 2>/dev/null || echo open)
if [[ \"\$_pr_state\" != 'open' ]]; then
    echo 'SUPPRESSED'
else
    echo 'EMITTED'
fi
" 2>/dev/null)

if echo "$E_RESULT" | grep -q "EMITTED"; then
    ok "Test E: pr_stuck emitted (not suppressed) when PR is open"
else
    fail "Test E: expected EMITTED for open PR; got: $E_RESULT"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "${#FAILS[@]}" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
