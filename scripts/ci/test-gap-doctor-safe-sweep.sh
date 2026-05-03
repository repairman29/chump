#!/usr/bin/env bash
# test-gap-doctor-safe-sweep.sh — INFRA-308 regression test.
#
# Verifies scripts/coord/gap-doctor.py safe-sweep:
#   1. Dry-run never mutates state.db or YAMLs
#   2. Real run auto-fixes Bucket 1 (DB done / YAML open) by regen YAML
#   3. Real run auto-fixes Bucket 2 (DB open / YAML done) by syncing DB
#   4. Bucket 3 (DB-only orphans) emits ALERT to ambient.jsonl
#   5. Bucket 4 (YAML-only) emits ALERT to ambient.jsonl
#
# Strategy: create a temp git repo with a fake state.db + fake docs/gaps/
# tree containing each bucket case, run safe-sweep, assert outcomes.
# Avoids touching the real repo's state.db.

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

# Create a minimal SQLite state.db schema mirroring gap_store.rs.
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

# Bucket 1 (DB done / YAML open): create both, DB says done, YAML says open
db_insert "INFRA-B1" "done"
yaml_write "INFRA-B1" "open"

# Bucket 2 (DB open / YAML done): create both, DB says open, YAML says done
db_insert "INFRA-B2" "open"
yaml_write "INFRA-B2" "done"

# Bucket 3 (DB-only): row in DB, NO YAML file
db_insert "INFRA-B3" "open"

# Bucket 4 (YAML-only): YAML file, NO DB row
yaml_write "INFRA-B4" "open"

git add -A && git commit -qm "fixture"

# ── Test 1: dry-run does not mutate ──────────────────────────────────────────
echo "Test 1: --dry-run leaves state untouched"
DB_BEFORE=$(sqlite3 .chump/state.db "SELECT id, status FROM gaps ORDER BY id;")
YAML_BEFORE=$(cat docs/gaps/*.yaml)
python3 scripts/coord/gap-doctor.py safe-sweep --dry-run >/tmp/sweep-dry.out 2>&1
DB_AFTER=$(sqlite3 .chump/state.db "SELECT id, status FROM gaps ORDER BY id;")
YAML_AFTER=$(cat docs/gaps/*.yaml)
[[ "$DB_BEFORE" == "$DB_AFTER" ]] || { echo "[FAIL] dry-run mutated state.db"; exit 1; }
[[ "$YAML_BEFORE" == "$YAML_AFTER" ]] || { echo "[FAIL] dry-run mutated YAML"; exit 1; }
echo "[PASS] --dry-run is read-only"

# ── Test 2: real safe-sweep auto-fixes Bucket 1 + 2 ──────────────────────────
echo ""
echo "Test 2: real safe-sweep auto-fixes Bucket 1 and Bucket 2"
# Capture but surface the script's stderr/stdout if the script itself exits
# non-zero — otherwise CI failures look like silent exit-1 with no clue why
# (spent ~2h diagnosing this before catching the FileNotFoundError on the
# `chump` binary subprocess invocation in cmd_sync_from_yaml — INFRA-308 fix).
if ! python3 scripts/coord/gap-doctor.py safe-sweep >/tmp/sweep-real.out 2>&1; then
    echo "[FAIL] safe-sweep exited non-zero — output below:"
    cat /tmp/sweep-real.out
    exit 1
fi

# Bucket 1: YAML should now say done (regenerated from DB)
B1_YAML=$(grep "^  status:" docs/gaps/INFRA-B1.yaml | awk '{print $2}')
[[ "$B1_YAML" == "done" ]] || { echo "[FAIL] Bucket 1: YAML status=$B1_YAML expected done"; cat /tmp/sweep-real.out; exit 1; }
echo "[PASS] Bucket 1: YAML synced from DB (now done)"

# Bucket 2: DB should now say done (synced from YAML)
B2_DB=$(sqlite3 .chump/state.db "SELECT status FROM gaps WHERE id = 'INFRA-B2';")
[[ "$B2_DB" == "done" ]] || { echo "[FAIL] Bucket 2: DB status=$B2_DB expected done"; cat /tmp/sweep-real.out; exit 1; }
echo "[PASS] Bucket 2: DB synced from YAML (now done)"

# ── Test 3: Bucket 3 + 4 emit ALERT events to ambient.jsonl ──────────────────
echo ""
echo "Test 3: Bucket 3 + 4 emit ALERT events to ambient.jsonl"
AMBIENT=".chump-locks/ambient.jsonl"
[[ -f "$AMBIENT" ]] || { echo "[FAIL] ambient.jsonl not created at $AMBIENT"; exit 1; }
ORPHAN_ALERT=$(grep '"kind":"gap_drift_orphan"' "$AMBIENT" | head -1 || true)
YAML_ONLY_ALERT=$(grep '"kind":"gap_drift_yaml_only"' "$AMBIENT" | head -1 || true)
[[ -n "$ORPHAN_ALERT" ]] || { echo "[FAIL] no gap_drift_orphan ALERT in ambient.jsonl"; exit 1; }
[[ -n "$YAML_ONLY_ALERT" ]] || { echo "[FAIL] no gap_drift_yaml_only ALERT in ambient.jsonl"; exit 1; }
echo "$ORPHAN_ALERT" | grep -q "INFRA-B3" || { echo "[FAIL] orphan ALERT missing INFRA-B3"; exit 1; }
echo "$YAML_ONLY_ALERT" | grep -q "INFRA-B4" || { echo "[FAIL] yaml-only ALERT missing INFRA-B4"; exit 1; }
echo "[PASS] gap_drift_orphan ALERT names INFRA-B3"
echo "[PASS] gap_drift_yaml_only ALERT names INFRA-B4"

# ── Test 4: idempotent — second run finds 0 of each (Bucket 1+2 fixed) ─────
echo ""
echo "Test 4: second run is idempotent (Bucket 1 + 2 stay fixed)"
python3 scripts/coord/gap-doctor.py safe-sweep >/tmp/sweep-2nd.out 2>&1
B1_SECOND=$(grep "Bucket 1" /tmp/sweep-2nd.out | grep -oE '[0-9]+ →' | grep -oE '[0-9]+')
B2_SECOND=$(grep "Bucket 2" /tmp/sweep-2nd.out | grep -oE '[0-9]+ →' | grep -oE '[0-9]+')
[[ "$B1_SECOND" == "0" ]] || { echo "[FAIL] Bucket 1 still has $B1_SECOND drifts after first sweep"; exit 1; }
[[ "$B2_SECOND" == "0" ]] || { echo "[FAIL] Bucket 2 still has $B2_SECOND drifts after first sweep"; exit 1; }
echo "[PASS] safe-sweep is idempotent (Bucket 1+2 stay 0)"

echo ""
echo "[OK] all 4 INFRA-308 safe-sweep cases passed"
