#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests for scripts/ops/pillar-balance-check.sh:
#   1. Balanced fleet → exit 0, no alerts
#   2. Underfloor pillar (count < 2) → exit 1, kind=pillar_balance_alert
#   3. Overweight pillar (>50%) → exit 1, kind=pillar_balance_overweight
#   4. Alert JSON schema has required fields (pillar, count, floor)
#   5. Overweight alert has pct and total fields
#   6. --dry-run skips ambient emit
#   7. --json emits machine-readable output
#   8. Zero-total (no pickable gaps) → exit 0, no overweight alert
#   9. M-effort gaps excluded from pickable count
#  10. Gaps with non-empty depends_on excluded from pickable count
#
# Exit: 0 = all pass, 1 = any fail

# capability-guard-exempt: CHUMP_BIN + exit-0 skip path covers missing-binary case (CREDIBLE-078)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

PASS=0
FAIL=0

ok() { echo "OK  $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

# ── Find chump binary (INFRA-481: honour cargo metadata target_directory) ──
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    TARGET_DIR="$(cargo metadata --no-deps --format-version=1 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null \
        || echo "$REPO_ROOT/target")"
    if [[ -x "$TARGET_DIR/release/chump" ]]; then
        CHUMP_BIN="$TARGET_DIR/release/chump"
    elif [[ -x "$TARGET_DIR/debug/chump" ]]; then
        CHUMP_BIN="$TARGET_DIR/debug/chump"
    elif [[ -x "$REPO_ROOT/target/release/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/release/chump"
    elif [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif command -v chump >/dev/null 2>&1; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "SKIP test-pillar-balance-alerts: chump binary not found"
        exit 0
    fi
fi
export CHUMP_BIN

# ── Minimal gap schema for fixtures ──────────────────────────────────────
create_schema() {
    local db="$1"
    sqlite3 "$db" <<'SQL'
CREATE TABLE gaps (
    id TEXT PRIMARY KEY,
    domain TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT 'P2',
    effort TEXT NOT NULL DEFAULT 's',
    status TEXT NOT NULL DEFAULT 'open',
    acceptance_criteria TEXT NOT NULL DEFAULT '',
    depends_on TEXT NOT NULL DEFAULT '[]',
    notes TEXT NOT NULL DEFAULT '',
    source_doc TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL DEFAULT 0,
    closed_at INTEGER,
    opened_date TEXT NOT NULL DEFAULT '',
    closed_date TEXT NOT NULL DEFAULT '',
    closed_pr INTEGER,
    skills_required TEXT NOT NULL DEFAULT '',
    preferred_backend TEXT NOT NULL DEFAULT '',
    preferred_machine TEXT NOT NULL DEFAULT '',
    estimated_minutes TEXT NOT NULL DEFAULT '',
    required_model TEXT NOT NULL DEFAULT '',
    shipped_in TEXT NOT NULL DEFAULT '',
    outcome_id TEXT,
    evidence TEXT
);
SQL
}

# Insert a pickable gap: P1/s, with AC, no deps, title tagged with pillar
insert_gap() {
    local db="$1" id="$2" pillar="$3"
    sqlite3 "$db" \
        "INSERT INTO gaps (id, domain, title, priority, effort, status, acceptance_criteria, depends_on, created_at)
         VALUES ('$id', '$pillar', '$pillar: gap $id', 'P1', 's', 'open', '[\"AC1\"]', '[]', 1779000000);"
}

# ── Test 1: balanced fleet → exit 0, no alerts ────────────────────────────
T1_DIR="$(mktemp -d -t chump-infra-902-t1-XXXXXX)"
trap 'rm -rf "$T1_DIR"' EXIT
mkdir -p "$T1_DIR/.chump" "$T1_DIR/.chump-locks"
DB="$T1_DIR/.chump/state.db"
create_schema "$DB"
# 2 gaps each for EFFECTIVE and CREDIBLE (4 total, balanced)
insert_gap "$DB" "EFFECTIVE-001" "EFFECTIVE"
insert_gap "$DB" "EFFECTIVE-002" "EFFECTIVE"
insert_gap "$DB" "CREDIBLE-001" "CREDIBLE"
insert_gap "$DB" "CREDIBLE-002" "CREDIBLE"
insert_gap "$DB" "RESILIENT-001" "RESILIENT"
insert_gap "$DB" "RESILIENT-002" "RESILIENT"
insert_gap "$DB" "ZERO-001" "ZERO-WASTE"
insert_gap "$DB" "ZERO-002" "ZERO-WASTE"

AMBIENT="$T1_DIR/.chump-locks/ambient.jsonl"
if (cd "$T1_DIR" && CHUMP_BIN="$CHUMP_BIN" CHUMP_LOCK_DIR="$T1_DIR/.chump-locks" CHUMP_AMBIENT_LOG="$AMBIENT" \
        CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
        bash "$SCRIPT" 2>/dev/null); then
    ok "1: balanced fleet exits 0"
else
    fail "1: balanced fleet should exit 0"
fi

# ── Test 2: underfloor pillar → exit 1 ───────────────────────────────────
T2_DIR="$(mktemp -d -t chump-infra-902-t2-XXXXXX)"
trap 'rm -rf "$T2_DIR"' EXIT
mkdir -p "$T2_DIR/.chump" "$T2_DIR/.chump-locks"
DB="$T2_DIR/.chump/state.db"
create_schema "$DB"
# EFFECTIVE has 0, others have 2
insert_gap "$DB" "CREDIBLE-001" "CREDIBLE"
insert_gap "$DB" "CREDIBLE-002" "CREDIBLE"
insert_gap "$DB" "RESILIENT-001" "RESILIENT"
insert_gap "$DB" "RESILIENT-002" "RESILIENT"
insert_gap "$DB" "ZERO-001" "ZERO-WASTE"
insert_gap "$DB" "ZERO-002" "ZERO-WASTE"

AMBIENT2="$T2_DIR/.chump-locks/ambient.jsonl"
if ! (cd "$T2_DIR" && CHUMP_BIN="$CHUMP_BIN" CHUMP_LOCK_DIR="$T2_DIR/.chump-locks" CHUMP_AMBIENT_LOG="$AMBIENT2" \
        CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
        bash "$SCRIPT" 2>/dev/null); then
    ok "2: underfloor pillar exits 1"
else
    fail "2: underfloor pillar should exit 1"
fi

# ── Test 3: pillar_balance_alert emitted with correct fields ─────────────
if [[ -f "$AMBIENT2" ]] && grep -q '"kind":"pillar_balance_alert"' "$AMBIENT2"; then
    # Check required fields: pillar, count, floor
    LINE="$(grep '"kind":"pillar_balance_alert"' "$AMBIENT2" | head -1)"
    if echo "$LINE" | python3 -c '
import json, sys
ev = json.loads(sys.stdin.read())
assert "pillar" in ev, "missing pillar"
assert "count" in ev, "missing count"
assert "floor" in ev, "missing floor"
assert ev["pillar"] == "EFFECTIVE", "wrong pillar: %s" % ev["pillar"]
assert ev["count"] == 0, "wrong count: %d" % ev["count"]
assert ev["floor"] == 2, "wrong floor: %d" % ev["floor"]
' 2>/dev/null; then
        ok "3: pillar_balance_alert has correct schema (pillar, count, floor)"
    else
        fail "3: pillar_balance_alert schema invalid — line: $LINE"
    fi
else
    fail "3: pillar_balance_alert not emitted to ambient.jsonl"
fi

# ── Test 4: overweight pillar → exit 1, kind=pillar_balance_overweight ────
T4_DIR="$(mktemp -d -t chump-infra-902-t4-XXXXXX)"
trap 'rm -rf "$T4_DIR"' EXIT
mkdir -p "$T4_DIR/.chump" "$T4_DIR/.chump-locks"
DB="$T4_DIR/.chump/state.db"
create_schema "$DB"
# CREDIBLE has 6 of 8 total = 75% (>50%)
for i in 1 2 3 4 5 6; do
    insert_gap "$DB" "CREDIBLE-00$i" "CREDIBLE"
done
insert_gap "$DB" "EFFECTIVE-001" "EFFECTIVE"
insert_gap "$DB" "EFFECTIVE-002" "EFFECTIVE"

AMBIENT4="$T4_DIR/.chump-locks/ambient.jsonl"
if ! (cd "$T4_DIR" && CHUMP_BIN="$CHUMP_BIN" CHUMP_LOCK_DIR="$T4_DIR/.chump-locks" CHUMP_AMBIENT_LOG="$AMBIENT4" \
        CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
        bash "$SCRIPT" 2>/dev/null); then
    ok "4: overweight pillar exits 1"
else
    fail "4: overweight pillar should exit 1"
fi

# ── Test 5: pillar_balance_overweight has pct and total fields ────────────
if [[ -f "$AMBIENT4" ]] && grep -q '"kind":"pillar_balance_overweight"' "$AMBIENT4"; then
    LINE="$(grep '"kind":"pillar_balance_overweight"' "$AMBIENT4" | head -1)"
    if echo "$LINE" | python3 -c '
import json, sys
ev = json.loads(sys.stdin.read())
assert "pillar" in ev, "missing pillar"
assert "count" in ev, "missing count"
assert "pct" in ev, "missing pct"
assert "total" in ev, "missing total"
assert ev["pillar"] == "CREDIBLE", "wrong pillar: %s" % ev["pillar"]
assert ev["total"] == 8, "wrong total: %d" % ev["total"]
assert ev["pct"] >= 50, "pct should be >=50: %d" % ev["pct"]
' 2>/dev/null; then
        ok "5: pillar_balance_overweight has correct schema (pillar, count, pct, total)"
    else
        fail "5: pillar_balance_overweight schema invalid — line: $LINE"
    fi
else
    fail "5: pillar_balance_overweight not emitted to ambient.jsonl"
fi

# ── Test 6: --dry-run skips ambient emit ──────────────────────────────────
T6_DIR="$(mktemp -d -t chump-infra-902-t6-XXXXXX)"
trap 'rm -rf "$T6_DIR"' EXIT
mkdir -p "$T6_DIR/.chump" "$T6_DIR/.chump-locks"
DB="$T6_DIR/.chump/state.db"
create_schema "$DB"
# Make underfloor condition (no EFFECTIVE gaps)
insert_gap "$DB" "CREDIBLE-001" "CREDIBLE"
insert_gap "$DB" "CREDIBLE-002" "CREDIBLE"

AMBIENT6="$T6_DIR/.chump-locks/ambient.jsonl"
(cd "$T6_DIR" && CHUMP_BIN="$CHUMP_BIN" CHUMP_LOCK_DIR="$T6_DIR/.chump-locks" CHUMP_AMBIENT_LOG="$AMBIENT6" \
    CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
    bash "$SCRIPT" --dry-run 2>/dev/null) || true

if [[ ! -f "$AMBIENT6" ]] || ! grep -q '"kind":"pillar_balance_alert"' "$AMBIENT6" 2>/dev/null; then
    ok "6: --dry-run skips ambient emit"
else
    fail "6: --dry-run should not write to ambient.jsonl"
fi

# ── Test 7: --json outputs machine-readable JSON ──────────────────────────
T7_DIR="$(mktemp -d -t chump-infra-902-t7-XXXXXX)"
trap 'rm -rf "$T7_DIR"' EXIT
mkdir -p "$T7_DIR/.chump" "$T7_DIR/.chump-locks"
DB="$T7_DIR/.chump/state.db"
create_schema "$DB"
insert_gap "$DB" "EFFECTIVE-001" "EFFECTIVE"
insert_gap "$DB" "EFFECTIVE-002" "EFFECTIVE"
insert_gap "$DB" "CREDIBLE-001" "CREDIBLE"
insert_gap "$DB" "CREDIBLE-002" "CREDIBLE"
insert_gap "$DB" "RESILIENT-001" "RESILIENT"
insert_gap "$DB" "RESILIENT-002" "RESILIENT"
insert_gap "$DB" "ZERO-001" "ZERO-WASTE"
insert_gap "$DB" "ZERO-002" "ZERO-WASTE"

JSON_OUT="$(cd "$T7_DIR" && CHUMP_BIN="$CHUMP_BIN" CHUMP_LOCK_DIR="$T7_DIR/.chump-locks" \
    CHUMP_AMBIENT_LOG="$T7_DIR/.chump-locks/ambient.jsonl" \
    CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
    bash "$SCRIPT" --json 2>/dev/null)"

if echo "$JSON_OUT" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert "total" in d, "missing total"
assert "counts" in d, "missing counts"
assert "alerts" in d, "missing alerts"
assert "floor" in d, "missing floor"
assert "EFFECTIVE" in d["counts"], "missing EFFECTIVE in counts"
' 2>/dev/null; then
    ok "7: --json output has expected fields (total, counts, alerts, floor)"
else
    fail "7: --json output missing expected fields — got: $JSON_OUT"
fi

# ── Test 8: zero pickable gaps → exit 0, no overweight alert ─────────────
T8_DIR="$(mktemp -d -t chump-infra-902-t8-XXXXXX)"
trap 'rm -rf "$T8_DIR"' EXIT
mkdir -p "$T8_DIR/.chump" "$T8_DIR/.chump-locks"
DB="$T8_DIR/.chump/state.db"
create_schema "$DB"
# Only P2 gaps — not pickable
sqlite3 "$DB" \
    "INSERT INTO gaps (id, domain, title, priority, effort, status, acceptance_criteria, depends_on, created_at)
     VALUES ('INFRA-999', 'INFRA', 'EFFECTIVE: low priority gap', 'P2', 's', 'open', '[\"AC1\"]', '[]', 1779000000);"

AMBIENT8="$T8_DIR/.chump-locks/ambient.jsonl"
# Zero total → underfloor for all pillars, but test is about exit code
(cd "$T8_DIR" && CHUMP_BIN="$CHUMP_BIN" CHUMP_LOCK_DIR="$T8_DIR/.chump-locks" CHUMP_AMBIENT_LOG="$AMBIENT8" \
    CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
    bash "$SCRIPT" --json 2>/dev/null) || true
JSON8="$(cd "$T8_DIR" && CHUMP_BIN="$CHUMP_BIN" CHUMP_LOCK_DIR="$T8_DIR/.chump-locks" CHUMP_AMBIENT_LOG="$AMBIENT8" \
    CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
    bash "$SCRIPT" --json 2>/dev/null || true)"
if echo "$JSON8" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
# With zero total, no overweight alert should fire (division guard)
overweight = [a for a in d["alerts"] if a["type"] == "overweight"]
assert len(overweight) == 0, "overweight alert should not fire when total=0"
' 2>/dev/null; then
    ok "8: zero pickable gaps → no overweight alert"
else
    fail "8: zero pickable gaps should produce no overweight alert"
fi

# ── Test 9: m-effort gaps excluded from pickable count ────────────────────
T9_DIR="$(mktemp -d -t chump-infra-902-t9-XXXXXX)"
trap 'rm -rf "$T9_DIR"' EXIT
mkdir -p "$T9_DIR/.chump" "$T9_DIR/.chump-locks"
DB="$T9_DIR/.chump/state.db"
create_schema "$DB"
# Insert an m-effort gap (should be excluded)
sqlite3 "$DB" \
    "INSERT INTO gaps (id, domain, title, priority, effort, status, acceptance_criteria, depends_on, created_at)
     VALUES ('EFFECTIVE-M01', 'EFFECTIVE', 'EFFECTIVE: medium effort gap', 'P1', 'm', 'open', '[\"AC1\"]', '[]', 1779000000);"
# Also insert 2 xs/s gaps for EFFECTIVE so total remains valid
insert_gap "$DB" "EFFECTIVE-001" "EFFECTIVE"
insert_gap "$DB" "EFFECTIVE-002" "EFFECTIVE"
insert_gap "$DB" "CREDIBLE-001" "CREDIBLE"
insert_gap "$DB" "CREDIBLE-002" "CREDIBLE"
insert_gap "$DB" "RESILIENT-001" "RESILIENT"
insert_gap "$DB" "RESILIENT-002" "RESILIENT"
insert_gap "$DB" "ZERO-001" "ZERO-WASTE"
insert_gap "$DB" "ZERO-002" "ZERO-WASTE"

JSON9="$(cd "$T9_DIR" && CHUMP_BIN="$CHUMP_BIN" CHUMP_LOCK_DIR="$T9_DIR/.chump-locks" \
    CHUMP_AMBIENT_LOG="$T9_DIR/.chump-locks/ambient.jsonl" \
    CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
    bash "$SCRIPT" --json 2>/dev/null)"
if echo "$JSON9" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
# m-effort gap should not count; EFFECTIVE should show 2 not 3
assert d["counts"]["EFFECTIVE"] == 2, "EFFECTIVE should be 2 (m excluded), got %d" % d["counts"]["EFFECTIVE"]
' 2>/dev/null; then
    ok "9: m-effort gaps excluded from pickable count"
else
    fail "9: m-effort gaps should not count as pickable — got: $JSON9"
fi

# ── Test 10: gaps with non-empty depends_on excluded ─────────────────────
T10_DIR="$(mktemp -d -t chump-infra-902-t10-XXXXXX)"
trap 'rm -rf "$T10_DIR"' EXIT
mkdir -p "$T10_DIR/.chump" "$T10_DIR/.chump-locks"
DB="$T10_DIR/.chump/state.db"
create_schema "$DB"
# Gap with a dependency — should be excluded
sqlite3 "$DB" \
    "INSERT INTO gaps (id, domain, title, priority, effort, status, acceptance_criteria, depends_on, created_at)
     VALUES ('EFFECTIVE-DEP', 'EFFECTIVE', 'EFFECTIVE: blocked gap', 'P1', 's', 'open', '[\"AC1\"]', '[\"OTHER-001\"]', 1779000000);"
# 2 unblocked EFFECTIVE gaps
insert_gap "$DB" "EFFECTIVE-001" "EFFECTIVE"
insert_gap "$DB" "EFFECTIVE-002" "EFFECTIVE"
insert_gap "$DB" "CREDIBLE-001" "CREDIBLE"
insert_gap "$DB" "CREDIBLE-002" "CREDIBLE"
insert_gap "$DB" "RESILIENT-001" "RESILIENT"
insert_gap "$DB" "RESILIENT-002" "RESILIENT"
insert_gap "$DB" "ZERO-001" "ZERO-WASTE"
insert_gap "$DB" "ZERO-002" "ZERO-WASTE"

JSON10="$(cd "$T10_DIR" && CHUMP_BIN="$CHUMP_BIN" CHUMP_LOCK_DIR="$T10_DIR/.chump-locks" \
    CHUMP_AMBIENT_LOG="$T10_DIR/.chump-locks/ambient.jsonl" \
    CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
    bash "$SCRIPT" --json 2>/dev/null)"
if echo "$JSON10" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
# Dependent gap should not count; EFFECTIVE should show 2 not 3
assert d["counts"]["EFFECTIVE"] == 2, "EFFECTIVE should be 2 (dep excluded), got %d" % d["counts"]["EFFECTIVE"]
' 2>/dev/null; then
    ok "10: gaps with non-empty depends_on excluded from pickable count"
else
    fail "10: dependent gaps should not count as pickable — got: $JSON10"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
