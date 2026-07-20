#!/usr/bin/env bash
# test-operator-recall-queue-saturated.sh — AC 6 smoke test for META-101
#
# Two stubbed scenarios against scripts/dispatch/operator-recall.sh's
# _detect_queue_saturation():
#   1. self-hosted runner idle + jobs target self-hosted labels
#        -> asserts condition=RUNNERS_GHOSTED
#   2. GitHub-hosted (ubuntu-latest) queue + self-hosted runner idle but
#      jobs target ubuntu-latest, not self-hosted
#        -> asserts condition=QUEUE_SATURATED_GH_HOSTED + no-restart-fix text
#
# Usage:
#   scripts/ci/test-operator-recall-queue-saturated.sh
# Exit: 0 = pass, non-zero = fail

set -uo pipefail

SCRIPT_REPO_ROOT="${SCRIPT_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
RECALL_SCRIPT="$SCRIPT_REPO_ROOT/scripts/dispatch/operator-recall.sh"
PASS=0
FAIL=0

_pass() { echo "[PASS] $1"; (( PASS++ )) || true; }
_fail() { echo "[FAIL] $1"; (( FAIL++ )) || true; }

_seed_queued_runs() {
    # $1 = db path; seeds 3 queued runs (run_id 1,2,3), all stale.
    local db_path="$1"
    python3 - "$db_path" <<'PYEOF'
import sys, sqlite3
from datetime import datetime, timezone, timedelta
db_path = sys.argv[1]
conn = sqlite3.connect(db_path)
conn.execute("CREATE TABLE workflow_run_cache (run_id INTEGER PRIMARY KEY, status TEXT, created_at TEXT)")
old_ts = (datetime.now(timezone.utc) - timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ")
for run_id in (1, 2, 3):
    conn.execute("INSERT INTO workflow_run_cache VALUES (?, 'queued', ?)", (run_id, old_ts))
conn.commit()
conn.close()
PYEOF
}

# ══════════════════════════════════════════════════════════════════════════
# Scenario 1: self-hosted idle + jobs target self-hosted -> RUNNERS_GHOSTED
# ══════════════════════════════════════════════════════════════════════════
echo "Scenario 1: self-hosted idle + jobs target self-hosted labels..."
_dir1="$(mktemp -d)"
trap 'rm -rf "$_dir1"' RETURN

_amb1="$_dir1/ambient.jsonl"
mkdir -p "$_dir1/repo/.chump" "$_dir1/repo/.chump-locks" "$_dir1/bin"
_seed_queued_runs "$_dir1/repo/.chump/github_cache.db"

cat > "$_dir1/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${*}" == *"actions/runners"* ]]; then
    echo '{"runners":[{"id":1,"name":"self-hosted-1","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"macOS"}]}]}'
    exit 0
fi
if [[ "${*}" == *"/jobs"* ]]; then
    echo '{"jobs":[{"labels":["self-hosted","macOS"]}]}'
    exit 0
fi
echo '{"total_count":0,"workflow_runs":[]}'
exit 0
MOCKEOF
chmod +x "$_dir1/bin/gh"

PATH="$_dir1/bin:$PATH" \
CHUMP_AMBIENT_LOG="$_amb1" \
CHUMP_RUNNER_QUEUE_THRESHOLD_S=0 \
CHUMP_RUNNER_GHOST_MIN_QUEUED=3 \
CHUMP_RUNNER_GHOST_ONLINE_DETECT=1 \
CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0 \
REPO_ROOT="$_dir1/repo" \
GITHUB_REPOSITORY="repairman29/chump" \
bash "$RECALL_SCRIPT" 2>&1 || true

if grep -q '"kind":"operator_recall"' "$_amb1" 2>/dev/null && \
   grep '"kind":"operator_recall"' "$_amb1" | grep -q '"condition":"RUNNERS_GHOSTED"'; then
    _pass "Scenario 1: condition=RUNNERS_GHOSTED emitted"
else
    _fail "Scenario 1: RUNNERS_GHOSTED not emitted"
    cat "$_amb1" 2>/dev/null | sed 's/^/    /'
fi

if grep '"condition":"RUNNERS_GHOSTED"' "$_amb1" 2>/dev/null | grep -q 'restart the runner daemon'; then
    _pass "Scenario 1: remediation is restart-suggestion"
else
    _fail "Scenario 1: remediation missing/wrong for RUNNERS_GHOSTED"
fi

if grep -q '"condition":"QUEUE_SATURATED_GH_HOSTED"' "$_amb1" 2>/dev/null; then
    _fail "Scenario 1: QUEUE_SATURATED_GH_HOSTED incorrectly also fired"
else
    _pass "Scenario 1: QUEUE_SATURATED_GH_HOSTED did not fire"
fi

trap - RETURN
rm -rf "$_dir1"

# ══════════════════════════════════════════════════════════════════════════
# Scenario 2: ubuntu-latest queue + self-hosted idle, jobs target ubuntu-latest
#             -> QUEUE_SATURATED_GH_HOSTED + no-restart-fix text
# ══════════════════════════════════════════════════════════════════════════
echo "Scenario 2: GH-hosted (ubuntu-latest) queue with idle self-hosted runner present..."
_dir2="$(mktemp -d)"
trap 'rm -rf "$_dir2"' RETURN

_amb2="$_dir2/ambient.jsonl"
mkdir -p "$_dir2/repo/.chump" "$_dir2/repo/.chump-locks" "$_dir2/bin"
_seed_queued_runs "$_dir2/repo/.chump/github_cache.db"

cat > "$_dir2/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${*}" == *"actions/runners"* ]]; then
    echo '{"runners":[{"id":1,"name":"self-hosted-1","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"macOS"}]}]}'
    exit 0
fi
if [[ "${*}" == *"/jobs"* ]]; then
    echo '{"jobs":[{"labels":["ubuntu-latest"]}]}'
    exit 0
fi
echo '{"total_count":0,"workflow_runs":[]}'
exit 0
MOCKEOF
chmod +x "$_dir2/bin/gh"

PATH="$_dir2/bin:$PATH" \
CHUMP_AMBIENT_LOG="$_amb2" \
CHUMP_RUNNER_QUEUE_THRESHOLD_S=0 \
CHUMP_RUNNER_GHOST_MIN_QUEUED=3 \
CHUMP_RUNNER_GHOST_ONLINE_DETECT=1 \
CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0 \
REPO_ROOT="$_dir2/repo" \
GITHUB_REPOSITORY="repairman29/chump" \
bash "$RECALL_SCRIPT" 2>&1 || true

if grep -q '"kind":"operator_recall"' "$_amb2" 2>/dev/null && \
   grep '"kind":"operator_recall"' "$_amb2" | grep -q '"condition":"QUEUE_SATURATED_GH_HOSTED"'; then
    _pass "Scenario 2: condition=QUEUE_SATURATED_GH_HOSTED emitted"
else
    _fail "Scenario 2: QUEUE_SATURATED_GH_HOSTED not emitted"
    cat "$_amb2" 2>/dev/null | sed 's/^/    /'
fi

if grep '"condition":"QUEUE_SATURATED_GH_HOSTED"' "$_amb2" 2>/dev/null | grep -q 'no-restart-fix'; then
    _pass "Scenario 2: remediation contains no-restart-fix text"
else
    _fail "Scenario 2: remediation missing/wrong for QUEUE_SATURATED_GH_HOSTED"
fi

if grep -q '"condition":"RUNNERS_GHOSTED"' "$_amb2" 2>/dev/null; then
    _fail "Scenario 2: RUNNERS_GHOSTED incorrectly also fired"
else
    _pass "Scenario 2: RUNNERS_GHOSTED did not fire"
fi

trap - RETURN
rm -rf "$_dir2"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
