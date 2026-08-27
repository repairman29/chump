#!/usr/bin/env bash
# test-gap-opened-date-coverage.sh — INFRA-1611
#
# Validates the opened_date aging-census fix:
#  - `chump gap reserve` stamps opened_date at reservation time (durable fix,
#    not the shell-wrapper patch this replaces).
#  - gap_age_days() prefers opened_date over created_at so a freshly-imported
#    state.db doesn't blind the P0 aging census (every gap reading "0d old").
#  - the tracked .chump/state.sql registry has NO open P0/P1 gap with a
#    missing/placeholder opened_date (the enforcement bar this gap exists
#    to hold).
#  - scripts/dev/backfill-opened-dates-registry.sh exists for future drift.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-1611 gap opened_date coverage test ==="
echo

# 1. reserve() in the gap-store crate sets opened_date at insert time.
if grep -q 'opened_date' "$REPO_ROOT/crates/chump-gap-store/src/lib.rs" \
    && grep -qE 'INSERT INTO gaps\(id,domain,title,priority,effort,status,created_at,opened_date\)' \
        "$REPO_ROOT/crates/chump-gap-store/src/lib.rs"; then
    ok "reserve() INSERT stamps opened_date"
else
    fail "reserve() INSERT does not stamp opened_date"
fi

# 2. gap_age_days() helper exists and is wired into audit-priorities.
if grep -q 'fn gap_age_days' "$REPO_ROOT/src/main.rs"; then
    ok "gap_age_days() helper defined"
else
    fail "gap_age_days() helper missing"
fi

AGE_CALL_COUNT=$(grep -c 'gap_age_days(now_secs, &g.opened_date, g.created_at)' "$REPO_ROOT/src/main.rs" || true)
if [[ "$AGE_CALL_COUNT" -ge 3 ]]; then
    ok "audit-priorities uses gap_age_days() at all 3 call sites (got $AGE_CALL_COUNT)"
else
    fail "expected >=3 gap_age_days() call sites in audit-priorities, got $AGE_CALL_COUNT"
fi

# 3. Backfill tooling exists (both the live-state.db patcher from EVAL-086
#    and the tracked-state.sql patcher added for INFRA-1611).
if [[ -x "$REPO_ROOT/scripts/dev/backfill-opened-dates.sh" ]]; then
    ok "backfill-opened-dates.sh (live state.db) present + executable"
else
    fail "backfill-opened-dates.sh missing or not executable"
fi

if [[ -x "$REPO_ROOT/scripts/dev/backfill-opened-dates-registry.sh" ]]; then
    ok "backfill-opened-dates-registry.sh (tracked state.sql) present + executable"
else
    fail "backfill-opened-dates-registry.sh missing or not executable"
fi

# 4. Registry coverage: no open P0/P1 gap in the tracked .chump/state.sql
#    has a missing or placeholder opened_date.
SQL_PATH="$REPO_ROOT/.chump/state.sql"
if [[ -f "$SQL_PATH" ]]; then
    MISSING=$(python3 - "$SQL_PATH" <<'PYEOF'
import sys
import yaml

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

placeholder_values = {"", "TBD", "TODO", "0000-00-00", "1970-01-01"}
missing = [
    g["id"]
    for g in data.get("gaps", [])
    if g.get("status") == "open"
    and g.get("priority") in ("P0", "P1")
    and (g.get("opened_date") or "").strip() in placeholder_values
]
for gid in missing:
    print(gid)
PYEOF
)
    if [[ -z "$MISSING" ]]; then
        ok "no open P0/P1 gap missing opened_date in .chump/state.sql"
    else
        fail "open P0/P1 gaps missing opened_date: $(echo "$MISSING" | tr '\n' ' ')"
    fi
else
    fail ".chump/state.sql not found — cannot check registry coverage"
fi

# 5. Functional test: build binary and confirm `gap reserve` stamps
#    opened_date on a fresh isolated fixture.
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ -f "$BIN" ]]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    export CHUMP_REPO="$TMP"
    export CHUMP_HOME="$TMP"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1

    NEW_ID=$("$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
        --title "opened-date-fixture" --skip-obs-acs --quiet --json 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)

    if [[ -n "$NEW_ID" ]]; then
        JSON=$("$BIN" gap audit-priorities --json 2>/dev/null || true)
        OPENED=$("$BIN" gap show "$NEW_ID" 2>/dev/null | grep -c 'opened_date' || true)
        # Fall back to a direct DB check if `gap show` doesn't expose the field.
        DB="$TMP/.chump/state.db"
        DB_OPENED=""
        if [[ -f "$DB" ]]; then
            DB_OPENED=$(sqlite3 "$DB" "SELECT opened_date FROM gaps WHERE id='$NEW_ID'" 2>/dev/null || true)
        fi
        if [[ -n "$DB_OPENED" ]]; then
            ok "fresh reserve() stamped opened_date=$DB_OPENED on $NEW_ID"
        else
            fail "fresh reserve() did not stamp opened_date on $NEW_ID"
        fi
    else
        fail "could not reserve a fixture gap to verify opened_date stamping"
    fi
else
    fail "chump binary not found after build — skipping functional test"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
