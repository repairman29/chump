#!/usr/bin/env bash
# scripts/ci/test-autopilot-unified.sh — MISSION-007
#
# Validates the bridge between the Rust autopilot (worker ship-loop) and the
# bash daemon-set autopilot (META-090). Source-contract assertions only —
# does not actually start the autopilot.
#
# capability-guard-exempt: source-contract assertions; no chump binary invocation

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== MISSION-007 unified autopilot bridge tests ==="

# (1) docs/process/AUTOPILOT_MODEL.md exists + describes the bridge
DOC="$REPO_ROOT/docs/process/AUTOPILOT_MODEL.md"
[[ -f "$DOC" ]] && ok "AUTOPILOT_MODEL.md exists" || fail "missing $DOC"
for needle in \
    "One toggle, two layers" \
    "MISSION-007" \
    "invoke_daemon_set" \
    "handle_autopilot_start" \
    "daemon_set"; do
    if grep -qF "$needle" "$DOC"; then
        ok "doc: $needle"
    else
        fail "doc missing: $needle"
    fi
done

# (2) Source-contract: web_server.rs has the bridge fn + uses it in both handlers
WEB="$REPO_ROOT/src/web_server.rs"
[[ -f "$WEB" ]] && ok "web_server.rs exists" || { fail "missing $WEB"; exit 1; }

for needle in \
    "fn invoke_daemon_set" \
    "MISSION-007" \
    "scripts/coord/fleet-autopilot.sh" \
    "invoke_daemon_set(\"start\")" \
    "invoke_daemon_set(\"stop\")" \
    "invoke_daemon_set(\"status\")" \
    "\"daemon_set\":" \
    "\"worker\":"; do
    if grep -qF "$needle" "$WEB"; then
        ok "bridge wiring: $needle"
    else
        fail "bridge missing: $needle"
    fi
done

# (3) The bash script the bridge calls actually exists + is executable
BASH_AP="$REPO_ROOT/scripts/coord/fleet-autopilot.sh"
[[ -x "$BASH_AP" ]] && ok "bash autopilot orchestrator executable" || fail "$BASH_AP not executable"

# (4) The bash script supports the args the bridge passes
if "$BASH_AP" --help 2>&1 | grep -qE 'start|stop|status'; then
    ok "bash autopilot supports start/stop/status"
else
    fail "bash autopilot missing required subcommands"
fi

# (5) bash status json output produces valid JSON (bridge depends on this)
if "$BASH_AP" status json 2>/dev/null | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    ok "bash autopilot status json produces valid JSON"
else
    fail "bash autopilot status json invalid (bridge cannot parse)"
fi

# (6) Handlers return unified shape (verified by grep for both keys in same handler block)
status_body=$(awk '/async fn handle_autopilot_status/,/^}/' "$WEB")
if echo "$status_body" | grep -q '"worker"' && echo "$status_body" | grep -q '"daemon_set"'; then
    ok "handle_autopilot_status returns both worker + daemon_set"
else
    fail "handle_autopilot_status doesn't return unified shape"
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
