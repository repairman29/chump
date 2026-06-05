#!/usr/bin/env bash
# scripts/ci/test-gap-reconcile.sh — CREDIBLE-092
#
# Regression test for `chump gap reconcile` — the local post-merge healer
# that flips open-but-merged gaps to done by scanning git log origin/main.
#
# Strategy: use a synthetic state.db via CHUMP_STATE_DB env var plus a
# fake git repo with controlled commit history, so no network is needed
# and the real state.db is never touched.
#
# Test cases:
#   1. --dry-run shows planned flips without mutating state.db
#   2. Live run flips the open gap whose ID appears in origin/main commits
#   3. Gap NOT in any commit stays open
#   4. Already-done gap is skipped (idempotency)
#   5. Ambient event kind=gap_reconciled emitted on flip with correct fields
#   6. Second run produces flipped=0 (idempotent)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# Locate chump binary.
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if command -v chump >/dev/null 2>&1; then
        CHUMP_BIN="chump"
    elif [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif [[ -x "$REPO_ROOT/target/release/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/release/chump"
    else
        fail "chump binary not found (set CHUMP_BIN or build first)"
    fi
fi

# ── Setup: synthetic git repo ───────────────────────────────────────────────
TMP="$(mktemp -d -t test-gap-reconcile.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# We need a git repo where `git log origin/main` has the commit we care about.
# Use a bare repo as the remote so we can control what's "on origin/main".
BARE_REPO="$TMP/bare"
FAKE_REPO="$TMP/repo"
git init --bare -q "$BARE_REPO"
git init -q "$FAKE_REPO"
git -C "$FAKE_REPO" config user.email "test@test"
git -C "$FAKE_REPO" config user.name  "test"
git -C "$FAKE_REPO" remote add origin "$FAKE_REPO/../bare"  # relative-safe

# Initial commit so HEAD is valid
touch "$FAKE_REPO/README"
git -C "$FAKE_REPO" add README
git -C "$FAKE_REPO" commit -q -m "chore: initial"

# Commit referencing two gap IDs — one will be in state.db as open,
# one will already be done (idempotency), one will not be in state.db at all.
# We use the prefix RCNTEST- to avoid colliding with real gap IDs.
touch "$FAKE_REPO/feat"
git -C "$FAKE_REPO" add feat
git -C "$FAKE_REPO" commit -q -m "feat(RCNTEST-1): implement the thing (#777)"

touch "$FAKE_REPO/feat2"
git -C "$FAKE_REPO" add feat2
git -C "$FAKE_REPO" commit -q -m "feat(RCNTEST-3): already done gap (#888)"

# Push to origin so `git log origin/main` works
git -C "$FAKE_REPO" push -q origin HEAD:main
git -C "$FAKE_REPO" fetch -q origin

# ── Setup: synthetic state.db via sqlite3 ──────────────────────────────────
# We bypass `chump gap reserve` (which needs the full Chump repo env) by
# constructing the state.db directly via sqlite3.  The schema mirrors what
# GapStore::open() creates.  We only need the columns that `gap reconcile`
# reads and writes.
STATE_DB="$TMP/state.db"
# ambient.jsonl lives under repo_root/.chump-locks/ (CHUMP_REPO resolves this)
AMB="$FAKE_REPO/.chump-locks/ambient.jsonl"
mkdir -p "$FAKE_REPO/.chump-locks"

# Create the gaps table with the required columns. Minimal schema — just what
# reconcile needs (status, closed_at, closed_pr) plus what `gap show` displays.
sqlite3 "$STATE_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS gaps (
    id TEXT PRIMARY KEY,
    domain TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT 'P2',
    effort TEXT NOT NULL DEFAULT 'm',
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
    required_model TEXT NOT NULL DEFAULT '',
    shipped_in TEXT,
    outcome_id TEXT
);
SQL

# Insert test rows:
#   RCNTEST-1: open — should be flipped to done by reconcile
#   RCNTEST-2: open — NOT in any commit, should stay open
#   RCNTEST-3: done — already closed, should be skipped (idempotency)
sqlite3 "$STATE_DB" <<'SQL'
INSERT INTO gaps (id, domain, title, status) VALUES
    ('RCNTEST-1', 'RCNTEST', 'open gap in commit', 'open'),
    ('RCNTEST-2', 'RCNTEST', 'open gap NOT in commit', 'open'),
    ('RCNTEST-3', 'RCNTEST', 'already done gap', 'done');
SQL

pass "Setup: state.db with RCNTEST-1 (open/in-commit), RCNTEST-2 (open/no-commit), RCNTEST-3 (done)"

# Helper: query state.db status for a gap ID
db_status() {
    sqlite3 "$STATE_DB" "SELECT status FROM gaps WHERE id='$1';"
}

db_closed_pr() {
    sqlite3 "$STATE_DB" "SELECT closed_pr FROM gaps WHERE id='$1';"
}

# ── Test 1: --dry-run shows flip but doesn't mutate ─────────────────────────
dry_out="$(CHUMP_STATE_DB="$STATE_DB" \
    CHUMP_REPO="$FAKE_REPO" \
    CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
    CHUMP_SKIP_SUPERSEDED_CLOSE=1 \
        git -C "$FAKE_REPO" fetch -q origin 2>/dev/null || true; \
    CHUMP_STATE_DB="$STATE_DB" \
    CHUMP_REPO="$FAKE_REPO" \
    CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
    CHUMP_SKIP_SUPERSEDED_CLOSE=1 \
        "$CHUMP_BIN" gap reconcile --dry-run 2>&1)"

echo "$dry_out" | grep -q "RCNTEST-1" || fail "dry-run output missing RCNTEST-1: $dry_out"
echo "$dry_out" | grep -qi "dry.run" || fail "dry-run output missing 'dry-run' label: $dry_out"

# State.db must still show RCNTEST-1 as open after dry-run
r1_status="$(db_status RCNTEST-1)"
[ "$r1_status" = "open" ] || fail "dry-run mutated RCNTEST-1 to $r1_status (expected open)"

# No ambient event written in dry-run
[ ! -s "$AMB" ] || fail "dry-run wrote ambient event unexpectedly: $(cat "$AMB")"

pass "Test 1: --dry-run shows RCNTEST-1 flip, state.db unchanged, no ambient event"

# ── Test 2: live run flips RCNTEST-1 → done ─────────────────────────────────
run_out="$(CHUMP_STATE_DB="$STATE_DB" \
    CHUMP_REPO="$FAKE_REPO" \
    CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
    CHUMP_SKIP_SUPERSEDED_CLOSE=1 \
        "$CHUMP_BIN" gap reconcile 2>&1)"

echo "$run_out" | grep -qi "flipped=1" || fail "live run flipped count not 1: $run_out"
echo "$run_out" | grep -q "RCNTEST-1" || fail "live run missing RCNTEST-1: $run_out"

# Check RCNTEST-1 is now done
r1_after="$(db_status RCNTEST-1)"
[ "$r1_after" = "done" ] || fail "RCNTEST-1 still $r1_after after reconcile (expected done)"

# Check RCNTEST-1 closed_pr = 777
r1_pr="$(db_closed_pr RCNTEST-1)"
[ "$r1_pr" = "777" ] || fail "RCNTEST-1 closed_pr=$r1_pr (expected 777)"

pass "Test 2: live run flips RCNTEST-1 → done with closed_pr=777"

# ── Test 3: RCNTEST-2 (not in any commit) stays open ────────────────────────
r2_status="$(db_status RCNTEST-2)"
[ "$r2_status" = "open" ] || fail "RCNTEST-2 unexpectedly flipped to $r2_status (should stay open)"
pass "Test 3: RCNTEST-2 (not-in-commit) stays open"

# ── Test 4: idempotency — second run produces flipped=0 ─────────────────────
run2_out="$(CHUMP_STATE_DB="$STATE_DB" \
    CHUMP_REPO="$FAKE_REPO" \
    CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
    CHUMP_SKIP_SUPERSEDED_CLOSE=1 \
        "$CHUMP_BIN" gap reconcile 2>&1)"
echo "$run2_out" | grep -qi "flipped=0" || fail "second run unexpectedly flipped something: $run2_out"
pass "Test 4: idempotency — second run flipped=0"

# ── Test 5: ambient event emitted with correct fields ───────────────────────
[ -s "$AMB" ] || fail "no ambient event in $AMB after live run"
# The ambient log may have multiple lines (from the ship step); find our event
amb_line="$(grep '"kind":"gap_reconciled"' "$AMB" | tail -1 || echo "")"
[ -n "$amb_line" ] || fail "gap_reconciled event not found in ambient log: $(cat "$AMB")"
echo "$amb_line" | grep -q '"flipped_count":1' || fail "ambient event wrong flipped_count: $amb_line"
echo "$amb_line" | grep -q 'RCNTEST-1' || fail "ambient event missing RCNTEST-1: $amb_line"
echo "$amb_line" | grep -q '"dry_run":false' || fail "ambient event missing dry_run=false: $amb_line"
pass "Test 5: ambient event gap_reconciled emitted with correct fields"

# ── Test 6: EVENT_REGISTRY.yaml registers gap_reconciled ────────────────────
grep -q "kind: gap_reconciled" "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
    || fail "gap_reconciled not registered in docs/observability/EVENT_REGISTRY.yaml"
pass "Test 6: EVENT_REGISTRY.yaml registers gap_reconciled"

echo
echo "All CREDIBLE-092 gap-reconcile tests passed."
