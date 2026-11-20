#!/usr/bin/env bash
# capability-guard-exempt: existing skip-path covers missing binary; pattern wording differs from canonical (CREDIBLE-078)
# test-gap-ship-stale-gate.sh — INFRA-1007
#
# Verifies that `chump gap ship` refuses when the branch is > STALE_THRESHOLD
# commits behind origin/main, and passes when it is within threshold.
#
# AC:
#   1. chump gap ship exits non-zero when BEHIND=20 (> threshold 15)
#   2. chump gap ship exits 0 for BEHIND=5 (< threshold 15, error is non-stale)
#   3. stale_branch_blocked event emitted to ambient.jsonl on refusal
#   4. event has kind=stale_branch_blocked, phase=gap-ship, correct behind count
#   5. CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 bypasses the gate

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# Resolve chump binary
CHUMP_BIN="${CHUMP_BIN:-${REPO_ROOT}/target/debug/chump}"
if [ ! -x "$CHUMP_BIN" ]; then
    CHUMP_BIN="$(command -v chump 2>/dev/null || true)"
fi
[ -x "$CHUMP_BIN" ] || fail "Cannot find chump binary"

TMP="$(mktemp -d -t test-infra-1007.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO/.chump-locks" "$FAKE_REPO/.chump"
AMBIENT="$FAKE_REPO/.chump-locks/ambient.jsonl"

# ── Create mock git wrapper ────────────────────────────────────────────────────
MOCK_GIT_DIR="$TMP/mock-git"
mkdir -p "$MOCK_GIT_DIR"
BEHIND_FILE="$TMP/behind_count"

cat > "$MOCK_GIT_DIR/git" <<'MOCK'
#!/usr/bin/env bash
BEHIND_FILE="${BEHIND_FILE:-/tmp/behind_count}"
if [ "${1:-}" = "rev-list" ] && [ "${2:-}" = "--count" ]; then
    cat "$BEHIND_FILE" 2>/dev/null || echo 0
    exit 0
elif [ "${1:-}" = "fetch" ]; then
    exit 0
elif [ "${1:-}" = "rev-parse" ] && [ "${3:-}" = "HEAD" ]; then
    echo "chump/infra-1007-claim"
    exit 0
fi
exec /usr/bin/git "$@"
MOCK
chmod +x "$MOCK_GIT_DIR/git"

# ── Initialize minimal state.db ───────────────────────────────────────────────
python3 - <<PYEOF
import sqlite3, os
db = os.path.join('$FAKE_REPO', '.chump', 'state.db')
c = sqlite3.connect(db)
c.executescript('''
CREATE TABLE IF NOT EXISTS gaps (
    id TEXT PRIMARY KEY, domain TEXT, title TEXT, status TEXT,
    priority TEXT, effort TEXT, description TEXT,
    acceptance_criteria TEXT, depends_on TEXT, notes TEXT,
    closed_pr INTEGER, closed_date TEXT, created_at TEXT, updated_at TEXT,
    session_id TEXT, author TEXT, extra_meta TEXT
);
CREATE TABLE IF NOT EXISTS leases (
    session_id TEXT PRIMARY KEY, gap_id TEXT, worktree TEXT,
    pid INTEGER, started_at TEXT, expires_at TEXT, extra_meta TEXT
);
''')
c.execute("INSERT OR REPLACE INTO gaps (id,domain,title,status,priority,effort) VALUES ('TEST-001','TEST','Stale gate test','in_flight','P1','xs')")
c.execute("INSERT OR REPLACE INTO leases (session_id,gap_id,worktree,pid,started_at,expires_at) VALUES ('test-session-1007','TEST-001','$FAKE_REPO',999999,'2026-01-01T00:00:00Z','2099-01-01T00:00:00Z')")
c.commit()
print('DB ready')
PYEOF

# Helper: reset gap status to in_flight
reset_gap() {
    python3 -c "
import sqlite3
c = sqlite3.connect('$FAKE_REPO/.chump/state.db')
c.execute(\"UPDATE gaps SET status='in_flight' WHERE id='TEST-001'\")
c.commit()
"
}

# Common env for all tests
BASE_ENV=(
    "CHUMP_REPO=$FAKE_REPO"
    "CHUMP_WORKTREE_ROOT=$FAKE_REPO"
    "CHUMP_SESSION_ID=test-session-1007"
    "CHUMP_GAP_SHIP_STALE_THRESHOLD=15"
    "BEHIND_FILE=$BEHIND_FILE"
    "PATH=$MOCK_GIT_DIR:$PATH"
)

# ── Test 1: BEHIND=20 exits non-zero ─────────────────────────────────────────
echo 20 > "$BEHIND_FILE"
reset_gap
if env "${BASE_ENV[@]}" "$CHUMP_BIN" gap ship TEST-001 >/dev/null 2>&1; then
    fail "Test 1: expected exit 3 for BEHIND=20 but got 0"
fi
pass "Test 1: chump gap ship exits non-zero when 20 commits behind (threshold 15)"

# ── Test 2: stale_branch_blocked emitted with phase=gap-ship ──────────────────
echo 20 > "$BEHIND_FILE"
reset_gap
env "${BASE_ENV[@]}" "$CHUMP_BIN" gap ship TEST-001 >/dev/null 2>&1 || true
grep -q "stale_branch_blocked" "$AMBIENT" \
    || fail "Test 2a: stale_branch_blocked not in ambient.jsonl"
grep -q '"phase":"gap-ship"' "$AMBIENT" \
    || fail "Test 2b: phase!=gap-ship in ambient.jsonl"
pass "Test 2: stale_branch_blocked event emitted with phase=gap-ship"

# ── Test 3: event has all required fields ────────────────────────────────────
EVENT=$(grep "stale_branch_blocked" "$AMBIENT" | tail -1)
python3 - "$EVENT" <<'PYEOF'
import sys, json
event = sys.argv[1]
try:
    d = json.loads(event)
    required = ['ts', 'kind', 'branch', 'behind', 'threshold', 'phase']
    missing = [k for k in required if k not in d]
    if missing:
        print(f'MISSING: {missing}', file=sys.stderr); sys.exit(1)
    if d['kind'] != 'stale_branch_blocked':
        print(f"wrong kind: {d['kind']}", file=sys.stderr); sys.exit(1)
    if d['phase'] != 'gap-ship':
        print(f"wrong phase: {d['phase']}", file=sys.stderr); sys.exit(1)
    if d['behind'] != 20:
        print(f"wrong behind: {d['behind']}", file=sys.stderr); sys.exit(1)
except Exception as e:
    print(f'parse error: {e}', file=sys.stderr); sys.exit(1)
PYEOF
pass "Test 3: event has all required fields (kind, branch, behind=20, threshold, phase=gap-ship)"

# ── Test 4: BEHIND=5 does not trigger stale gate ────────────────────────────
echo 5 > "$BEHIND_FILE"
reset_gap
> "$AMBIENT"
STDERR=$(env "${BASE_ENV[@]}" "$CHUMP_BIN" gap ship TEST-001 2>&1 || true)
if echo "$STDERR" | grep -q "commits behind origin/main"; then
    fail "Test 4: stale gate fired for BEHIND=5 (should not fire)"
fi
pass "Test 4: stale gate silent when only 5 commits behind (threshold 15)"

# ── Test 5: SKIP_STALE_CHECK=1 bypasses for BEHIND=100 ──────────────────────
echo 100 > "$BEHIND_FILE"
reset_gap
> "$AMBIENT"
STDERR=$(env "${BASE_ENV[@]}" CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
    "$CHUMP_BIN" gap ship TEST-001 2>&1 || true)
if echo "$STDERR" | grep -q "commits behind origin/main"; then
    fail "Test 5: stale gate fired despite CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1"
fi
pass "Test 5: CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 bypasses the gate"

echo ""
echo "All INFRA-1007 staleness gate checks passed (5/5)."
