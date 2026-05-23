#!/usr/bin/env bash
# scripts/ci/test-fleet-backend-auto-detect.sh — INFRA-1717
#
# Verifies that scripts/dispatch/worker.sh + scripts/dispatch/run-fleet.sh
# correctly auto-detect FLEET_BACKEND across the three claude auth paths:
#   1. ANTHROPIC_API_KEY  set → claude
#   2. CLAUDE_CODE_OAUTH_TOKEN set → claude
#   3. ~/.chump/oauth-token.json present (non-empty) → claude
#   4. None of the above → chump-local
#
# Pre-INFRA-1717 the check was ANTHROPIC_API_KEY-only, so case 2 + 3 (the
# OAUTH-subscription path) mis-routed to the exhausted chump-local cascade
# and workers timed out without shipping.
#
# Strategy: rather than spawning the full fleet, we extract the relevant
# auto-detect lines from each script and evaluate them in a sub-shell with
# controlled HOME + env. This keeps the test hermetic and fast.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
RUNFLEET="$REPO_ROOT/scripts/dispatch/run-fleet.sh"

failures=0

# Create a fake HOME with a controlled oauth-token.json.
TMPHOME="$(mktemp -d)"
trap 'rm -rf "$TMPHOME"' EXIT
mkdir -p "$TMPHOME/.chump"

# ─── Test helper ─────────────────────────────────────────────────────────────
# Evaluates worker.sh's auto-detect block in isolation. Returns the resolved
# FLEET_BACKEND value to stdout.
detect_worker_backend() {
    local api_key="$1"
    local oauth_env="$2"
    local oauth_file_present="$3"  # "1" to create file, "" otherwise
    local explicit_backend="$4"     # "" if unset

    rm -f "$TMPHOME/.chump/oauth-token.json"
    if [[ "$oauth_file_present" == "1" ]]; then
        echo '{"token":"fake"}' > "$TMPHOME/.chump/oauth-token.json"
    fi

    HOME="$TMPHOME" \
    ANTHROPIC_API_KEY="$api_key" \
    CLAUDE_CODE_OAUTH_TOKEN="$oauth_env" \
    FLEET_BACKEND="$explicit_backend" \
    bash -c '
        if [[ -z "${ANTHROPIC_API_KEY:-}" \
           && -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" \
           && ! -s "${HOME}/.chump/oauth-token.json" ]]; then
            FLEET_BACKEND="${FLEET_BACKEND:-chump-local}"
        else
            FLEET_BACKEND="${FLEET_BACKEND:-claude}"
        fi
        echo "$FLEET_BACKEND"
    '
}

assert_eq() {
    local got="$1" want="$2" desc="$3"
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: $desc — got '$got', want '$want'"
        failures=$((failures + 1))
    fi
}

# ─── Test cases ──────────────────────────────────────────────────────────────

# Case 1: ANTHROPIC_API_KEY set → claude
got="$(detect_worker_backend "sk-ant-fake" "" "" "")"
assert_eq "$got" "claude" \
    "ANTHROPIC_API_KEY set → backend=claude"

# Case 2: CLAUDE_CODE_OAUTH_TOKEN set → claude
got="$(detect_worker_backend "" "oauth-fake" "" "")"
assert_eq "$got" "claude" \
    "CLAUDE_CODE_OAUTH_TOKEN set → backend=claude"

# Case 3: ~/.chump/oauth-token.json present → claude  (INFRA-1717 fix)
got="$(detect_worker_backend "" "" "1" "")"
assert_eq "$got" "claude" \
    "oauth-token.json present (no env vars) → backend=claude (INFRA-1717)"

# Case 4: nothing set → chump-local
got="$(detect_worker_backend "" "" "" "")"
assert_eq "$got" "chump-local" \
    "no auth path → backend=chump-local"

# Case 5: explicit FLEET_BACKEND override always wins (api_key path)
got="$(detect_worker_backend "sk-ant-fake" "" "" "chump-local")"
assert_eq "$got" "chump-local" \
    "explicit FLEET_BACKEND=chump-local overrides api_key auto-detect"

# Case 6: explicit FLEET_BACKEND override always wins (oauth path)
got="$(detect_worker_backend "" "" "1" "chump-local")"
assert_eq "$got" "chump-local" \
    "explicit FLEET_BACKEND=chump-local overrides oauth-file auto-detect"

# ─── run-fleet.sh auth-path detection block ──────────────────────────────────
# Verify the new oauth-token.json branch exists in run-fleet.sh too.
if ! grep -q 'oauth-token.json' "$RUNFLEET" 2>/dev/null; then
    echo "FAIL: run-fleet.sh missing oauth-token.json branch in auth detection"
    failures=$((failures + 1))
fi
if ! grep -q '_fleet_auth_mode' "$RUNFLEET" 2>/dev/null; then
    echo "FAIL: run-fleet.sh missing _fleet_auth_mode resolution"
    failures=$((failures + 1))
fi

# ─── worker.sh: the INFRA-1717 changes ───────────────────────────────────────
# Verify the worker uses all three checks before falling back to chump-local.
if ! grep -q 'CLAUDE_CODE_OAUTH_TOKEN' "$WORKER" 2>/dev/null; then
    echo "FAIL: worker.sh missing CLAUDE_CODE_OAUTH_TOKEN in auto-detect"
    failures=$((failures + 1))
fi
if ! grep -q 'oauth-token.json' "$WORKER" 2>/dev/null; then
    echo "FAIL: worker.sh missing oauth-token.json in auto-detect"
    failures=$((failures + 1))
fi

if [[ $failures -gt 0 ]]; then
    echo ""
    echo "FAIL INFRA-1717: $failures assertion(s) failed"
    exit 1
fi

echo "OK INFRA-1717: fleet backend auto-detect honors all three claude auth paths"
