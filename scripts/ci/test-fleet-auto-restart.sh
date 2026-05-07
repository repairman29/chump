#!/usr/bin/env bash
# test-fleet-auto-restart.sh — INFRA-611
#
# Verifies fleet-autorestart-daemon.sh trigger logic for all 4 conditions:
#   (a) version skew on coord-affecting paths (no in-flight PR)
#   (b) ≥ 3 fleet_wedge events in 30-min window
#   (c) fleet uptime > 24 h
#   (d) auth storm threshold (fleet_auth_storm events)
#
# Also verifies:
#   - CHUMP_FLEET_AUTO_RESTART=0 disables all triggers
#   - Operator cancel via fleet_auto_restart_cancel event is respected
#   - fleet_auto_restart_decision is emitted before restart

set -euo pipefail

PASS=0; FAIL=0
ok()   { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
DAEMON="$REPO_ROOT/scripts/dispatch/fleet-autorestart-daemon.sh"

[[ -f "$DAEMON" ]] || { echo "FATAL: fleet-autorestart-daemon.sh missing"; exit 2; }

echo "=== INFRA-611 fleet-auto-restart-daemon test ==="
echo

# ── Helpers ───────────────────────────────────────────────────────────────────

TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT

_ambient="$TD/ambient.jsonl"
_wedge_file="$TD/fleet-autorestart-wedge-times.txt"
_restart_log="$TD/restart-calls.log"

# Stub fleet-restart.sh — records calls, does not actually restart
mkdir -p "$TD/bin"
cat > "$TD/bin/fleet-restart.sh" <<'STUB'
#!/usr/bin/env bash
printf 'fleet-restart called: %s\n' "$*" >> "$RESTART_LOG"
exit 0
STUB
chmod +x "$TD/bin/fleet-restart.sh"

# Stub tmux — controls _fleet_alive() return
_tmux_alive=1
cat > "$TD/bin/tmux" <<'STUB'
#!/usr/bin/env bash
# If first arg is "has-session", report based on $TMUX_ALIVE env
if [[ "${1:-}" = "has-session" ]]; then
    [[ "${TMUX_ALIVE:-1}" = "1" ]] && exit 0 || exit 1
fi
exec /usr/bin/tmux "$@" 2>/dev/null || exit 1
STUB
chmod +x "$TD/bin/tmux"

# Stub fleet-version-skew-detect.sh — controlled by $SKEW_EXIT
cat > "$TD/bin/fleet-version-skew-detect.sh" <<'STUB'
#!/usr/bin/env bash
exit "${SKEW_EXIT:-0}"
STUB
chmod +x "$TD/bin/fleet-version-skew-detect.sh"

# Source the helper functions from the daemon by extracting and wrapping them.
# We test the logic-heavy functions directly rather than running the full daemon.
_helpers="$TD/helpers.sh"
{
    # Extract helper functions (everything before the main event loop comment).
    # Use awk to grab from start up to "# ── Main event loop".
    awk '/^# ── Main event loop ──/{ exit } 1' "$DAEMON" | \
        grep -v '^set -uo pipefail' | \
        grep -v '^#!/'

    # Override paths to use test directory
    cat <<OVERRIDES
REPO_ROOT="$TD"
_amb="$_ambient"
_lock_dir="$TD"
_wedge_times_file="$_wedge_file"
_restart_lock="$TD/fleet-autorestart.lock"
_restart_script="$TD/bin/fleet-restart.sh"
_skew_script="$TD/bin/fleet-version-skew-detect.sh"
FLEET_SESSION="test-fleet"
FLEET_START_EPOCH=0
CHUMP_FLEET_AUTO_RESTART=1
_auth_storm_threshold=3
_wedge_threshold=3
_wedge_window=1800
_uptime_limit=86400
_grace_secs=5
_skew_check_interval=300
RESTART_LOG="$_restart_log"
OVERRIDES
} > "$_helpers"

_run() {
    PATH="$TD/bin:$PATH" \
    TMUX_ALIVE="${TMUX_ALIVE:-1}" \
    SKEW_EXIT="${SKEW_EXIT:-0}" \
    RESTART_LOG="$_restart_log" \
    bash -c "source '$_helpers'; $*" 2>/dev/null
}

# ── Test 1: daemon script exists and is executable ────────────────────────────
if [[ -f "$DAEMON" && -r "$DAEMON" ]]; then
    ok "fleet-autorestart-daemon.sh exists"
else
    fail "fleet-autorestart-daemon.sh missing"
fi

if bash -n "$DAEMON" 2>/dev/null; then
    ok "daemon script has no syntax errors"
else
    fail "daemon script has syntax errors: $(bash -n "$DAEMON" 2>&1 | head -3)"
fi

# ── Test 2: launchd install script exists ─────────────────────────────────────
INSTALL_SCRIPT="$REPO_ROOT/scripts/setup/install-fleet-auto-restart-launchd.sh"
if [[ -f "$INSTALL_SCRIPT" ]]; then
    ok "install-fleet-auto-restart-launchd.sh exists"
else
    fail "install-fleet-auto-restart-launchd.sh missing"
fi

if bash -n "$INSTALL_SCRIPT" 2>/dev/null; then
    ok "install script has no syntax errors"
else
    fail "install script has syntax errors: $(bash -n "$INSTALL_SCRIPT" 2>&1 | head -3)"
fi

if grep -q 'StartInterval' "$INSTALL_SCRIPT" && \
   grep -q '600' "$INSTALL_SCRIPT"; then
    ok "launchd plist uses StartInterval 600 (10 min)"
else
    fail "launchd plist missing StartInterval 600"
fi

# ── Test 3: CHUMP_FLEET_AUTO_RESTART=0 disables all triggers ─────────────────
: > "$_ambient"
_run "
    CHUMP_FLEET_AUTO_RESTART=0
    _grace_secs=0
    _restart_with_grace 'test_trigger' 'test_reason'
" 2>/dev/null || true

if grep -q '"kind":"fleet_auto_restart_decision"' "$_ambient" && \
   grep -q 'CHUMP_FLEET_AUTO_RESTART=0' "$_ambient"; then
    ok "CHUMP_FLEET_AUTO_RESTART=0 emits decision with disabled=CHUMP_FLEET_AUTO_RESTART=0"
else
    fail "expected disabled decision event; ambient: $(cat "$_ambient" 2>/dev/null || echo '(empty)')"
fi
if [[ ! -s "$_restart_log" ]]; then
    ok "CHUMP_FLEET_AUTO_RESTART=0 does not call fleet-restart.sh"
else
    fail "fleet-restart.sh was called despite CHUMP_FLEET_AUTO_RESTART=0"
fi

# ── Test 4: fleet_auto_restart_decision emitted before restart ────────────────
: > "$_ambient"
: > "$_restart_log"
# Use _grace_secs=0 for instant restart in tests, run in background
_run "
    CHUMP_FLEET_AUTO_RESTART=1
    _grace_secs=0
    TMUX_ALIVE=1
    _restart_with_grace 'test_trigger' 'unit_test_reason'
" 2>/dev/null || true
sleep 1

if grep -q '"kind":"fleet_auto_restart_decision"' "$_ambient"; then
    ok "fleet_auto_restart_decision event emitted on trigger"
else
    fail "fleet_auto_restart_decision not emitted; ambient: $(cat "$_ambient" 2>/dev/null || echo '(empty)')"
fi

# ── Test 5: operator cancel via fleet_auto_restart_cancel ────────────────────
: > "$_ambient"
: > "$_restart_log"
# Write a cancel event that _restart_with_grace's grace loop will see
printf '{"ts":"%s","kind":"fleet_auto_restart_cancel","message":"operator override"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_ambient"

_run "
    CHUMP_FLEET_AUTO_RESTART=1
    _grace_secs=5
    TMUX_ALIVE=1
    _restart_with_grace 'test_trigger' 'should_be_cancelled'
" 2>/dev/null || true

if [[ ! -s "$_restart_log" ]]; then
    ok "restart cancelled by fleet_auto_restart_cancel event"
else
    fail "fleet-restart.sh was called despite cancel event; restart_log: $(cat "$_restart_log")"
fi

# ── Test 6: trigger (b) — wedge cluster logic ─────────────────────────────────
: > "$_wedge_file"
_now=$(date +%s)

# Record 2 wedge times within window — should NOT hit threshold (3)
printf '%d\n' "$((_now - 100))" >> "$_wedge_file"
printf '%d\n' "$((_now - 50))"  >> "$_wedge_file"
count=$(_run "_wedge_count_recent")
if [[ "$count" -eq 2 ]]; then
    ok "2 wedge events in window → count=2 (below threshold)"
else
    fail "expected count=2, got: $count"
fi

# Record a 3rd — should hit threshold
printf '%d\n' "$_now" >> "$_wedge_file"
count=$(_run "_wedge_count_recent")
if [[ "$count" -ge 3 ]]; then
    ok "3 wedge events in window → count≥3 (at threshold)"
else
    fail "expected count≥3, got: $count"
fi

# Record one that is too old (> 30 min ago) — should not count
: > "$_wedge_file"
printf '%d\n' "$((_now - 3700))" >> "$_wedge_file"
printf '%d\n' "$_now" >> "$_wedge_file"
count=$(_run "_wedge_count_recent")
if [[ "$count" -eq 1 ]]; then
    ok "old wedge event (>30 min) is pruned from window"
else
    fail "expected count=1 after pruning stale entry, got: $count"
fi

# ── Test 7: trigger (c) — uptime > 24 h ──────────────────────────────────────
: > "$_ambient"
: > "$_restart_log"
_old_epoch=$(( $(date +%s) - 90000 ))  # 25 h ago

_run "
    CHUMP_FLEET_AUTO_RESTART=1
    FLEET_START_EPOCH=$_old_epoch
    _uptime_limit=86400
    _last_periodic_check=0
    _skew_check_interval=0
    SKEW_EXIT=0
    _fleet_alive() { return 0; }
    _run_periodic_checks
" 2>/dev/null || true
sleep 1

if grep -q '"kind":"fleet_auto_restart_decision"' "$_ambient" && \
   grep -q 'uptime' "$_ambient"; then
    ok "trigger (c): uptime > 24 h emits fleet_auto_restart_decision with trigger=uptime"
else
    fail "expected uptime decision; ambient: $(cat "$_ambient" 2>/dev/null || echo '(empty)')"
fi

# ── Test 8: trigger (a) — version skew (no in-flight PR) ─────────────────────
: > "$_ambient"
: > "$_restart_log"

_run "
    CHUMP_FLEET_AUTO_RESTART=1
    FLEET_START_EPOCH=0
    _last_periodic_check=0
    _skew_check_interval=0
    _uptime_limit=999999
    SKEW_EXIT=1
    _no_inflight_pr_for_skew() { return 0; }
    _fleet_alive() { return 0; }
    _run_periodic_checks
" 2>/dev/null || true
sleep 1

if grep -q '"kind":"fleet_auto_restart_decision"' "$_ambient" && \
   grep -q 'version_skew' "$_ambient"; then
    ok "trigger (a): version skew with no in-flight PR emits decision with trigger=version_skew"
else
    fail "expected version_skew decision; ambient: $(cat "$_ambient" 2>/dev/null || echo '(empty)')"
fi

# ── Test 9: trigger (a) skipped when in-flight PR exists ─────────────────────
: > "$_ambient"
: > "$_restart_log"

_run "
    CHUMP_FLEET_AUTO_RESTART=1
    FLEET_START_EPOCH=0
    _last_periodic_check=0
    _skew_check_interval=0
    _uptime_limit=999999
    SKEW_EXIT=1
    _no_inflight_pr_for_skew() { return 1; }
    _fleet_alive() { return 0; }
    _run_periodic_checks
" 2>/dev/null || true

if ! grep -q '"kind":"fleet_auto_restart_decision"' "$_ambient"; then
    ok "trigger (a): version skew skipped when in-flight PR covers affected gap"
else
    fail "restart decision emitted despite in-flight PR"
fi

# ── Test 10: trigger (d) — auth storm ────────────────────────────────────────
if grep -q 'fleet_auth_storm' "$DAEMON"; then
    ok "trigger (d): fleet_auth_storm handler present in daemon"
else
    fail "fleet_auth_storm handler missing from daemon"
fi
if grep -q '_auth_storm_threshold' "$DAEMON"; then
    ok "trigger (d): auth storm uses configurable threshold"
else
    fail "auth storm threshold not configurable"
fi

# ── Test 11: all 4 trigger names present in daemon ───────────────────────────
for trigger in version_skew wedge_cluster uptime auth_storm; do
    if grep -q "\"$trigger\"\|'$trigger'" "$DAEMON"; then
        ok "trigger '$trigger' referenced in daemon"
    else
        fail "trigger '$trigger' not found in daemon"
    fi
done

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
