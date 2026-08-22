#!/usr/bin/env bash
# organ-deploy.sh — RESILIENT-374. The root-privileged self-deploy organ.
#
# WHY THIS EXISTS (merged-not-running disease, owned-node instance).
# On the PRIMARY helsinki node, chump-organ-watchdog and chump-organ-reconcile
# ran as root, so they could write /etc/systemd/system and `enable --now` every
# merged chump-*.service/.timer. On an OWNED node (CJ, User=jeff) the same
# organs are host-rewritten to run as the repo-owning user — and BOTH then fail
# their one privileged job every cycle:
#     chump-organ-reconcile:  "needs root to write /etc/systemd/system; skipping"
#     chump-organ-watchdog:   "--auto invoked without root; skipping system-unit deploy"
# So on CJ, a gap's PR could MERGE, add a fully-formed organ (unit file +
# `enabled` manifest row), and that organ would sit DARK forever: installed in
# the repo, never installed in systemd. Merged, not running — verified live:
# chump-outcome-verify-heal-consumer (#4119, INFRA-3654) merged and was never
# `systemctl is-active` on CJ because nothing privileged ever deployed it.
#
# This organ closes that hole at its root: it runs the privileged deploy AS
# ROOT (its unit is User=root — the one deliberate exception to the host
# de-privilege rewrite, see scripts/setup/install-helsinki-atc.sh
# _KEEP_ROOT_ORGANS). install-helsinki-atc.sh --auto then installs every
# manifest-declared unit, `enable --now`s it, and runs organ-reconcile — so a
# merged organ actually RUNS on the target. It is the standing anti-
# "merged-not-running" faculty for owned nodes.
#
# Algorithm (oneshot, driven by chump-organ-deploy.timer):
#   1. Refuse cheaply if not root (its job IS the root-only write; a non-root
#      run is a no-op, never a crash — the unit runs User=root so this only
#      trips in tests / manual mis-invocation).
#   2. Point CARGO_BIN_DIR at the repo-owner's cargo bin so install-helsinki-
#      atc's integrator-binary guard finds the existing binary and never builds
#      as root inside the owner's checkout.
#   3. Run install-helsinki-atc.sh --auto (install + enable --now + reconcile),
#      whose own registered ambient kinds (organ_units_deployed / _skipped /
#      _failed, organ_reconcile_applied) are the observability for the actions.
#   4. Advisory audit: count manifest `enabled` organs still not is-active after
#      the deploy and log them (a merged-not-running residue the next cycle, or
#      a human, should look at). Log-only — no new ambient kinds, no paging.
#
# Env / test hooks:
#   CHUMP_REPO_ROOT                       repo checkout root (default: derived)
#   CHUMP_ORGAN_DEPLOY_INSTALLER          override install-helsinki-atc.sh path
#   CHUMP_ORGAN_DEPLOY_SYSTEMCTL_BIN      override `systemctl` (audit stub)
#   CHUMP_ORGAN_DEPLOY_ALLOW_NONROOT=1    run the deploy path without root (tests)
#   CARGO_BIN_DIR                         integrator-binary dir (default: owner ~/.cargo/bin)
#
# Exit code: propagates install-helsinki-atc.sh --auto's exit (0 on the common
# path; --auto is itself non-fatal by design).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
INSTALLER="${CHUMP_ORGAN_DEPLOY_INSTALLER:-$REPO_ROOT/scripts/setup/install-helsinki-atc.sh}"
SYSTEMCTL_BIN="${CHUMP_ORGAN_DEPLOY_SYSTEMCTL_BIN:-systemctl}"
MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"

log() { printf '[%s] organ-deploy: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

if [[ "$(id -u)" != "0" && "${CHUMP_ORGAN_DEPLOY_ALLOW_NONROOT:-0}" != "1" ]]; then
  log "not root — the privileged system-unit deploy needs root; nothing to do (non-fatal). This organ's unit runs User=root."
  exit 0
fi

if [[ ! -f "$INSTALLER" ]]; then
  log "ERROR: installer not found at $INSTALLER"
  exit 0
fi

# Point the integrator-binary guard at the repo owner's cargo bin so it finds
# the existing binary and never triggers a root-owned cargo build in the tree.
if [[ -z "${CARGO_BIN_DIR:-}" ]]; then
  _owner="$(stat -c %U "$REPO_ROOT" 2>/dev/null || echo root)"
  _ownhome="$(getent passwd "$_owner" 2>/dev/null | cut -d: -f6)"
  [[ -z "$_ownhome" ]] && _ownhome="/home/$_owner"
  export CARGO_BIN_DIR="$_ownhome/.cargo/bin"
fi

log "privileged deploy: $INSTALLER --auto (REPO_ROOT=$REPO_ROOT CARGO_BIN_DIR=$CARGO_BIN_DIR)"
CHUMP_REPO_ROOT="$REPO_ROOT" bash "$INSTALLER" --auto
rc=$?
log "install-helsinki-atc --auto exit=$rc"

# Advisory post-deploy audit (log-only; no new ambient kinds).
if [[ -f "$MANIFEST" ]]; then
  dark=0; total=0
  while read -r state unit _rest; do
    [[ "$state" == "enabled" ]] || continue
    case "$unit" in *.service|*.timer) : ;; *) continue ;; esac
    total=$((total + 1))
    if ! "$SYSTEMCTL_BIN" is-active --quiet "$unit" 2>/dev/null; then
      dark=$((dark + 1)); log "STILL DARK after deploy: $unit"
    fi
  done < <(grep -E '^enabled[[:space:]]' "$MANIFEST" 2>/dev/null)
  log "post-deploy manifest audit: $((total - dark))/$total enabled organs active ($dark still dark)"
fi

exit "$rc"
