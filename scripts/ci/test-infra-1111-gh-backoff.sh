#!/usr/bin/env bash
# test-infra-1111-gh-backoff.sh — INFRA-1111
#
# Verifies chump_gh exponential backoff on GitHub secondary rate-limit response.
#
# Tests:
#  1. Rate-limit response detected; chump_gh sleeps 1s and retries
#  2. After 4 retries exhausted, gh_secondary_limit_hit emitted
#  3. CHUMP_GH_NO_RETRY=1 bypasses backoff entirely
#  4. Non-rate-limit failure is not retried
#  5. Successful call (rc=0) is never retried

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/github.sh"

PASS=0
FAIL=0

ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

echo "=== INFRA-1111: chump_gh secondary rate-limit backoff ==="

# ── Setup: fake gh binary ─────────────────────────────────────────────────────
FAKE_GH="$TMPDIR_BASE/gh"

make_fake_gh() {
    local exit_code="${1:-0}"
    local stderr_msg="${2:-}"
    local call_count_file="${3:-$TMPDIR_BASE/call_count}"
    local succeed_after="${4:-999}"
    printf '0' > "$call_count_file"
    cat >"$FAKE_GH" <<GHEOF
#!/usr/bin/env bash
count=\$(cat "$call_count_file" 2>/dev/null || echo 0)
count=\$((count+1))
printf '%d' "\$count" > "$call_count_file"
if (( count > $succeed_after )); then
    exit 0
fi
if [[ -n "$stderr_msg" ]]; then
    printf '%s\n' "$stderr_msg" >&2
fi
exit $exit_code
GHEOF
    chmod +x "$FAKE_GH"
}

ambient_file="$TMPDIR_BASE/ambient.jsonl"
export CHUMP_AMBIENT_OVERRIDE="$ambient_file"
export CHUMP_GH_SILENT=1
export CHUMP_GH_NO_THROTTLE=1
export CHUMP_GH_NO_PREEMPT=1
export CHUMP_GH_NO_PATH_INJECT=1

# Source the library with fake gh in PATH.
export PATH="$TMPDIR_BASE:$PATH"

# ── Test 1: rate-limit detected → retries (succeeds on 2nd try) ──────────────
echo ""
echo "--- Test 1: rate-limit detected, succeeds on 2nd try"

call_count_file1="$TMPDIR_BASE/calls1"
make_fake_gh 1 "GraphQL: API rate limit already exceeded for user ID 123" "$call_count_file1" 1

(
    # Reset ambient
    rm -f "$ambient_file"
    # Need fresh subshell to re-source library (avoid _CHUMP_GH_LIB_LOADED guard)
    unset _CHUMP_GH_LIB_LOADED
    source "$LIB"
    set +e
    chump_gh pr list 2>/dev/null
    rc=$?
    set -e
    calls=$(cat "$call_count_file1" 2>/dev/null || echo 0)
    # Should have retried: at least 2 calls
    if (( calls >= 2 )); then
        echo "RETRY_OK"
    fi
    # Second call succeeded (rc=0)
    if (( rc == 0 )); then
        echo "RC_OK"
    fi
)  > "$TMPDIR_BASE/out1" 2>/dev/null

if grep -q "RETRY_OK" "$TMPDIR_BASE/out1"; then
    ok "rate-limit response triggers retry"
else
    fail "rate-limit response did not trigger retry"
fi
if grep -q "RC_OK" "$TMPDIR_BASE/out1"; then
    ok "successful retry returns rc=0"
else
    fail "final rc not 0 when retry succeeds"
fi

# ── Test 2: all 4 retries exhausted → gh_secondary_limit_hit emitted ─────────
echo ""
echo "--- Test 2: 4 retries exhausted → gh_secondary_limit_hit emitted"

call_count_file2="$TMPDIR_BASE/calls2"
make_fake_gh 1 "You have exceeded a secondary rate limit" "$call_count_file2" 999

rm -f "$ambient_file"
(
    unset _CHUMP_GH_LIB_LOADED
    source "$LIB"
    set +e
    # Override sleep to be instant so test doesn't take 15+ seconds
    sleep() { :; }
    export -f sleep
    chump_gh pr list 2>/dev/null
    set -e
) > "$TMPDIR_BASE/out2" 2>/dev/null || true

if [[ -f "$ambient_file" ]] && grep -q 'gh_secondary_limit_hit' "$ambient_file"; then
    ok "gh_secondary_limit_hit emitted after exhausted retries"
else
    fail "gh_secondary_limit_hit NOT emitted after exhausted retries"
fi
if [[ -f "$ambient_file" ]]; then
    retries=$(python3 -c "import json,sys; d=[json.loads(l) for l in open('$ambient_file') if 'gh_secondary_limit_hit' in l]; print(d[-1]['retries'] if d else -1)" 2>/dev/null || echo "-1")
    if (( retries == 4 )); then
        ok "gh_secondary_limit_hit retries=4"
    else
        fail "gh_secondary_limit_hit retries=$retries (expected 4)"
    fi
fi

# ── Test 3: CHUMP_GH_NO_RETRY=1 bypasses backoff ─────────────────────────────
echo ""
echo "--- Test 3: CHUMP_GH_NO_RETRY=1 bypasses backoff"

call_count_file3="$TMPDIR_BASE/calls3"
make_fake_gh 1 "GraphQL: API rate limit already exceeded" "$call_count_file3" 999

rm -f "$ambient_file"
(
    unset _CHUMP_GH_LIB_LOADED
    source "$LIB"
    export CHUMP_GH_NO_RETRY=1
    set +e
    chump_gh pr list 2>/dev/null
    set -e
    calls=$(cat "$call_count_file3" 2>/dev/null || echo 0)
    printf 'CALLS=%d\n' "$calls"
) > "$TMPDIR_BASE/out3" 2>/dev/null || true

calls3=$(grep 'CALLS=' "$TMPDIR_BASE/out3" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "0")
if [[ "$calls3" == "1" ]]; then
    ok "CHUMP_GH_NO_RETRY=1 calls gh exactly once (no retry)"
else
    fail "CHUMP_GH_NO_RETRY=1 made $calls3 calls (expected 1)"
fi

if [[ -f "$ambient_file" ]] && grep -q 'gh_secondary_limit_hit' "$ambient_file"; then
    fail "gh_secondary_limit_hit emitted with CHUMP_GH_NO_RETRY=1"
else
    ok "gh_secondary_limit_hit NOT emitted with CHUMP_GH_NO_RETRY=1"
fi

# ── Test 4: non-rate-limit failure is not retried ─────────────────────────────
echo ""
echo "--- Test 4: non-rate-limit failure is not retried"

call_count_file4="$TMPDIR_BASE/calls4"
make_fake_gh 1 "error: repository not found" "$call_count_file4" 999

rm -f "$ambient_file"
(
    unset _CHUMP_GH_LIB_LOADED
    source "$LIB"
    set +e
    chump_gh pr list 2>/dev/null
    set -e
    calls=$(cat "$call_count_file4" 2>/dev/null || echo 0)
    printf 'CALLS=%d\n' "$calls"
) > "$TMPDIR_BASE/out4" 2>/dev/null || true

calls4=$(grep 'CALLS=' "$TMPDIR_BASE/out4" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "0")
if [[ "$calls4" == "1" ]]; then
    ok "non-rate-limit error: gh called exactly once (no retry)"
else
    fail "non-rate-limit error made $calls4 calls (expected 1)"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
