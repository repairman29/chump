#!/usr/bin/env bash
# scripts/setup/install-helsinki-atc.sh — RESILIENT-300
#
# Establishes the full "ATC roster" on the primary node (helsinki) from a
# fresh clone: the self-maintenance daemons that keep the shipping pipeline
# moving without an agent having to remember them:
#
#   chump-pr-lander      (RESILIENT-288) — arms green-but-unarmed PRs so they merge
#   chump-armed-rebaser  (INFRA-3473)    — rebases armed PRs that drift BEHIND/DIRTY
#   chump-node-refresh   (RESILIENT-200) — keeps the installed chump binary current
#   chump-board-cycle    (INFRA-3590)    — Sonnet board-cycle agent: SLA score +
#                                           stall classify + Discord report, zero
#                                           desktop session required
#
# Before RESILIENT-300, these were live-hacked directly into /etc/systemd/system
# and ~/.config/systemd/user — a node rebuild silently lost ATC. This script is
# the single, idempotent entrypoint that re-establishes the whole roster from
# tracked repo files.
#
# pr-lander + armed-rebaser are SYSTEM units (root-owned, /etc/systemd/system) —
# this script must run as root (or via sudo). node-refresh is a USER unit
# (systemd --user) — installed by delegating to install-node-refresh-systemd.sh.
#
# Idempotent: safe to re-run any time (e.g. after a node rebuild, or to pick up
# unit-file changes) — copies + daemon-reload + enable --now every time.
#
# Usage:
#   sudo bash scripts/setup/install-helsinki-atc.sh
#   sudo bash scripts/setup/install-helsinki-atc.sh --check   # exit 0 iff all 3 timers active

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

SYSTEM_UNITS=(
  chump-pr-lander.service
  chump-pr-lander.timer
  chump-armed-rebaser.service
  chump-armed-rebaser.timer
  chump-board-cycle.service
  chump-board-cycle.timer
)
SYSTEM_TIMERS=(chump-pr-lander.timer chump-armed-rebaser.timer chump-board-cycle.timer)

# ── --check mode ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
  fail=0
  for t in "${SYSTEM_TIMERS[@]}"; do
    if ! systemctl is-active --quiet "$t" 2>/dev/null; then
      echo "MISSING: $t not active"; fail=1
    fi
  done
  if ! systemctl --user is-active --quiet chump-node-refresh.timer 2>/dev/null; then
    echo "MISSING: chump-node-refresh.timer (user) not active"; fail=1
  fi
  [[ "$fail" == 0 ]] && echo "ok: full ATC roster active"
  exit "$fail"
fi

if [[ "$(id -u)" != "0" ]]; then
  echo "ERROR: system units require root (sudo bash $0)" >&2
  exit 1
fi

echo "== installing system units (pr-lander, armed-rebaser) =="
for unit in "${SYSTEM_UNITS[@]}"; do
  src="$REPO_ROOT/scripts/dispatch/$unit"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: $src not found" >&2
    exit 1
  fi
  cp -f "$src" "/etc/systemd/system/$unit"
  echo "  installed $unit"
done

systemctl daemon-reload
for t in "${SYSTEM_TIMERS[@]}"; do
  systemctl enable --now "$t"
  echo "  enabled + started $t"
done

echo "== installing user unit (node-refresh) =="
# node-refresh runs as the operator user (not root's systemd --user unless
# helsinki genuinely operates as root), so hand off to its own installer,
# which generates the unit files directly rather than tracking static copies.
NODE_REFRESH_INSTALLER="$REPO_ROOT/scripts/setup/install-node-refresh-systemd.sh"
if [[ ! -f "$NODE_REFRESH_INSTALLER" ]]; then
  echo "ERROR: $NODE_REFRESH_INSTALLER not found" >&2
  exit 1
fi
CHUMP_NODE_REPO="$REPO_ROOT" bash "$NODE_REFRESH_INSTALLER"

echo ""
echo "== ATC roster status =="
systemctl list-timers "${SYSTEM_TIMERS[@]}" --no-pager 2>/dev/null || true
systemctl --user list-timers chump-node-refresh.timer --no-pager 2>/dev/null || true

echo ""
echo "Verify: bash $0 --check"
