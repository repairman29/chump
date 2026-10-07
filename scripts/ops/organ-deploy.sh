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
#   4. Advisory audit: classify every manifest `enabled` organ after the deploy —
#      active, scoped off this node (platforms=/requires=), or UNEXPECTED-DARK with
#      a named root cause (unit-missing / unit-not-installed / exec-missing /
#      unmet-requires / inactive; RESILIENT-1534). Log-only — no new ambient
#      kinds, no paging. `organ-deploy.sh --audit-only` runs just this audit (no
#      root, no installer) and exits 1 while any UNEXPECTED-DARK organ remains.
#
# Env / test hooks:
#   CHUMP_REPO_ROOT                       repo checkout root (default: derived)
#   CHUMP_ORGAN_DEPLOY_INSTALLER          override install-helsinki-atc.sh path
#   CHUMP_ORGAN_DEPLOY_SYSTEMCTL_BIN      override `systemctl` (audit stub)
#   CHUMP_ORGAN_DEPLOY_SYSTEMD_DIR        where installed units live (default /etc/systemd/system)
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

# RESILIENT-1534: the post-deploy audit, as a function so `--audit-only` can run it
# on its own (no root, no installer). It no longer counts an organ the manifest
# scopes OFF this node (platforms=launchd on a systemd hub) or whose requires= is
# unmet as a silent "STILL DARK": every non-active organ is classified with a ROOT
# CAUSE (organ_dark_cause), and only the unexplained-or-faulty ones are
# UNEXPECTED-DARK. Returns 1 when any UNEXPECTED-DARK organ remains.
LIB="$SCRIPT_DIR/lib/organ-manifest-lib.sh"
organ_audit() {
  [[ -f "$MANIFEST" && -f "$LIB" ]] || return 0
  # shellcheck disable=SC1090
  source "$LIB"
  local _po=() _en=() unit cause current current_node sysdir="${CHUMP_ORGAN_DEPLOY_SYSTEMD_DIR:-/etc/systemd/system}"
  declare -A _role _req _plat _node
  organ_manifest_parse "$MANIFEST" _po _en _role _req _plat _node || return 0
  current="$(organ_current_platform)"
  current_node="$(organ_current_node)"
  local total=0 active=0 scoped=0 unexpected=0
  for unit in "${_en[@]}"; do
    case "$unit" in *.service|*.timer) : ;; *) continue ;; esac
    total=$((total + 1))
    cause="$(organ_dark_cause "$unit" "${_plat[$unit]:-}" "${_req[$unit]:-}" "$current" "$REPO_ROOT" "$sysdir" "${_node[$unit]:-}" "$current_node")"
    case "$cause" in
      active) active=$((active + 1)) ;;
      scoped-off:*) scoped=$((scoped + 1)); log "scoped off this node: $unit ($cause)" ;;
      *) unexpected=$((unexpected + 1)); log "UNEXPECTED-DARK: $unit — $cause" ;;
    esac
  done
  log "post-deploy manifest audit: $active/$total enabled organs active, $scoped scoped off this node (platform=$current), $unexpected UNEXPECTED-DARK"
  [[ "$unexpected" -eq 0 ]]
}

if [[ "${1:-}" == "--audit-only" ]]; then
  organ_audit
  exit $?
fi

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

# Advisory post-deploy audit (log-only; no new ambient kinds) — see organ_audit above.
organ_audit || true

exit "$rc"
