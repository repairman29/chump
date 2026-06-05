#!/usr/bin/env bash
# scripts/ci/test-broadcast-reply-to.sh — EFFECTIVE-028
#
# Smoke test: verify broadcast.sh --reply-to <parent-corr-id> threading.
#
# Tests:
#   (a) --reply-to sets corr_id=<parent-corr-id> AND parent_corr_id=<parent-corr-id>
#       in the emitted ambient.jsonl payload.
#   (b) Default path (no --reply-to) is unchanged: no parent_corr_id field,
#       corr_id auto-derived from branch/gap/ts as before.
#   (c) FEEDBACK kind=preference with --reply-to lands under the correct
#       corr_id so the deliberator tally bucket matches the parent proposal.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BROADCAST="$REPO_ROOT/scripts/coord/broadcast.sh"
[[ -x "$BROADCAST" ]] || { echo "[FAIL] broadcast.sh not executable at $BROADCAST" >&2; exit 1; }

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stand up a minimal git sandbox so broadcast.sh's git calls succeed.
SANDBOX="$TMP/repo"
mkdir -p "$SANDBOX/.chump-locks/inbox"
git -C "$TMP" init -q "$SANDBOX"
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

AMBIENT="$SANDBOX/.chump-locks/ambient.jsonl"
PARENT_CORR="proposal-abc-123"

run_broadcast() {
    (
        cd "$SANDBOX"
        CHUMP_SESSION_ID="ci-test-$$" \
            "$BROADCAST" "$@"
    ) 2>/dev/null
}

# ── (a) --reply-to sets corr_id and parent_corr_id ───────────────────────────
run_broadcast --reply-to "$PARENT_CORR" WARN "threading smoke test"
[[ -f "$AMBIENT" ]] || fail "(a) ambient.jsonl not created"

LAST_LINE="$(tail -1 "$AMBIENT")"

# corr_id must equal the parent corr id
echo "$LAST_LINE" | grep -q "\"corr_id\".*\"${PARENT_CORR}\"" \
    || fail "(a) corr_id should be ${PARENT_CORR} but got: $LAST_LINE"
ok "(a) corr_id=${PARENT_CORR} present in payload"

# parent_corr_id must also be set
echo "$LAST_LINE" | grep -q "\"parent_corr_id\".*\"${PARENT_CORR}\"" \
    || fail "(a) parent_corr_id should be ${PARENT_CORR} but got: $LAST_LINE"
ok "(a) parent_corr_id=${PARENT_CORR} present in payload"

# ── (b) Default path unchanged — no parent_corr_id, corr_id auto-derived ─────
# Clear ambient so we only inspect the new line.
rm -f "$AMBIENT"
run_broadcast WARN "default path no threading"
[[ -f "$AMBIENT" ]] || fail "(b) ambient.jsonl not created on default path"

DEFAULT_LINE="$(tail -1 "$AMBIENT")"

# parent_corr_id must NOT appear
if echo "$DEFAULT_LINE" | grep -q '"parent_corr_id"'; then
    fail "(b) default path must not emit parent_corr_id but got: $DEFAULT_LINE"
fi
ok "(b) default path has no parent_corr_id"

# corr_id must still be present (auto-derived)
echo "$DEFAULT_LINE" | grep -q '"corr_id"' \
    || fail "(b) default path must still have corr_id but got: $DEFAULT_LINE"
ok "(b) default path has auto-derived corr_id"

# corr_id must NOT equal PARENT_CORR (it was auto-derived, not forced)
if echo "$DEFAULT_LINE" | grep -q "\"corr_id\".*\"${PARENT_CORR}\""; then
    fail "(b) default corr_id should NOT be ${PARENT_CORR} but got: $DEFAULT_LINE"
fi
ok "(b) default corr_id differs from parent corr id"

# ── (c) FEEDBACK preference with --reply-to lands on parent corr_id ──────────
# Simulate: agent emits a proposal, peer votes on it via --reply-to.
PROPOSAL_CORR="meta-proposal-xyz-456"
rm -f "$AMBIENT"

# Proposal broadcast (sets corr_id=PROPOSAL_CORR via --corr)
run_broadcast --corr "$PROPOSAL_CORR" FEEDBACK proposal "adopt-new-policy" "proposing X"

# Vote on it by threading with --reply-to
run_broadcast --reply-to "$PROPOSAL_CORR" FEEDBACK preference "adopt-new-policy" "vote for X" +1

# Both lines should be in ambient now.
VOTE_LINE="$(grep '"event".*"FEEDBACK"' "$AMBIENT" | grep '"kind".*"preference"' | tail -1)"
[[ -n "$VOTE_LINE" ]] || fail "(c) no FEEDBACK preference line in ambient: $(cat "$AMBIENT")"

# The vote's corr_id must equal the proposal's corr_id so the deliberator tallies correctly.
echo "$VOTE_LINE" | grep -q "\"corr_id\".*\"${PROPOSAL_CORR}\"" \
    || fail "(c) vote corr_id should be ${PROPOSAL_CORR} (deliberator tally bucket) but got: $VOTE_LINE"
ok "(c) FEEDBACK preference corr_id=${PROPOSAL_CORR} matches parent proposal"

echo ""
echo "All tests passed."
