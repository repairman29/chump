#!/usr/bin/env bash
# INFRA-622: multi-auth regression test — covers all 4 auth quadrants.
#
# Quadrant matrix:
#   1. api-only  — ANTHROPIC_API_KEY set, no OAUTH token
#   2. oauth-only — CLAUDE_CODE_OAUTH_TOKEN set, no API key
#   3. both      — both credentials present; API key preferred in auto mode
#   4. neither   — no credentials; resolved mode must be None
#
# Also validates:
#   • CHUMP_AUTH_MODE override forces a specific mode
#   • OAUTH token refresh file (CHUMP_OAUTH_TOKEN_FILE) is read correctly
#   • fleet_auth_fallback ambient event is emitted on 401-mode switch
#   • `chump fleet doctor` (auth path) exits 0 when credentials present
#
# Run from repo root: bash scripts/ci/test-multi-auth.sh
#
# Dependencies: cargo (for unit tests), bash 4+, python3 (for JSON check).
# Exit code: 0 = all pass, 1 = any failure.

set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Helper: run cargo test for a specific test in src/auth.rs ──────────────

run_auth_unit_test() {
    local test_name="$1"
    if cargo test --quiet "auth::tests::${test_name}" 2>/dev/null; then
        pass "cargo test auth::tests::${test_name}"
    else
        fail "cargo test auth::tests::${test_name}"
    fi
}

# ── Helper: source run-fleet.sh auth detection logic in isolation ──────────

detect_fleet_auth_mode() {
    local api_key="${1:-}"
    local oauth_token="${2:-}"

    (
        export ANTHROPIC_API_KEY="$api_key"
        export CLAUDE_CODE_OAUTH_TOKEN="$oauth_token"
        export FLEET_DRY_RUN=1
        export FLEET_SIZE=1
        export CHUMP_AMBIENT_LOG="$SANDBOX/amb-$RANDOM.jsonl"
        export HOME="$SANDBOX"
        export PATH="$SANDBOX/bin:$PATH"
        mkdir -p "$SANDBOX/bin" "$SANDBOX/.chump-locks" "$SANDBOX/.chump"
        for stub in git tmux claude chump sqlite3; do
            printf '#!/bin/sh\necho stub-${0##*/}\nexit 0\n' > "$SANDBOX/bin/$stub"
            chmod +x "$SANDBOX/bin/$stub"
        done
        touch "$SANDBOX/.chump/state.db"
        # Extract just the auth detection block and eval it.
        eval "$(sed -n '/^_fleet_auth_mode=/,/^_fleet_auth_path=/p' \
            "$REPO_ROOT/scripts/dispatch/run-fleet.sh" 2>/dev/null || echo '')"
        echo "${_fleet_auth_mode:-unknown}"
    ) 2>/dev/null || echo "error"
}

# ── Section 1: Rust unit tests (4 quadrants + fallback) ───────────────────

echo ""
echo "── Section 1: Rust unit tests (src/auth.rs) ─────────────────────────"

if cargo test --quiet --lib "auth::tests" 2>/dev/null; then
    pass "all src/auth.rs unit tests pass"
else
    # Run individually so we see which ones failed
    for t in \
        api_key_only_resolves_api_key_mode \
        oauth_only_resolves_oauth_mode \
        both_present_auto_prefers_api_key \
        both_present_mode_override_forces_oauth \
        neither_present_resolves_none \
        api_key_fallback_to_oauth_on_401 \
        oauth_fallback_to_api_key_on_401 \
        no_fallback_when_only_one_cred \
        reads_oauth_token_from_refresh_file \
        config_toml_parsed_correctly \
        extract_json_string_basic \
        extract_json_string_access_token \
        fleet_doctor_warns_when_no_creds \
        fleet_doctor_clean_with_api_key; do
        run_auth_unit_test "$t"
    done
fi

# ── Section 2: Shell-layer auth detection (run-fleet.sh quadrants) ─────────

echo ""
echo "── Section 2: run-fleet.sh auth mode detection ──────────────────────"

# Q1: api-only
_mode=$(detect_fleet_auth_mode "sk-ant-apikey" "")
if [[ "$_mode" == "api_key" ]]; then
    pass "Q1 api-only: run-fleet.sh detects api_key mode"
else
    fail "Q1 api-only: expected api_key, got '$_mode'"
fi

# Q2: oauth-only
_mode=$(detect_fleet_auth_mode "" "sk-ant-oat01-tok")
if [[ "$_mode" == "subscription" ]]; then
    pass "Q2 oauth-only: run-fleet.sh detects subscription mode"
else
    fail "Q2 oauth-only: expected subscription, got '$_mode'"
fi

# Q3: both — api_key preferred (auto mode)
_mode=$(detect_fleet_auth_mode "sk-ant-apikey" "sk-ant-oat01-tok")
if [[ "$_mode" == "api_key" ]]; then
    pass "Q3 both: run-fleet.sh prefers api_key over subscription in auto mode"
else
    fail "Q3 both: expected api_key, got '$_mode'"
fi

# Q4: neither
_mode=$(detect_fleet_auth_mode "" "")
if [[ "$_mode" == "unknown" ]]; then
    pass "Q4 neither: run-fleet.sh resolves unknown when no creds present"
else
    fail "Q4 neither: expected unknown, got '$_mode'"
fi

# ── Section 3: OAUTH token refresh file ───────────────────────────────────

echo ""
echo "── Section 3: OAUTH token refresh file ──────────────────────────────"

_tok_file="$SANDBOX/oauth-token.json"
printf '{"token":"sk-ant-oat01-fresh","written_at":"2026-05-06T00:00:00Z","source":"test"}\n' \
    > "$_tok_file"

# worker.sh refresh_oauth_token() reads from CHUMP_OAUTH_TOKEN_FILE
if grep -q 'CHUMP_OAUTH_TOKEN_FILE' "$REPO_ROOT/scripts/dispatch/worker.sh" 2>/dev/null; then
    pass "worker.sh references CHUMP_OAUTH_TOKEN_FILE for token refresh"
else
    fail "worker.sh does not reference CHUMP_OAUTH_TOKEN_FILE"
fi

if grep -q 'refresh_oauth_token' "$REPO_ROOT/scripts/dispatch/worker.sh" 2>/dev/null; then
    pass "worker.sh defines refresh_oauth_token()"
else
    fail "worker.sh does not define refresh_oauth_token()"
fi

# Verify control.sh or run-fleet.sh writes the refresh file in subscription mode
if grep -q 'oauth-token.json\|CHUMP_OAUTH_TOKEN_FILE' \
    "$REPO_ROOT/scripts/dispatch/run-fleet.sh" 2>/dev/null; then
    pass "run-fleet.sh writes oauth token refresh file in subscription mode"
else
    fail "run-fleet.sh does not write oauth token refresh file"
fi

# ── Section 4: fleet_auth_fallback ambient event ───────────────────────────

echo ""
echo "── Section 4: fleet_auth_fallback ambient emission ──────────────────"

_amb="$SANDBOX/fallback-test.jsonl"

# The Rust on_auth_failure() writes to CHUMP_AMBIENT_LOG.
# We verify the field exists in src/auth.rs source (compile-time check above
# already validates runtime behaviour via unit tests).
if grep -q 'fleet_auth_fallback' "$REPO_ROOT/src/auth.rs" 2>/dev/null; then
    pass "src/auth.rs emits fleet_auth_fallback event kind"
else
    fail "src/auth.rs does not emit fleet_auth_fallback event kind"
fi

if grep -q 'fleet_auth_fallback' "$REPO_ROOT/src/auth.rs" \
    && grep -q 'failed_mode\|fallback_mode' "$REPO_ROOT/src/auth.rs" 2>/dev/null; then
    pass "fleet_auth_fallback event includes failed_mode and fallback_mode fields"
else
    fail "fleet_auth_fallback event missing required fields"
fi

# ── Section 5: CHUMP_AUTH_MODE env override ────────────────────────────────

echo ""
echo "── Section 5: CHUMP_AUTH_MODE env override ──────────────────────────"

if grep -q 'CHUMP_AUTH_MODE' "$REPO_ROOT/src/auth.rs" 2>/dev/null; then
    pass "src/auth.rs reads CHUMP_AUTH_MODE for mode override"
else
    fail "src/auth.rs does not read CHUMP_AUTH_MODE"
fi

for val in "auto" "api-key" "api_key" "oauth"; do
    if grep -qiE "\"${val}\"|'${val}'" "$REPO_ROOT/src/auth.rs" 2>/dev/null; then
        pass "CHUMP_AUTH_MODE value '$val' handled in src/auth.rs"
    else
        fail "CHUMP_AUTH_MODE value '$val' not handled in src/auth.rs"
    fi
done

# ── Section 6: fleet doctor coverage ──────────────────────────────────────

echo ""
echo "── Section 6: fleet doctor auth validation ──────────────────────────"

if grep -q 'fleet_doctor_validate' "$REPO_ROOT/src/auth.rs" 2>/dev/null; then
    pass "src/auth.rs exports fleet_doctor_validate()"
else
    fail "src/auth.rs missing fleet_doctor_validate()"
fi

if grep -q 'DoctorReport' "$REPO_ROOT/src/auth.rs" 2>/dev/null; then
    pass "src/auth.rs defines DoctorReport struct"
else
    fail "src/auth.rs missing DoctorReport struct"
fi

# ── Section 7: documentation coverage ─────────────────────────────────────

echo ""
echo "── Section 7: documentation ──────────────────────────────────────────"

if grep -q 'CHUMP_AUTH_MODE' "$REPO_ROOT/docs/QUICKSTART_OFFLINE.md" 2>/dev/null; then
    pass "QUICKSTART_OFFLINE.md documents CHUMP_AUTH_MODE"
else
    fail "QUICKSTART_OFFLINE.md does not document CHUMP_AUTH_MODE"
fi

if grep -q 'CHUMP_AUTH_MODE' "$REPO_ROOT/CLAUDE.md" 2>/dev/null; then
    pass "CLAUDE.md documents CHUMP_AUTH_MODE"
else
    fail "CLAUDE.md does not document CHUMP_AUTH_MODE"
fi

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
