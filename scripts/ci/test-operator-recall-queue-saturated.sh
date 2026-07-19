#!/usr/bin/env bash
# test-operator-recall-queue-saturated.sh — AC 6 smoke test for META-101
#
# Verifies _detect_runner_ghost_online() in scripts/dispatch/operator-recall.sh
# correctly splits the old single RUNNER_GHOST_ONLINE contradiction into two
# subclasses based on the runs-on label of the queued jobs:
#
#   Scenario 1 — self-hosted idle runner + queued job targets "self-hosted"
#                labels -> condition=RUNNERS_GHOSTED
#   Scenario 2 — self-hosted idle runner present, but queued job targets a
#                GitHub-hosted label (ubuntu-latest) -> condition=
#                QUEUE_SATURATED_GH_HOSTED with a no-restart-fix remediation
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

_make_cache_db() {
    # $1 = db path
    python3 - "$1" <<'PYEOF'
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
conn.execute("INSERT INTO workflow_run_cache VALUES (42, 'queued', ?)", (old_ts,))
conn.commit()
conn.close()
PYEOF
}

# ── Scenario 1: self-hosted idle runner, jobs target self-hosted labels ──────
run_scenario_1() {
    local _tmpdir; _tmpdir="$(mktemp -d)"
    local _amb_log="$_tmpdir/ambient.jsonl"

    _make_cache_db "$_tmpdir/github_cache.db"
    mkdir -p "$_tmpdir/repo/.chump" "$_tmpdir/repo/.chump-locks"
    cp "$_tmpdir/github_cache.db" "$_tmpdir/repo/.chump/github_cache.db"

    mkdir -p "$_tmpdir/bin"
    cat > "$_tmpdir/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${*}" == *"actions/runners"* ]]; then
    echo '{"runners":[{"id":1,"name":"test-runner","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"macOS"}]}]}'
    exit 0
fi
if [[ "${*}" == *"actions/runs/42/jobs"* ]]; then
    echo '{"jobs":[{"id":1,"labels":["self-hosted","macOS"]}]}'
    exit 0
fi
echo '{"total_count":0,"workflow_runs":[]}'
exit 0
MOCKEOF
    chmod +x "$_tmpdir/bin/gh"

    (
        export CHUMP_AMBIENT_LOG="$_amb_log"
        export CHUMP_RUNNER_QUEUE_THRESHOLD_S=0
        export CHUMP_RUNNER_GHOST_ONLINE_DETECT=1
        export CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0
        export REPO_ROOT="$_tmpdir/repo"
        export GITHUB_REPOSITORY="repairman29/chump"
        export PATH="$_tmpdir/bin:$PATH"
        bash "$SCRIPT_REPO_ROOT/scripts/dispatch/operator-recall.sh" >/dev/null 2>&1 || true
    )

    if grep -q '"kind":"operator_recall".*"condition":"RUNNERS_GHOSTED"' "$_amb_log" 2>/dev/null; then
        _pass "scenario 1: self-hosted-targeted queued job -> condition=RUNNERS_GHOSTED"
    else
        _fail "scenario 1: expected condition=RUNNERS_GHOSTED not found"
        cat "$_amb_log" 2>/dev/null | sed 's/^/    /'
    fi

    rm -rf "$_tmpdir"
}

# ── Scenario 2: idle self-hosted runner present, jobs target ubuntu-latest ──
run_scenario_2() {
    local _tmpdir; _tmpdir="$(mktemp -d)"
    local _amb_log="$_tmpdir/ambient.jsonl"

    _make_cache_db "$_tmpdir/github_cache.db"
    mkdir -p "$_tmpdir/repo/.chump" "$_tmpdir/repo/.chump-locks"
    cp "$_tmpdir/github_cache.db" "$_tmpdir/repo/.chump/github_cache.db"

    mkdir -p "$_tmpdir/bin"
    cat > "$_tmpdir/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${*}" == *"actions/runners"* ]]; then
    echo '{"runners":[{"id":1,"name":"test-runner","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"macOS"}]}]}'
    exit 0
fi
if [[ "${*}" == *"actions/runs/42/jobs"* ]]; then
    echo '{"jobs":[{"id":1,"labels":["ubuntu-latest"]}]}'
    exit 0
fi
echo '{"total_count":0,"workflow_runs":[]}'
exit 0
MOCKEOF
    chmod +x "$_tmpdir/bin/gh"

    (
        export CHUMP_AMBIENT_LOG="$_amb_log"
        export CHUMP_RUNNER_QUEUE_THRESHOLD_S=0
        export CHUMP_RUNNER_GHOST_ONLINE_DETECT=1
        export CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0
        export REPO_ROOT="$_tmpdir/repo"
        export GITHUB_REPOSITORY="repairman29/chump"
        export PATH="$_tmpdir/bin:$PATH"
        bash "$SCRIPT_REPO_ROOT/scripts/dispatch/operator-recall.sh" >/dev/null 2>&1 || true
    )

    if grep -q '"kind":"operator_recall".*"condition":"QUEUE_SATURATED_GH_HOSTED"' "$_amb_log" 2>/dev/null; then
        _pass "scenario 2: GH-hosted-targeted queued job -> condition=QUEUE_SATURATED_GH_HOSTED"
    else
        _fail "scenario 2: expected condition=QUEUE_SATURATED_GH_HOSTED not found"
        cat "$_amb_log" 2>/dev/null | sed 's/^/    /'
    fi

    if grep -q '"condition":"QUEUE_SATURATED_GH_HOSTED".*no-restart-fix' "$_amb_log" 2>/dev/null; then
        _pass "scenario 2: reason includes no-restart-fix remediation text"
    else
        _fail "scenario 2: reason missing no-restart-fix remediation text"
    fi

    rm -rf "$_tmpdir"
}

run_scenario_1
run_scenario_2

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
