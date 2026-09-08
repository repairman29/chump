#!/usr/bin/env bash
# install-mission-grade-launchd.sh — INFRA-599 / CREDIBLE-421: install a
# recurring cron job that runs `chump mission-grade` every 30 minutes,
# emitting a kind=mission_grade event to .chump-locks/ambient.jsonl so
# `chump kpi report`'s "Mission Grade History" trend is never empty and the
# operator never has to ask "are we on mission?" manually.
#
# CREDIBLE-421: this used to hand-roll a macOS-only launchd plist, which
# meant it silently did nothing on Linux workers and was never wired into
# chump-fleet-bootstrap.sh's daemon manifest — so the gauge stayed dark on
# every machine. Now delegates to `chump cron install` (INFRA-2057), which
# auto-detects launchd (macOS) vs systemd --user (Linux) and is idempotent.
#
# Disable: chump cron uninstall --name mission-grade
# Status:  chump cron status --name mission-grade
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

CHUMP_BIN="$(command -v chump || echo "$HOME/.cargo/bin/chump")"
if [[ ! -x "$CHUMP_BIN" ]]; then
  echo "ERROR: chump binary not found (looked at PATH and $HOME/.cargo/bin/chump)" >&2
  exit 1
fi

"$CHUMP_BIN" cron install --name mission-grade --interval 1800s \
  --exec "$CHUMP_BIN mission-grade" \
  --working-dir "$REPO" \
  --description "CREDIBLE-421/INFRA-599: 4-pillar mission scorecard, emits kind=mission_grade to ambient.jsonl" \
  --stdout-log /tmp/chump-mission-grade.out.log \
  --stderr-log /tmp/chump-mission-grade.err.log \
  --env "CHUMP_REPO_ROOT=$REPO"

echo
"$CHUMP_BIN" cron status --name mission-grade || true
echo
echo "Fires every 30 min (installs run immediately too)."
echo "Force fire  : chump mission-grade"
echo "Tail logs   : tail -f /tmp/chump-mission-grade.{out,err}.log"
echo "Check event : tail -5 $REPO/.chump-locks/ambient.jsonl | grep mission_grade"
echo "Full trend  : chump kpi report"
