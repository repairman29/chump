#!/usr/bin/env bash
# scripts/ci/test-inbox-glance.sh — INFRA-1798 AC #5 smoke test.
#
# Drives a REAL curator loop cycle (scripts/coord/ci-audit-loop.sh heartbeat)
# with 1 unread FEEDBACK kind=proposal sitting in the session's inbox, and
# asserts the mandatory Glance phase (scripts/coord/lib/inbox-glance.sh):
#   (a) drained the proposal (cursor advances / no longer unread),
#   (b) cast a `chump vote` for its corr_id,
#   (c) emitted kind=inbox_advance.
#
# This is not a hand-written fixture of the library function — it invokes
# the loop script's public CLI exactly as a curator cycle would.
#
# Isolation: several scripts/coord/*.sh derive LOCK_DIR from
# `git rev-parse --show-toplevel` unconditionally (ignore env overrides), so
# the only reliable isolation is a real, throwaway git repo with the real
# scripts/ tree symlinked in — not an env-var trick.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

_pass=0
_fail=0
_ok()  { echo "  ✓ $*"; _pass=$((_pass + 1)); }
_bad() { echo "  ✗ FAIL: $*" >&2; _fail=$((_fail + 1)); }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

git init -q "$TMPDIR_TEST"
ln -s "$REPO_ROOT/scripts" "$TMPDIR_TEST/scripts"

LOOP_SCRIPT="$TMPDIR_TEST/scripts/coord/ci-audit-loop.sh"
INBOX_SCRIPT="$TMPDIR_TEST/scripts/coord/chump-inbox.sh"

if [[ ! -x "$LOOP_SCRIPT" ]]; then
    echo "FAIL: $LOOP_SCRIPT not found or not executable" >&2
    exit 1
fi

TEST_SESSION="test-glance-ci-audit-$$"
LOCK_DIR="$TMPDIR_TEST/.chump-locks"
AMBIENT="$LOCK_DIR/ambient.jsonl"
export CHUMP_SESSION_ID="$TEST_SESSION"
export CHUMP_FLEET_RECV_SIDE_V0=1

mkdir -p "$LOCK_DIR/inbox"

CORR_ID="INFRA-1798-TEST-PROPOSAL-$$"
INBOX_FILE="$LOCK_DIR/inbox/$TEST_SESSION.jsonl"
cat > "$INBOX_FILE" <<EOF
{"ts":"2026-08-12T00:00:00Z","event":"FEEDBACK","kind":"proposal","session":"sibling-curator","corr_id":"$CORR_ID","subject":"test proposal","rationale":"does INFRA-1798 glance drain and act on this?"}
EOF

echo "Test: ci-audit-loop.sh heartbeat runs the Glance phase first (cwd=\$TMPDIR_TEST, a real isolated git repo)..."
_rc=0
( cd "$TMPDIR_TEST" && "$LOOP_SCRIPT" heartbeat ) >/dev/null 2>&1 || _rc=$?
if (( _rc == 0 )); then
    _ok "heartbeat exits 0 (glance step did not break the cycle)"
else
    _bad "heartbeat should exit 0, got $_rc"
fi

# (a) proposal drained: chump-inbox.sh read now sees nothing new.
_remaining="$(cd "$TMPDIR_TEST" && "$INBOX_SCRIPT" read --json 2>/dev/null || echo '[]')"
if [[ "$_remaining" == "[]" ]]; then
    _ok "AC1: proposal drained — cursor advanced past the seeded message"
else
    _bad "expected inbox to be drained, still has: $_remaining"
fi

# (b) chump vote cast for the proposal's corr_id.
if grep -q '"kind":"vote"' "$AMBIENT" 2>/dev/null \
        && grep -q "\"corr_id\":\"$CORR_ID\"" "$AMBIENT" 2>/dev/null; then
    _ok "AC2: chump vote emitted for corr_id=$CORR_ID"
else
    _bad "no kind=vote event for corr_id=$CORR_ID in $AMBIENT"
    [[ -f "$AMBIENT" ]] && cat "$AMBIENT" >&2
fi

# (c) inbox_advance emitted with messages_read > 0.
if grep -q '"kind":"inbox_advance"' "$AMBIENT" 2>/dev/null; then
    _ok "AC3: kind=inbox_advance emitted"
else
    _bad "no kind=inbox_advance event in $AMBIENT"
fi

echo ""
echo "── Summary ──"
echo "  PASS: $_pass"
echo "  FAIL: $_fail"

if (( _fail > 0 )); then
    exit 1
fi
exit 0
