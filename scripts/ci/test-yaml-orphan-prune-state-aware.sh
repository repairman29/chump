#!/usr/bin/env bash
# test-yaml-orphan-prune-state-aware.sh — EFFECTIVE-219 regression test.
#
# Verifies scripts/coord/gap-doctor.py safe-sweep --prune-orphans is
# STATE-AWARE, never DB-status-aware:
#   1. state.db row EXISTS (any status, incl. open) + YAML present
#      → daemon does NOT delete the YAML.
#   2. state.db row ABSENT + YAML present (bucket 4)
#      → daemon deletes the YAML AND emits kind=yaml_orphan_pruned with
#        gap_id, file_path, reason, daemon_name.
#
# This is the guardrail for EFFECTIVE-219: "YAML+state.db divergence means
# STATE WINS — a daemon must confirm the row is ABSENT (not just
# status:done/closed) before it may delete the mirror file."
#
# Strategy mirrors test-gap-doctor-safe-sweep.sh: temp git repo with a
# fake state.db + fake docs/gaps/ tree, run safe-sweep --prune-orphans,
# assert file-level and ambient-event outcomes.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/coord/gap-doctor.py"

if [[ ! -f "$SCRIPT" ]]; then
    echo "[FAIL] gap-doctor.py not found at $SCRIPT"
    exit 1
fi

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
git init -q -b main
git config user.email "test@chump.local"
git config user.name "Chump Test"
mkdir -p docs/gaps .chump scripts/coord
cp "$SCRIPT" scripts/coord/gap-doctor.py

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

db_insert() {
    sqlite3 .chump/state.db "INSERT INTO gaps (id, domain, title, status, priority, effort, created_at) VALUES ('$1', 'EFFECTIVE', 'test', '$2', 'P2', 's', strftime('%s','now'));"
}

yaml_write() {
    cat > "docs/gaps/$1.yaml" <<EOF
- id: $1
  domain: EFFECTIVE
  title: test
  status: $2
  priority: P2
  effort: s
EOF
}

# Case 1: state.db row EXISTS and is open, YAML present too — mimics a gap
# freshly reserved (row present) whose YAML mirror is a leftover/pre-existing
# file. The daemon must never delete this.
db_insert "EFFECTIVE-P1" "open"
yaml_write "EFFECTIVE-P1" "open"

# Case 2: state.db row ABSENT, YAML present — the genuinely-orphaned case.
yaml_write "EFFECTIVE-P2" "open"

git add -A && git commit -qm "fixture"

AMBIENT=".chump-locks/ambient.jsonl"

echo "Test 1: state.db row present -> YAML is NOT deleted"
set +e
python3 scripts/coord/gap-doctor.py safe-sweep --prune-orphans >/tmp/sweep-prune.out 2>&1
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
    echo "[FAIL] safe-sweep --prune-orphans returned non-zero ($RC)"
    cat /tmp/sweep-prune.out
    exit 1
fi
[[ -f docs/gaps/EFFECTIVE-P1.yaml ]] || { echo "[FAIL] EFFECTIVE-P1.yaml was deleted despite a live state.db row"; cat /tmp/sweep-prune.out; exit 1; }
echo "[PASS] EFFECTIVE-P1.yaml preserved (state.db row present)"

echo ""
echo "Test 2: state.db row absent -> YAML IS deleted with audit emit"
[[ ! -f docs/gaps/EFFECTIVE-P2.yaml ]] || { echo "[FAIL] EFFECTIVE-P2.yaml still present after prune"; cat /tmp/sweep-prune.out; exit 1; }
echo "[PASS] EFFECTIVE-P2.yaml deleted (no state.db row)"

[[ -f "$AMBIENT" ]] || { echo "[FAIL] ambient.jsonl not created at $AMBIENT"; exit 1; }
PRUNE_EVT=$(grep '"kind":"yaml_orphan_pruned"' "$AMBIENT" | grep "EFFECTIVE-P2" || true)
[[ -n "$PRUNE_EVT" ]] || { echo "[FAIL] no yaml_orphan_pruned event for EFFECTIVE-P2 in ambient.jsonl"; cat "$AMBIENT"; exit 1; }
echo "$PRUNE_EVT" | grep -q '"gap_id":"EFFECTIVE-P2"' || { echo "[FAIL] event missing gap_id"; exit 1; }
echo "$PRUNE_EVT" | grep -q '"daemon_name":"gap-doctor-safe-sweep"' || { echo "[FAIL] event missing daemon_name"; exit 1; }
echo "$PRUNE_EVT" | grep -q '"reason":' || { echo "[FAIL] event missing reason"; exit 1; }
echo "$PRUNE_EVT" | grep -q '"file_path":' || { echo "[FAIL] event missing file_path"; exit 1; }
echo "[PASS] yaml_orphan_pruned event carries gap_id, file_path, reason, daemon_name"

NO_PRUNE_EVT=$(grep '"kind":"yaml_orphan_pruned"' "$AMBIENT" | grep "EFFECTIVE-P1" || true)
[[ -z "$NO_PRUNE_EVT" ]] || { echo "[FAIL] unexpected prune event for EFFECTIVE-P1 (state.db row was present)"; exit 1; }
echo "[PASS] no prune event for EFFECTIVE-P1 (state.db row was present)"

echo ""
echo "Test 3: default safe-sweep (no --prune-orphans) never deletes bucket 4"
rm -f "$AMBIENT"
db_insert "EFFECTIVE-P3" "open"
yaml_write "EFFECTIVE-P3" "open"
yaml_write "EFFECTIVE-P4" "open"  # orphan, no DB row
python3 scripts/coord/gap-doctor.py safe-sweep >/tmp/sweep-default.out 2>&1
[[ -f docs/gaps/EFFECTIVE-P4.yaml ]] || { echo "[FAIL] default safe-sweep deleted a YAML without --prune-orphans"; cat /tmp/sweep-default.out; exit 1; }
echo "[PASS] default safe-sweep (no --prune-orphans) leaves bucket-4 files in place"

echo ""
echo "[OK] all EFFECTIVE-219 yaml-orphan-prune state-aware cases passed"
