#!/usr/bin/env bash
# INFRA-168: gap reserved in SQLite but not yet in origin/main YAML must pass
# gap-preflight.sh without CHUMP_ALLOW_UNREGISTERED_GAP=1.
#
# Regression for the PRODUCT-022 failure class: `chump gap reserve` writes to
# state.db with status=open, but the per-file YAML isn't pushed to origin/main
# yet. The old YAML-only check rejected such gaps unless the session lease had
# a matching pending_new_gap or CHUMP_ALLOW_UNREGISTERED_GAP=1 was set.
#
# After INFRA-168, gap-preflight.sh calls `chump gap preflight <ID>` which
# reads state.db directly — no escape hatch needed.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Require chump binary — this test is meaningless without it.
if ! command -v chump >/dev/null 2>&1; then
    echo "skip: chump binary not in PATH — cannot run INFRA-168 SQLite preflight test"
    exit 0
fi

export CHUMP_ALLOW_MAIN_WORKTREE=1
export CHUMP_GAP_RESERVE_SKIP_PR=1
export CHUMP_PREFLIGHT_PR_CHECK=0
export CHUMP_PREFLIGHT_NATS_CHECK=0
export CHUMP_AMBIENT_GLANCE=0

# ── Reserve a gap directly via chump binary (bypasses flock / gap-reserve.sh) ─
# We call `chump gap reserve` directly so this test works on macOS where
# `flock` may not be installed. We don't need the lease's pending_new_gap —
# the whole point of this test is that state.db alone is sufficient.
RID="$(chump gap reserve --domain TEST168 --title "INFRA-168 sqlite preflight regression" 2>/dev/null)" || {
    echo "skip: chump gap reserve failed (binary may be wedged — run scripts/dev/chump-binary-unwedge.sh)"
    exit 0
}
RID="$(echo "$RID" | tr -d '\r\n')"
if ! [[ "$RID" =~ ^TEST168-[0-9]+$ ]]; then
    echo "FAIL: unexpected reserved id: '$RID'" >&2
    exit 1
fi

cleanup() {
    rm -f "$ROOT/.chump-locks/infra168-reader-${$}"*.json 2>/dev/null || true
}
trap cleanup EXIT

# ── Run preflight as a session with NO matching lease / pending_new_gap ────────
# This simulates the PRODUCT-022 failure: session changed between reserve and
# preflight (e.g. new session, same machine). Without INFRA-168, this would
# fail with "not found in gap registry". With INFRA-168, `chump gap preflight`
# finds the gap as Available in state.db and preflight succeeds.
READER_SESSION="infra168-reader-$$"
export CHUMP_SESSION_ID="$READER_SESSION"

OUT="$(mktemp)"
ERR="$(mktemp)"
trap "cleanup; rm -f '$OUT' '$ERR'" EXIT

set +e
scripts/coord/gap-preflight.sh "$RID" >"$OUT" 2>"$ERR"
RC=$?
set -e

if [[ "$RC" -ne 0 ]]; then
    echo "FAIL: gap-preflight.sh should pass for SQLite-reserved gap '$RID' (no escape hatch), got exit $RC" >&2
    echo "stdout:" >&2; cat "$OUT" >&2 || true
    echo "stderr:" >&2; cat "$ERR" >&2 || true
    exit 1
fi

COMBINED="$(cat "$OUT" "$ERR" 2>/dev/null || true)"
if ! echo "$COMBINED" | grep -qE "INFRA-168|local state\.db"; then
    echo "FAIL: expected INFRA-168 SQLite path message in output, got:" >&2
    echo "$COMBINED" >&2
    exit 1
fi

echo "ok: INFRA-168 — SQLite-reserved gap passes gap-preflight.sh without escape hatch (gap: $RID)"
