#!/usr/bin/env bash
# scripts/ci/test-manifest-installer-parity.sh — RESILIENT-376 (manifest->installer parity)
#
# WHY THIS EXISTS. The install path is the ribbon: fresh box -> one command ->
# working factory. An organ only reproduces on a fresh node if SOMETHING on the
# install path installs its systemd unit. scripts/ops/organ-reconcile.sh keeps a
# manifest-`enabled` organ ALIVE, but it can only `enable --now` a unit whose
# FILE already landed in /etc/systemd/system — and on the primary/owned-node path
# that copy happens in scripts/setup/install-helsinki-atc.sh's SYSTEM_UNITS
# roster (with the .timer additionally in SYSTEM_TIMERS). So a unit declared
# `enabled` in the manifest but ABSENT from that roster (and from every dedicated
# installer) stays DARK on a clean install: reconcile's enable fails on the
# missing unit -> backoff -> the "runs on CJ but wouldn't reproduce" drift.
#
# This is the ENFORCEMENT GATE for the RESILIENT-376 rule (manifest ⊆ install
# path). test-resilient-366-organ-roll-call.sh guards the REVERSE direction
# (installer roster ⊆ manifest, so an installed timer is always revivable) but
# only PINS a couple of specific organs for this direction because a naive
# "every enabled organ must be in install-helsinki-atc.sh" rule false-positives
# on organs installed by a DEDICATED installer (e.g. almanac-liveness <-
# install-almanac-organ.sh, postgrest <- install-gap-substrate.sh) or generated
# per-node (the cj-* concrete owned-node units). This test encodes that nuance
# explicitly: an `enabled` organ passes if it is EITHER in the install-helsinki
# -atc.sh roster OR in the DEDICATED/NODE-GENERATED exclusion map below — and the
# exclusion map is kept honest (a dedicated-installer path must still exist on
# disk, and a stale exclusion for a no-longer-enabled organ fails the test).
#
# 2026-08-30 drift this closed: ci-flake-rerun, discord-gateway, faculty-collector,
# next-best-action, organ-deploy, outcome-verify-heal-consumer, pr-book-settle,
# process-organ-heal were all manifest-`enabled` but un-rostered (their only
# installers were Mac-launchd-only or nonexistent) — DARK on a fresh Linux node.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/setup/install-helsinki-atc.sh"
MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$INSTALLER" ] || fail "missing $INSTALLER"
[ -f "$MANIFEST" ]  || fail "missing $MANIFEST"

# ── Excluded organs: manifest-`enabled` but deliberately NOT in the
# install-helsinki-atc.sh roster because a DEDICATED installer (value = the
# installer file, which MUST exist so the exclusion can't silently rot) or
# per-node generation (value = NODE_GENERATED) installs them instead. Add a
# line here — with a real reason — only when you genuinely move an organ's
# install off install-helsinki-atc.sh; the default answer is to roster it.
declare -A EXCLUDED=(
  [chump-almanac-liveness.timer]="scripts/setup/install-almanac-organ.sh"
  [chump-postgrest.service]="scripts/setup/install-gap-substrate.sh"
  [chump-cj-disk-monitor.service]="scripts/setup/install-node-housekeeping.sh"
  # cj-worker / cj-sync are CJ-concrete owned-node units (RESILIENT-345 /
  # INFRA-3642) generated/hand-installed on the node, not from a repo-tracked
  # static unit file — deliberately manifest-only (and pinned as owned-node
  # factory organs by test-resilient-366-organ-roll-call.sh).
  [chump-cj-worker.service]="NODE_GENERATED"
  [chump-cj-sync.service]="NODE_GENERATED"
)

# ── Parse the manifest's `enabled` organs.
mapfile -t ENABLED < <(grep -E '^enabled' "$MANIFEST" | awk '{print $2}' | sort -u)
[ "${#ENABLED[@]}" -gt 0 ] || fail "no 'enabled' organs parsed from $MANIFEST — parse broke"

# ── Parse the installer roster = SYSTEM_UNITS (multi-line copy-into-place list)
# ∪ SYSTEM_TIMERS (single-line enable list). A unit is "rostered" (its file will
# land, so reconcile can enable it) iff it appears in either.
mapfile -t ROSTER < <(
  {
    sed -n '/^SYSTEM_UNITS=(/,/^)/p' "$INSTALLER" | grep -oE 'chump-[A-Za-z0-9_-]+\.(service|timer)'
    grep '^SYSTEM_TIMERS=(' "$INSTALLER" | grep -oE 'chump-[A-Za-z0-9_-]+\.timer'
  } | sort -u
)
[ "${#ROSTER[@]}" -gt 0 ] || fail "no units parsed from $INSTALLER SYSTEM_UNITS/SYSTEM_TIMERS — parse broke"

in_roster()   { local u="$1" r; for r in "${ROSTER[@]}";   do [[ "$u" == "$r" ]] && return 0; done; return 1; }
is_enabled()  { local u="$1" e; for e in "${ENABLED[@]}";  do [[ "$u" == "$e" ]] && return 0; done; return 1; }

# ── Guard: keep the exclusion map honest.
#   (a) a dedicated-installer path listed here must still exist on disk;
#   (b) an excluded organ that is no longer manifest-`enabled` is a stale entry
#       (delete it) — flag it so the allowlist can't quietly rot.
for unit in "${!EXCLUDED[@]}"; do
  reason="${EXCLUDED[$unit]}"
  if [[ "$reason" != "NODE_GENERATED" ]]; then
    [ -f "$REPO_ROOT/$reason" ] || fail "exclusion for $unit names a dedicated installer '$reason' that does NOT exist — the exclusion is no longer valid; roster the organ or fix the path"
  fi
  is_enabled "$unit" || fail "stale exclusion: $unit is in the EXCLUDED map but is no longer 'enabled' in organ-manifest.txt — remove the stale entry"
done
ok "exclusion map is honest (every dedicated-installer path exists; no stale entries)"

# ── The parity check: every manifest-`enabled` organ must be rostered OR excluded.
missing=()
for unit in "${ENABLED[@]}"; do
  in_roster "$unit" && continue
  [[ -n "${EXCLUDED[$unit]:-}" ]] && continue
  missing+=("$unit")
done

if [ "${#missing[@]}" -gt 0 ]; then
  printf '\n' >&2
  for u in "${missing[@]}"; do
    printf '  DARK-ON-FRESH-INSTALL: %s is enabled in organ-manifest.txt but is neither in install-helsinki-atc.sh SYSTEM_UNITS/SYSTEM_TIMERS nor in this test'"'"'s dedicated-installer exclusion map\n' "$u" >&2
  done
  fail "${#missing[@]} manifest-'enabled' organ(s) would stay DARK on a fresh install (RESILIENT-376). Add each to install-helsinki-atc.sh's roster (both .service and .timer to SYSTEM_UNITS, the .timer also to SYSTEM_TIMERS; a service-only organ goes in SYSTEM_UNITS and organ-reconcile enables it), or — only if a dedicated installer genuinely owns it — add an EXCLUDED entry above."
fi
ok "every manifest-'enabled' organ (${#ENABLED[@]}) is covered by the install path (install-helsinki-atc.sh roster or a dedicated installer)"

echo "ALL PASS"
