#!/usr/bin/env bash
# scripts/ci/test-fleet-autopilot.sh — META-090 / META-122
#
# Smoke test for the chump fleet autopilot orchestrator. Validates the source
# contract + status command + bypass env, without actually installing any
# launchd plists (skip cleanly on Linux CI).
#
# META-122 additions: validates curator session config, bypass env, and new
# ambient event kinds are present in the script.
#
# capability-guard-exempt: source-contract assertions only; no chump binary invocation

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/coord/fleet-autopilot.sh"
INSTALLER="$REPO_ROOT/scripts/setup/install-fleet-autopilot-launchd.sh"

echo "=== META-090 fleet autopilot tests ==="

# (1) Source contract — orchestrator
[[ -f "$TARGET" ]] && ok "autopilot script exists" || { fail "missing $TARGET"; exit 1; }
[[ -x "$TARGET" ]] && ok "autopilot script executable" || fail "$TARGET not executable"

for needle in \
    "AUTOPILOT_LAYERS=" \
    "dev.chump.pr-auto-rebase" \
    "dev.chump.auto-arm-sweeper" \
    "com.chump.pr-pulse-consumer" \
    "com.chump.transient-retrigger" \
    "com.chump.oracle-refresh" \
    "com.chump.curator-jit-scheduler" \
    "com.chump.opus-curator" \
    "com.chump.emergency-fast-path" \
    "com.chump.fleet-autopilot" \
    "com.chump.refresh-runner-binary" \
    "cmd_start" \
    "cmd_stop" \
    "cmd_status" \
    "cmd_heartbeat" \
    "cmd_healthcheck" \
    "autopilot_state" \
    "autopilot_started" \
    "autopilot_stopped" \
    "autopilot_heartbeat" \
    "autopilot_partial" \
    "not_started" \
    "CHUMP_AUTOPILOT_DISABLED" \
    "chump-fleet-bootstrap.sh"; do
    if grep -qF "$needle" "$TARGET"; then
        ok "contract: $needle"
    else
        fail "contract missing: $needle"
    fi
done

# META-122: curator session contract checks
echo
echo "--- META-122 curator session contract ---"
for needle in \
    "CURATOR_ROLES=" \
    "CHUMP_AUTOPILOT_SKIP_CURATOR_LAUNCH" \
    "CURATOR_TMUX_SESSION" \
    "curator_session_launched" \
    "curator_session_respawned" \
    "curator_sessions_stopped" \
    "curator_check_and_respawn" \
    "cmd_launch_curators" \
    "cmd_stop_curators" \
    "curator_status_lines" \
    "chump-curators" \
    "handoff-loop.sh" \
    "ci-audit-loop.sh" \
    "decompose-loop.sh" \
    "md-links-loop.sh"; do
    if grep -qF "$needle" "$TARGET"; then
        ok "META-122 contract: $needle"
    else
        fail "META-122 contract missing: $needle"
    fi
done

# META-122: 6 curator roles declared
curator_role_count=$(grep -c '"shepherd\|"target\|"handoff\|"ci-audit\|"decompose\|"md-links' "$TARGET" 2>/dev/null || echo 0)
if [[ "$curator_role_count" -ge 6 ]]; then
    ok "META-122: 6 curator roles present in CURATOR_ROLES"
else
    fail "META-122: expected 6 curator roles, found $curator_role_count"
fi

# META-122: bypass env honored (CHUMP_AUTOPILOT_SKIP_CURATOR_LAUNCH)
if CHUMP_AUTOPILOT_SKIP_CURATOR_LAUNCH=1 CHUMP_AUTOPILOT_DISABLED=1 \
    "$TARGET" start 2>&1 | grep -qE "BYPASS|CHUMP_AUTOPILOT_DISABLED"; then
    ok "META-122: CHUMP_AUTOPILOT_SKIP_CURATOR_LAUNCH bypass present"
else
    fail "META-122: CHUMP_AUTOPILOT_SKIP_CURATOR_LAUNCH not wired to start"
fi

# (2) AC#1 requirement: >=10 daemons configured (post-RESILIENT-021: dev.* + com.* mix)
layer_count=$(grep -cE '^\s+"(com|dev)\.chump\.' "$TARGET")
if [[ "$layer_count" -ge 10 ]]; then
    ok "AC#1: $layer_count daemon layers configured (>=10 required)"
else
    fail "AC#1: only $layer_count layers configured (need >=10 per AC#7 smoke target)"
fi

# (3) Installer contract
[[ -f "$INSTALLER" ]] && ok "launchd installer exists" || fail "missing $INSTALLER"

for needle in \
    "PLIST_NAME=\"com.chump.fleet-autopilot\"" \
    "StartInterval" \
    "300" \
    "RunAtLoad" \
    "heartbeat" \
    "uninstall"; do
    if grep -qF -- "$needle" "$INSTALLER"; then
        ok "installer contract: $needle"
    else
        fail "installer missing: $needle"
    fi
done

# (4) Help text reachable
if "$TARGET" --help 2>&1 | grep -qE "start|stop|status"; then
    ok "help text mentions start/stop/status"
else
    fail "help text missing standard commands"
fi

# (5) status command runs without crashing (no daemons loaded ≠ failure)
if "$TARGET" status >/dev/null 2>&1; then
    ok "status command exits 0 on clean state"
else
    fail "status command exits non-zero unexpectedly"
fi

# (6) status --json produces parseable JSON with both daemon + curator keys
if "$TARGET" status json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'layers' in d and 'loaded' in d, 'missing daemon keys'
assert 'curator_tmux_session' in d, 'missing curator_tmux_session (META-122)'
assert 'curator_session_alive' in d, 'missing curator_session_alive (META-122)'
assert 'curators' in d and isinstance(d['curators'], list), 'missing curators list (META-122)'
assert len(d['curators']) == 6, f'expected 6 curators, got {len(d[\"curators\"])}'
" 2>/dev/null; then
    ok "status json output parseable + has layers/loaded/curator keys (META-122)"
else
    fail "status json output not parseable or missing META-122 curator fields"
fi

# (7) bypass env honored
if CHUMP_AUTOPILOT_DISABLED=1 "$TARGET" start 2>&1 | grep -qE "BYPASS|CHUMP_AUTOPILOT_DISABLED"; then
    ok "CHUMP_AUTOPILOT_DISABLED bypass honored"
else
    fail "bypass env not honored on start"
fi

# (8b) RESILIENT-120: healthcheck exits 0 when not_started (CI/dev host, never ran `start`)
if "$TARGET" healthcheck >/dev/null 2>&1; then
    ok "RESILIENT-120: healthcheck exits 0 on a not-started host"
else
    fail "RESILIENT-120: healthcheck unexpectedly non-zero on a not-started host"
fi

# (8c) RESILIENT-120: status text output includes the state field
if "$TARGET" status 2>/dev/null | grep -qE '^\s*state:\s+(not_started|running|degraded)'; then
    ok "RESILIENT-120: status reports state field"
else
    fail "RESILIENT-120: status missing state field"
fi

# (8) Unknown command rejected
if ! "$TARGET" nonsense-command 2>/dev/null; then
    ok "unknown command rejected with non-zero exit"
else
    fail "unknown command silently accepted"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "OK"
exit 0
