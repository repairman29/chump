#!/usr/bin/env bash
# scripts/ci/test-inbox-glance-act.sh — INFRA-1798
#
# Smoke test for the "Glance" phase addendum: a curator/worker/autopilot
# tick must (a) read its own DM inbox as the FIRST step (chump-inbox.sh
# read), (b) ACT on what it finds — ack HANDOFF/STUCK, vote on unvoted-by-me
# open FEEDBACK kind=proposal — not just skim it, and (c) emit
# kind=inbox_advance so the outcome is measurable.
#
# This drives the REAL loop (ambient-context-inject.sh --tick-preamble via
# deliberator-loop.sh tick), not a hand-written fixture asserting internal
# shape — the same class of mistake CREDIBLE-122 refused to repeat.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
ok()  { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1798: inbox glance-and-act smoke test ==="

if ! command -v chump >/dev/null 2>&1; then
    echo "  SKIP: chump binary not on PATH"
    exit 0
fi

TMP="$(mktemp -d -t inbox-glance-act.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

unset CHUMP_REPO CHUMP_LOCK_DIR

cd "$TMP"
git init --quiet
git config user.email test@example.com
git config user.name Test

mkdir -p scripts/coord scripts/lib .chump-locks
cp "$REPO_ROOT/scripts/coord/broadcast.sh" scripts/coord/broadcast.sh
cp "$REPO_ROOT/scripts/coord/chump-inbox.sh" scripts/coord/chump-inbox.sh
cp "$REPO_ROOT/scripts/coord/ambient-context-inject.sh" scripts/coord/ambient-context-inject.sh
cp "$REPO_ROOT/scripts/lib/discover-flock.sh" scripts/lib/discover-flock.sh
[[ -f "$REPO_ROOT/scripts/coord/lib/inbox-routing.sh" ]] && {
    mkdir -p scripts/coord/lib
    cp "$REPO_ROOT/scripts/coord/lib/inbox-routing.sh" scripts/coord/lib/inbox-routing.sh
}
chmod +x scripts/coord/*.sh

SESSION="smoke-glance-$$"
CORR="smoke-glance-corr-$$"
LOCK="$TMP/.chump-locks"
AMBIENT="$LOCK/ambient.jsonl"
FEEDBACK="$LOCK/feedback.jsonl"
: > "$AMBIENT"
: > "$FEEDBACK"

export CHUMP_SESSION_ID="$SESSION"
export CHUMP_AMBIENT_LOG="$AMBIENT"
export CHUMP_FEEDBACK_LOG="$FEEDBACK"
export CHUMP_FLEET_RECV_SIDE_V0=1

# ── Seed: 1 unread proposal addressed to this session's inbox ───────────────
CHUMP_SESSION_ID=proposer-A scripts/coord/broadcast.sh --to "$SESSION" --corr "$CORR" \
    FEEDBACK proposal "smoke-test-subject" "should we do the thing" >/dev/null 2>&1

INBOX_FILE="$LOCK/inbox/${SESSION}.jsonl"
if [[ -s "$INBOX_FILE" ]]; then
    ok "seed: proposal landed in $SESSION's inbox"
else
    bad "seed: proposal did NOT land in $SESSION's inbox — cannot proceed"
fi

pre_advance_count="$(grep -c '"kind":"inbox_advance"' "$AMBIENT" 2>/dev/null)"

# ── Drive the real tick-preamble (the "Glance" phase) ────────────────────────
bash scripts/coord/ambient-context-inject.sh --tick-preamble smoke >/dev/null 2>&1

# (a) proposal read: cursor advanced, inbox drained
post_read="$(bash scripts/coord/chump-inbox.sh read 2>/dev/null || true)"
if [[ -z "$post_read" ]]; then
    ok "(a) proposal was read — re-reading the inbox now returns nothing new"
else
    bad "(a) inbox still has unread content after tick-preamble: $post_read"
fi

# (b) a chump vote was emitted for it
if grep -q "\"corr_id\":\"${CORR}\"" "$AMBIENT" 2>/dev/null && \
   grep "\"corr_id\":\"${CORR}\"" "$AMBIENT" | grep -q '"kind":"vote"'; then
    ok "(b) chump vote emitted for corr_id=$CORR"
else
    bad "(b) no kind=vote event found for corr_id=$CORR in ambient"
fi

# (c) an inbox_advance event was emitted
post_advance_count="$(grep -c '"kind":"inbox_advance"' "$AMBIENT" 2>/dev/null)"
if [[ "$post_advance_count" -gt "$pre_advance_count" ]]; then
    ok "(c) inbox_advance event count increased ($pre_advance_count -> $post_advance_count)"
else
    bad "(c) inbox_advance event was not emitted (count stayed at $pre_advance_count)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
