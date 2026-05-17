#!/usr/bin/env bash
# test-pr-stuck-auto-respawn.sh — INFRA-1410 smoke test.
#
# Exercises the auto-respawn module added to scripts/ops/stale-pr-reaper.sh
# and the matching `reopen_respawned_gaps` pass in scripts/ops/stuck-pr-filer.sh.
#
# State machine under test (one PR through every transition):
#   1. BLOCKED for < CHUMP_PR_STUCK_SLO_HRS  → no action, no state.
#   2. BLOCKED for ≥ SLO, no prior state    → emit pr_stuck_cycle_1_rebase_attempted,
#                                              invoke chump-rebase-and-push.sh, record state.
#   3. Prior state, < CHUMP_PR_STUCK_RECLOSE_MINS since attempt → wait.
#   4. Prior state, ≥ RECLOSE_MINS since attempt, still BLOCKED → close PR,
#                                              emit pr_auto_closed_for_respawn.
#   5. Label `do-not-respawn` present        → emit pr_stuck_exempt, clear state.
#   6. PR transitions away from BLOCKED      → clear state (no emit).
#   7. stuck-pr-filer.sh reads the respawn event and reopens the cited gap.
#
# Network-free: stubs `gh`, `chump`, and the rebase script via PATH.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/stale-pr-reaper.sh"
FILER="$REPO_ROOT/scripts/ops/stuck-pr-filer.sh"

[[ -x "$REAPER" ]] || { echo "FAIL: $REAPER not executable"; exit 1; }
[[ -x "$FILER" ]]  || { echo "FAIL: $FILER not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/.chump-locks"
export PATH="$TMP/bin:$PATH"

# ── Stubbed binaries ─────────────────────────────────────────────────────────

# Stub `chump`: empty open list by default, "ship" no-ops, "gap show" returns
# a single gap row whose status flips per fixture.
GAP_FIXTURE="$TMP/gap-fixture.txt"
echo 'status: in_progress' > "$GAP_FIXTURE"
GAP_SET_LOG="$TMP/gap-set.log"
: > "$GAP_SET_LOG"
cat > "$TMP/bin/chump" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "gap list --status open --json") echo "[]" ;;
    "gap show "*)
        cat "$GAP_FIXTURE"
        ;;
    "gap set "*)
        echo "\$*" >> "$GAP_SET_LOG"
        ;;
    "gap reserve "*) echo "INFRA-9999" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/chump"

# Stub `chump-rebase-and-push.sh`: log invocations, configurable rc via env.
REBASE_LOG="$TMP/rebase.log"
export REBASE_LOG
: > "$REBASE_LOG"
# Hard-code the log path into the fake script so subprocess inherits via PATH only.
cat > "$TMP/bin/fake-rebase-and-push" <<EOF
#!/usr/bin/env bash
echo "rebase \$*" >> "$REBASE_LOG"
exit "\${FAKE_REBASE_RC:-0}"
EOF
chmod +x "$TMP/bin/fake-rebase-and-push"

# Set up a real git repo so reaper_setup can find a worktree.
cd "$TMP"
git init -q --bare origin.git >/dev/null
git init -q -b main repo >/dev/null
cd "$TMP/repo"
git config user.email "test@chump.local"
git config user.name "Chump Test"
echo init > README.md
git add README.md && git commit -qm "init"
git remote add origin "$TMP/origin.git"
git push -q origin main

export REAPER_LOCK_DIR="$TMP/repo/.chump-locks"
mkdir -p "$REAPER_LOCK_DIR"
AMBIENT="$REAPER_LOCK_DIR/ambient.jsonl"
STATE_FILE="$REAPER_LOCK_DIR/stuck-pr-state.json"

# Helper: PR-list JSON literal builder.
mk_pr_json() {
    local pr_num="$1" branch="$2" title="$3" mss="$4" updated_at="$5" labels_json="$6"
    cat <<JSON
[{"number":$pr_num,"title":"$title","headRefName":"$branch","mergeStateStatus":"$mss","updatedAt":"$updated_at","labels":$labels_json,"isDraft":false,"author":{"login":"alice"},"autoMergeRequest":null}]
JSON
}

# Helper: stub gh that returns a configurable PR list.
PR_FIXTURE="$TMP/prs.json"
echo "[]" > "$PR_FIXTURE"
PR_CLOSE_LOG="$TMP/pr-close.log"
: > "$PR_CLOSE_LOG"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "pr list "*)
        cat "$PR_FIXTURE"
        ;;
    "pr close "*)
        echo "\$*" >> "$PR_CLOSE_LOG"
        ;;
    "pr view "*)
        # stale-pr-reaper's existing freshness gate calls this; return a recent
        # timestamp so the freshness check never aborts a close in tests.
        echo "1970-01-01T00:00:00Z"
        ;;
    "pr diff "*) echo "" ;;
    "pr checks "*) echo "[]" ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

# Common env for every reaper invocation:
#   - keep CHUMP_REAPER_PARITY_CHECK=0 (parity check is for the ghost path, irrelevant)
#   - skip ghost-status scan: empty merged PR list returns nothing anyway
COMMON_ENV=(
    REMOTE=origin
    BASE=main
    REAPER_LOCK_DIR="$REAPER_LOCK_DIR"
    REAPER_REPO_ROOT="$TMP/repo"
    REBASE_SCRIPT_OVERRIDE="$TMP/bin/fake-rebase-and-push"
    CHUMP_REAPER_PARITY_CHECK=0
    CHUMP_GAP_CHECK=0
)

old_iso() {
    # ISO timestamp $1 hours ago.
    python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(hours=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}
old_iso_min() {
    python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(minutes=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}

count_kind() {
    local kind="$1"
    [[ -s "$AMBIENT" ]] || { echo 0; return; }
    local n
    n=$(grep -c "\"kind\":\"${kind}\"" "$AMBIENT" 2>/dev/null || true)
    echo "${n:-0}"
}

reset_state() {
    echo '{}' > "$STATE_FILE"
    : > "$AMBIENT"
    : > "$REBASE_LOG"
    : > "$PR_CLOSE_LOG"
}

PASS=0
FAIL=0
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS"; PASS=$((PASS+1)); }

# ── Test 1: BLOCKED for <SLO — no action ────────────────────────────────────
echo "Test 1: BLOCKED PR younger than SLO is left alone"
reset_state
mk_pr_json 1001 chump/test-young "INFRA-9001: young" BLOCKED "$(old_iso_min 30)" '[]' > "$PR_FIXTURE"
out=$(env "${COMMON_ENV[@]}" CHUMP_PR_STUCK_SLO_HRS=2 "$REAPER" --dry-run 2>&1 || true)
if [[ "$(count_kind pr_stuck_cycle_1_rebase_attempted)" == "0" \
   && "$(count_kind pr_auto_closed_for_respawn)" == "0" ]]; then
    pass
else
    fail "young BLOCKED PR triggered an emit; ambient: $(cat "$AMBIENT")"
fi

# ── Test 2: First detection ≥SLO — emit + invoke rebase ─────────────────────
echo "Test 2: BLOCKED PR ≥ SLO triggers rebase + cycle_1 emit"
reset_state
mk_pr_json 1002 chump/test-stuck "INFRA-9002: needs rebase" BLOCKED "$(old_iso 3)" '[]' > "$PR_FIXTURE"
env "${COMMON_ENV[@]}" CHUMP_PR_STUCK_SLO_HRS=2 "$REAPER" >/dev/null 2>&1 || true
if [[ "$(count_kind pr_stuck_cycle_1_rebase_attempted)" -ge 1 \
   && -s "$REBASE_LOG" \
   && "$(count_kind pr_auto_closed_for_respawn)" == "0" ]]; then
    pass
else
    fail "cycle_1 emit or rebase invocation missing
    ambient: $(cat "$AMBIENT")
    rebase log: $(cat "$REBASE_LOG")"
fi

# Check state recorded.
if grep -q '"rebase_attempted_at"' "$STATE_FILE"; then
    echo "  (state file recorded rebase attempt)"
else
    fail "state file did not record rebase_attempted_at: $(cat "$STATE_FILE")"
fi

# ── Test 3: Within RECLOSE window — wait, no close ──────────────────────────
echo "Test 3: < RECLOSE window since rebase → no close"
reset_state
# Pre-seed state file with a recent rebase attempt.
NOW_ISO=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
cat > "$STATE_FILE" <<JSON
{"1003":{"rebase_attempted_at":"$NOW_ISO","branch":"chump/test","age_hrs_at_attempt":3}}
JSON
mk_pr_json 1003 chump/test "INFRA-9003: still blocked" BLOCKED "$(old_iso 4)" '[]' > "$PR_FIXTURE"
env "${COMMON_ENV[@]}" CHUMP_PR_STUCK_SLO_HRS=2 CHUMP_PR_STUCK_RECLOSE_MINS=30 "$REAPER" >/dev/null 2>&1 || true
if [[ "$(count_kind pr_auto_closed_for_respawn)" == "0" \
   && ! -s "$PR_CLOSE_LOG" ]]; then
    pass
else
    fail "PR closed prematurely within RECLOSE window
    ambient: $(cat "$AMBIENT")
    close log: $(cat "$PR_CLOSE_LOG")"
fi

# ── Test 4: ≥ RECLOSE window, still BLOCKED → close + respawn emit ──────────
echo "Test 4: ≥ RECLOSE window since rebase → close + pr_auto_closed_for_respawn"
reset_state
OLD_ATTEMPT=$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(minutes=45)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
cat > "$STATE_FILE" <<JSON
{"1004":{"rebase_attempted_at":"$OLD_ATTEMPT","branch":"chump/test","age_hrs_at_attempt":3}}
JSON
mk_pr_json 1004 chump/test "INFRA-9004: persistently blocked" BLOCKED "$(old_iso 5)" '[]' > "$PR_FIXTURE"
env "${COMMON_ENV[@]}" CHUMP_PR_STUCK_SLO_HRS=2 CHUMP_PR_STUCK_RECLOSE_MINS=30 "$REAPER" >/dev/null 2>&1 || true
if [[ "$(count_kind pr_auto_closed_for_respawn)" -ge 1 \
   && -s "$PR_CLOSE_LOG" ]]; then
    pass
else
    fail "expected close + pr_auto_closed_for_respawn emit
    ambient: $(cat "$AMBIENT")
    close log: $(cat "$PR_CLOSE_LOG")"
fi

# State for this PR should be cleared after close.
if grep -q '"1004"' "$STATE_FILE"; then
    fail "state for PR 1004 should be cleared after close: $(cat "$STATE_FILE")"
fi

# ── Test 5: do-not-respawn label → exempt emit, no rebase/close ─────────────
echo "Test 5: do-not-respawn label exempts PR"
reset_state
mk_pr_json 1005 chump/test "INFRA-9005: protected" BLOCKED "$(old_iso 5)" '[{"name":"do-not-respawn"}]' > "$PR_FIXTURE"
env "${COMMON_ENV[@]}" CHUMP_PR_STUCK_SLO_HRS=2 "$REAPER" >/dev/null 2>&1 || true
if [[ "$(count_kind pr_stuck_exempt)" -ge 1 \
   && "$(count_kind pr_stuck_cycle_1_rebase_attempted)" == "0" \
   && "$(count_kind pr_auto_closed_for_respawn)" == "0" \
   && ! -s "$PR_CLOSE_LOG" ]]; then
    pass
else
    fail "do-not-respawn label not honored
    ambient: $(cat "$AMBIENT")"
fi

# ── Test 6: PR transitions away from BLOCKED → state cleared ────────────────
echo "Test 6: PR no longer BLOCKED → state cleared, no emit"
reset_state
cat > "$STATE_FILE" <<JSON
{"1006":{"rebase_attempted_at":"$NOW_ISO","branch":"chump/test","age_hrs_at_attempt":3}}
JSON
mk_pr_json 1006 chump/test "INFRA-9006: now mergeable" CLEAN "$(old_iso 5)" '[]' > "$PR_FIXTURE"
env "${COMMON_ENV[@]}" CHUMP_PR_STUCK_SLO_HRS=2 "$REAPER" >/dev/null 2>&1 || true
if [[ "$(count_kind pr_auto_closed_for_respawn)" == "0" \
   && ! -s "$PR_CLOSE_LOG" ]] \
   && ! grep -q '"1006"' "$STATE_FILE"; then
    pass
else
    fail "state for unblocked PR should be cleared without emit
    ambient: $(cat "$AMBIENT")
    state: $(cat "$STATE_FILE")"
fi

# ── Test 7: stuck-pr-filer reopens gap from respawn event ───────────────────
echo "Test 7: stuck-pr-filer reopens cited gap from pr_auto_closed_for_respawn"
# Make sure the gap fixture reports a closed/in_progress gap so the filer flips it open.
cat > "$GAP_FIXTURE" <<EOF
- id: INFRA-9007
  status: claimed
  notes: ""
EOF
# Seed ambient with a respawn event (this is what the reaper emitted earlier).
: > "$AMBIENT"
NOW_ISO2=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
printf '{"ts":"%s","kind":"pr_auto_closed_for_respawn","pr":1007,"branch":"chump/test","gap_ids":"INFRA-9007","title":"INFRA-9007: stuck"}\n' \
    "$NOW_ISO2" >> "$AMBIENT"

# Stub `gh pr list` to return empty (the filer's main loop expects a PR list).
echo "[]" > "$PR_FIXTURE"
: > "$GAP_SET_LOG"

env "${COMMON_ENV[@]}" CHUMP_STUCK_PR_FILER=1 INFRA_386_AUTOCLOSE=0 "$FILER" >/dev/null 2>&1 || true

if grep -q "gap set INFRA-9007 --status open" "$GAP_SET_LOG" \
   && grep -q "gap set INFRA-9007 --add-note .*stuck cycle" "$GAP_SET_LOG"; then
    pass
else
    fail "stuck-pr-filer did not reopen the gap from the respawn event
    gap set log: $(cat "$GAP_SET_LOG")"
fi

# ── Test 8: idempotent — second filer pass does not re-reopen ───────────────
echo "Test 8: filer is idempotent across runs (respawn-handled marker)"
# Re-stub gap show to return the gap *with* the respawn-handled marker now.
cat > "$GAP_FIXTURE" <<EOF
- id: INFRA-9007
  status: open
  notes: "stuck cycle 1 → re-attempt 2026-05-16 (PR #1007 auto-closed) respawn-handled:1007"
EOF
: > "$GAP_SET_LOG"

env "${COMMON_ENV[@]}" CHUMP_STUCK_PR_FILER=1 INFRA_386_AUTOCLOSE=0 "$FILER" >/dev/null 2>&1 || true

if ! grep -q "gap set INFRA-9007" "$GAP_SET_LOG"; then
    pass
else
    fail "filer re-reopened the same gap twice (not idempotent)
    gap set log: $(cat "$GAP_SET_LOG")"
fi

echo ""
echo "=== INFRA-1410 auto-respawn test: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
