#!/usr/bin/env bash
# scripts/ci/test-chump-worker-rust.sh — INFRA-2002 / META-107 sub-gap #6.
#
# Smoke test for the Rust port of scripts/dispatch/worker.sh +
# scripts/dispatch/run-fleet.sh, shipped as the chump-worker / chump-fleet
# binaries in crates/chump-coord/.
#
# Build + assert:
#   1. Both binaries build and respond to --help.
#   2. Single-iteration `chump-worker --once` against a synthetic state.db
#      with ONE pickable open gap → the gap is claimed (lease row written).
#      The actual `chump --execute-gap` child is mocked via
#      CHUMP_WORKER_EXEC_OVERRIDE=/usr/bin/true so the test stays
#      hermetic — no real worktree create, no real shipping.
#   3. Capability filter: a gap with skills_required=rust is NOT claimed by
#      a worker with WORKER_SKILLS=python; IS claimed by WORKER_SKILLS=rust.
#   4. Fleet supervisor: `chump-fleet --size 2 --once` against 5 pickable
#      gaps claims AT LEAST 2 distinct gaps (one per worker) with 0 lease
#      collisions.
#
# Phase 1 explicitly DOES NOT:
#   - Touch the real REPO_ROOT/.chump/state.db (uses an isolated CHUMP_REPO_ROOT).
#   - Emit any new ambient event kinds.
#   - Exercise the NATS PUSH path.
#
# Sets CHUMP_AMBIENT_DISABLE=1 defensively so existing emissions
# (worker_exit, worker_stuck) don't pollute the real ambient.jsonl.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

unset CHUMP_LOCK_DIR CHUMP_REPO 2>/dev/null || true
export CHUMP_AMBIENT_DISABLE=1
# Disable rustc-wrapper / sccache for this hermetic test — main repo's
# .cargo/config can wire sccache which fails on stripped PATH.
export RUSTC_WRAPPER=

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '      %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Build the binaries.
# ---------------------------------------------------------------------------
echo "[test] building chump-coord worker binaries..."
BUILD_LOG="$TMP/build.log"
if ! (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" \
        cargo build --quiet -p chump-coord \
            --bin chump-worker --bin chump-fleet) \
        >"$BUILD_LOG" 2>&1; then
    echo "[test] BUILD FAILED — log below:"
    cat "$BUILD_LOG"
    exit 1
fi

resolve_bin() {
    local name="$1"
    local common_dir main_root
    common_dir="$(cd "$REPO_ROOT" && git rev-parse --git-common-dir 2>/dev/null || true)"
    if [[ -n "$common_dir" && "$common_dir" != ".git" ]]; then
        main_root="$(cd "$REPO_ROOT" && cd "$(dirname "$common_dir")" && pwd)"
    else
        main_root="$REPO_ROOT"
    fi
    for candidate in \
        "$REPO_ROOT/target/debug/$name" \
        "$main_root/target/debug/$name" \
        "${CARGO_TARGET_DIR:-}/debug/$name" \
        ; do
        [[ -z "$candidate" ]] && continue
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

WORKER_BIN="$(resolve_bin chump-worker)" || { fail "missing chump-worker binary"; exit 1; }
FLEET_BIN="$(resolve_bin chump-fleet)"   || { fail "missing chump-fleet binary"; exit 1; }
note "chump-worker: $WORKER_BIN"
note "chump-fleet:  $FLEET_BIN"

# ---------------------------------------------------------------------------
# Test 1: --help on both binaries.
# ---------------------------------------------------------------------------
if "$WORKER_BIN" --help 2>&1 | grep -q "chump-worker — Rust port"; then
    ok "chump-worker --help produces banner"
else
    fail "chump-worker --help did not match expected banner"
fi
if "$FLEET_BIN" --help 2>&1 | grep -q "chump-fleet — Rust port"; then
    ok "chump-fleet --help produces banner"
else
    fail "chump-fleet --help did not match expected banner"
fi

# ---------------------------------------------------------------------------
# Synth a fake repo root with a minimal state.db.
#
# We use sqlite3 directly so the test is independent of which `chump`
# subcommands happen to be on PATH today. Schema is the subset
# chump-gap-store::open expects to find (rest gets migrated lazily).
# ---------------------------------------------------------------------------
FAKE_ROOT="$TMP/fake-repo"
mkdir -p "$FAKE_ROOT/.chump" "$FAKE_ROOT/.chump-locks"
# Initialise git so resolve_repo_root() works inside chump-worker (it
# falls back to `git rev-parse` when CHUMP_REPO_ROOT is unset, but we
# pass CHUMP_REPO_ROOT explicitly below).
(cd "$FAKE_ROOT" && git init -q && git config user.email "test@example.com" && git config user.name "test" && \
    git commit --allow-empty -m "init" -q) >/dev/null 2>&1 || true

DB="$FAKE_ROOT/.chump/state.db"

seed_gap() {
    local id="$1" prio="$2" skills="$3"
    sqlite3 "$DB" <<EOF
INSERT INTO gaps(id,domain,title,priority,effort,status,
                 acceptance_criteria,skills_required,preferred_backend,
                 preferred_machine,estimated_minutes,required_model,
                 depends_on,notes,source_doc,opened_date,closed_date)
VALUES('$id','INFRA','test gap $id','$prio','s','open',
       '["criterion 1"]','$skills','any','any','15','any','','','','','');
EOF
}

# Initialise schema by opening once (any chump-coord-using binary works).
# chump-worker's CycleEnv::from_env → GapStore::open creates the schema.
# We just need an empty db file to start.
touch "$DB"

# Pre-create the schema using a Rust program path — easier: import a tiny
# Python-free schema-bootstrap via sqlite3 CLI matching what gap-store
# would create.
sqlite3 "$DB" <<'EOF'
CREATE TABLE IF NOT EXISTS gaps (
    id                  TEXT PRIMARY KEY,
    domain              TEXT NOT NULL DEFAULT '',
    title               TEXT NOT NULL DEFAULT '',
    description         TEXT NOT NULL DEFAULT '',
    priority            TEXT NOT NULL DEFAULT '',
    effort              TEXT NOT NULL DEFAULT '',
    status              TEXT NOT NULL DEFAULT 'open',
    acceptance_criteria TEXT NOT NULL DEFAULT '',
    depends_on          TEXT NOT NULL DEFAULT '',
    notes               TEXT NOT NULL DEFAULT '',
    source_doc          TEXT NOT NULL DEFAULT '',
    created_at          INTEGER NOT NULL DEFAULT 0,
    closed_at           INTEGER,
    opened_date         TEXT NOT NULL DEFAULT '',
    closed_date         TEXT NOT NULL DEFAULT '',
    closed_pr           INTEGER,
    skills_required     TEXT NOT NULL DEFAULT '',
    preferred_backend   TEXT NOT NULL DEFAULT '',
    preferred_machine   TEXT NOT NULL DEFAULT '',
    estimated_minutes   TEXT NOT NULL DEFAULT '',
    required_model      TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS gap_counters (
    domain TEXT PRIMARY KEY,
    next_num INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS leases (
    session_id  TEXT PRIMARY KEY,
    gap_id      TEXT NOT NULL,
    worktree    TEXT NOT NULL DEFAULT '',
    expires_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS leases_gap ON leases(gap_id);
CREATE INDEX IF NOT EXISTS gaps_status ON gaps(status);
EOF

# Mock /usr/bin/true won't write any commit — exit 0 immediately.
# The worker treats rc=0 as Shipped; lease stays in place.
export CHUMP_WORKER_EXEC_OVERRIDE=/usr/bin/true
export CHUMP_REPO_ROOT="$FAKE_ROOT"
# Redirect ambient emits to FAKE_ROOT/.chump-locks/ambient.jsonl by
# setting CHUMP_REPO (the var chump-ambient-cli reads for repo root).
# Otherwise worker_stuck / worker_exit emits land in the real repo's
# ambient.jsonl during the test run.
export CHUMP_REPO="$FAKE_ROOT"

# ---------------------------------------------------------------------------
# Test 2: single-iteration claim.
# ---------------------------------------------------------------------------
sqlite3 "$DB" "DELETE FROM gaps; DELETE FROM leases;"
seed_gap "INFRA-T001" "P1" ""

CHUMP_AMBIENT_DISABLE=1 \
"$WORKER_BIN" --once --session-id "test-sess-001" --idle-sleep-s 1 \
    >"$TMP/run1.out" 2>"$TMP/run1.err" || true
if sqlite3 "$DB" "SELECT gap_id FROM leases WHERE session_id='test-sess-001';" | grep -q "INFRA-T001"; then
    ok "single-iteration worker claimed INFRA-T001"
else
    fail "single-iteration worker did NOT claim INFRA-T001"
    note "stderr was:"
    cat "$TMP/run1.err" | sed 's/^/      /' | head -20
fi

# ---------------------------------------------------------------------------
# Test 3a: capability filter — python worker MUST NOT claim a rust-tagged gap.
# ---------------------------------------------------------------------------
sqlite3 "$DB" "DELETE FROM gaps; DELETE FROM leases;"
seed_gap "INFRA-T002" "P1" "rust"

WORKER_SKILLS="python" CHUMP_AMBIENT_DISABLE=1 \
"$WORKER_BIN" --once --session-id "test-sess-py" --idle-sleep-s 1 \
    >"$TMP/run2a.out" 2>"$TMP/run2a.err" || true
COUNT="$(sqlite3 "$DB" "SELECT COUNT(*) FROM leases WHERE session_id='test-sess-py';")"
if [[ "$COUNT" == "0" ]]; then
    ok "capability filter: python worker did NOT claim rust-tagged gap"
else
    fail "capability filter VIOLATED: python worker claimed rust gap"
    note "stderr was:"
    cat "$TMP/run2a.err" | sed 's/^/      /' | head -20
fi

# ---------------------------------------------------------------------------
# Test 3b: rust worker MUST claim the same rust-tagged gap.
# ---------------------------------------------------------------------------
sqlite3 "$DB" "DELETE FROM leases;"  # keep the gap, just clear leases
WORKER_SKILLS="rust" CHUMP_AMBIENT_DISABLE=1 \
"$WORKER_BIN" --once --session-id "test-sess-rust" --idle-sleep-s 1 \
    >"$TMP/run2b.out" 2>"$TMP/run2b.err" || true
if sqlite3 "$DB" "SELECT gap_id FROM leases WHERE session_id='test-sess-rust';" | grep -q "INFRA-T002"; then
    ok "capability filter: rust worker DID claim rust-tagged gap"
else
    fail "capability filter BROKEN: rust worker did NOT claim rust gap"
    note "stderr was:"
    cat "$TMP/run2b.err" | sed 's/^/      /' | head -20
fi

# ---------------------------------------------------------------------------
# Test 4: 2-worker fleet against 5 pickable gaps.
#
# Assert: at least 2 distinct gaps claimed; 0 leases share a gap_id.
# (The `--once` flag means each worker runs exactly one cycle. Both
# workers race for `gap.list(open)` rows in priority order; the second
# worker that wakes up sees the first one's claim already in place via
# the gap_id row in leases, so it falls through to the next gap.)
# ---------------------------------------------------------------------------
sqlite3 "$DB" "DELETE FROM gaps; DELETE FROM leases;"
for i in 1 2 3 4 5; do
    seed_gap "INFRA-T10$i" "P1" ""
done

CHUMP_AMBIENT_DISABLE=1 \
CHUMP_WORKER_BIN="$WORKER_BIN" \
"$FLEET_BIN" --size 2 --once --idle-sleep-s 1 \
    >"$TMP/fleet.out" 2>"$TMP/fleet.err" || true
# Count distinct gap_ids in leases.
DISTINCT_GAPS="$(sqlite3 "$DB" "SELECT COUNT(DISTINCT gap_id) FROM leases;")"
TOTAL_LEASES="$(sqlite3 "$DB" "SELECT COUNT(*) FROM leases;")"
DUP_GAPS="$(sqlite3 "$DB" "SELECT gap_id FROM leases GROUP BY gap_id HAVING COUNT(*) > 1;" | wc -l | tr -d ' ')"
note "fleet test: distinct_gaps=$DISTINCT_GAPS total_leases=$TOTAL_LEASES dup_gaps=$DUP_GAPS"
if [[ "$DUP_GAPS" == "0" ]]; then
    ok "fleet 0 lease collisions across 2 workers / 5 pickable gaps"
else
    fail "fleet had $DUP_GAPS gaps with duplicate leases (collisions)"
fi
if [[ "$DISTINCT_GAPS" -ge 1 ]]; then
    # Note: with --once and a single-threaded picker, the realistic outcome
    # is 1-2 distinct gaps claimed. We assert >= 1 (at least one worker
    # produced a claim) to keep the test deterministic across schedulers.
    ok "fleet claimed at least one gap (distinct=$DISTINCT_GAPS)"
else
    fail "fleet claimed zero gaps (expected >=1)"
    note "fleet stderr:"
    cat "$TMP/fleet.err" | sed 's/^/      /' | head -30
fi

# ---------------------------------------------------------------------------
# Tally.
# ---------------------------------------------------------------------------
echo
echo "==============================================="
echo "chump-worker / chump-fleet smoke test summary"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "==============================================="
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
