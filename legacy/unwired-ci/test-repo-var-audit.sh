#!/usr/bin/env bash
# scripts/ci/test-repo-var-audit.sh — CI gate for INFRA-1976 repo-var audit
#
# Tests the check-repo-vars step in infra-watcher-loop.sh by mocking
# gh variable list output and asserting:
#   (a) matching variable → no event emitted
#   (b) fresh mismatch → divergence recorded in state file, no event yet
#   (c) stale mismatch (>2h) → kind=repo_var_stale_after_incident emitted
#   (d) recovered variable → state file entry cleared, no event emitted

set -euo pipefail

PASS=0
FAIL=0

_pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── Test harness setup ────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INFRA_WATCHER="${REPO_ROOT}/scripts/coord/infra-watcher-loop.sh"

# Workspace for all temp files
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FAKE_REPO_ROOT="${TMPDIR_TEST}/repo"
mkdir -p "${FAKE_REPO_ROOT}/.chump-locks"
mkdir -p "${FAKE_REPO_ROOT}/scripts/setup"

AMBIENT_LOG="${FAKE_REPO_ROOT}/.chump-locks/ambient.jsonl"
STATE_FILE="${FAKE_REPO_ROOT}/.chump-locks/repo-var-divergence-state.json"

# Copy expected-repo-vars.yaml into the fake repo root
cp "${REPO_ROOT}/scripts/setup/expected-repo-vars.yaml" \
   "${FAKE_REPO_ROOT}/scripts/setup/expected-repo-vars.yaml"

mkdir -p "${TMPDIR_TEST}/bin"

# Helper: run check-repo-vars with a mocked gh variable list command
# $1 = JSON array to return from gh variable list
# $2 = optional: pre-existing state JSON (defaults to {})
run_check() {
    local mock_vars_json="$1"
    local initial_state
    initial_state="${2:-}"
    [[ -z "$initial_state" ]] && initial_state="{}"

    # Write initial state
    printf '%s\n' "$initial_state" > "$STATE_FILE"
    # Clear ambient log
    > "$AMBIENT_LOG"

    # Write mock gh script — handles: variable list --repo <slug> --json name,value
    local fake_gh="${TMPDIR_TEST}/bin/gh"
    # Store json in a temp file to avoid quoting complexity inside the heredoc
    local json_file="${TMPDIR_TEST}/mock_vars.json"
    printf '%s\n' "$mock_vars_json" > "$json_file"
    cat > "$fake_gh" <<GHEOF
#!/usr/bin/env bash
# Mock gh: intercept variable list, pass everything else through
if [[ "\${1:-}" == "variable" && "\${2:-}" == "list" ]]; then
    cat "${json_file}"
    exit 0
fi
exit 0
GHEOF
    chmod +x "$fake_gh"

    PATH="${TMPDIR_TEST}/bin:$PATH" \
    REPO_ROOT="$FAKE_REPO_ROOT" \
    CHUMP_GH_BIN="$fake_gh" \
    CHUMP_INFRA_WATCHER_REPO_SLUG="repairman29/Chump" \
        bash "$INFRA_WATCHER" check-repo-vars 2>&1 || true
}

# ── Test A: variable matches expected → no event ─────────────────────────────
printf '\n--- Test A: matching variable → no event ---\n'
run_check '[{"name":"CHUMP_SELF_HOSTED_ENABLED","value":"true"}]'

if grep -q "repo_var_stale_after_incident" "$AMBIENT_LOG" 2>/dev/null; then
    _fail "A: event emitted when variable matches expected (no event expected)"
else
    _pass "A: no event emitted for matching variable"
fi

if [[ -f "$STATE_FILE" ]]; then
    state_content="$(cat "$STATE_FILE")"
    if python3 -c "import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if 'CHUMP_SELF_HOSTED_ENABLED' not in d else 1)" <<< "$state_content" 2>/dev/null; then
        _pass "A: state file has no divergence entry for matching variable"
    else
        _fail "A: state file unexpectedly contains divergence entry for matching variable"
    fi
fi

# ── Test B: fresh mismatch → state recorded, no event yet ────────────────────
printf '\n--- Test B: fresh mismatch → state recorded, no event ---\n'
run_check '[{"name":"CHUMP_SELF_HOSTED_ENABLED","value":"false"}]'

if grep -q "repo_var_stale_after_incident" "$AMBIENT_LOG" 2>/dev/null; then
    _fail "B: event emitted for fresh mismatch (should wait for drift threshold)"
else
    _pass "B: no event emitted for fresh mismatch (within 2h window)"
fi

if [[ -f "$STATE_FILE" ]]; then
    state_b="$(cat "$STATE_FILE")"
    if python3 -c "import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if 'CHUMP_SELF_HOSTED_ENABLED' in d else 1)" <<< "$state_b" 2>/dev/null; then
        _pass "B: divergence entry recorded in state file"
    else
        _fail "B: divergence entry NOT recorded in state file"
    fi
fi

# ── Test C: stale mismatch (first_seen >2h ago) → event emitted ──────────────
printf '\n--- Test C: stale mismatch (>2h) → event emitted ---\n'
# Inject a first_seen_epoch 3 hours ago
three_hours_ago=$(( $(date -u +%s) - 10800 ))
stale_state=$(python3 -c "
import json
print(json.dumps({'CHUMP_SELF_HOSTED_ENABLED': {
    'first_seen_epoch': ${three_hours_ago},
    'expected': 'true',
    'actual': 'false'
}}))
")

run_check '[{"name":"CHUMP_SELF_HOSTED_ENABLED","value":"false"}]' "$stale_state"

if grep -q "repo_var_stale_after_incident" "$AMBIENT_LOG" 2>/dev/null; then
    _pass "C: kind=repo_var_stale_after_incident emitted for stale mismatch"
else
    _fail "C: no event emitted for stale mismatch (expected event after >2h drift)"
fi

# Verify event fields
if grep -q '"var_name":"CHUMP_SELF_HOSTED_ENABLED"' "$AMBIENT_LOG" 2>/dev/null; then
    _pass "C: event contains correct var_name field"
else
    _fail "C: event missing var_name field"
fi

if grep -q '"expected_value":"true"' "$AMBIENT_LOG" 2>/dev/null; then
    _pass "C: event contains correct expected_value field"
else
    _fail "C: event missing expected_value field"
fi

if grep -q '"actual_value":"false"' "$AMBIENT_LOG" 2>/dev/null; then
    _pass "C: event contains correct actual_value field"
else
    _fail "C: event missing actual_value field"
fi

if grep -q '"diverged_since"' "$AMBIENT_LOG" 2>/dev/null; then
    _pass "C: event contains diverged_since field"
else
    _fail "C: event missing diverged_since field"
fi

# ── Test D: variable recovered → state entry cleared, no new event ────────────
printf '\n--- Test D: recovered variable → state cleared, no new event ---\n'
# Start with a divergence in state but variable now matches
prior_divergence=$(python3 -c "
import json
print(json.dumps({'CHUMP_SELF_HOSTED_ENABLED': {
    'first_seen_epoch': ${three_hours_ago},
    'expected': 'true',
    'actual': 'false'
}}))
")

run_check '[{"name":"CHUMP_SELF_HOSTED_ENABLED","value":"true"}]' "$prior_divergence"

if grep -q "repo_var_stale_after_incident" "$AMBIENT_LOG" 2>/dev/null; then
    _fail "D: event emitted for recovered variable (variable is now correct)"
else
    _pass "D: no event emitted for recovered variable"
fi

if [[ -f "$STATE_FILE" ]]; then
    state_d="$(cat "$STATE_FILE")"
    if python3 -c "import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if 'CHUMP_SELF_HOSTED_ENABLED' not in d else 1)" <<< "$state_d" 2>/dev/null; then
        _pass "D: divergence entry cleared from state file after recovery"
    else
        _fail "D: divergence entry still present in state file after recovery"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n=== test-repo-var-audit: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
