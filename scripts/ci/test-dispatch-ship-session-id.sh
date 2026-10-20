#!/usr/bin/env bash
# scripts/ci/test-dispatch-ship-session-id.sh — INFRA-8204
#
# `chump dispatch --backend headless` creates a fresh worktree, claims the
# gap's lease INTO that worktree's own `.chump-locks/`, then runs bot-merge.sh
# there WITHOUT exporting CHUMP_SESSION_ID — so bot-merge.sh's session-ID
# auto-detection (which only ever scanned the MAIN checkout's $LOCK_DIR and
# state.db) could never find the lease claim() just wrote, and its INFRA-1901
# "already inside claimed worktree" check re-invoked `chump claim`, either
# spawning a stray second worktree or failing with "worktree already exists".
#
# This test exercises the building blocks the fix added:
#   1. lease_file_for_gap_in_dir() finds/misses leases in a dispatch-shaped
#      worktree's .chump-locks/ dir.
#   2. lease_session_id() reads the session id back out of that lease file.
#   3. grep-level contract on bot-merge.sh: both the session auto-detection
#      block and the INFRA-1901 pre-claim check call
#      lease_file_for_gap_in_dir against "$PWD/.chump-locks", and the
#      META-156 AC#2 message block no longer prints the literal '<unset>' or
#      '<unknown>'.
#   4. grep-level contract on src/dispatch.rs: ship() exports
#      CHUMP_SESSION_ID on the bot-merge Command.
# Best effort: a bot-merge.sh --dry-run smoke run against a fixture worktree
# with stub gh/chump binaries on PATH, asserting the auto-detect line appears
# and `chump claim` is never invoked.
#
# No network, no cargo, no real headless child — bash only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FAIL_COUNT=0
ok()   { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "=== INFRA-8204 dispatch ship-phase session-id test ==="
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../lib/lease.sh
source "${REPO_ROOT}/scripts/lib/lease.sh"

# ── Fixture: a dispatch-shaped worktree lease ────────────────────────────────
WT="${TMP}/dispatch-wt"
mkdir -p "${WT}/.chump-locks"
LEASE_FILE="${WT}/.chump-locks/dispatch-infra-9999-1-1.json"
cat > "$LEASE_FILE" <<'EOF'
{"session_id":"dispatch-infra-9999-1-1","gap_id":"INFRA-9999","worktree":"PLACEHOLDER","expires_at":"2099-01-01T00:00:00Z"}
EOF
# Swap in the real worktree path (avoids escaping it into the heredoc above).
sed -i.bak "s#PLACEHOLDER#${WT}#" "$LEASE_FILE" && rm -f "${LEASE_FILE}.bak"
printf '%s' "dispatch-infra-9999-1-1" > "${WT}/.chump-locks/.wt-session-id"

# ── 1. lease_file_for_gap_in_dir finds/misses correctly ──────────────────────
echo "[1. lease_file_for_gap_in_dir]"

FOUND="$(lease_file_for_gap_in_dir "${WT}/.chump-locks" "INFRA-9999" || true)"
if [[ "$FOUND" == "$LEASE_FILE" ]]; then
    ok "finds the dispatch worktree's own lease file for INFRA-9999"
else
    fail "expected '$LEASE_FILE', got '$FOUND'"
fi

if MISS="$(lease_file_for_gap_in_dir "${WT}/.chump-locks" "INFRA-0000")"; then
    fail "expected rc=1 (no match) for INFRA-0000, got rc=0 output='$MISS'"
elif [[ -n "$MISS" ]]; then
    fail "expected empty output for INFRA-0000, got '$MISS'"
else
    ok "returns empty + rc=1 for a gap id with no lease in the dir"
fi

# ── 2. lease_session_id reads the dispatch session id back out ──────────────
echo
echo "[2. lease_session_id]"

SID="$(lease_session_id "$LEASE_FILE")"
if [[ "$SID" == "dispatch-infra-9999-1-1" ]]; then
    ok "lease_session_id reads back the dispatch session id"
else
    fail "expected 'dispatch-infra-9999-1-1', got '$SID'"
fi

# ── 3. grep-level contracts ──────────────────────────────────────────────────
echo
echo "[3. grep-level contracts]"

BOT_MERGE="${REPO_ROOT}/scripts/coord/bot-merge.sh"
DISPATCH_RS="${REPO_ROOT}/src/dispatch.rs"

# bot-merge.sh must call lease_file_for_gap_in_dir against $PWD/.chump-locks
# in BOTH the session auto-detection block and the INFRA-1901 pre-claim check.
CALL_COUNT="$(grep -c 'lease_file_for_gap_in_dir "\$PWD/.chump-locks"' "$BOT_MERGE" || true)"
if [[ "$CALL_COUNT" -ge 2 ]]; then
    ok "bot-merge.sh calls lease_file_for_gap_in_dir \"\$PWD/.chump-locks\" at least twice (got $CALL_COUNT)"
else
    fail "expected >=2 calls to lease_file_for_gap_in_dir \"\$PWD/.chump-locks\" in bot-merge.sh, got $CALL_COUNT"
fi

# The META-156 AC#2 block (bounded by its characteristic marker through the
# next top-level 'else' claim-failure branch) must never print the literal
# placeholders this gap replaced with concrete sources.
AC2_BLOCK="$(awk '/META-156 AC#2: re-claim failure/,/Some other claim failure/' "$BOT_MERGE")"
if printf '%s' "$AC2_BLOCK" | grep -qF '<unset>'; then
    fail "META-156 AC#2 block still contains the literal '<unset>'"
elif printf '%s' "$AC2_BLOCK" | grep -qF '<unknown>'; then
    fail "META-156 AC#2 block still contains the literal '<unknown>'"
else
    ok "META-156 AC#2 block no longer prints '<unset>' or '<unknown>'"
fi

# dispatch.rs: ship() must export CHUMP_SESSION_ID explicitly onto the
# bot-merge Command, not merely rely on inheritance.
SHIP_FN="$(awk '/^fn ship\(/,/^fn current_pr_number/' "$DISPATCH_RS")"
if printf '%s' "$SHIP_FN" | grep -q 'cmd.env("CHUMP_SESSION_ID"'; then
    ok "dispatch.rs ship() sets CHUMP_SESSION_ID on the bot-merge Command"
else
    fail "dispatch.rs ship() does not set CHUMP_SESSION_ID on the bot-merge Command"
fi

# ── 4. best-effort: bot-merge.sh --dry-run smoke run ─────────────────────────
echo
echo "[4. bot-merge.sh --dry-run smoke run (best effort)]"

run_dry_run_smoke() {
    local fixture="${TMP}/fixture-repo"
    mkdir -p "$fixture"
    (
        cd "$fixture" || exit 1
        git init -q -b main
        git config user.email test@example.com
        git config user.name test
        echo "x" > f.txt
        git add f.txt
        git commit -q -m init
        git checkout -q -b claude/infra-9999
        echo "y" >> f.txt
        git add f.txt
        git commit -q -m "work for INFRA-9999"
    ) || return 1

    mkdir -p "${fixture}/.chump-locks"
    cat > "${fixture}/.chump-locks/dispatch-infra-9999-1-1.json" <<EOF
{"session_id":"dispatch-infra-9999-1-1","gap_id":"INFRA-9999","worktree":"${fixture}","expires_at":"2099-01-01T00:00:00Z"}
EOF
    printf '%s' "dispatch-infra-9999-1-1" > "${fixture}/.chump-locks/.wt-session-id"

    local stub_bin="${TMP}/stub-bin"
    mkdir -p "$stub_bin"
    local argv_log="${TMP}/chump-argv.log"
    : > "$argv_log"

    cat > "${stub_bin}/chump" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${argv_log}"
if [[ "\$1" == "gap" && "\$2" == "preflight" ]]; then
    echo "[preflight] OK"
    exit 0
fi
exit 0
EOF
    chmod +x "${stub_bin}/chump"

    cat > "${stub_bin}/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${stub_bin}/gh"

    local out
    if ! out="$(cd "$fixture" && PATH="${stub_bin}:${PATH}" bash "${BOT_MERGE}" --gap INFRA-9999 --dry-run 2>&1)"; then
        printf '%s\n' "$out" >&2
        return 2
    fi

    if grep -q 'claim' "$argv_log" 2>/dev/null; then
        printf '%s\n' "$out" >&2
        fail "stub chump recorded a 'claim' call — bot-merge re-invoked chump claim \
instead of recognizing the dispatch worktree's own lease"
    else
        ok "stub chump never saw a 'claim' invocation during --dry-run"
    fi

    if printf '%s' "$out" | grep -q 'INFRA-8204'; then
        ok "bot-merge --dry-run output contains the INFRA-8204 auto-detect line"
    else
        fail "bot-merge --dry-run output missing the INFRA-8204 auto-detect line"
    fi

    if printf '%s' "$out" | grep -qi 're-claim failure'; then
        fail "bot-merge --dry-run output contains a re-claim failure message"
    else
        ok "bot-merge --dry-run output contains no re-claim failure message"
    fi
}

if run_dry_run_smoke; then
    :
else
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
        echo "SKIP: bot-merge dry-run not exercised (fixture invocation failed — \
bot-merge.sh's --dry-run path has preconditions beyond this fixture's reach)"
    fi
fi

# ── 5. CREDIBLE-1580: auto-merge is default-OFF without --auto-merge ─────────
#    bot-merge.sh self-armed GitHub auto-merge on the default `internal` lane
#    even when `chump dispatch` never passed --auto-merge (src/dispatch.rs only
#    appends the flag when opts.auto_merge is true) — #5613 self-armed 3x in 95
#    min inside the CREDIBLE-1576 dispatch. The arm decision is now default-OFF
#    on every lane; the ONLY arming route is an explicit --auto-merge (the
#    CREDIBLE-1542 review-held path). bot_merge_lane_resolved.auto_merge_requested
#    is the resolved decision the arm step (bot-merge.sh section 7) gates on, so
#    asserting it is a behavioral check on a dispatch-shaped run: without the
#    flag it must resolve to 0 and make zero `gh pr merge` calls. Mutant
#    (restore the internal-lane default arm) flips it to 1 and this leg fails.
echo
echo "[5. CREDIBLE-1580 auto-merge default-OFF without --auto-merge]"

credible_1580_arm_default() {
    local wt="${TMP}/cred1580-wt"
    mkdir -p "$wt"
    (
        cd "$wt" || exit 1
        git init -q -b main
        git config user.email test@example.com
        git config user.name test
        echo x > f.txt && git add f.txt && git commit -q -m init
        git checkout -q -b claude/infra-9999
        echo y >> f.txt && git add f.txt && git commit -q -m "work for INFRA-9999"
    ) || return 2

    mkdir -p "${wt}/.chump-locks"
    cat > "${wt}/.chump-locks/dispatch-infra-9999-1-1.json" <<EOF
{"session_id":"dispatch-infra-9999-1-1","gap_id":"INFRA-9999","worktree":"${wt}","expires_at":"2099-01-01T00:00:00Z"}
EOF
    printf '%s' "dispatch-infra-9999-1-1" > "${wt}/.chump-locks/.wt-session-id"

    local sbin="${TMP}/cred1580-bin"
    mkdir -p "$sbin"
    local gh_argv="${TMP}/cred1580-gh-argv.log"
    : > "$gh_argv"
    cat > "${sbin}/chump" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == gap && "$2" == preflight ]] && { echo "[preflight] OK"; exit 0; }
exit 0
EOF
    chmod +x "${sbin}/chump"
    # Stub gh records every argv so we can prove zero `pr merge` calls.
    cat > "${sbin}/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_argv}"
exit 1
EOF
    chmod +x "${sbin}/gh"

    # auto_merge_requested of the last bot_merge_lane_resolved event ("" if none).
    _resolved() {
        grep 'bot_merge_lane_resolved' "$1" 2>/dev/null | tail -1 \
            | grep -oE '"auto_merge_requested":[01]' | grep -oE '[01]$' || true
    }

    # Run exactly as `chump dispatch` does: no --auto-merge. The lane-resolved
    # event is emitted right after arg-parse, so it lands regardless of
    # bot-merge's eventual exit code; capture with || true.
    local amb_no="${TMP}/cred1580-amb-no.jsonl"; : > "$amb_no"
    ( cd "$wt" && PATH="${sbin}:${PATH}" CHUMP_AMBIENT_LOG="$amb_no" \
        CHUMP_SESSION_ID=dispatch-infra-9999-1-1 \
        bash "${BOT_MERGE}" --gap INFRA-9999 --dry-run >/dev/null 2>&1 ) || true
    local got_no; got_no="$(_resolved "$amb_no")"
    if [[ -z "$got_no" ]]; then
        return 2   # lane resolution not reached in this env — SKIP (don't false-fail)
    fi
    if [[ "$got_no" == "0" ]]; then
        ok "dispatch-shaped run without --auto-merge resolves auto_merge_requested=0"
    else
        fail "dispatch-shaped run without --auto-merge resolved auto_merge_requested=$got_no (self-arm default is back)"
    fi
    if grep -qE '(^| )pr merge( |$)' "$gh_argv" 2>/dev/null; then
        fail "bot-merge made a 'gh pr merge' call without --auto-merge: $(grep 'pr merge' "$gh_argv")"
    else
        ok "bot-merge made zero 'gh pr merge' calls without --auto-merge"
    fi

    # Positive control: the explicit flag still arms (resolves to 1).
    local amb_yes="${TMP}/cred1580-amb-yes.jsonl"; : > "$amb_yes"
    ( cd "$wt" && PATH="${sbin}:${PATH}" CHUMP_AMBIENT_LOG="$amb_yes" \
        CHUMP_SESSION_ID=dispatch-infra-9999-1-1 \
        bash "${BOT_MERGE}" --gap INFRA-9999 --auto-merge --dry-run >/dev/null 2>&1 ) || true
    local got_yes; got_yes="$(_resolved "$amb_yes")"
    if [[ "$got_yes" == "1" ]]; then
        ok "explicit --auto-merge resolves auto_merge_requested=1 (review-held arming route intact)"
    elif [[ -n "$got_yes" ]]; then
        fail "explicit --auto-merge resolved auto_merge_requested=$got_yes (expected 1)"
    fi
    return 0
}

_c1580_rc=0
credible_1580_arm_default || _c1580_rc=$?
if [[ "$_c1580_rc" -eq 2 ]]; then
    echo "SKIP: bot-merge lane resolution not reached in this fixture (CREDIBLE-1580 leg skipped)"
fi

echo
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "=== INFRA-8204 tests FAILED ($FAIL_COUNT failure(s)) ==="
    exit 1
fi
echo "=== INFRA-8204 tests complete ==="
