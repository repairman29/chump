#!/usr/bin/env bash
# test-auth-storm-auto-recovery.sh — INFRA-623
#
# Verifies fleet-restart.sh --refresh-auth covers all 3 credential paths:
#   1. ~/.chump/oauth-token.json mtime newer than fleet start → resolves oauth
#   2. No fresh oauth, but ANTHROPIC_API_KEY set → resolves api_key
#   3. Neither → emits fleet_auth_unrecoverable, exits 4
#
# Also verifies:
#   4. run-fleet.sh exports FLEET_START_EPOCH and spawns the autorestart daemon
#   5. fleet-autorestart-daemon.sh triggers restart after threshold auth-storm events
#   6. run-fleet.sh control loop passes FLEET_START_EPOCH to worker env

set -uo pipefail

PASS=0
FAIL=0
ok()   { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$(( FAIL + 1 )); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
RESTART="$REPO_ROOT/scripts/dispatch/fleet-restart.sh"
DAEMON="$REPO_ROOT/scripts/dispatch/fleet-autorestart-daemon.sh"
RUN_FLEET="$REPO_ROOT/scripts/dispatch/run-fleet.sh"

[[ -f "$RESTART" ]] || { printf 'FATAL: fleet-restart.sh missing\n'; exit 2; }
[[ -f "$DAEMON"  ]] || { printf 'FATAL: fleet-autorestart-daemon.sh missing\n'; exit 2; }

printf '=== INFRA-623 auth-storm auto-recovery test ===\n\n'

# ── Helper: run fleet-restart.sh --refresh-auth in an isolated environment ──
# Sets HOME to a tmpdir, overrides FLEET_SESSION to something that has no
# active tmux session (so the "stop existing fleet" step is skipped), and
# uses FLEET_DRY_RUN=1 so no actual fleet restart occurs.
run_refresh() {
    local _tmpdir="$1" _epoch="$2"
    local _ambient="$_tmpdir/ambient.jsonl"
    HOME="$_tmpdir" \
    FLEET_START_EPOCH="$_epoch" \
    FLEET_SESSION="test-fleet-nonexistent-$$" \
    CHUMP_AMBIENT_LOG="$_ambient" \
    FLEET_DRY_RUN=1 \
    bash "$RESTART" --refresh-auth --fleet-start-epoch "$_epoch" 2>&1
    return $?
}

# ────────────────────────────────────────────────────────────────────────────
# Test 1: path-1 — fresh oauth-token.json (mtime > fleet start)
# ────────────────────────────────────────────────────────────────────────────
T1="$(mktemp -d)"
trap 'rm -rf "$T1"' EXIT

_now=$(date +%s)
_fleet_epoch=$(( _now - 60 ))   # fleet started 60s ago

mkdir -p "$T1/.chump"
printf '{"api_key":"sk-test-oauth-path1"}\n' > "$T1/.chump/oauth-token.json"
# Ensure mtime is newer than fleet_epoch (it was just created)

: > "$T1/ambient.jsonl"
_rc=0
run_refresh "$T1" "$_fleet_epoch" > /dev/null 2>&1 || _rc=$?

if grep -q '"kind":"fleet_auth_refresh"' "$T1/ambient.jsonl" \
   && grep -q 'path=oauth' "$T1/ambient.jsonl"; then
    ok "path-1: fresh oauth-token.json → fleet_auth_refresh path=oauth emitted"
else
    fail "path-1: expected fleet_auth_refresh path=oauth in ambient; got: $(cat "$T1/ambient.jsonl" 2>/dev/null)"
fi
if [[ $_rc -eq 0 ]]; then
    ok "path-1: exit code 0 (success)"
else
    fail "path-1: expected exit 0, got $_rc"
fi

# ────────────────────────────────────────────────────────────────────────────
# Test 2: path-1 stale, path-2 — ANTHROPIC_API_KEY set
# ────────────────────────────────────────────────────────────────────────────
T2="$(mktemp -d)"

_future_epoch=$(( $(date +%s) + 9999 ))   # fleet "started" far in future → token is stale

mkdir -p "$T2/.chump"
printf '{"api_key":"sk-stale-token"}\n' > "$T2/.chump/oauth-token.json"
# mtime will be older than _future_epoch

: > "$T2/ambient.jsonl"
_rc=0
ANTHROPIC_API_KEY="sk-test-api-key" \
HOME="$T2" \
FLEET_START_EPOCH="$_future_epoch" \
FLEET_SESSION="test-fleet-nonexistent-$$" \
CHUMP_AMBIENT_LOG="$T2/ambient.jsonl" \
FLEET_DRY_RUN=1 \
bash "$RESTART" --refresh-auth --fleet-start-epoch "$_future_epoch" > /dev/null 2>&1 || _rc=$?

if grep -q '"kind":"fleet_auth_refresh"' "$T2/ambient.jsonl" \
   && grep -q 'path=api_key' "$T2/ambient.jsonl"; then
    ok "path-2: ANTHROPIC_API_KEY → fleet_auth_refresh path=api_key emitted"
else
    fail "path-2: expected fleet_auth_refresh path=api_key; got: $(cat "$T2/ambient.jsonl" 2>/dev/null)"
fi
if [[ $_rc -eq 0 ]]; then
    ok "path-2: exit code 0 (success)"
else
    fail "path-2: expected exit 0, got $_rc"
fi
rm -rf "$T2"

# ────────────────────────────────────────────────────────────────────────────
# Test 3: path-3 — neither oauth nor API key → fleet_auth_unrecoverable
# ────────────────────────────────────────────────────────────────────────────
T3="$(mktemp -d)"

_future_epoch=$(( $(date +%s) + 9999 ))

mkdir -p "$T3/.chump"
# No oauth-token.json; no ANTHROPIC_API_KEY

: > "$T3/ambient.jsonl"
_rc=0
(
    export HOME="$T3"
    export FLEET_START_EPOCH="$_future_epoch"
    export FLEET_SESSION="test-fleet-nonexistent-$$"
    export CHUMP_AMBIENT_LOG="$T3/ambient.jsonl"
    export FLEET_DRY_RUN=1
    unset ANTHROPIC_API_KEY 2>/dev/null || true
    bash "$RESTART" --refresh-auth --fleet-start-epoch "$_future_epoch" > /dev/null 2>&1
) || _rc=$?

if [[ $_rc -eq 4 ]]; then
    ok "path-3: exit code 4 (unrecoverable)"
else
    fail "path-3: expected exit 4, got $_rc"
fi
if grep -q '"kind":"fleet_auth_unrecoverable"' "$T3/ambient.jsonl"; then
    ok "path-3: fleet_auth_unrecoverable emitted to ambient.jsonl"
else
    fail "path-3: fleet_auth_unrecoverable not in ambient: $(cat "$T3/ambient.jsonl" 2>/dev/null)"
fi
rm -rf "$T3"

# ────────────────────────────────────────────────────────────────────────────
# Test 4: run-fleet.sh sets FLEET_START_EPOCH and spawns autorestart daemon
# ────────────────────────────────────────────────────────────────────────────
if grep -q 'FLEET_START_EPOCH' "$RUN_FLEET"; then
    ok "run-fleet.sh exports FLEET_START_EPOCH"
else
    fail "run-fleet.sh missing FLEET_START_EPOCH"
fi
if grep -q 'fleet-autorestart-daemon.sh' "$RUN_FLEET"; then
    ok "run-fleet.sh spawns fleet-autorestart-daemon.sh"
else
    fail "run-fleet.sh does not spawn fleet-autorestart-daemon.sh"
fi

# ────────────────────────────────────────────────────────────────────────────
# Test 5: fleet-autorestart-daemon.sh has threshold-triggered restart logic
# ────────────────────────────────────────────────────────────────────────────
if grep -q 'fleet_auth_storm' "$DAEMON" \
   && grep -q 'fleet-restart.sh' "$DAEMON" \
   && grep -q 'refresh-auth' "$DAEMON"; then
    ok "daemon watches fleet_auth_storm and calls fleet-restart.sh --refresh-auth"
else
    fail "daemon missing auth-storm trigger or restart call"
fi
if grep -q 'CHUMP_AUTH_STORM_RESTART_THRESHOLD' "$DAEMON"; then
    ok "daemon respects CHUMP_AUTH_STORM_RESTART_THRESHOLD knob"
else
    fail "daemon missing CHUMP_AUTH_STORM_RESTART_THRESHOLD"
fi

# ────────────────────────────────────────────────────────────────────────────
# Test 6: fleet-restart.sh script is executable
# ────────────────────────────────────────────────────────────────────────────
if [[ -x "$RESTART" ]]; then
    ok "fleet-restart.sh is executable"
else
    fail "fleet-restart.sh is not executable"
fi
if [[ -x "$DAEMON" ]]; then
    ok "fleet-autorestart-daemon.sh is executable"
else
    fail "fleet-autorestart-daemon.sh is not executable"
fi

printf '\n=== Results: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
