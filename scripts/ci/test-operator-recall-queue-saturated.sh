#!/usr/bin/env bash
# test-operator-recall-queue-saturated.sh — AC 6 smoke test for META-101
#
# Verifies the QUEUE_SATURATED detector's two-subclass classification in
# scripts/dispatch/operator-recall.sh:
#
#   Scenario 1: self-hosted runner online+idle AND queued jobs target
#               self-hosted labels -> condition=RUNNERS_GHOSTED
#   Scenario 2: self-hosted runner online+idle (a red herring) BUT queued
#               jobs target a GitHub-hosted label (ubuntu-latest) ->
#               condition=QUEUE_SATURATED_GH_HOSTED with no-restart-fix text
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

_tmpdir="$(mktemp -d)"
trap 'rm -rf "$_tmpdir"' EXIT

_make_cache_db() {
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
for rid in (101, 102, 103):
    conn.execute("INSERT INTO workflow_run_cache VALUES (?, 'queued', ?)", (rid, old_ts))
conn.commit()
conn.close()
PYEOF
}

_common_env() {
    local amb="$1" repo="$2"
    export CHUMP_AMBIENT_LOG="$amb"
    export CHUMP_RUNNER_QUEUE_THRESHOLD_S=0
    export CHUMP_RUNNER_QUEUE_MIN_COUNT=3
    export CHUMP_RUNNER_GHOST_ONLINE_DETECT=1
    export CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0
    export REPO_ROOT="$repo"
    export GITHUB_REPOSITORY="repairman29/chump"
}

# ── Scenario 1: self-hosted idle + jobs target self-hosted labels ────────────
echo "Scenario 1: self-hosted runner idle, jobs target self-hosted labels..."
_s1="$_tmpdir/s1"
mkdir -p "$_s1/repo/.chump" "$_s1/repo/.chump-locks" "$_s1/bin"
_make_cache_db "$_s1/repo/.chump/github_cache.db"

cat > "$_s1/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${*}" == *"actions/runners"* ]]; then
    echo '{"runners":[{"id":1,"name":"r1","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"macOS"}]}]}'
    exit 0
fi
if [[ "${*}" == *"actions/runs/"*"/jobs"* ]]; then
    echo '{"jobs":[{"status":"queued","labels":["self-hosted","macOS"]}]}'
    exit 0
fi
echo '{"total_count":0,"workflow_runs":[]}'
exit 0
MOCKEOF
chmod +x "$_s1/bin/gh"

_amb1="$_s1/ambient.jsonl"
_common_env "$_amb1" "$_s1/repo"
PATH="$_s1/bin:$PATH" bash "$RECALL_SCRIPT" 2>&1 || true

_line1=$(grep '"kind":"operator_recall"' "$_amb1" 2>/dev/null | grep '"condition":"RUNNERS_GHOSTED"' || true)
if [[ -n "$_line1" ]]; then
    _pass "Scenario 1: condition=RUNNERS_GHOSTED emitted"
else
    _fail "Scenario 1: condition=RUNNERS_GHOSTED NOT found"
    cat "$_amb1" 2>/dev/null | sed 's/^/    /'
fi
if echo "$_line1" | grep -q '"remediation":"launchctl restart'; then
    _pass "Scenario 1: remediation mentions launchctl restart"
else
    _fail "Scenario 1: remediation missing launchctl restart text"
fi

# ── Scenario 2: GH-hosted queue targeted; self-hosted idle but unrelated ─────
echo "Scenario 2: GH-hosted (ubuntu-latest) queue saturated..."
_s2="$_tmpdir/s2"
mkdir -p "$_s2/repo/.chump" "$_s2/repo/.chump-locks" "$_s2/bin"
_make_cache_db "$_s2/repo/.chump/github_cache.db"

cat > "$_s2/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${*}" == *"actions/runners"* ]]; then
    echo '{"runners":[{"id":1,"name":"r1","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"macOS"}]}]}'
    exit 0
fi
if [[ "${*}" == *"actions/runs/"*"/jobs"* ]]; then
    echo '{"jobs":[{"status":"queued","labels":["ubuntu-latest"]}]}'
    exit 0
fi
echo '{"total_count":0,"workflow_runs":[]}'
exit 0
MOCKEOF
chmod +x "$_s2/bin/gh"

_amb2="$_s2/ambient.jsonl"
_common_env "$_amb2" "$_s2/repo"
PATH="$_s2/bin:$PATH" bash "$RECALL_SCRIPT" 2>&1 || true

_line2=$(grep '"kind":"operator_recall"' "$_amb2" 2>/dev/null | grep '"condition":"QUEUE_SATURATED_GH_HOSTED"' || true)
if [[ -n "$_line2" ]]; then
    _pass "Scenario 2: condition=QUEUE_SATURATED_GH_HOSTED emitted"
else
    _fail "Scenario 2: condition=QUEUE_SATURATED_GH_HOSTED NOT found"
    cat "$_amb2" 2>/dev/null | sed 's/^/    /'
fi
if echo "$_line2" | grep -q 'no-restart-fix'; then
    _pass "Scenario 2: remediation contains no-restart-fix text"
else
    _fail "Scenario 2: remediation missing no-restart-fix text"
fi
if echo "$_line2" | grep -q '"runs_on_labels":\["ubuntu-latest"\]'; then
    _pass "Scenario 2: runs_on_labels lists ubuntu-latest"
else
    _fail "Scenario 2: runs_on_labels missing ubuntu-latest"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
