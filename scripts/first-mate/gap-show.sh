#!/usr/bin/env bash
# gap-show.sh — INFRA-8056: look up a gap on the CANONICAL gap-store node.
# Usage: gap-show.sh <GAP-ID> | --title <substring>
# Host resolution: $CHUMP_CANONICAL_GAP_HOST > ~/.chump/canonical-gap-host > cuphead.
# Never hardcode a node here: the canonical store moved CJ -> cuphead (2026-09-29).
set -euo pipefail

HOST="${CHUMP_CANONICAL_GAP_HOST:-}"
if [ -z "$HOST" ] && [ -f "$HOME/.chump/canonical-gap-host" ]; then
  HOST="$(head -1 "$HOME/.chump/canonical-gap-host" | tr -d '[:space:]')"
fi
HOST="${HOST:-cuphead}"
REPO="${CHUMP_CANONICAL_GAP_REPO:-\$HOME/chump}"

[ $# -ge 1 ] || { echo "usage: $0 <GAP-ID> | --title <substring>" >&2; exit 2; }

if [ "$1" = "--title" ]; then
  [ $# -ge 2 ] || { echo "usage: $0 --title <substring>" >&2; exit 2; }
  needle="$2"
  ssh -o BatchMode=yes "$HOST" "cd $REPO && chump gap list --status open" | grep -iF -- "$needle" || { echo "no open gap matching: $needle (host=$HOST)" >&2; exit 1; }
else
  id="$1"
  case "$id" in *[!A-Za-z0-9-]*) echo "bad gap id: $id" >&2; exit 2;; esac
  ssh -o BatchMode=yes "$HOST" "cd $REPO && chump gap show $id"
fi
