#!/usr/bin/env bash
# test-chump-commit-auto-lease.sh — INFRA-085 unit tests.
#
# Verifies the auto-lease-from-commit-message block in
# scripts/coord/chump-commit.sh:
#
#   (1) -m "INFRA-100: ..." extracts INFRA-100 and calls gap-claim.sh
#   (2) -F <file> with "Closes INFRA-200" extracts and calls
#   (3) Multiple gap-IDs in message (subject + body) all get claimed
#   (4) No gap-IDs → no gap-claim.sh call (silent)
#   (5) CHUMP_AUTO_LEASE_FROM_MSG=0 disables (no call regardless of message)
#   (6) Editor-mode commit (no -m / -F) → silent skip (no spurious call)
#
# Strategy: stub gap-claim.sh as a logger, run chump-commit.sh in dry-run
# (just the message-parse block, not the actual commit), assert the log.
#
# Run from repo root: bash scripts/ci/test-chump-commit-auto-lease.sh

set -euo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-085 chump-commit.sh auto-lease-from-msg unit tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMIT_SH="$REPO_ROOT/scripts/coord/chump-commit.sh"

if [ ! -x "$COMMIT_SH" ]; then
    echo "FATAL: $COMMIT_SH not executable"
    exit 2
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Set up a fake repo root so REPO_ROOT inside chump-commit.sh resolves to
# our temp tree, and stub gap-claim.sh as a logger.
FAKE_REPO="$TMPDIR_BASE/repo"
mkdir -p "$FAKE_REPO/scripts/coord"
cp "$COMMIT_SH" "$FAKE_REPO/scripts/coord/chump-commit.sh"
chmod +x "$FAKE_REPO/scripts/coord/chump-commit.sh"
git -C "$FAKE_REPO" init -q -b main
git -C "$FAKE_REPO" config user.email t@t
git -C "$FAKE_REPO" config user.name T

LEASE_LOG="$TMPDIR_BASE/lease-calls.log"
cat > "$FAKE_REPO/scripts/coord/gap-claim.sh" <<LEASE_EOF
#!/usr/bin/env bash
# Stub: log invocations, never fail. Quoted heredoc would prevent
# \$LEASE_LOG expansion at write-time; we want it expanded so the stub
# knows which path to log to.
echo "claim:\$1" >> "$LEASE_LOG"
exit 0
LEASE_EOF
chmod +x "$FAKE_REPO/scripts/coord/gap-claim.sh"

# Extract just the auto-lease block from chump-commit.sh and run it
# in isolation against synthetic GIT_ARGS. Avoids exercising the full
# script (which would try to actually commit, run pre-commit hooks, etc).
extract_lease_block() {
    awk '/^# ── INFRA-085: auto-write lease/,/^# Commit with the passed-through git args/' \
        "$COMMIT_SH" | sed '$d'
}

run_lease_block() {
    local -a args=("$@")
    : > "$LEASE_LOG"
    (
        REPO_ROOT="$FAKE_REPO"
        GIT_ARGS=("${args[@]}")
        eval "$(extract_lease_block)"
    )
}

# ── Test 1: -m extracts gap-ID ────────────────────────────────────────────────
echo "--- Test 1: -m 'INFRA-100: foo' extracts INFRA-100 ---"
run_lease_block -m "INFRA-100: implement the foo widget"
if grep -q "claim:INFRA-100" "$LEASE_LOG"; then
    ok "Test 1: gap-claim.sh called with INFRA-100"
else
    fail "Test 1: expected claim:INFRA-100, got: $(cat "$LEASE_LOG")"
fi

# ── Test 2: -F path with body content ─────────────────────────────────────────
echo "--- Test 2: -F <file> with 'Closes INFRA-200' extracts INFRA-200 ---"
msg_file="$TMPDIR_BASE/msg-200"
printf 'feat: thing\n\nCloses INFRA-200 by adding handler\n' > "$msg_file"
run_lease_block -F "$msg_file"
if grep -q "claim:INFRA-200" "$LEASE_LOG"; then
    ok "Test 2: gap-claim.sh called with INFRA-200 from -F file"
else
    fail "Test 2: expected claim:INFRA-200, got: $(cat "$LEASE_LOG")"
fi

# ── Test 3: multiple gap-IDs (subject + body) ────────────────────────────────
echo "--- Test 3: subject INFRA-300 + body 'closes INFRA-301 + INFRA-302' all claim ---"
msg_file="$TMPDIR_BASE/msg-multi"
printf 'INFRA-300: ship feature\n\nAlso closes INFRA-301 + INFRA-302 along the way\n' > "$msg_file"
run_lease_block -F "$msg_file"
calls=$(sort -u "$LEASE_LOG" | tr '\n' ' ')
if echo "$calls" | grep -q "claim:INFRA-300" \
   && echo "$calls" | grep -q "claim:INFRA-301" \
   && echo "$calls" | grep -q "claim:INFRA-302"; then
    ok "Test 3: all three IDs claimed; got: $calls"
else
    fail "Test 3: missing IDs; got: $calls"
fi

# ── Test 4: no gap-IDs in message → no calls ─────────────────────────────────
echo "--- Test 4: -m 'fix: typo' (no gap-ID) → no claim calls ---"
run_lease_block -m "fix: typo in README"
if [ ! -s "$LEASE_LOG" ]; then
    ok "Test 4: no spurious claim calls when message has no gap-ID"
else
    fail "Test 4: unexpected calls: $(cat "$LEASE_LOG")"
fi

# ── Test 5: kill-switch env disables ─────────────────────────────────────────
echo "--- Test 5: CHUMP_AUTO_LEASE_FROM_MSG=0 disables, even with INFRA-500 in msg ---"
: > "$LEASE_LOG"
(
    REPO_ROOT="$FAKE_REPO"
    GIT_ARGS=(-m "INFRA-500: ship something")
    CHUMP_AUTO_LEASE_FROM_MSG=0
    eval "$(extract_lease_block)"
)
if [ ! -s "$LEASE_LOG" ]; then
    ok "Test 5: kill-switch env suppresses claim"
else
    fail "Test 5: kill-switch ignored — got: $(cat "$LEASE_LOG")"
fi

# ── Test 6: editor-mode commit (no -m / -F) → no spurious calls ──────────────
echo "--- Test 6: editor-mode commit (no -m / -F flags) → silent ---"
run_lease_block --amend --no-edit
if [ ! -s "$LEASE_LOG" ]; then
    ok "Test 6: editor-mode commit produced no spurious claim calls"
else
    fail "Test 6: editor-mode produced calls: $(cat "$LEASE_LOG")"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
