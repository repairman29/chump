#!/usr/bin/env bash
# scripts/ci/test-resilient-366-organ-roll-call.sh — RESILIENT-366
#
# WHY THIS EXISTS. chump-backlog-sync-writer.timer was DESIGNED (RESILIENT-194)
# and later added to install-fleet-node.sh's SYSTEM_TIMERS roster (CREDIBLE-292)
# but sat inactive/disabled on the live node for 21 days undetected — no organ
# was watching for the case "declared in the install roster, but forgotten from
# organ-manifest.txt" (the file organ-reconcile.sh actually reads to revive a
# dead organ). A unit present ONLY in the installer's roster and absent from the
# manifest can never be self-healed: organ-reconcile only acts on lines in
# scripts/ops/organ-manifest.txt.
#
# This is the "Roll-Call": every systemd timer install-fleet-node.sh installs
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
INSTALLER="$REPO_ROOT/scripts/setup/install-fleet-node.sh"
MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$INSTALLER" ] || fail "missing $INSTALLER"
[ -f "$MANIFEST" ]  || fail "missing $MANIFEST"

# chump-organ-reconcile.timer is intentionally self-excluded from the manifest
# (its own liveness is install-fleet-node.sh's job, per the manifest's header
# comment) — the one deliberate, documented exception to the roll-call.
EXEMPT=(chump-organ-reconcile.timer)

is_exempt() {
  local unit="$1" e
  for e in "${EXEMPT[@]}"; do
    [[ "$unit" == "$e" ]] && return 0
  done
  return 1
}

# Extract every *.timer entry from install-fleet-node.sh's SYSTEM_TIMERS
# array — the roster actually installed (systemctl enable --now'd) at
# lines 160/268, not SYSTEM_UNITS (which is only a copy-into-place list that
# includes .service siblings never enabled as timers). SYSTEM_TIMERS is
# declared as a single-line `SYSTEM_TIMERS=(...)` array, so grab that one
# line rather than sed-ing a multi-line `(...)` block.
mapfile -t ROSTER_TIMERS < <(
  grep -oE 'chump-[A-Za-z0-9_-]+\.timer' \
    < <(grep '^SYSTEM_TIMERS=(' "$INSTALLER")
)
[ "${#ROSTER_TIMERS[@]}" -gt 0 ] || fail "no *.timer entries found in $INSTALLER SYSTEM_TIMERS — parse broke"

# Regression guard (INFRA-3645): every *.timer declared in SYSTEM_UNITS (the
# copy-into-place list) must also appear in the parsed ROSTER_TIMERS above.
# If a future rename splits the two arrays further apart, this catches a
# timer that's installed via SYSTEM_UNITS but silently excluded from the
# SYSTEM_TIMERS roll-call roster before it can reopen the silent-skip hole.
mapfile -t UNITS_TIMERS < <(
  sed -n '/^SYSTEM_UNITS=(/,/^)/p' "$INSTALLER" \
    | grep -oE 'chump-[A-Za-z0-9_-]+\.timer'
)
unroostered=()
for unit in "${UNITS_TIMERS[@]}"; do
  found=0
  for r in "${ROSTER_TIMERS[@]}"; do
    [[ "$unit" == "$r" ]] && { found=1; break; }
  done
  [ "$found" -eq 0 ] && unroostered+=("$unit")
done
if [ "${#unroostered[@]}" -gt 0 ]; then
  fail "${unroostered[*]} appears in SYSTEM_UNITS but not in SYSTEM_TIMERS — a timer can be installed without ever entering the roll-call roster this test parses (the INFRA-3645 array-mismatch class)"
fi
ok "every SYSTEM_UNITS *.timer entry is present in SYSTEM_TIMERS"

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
  fail "roll-call gap: ${missing[*]} installed by install-fleet-node.sh but absent from organ-manifest.txt (organ-reconcile can never revive them — the exact silent-disable class RESILIENT-366 closes)"
fi
ok "every install-fleet-node.sh SYSTEM_TIMERS entry (the installed roster) is covered by organ-manifest.txt (enabled or paging_off)"

# Specifically pin the backlog-sync --writer, since it's the organ that caused
# the 21-day undetected outage this gap traces to.
grep -qE '^enabled +chump-backlog-sync-writer\.timer' "$MANIFEST" \
  || fail "chump-backlog-sync-writer.timer must be an 'enabled' line in organ-manifest.txt (Roll-Call revivable gate)"
ok "chump-backlog-sync-writer.timer is declared 'enabled' in organ-manifest.txt"

# INFRA-3642 (TREK-16): pin the owned-node factory organs — worker,
# coherence-sync, and self-hosted gap-store/postgrest — that ran only as
# hand-installed units on CJ with no organ-manifest.txt line until this gap.
# Without these, organ-reconcile can never revive them, the same class of
# silent-disable this whole roll-call test exists to catch.
for unit in "chump-cj-worker.service" "chump-cj-sync.service" "chump-postgrest.service"; do
  line="$(grep -E "^enabled +${unit//./\\.}" "$MANIFEST")"
  [ -n "$line" ] || fail "$unit must be an 'enabled' line in organ-manifest.txt (INFRA-3642 owned-node factory organ)"
  echo "$line" | grep -q 'role=' || fail "organ-manifest.txt line for $unit has no role="
  echo "$line" | grep -q 'requires=' || fail "organ-manifest.txt line for $unit has no requires="
done
ok "worker/coherence-sync/gap-store organs are declared 'enabled' with role+requires in organ-manifest.txt (INFRA-3642)"

# INFRA-3826: the REVERSE roll-call. The checks above prove installer-roster ⊆
# manifest (a timer that's installed can always be revived). The OTHER direction
# had no guard, and that is exactly how chump-gap-closure-reconcile.timer sat
# dead 2026-08-21 → 2026-08-26: declared `enabled` in the manifest but ABSENT
# from install-fleet-node.sh's SYSTEM_TIMERS, so the deploy never cp'd/enabled
# it and organ-reconcile (which sees the wedged timer as `active`) never re-armed
# it. A fully general "every enabled *.timer must be in THIS installer" invariant
# would false-positive on organs installed by a dedicated installer (e.g.
# chump-almanac-liveness.timer ← install-almanac-organ.sh), so we pin the
# specific organ this gap traces to rather than encoding an over-broad rule.
# (Suspected same-class organs with no dedicated installer found —
# ci-flake-rerun, process-organ-heal, outcome-verify-heal-consumer,
# faculty-collector, pr-book-settle, organ-deploy — are filed as a follow-up for
# node verification, not asserted broken here.)
grep -qE '^enabled +chump-gap-closure-reconcile\.timer' "$MANIFEST" \
  || fail "chump-gap-closure-reconcile.timer must be an 'enabled' line in organ-manifest.txt (organ-reconcile revive gate)"
grep -qE 'chump-gap-closure-reconcile\.timer' <<<"${ROSTER_TIMERS[*]}" \
  || fail "chump-gap-closure-reconcile.timer must be in install-fleet-node.sh SYSTEM_TIMERS so the deploy installs + enables it (INFRA-3826: it was dead 2026-08-21 precisely because it was manifest-enabled but un-rostered)"
ok "chump-gap-closure-reconcile.timer is both manifest-'enabled' and installer-rostered (INFRA-3826)"

echo "ALL PASS"
