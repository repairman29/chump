#!/usr/bin/env bash
# INFRA-021: two concurrent gap-reserve calls must not return the same ID.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
export CHUMP_ALLOW_MAIN_WORKTREE=1 CHUMP_GAP_RESERVE_SKIP_PR=1

OUT1="$(mktemp)"
OUT2="$(mktemp)"
LOCK="$ROOT/.chump-locks"
trap 'rm -f "$OUT1" "$OUT2" "$LOCK"/grconcatesta*.json "$LOCK"/grconcatestb*.json 2>/dev/null || true' EXIT

(
    export CHUMP_SESSION_ID="grconcatesta$$"
    scripts/gap-reserve.sh TEST "parallel a" >"$OUT1"
) &
(
    export CHUMP_SESSION_ID="grconcatestb$$"
    scripts/gap-reserve.sh TEST "parallel b" >"$OUT2"
) &
wait

A="$(tr -d '\r\n' <"$OUT1")"
B="$(tr -d '\r\n' <"$OUT2")"
if [[ -z "$A" || -z "$B" ]]; then
    echo "expected two non-empty reserved ids" >&2
    exit 1
fi
if [[ "$A" == "$B" ]]; then
    echo "collision: both sessions got $A" >&2
    exit 1
fi
echo "ok: concurrent gap-reserve returned distinct ids ($A vs $B)"
