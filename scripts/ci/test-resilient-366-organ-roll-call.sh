#!/usr/bin/env bash
# scripts/ci/test-resilient-366-organ-roll-call.sh — RESILIENT-366
#
# WHY THIS EXISTS. chump-backlog-sync-writer.timer was DESIGNED (RESILIENT-194)
# and later added to install-helsinki-atc.sh's SYSTEM_TIMERS roster (CREDIBLE-292)
# but sat inactive/disabled on the live node for 21 days undetected — no organ
# was watching for the case "declared in the install roster, but forgotten from
# organ-manifest.txt" (the file organ-reconcile.sh actually reads to revive a
# dead organ). A unit present ONLY in the installer's roster and absent from the
# manifest can never be self-healed: organ-reconcile only acts on lines in
# scripts/ops/organ-manifest.txt.
#
# This is the "Roll-Call": every systemd timer install-helsinki-atc.sh installs
# on the primary node must appear in organ-manifest.txt as either `enabled`
# (organ-reconcile keeps it alive) or `paging_off` (organ-reconcile deliberately
# keeps it silent) — so a future organ can never be added to the roster and
# quietly skipped from the revivable gate the way backlog-sync-writer was.
#
# Before this test existed, chump-armed-rebaser.timer and chump-board-cycle.timer
# were BOTH in this exact blind spot (declared in the installer, absent from the
# manifest) — this test fails without RESILIENT-366's manifest fix.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/setup/install-helsinki-atc.sh"
MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$INSTALLER" ] || fail "missing $INSTALLER"
[ -f "$MANIFEST" ]  || fail "missing $MANIFEST"

# chump-organ-reconcile.timer is intentionally self-excluded from the manifest
# (its own liveness is install-helsinki-atc.sh's job, per the manifest's header
# comment) — the one deliberate, documented exception to the roll-call.
EXEMPT=(chump-organ-reconcile.timer)

is_exempt() {
  local unit="$1" e
  for e in "${EXEMPT[@]}"; do
    [[ "$unit" == "$e" ]] && return 0
  done
  return 1
}

# Extract every *.timer entry from install-helsinki-atc.sh's SYSTEM_UNITS array.
mapfile -t ROSTER_TIMERS < <(
  sed -n '/^SYSTEM_UNITS=(/,/^)/p' "$INSTALLER" \
    | grep -oE 'chump-[A-Za-z0-9_-]+\.timer'
)
[ "${#ROSTER_TIMERS[@]}" -gt 0 ] || fail "no *.timer entries found in $INSTALLER SYSTEM_UNITS — parse broke"

missing=()
for unit in "${ROSTER_TIMERS[@]}"; do
  is_exempt "$unit" && continue
  # paging_off entries are declared against the .service (the oneshot unit
  # whose ExecStart gets neutered), not the .timer that fires it — so a
  # roster *.timer covers the roll-call if EITHER its own .timer line or its
  # .service sibling's line is present as enabled/paging_off.
  base="${unit%.timer}"
  if grep -qE "^(enabled|paging_off) +${unit//./\\.}( |\$)" "$MANIFEST"; then
    continue
  fi
  if grep -qE "^(enabled|paging_off) +${base//./\\.}\.service( |\$)" "$MANIFEST"; then
    continue
  fi
  missing+=("$unit")
done

if [ "${#missing[@]}" -gt 0 ]; then
  fail "roll-call gap: ${missing[*]} installed by install-helsinki-atc.sh but absent from organ-manifest.txt (organ-reconcile can never revive them — the exact silent-disable class RESILIENT-366 closes)"
fi
ok "every install-helsinki-atc.sh SYSTEM_TIMERS entry is covered by organ-manifest.txt (enabled or paging_off)"

# Specifically pin the backlog-sync --writer, since it's the organ that caused
# the 21-day undetected outage this gap traces to.
grep -qE '^enabled +chump-backlog-sync-writer\.timer' "$MANIFEST" \
  || fail "chump-backlog-sync-writer.timer must be an 'enabled' line in organ-manifest.txt (Roll-Call revivable gate)"
ok "chump-backlog-sync-writer.timer is declared 'enabled' in organ-manifest.txt"

echo "ALL PASS"
