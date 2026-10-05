#!/usr/bin/env bash
# capability-guard-exempt: existing CHUMP_BIN check + exit-0 skip path covers missing-binary case (CREDIBLE-078)
# scripts/ci/test-gap-opened-date-coverage.sh — INFRA-1611
#
# Regression guard for the "486/540 gaps missing opened_date — P0 aging
# census blind" gap: `chump gap audit-priorities` used to compute age from
# `created_at` (state.db import time), so a freshly-imported DB showed
# every P0 as "0d old" regardless of when the gap was actually reserved.
#
# This test asserts:
#   1. `chump gap reserve` stamps a real (non-empty, non-placeholder)
#      opened_date on the new gap row at reservation time.
#   2. `chump gap audit-priorities --json` surfaces open P0/P1 gaps with
#      missing/placeholder opened_date via `missing_opened_date_p0p1_count`.
#   3. Age (`p0_gaps[].age_days`) is computed from `opened_date`, not
#      `created_at` — a gap opened long ago but only just imported (fresh
#      created_at) still reports a non-zero age.
#
# Exit: 0 = fix intact, 1 = regression

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if command -v chump >/dev/null 2>&1; then
        CHUMP_BIN="$(command -v chump)"
    elif [[ -x "$REPO_ROOT/target/release/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/release/chump"
    elif [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    else
        echo "FAIL INFRA-1611: chump binary not found"
        exit 1
    fi
fi

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1611 gap opened_date coverage test ==="
echo

# ── Part 1: reserve stamps opened_date ────────────────────────────────────
FIXTURE_REPO="$(mktemp -d -t chump-infra-1611-reserve-XXXXXX)"
trap 'rm -rf "$FIXTURE_REPO" "${FIXTURE_DIR:-}"' EXIT

git -C "$FIXTURE_REPO" init -q
git -C "$FIXTURE_REPO" config user.email "test@example.com"
git -C "$FIXTURE_REPO" config user.name "Test"
mkdir -p "$FIXTURE_REPO/docs/gaps" "$FIXTURE_REPO/.chump-locks"
touch "$FIXTURE_REPO/README.md"
git -C "$FIXTURE_REPO" add README.md
git -C "$FIXTURE_REPO" commit -q -m "init"

pushd "$FIXTURE_REPO" >/dev/null
reserved_id="$("$CHUMP_BIN" gap reserve --domain INFRA --title "opened_date coverage fixture gap" \
    --quiet --no-ac-required --no-evidence-required --force 2>/dev/null | tail -1)"
popd >/dev/null

if [[ -z "$reserved_id" ]]; then
    fail "chump gap reserve did not return a gap id (fixture setup broken)"
else
    opened_date="$(sqlite3 "$FIXTURE_REPO/.chump/state.db" \
        "SELECT opened_date FROM gaps WHERE id='$reserved_id'" 2>/dev/null || true)"
    if [[ -z "$opened_date" || "$opened_date" == "0000-00-00" ]]; then
        fail "reserve did not stamp opened_date on $reserved_id (got '$opened_date')"
    elif [[ ! "$opened_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        fail "reserve stamped a malformed opened_date on $reserved_id: '$opened_date'"
    else
        ok "chump gap reserve stamps opened_date='$opened_date' on $reserved_id"
    fi
fi

# ── Part 2 + 3: audit-priorities coverage + age computed from opened_date ──
FIXTURE_DIR="$(mktemp -d -t chump-infra-1611-audit-XXXXXX)"
mkdir -p "$FIXTURE_DIR/.chump"
DB="$FIXTURE_DIR/.chump/state.db"

sqlite3 "$DB" <<'SQL'
CREATE TABLE gaps (
    id TEXT PRIMARY KEY,
    domain TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT 'P2',
    effort TEXT NOT NULL DEFAULT 's',
    status TEXT NOT NULL DEFAULT 'open',
    acceptance_criteria TEXT NOT NULL DEFAULT '',
    depends_on TEXT NOT NULL DEFAULT '',
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
    required_model TEXT NOT NULL DEFAULT ''
);

-- Freshly "imported" (created_at = now) but genuinely opened 100 days ago:
-- age must come from opened_date, not created_at, or this reports 0d old.
INSERT INTO gaps (id, title, priority, status, acceptance_criteria, created_at, opened_date)
  VALUES ('TEST-OLD', 'genuinely old P0, freshly imported', 'P0', 'open', '["AC1"]',
          strftime('%s','now'), strftime('%Y-%m-%d','now','-100 days'));

-- Open P1 with no opened_date at all — should be flagged as coverage gap.
INSERT INTO gaps (id, title, priority, status, acceptance_criteria, created_at, opened_date)
  VALUES ('TEST-MISSING', 'P1 missing opened_date', 'P1', 'open', '["AC1"]',
          strftime('%s','now'), '');
SQL

pushd "$FIXTURE_DIR" >/dev/null
# NOTE: audit-priorities intentionally exits non-zero when it finds a P0
# stuck >7d (by design, unrelated to opened_date coverage) — the fixture's
# TEST-OLD gap trips that on purpose to prove age comes from opened_date,
# so the exit code itself is not asserted here; only the JSON content is.
audit_json="$("$CHUMP_BIN" gap audit-priorities --json 2>/dev/null || true)"
popd >/dev/null

if [[ -z "$audit_json" ]]; then
    fail "audit-priorities produced no output on fixture DB"
else
    missing_count="$(echo "$audit_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["missing_opened_date_p0p1_count"])' 2>/dev/null || echo "ERR")"
    if [[ "$missing_count" == "1" ]]; then
        ok "audit-priorities flags exactly 1 open P0/P1 gap missing opened_date (TEST-MISSING)"
    else
        fail "audit-priorities missing_opened_date_p0p1_count = '$missing_count', want 1"
    fi

    old_age="$(echo "$audit_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for g in d.get("p0_gaps", []):
    if g["id"] == "TEST-OLD":
        print(g["age_days"])
        break
else:
    print("NOTFOUND")
' 2>/dev/null || echo "ERR")"
    if [[ "$old_age" =~ ^[0-9]+$ ]] && [[ "$old_age" -ge 99 ]]; then
        ok "TEST-OLD age_days=$old_age computed from opened_date (~100d), not fresh created_at"
    else
        fail "TEST-OLD age_days='$old_age', want >=99 (age must derive from opened_date)"
    fi
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
