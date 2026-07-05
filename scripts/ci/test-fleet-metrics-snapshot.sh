#!/usr/bin/env bash
# scripts/ci/test-fleet-metrics-snapshot.sh — INFRA-900
#
# 8 tests verifying fleet-metrics-snapshot.sh:
#  1. script exists and is executable
#  2. kind=fleet_metrics_snapshot registered in EVENT_REGISTRY.yaml
#  3. INFRA-900 referenced in script
#  4. emits fleet_metrics_snapshot event to ambient.jsonl
#  5. event has all required fields: ts, kind, ship_rate_24h, waste_rate_24h,
#     cycle_time_p50_h, active_gaps, p0_count
#  6. field types correct (ship_rate_24h numeric, active_gaps int, p0_count int)
#  7. --dry-run suppresses ambient write
#  8. --json outputs JSON to stdout containing all required fields

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Always resolve from script location — REPO_ROOT env may point at main checkout
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="${REPO_ROOT:-$WORKTREE_ROOT}"
SCRIPT="$WORKTREE_ROOT/scripts/ops/fleet-metrics-snapshot.sh"
MAIN_RS_LOCAL="$WORKTREE_ROOT/src/main.rs"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-900: fleet-metrics-snapshot ==="
echo

# 1. script exists and is executable
if [[ -x "$SCRIPT" ]]; then
    ok "fleet-metrics-snapshot.sh exists and is executable"
else
    fail "fleet-metrics-snapshot.sh missing or not executable at $SCRIPT"
fi

# 2. kind=fleet_metrics_snapshot registered in EVENT_REGISTRY.yaml
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q "fleet_metrics_snapshot" "$REGISTRY" 2>/dev/null; then
    ok "fleet_metrics_snapshot registered in EVENT_REGISTRY.yaml"
else
    fail "fleet_metrics_snapshot not found in EVENT_REGISTRY.yaml"
fi

# 3. INFRA-900 referenced in script
if grep -q "INFRA-900" "$SCRIPT" 2>/dev/null; then
    ok "INFRA-900 referenced in fleet-metrics-snapshot.sh"
else
    fail "INFRA-900 not referenced in fleet-metrics-snapshot.sh"
fi

# 4. main.rs has chump fleet metrics arm (always check worktree copy)
if grep -q '"metrics"' "$MAIN_RS_LOCAL" 2>/dev/null && \
   grep -q "fleet-metrics-snapshot.sh" "$MAIN_RS_LOCAL" 2>/dev/null; then
    ok "main.rs: chump fleet metrics arm wired to fleet-metrics-snapshot.sh"
else
    fail "main.rs: missing 'metrics' arm or fleet-metrics-snapshot.sh reference"
fi

# ── Functional tests with synthetic state ───────────────────────────────────
TMP="$(mktemp -d)"
# W-013: unset injected env vars so test fixtures are not hijacked
unset CHUMP_REPO CHUMP_LOCK_DIR
trap 'rm -rf "$TMP"' EXIT

FAKE_AMB="$TMP/ambient.jsonl"
FAKE_DB="$TMP/state.db"

# Build a synthetic state.db with known gap counts
sqlite3 "$FAKE_DB" "
CREATE TABLE gaps (
    id TEXT PRIMARY KEY,
    domain TEXT DEFAULT '',
    title TEXT DEFAULT '',
    description TEXT DEFAULT '',
    priority TEXT DEFAULT '',
    effort TEXT DEFAULT '',
    status TEXT DEFAULT 'open',
    acceptance_criteria TEXT DEFAULT '',
    depends_on TEXT DEFAULT '[]',
    notes TEXT DEFAULT '',
    source_doc TEXT DEFAULT '',
    created_at INTEGER DEFAULT 0,
    closed_at INTEGER,
    opened_date TEXT DEFAULT '',
    closed_date TEXT DEFAULT '',
    closed_pr INTEGER,
    skills_required TEXT DEFAULT '',
    preferred_backend TEXT DEFAULT '',
    preferred_machine TEXT DEFAULT '',
    estimated_minutes TEXT DEFAULT '',
    required_model TEXT DEFAULT '',
    shipped_in TEXT,
    outcome_id TEXT,
    evidence TEXT
);
INSERT INTO gaps VALUES ('INFRA-001','INFRA','gap1','',  'P0','s','open', '','[]','','', strftime('%s','now')-7200, NULL,'','',NULL,'','','','','',NULL,NULL,NULL);
INSERT INTO gaps VALUES ('INFRA-002','INFRA','gap2','',  'P1','xs','open','','[]','','', strftime('%s','now')-3600, NULL,'','',NULL,'','','','','',NULL,NULL,NULL);
INSERT INTO gaps VALUES ('INFRA-003','INFRA','gap3','',  'P1','m', 'open','','[]','','', strftime('%s','now')-1800, NULL,'','',NULL,'','','','','',NULL,NULL,NULL);
INSERT INTO gaps VALUES ('INFRA-004','INFRA','gap4','',  'P1','s', 'done','','[]','','', strftime('%s','now')-7200, strftime('%s','now')-600,'','',42,'','','','','',NULL,NULL,NULL);
"

# Synthetic ambient.jsonl with pr_merged and session_start events
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$FAKE_AMB" <<EOF
{"ts":"$NOW_ISO","kind":"session_start","session_id":"claim-INFRA-001-999-111"}
{"ts":"$NOW_ISO","kind":"session_start","session_id":"claim-INFRA-002-999-222"}
{"ts":"$NOW_ISO","kind":"pr_merged","gap_id":"INFRA-004","pr":42}
{"ts":"$NOW_ISO","kind":"gap_shipped","gap_id":"INFRA-004"}
EOF

# Fake chump that returns predictable waste-tally JSON
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" <<'FAKECHUMP'
#!/usr/bin/env bash
if [[ "${1:-}" == "waste-tally" ]]; then
    echo '{"waste_rate": 0.25, "total_events": 5}'
    exit 0
fi
exit 1
FAKECHUMP
chmod +x "$TMP/bin/chump"

# Prepend fake bin to PATH for tests 5-8
OLD_PATH="$PATH"
export PATH="$TMP/bin:$PATH"

# 5. emits fleet_metrics_snapshot to ambient.jsonl
CHUMP_AMBIENT_LOG="$FAKE_AMB" CHUMP_STATE_DB="$FAKE_DB" \
    REPO_ROOT="$REPO_ROOT" \
    bash "$SCRIPT" --dry-run 2>/dev/null
# With --dry-run we won't get an emit; run without to get the event
CHUMP_AMBIENT_LOG="$FAKE_AMB" CHUMP_STATE_DB="$FAKE_DB" \
    REPO_ROOT="$REPO_ROOT" \
    bash "$SCRIPT" 2>/dev/null
if grep -q "fleet_metrics_snapshot" "$FAKE_AMB" 2>/dev/null; then
    ok "emits fleet_metrics_snapshot event to ambient.jsonl"
else
    fail "no fleet_metrics_snapshot event found in ambient.jsonl"
fi

# 6. event has all required fields with correct types
EVENT="$(grep 'fleet_metrics_snapshot' "$FAKE_AMB" | tail -1)"
if [[ -n "$EVENT" ]]; then
    TYPE_OK="$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
required = ['ts','kind','ship_rate_24h','waste_rate_24h','cycle_time_p50_h','active_gaps','p0_count']
missing = [f for f in required if f not in d]
if missing: print('MISSING:' + ','.join(missing)); sys.exit(0)
assert isinstance(d['ship_rate_24h'], (int,float)), 'ship_rate_24h not numeric'
assert isinstance(d['waste_rate_24h'], (int,float)), 'waste_rate_24h not numeric'
assert isinstance(d['cycle_time_p50_h'], (int,float)), 'cycle_time_p50_h not numeric'
assert isinstance(d['active_gaps'], (int,float)), 'active_gaps not numeric'
assert isinstance(d['p0_count'], (int,float)), 'p0_count not numeric'
assert d['kind'] == 'fleet_metrics_snapshot', 'kind mismatch'
print('OK')
" "$EVENT" 2>&1 || echo "ERR")"
    if [[ "$TYPE_OK" == "OK" ]]; then
        ok "event has all required fields with correct types"
    else
        fail "event field check: $TYPE_OK"
    fi
else
    fail "no fleet_metrics_snapshot event to inspect"
fi

# 7. active_gaps and p0_count read from state.db (3 open, 1 P0)
if [[ -n "$EVENT" ]]; then
    COUNTS="$(printf '%s' "$EVENT" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
print(int(d['active_gaps']), int(d['p0_count']))
")"
    AG="$(echo "$COUNTS" | awk '{print $1}')"
    P0="$(echo "$COUNTS" | awk '{print $2}')"
    if [[ "$AG" -eq 3 && "$P0" -eq 1 ]]; then
        ok "active_gaps=3 and p0_count=1 match synthetic state.db"
    else
        fail "active_gaps=$AG p0_count=$P0 (expected 3 and 1)"
    fi
else
    fail "no event to check active_gaps/p0_count"
fi

# 8. --dry-run suppresses ambient write
DRY_AMB="$TMP/dry-ambient.jsonl"
touch "$DRY_AMB"
CHUMP_AMBIENT_LOG="$DRY_AMB" CHUMP_STATE_DB="$FAKE_DB" \
    REPO_ROOT="$REPO_ROOT" \
    bash "$SCRIPT" --dry-run 2>/dev/null
if [[ ! -s "$DRY_AMB" ]]; then
    ok "--dry-run suppresses ambient.jsonl write"
else
    fail "--dry-run still wrote to ambient.jsonl"
fi

# 9. --json outputs JSON to stdout with all required fields
JSON_OUT="$(CHUMP_AMBIENT_LOG="$TMP/json-ambient.jsonl" CHUMP_STATE_DB="$FAKE_DB" \
    REPO_ROOT="$REPO_ROOT" \
    bash "$SCRIPT" --json 2>/dev/null | grep "fleet_metrics_snapshot" | tail -1)"
if [[ -n "$JSON_OUT" ]]; then
    JSON_VALID="$(printf '%s' "$JSON_OUT" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    required=['ts','kind','ship_rate_24h','waste_rate_24h','cycle_time_p50_h','active_gaps','p0_count']
    missing=[f for f in required if f not in d]
    print('MISS:'+','.join(missing) if missing else 'OK')
except Exception as e:
    print(f'ERR:{e}')
")"
    if [[ "$JSON_VALID" == "OK" ]]; then
        ok "--json outputs valid JSON with all required fields"
    else
        fail "--json output check: $JSON_VALID"
    fi
else
    fail "--json produced no fleet_metrics_snapshot output"
fi

export PATH="$OLD_PATH"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
