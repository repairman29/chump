#!/usr/bin/env bash
# scripts/ops/node-organ-check.sh — PEER-HEAL-01 / INFRA-3648
#
# WHY THIS EXISTS. organ-manifest.txt + organ-reconcile.sh heal systemd-unit
# organs only (`systemctl is-active`). Nodes bootstrapped via
# install-node-housekeeping.sh's SUP=nohup fallback (no systemd at all —
# closetjunky's original shape) have process organs that systemd can never
# see, so they were structurally invisible to any heal-detection loop. This
# script reads node-organ-manifest.txt (the sibling registry for THAT organ
# class) and reports per-organ liveness via `pgrep -f`, with zero systemctl
# dependency.
#
# Usage:
#   scripts/ops/node-organ-check.sh --check [--manifest PATH]
#     Prints "<name>  <STATE>" per enabled organ (DETECTED-ALIVE / DEAD /
#     UNKNOWN) and exits non-zero if any required organ is DEAD.
#
# Env overrides (test hooks):
#   CHUMP_NODE_ORGAN_MANIFEST   — manifest path (default scripts/ops/node-organ-manifest.txt)
#   CHUMP_NODE_ORGAN_PGREP_BIN  — pgrep binary override (default `pgrep`)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
MANIFEST="${CHUMP_NODE_ORGAN_MANIFEST:-$REPO_ROOT/scripts/ops/node-organ-manifest.txt}"
PGREP_BIN="${CHUMP_NODE_ORGAN_PGREP_BIN:-pgrep}"

MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --manifest) shift; MANIFEST="$1" ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$MODE" = "check" ] || { echo "usage: $0 --check [--manifest PATH]" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "no manifest at $MANIFEST" >&2; exit 2; }

# parse_field NAME LINE — extract key=value token (may contain no spaces; the
# detector field's regex is expected to be a single pgrep -f token).
parse_field() {
  local key="$1" line="$2"
  printf '%s\n' "$line" | grep -oE "${key}=[^ ]+" | head -1 | cut -d= -f2-
}

any_dead=0
while IFS= read -r line; do
  # strip comments/blank lines
  case "$line" in
    ''|'#'*) continue ;;
  esac
  local_state="$(printf '%s\n' "$line" | awk '{print $1}')"
  [ "$local_state" = "enabled" ] || continue
  name="$(printf '%s\n' "$line" | awk '{print $2}')"
  [ -n "$name" ] || continue
  detector="$(parse_field detector "$line")"
  heartbeat="$(parse_field heartbeat "$line")"
  max_age="$(parse_field max_age "$line")"

  status="UNKNOWN"
  if [ -n "$detector" ] && command -v "$PGREP_BIN" >/dev/null 2>&1; then
    if "$PGREP_BIN" -f "$detector" >/dev/null 2>&1; then
      status="DETECTED-ALIVE"
    elif [ -n "$heartbeat" ] && [ -f "$heartbeat" ]; then
      now=$(date +%s)
      mtime=$(stat -c %Y "$heartbeat" 2>/dev/null || stat -f %m "$heartbeat" 2>/dev/null || echo 0)
      age=$((now - mtime))
      if [ -n "$max_age" ] && [ "$age" -lt "$max_age" ]; then
        status="DETECTED-ALIVE"
      else
        status="DEAD"
      fi
    else
      status="DEAD"
    fi
  fi

  printf '%s  %s\n' "$name" "$status"
  [ "$status" = "DEAD" ] && any_dead=1
done < "$MANIFEST"

exit "$any_dead"
