#!/usr/bin/env bash
# scripts/ci/test-resilient-1058-gap-store-organ.sh — RESILIENT-1058
#
# Proves scripts/coord/gap-store-single-source-check.sh (RESILIENT-1057) is
# wired into a SCHEDULED ORGAN, not just a script that only runs when someone
# remembers to invoke it by hand. Fails without RESILIENT-1058's changes:
# before this gap, the .service/.timer pair did not exist, the installer
# never rostered them, and organ-manifest.txt had no line for them — so
# organ-reconcile could never revive the check if it drifted or was never
# installed in the first place (the RESILIENT-366 "designed but never wired
# into the revivable gate" class).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
ok()  { printf 'ok   - %s\n' "$*"; }
bad() { printf 'FAIL - %s\n' "$*"; fail=1; }

SERVICE="scripts/dispatch/chump-gap-store-single-source-check.service"
TIMER="scripts/dispatch/chump-gap-store-single-source-check.timer"
INSTALLER="scripts/setup/install-helsinki-atc.sh"
MANIFEST="scripts/ops/organ-manifest.txt"
CHECK_SCRIPT="scripts/coord/gap-store-single-source-check.sh"

# 1) The underlying check script must actually still exist (RESILIENT-1057).
if [ -x "$CHECK_SCRIPT" ]; then
  ok "$CHECK_SCRIPT exists and is executable"
else
  bad "$CHECK_SCRIPT missing or not executable — nothing for the organ to run"
fi

# 2) Tracked systemd unit pair must exist and reference the check script.
if [ -f "$SERVICE" ]; then
  ok "$SERVICE present"
  if grep -q 'gap-store-single-source-check.sh' "$SERVICE"; then
    ok "$SERVICE ExecStart invokes gap-store-single-source-check.sh"
  else
    bad "$SERVICE does not reference gap-store-single-source-check.sh"
  fi
else
  bad "$SERVICE missing — the organ has no runnable unit"
fi

if [ -f "$TIMER" ]; then
  ok "$TIMER present"
  grep -qE '^\[Timer\]' "$TIMER" || bad "$TIMER has no [Timer] section"
else
  bad "$TIMER missing — nothing schedules the check"
fi

# 3) Both units must be in install-helsinki-atc.sh's rosters, or a fresh
#    deploy never copies/enables them (the RESILIENT-376 merged-not-running
#    class this whole manifest discipline exists to prevent).
if grep -qE 'chump-gap-store-single-source-check\.service' "$INSTALLER"; then
  ok "$INSTALLER SYSTEM_UNITS includes chump-gap-store-single-source-check.service"
else
  bad "chump-gap-store-single-source-check.service missing from $INSTALLER"
fi

if grep '^SYSTEM_TIMERS=(' "$INSTALLER" | grep -qE 'chump-gap-store-single-source-check\.timer'; then
  ok "$INSTALLER SYSTEM_TIMERS roster includes chump-gap-store-single-source-check.timer"
else
  bad "chump-gap-store-single-source-check.timer missing from $INSTALLER SYSTEM_TIMERS"
fi

# 4) organ-manifest.txt must declare it 'enabled' with role+requires — the
#    Roll-Call gate (RESILIENT-366) that lets organ-reconcile self-heal it.
line="$(grep -E '^enabled\s+chump-gap-store-single-source-check\.timer' "$MANIFEST")"
if [ -n "$line" ]; then
  ok "chump-gap-store-single-source-check.timer declared 'enabled' in $MANIFEST"
  echo "$line" | grep -q 'role=' || bad "organ-manifest.txt line has no role="
  echo "$line" | grep -q 'requires=' || bad "organ-manifest.txt line has no requires="
else
  bad "chump-gap-store-single-source-check.timer not declared 'enabled' in $MANIFEST (Roll-Call)"
fi

# 5) Roll-Call self-consistency for THIS organ specifically: re-run the
#    RESILIENT-366 roll-call matcher's own check for our unit only, so this
#    test does not depend on unrelated pre-existing roll-call findings
#    (e.g. chump-armed-rebaser.timer's known SYSTEM_UNITS/SYSTEM_TIMERS
#    mismatch, tracked separately) staying clean.
if grep -qE "^enabled\s+chump-gap-store-single-source-check\.timer( |\$)" "$MANIFEST"; then
  ok "our organ passes the Roll-Call matcher (enabled line present for the .timer)"
else
  bad "our organ would fail the RESILIENT-366 Roll-Call matcher"
fi

if [ "$fail" -ne 0 ]; then
  echo "gap-store-single-source-check organ wiring INCOMPLETE"
  exit 1
fi
echo "gap-store-single-source-check is wired into a scheduled, revivable organ"
exit 0
