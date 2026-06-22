#!/usr/bin/env bash
# RESILIENT-158 regression: the fleet-autopilot heartbeat's ensure_worker_pool
# durably owns the run-fleet worker pool — relaunches it when down, is a no-op
# when healthy, and HONORS the operator kill-switches (flag file + env var).
#
# Tests the REAL ensure_worker_pool extracted from fleet-autopilot.sh, with the
# actual launch + tmux + emit/log stubbed (no real fleet spawned).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.."
ROOT="$(cd "$ROOT" && pwd)"
AP="$ROOT/scripts/coord/fleet-autopilot.sh"
[[ -f "$AP" ]] || { echo "FAIL: fleet-autopilot.sh not found"; exit 1; }

fails=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

# Load the REAL functions (column-0 defs).
eval "$(sed -n '/^_keeper_off_flag() {/,/^}/p' "$AP")"
eval "$(sed -n '/^ensure_worker_pool() {/,/^}/p' "$AP")"
type ensure_worker_pool >/dev/null 2>&1 || { echo "FAIL: ensure_worker_pool did not load"; exit 1; }
type _keeper_off_flag    >/dev/null 2>&1 || { echo "FAIL: _keeper_off_flag did not load"; exit 1; }
ok "loaded real ensure_worker_pool + _keeper_off_flag from fleet-autopilot.sh"

# Stubs: capture launch, silence emit/log, mock tmux via MOCK_* env.
LAUNCHED=0
_keeper_launch_fleet() { LAUNCHED=1; }
emit() { :; }
log()  { :; }
tmux() {
    case "${1:-}" in
        has-session)  [[ "${MOCK_SESSION:-0}" == "1" ]] && return 0 || return 1 ;;
        list-panes)   local i; for ((i=0;i<${MOCK_PANES:-0};i++)); do echo 0; done ;;
        kill-session) return 0 ;;
        *)            return 0 ;;
    esac
}

# Isolate HOME so the kill-switch flag is sandboxed (and we never touch the real one).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"; mkdir -p "$HOME/.chump"

# ── 1: flag-file kill-switch → no launch ──────────────────────────────────────
touch "$HOME/.chump/FLEET_KEEPER_OFF"
LAUNCHED=0; MOCK_SESSION=0 ensure_worker_pool
[[ "$LAUNCHED" -eq 0 ]] && ok "FLEET_KEEPER_OFF flag → keeper does NOT launch" || fail "kill-switch flag ignored (launched anyway)"
rm -f "$HOME/.chump/FLEET_KEEPER_OFF"

# ── 2: env kill-switch → no launch ────────────────────────────────────────────
LAUNCHED=0; CHUMP_FLEET_KEEPER_DISABLE=1 MOCK_SESSION=0 ensure_worker_pool
[[ "$LAUNCHED" -eq 0 ]] && ok "CHUMP_FLEET_KEEPER_DISABLE=1 → keeper does NOT launch" || fail "env kill-switch ignored"

# ── 3: healthy pool (session up, >= target+1 panes) → no launch ───────────────
LAUNCHED=0; MOCK_SESSION=1 MOCK_PANES=3 ensure_worker_pool
[[ "$LAUNCHED" -eq 0 ]] && ok "healthy pool (3 live panes >= target+1) → no relaunch (idempotent)" || fail "relaunched a healthy pool"

# ── 4: pool down → relaunch invoked ───────────────────────────────────────────
LAUNCHED=0; MOCK_SESSION=0 ensure_worker_pool
[[ "$LAUNCHED" -eq 1 ]] && ok "pool down → keeper relaunches run-fleet" || fail "pool down but keeper did NOT relaunch"

# ── 5: pool degraded (session up but too few panes) → relaunch ────────────────
LAUNCHED=0; MOCK_SESSION=1 MOCK_PANES=1 ensure_worker_pool
[[ "$LAUNCHED" -eq 1 ]] && ok "pool degraded (1 pane < target+1) → keeper relaunches" || fail "degraded pool not revived"

echo ""
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: test-fleet-autopilot-worker-pool (durable + idempotent + kill-switches honored)"
  exit 0
else
  echo "FAIL: test-fleet-autopilot-worker-pool ($fails assertion(s) failed)"
  exit 1
fi
