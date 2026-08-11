#!/usr/bin/env bash
# scripts/setup/install-helsinki-atc.sh — RESILIENT-300, auto-deploy path INFRA-3593
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
#   chump-sla-scorecard  (RESILIENT-302) — flags PRs open >30m unmerged with no
#                                           owner as a board BREACH
#
# Before RESILIENT-300, these were live-hacked directly into /etc/systemd/system
# and ~/.config/systemd/user — a node rebuild silently lost ATC. This script is
# the single, idempotent entrypoint that re-establishes the whole roster from
# tracked repo files.
#
# pr-lander, armed-rebaser, sla-scorecard, board-cycle are SYSTEM units
# (root-owned, /etc/systemd/system) — this script must run as root (or via
# sudo). node-refresh is a USER unit (systemd --user) — installed by
# delegating to install-node-refresh-systemd.sh.
#
# Idempotent: safe to re-run any time (e.g. after a node rebuild, or to pick up
# unit-file changes) — copies + daemon-reload + enable --now every time.
#
# INFRA-3593: this is also the AUTO-DEPLOY entrypoint. node-refresh-chump.sh
# (RESILIENT-200) calls this script with --auto after every fast-forward to
# origin/main, so a merge that touches a chump-*.service/.timer file installs
# on helsinki with no human step — mirroring how node-refresh already
# auto-deploys binary changes. --auto diffs each tracked unit file against
# what's live in /etc/systemd/system BEFORE copying, and emits
# kind=organ_units_deployed (listing only the units that actually changed)
# so the board can verify the auto-deploy ran (AC 7). If nothing changed, it
# emits kind=organ_units_deploy_skipped instead — quiet on the common path,
# but still observable that the check happened (INFRA-3593 AC 1/7).
# --auto degrades to a warning (not a hard failure) when not root, since it
# may be invoked from a non-privileged refresh context — see
# kind=organ_units_deploy_failed reason=not_root.
#
# Usage:
#   sudo bash scripts/setup/install-helsinki-atc.sh
#   sudo bash scripts/setup/install-helsinki-atc.sh --check   # exit 0 iff all timers active
#   bash scripts/setup/install-helsinki-atc.sh --auto         # merge-triggered auto-deploy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
AMBIENT_LOG="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
LIB_AMBIENT="$REPO_ROOT/scripts/coord/lib/ambient-write.sh"
[[ -f "$LIB_AMBIENT" ]] && source "$LIB_AMBIENT"

emit() {  # kind, extra-json (no leading/trailing comma)
  local kind="$1" extra="${2:-}"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line
  if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
  else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
  if command -v _ambient_write >/dev/null 2>&1; then
    [[ -d "$(dirname "$AMBIENT_LOG")" ]] && _ambient_write "$AMBIENT_LOG" "$line"
  else
    [[ -d "$(dirname "$AMBIENT_LOG")" ]] && printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
  fi
}

SYSTEM_UNITS=(
  chump-pr-lander.service
  chump-pr-lander.timer
  chump-armed-rebaser.service
  chump-armed-rebaser.timer
  chump-board-cycle.service
  chump-board-cycle.timer
  chump-sla-scorecard.service
  chump-sla-scorecard.timer
)
SYSTEM_TIMERS=(chump-pr-lander.timer chump-armed-rebaser.timer chump-board-cycle.timer chump-sla-scorecard.timer)

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

AUTO=0
[[ "${1:-}" == "--auto" ]] && AUTO=1

if [[ "$(id -u)" != "0" ]]; then
  if [[ "$AUTO" == "1" ]]; then
    echo "WARN: --auto invoked without root; skipping system-unit deploy (this worker context cannot install system units)" >&2
    # scanner-anchor: "kind":"organ_units_deploy_failed"  (INFRA-3593; fires
    # when the auto-deploy caller lacks root and cannot write /etc/systemd/system)
    emit organ_units_deploy_failed "\"reason\":\"not_root\""
    exit 0
  fi
  echo "ERROR: system units require root (sudo bash $0)" >&2
  exit 1
fi

echo "== installing system units (pr-lander, armed-rebaser, sla-scorecard, board-cycle) =="
CHANGED_UNITS=()
for unit in "${SYSTEM_UNITS[@]}"; do
  src="$REPO_ROOT/scripts/dispatch/$unit"
  dest="/etc/systemd/system/$unit"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: $src not found" >&2
    exit 1
  fi
  if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
    CHANGED_UNITS+=("$unit")
  fi
  cp -f "$src" "$dest"
  echo "  installed $unit"
done

if ! systemctl daemon-reload 2>&1; then
  echo "ERROR: systemctl daemon-reload failed (no systemd bus reachable?)" >&2
  emit organ_units_deploy_failed "\"reason\":\"systemctl_daemon_reload_failed\""
  [[ "$AUTO" == "1" ]] && exit 0
  exit 1
fi
for t in "${SYSTEM_TIMERS[@]}"; do
  if ! systemctl enable --now "$t" 2>&1; then
    echo "ERROR: systemctl enable --now $t failed" >&2
    emit organ_units_deploy_failed "\"reason\":\"systemctl_enable_failed\",\"unit\":\"$t\""
    [[ "$AUTO" == "1" ]] && exit 0
    exit 1
  fi
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
CHUMP_NODE_REPO="$REPO_ROOT" bash "$NODE_REFRESH_INSTALLER" \
  || echo "WARN: node-refresh user-unit install failed (non-fatal; system units above still installed)" >&2

echo ""
echo "== ATC roster status =="
systemctl list-timers "${SYSTEM_TIMERS[@]}" --no-pager 2>/dev/null || true
systemctl --user list-timers chump-node-refresh.timer --no-pager 2>/dev/null || true

if [[ "${#CHANGED_UNITS[@]}" -gt 0 ]]; then
  units_json="$(printf '"%s",' "${CHANGED_UNITS[@]}")"
  units_json="[${units_json%,}]"
  # scanner-anchor: "kind":"organ_units_deployed"  (INFRA-3593; fires only
  # when a chump-*.service/.timer diff was actually installed — the
  # merge-triggered auto-deploy signal the board polls to verify AC 1/7)
  emit organ_units_deployed "\"units\":$units_json,\"auto\":$([[ "$AUTO" == 1 ]] && echo true || echo false)"
  echo ""
  echo "deployed (changed): ${CHANGED_UNITS[*]}"
else
  # scanner-anchor: "kind":"organ_units_deploy_skipped"  (INFRA-3593; no unit
  # diff found — roster already current, no-op on the common auto-deploy path)
  emit organ_units_deploy_skipped "\"auto\":$([[ "$AUTO" == 1 ]] && echo true || echo false)"
fi

echo ""
echo "Verify: bash $0 --check"
