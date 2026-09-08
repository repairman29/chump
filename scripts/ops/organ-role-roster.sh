#!/usr/bin/env bash
# scripts/ops/organ-role-roster.sh — RESILIENT-1055
#
# Print this node's role roster with each organ's live systemd state — the
# is-active RECEIPT for a `--role` node. For every `enabled` manifest organ
# whose role= matches the role filter, emit one tab-separated row:
#
#   <state>\t<unit>\t<kind>\t<reason>
#
#   state : `systemctl is-active` (active/activating/inactive/failed), or SKIP
#           when the organ is not applicable to this node (unmet requires=), or
#           NOFILE when it is in-role but has no unit file installed here.
#   kind  : timer | service  (a .timer arms on enable regardless of whether the
#           oneshot it fires succeeds; a long-running .service needs its
#           binary/secret to actually stay active — the caller weighs them
#           differently).
#   reason: the applicability reason for SKIP rows, else "-".
#
# Reuses the SAME organ-manifest-lib.sh parser + organ_is_applicable the
# reconcile uses, so "in-role" and "applicable" mean exactly what the reconcile
# means. Role filter comes from $CHUMP_ORGAN_RECONCILE_ROLE (comma-separated
# role= values; empty = all roles), mirroring organ-reconcile.sh.
#
# Read-only: it never enables, disables, or places anything. Safe to run any
# time, on any node or in the FTUE container, to snapshot "what is this role's
# roster actually doing".
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="${CHUMP_ORGAN_MANIFEST:-$REPO_ROOT/scripts/ops/organ-manifest.txt}"
SYSTEMCTL_BIN="${CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN:-systemctl}"
ROLE_FILTER="${CHUMP_ORGAN_RECONCILE_ROLE:-}"

source "$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"

PAGING_OFF=(); ENABLED=(); declare -A ORGAN_ROLE ORGAN_REQUIRES
organ_manifest_parse "$MANIFEST" PAGING_OFF ENABLED ORGAN_ROLE ORGAN_REQUIRES || exit 1

in_role() {
  local role="$1" tok
  [[ -z "$ROLE_FILTER" ]] && return 0
  IFS=',' read -ra toks <<< "$ROLE_FILTER"
  for tok in "${toks[@]}"; do [[ "$tok" == "$role" ]] && return 0; done
  return 1
}

kind_of() { case "$1" in *.timer) echo timer;; *) echo service;; esac; }

for unit in "${ENABLED[@]}"; do
  role="${ORGAN_ROLE[$unit]:-brain}"
  in_role "$role" || continue
  kind="$(kind_of "$unit")"
  reason=""
  if ! organ_is_applicable "$unit" "${ORGAN_REQUIRES[$unit]:-}" reason; then
    printf '%s\t%s\t%s\t%s\n' "SKIP" "$unit" "$kind" "$reason"
    continue
  fi
  if ! "$SYSTEMCTL_BIN" cat "$unit" >/dev/null 2>&1; then
    printf '%s\t%s\t%s\t%s\n' "NOFILE" "$unit" "$kind" "no-unit-file-on-this-node"
    continue
  fi
  st="$("$SYSTEMCTL_BIN" is-active "$unit" 2>/dev/null || true)"
  printf '%s\t%s\t%s\t%s\n' "${st:-inactive}" "$unit" "$kind" "-"
done
