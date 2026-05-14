#!/usr/bin/env bash
# test-gap-claim-race.sh — INFRA-403: claim-time exclusivity check in gap-claim.sh
#
# Verifies that gap-claim.sh aborts when:
#   (1) A sibling session already wrote a live lease for the same gap-ID
#   (2) An open PR already implements the gap (Check 1.5 mirror at claim time)
# And that:
#   (3) CHUMP_SPECULATIVE=1 bypasses both checks (intentional race, INFRA-193)
#   (4) Own session's existing lease does NOT block re-entrant claim
#   (5) Expired sibling lease does NOT block (stale = free)
#
# Run:
#   bash scripts/ci/test-gap-claim-race.sh
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed

set -euo pipefail

# INFRA-1025: gap-claim.sh is now a thin wrapper around `chump claim`. The
# INFRA-403 exclusivity logic lives in Rust (src/atomic_claim.rs) and is
# tested there. This shell test requires the chump binary to be built; skip
# gracefully when it is not available (e.g., the fast-checks job pre-build).
ROOT_TMP="$(cd "$(dirname "$0")/../.." && pwd)"
CHUMP_BIN=""
if [[ -x "$ROOT_TMP/target/release/chump" ]]; then
    CHUMP_BIN="$ROOT_TMP/target/release/chump"
elif command -v chump &>/dev/null; then
    CHUMP_BIN="$(command -v chump)"
fi
if [[ -z "$CHUMP_BIN" ]]; then
    echo "=== INFRA-403 gap-claim claim-time exclusivity tests ==="
    echo "  SKIP: chump binary not found; INFRA-403 logic is tested via Rust unit"
    echo "        tests in src/atomic_claim.rs (cargo test). Build first to run here."
    exit 0
fi

PASS=0
FAIL=0
FAILS=()

ok()   { printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); FAILS+=("$*"); }

echo "=== INFRA-403 gap-claim claim-time exclusivity tests ==="
echo

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLAIM_SH="$ROOT/scripts/coord/gap-claim.sh"

if [[ ! -x "$CLAIM_SH" ]]; then
    echo "FATAL: gap-claim.sh not executable: $CLAIM_SH"
    exit 2
fi

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
future="$(python3 -c 'import datetime; print((datetime.datetime.utcnow()+datetime.timedelta(hours=4)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
past="$(python3 -c 'import datetime; print((datetime.datetime.utcnow()-datetime.timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

GAP_ID="INFRA-RACE-TEST"
MY_SESSION="session-mine-$$"
OTHER_SESSION="session-other-$$"

# Minimal stub git repo (gap-claim.sh calls git worktree list, rev-parse)
make_stub_repo() {
    local dir="$1"
    mkdir -p "$dir/.chump-locks"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit --allow-empty -m "init" -q
    echo "$dir"
}

# Stub gh binary: returns match or no-match for PR search
make_gh_stub() {
    local dir="$1"
    local mode="${2:-no-match}"  # "match" or "no-match"
    local pr_num="${3:-42}"
    mkdir -p "$dir"
    if [[ "$mode" == "match" ]]; then
        cat > "$dir/gh" <<STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"--search"* && "\$*" == *"in:title"* ]]; then
    echo '{"number":${pr_num},"headRefName":"chump/other-branch"}'
    exit 0
fi
exit 0
STUBEOF
    else
        cat > "$dir/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"--search"* && "$*" == *"in:title"* ]]; then
    echo 'null'
    exit 0
fi
exit 0
STUBEOF
    fi
    chmod +x "$dir/gh"
}

# Helper: run gap-claim.sh under controlled env; capture output + RC
run_claim() {
    local lock_dir="$1"
    local repo_dir="$2"
    local stub_path="$3"
    local -a extra_env=("${@:4}")

    set +e
    OUTPUT="$(env \
        PATH="${stub_path}:${PATH}" \
        CHUMP_LOCK_DIR="$lock_dir" \
        CHUMP_SESSION_ID="$MY_SESSION" \
        REPO_ROOT="$repo_dir" \
        CHUMP_ALLOW_MAIN_WORKTREE=1 \
        CHUMP_ALLOW_REUSE_BRANCH=1 \
        CHUMP_AMBIENT_GLANCE=0 \
        CHUMP_AMBIENT_SESSION_START_EMIT=0 \
        "${extra_env[@]+"${extra_env[@]}"}" \
        bash "$CLAIM_SH" "$GAP_ID" 2>&1)"
    RC=$?
    set -e
}

# ── Test 1: sibling live lease → claim-time check aborts ────────────────────
echo "--- Test 1: sibling live lease blocks claim (INFRA-403 exclusivity check) ---"
T1_REPO="$(make_stub_repo "$TMPBASE/t1")"
T1_LOCKS="$T1_REPO/.chump-locks"
T1_STUBS="$TMPBASE/t1-stubs"
make_gh_stub "$T1_STUBS" "no-match"

cat > "$T1_LOCKS/${OTHER_SESSION}.json" <<JSON
{
  "session_id": "$OTHER_SESSION",
  "gap_id": "$GAP_ID",
  "taken_at": "$now",
  "expires_at": "$future",
  "heartbeat_at": "$now",
  "purpose": "gap:$GAP_ID"
}
JSON

run_claim "$T1_LOCKS" "$T1_REPO" "$T1_STUBS"
if echo "$OUTPUT" | grep -q "INFRA-403"; then
    ok "Test 1: sibling live lease aborts claim with INFRA-403 message"
else
    fail "Test 1: expected INFRA-403 abort message; output was: >>>$OUTPUT<<<"
fi
if [[ "$RC" -ne 0 ]]; then
    ok "Test 1: exit code non-zero (claim correctly failed)"
else
    fail "Test 1: expected non-zero exit, got 0"
fi

# ── Test 2: open PR for gap → claim-time PR check aborts ────────────────────
echo "--- Test 2: open PR for gap blocks claim (Check 1.5 at claim time) ---"
T2_REPO="$(make_stub_repo "$TMPBASE/t2")"
T2_LOCKS="$T2_REPO/.chump-locks"
T2_STUBS="$TMPBASE/t2-stubs"
make_gh_stub "$T2_STUBS" "match" 42

run_claim "$T2_LOCKS" "$T2_REPO" "$T2_STUBS"
if echo "$OUTPUT" | grep -q "INFRA-403"; then
    ok "Test 2: open PR aborts claim with INFRA-403 message"
else
    fail "Test 2: expected INFRA-403 abort for open PR; output was: >>>$OUTPUT<<<"
fi
if [[ "$RC" -ne 0 ]]; then
    ok "Test 2: exit code non-zero (claim correctly failed)"
else
    fail "Test 2: expected non-zero exit, got 0"
fi

# ── Test 3: CHUMP_SPECULATIVE=1 bypasses both checks ────────────────────────
echo "--- Test 3: CHUMP_SPECULATIVE=1 bypasses claim-time exclusivity checks ---"
T3_REPO="$(make_stub_repo "$TMPBASE/t3")"
T3_LOCKS="$T3_REPO/.chump-locks"
T3_STUBS="$TMPBASE/t3-stubs"
make_gh_stub "$T3_STUBS" "match" 42

# Also write a sibling lease
cat > "$T3_LOCKS/${OTHER_SESSION}.json" <<JSON
{
  "session_id": "$OTHER_SESSION",
  "gap_id": "$GAP_ID",
  "taken_at": "$now",
  "expires_at": "$future",
  "heartbeat_at": "$now",
  "purpose": "gap:$GAP_ID"
}
JSON

run_claim "$T3_LOCKS" "$T3_REPO" "$T3_STUBS" "CHUMP_SPECULATIVE=1"
if [[ "$RC" -eq 0 ]]; then
    ok "Test 3: CHUMP_SPECULATIVE=1 bypasses claim-time checks (INFRA-193 race mode)"
else
    fail "Test 3: CHUMP_SPECULATIVE=1 should bypass; output was: >>>$OUTPUT<<<"
fi

# ── Test 4: own session's existing lease does not block ─────────────────────
echo "--- Test 4: own session's existing lease is not a conflict ---"
T4_REPO="$(make_stub_repo "$TMPBASE/t4")"
T4_LOCKS="$T4_REPO/.chump-locks"
T4_STUBS="$TMPBASE/t4-stubs"
make_gh_stub "$T4_STUBS" "no-match"

# Write OUR OWN session's lease (re-entrant claim)
cat > "$T4_LOCKS/${MY_SESSION}.json" <<JSON
{
  "session_id": "$MY_SESSION",
  "gap_id": "$GAP_ID",
  "taken_at": "$now",
  "expires_at": "$future",
  "heartbeat_at": "$now",
  "purpose": "gap:$GAP_ID"
}
JSON

run_claim "$T4_LOCKS" "$T4_REPO" "$T4_STUBS"
if [[ "$RC" -eq 0 ]]; then
    ok "Test 4: own session's existing lease does not block re-entrant claim"
else
    fail "Test 4: own lease should not block; output was: >>>$OUTPUT<<<"
fi

# ── Test 5: expired sibling lease is ignored ─────────────────────────────────
echo "--- Test 5: expired/stale sibling lease does not block ---"
T5_REPO="$(make_stub_repo "$TMPBASE/t5")"
T5_LOCKS="$T5_REPO/.chump-locks"
T5_STUBS="$TMPBASE/t5-stubs"
make_gh_stub "$T5_STUBS" "no-match"

cat > "$T5_LOCKS/${OTHER_SESSION}.json" <<JSON
{
  "session_id": "$OTHER_SESSION",
  "gap_id": "$GAP_ID",
  "taken_at": "$past",
  "expires_at": "$past",
  "heartbeat_at": "$past",
  "purpose": "gap:$GAP_ID"
}
JSON

run_claim "$T5_LOCKS" "$T5_REPO" "$T5_STUBS"
if [[ "$RC" -eq 0 ]]; then
    ok "Test 5: expired sibling lease is ignored (stale = free)"
else
    fail "Test 5: expired lease should not block; output was: >>>$OUTPUT<<<"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "${#FAILS[@]}" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
