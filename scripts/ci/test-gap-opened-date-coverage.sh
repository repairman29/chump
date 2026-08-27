#!/usr/bin/env bash
# test-gap-opened-date-coverage.sh — INFRA-1611
#
# Validates the opened_date data-quality fix:
#  - `chump gap audit-priorities` computes age from opened_date (not
#    created_at / DB-insert time) so a fresh import/reimport doesn't make
#    every P0 read "0d old" (RED_LETTER#12, 2026-05-18).
#  - no open P0 or P1 gap in the live registry has a missing or
#    placeholder opened_date.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

_GIT_COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON_DIR" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON_DIR/.." 2>/dev/null && pwd || echo "$REPO_ROOT")"
fi
unset _GIT_COMMON_DIR

echo "=== INFRA-1611 gap opened_date coverage test ==="
echo

# 1. audit-priorities age computation must read opened_date, not bare
#    created_at (the exact bug: a fresh state.db import/reimport makes
#    created_at == import time, so every P0 read "0d old" regardless of
#    how old the gap actually is).
if grep -q 'fn gap_age_days' "$REPO_ROOT/src/main.rs"; then
    ok "gap_age_days() helper present"
else
    fail "gap_age_days() helper missing from src/main.rs"
fi

AUDIT_BLOCK="$(awk '/"audit-priorities" =>/{flag=1} flag{print} flag && /^            "[a-z-]+" =>/ && !/"audit-priorities" =>/{exit}' "$REPO_ROOT/src/main.rs")"
if echo "$AUDIT_BLOCK" | grep -q 'now_secs - g\.created_at' ; then
    fail "audit-priorities still computes age from bare created_at (opened_date ignored)"
else
    ok "audit-priorities age computation no longer reads bare created_at"
fi
if echo "$AUDIT_BLOCK" | grep -q 'gap_age_days('; then
    ok "audit-priorities age computation routes through gap_age_days()"
else
    fail "audit-priorities does not call gap_age_days()"
fi

# 2. gap-reserve.sh stamps opened_date at reservation time (EVAL-086).
if grep -q 'opened_date' "$REPO_ROOT/scripts/coord/gap-reserve.sh"; then
    ok "gap-reserve.sh stamps opened_date at reservation time"
else
    fail "gap-reserve.sh does not stamp opened_date"
fi

# 3. Backfill script exists (git-log-derived date, created_at fallback).
if [[ -x "$REPO_ROOT/scripts/dev/backfill-opened-dates.sh" ]]; then
    ok "backfill-opened-dates.sh exists and is executable"
else
    fail "scripts/dev/backfill-opened-dates.sh missing or not executable"
fi

# 4. Functional: build binary and run against an isolated fixture DB —
#    a gap with a backdated opened_date must report non-zero age, proving
#    the fix actually changes audit-priorities' output (not just present
#    in source).
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1

"$BIN" gap reserve --domain INFRA --priority P0 --effort xs \
    --title "opened-date-fixture-old-p0" --no-outcome-required --quiet 2>/dev/null

FIXTURE_ID="$("$BIN" gap list --status open --json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print([g['id'] for g in d if g.get('title')=='opened-date-fixture-old-p0'][0])" 2>/dev/null || true)"

if [[ -z "$FIXTURE_ID" ]]; then
    fail "could not reserve fixture P0 gap for functional test"
else
    ok "reserved fixture P0 gap $FIXTURE_ID"

    FIXTURE_DB="$TMP/.chump/state.db"
    if [[ ! -f "$FIXTURE_DB" ]]; then
        fail "fixture state.db not found at $FIXTURE_DB"
    else
        OLD_DATE="$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(days=42)).strftime('%Y-%m-%d'))
")"
        sqlite3 "$FIXTURE_DB" "UPDATE gaps SET opened_date='$OLD_DATE', created_at=strftime('%s','now') WHERE id='$FIXTURE_ID'"

        AGE_DAYS=$("$BIN" gap audit-priorities --json 2>/dev/null \
            | python3 -c "
import sys, json
d = json.load(sys.stdin)
match = [g for g in d.get('p0_gaps', []) if g['id'] == '$FIXTURE_ID']
print(match[0]['age_days'] if match else -1)
" 2>/dev/null || echo -1)

        if [[ "$AGE_DAYS" -ge 40 ]]; then
            ok "audit-priorities reports age from opened_date (got ${AGE_DAYS}d, expected ~42d despite created_at=now)"
        else
            fail "audit-priorities age_days=$AGE_DAYS — expected ~42d (opened_date backdated, created_at=now); age computation is still keyed off created_at"
        fi
    fi
fi

# 5. Live registry coverage: no open P0/P1 gap missing opened_date.
LIVE_DB="$MAIN_REPO/.chump/state.db"
if [[ -f "$LIVE_DB" ]]; then
    MISSING_COUNT=$(sqlite3 "$LIVE_DB" \
        "SELECT COUNT(*) FROM gaps WHERE status='open' AND priority IN ('P0','P1') AND (opened_date IS NULL OR opened_date='' OR opened_date='0000-00-00');")
    if [[ "$MISSING_COUNT" -eq 0 ]]; then
        ok "no open P0/P1 gap missing opened_date in live registry"
    else
        fail "$MISSING_COUNT open P0/P1 gap(s) missing opened_date — run scripts/dev/backfill-opened-dates.sh"
        sqlite3 "$LIVE_DB" \
            "SELECT '  - ' || id || ' (' || priority || ')' FROM gaps WHERE status='open' AND priority IN ('P0','P1') AND (opened_date IS NULL OR opened_date='' OR opened_date='0000-00-00') LIMIT 10;"
    fi
else
    echo "  [skip] no live state.db at $LIVE_DB — coverage check needs an initialized registry"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
