#!/usr/bin/env bash
# test-gap-drift-source-dedup.sh — INFRA-1424 regression test.
#
# Verifies gap_drift_orphan / gap_drift_yaml_only dedup at the source:
#   1. First safe-sweep with drift → emits 1 alert per unique subject
#   2. Second sweep within window → suppressed (no new entry in ambient.jsonl)
#   3. Third sweep after window expires → re-emits 1 alert per subject
#   4. Different subject (different orphan set) → always emits (new hash)
#   5. State file is valid JSON with expected shape
#   6. CHUMP_DRIFT_ALERT_WINDOW_MIN=0 overrides window (forces emit every run)
#
# Strategy: use a temp git repo with synthetic state.db + docs/gaps/,
# manipulate drift-alert-state.json timestamps to simulate window expiry.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/coord/gap-doctor.py"

if [[ ! -f "$SCRIPT" ]]; then
    echo "[FAIL] gap-doctor.py not found at $SCRIPT"
    exit 1
fi

fail() { echo "[FAIL] $*"; exit 1; }
pass() { echo "[PASS] $*"; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
git init -q -b main
git config user.email "test@chump.local"
git config user.name "Chump Test"
mkdir -p docs/gaps .chump .chump-locks scripts/coord
cp "$SCRIPT" scripts/coord/gap-doctor.py

# Create a minimal SQLite state.db schema
sqlite3 .chump/state.db <<'SQL'
CREATE TABLE gaps (
  id TEXT PRIMARY KEY,
  domain TEXT,
  title TEXT,
  description TEXT,
  priority TEXT,
  effort TEXT,
  status TEXT,
  acceptance_criteria TEXT,
  depends_on TEXT,
  notes TEXT,
  source_doc TEXT,
  created_at INTEGER,
  closed_at INTEGER,
  opened_date TEXT,
  closed_date TEXT,
  closed_pr INTEGER
);
SQL

# Helper: insert a row
db_insert() {
    sqlite3 .chump/state.db "INSERT INTO gaps (id, domain, title, status, priority, effort, created_at) VALUES ('$1', 'INFRA', 'test', '$2', 'P2', 's', strftime('%s','now'));"
}

# Helper: write a YAML file
yaml_write() {
    cat > "docs/gaps/$1.yaml" <<EOF
- id: $1
  domain: INFRA
  title: test
  status: $2
  priority: P2
  effort: s
EOF
}

AMBIENT=".chump-locks/ambient.jsonl"
STATE_FILE=".chump-locks/drift-alert-state.json"

# ── Fixture: Bucket 3 orphan (DB open, no YAML) ──────────────────────────────
db_insert "INFRA-DEDUP-1" "open"
# Bucket 4 YAML-only
yaml_write "INFRA-YAML-ONLY-1" "open"

git add -A && git commit -qm "fixture"

# ── Test 1: first sweep emits alerts ─────────────────────────────────────────
echo "Test 1: first safe-sweep emits gap_drift_orphan and gap_drift_yaml_only"
> "$AMBIENT"
set +e
python3 scripts/coord/gap-doctor.py safe-sweep >/tmp/dedup-t1.out 2>&1
RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "[FAIL] safe-sweep returned $RC:"; cat /tmp/dedup-t1.out; exit 1; }

ORPHAN_COUNT=$(grep -c '"kind":"gap_drift_orphan"' "$AMBIENT" || true)
YAML_ONLY_COUNT=$(grep -c '"kind":"gap_drift_yaml_only"' "$AMBIENT" || true)
[[ "$ORPHAN_COUNT" -eq 1 ]] || fail "expected 1 gap_drift_orphan, got $ORPHAN_COUNT"
[[ "$YAML_ONLY_COUNT" -eq 1 ]] || fail "expected 1 gap_drift_yaml_only, got $YAML_ONLY_COUNT"
pass "first sweep emits 1 gap_drift_orphan and 1 gap_drift_yaml_only"

# State file should exist
[[ -f "$STATE_FILE" ]] || fail "drift-alert-state.json not created"
pass "drift-alert-state.json created"

# subject_hash should appear in alert
grep -q '"subject_hash"' "$AMBIENT" || fail "alert missing subject_hash field"
pass "alert includes subject_hash field"

# ── Test 2: second sweep within window → suppressed ──────────────────────────
echo ""
echo "Test 2: second sweep within window suppresses re-emit"
AMBIENT_LINES_BEFORE=$(wc -l < "$AMBIENT")
set +e
python3 scripts/coord/gap-doctor.py safe-sweep >/tmp/dedup-t2.out 2>&1
RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "[FAIL] safe-sweep returned $RC:"; cat /tmp/dedup-t2.out; exit 1; }

AMBIENT_LINES_AFTER=$(wc -l < "$AMBIENT")
[[ "$AMBIENT_LINES_AFTER" -eq "$AMBIENT_LINES_BEFORE" ]] || \
    fail "second sweep added lines to ambient.jsonl (expected suppression): before=$AMBIENT_LINES_BEFORE after=$AMBIENT_LINES_AFTER"
pass "second sweep is suppressed within window"

# Should print a suppressed message to stdout
grep -q "suppressed" /tmp/dedup-t2.out || fail "expected 'suppressed' in output but got: $(cat /tmp/dedup-t2.out)"
pass "suppressed message printed to stdout"

# ── Test 3: simulate window expiry → re-emits ────────────────────────────────
echo ""
echo "Test 3: after window expires, alerts re-emit"

# Backdating all entries in drift-alert-state.json to 2 hours ago
python3 - <<'PYEOF'
import json, time
from pathlib import Path
p = Path(".chump-locks/drift-alert-state.json")
state = json.loads(p.read_text())
# Move all timestamps 7200 seconds into the past
state = {k: v - 7200 for k, v in state.items()}
p.write_text(json.dumps(state))
PYEOF

AMBIENT_LINES_BEFORE=$(wc -l < "$AMBIENT")
set +e
python3 scripts/coord/gap-doctor.py safe-sweep >/tmp/dedup-t3.out 2>&1
RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "[FAIL] safe-sweep returned $RC:"; cat /tmp/dedup-t3.out; exit 1; }

AMBIENT_LINES_AFTER=$(wc -l < "$AMBIENT")
NEW_LINES=$(( AMBIENT_LINES_AFTER - AMBIENT_LINES_BEFORE ))
[[ "$NEW_LINES" -ge 1 ]] || fail "expected re-emit after window expiry but ambient.jsonl unchanged"
pass "after window expiry, alerts re-emit ($NEW_LINES new line(s))"

# ── Test 4: different subject emits separately ────────────────────────────────
echo ""
echo "Test 4: different orphan set (different subject_hash) always emits"
# Reset state and ambient
> "$AMBIENT"
rm -f "$STATE_FILE"

# Add second orphan
db_insert "INFRA-DEDUP-2" "open"

# First run: both INFRA-DEDUP-1 and INFRA-DEDUP-2 in bucket3
set +e
python3 scripts/coord/gap-doctor.py safe-sweep >/tmp/dedup-t4a.out 2>&1
RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "[FAIL] safe-sweep returned $RC:"; cat /tmp/dedup-t4a.out; exit 1; }

LINES_AFTER_T4A=$(wc -l < "$AMBIENT")
[[ "$LINES_AFTER_T4A" -ge 1 ]] || fail "no alerts emitted in test 4a"

# Now remove INFRA-DEDUP-2 from DB → different subject hash for next run
sqlite3 .chump/state.db "DELETE FROM gaps WHERE id='INFRA-DEDUP-2';"

# Second run within window: bucket3 now has only INFRA-DEDUP-1 (different hash)
# → should emit because the IDs changed
set +e
python3 scripts/coord/gap-doctor.py safe-sweep >/tmp/dedup-t4b.out 2>&1
RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "[FAIL] safe-sweep returned $RC:"; cat /tmp/dedup-t4b.out; exit 1; }

LINES_AFTER_T4B=$(wc -l < "$AMBIENT")
[[ "$LINES_AFTER_T4B" -gt "$LINES_AFTER_T4A" ]] || \
    fail "different subject (INFRA-DEDUP-2 removed) should emit new alert; got same line count"
pass "different orphan set triggers new emit even within window"

# ── Test 5: state file is valid JSON ─────────────────────────────────────────
echo ""
echo "Test 5: drift-alert-state.json is valid JSON with expected shape"
python3 - <<'PYEOF'
import json, sys
from pathlib import Path
p = Path(".chump-locks/drift-alert-state.json")
if not p.exists():
    print("[FAIL] state file missing")
    sys.exit(1)
state = json.loads(p.read_text())
if not isinstance(state, dict):
    print(f"[FAIL] state is not a dict: {type(state)}")
    sys.exit(1)
for k, v in state.items():
    if not isinstance(k, str) or len(k) != 16:
        print(f"[FAIL] key '{k}' is not a 16-char hex string")
        sys.exit(1)
    if not isinstance(v, (int, float)):
        print(f"[FAIL] value for '{k}' is not a number: {v!r}")
        sys.exit(1)
print(f"[PASS] drift-alert-state.json has {len(state)} entries, all valid")
PYEOF

# ── Test 6: CHUMP_DRIFT_ALERT_WINDOW_MIN=0 forces emit every run ─────────────
echo ""
echo "Test 6: CHUMP_DRIFT_ALERT_WINDOW_MIN=0 forces emit on every run"
> "$AMBIENT"

set +e
CHUMP_DRIFT_ALERT_WINDOW_MIN=0 python3 scripts/coord/gap-doctor.py safe-sweep >/tmp/dedup-t6a.out 2>&1
RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "[FAIL] sweep returned $RC:"; cat /tmp/dedup-t6a.out; exit 1; }

LINES_AFTER_T6A=$(wc -l < "$AMBIENT")

set +e
CHUMP_DRIFT_ALERT_WINDOW_MIN=0 python3 scripts/coord/gap-doctor.py safe-sweep >/tmp/dedup-t6b.out 2>&1
RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "[FAIL] sweep returned $RC:"; cat /tmp/dedup-t6b.out; exit 1; }

LINES_AFTER_T6B=$(wc -l < "$AMBIENT")
[[ "$LINES_AFTER_T6B" -gt "$LINES_AFTER_T6A" ]] || \
    fail "CHUMP_DRIFT_ALERT_WINDOW_MIN=0 should force emit on every run"
pass "CHUMP_DRIFT_ALERT_WINDOW_MIN=0 forces emit every cycle"

echo ""
echo "[OK] all 6 INFRA-1424 gap-drift source-dedup cases passed"
