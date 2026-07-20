#!/usr/bin/env bash
# test-operator-recall-queue-saturated.sh — META-101 AC 6 smoke test.
#
# Verifies _detect_runner_ghost_online() correctly subclassifies QUEUE_SATURATED
# by sampling job runs-on labels instead of assuming every ghost-online contradiction
# is a runner problem:
#
#   Scenario 1 (RUNNERS_GHOSTED): self-hosted runner is online+idle AND the sampled
#     queued job targets the "self-hosted" label -> restart-the-runner is the fix.
#
#   Scenario 2 (QUEUE_SATURATED_GH_HOSTED): a self-hosted runner is online+idle
#     (a red herring) BUT the sampled queued job targets "ubuntu-latest" (GH-hosted)
#     -> GH-hosted concurrency quota is exhausted; no restart will fix this.
#
# Usage:
#   scripts/ci/test-operator-recall-queue-saturated.sh
# Exit: 0 = pass, non-zero = fail

set -uo pipefail

SCRIPT_REPO_ROOT="${SCRIPT_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PASS=0
FAIL=0

_pass() { echo "[PASS] $1"; (( PASS++ )) || true; }
_fail() { echo "[FAIL] $1"; (( FAIL++ )) || true; }

_build_fake_db() {
    local db_path="$1"
    python3 - "$db_path" <<'PYEOF'
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
old_ts = (datetime.now(timezone.utc) - timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ")
conn.execute("INSERT INTO workflow_run_cache VALUES (1, 'queued', ?)", (old_ts,))
conn.commit()
conn.close()
PYEOF
}

# ── Scenario 1: self-hosted idle + jobs target self-hosted -> RUNNERS_GHOSTED ──

echo "Scenario 1: self-hosted idle + jobs target self-hosted labels..."

_tmp1="$(mktemp -d)"
_amb1="$_tmp1/ambient.jsonl"
mkdir -p "$_tmp1/repo/.chump" "$_tmp1/repo/.chump-locks"
_build_fake_db "$_tmp1/repo/.chump/github_cache.db"

mkdir -p "$_tmp1/bin"
cat > "$_tmp1/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${*}" == *"actions/runners"* ]]; then
    echo '{"runners":[{"id":1,"name":"test-runner","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"macOS"}]}]}'
    exit 0
fi
if [[ "${*}" == *"actions/runs/1/jobs"* ]]; then
    echo '{"jobs":[{"labels":["self-hosted","macOS"]}]}'
    exit 0
fi
echo '{"total_count":0,"workflow_runs":[]}'
exit 0
MOCKEOF
chmod +x "$_tmp1/bin/gh"

CHUMP_AMBIENT_LOG="$_amb1" \
CHUMP_RUNNER_QUEUE_THRESHOLD_S=0 \
CHUMP_QUEUE_SATURATED_MIN_RUNS=1 \
CHUMP_RUNNER_GHOST_ONLINE_DETECT=1 \
CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0 \
REPO_ROOT="$_tmp1/repo" \
GITHUB_REPOSITORY="repairman29/chump" \
PATH="$_tmp1/bin:$PATH" \
bash "$SCRIPT_REPO_ROOT/scripts/dispatch/operator-recall.sh" >/dev/null 2>&1 || true

if grep -q '"kind":"operator_recall".*"condition":"RUNNERS_GHOSTED"' "$_amb1" 2>/dev/null; then
    _pass "scenario 1: RUNNERS_GHOSTED fired"
else
    _fail "scenario 1: RUNNERS_GHOSTED NOT found in ambient log"
    cat "$_amb1" 2>/dev/null | sed 's/^/    /'
fi

if grep -q '"condition":"QUEUE_SATURATED_GH_HOSTED"' "$_amb1" 2>/dev/null; then
    _fail "scenario 1: QUEUE_SATURATED_GH_HOSTED incorrectly fired alongside RUNNERS_GHOSTED"
else
    _pass "scenario 1: QUEUE_SATURATED_GH_HOSTED correctly did not fire"
fi

rm -rf "$_tmp1"

# ── Scenario 2: GH-hosted queue saturated, self-hosted idle is a red herring ────

echo "Scenario 2: GH-hosted (ubuntu-latest) queue saturated..."

_tmp2="$(mktemp -d)"
_amb2="$_tmp2/ambient.jsonl"
mkdir -p "$_tmp2/repo/.chump" "$_tmp2/repo/.chump-locks"
_build_fake_db "$_tmp2/repo/.chump/github_cache.db"

mkdir -p "$_tmp2/bin"
cat > "$_tmp2/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${*}" == *"actions/runners"* ]]; then
    echo '{"runners":[{"id":1,"name":"test-runner","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"macOS"}]}]}'
    exit 0
fi
if [[ "${*}" == *"actions/runs/1/jobs"* ]]; then
    echo '{"jobs":[{"labels":["ubuntu-latest"]}]}'
    exit 0
fi
echo '{"total_count":0,"workflow_runs":[]}'
exit 0
MOCKEOF
chmod +x "$_tmp2/bin/gh"

CHUMP_AMBIENT_LOG="$_amb2" \
CHUMP_RUNNER_QUEUE_THRESHOLD_S=0 \
CHUMP_QUEUE_SATURATED_MIN_RUNS=1 \
CHUMP_RUNNER_GHOST_ONLINE_DETECT=1 \
CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0 \
REPO_ROOT="$_tmp2/repo" \
GITHUB_REPOSITORY="repairman29/chump" \
PATH="$_tmp2/bin:$PATH" \
bash "$SCRIPT_REPO_ROOT/scripts/dispatch/operator-recall.sh" >/dev/null 2>&1 || true

_qs_line=$(grep '"kind":"operator_recall"' "$_amb2" 2>/dev/null | grep '"condition":"QUEUE_SATURATED_GH_HOSTED"' || true)
if [[ -n "$_qs_line" ]]; then
    _pass "scenario 2: QUEUE_SATURATED_GH_HOSTED fired"
    if echo "$_qs_line" | grep -q "no-restart-fix"; then
        _pass "scenario 2: reason includes no-restart-fix remediation text"
    else
        _fail "scenario 2: reason missing no-restart-fix remediation text"
    fi
else
    _fail "scenario 2: QUEUE_SATURATED_GH_HOSTED NOT found in ambient log"
    cat "$_amb2" 2>/dev/null | sed 's/^/    /'
fi

if grep -q '"condition":"RUNNERS_GHOSTED"' "$_amb2" 2>/dev/null; then
    _fail "scenario 2: RUNNERS_GHOSTED incorrectly fired for a GH-hosted job"
else
    _pass "scenario 2: RUNNERS_GHOSTED correctly did not fire"
fi

rm -rf "$_tmp2"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
