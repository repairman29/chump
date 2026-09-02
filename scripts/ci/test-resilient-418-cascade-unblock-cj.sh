#!/usr/bin/env bash
# scripts/ci/test-resilient-418-cascade-unblock-cj.sh — RESILIENT-418
#
# armed-pr-rebaser (INFRA-3473/RESILIENT-366) was already ported from
# Mac-launchd to CJ systemd. cascade-unblock-detector (INFRA-2070) was NOT:
# it only had a launchd installer (install-meta-118-daemons.sh), so on CJ
# nothing fanned a merged wedge_auto_fix PR out to sibling PRs blocked on the
# same failure signature — those PRs sat stale until a human manually reran
# `gh pr update-branch` after a gate fix landed.
#
# This test pins the three things that must ALL be true for CJ systemd to run
# and self-heal cascade-unblock-detector, the same "roll-call" shape as
# scripts/ci/test-resilient-366-organ-roll-call.sh:
#   1. the tracked systemd unit files exist
#   2. install-fleet-node.sh's SYSTEM_UNITS/SYSTEM_TIMERS roster includes them
#   3. organ-manifest.txt declares the timer `enabled` (so organ-reconcile can
#      revive it if it ever goes dark)
#
# Fails without RESILIENT-418's fix (none of the three existed before).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SERVICE="$REPO_ROOT/scripts/dispatch/chump-cascade-unblock-detector.service"
TIMER="$REPO_ROOT/scripts/dispatch/chump-cascade-unblock-detector.timer"
INSTALLER="$REPO_ROOT/scripts/setup/install-fleet-node.sh"
MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$SERVICE" ] || fail "missing $SERVICE — cascade-unblock-detector has no CJ systemd unit"
[ -f "$TIMER" ]   || fail "missing $TIMER — cascade-unblock-detector has no CJ systemd timer"
ok "chump-cascade-unblock-detector.service and .timer exist"

grep -q 'scripts/coord/cascade-unblock-detector.sh' "$SERVICE" \
  || fail "$SERVICE does not exec scripts/coord/cascade-unblock-detector.sh"
ok "service unit execs the real cascade-unblock-detector.sh script"

grep -qE 'chump-cascade-unblock-detector\.service' <(sed -n '/^SYSTEM_UNITS=(/,/^)/p' "$INSTALLER") \
  || fail "chump-cascade-unblock-detector.service missing from install-fleet-node.sh SYSTEM_UNITS — will never be copied to /etc/systemd/system"
grep -qE 'chump-cascade-unblock-detector\.timer' <(sed -n '/^SYSTEM_UNITS=(/,/^)/p' "$INSTALLER") \
  || fail "chump-cascade-unblock-detector.timer missing from install-fleet-node.sh SYSTEM_UNITS — will never be copied to /etc/systemd/system"
grep -qE 'chump-cascade-unblock-detector\.timer' <(grep '^SYSTEM_TIMERS=(' "$INSTALLER") \
  || fail "chump-cascade-unblock-detector.timer missing from install-fleet-node.sh SYSTEM_TIMERS — will never be enable --now'd"
ok "install-fleet-node.sh roster (SYSTEM_UNITS + SYSTEM_TIMERS) includes cascade-unblock-detector"

grep -qE '^enabled +chump-cascade-unblock-detector\.timer' "$MANIFEST" \
  || fail "chump-cascade-unblock-detector.timer must be an 'enabled' line in organ-manifest.txt (organ-reconcile revive gate)"
ok "chump-cascade-unblock-detector.timer is declared 'enabled' in organ-manifest.txt"

echo "ALL PASS"
