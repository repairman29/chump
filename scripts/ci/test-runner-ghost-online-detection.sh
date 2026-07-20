#!/usr/bin/env bash
# test-runner-ghost-online-detection.sh — AC 6 smoke test for META-100/META-101
#
# Verifies that _detect_queue_saturation() fires kind=operator_recall
# with condition=RUNNERS_GHOSTED when:
#   - a fake .chump/github_cache.db has >= M (default 3) queued runs
#   - CHUMP_RUNNER_QUEUE_THRESHOLD_S=0 (every queued run is "old")
#   - each queued run's jobs target self-hosted labels
#   - the runners API mock returns 1 online+idle self-hosted runner
#
# Usage:
#   scripts/ci/test-runner-ghost-online-detection.sh
# Exit: 0 = pass, non-zero = fail

set -uo pipefail

SCRIPT_REPO_ROOT="${SCRIPT_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PASS=0
FAIL=0

_pass() { echo "[PASS] $1"; (( PASS++ )) || true; }
_fail() { echo "[FAIL] $1"; (( FAIL++ )) || true; }

# ── Temp workspace ────────────────────────────────────────────────────────────
_tmpdir="$(mktemp -d)"
trap 'rm -rf "$_tmpdir"' EXIT

_amb_log="$_tmpdir/ambient-$$.jsonl"
_fake_db="$_tmpdir/github_cache.db"

# ── Build fake SQLite cache with 3 queued runs (meets default M=3) ────────────
python3 - "$_fake_db" <<'PYEOF'
import sys, sqlite3
from datetime import datetime, timezone, timedelta

db_path = sys.argv[1]
conn = sqlite3.connect(db_path)
conn.execute("""
CREATE TABLE workflow_run_cache (
    run_id   INTEGER PRIMARY KEY,
    status   TEXT,
    created_at TEXT
)
""")
# 3 runs created 10 minutes ago — well past any threshold
old_ts = (datetime.now(timezone.utc) - timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ")
for run_id in (1, 2, 3):
    conn.execute("INSERT INTO workflow_run_cache VALUES (?, 'queued', ?)", (run_id, old_ts))
conn.commit()
conn.close()
PYEOF

# ── Mock gh CLI — jobs target self-hosted; 1 online+idle self-hosted runner ──
mkdir -p "$_tmpdir/bin"
cat > "$_tmpdir/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
# Minimal gh mock for RUNNERS_GHOSTED scenario.
if [[ "${*}" == *"actions/runners"* ]]; then
    echo '{"runners":[{"id":1,"name":"test-runner","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"macOS"}]}]}'
    exit 0
fi
if [[ "${*}" == *"/jobs"* ]]; then
    echo '{"jobs":[{"labels":["self-hosted","macOS"]}]}'
    exit 0
fi
echo '{"total_count":0,"workflow_runs":[]}'
exit 0
MOCKEOF
chmod +x "$_tmpdir/bin/gh"

# ── Patch .chump/github_cache.db location ────────────────────────────────────
# operator-recall.sh reads $REPO_ROOT/.chump/github_cache.db
mkdir -p "$_tmpdir/repo/.chump"
cp "$_fake_db" "$_tmpdir/repo/.chump/github_cache.db"
mkdir -p "$_tmpdir/repo/.chump-locks"

# ── Run operator-recall with queue-saturation detection forced ───────────────
export CHUMP_AMBIENT_LOG="$_amb_log"
export CHUMP_RUNNER_QUEUE_THRESHOLD_S=0       # every queued run is "old"
export CHUMP_RUNNER_GHOST_MIN_QUEUED=3
export CHUMP_RUNNER_GHOST_ONLINE_DETECT=1
export CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0  # no cooldown suppression in tests
export REPO_ROOT="$_tmpdir/repo"
export GITHUB_REPOSITORY="repairman29/chump"

# Add mock gh to PATH
export PATH="$_tmpdir/bin:$PATH"

bash "$SCRIPT_REPO_ROOT/scripts/dispatch/operator-recall.sh" 2>&1 || true

# ── Assert kind=operator_recall with condition=RUNNERS_GHOSTED ──────────────
if [[ ! -f "$_amb_log" ]]; then
    _fail "ambient log not created at $_amb_log"
else
    _recall_line=$(grep '"kind":"operator_recall"' "$_amb_log" 2>/dev/null | grep '"condition":"RUNNERS_GHOSTED"' || true)
    if [[ -n "$_recall_line" ]]; then
        _pass "kind=operator_recall with condition=RUNNERS_GHOSTED emitted"
    else
        _fail "kind=operator_recall condition=RUNNERS_GHOSTED NOT found in ambient log"
        echo "  ambient log contents:"
        cat "$_amb_log" 2>/dev/null | sed 's/^/    /' || echo "    (empty)"
    fi

    if echo "$_recall_line" | grep -q '"remediation":"restart the runner daemon'; then
        _pass "remediation field is restart-suggestion for RUNNERS_GHOSTED"
    else
        _fail "remediation field missing or wrong for RUNNERS_GHOSTED"
    fi

    # Also assert pre-detection event fired
    _detect_line=$(grep '"kind":"runner_ghost_online_detected"' "$_amb_log" 2>/dev/null || true)
    if [[ -n "$_detect_line" ]]; then
        _pass "kind=runner_ghost_online_detected pre-recall event emitted"
    else
        _fail "kind=runner_ghost_online_detected NOT found in ambient log"
    fi
fi

# ── AC 7 bypass: CHUMP_RUNNER_GHOST_ONLINE_DETECT=0 suppresses detection ─────
_amb_log2="$_tmpdir/ambient-disabled-$$.jsonl"
export CHUMP_AMBIENT_LOG="$_amb_log2"
export CHUMP_RUNNER_GHOST_ONLINE_DETECT=0

bash "$SCRIPT_REPO_ROOT/scripts/dispatch/operator-recall.sh" 2>&1 || true

_ghost_when_disabled=$(grep '"condition":"RUNNERS_GHOSTED"' "$_amb_log2" 2>/dev/null || true)
if [[ -z "$_ghost_when_disabled" ]]; then
    _pass "RUNNERS_GHOSTED suppressed when CHUMP_RUNNER_GHOST_ONLINE_DETECT=0"
else
    _fail "RUNNERS_GHOSTED fired even with CHUMP_RUNNER_GHOST_ONLINE_DETECT=0"
fi

# ── Below-threshold guard: only 1 queued run should NOT fire (M=3 default) ───
_amb_log3="$_tmpdir/ambient-belowmin-$$.jsonl"
_fake_db2="$_tmpdir/github_cache_below.db"
python3 - "$_fake_db2" <<'PYEOF'
import sys, sqlite3
from datetime import datetime, timezone, timedelta
db_path = sys.argv[1]
conn = sqlite3.connect(db_path)
conn.execute("CREATE TABLE workflow_run_cache (run_id INTEGER PRIMARY KEY, status TEXT, created_at TEXT)")
old_ts = (datetime.now(timezone.utc) - timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ")
conn.execute("INSERT INTO workflow_run_cache VALUES (1, 'queued', ?)", (old_ts,))
conn.commit()
conn.close()
PYEOF
cp "$_fake_db2" "$_tmpdir/repo/.chump/github_cache.db"
export CHUMP_AMBIENT_LOG="$_amb_log3"
export CHUMP_RUNNER_GHOST_ONLINE_DETECT=1
export CHUMP_RUNNER_GHOST_MIN_QUEUED=3

bash "$SCRIPT_REPO_ROOT/scripts/dispatch/operator-recall.sh" 2>&1 || true

if [[ ! -f "$_amb_log3" ]] || ! grep -q '"kind":"operator_recall"' "$_amb_log3" 2>/dev/null; then
    _pass "below-min-queued (1 < M=3) does not fire any operator_recall"
else
    _fail "below-min-queued incorrectly fired an operator_recall"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
