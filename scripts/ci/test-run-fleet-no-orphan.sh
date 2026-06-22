#!/usr/bin/env bash
# RESILIENT-159 regression: run-fleet must NOT leak orphaned background procs.
# Root cause of the 49-orphan pile-up: the token refresher looped `sleep 300`
# forever with no session check, so a dead/never-launched fleet left it orphaned
# to PPID 1. Two cures, both pinned here:
#   1. the refresher self-exits when the fleet tmux session is gone;
#   2. an EXIT trap reaps spawned bg children when run-fleet exits without a
#      live session (covers the pre-first-check window).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.."
ROOT="$(cd "$ROOT" && pwd)"
RF="$ROOT/scripts/dispatch/run-fleet.sh"
[[ -f "$RF" ]] || { echo "FAIL: run-fleet.sh not found"; exit 1; }

fails=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

# ── 1. STATIC: the token refresher self-exits on session-gone ─────────────────
if grep -A12 'while true; do' "$RF" | grep -qE 'has-session -t "\$FLEET_SESSION" 2>/dev/null \|\| exit 0'; then
  ok "token refresher self-exits when fleet session is gone (no orphan loop)"
else
  fail "token refresher missing self-exit guard — would orphan on fleet death"
fi

# ── 2. STATIC: EXIT trap reaps bg children on setup-failure ───────────────────
if grep -q 'trap _reap_bg_if_no_fleet EXIT' "$RF"; then
  ok "EXIT trap installed (reaps bg children when launch leaves no session)"
else
  fail "no EXIT trap — a setup-killed launch would orphan its children"
fi

# ── 3. BEHAVIORAL: _reap_bg_if_no_fleet reaps iff no session ──────────────────
# Probe process-management visibility (sandboxes restrict it → skip loudly).
sleep 30 & _probe=$!
sleep 1
if ! kill -0 "$_probe" 2>/dev/null; then
  echo "  SKIP: cannot observe/manage child processes here (sandbox) — behavioral check skipped (runs in CI)"
  [[ "$fails" -eq 0 ]] && { echo "PASS: test-run-fleet-no-orphan (static checks; behavioral skipped)"; exit 0; } || { echo "FAIL ($fails)"; exit 1; }
fi
kill "$_probe" 2>/dev/null || true

eval "$(sed -n '/^_reap_bg_if_no_fleet() {/,/^}/p' "$RF")"
type _reap_bg_if_no_fleet >/dev/null 2>&1 || { echo "FAIL: could not extract _reap_bg_if_no_fleet"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FLEET_PIDS_FILE="$tmp/pids"
export FLEET_SESSION="test-nosuchsession-$$"

# (a) no session → tracked pid reaped
tmux() { [[ "${1:-}" == "has-session" ]] && return 1 || return 0; }
sleep 60 & victim=$!; echo "$victim" > "$FLEET_PIDS_FILE"
_reap_bg_if_no_fleet
sleep 1
if kill -0 "$victim" 2>/dev/null; then fail "no-session: tracked bg pid NOT reaped (orphan leak)"; kill "$victim" 2>/dev/null || true; else ok "no fleet session → tracked bg pid reaped (leak fixed)"; fi

# (b) session up → tracked pid spared (it supports the running fleet)
tmux() { return 0; }  # has-session succeeds
sleep 60 & keep=$!; echo "$keep" > "$FLEET_PIDS_FILE"
_reap_bg_if_no_fleet
if kill -0 "$keep" 2>/dev/null; then ok "live fleet session → tracked bg pid SPARED (supports the pool)"; kill "$keep" 2>/dev/null || true; else fail "session-up: pid wrongly reaped"; fi

echo ""
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: test-run-fleet-no-orphan (refresher self-exits; trap reaps only when no fleet)"
  exit 0
else
  echo "FAIL: test-run-fleet-no-orphan ($fails assertion(s) failed)"
  exit 1
fi
