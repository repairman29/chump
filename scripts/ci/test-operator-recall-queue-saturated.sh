#!/usr/bin/env bash
# test-operator-recall-queue-saturated.sh — AC 6 smoke test for META-101
#
# Verifies the QUEUE_SATURATED subclass detector in operator-recall.sh:
#   Scenario 1 — self-hosted runner online+idle AND queued job targets
#                self-hosted labels -> class=RUNNERS_GHOSTED
#   Scenario 2 — GitHub-hosted queue (job targets ubuntu-latest) while a
#                self-hosted runner sits idle but jobs don't target it ->
#                class=QUEUE_SATURATED_GH_HOSTED + no-restart-fix remediation
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
conn.execute("INSERT INTO workflow_run_cache VALUES (42, 'queued', ?)", (old_ts,))
conn.commit()
conn.close()
PYEOF
}

# ── Scenario 1: RUNNERS_GHOSTED ────────────────────────────────────────────────
_scenario1() {
    local wd="$_tmpdir/s1"
    mkdir -p "$wd/repo/.chump" "$wd/repo/.chump-locks" "$wd/bin"
    _make_cache_db "$wd/repo/.chump/github_cache.db"

    cat > "$wd/bin/gh" <<'MOCKEOF'
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
    chmod +x "$wd/bin/gh"

    local amb="$wd/ambient.jsonl"
    CHUMP_AMBIENT_LOG="$amb" \
    CHUMP_RUNNER_QUEUE_THRESHOLD_S=0 \
    CHUMP_RUNNER_GHOST_ONLINE_DETECT=1 \
    CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0 \
    REPO_ROOT="$wd/repo" \
    GITHUB_REPOSITORY="repairman29/chump" \
    PATH="$wd/bin:$PATH" \
    bash "$SCRIPT_REPO_ROOT/scripts/dispatch/operator-recall.sh" >/dev/null 2>&1 || true

    if [[ -f "$amb" ]] && grep -q '"condition":"RUNNER_GHOST_ONLINE".*"class":"RUNNERS_GHOSTED"' "$amb"; then
        _pass "scenario 1: class=RUNNERS_GHOSTED emitted for self-hosted idle+matching"
    else
        _fail "scenario 1: class=RUNNERS_GHOSTED NOT found"
        cat "$amb" 2>/dev/null | sed 's/^/    /' || echo "    (no ambient log)"
    fi

    if grep -q '"class":"RUNNERS_GHOSTED"' "$amb" 2>/dev/null && grep '"class":"RUNNERS_GHOSTED"' "$amb" | grep -q "launchctl restart"; then
        _pass "scenario 1: remediation mentions launchctl restart"
    else
        _fail "scenario 1: remediation missing launchctl restart text"
    fi
}

# ── Scenario 2: QUEUE_SATURATED_GH_HOSTED ──────────────────────────────────────
_scenario2() {
    local wd="$_tmpdir/s2"
    mkdir -p "$wd/repo/.chump" "$wd/repo/.chump-locks" "$wd/bin"
    _make_cache_db "$wd/repo/.chump/github_cache.db"

    cat > "$wd/bin/gh" <<'MOCKEOF'
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
    chmod +x "$wd/bin/gh"

    local amb="$wd/ambient.jsonl"
    CHUMP_AMBIENT_LOG="$amb" \
    CHUMP_RUNNER_QUEUE_THRESHOLD_S=0 \
    CHUMP_RUNNER_GHOST_ONLINE_DETECT=1 \
    CHUMP_OPERATOR_RECALL_COOLDOWN_SECS=0 \
    REPO_ROOT="$wd/repo" \
    GITHUB_REPOSITORY="repairman29/chump" \
    PATH="$wd/bin:$PATH" \
    bash "$SCRIPT_REPO_ROOT/scripts/dispatch/operator-recall.sh" >/dev/null 2>&1 || true

    if [[ -f "$amb" ]] && grep -q '"condition":"RUNNER_GHOST_ONLINE".*"class":"QUEUE_SATURATED_GH_HOSTED"' "$amb"; then
        _pass "scenario 2: class=QUEUE_SATURATED_GH_HOSTED emitted for GH-hosted queue"
    else
        _fail "scenario 2: class=QUEUE_SATURATED_GH_HOSTED NOT found"
        cat "$amb" 2>/dev/null | sed 's/^/    /' || echo "    (no ambient log)"
    fi

    if grep '"class":"QUEUE_SATURATED_GH_HOSTED"' "$amb" 2>/dev/null | grep -q "no-restart-fix"; then
        _pass "scenario 2: remediation contains no-restart-fix text"
    else
        _fail "scenario 2: remediation missing no-restart-fix text"
    fi

    if grep '"class":"QUEUE_SATURATED_GH_HOSTED"' "$amb" 2>/dev/null | grep -q "ubuntu-latest"; then
        _pass "scenario 2: reason lists affected runs_on_labels (ubuntu-latest)"
    else
        _fail "scenario 2: reason does not list runs_on_labels"
    fi

    if grep -q '"class":"RUNNERS_GHOSTED"' "$amb" 2>/dev/null; then
        _fail "scenario 2: RUNNERS_GHOSTED incorrectly fired for a GH-hosted-only queue"
    else
        _pass "scenario 2: RUNNERS_GHOSTED correctly did NOT fire"
    fi
}

_scenario1
_scenario2

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
