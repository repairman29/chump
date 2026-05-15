#!/usr/bin/env bash
# INFRA-021: pending_new_gap in this session's lease satisfies gap-preflight for an ID not yet on main.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
export CHUMP_ALLOW_MAIN_WORKTREE=1 CHUMP_GAP_RESERVE_SKIP_PR=1

ERR1="$(mktemp)"
OUT1="$(mktemp)"
ERR2="$(mktemp)"
OUT2="$(mktemp)"
cleanup_pf() {
    rm -f "$ROOT/.chump-locks/grpftest"*.json 2>/dev/null || true
    rm -f "$ERR1" "$OUT1" "$ERR2" "$OUT2" 2>/dev/null || true
}
trap cleanup_pf EXIT

export CHUMP_SESSION_ID="grpftest$$"

RID="$(scripts/coord/gap-reserve.sh TEST "preflight scaffold")"
RID="$(echo "$RID" | tr -d '\r\n')"
[[ "$RID" =~ ^TEST-[0-9]+$ ]] || {
    echo "unexpected reserved id: $RID" >&2
    exit 1
}

set +e
scripts/coord/gap-preflight.sh "$RID" >"$OUT1" 2>"$ERR1"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
    echo "preflight for reserved id should pass for same session" >&2
    cat "$ERR1" >&2 || true
    exit 1
fi

export CHUMP_SESSION_ID="grpftestother$$"
set +e
scripts/coord/gap-preflight.sh "$RID" >"$OUT2" 2>"$ERR2"
rc2=$?
set -e
if [[ "$rc2" -eq 0 ]]; then
    echo "expected other session preflight to fail on reserved id" >&2
    cat "$ERR2" >&2 || true
    exit 1
fi

echo "ok: preflight accepts own pending_new_gap; blocks other sessions"
