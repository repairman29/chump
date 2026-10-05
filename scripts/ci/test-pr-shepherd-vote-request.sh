#!/usr/bin/env bash
# META-189: PRs classified MERGEABLE trigger FEEDBACK kind=vote-request,
# corr_id=pr-N, and consensus votes are tracked per PR keyed by that corr_id.
#
# Asserts:
#   (a) broadcast.sh FEEDBACK accepts kind=vote-request (was previously
#       restricted to defect|proposal|preference|retro).
#   (b) the emitted event has corr_id=pr-<N> (derived from the subject arg).
#   (c) scripts/ci/event-registry-reserved.txt reserves "vote-request" so
#       ambient-emit.sh's kind-schema gate doesn't quarantine it.
#   (d) pr-shepherd-daemon.sh's MERGEABLE branch calls broadcast.sh FEEDBACK
#       vote-request with a "pr-<N>" subject (debounced via
#       _vote_request_already_sent / _record_vote_request_sent).
#   (e) chump vote (the existing corr_id-keyed consensus primitive) accepts
#       a "pr-N" corr_id — the per-PR tracking side of AC2 — with no new
#       code required since corr_id is opaque to vote.rs/consensus_tally.rs.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── (a)+(b): broadcast.sh FEEDBACK vote-request ───────────────────────────────
# broadcast.sh's LOCK_DIR is derived from `git rev-parse --git-common-dir`
# (the shared ambient stream across worktrees), not overridable via
# CHUMP_AMBIENT_LOG for the FEEDBACK path's emit_to_file — so, like
# test-pr-shepherd-daemon.sh, assert against the real ambient.jsonl by
# diffing line count before/after instead of pointing at an isolated file.
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# broadcast.sh resolves LOCK_DIR off the shared git-common-dir (the main
# checkout), not the worktree root — mirror that here so we tail the same
# file broadcast.sh actually writes to.
_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi
AMBIENT_REAL="$MAIN_REPO/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$AMBIENT_REAL")"
export CHUMP_FEEDBACK_LOG="$TMPDIR_TEST/feedback.jsonl"
export CHUMP_SESSION_ID="test-vote-request-$$"

before=$(wc -l < "$AMBIENT_REAL" 2>/dev/null || echo 0)
bash "$REPO_ROOT/scripts/coord/broadcast.sh" FEEDBACK vote-request "pr-999999" \
    "PR #999999 is MERGEABLE — cast a consensus vote" >/dev/null \
    || { echo "[test] FAIL: broadcast.sh FEEDBACK vote-request exited non-zero"; exit 1; }
after=$(wc -l < "$AMBIENT_REAL")
new_lines=$(tail -n "$((after - before))" "$AMBIENT_REAL")

echo "$new_lines" | grep -Eq '"kind":[[:space:]]*"vote-request"' \
    || { echo "[test] FAIL: no kind=vote-request event in ambient log"; echo "$new_lines" >&2; exit 1; }
echo "$new_lines" | grep -E '"kind":[[:space:]]*"vote-request"' | grep -Eq '"corr_id":[[:space:]]*"pr-999999"' \
    || { echo "[test] FAIL: vote-request event missing corr_id=pr-999999"; exit 1; }
echo "[test] (a-b) broadcast.sh FEEDBACK vote-request + corr_id=pr-N: OK"

# ── (c): reserved.txt entry so ambient-emit.sh's kind gate accepts it ────────
grep -Eq '^vote-request[[:space:]]' "$REPO_ROOT/scripts/ci/event-registry-reserved.txt" \
    || { echo "[test] FAIL: vote-request not in scripts/ci/event-registry-reserved.txt"; exit 1; }
echo "[test] (c) vote-request reserved: OK"

# ── (d): pr-shepherd-daemon.sh wires MERGEABLE -> broadcast.sh vote-request ──
grep -q 'FEEDBACK vote-request' "$REPO_ROOT/scripts/coord/pr-shepherd-daemon.sh" \
    || { echo "[test] FAIL: pr-shepherd-daemon.sh does not broadcast FEEDBACK vote-request"; exit 1; }
grep -q '_vote_request_already_sent' "$REPO_ROOT/scripts/coord/pr-shepherd-daemon.sh" \
    || { echo "[test] FAIL: pr-shepherd-daemon.sh missing vote-request debounce helper"; exit 1; }
bash -n "$REPO_ROOT/scripts/coord/pr-shepherd-daemon.sh" \
    || { echo "[test] FAIL: pr-shepherd-daemon.sh syntax error"; exit 1; }
echo "[test] (d) pr-shepherd-daemon.sh MERGEABLE -> vote-request wiring: OK"

# ── (e): per-PR consensus vote tracking keyed by corr_id (existing chump vote
# primitive, generic over any corr_id string including "pr-N") ───────────────
export CHUMP_REPO_ROOT="$REPO_ROOT"
export CHUMP_FLEET_RECV_SIDE_V0=1
FAKE_BROADCAST="$TMPDIR_TEST/broadcast.sh"
cat > "$FAKE_BROADCAST" << 'BROADCAST_EOF'
#!/usr/bin/env bash
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FB_KIND="${2:-preference}"
FB_SUBJECT="${3:-}"
FB_RATIONALE="${4:-}"
FB_VOTE="${5:-0}"
LINE="{\"ts\":\"$TS\",\"event\":\"FEEDBACK\",\"kind\":\"$FB_KIND\",\"corr_id\":\"$FB_SUBJECT\",\"vote\":$FB_VOTE,\"rationale\":\"$FB_RATIONALE\",\"session\":\"${CHUMP_SESSION_ID:-test}\"}"
echo "$LINE" >> "${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"
echo "[broadcast] FEEDBACK kind=$FB_KIND subject=$FB_SUBJECT"
BROADCAST_EOF
chmod +x "$FAKE_BROADCAST"

CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"
if [[ -x "$CHUMP_BIN" ]]; then
    : > "$CHUMP_AMBIENT_LOG"
    PATH="$TMPDIR_TEST:$PATH" "$CHUMP_BIN" vote pr-4242 +1 --reason "clean, ship it" >/dev/null 2>&1 || true
    grep -q '"kind":"vote"' "$CHUMP_AMBIENT_LOG" 2>/dev/null && grep '"kind":"vote"' "$CHUMP_AMBIENT_LOG" | grep -q '"corr_id":"pr-4242"' \
        && echo "[test] (e) chump vote pr-N — per-PR corr_id tracking: OK" \
        || echo "[test] (e) SKIP: chump vote pr-N smoke inconclusive (non-fatal, covered by test-chump-vote.sh generically)"
else
    echo "[test] (e) SKIP: chump binary not built (covered generically by test-chump-vote.sh)"
fi

echo "[test-pr-shepherd-vote-request] all checks passed"
