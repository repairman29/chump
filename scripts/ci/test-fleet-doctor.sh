#!/usr/bin/env bash
# test-fleet-doctor.sh — INFRA-603: CI tests for 'chump fleet doctor'.
#
# Covers all 5 invariants using synthetic fixtures so no live fleet is needed.
# Each test section creates its own isolated LOCK_DIR / state.db, then verifies
# that fleet_doctor exits and reports as expected.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHUMP="${CHUMP:-$REPO_ROOT/target/release/chump}"

if [[ ! -x "$CHUMP" ]]; then
    echo "SKIP: chump binary not found at $CHUMP (run cargo build --release first)" >&2
    exit 0
fi

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS  $1"; ((PASS++)) || true; }
fail() { echo "FAIL  $1: $2"; ((FAIL++)) || true; }
skip() { echo "SKIP  $1: $2"; ((SKIP++)) || true; }

# ── helpers ────────────────────────────────────────────────────────────────────

make_env() {
    local lock_dir="$1"
    local repo_dir="$2"
    mkdir -p "$lock_dir" "$repo_dir/.chump"
    echo "CHUMP_AMBIENT_LOG=$lock_dir/ambient.jsonl"
    echo "CHUMP_REPO=$repo_dir"
}

# Create a minimal SQLite state.db with a single gap row.
make_db_with_gap() {
    local db="$1" gap_id="$2" status="$3"
    sqlite3 "$db" <<SQL
CREATE TABLE IF NOT EXISTS gaps (
    id TEXT PRIMARY KEY,
    domain TEXT, title TEXT, description TEXT, priority TEXT, effort TEXT,
    status TEXT, acceptance_criteria TEXT, depends_on TEXT, notes TEXT,
    source_doc TEXT, created_at TEXT, closed_at TEXT, opened_date TEXT,
    closed_date TEXT, closed_pr TEXT, skills_required TEXT,
    preferred_backend TEXT, preferred_machine TEXT,
    estimated_minutes INTEGER, required_model TEXT
);
INSERT INTO gaps (id, domain, title, status, priority, effort)
    VALUES ('$gap_id', 'INFRA', 'test gap', '$status', 'P1', 's');
SQL
}

emit_ambient() {
    local log="$1" ts kind
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    kind="$2"
    shift 2
    printf '{"ts":"%s","kind":"%s"%s}\n' "$ts" "$kind" "$*" >> "$log"
}

emit_alert() {
    local log="$1" kind="${2:-fleet_wedge}" note="${3:-test alert}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","event":"ALERT","kind":"%s","note":"%s"}\n' \
        "$ts" "$kind" "$note" >> "$log"
}

# ── invariant 1: PID ratio ─────────────────────────────────────────────────────
# When fleet-desired-size is 0 (or absent), the check should warn/skip, not fail.

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

{
    lock_dir="$T/t1/locks"
    repo_dir="$T/t1/repo"
    mkdir -p "$lock_dir" "$repo_dir/.chump"
    # No fleet-desired-size file → fleet_size=0 → warn (not fail)
    out=$(CHUMP_AMBIENT_LOG="$lock_dir/ambient.jsonl" CHUMP_REPO="$repo_dir" \
          "$CHUMP" fleet doctor 2>&1 || true)
    if echo "$out" | grep -q "pid_ratio" && ! echo "$out" | grep -q "FAIL.*pid_ratio"; then
        pass "inv1: pid_ratio warn when fleet_size=0 (no fail)"
    else
        fail "inv1: pid_ratio" "unexpected output: $out"
    fi
}

# ── invariant 2: stale gap locks ───────────────────────────────────────────────

{
    lock_dir="$T/t2/locks"
    repo_dir="$T/t2/repo"
    mkdir -p "$lock_dir" "$repo_dir/.chump"
    make_db_with_gap "$repo_dir/.chump/state.db" "INFRA-TEST-2" "done"
    # Create a stale lock for that done gap.
    printf 'sess-abc %s\n' "$(date +%s)" > "$lock_dir/.gap-INFRA-TEST-2.lock"

    out=$(CHUMP_AMBIENT_LOG="$lock_dir/ambient.jsonl" CHUMP_REPO="$repo_dir" \
          "$CHUMP" fleet doctor 2>&1 || true)
    if echo "$out" | grep -q "FAIL.*stale_gap_locks"; then
        pass "inv2: stale lock for done gap detected"
    else
        fail "inv2: stale lock" "expected FAIL stale_gap_locks, got: $out"
    fi
}

# ── invariant 2b: --fix removes stale lock ─────────────────────────────────────

{
    lock_dir="$T/t2b/locks"
    repo_dir="$T/t2b/repo"
    mkdir -p "$lock_dir" "$repo_dir/.chump"
    make_db_with_gap "$repo_dir/.chump/state.db" "INFRA-TEST-2B" "done"
    printf 'sess-abc %s\n' "$(date +%s)" > "$lock_dir/.gap-INFRA-TEST-2B.lock"

    CHUMP_AMBIENT_LOG="$lock_dir/ambient.jsonl" CHUMP_REPO="$repo_dir" \
        "$CHUMP" fleet doctor --fix 2>&1 || true
    if [[ ! -f "$lock_dir/.gap-INFRA-TEST-2B.lock" ]]; then
        pass "inv2b: --fix removed stale lock"
    else
        fail "inv2b: --fix stale lock" "lock file still exists after --fix"
    fi
}

# ── invariant 3: orphan claude detection ───────────────────────────────────────
# We can't create a real orphan in CI, so we verify the check runs and
# produces the correct check name in output (pass when no orphans present).

{
    lock_dir="$T/t3/locks"
    repo_dir="$T/t3/repo"
    mkdir -p "$lock_dir" "$repo_dir/.chump"

    out=$(CHUMP_AMBIENT_LOG="$lock_dir/ambient.jsonl" CHUMP_REPO="$repo_dir" \
          "$CHUMP" fleet doctor 2>&1 || true)
    if echo "$out" | grep -q "orphan_claudes"; then
        pass "inv3: orphan_claudes check present in output"
    else
        fail "inv3: orphan_claudes" "check name missing from output: $out"
    fi
}

# ── invariant 4: waste-tally fleet_wedge ──────────────────────────────────────

{
    lock_dir="$T/t4/locks"
    repo_dir="$T/t4/repo"
    mkdir -p "$lock_dir" "$repo_dir/.chump"
    ambient="$lock_dir/ambient.jsonl"
    # Emit a recent fleet_wedge ALERT.
    emit_alert "$ambient" "fleet_wedge" "synthetic wedge"

    out=$(CHUMP_AMBIENT_LOG="$ambient" CHUMP_REPO="$repo_dir" \
          "$CHUMP" fleet doctor 2>&1 || true)
    if echo "$out" | grep -q "waste_tally_30m" && echo "$out" | grep -qi "fleet_wedge\|WARN\|FAIL"; then
        pass "inv4: fleet_wedge in last 30m detected"
    else
        fail "inv4: waste_tally" "expected wedge detection, got: $out"
    fi
}

# ── invariant 4b: clean ambient passes waste check ────────────────────────────

{
    lock_dir="$T/t4b/locks"
    repo_dir="$T/t4b/repo"
    mkdir -p "$lock_dir" "$repo_dir/.chump"
    ambient="$lock_dir/ambient.jsonl"
    emit_ambient "$ambient" "session_start"

    out=$(CHUMP_AMBIENT_LOG="$ambient" CHUMP_REPO="$repo_dir" \
          "$CHUMP" fleet doctor 2>&1 || true)
    if echo "$out" | grep -q "PASS.*waste_tally_30m"; then
        pass "inv4b: clean ambient → waste_tally_30m PASS"
    else
        fail "inv4b: clean ambient" "expected PASS waste_tally_30m, got: $out"
    fi
}

# ── invariant 5: ambient ALERT in last 5 min ──────────────────────────────────

{
    lock_dir="$T/t5/locks"
    repo_dir="$T/t5/repo"
    mkdir -p "$lock_dir" "$repo_dir/.chump"
    ambient="$lock_dir/ambient.jsonl"
    emit_alert "$ambient" "silent_agent" "worker-3 heartbeat missing"

    out=$(CHUMP_AMBIENT_LOG="$ambient" CHUMP_REPO="$repo_dir" \
          "$CHUMP" fleet doctor 2>&1 || true)
    if echo "$out" | grep -q "ambient_alerts_5m" && echo "$out" | grep -qi "WARN\|ALERT"; then
        pass "inv5: recent ALERT detected"
    else
        fail "inv5: ambient ALERT" "expected WARN ambient_alerts_5m, got: $out"
    fi
}

# ── invariant 5b: old ALERT not flagged ───────────────────────────────────────

{
    lock_dir="$T/t5b/locks"
    repo_dir="$T/t5b/repo"
    mkdir -p "$lock_dir" "$repo_dir/.chump"
    ambient="$lock_dir/ambient.jsonl"
    # Emit an alert 10 minutes ago.
    old_ts="$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || true)"
    if [[ -n "$old_ts" ]]; then
        printf '{"ts":"%s","event":"ALERT","kind":"pr_stuck","note":"old alert"}\n' \
            "$old_ts" >> "$ambient"
        out=$(CHUMP_AMBIENT_LOG="$ambient" CHUMP_REPO="$repo_dir" \
              "$CHUMP" fleet doctor 2>&1 || true)
        if echo "$out" | grep -q "PASS.*ambient_alerts_5m"; then
            pass "inv5b: old ALERT not flagged"
        else
            fail "inv5b: old ALERT" "expected PASS ambient_alerts_5m, got: $out"
        fi
    else
        skip "inv5b: old ALERT" "cannot compute past timestamp on this platform"
    fi
}

# ── fleet_doctor_report emitted to ambient.jsonl ──────────────────────────────

{
    lock_dir="$T/t6/locks"
    repo_dir="$T/t6/repo"
    mkdir -p "$lock_dir" "$repo_dir/.chump"
    ambient="$lock_dir/ambient.jsonl"

    CHUMP_AMBIENT_LOG="$ambient" CHUMP_REPO="$repo_dir" \
        "$CHUMP" fleet doctor 2>&1 || true
    if grep -q '"kind":"fleet_doctor_report"' "$ambient" 2>/dev/null; then
        pass "ambient_emit: fleet_doctor_report emitted to ambient.jsonl"
    else
        fail "ambient_emit" "fleet_doctor_report not found in ambient.jsonl"
    fi
}

# ── JSON output mode ──────────────────────────────────────────────────────────

{
    lock_dir="$T/t7/locks"
    repo_dir="$T/t7/repo"
    mkdir -p "$lock_dir" "$repo_dir/.chump"

    out=$(CHUMP_AMBIENT_LOG="$lock_dir/ambient.jsonl" CHUMP_REPO="$repo_dir" \
          "$CHUMP" fleet doctor --json 2>&1 || true)
    if echo "$out" | grep -qE '^\[.*\]$'; then
        pass "json_mode: --json produces JSON array"
    else
        fail "json_mode" "expected JSON array, got: $out"
    fi
}

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
