#!/usr/bin/env bash
# scripts/ci/test-fleet-metrics-snapshot.sh — INFRA-900
#
# 8 tests verifying fleet-metrics-snapshot.sh schema + field types:
#  1. script exists and is executable
#  2. INFRA-900 referenced in script
#  3. kind=fleet_metrics_snapshot registered in EVENT_REGISTRY.yaml
#  4. emits fleet_metrics_snapshot event to ambient.jsonl
#  5. event has all required fields: ts, kind, ship_rate_24h, waste_rate_24h,
#     cycle_time_p50_h, active_gaps, p0_count
#  6. ship_rate_24h is a float
#  7. waste_rate_24h is a float in [0.0, 1.0]
#  8. --no-emit suppresses ambient write; --json outputs valid JSON to stdout

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPT="$REPO_ROOT/scripts/ops/fleet-metrics-snapshot.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-900: fleet-metrics-snapshot ==="
echo

# 1. script exists and is executable
if [[ -x "$SCRIPT" ]]; then
    ok "fleet-metrics-snapshot.sh exists and is executable"
else
    fail "fleet-metrics-snapshot.sh missing or not executable"
fi

# 2. INFRA-900 referenced in script
if grep -q "INFRA-900" "$SCRIPT" 2>/dev/null; then
    ok "INFRA-900 referenced in fleet-metrics-snapshot.sh"
else
    fail "INFRA-900 not referenced in fleet-metrics-snapshot.sh"
fi

# 3. kind=fleet_metrics_snapshot registered in EVENT_REGISTRY.yaml
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q "fleet_metrics_snapshot" "$REGISTRY" 2>/dev/null; then
    ok "fleet_metrics_snapshot registered in EVENT_REGISTRY.yaml"
else
    fail "fleet_metrics_snapshot not found in EVENT_REGISTRY.yaml"
fi

# ── Functional tests with synthetic fixtures ──────────────────────────────────

TMPDIR_TEST=$(mktemp -d)
unset CHUMP_REPO CHUMP_LOCK_DIR
trap 'rm -rf "$TMPDIR_TEST"' EXIT

TODAY="$(date +%Y-%m-%d)"
FAKE_AMB="$TMPDIR_TEST/ambient.jsonl"
FAKE_DB="$TMPDIR_TEST/state.db"

# Synthetic ambient log with shipped sessions + gap_claimed events
cat > "$FAKE_AMB" <<EOF
{"ts":"${TODAY}T01:00:00Z","kind":"gap_claimed","gap_id":"INFRA-101","session_id":"s1"}
{"ts":"${TODAY}T02:00:00Z","kind":"gap_claimed","gap_id":"INFRA-102","session_id":"s2"}
{"ts":"${TODAY}T03:00:00Z","kind":"gap_claimed","gap_id":"INFRA-103","session_id":"s3"}
{"ts":"${TODAY}T04:00:00Z","kind":"session_end","gap_id":"INFRA-101","outcome":"shipped","elapsed_seconds":1800}
{"ts":"${TODAY}T05:00:00Z","kind":"session_end","gap_id":"INFRA-102","outcome":"shipped","elapsed_seconds":3600}
EOF

# Synthetic state.db with 5 open gaps (1 P0)
python3 - "$FAKE_DB" <<'PYEOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("""CREATE TABLE gaps (
    id TEXT PRIMARY KEY, domain TEXT, title TEXT, status TEXT,
    priority TEXT, effort TEXT, acceptance_criteria TEXT,
    depends_on TEXT, notes TEXT, worktree TEXT,
    created_at INTEGER, updated_at INTEGER, closed_pr INTEGER
)""")
gaps = [
    ("INFRA-101","INFRA","Gap one","open","P0","s","","","","",0,0,0),
    ("INFRA-102","INFRA","Gap two","open","P1","s","","","","",0,0,0),
    ("INFRA-103","INFRA","Gap three","open","P1","m","","","","",0,0,0),
    ("INFRA-104","INFRA","Gap four","open","P1","xs","","","","",0,0,0),
    ("INFRA-105","INFRA","Gap five","open","P2","l","","","","",0,0,0),
]
conn.executemany("INSERT INTO gaps VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", gaps)
conn.commit()
conn.close()
PYEOF

# Fake chump binary that returns predictable waste-tally JSON
mkdir -p "$TMPDIR_TEST/bin"
cat > "$TMPDIR_TEST/bin/chump" <<'FAKECHUMP'
#!/usr/bin/env bash
if [[ "${1:-}" == "waste-tally" ]]; then
    echo '{"since_seconds":86400,"total_events":3,"total_incidents":2,"total_cost_usd":0.0,"total_tokens_burned":0,"entries":[]}'
    exit 0
fi
exit 1
FAKECHUMP
chmod +x "$TMPDIR_TEST/bin/chump"

# 4. emits fleet_metrics_snapshot to ambient.jsonl
CHUMP_BIN="$TMPDIR_TEST/bin/chump" \
CHUMP_AMBIENT_LOG="$FAKE_AMB" \
CHUMP_STATE_DB="$FAKE_DB" \
    bash "$SCRIPT" >/dev/null 2>/dev/null

if grep -q '"kind":"fleet_metrics_snapshot"' "$FAKE_AMB" 2>/dev/null; then
    ok "emits fleet_metrics_snapshot event to ambient.jsonl"
else
    fail "no fleet_metrics_snapshot event found in ambient.jsonl"
fi

# Extract the emitted event
EVENT=$(grep '"kind":"fleet_metrics_snapshot"' "$FAKE_AMB" | tail -1)

# 5. event has all required fields
if [[ -n "$EVENT" ]]; then
    _missing=""
    for field in ts kind ship_rate_24h waste_rate_24h cycle_time_p50_h active_gaps p0_count; do
        if ! python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert '$field' in d, '$field missing'
" 2>/dev/null <<< "$EVENT"; then
            _missing="$_missing $field"
        fi
    done
    if [[ -z "$_missing" ]]; then
        ok "event has all required fields: ts, kind, ship_rate_24h, waste_rate_24h, cycle_time_p50_h, active_gaps, p0_count"
    else
        fail "event missing fields:$_missing"
    fi
else
    fail "no event emitted — cannot check required fields"
fi

# 6. ship_rate_24h is a float
if [[ -n "$EVENT" ]]; then
    _check=$(python3 -c "
import json
d = json.loads('''$EVENT''')
v = d['ship_rate_24h']
assert isinstance(v, (int, float)), f'expected float, got {type(v)}'
print(v)
" 2>/dev/null || echo "FAIL")
    if [[ "$_check" != "FAIL" ]]; then
        ok "ship_rate_24h is a float (got: $_check)"
    else
        fail "ship_rate_24h is not a float"
    fi
else
    fail "ship_rate_24h: no event to check"
fi

# 7. waste_rate_24h is a float in [0.0, 1.0]
if [[ -n "$EVENT" ]]; then
    _check=$(python3 -c "
import json
d = json.loads('''$EVENT''')
v = d['waste_rate_24h']
assert isinstance(v, (int, float)), f'expected float, got {type(v)}'
assert 0.0 <= float(v) <= 1.0, f'expected [0,1], got {v}'
print(v)
" 2>/dev/null || echo "FAIL")
    if [[ "$_check" != "FAIL" ]]; then
        ok "waste_rate_24h is a float in [0.0, 1.0] (got: $_check)"
    else
        fail "waste_rate_24h is not a float in [0.0, 1.0]"
    fi
else
    fail "waste_rate_24h: no event to check"
fi

# 8a. --no-emit suppresses ambient write
NO_EMIT_AMB="$TMPDIR_TEST/no-emit-ambient.jsonl"
touch "$NO_EMIT_AMB"
CHUMP_BIN="$TMPDIR_TEST/bin/chump" \
CHUMP_AMBIENT_LOG="$NO_EMIT_AMB" \
CHUMP_STATE_DB="$FAKE_DB" \
    bash "$SCRIPT" --no-emit >/dev/null 2>/dev/null
if [[ ! -s "$NO_EMIT_AMB" ]]; then
    ok "--no-emit suppresses ambient.jsonl write"
else
    fail "--no-emit still wrote to ambient.jsonl"
fi

# 8b. --json outputs valid JSON with all required fields to stdout (no ambient emit)
JSON_AMB="$TMPDIR_TEST/json-ambient.jsonl"
touch "$JSON_AMB"
JSON_OUT=$(CHUMP_BIN="$TMPDIR_TEST/bin/chump" \
    CHUMP_AMBIENT_LOG="$JSON_AMB" \
    CHUMP_STATE_DB="$FAKE_DB" \
    bash "$SCRIPT" --json 2>/dev/null || echo "")

if [[ -n "$JSON_OUT" ]]; then
    _ok=1
    for field in ts kind ship_rate_24h waste_rate_24h cycle_time_p50_h active_gaps p0_count; do
        if ! python3 -c "
import json
d = json.loads('''$JSON_OUT''')
assert '$field' in d, '$field missing'
" 2>/dev/null; then
            _ok=0
        fi
    done
    # --json implies --no-emit so ambient should still be empty
    if [[ "$_ok" -eq 1 ]] && [[ ! -s "$JSON_AMB" ]]; then
        ok "--json outputs valid JSON with all required fields (no ambient emit)"
    elif [[ "$_ok" -eq 0 ]]; then
        fail "--json output missing required fields"
    else
        fail "--json still wrote to ambient.jsonl"
    fi
else
    fail "--json produced no output"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
