#!/usr/bin/env bash
# scripts/ci/test-merge-queue-rebase-skip.sh — CREDIBLE-1510 (PHASE-R R3)
#
# Once main has a GitHub merge queue, a PR that is already queued must never
# be rebased or force-pushed from outside: the queue builds its own
# merge_group commit, and an external `gh pr update-branch` / push to the PR
# head evicts the entry. This proves the skip with a stubbed gh (no network):
#
#   1. lib/merge_queue.sh: queued numbers parsed from GraphQL; `[]`/empty
#      stub output reads as "nothing queued"; a failing gh reports unknown.
#   2. lib/pr_rebase.sh --now (pr-shepherd-daemon's path) and
#      pr_rebase_if_strict (cascade-unblock-detector / wizard path):
#      queued PR -> NO update-branch; unqueued -> update-branch;
#      lookup failure -> NO update-branch (fail closed).
#   3. armed-pr-rebaser.sh against a real local git fixture: queued armed
#      DIRTY PR -> branch untouched on origin; unqueued -> rebased + pushed;
#      lookup failure -> cycle skipped, branch untouched.
#   4. pr-shepherd-daemon.sh classifies the skip as rebase_skipped/merge_queue
#      (source contract — the daemon's rebase path needs a live tick).
#
# Depth: edge (positive, negative, and failure-mode per caller). Gap: no live
# merge queue exists until the ruleset flip (docs/process/MERGE_QUEUE_FLIP.md),
# so the GraphQL response shape for a NON-empty queue is asserted from the
# schema (introspected 2026-10-17), not from a recorded live response.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MQ_LIB="$REPO_ROOT/scripts/coord/lib/merge_queue.sh"
REBASE_LIB="$REPO_ROOT/scripts/coord/lib/pr_rebase.sh"
REBASER="$REPO_ROOT/scripts/coord/armed-pr-rebaser.sh"
SHEPHERD="$REPO_ROOT/scripts/coord/pr-shepherd-daemon.sh"

echo "=== CREDIBLE-1510 merge-queue rebase-skip tests ==="

for f in "$MQ_LIB" "$REBASE_LIB" "$REBASER" "$SHEPHERD"; do
    [[ -f "$f" ]] || { fail "missing $f"; echo "=== RESULTS: $PASS passed, $FAIL failed ==="; exit 1; }
done

TMP="$(mktemp -d -t mq-rebase-skip-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ── Stub gh ─────────────────────────────────────────────────────────────────
# Behaviour is driven by files in $STUB_DIR so one stub serves every case:
#   queue        — lines printed for `gh api graphql` (the queued PR numbers)
#   queue_fail   — if present, `gh api graphql` exits 1
#   pr_list      — JSON printed for `gh pr list`
#   calls        — every update-branch / merge invocation is appended here
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR" "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
D="$STUB_DIR"
case "\$1 \$2" in
    "api graphql")
        [ -f "\$D/queue_fail" ] && exit 1
        [ -f "\$D/queue" ] && cat "\$D/queue"
        exit 0 ;;
    "api "*)
        # branch protection (pr_rebase_if_strict)
        printf '{"required_status_checks":{"strict":true}}\n'
        exit 0 ;;
    "pr update-branch")
        echo "update-branch \$*" >> "\$D/calls"
        exit 0 ;;
    "pr list")
        [ -f "\$D/pr_list" ] && cat "\$D/pr_list" || echo '[]'
        exit 0 ;;
    "pr merge")
        echo "merge \$*" >> "\$D/calls"
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"
GH="$TMP/bin/gh"

reset_stub() { rm -f "$STUB_DIR"/*; }

# ── 1. lib/merge_queue.sh ───────────────────────────────────────────────────
echo "-- 1. merge_queue_numbers"
reset_stub
printf '4242\n4243\n' > "$STUB_DIR/queue"
out="$(bash -c "source '$MQ_LIB'; merge_queue_numbers test/repo main '$GH'")"; rc=$?
if [[ $rc -eq 0 && "$out" == $'4242\n4243' ]]; then
    ok "queued numbers parsed (4242, 4243)"
else
    fail "expected rc=0 + '4242\\n4243'; got rc=$rc out='$out'"
fi
if bash -c "source '$MQ_LIB'; merge_queue_contains \"\$(printf '4242\n4243')\" 4243"; then
    ok "merge_queue_contains finds a listed PR"
else
    fail "merge_queue_contains missed a listed PR"
fi
if bash -c "source '$MQ_LIB'; merge_queue_contains \"\$(printf '4242\n4243')\" 424"; then
    fail "merge_queue_contains matched a prefix (424 vs 4242)"
else
    ok "merge_queue_contains is exact-match (424 does not match 4242)"
fi

reset_stub
echo '[]' > "$STUB_DIR/queue"
out="$(bash -c "source '$MQ_LIB'; merge_queue_numbers test/repo main '$GH'")"; rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then
    ok "stub output '[]' (no queue) reads as nothing queued"
else
    fail "expected rc=0 + empty for '[]'; got rc=$rc out='$out'"
fi

reset_stub
touch "$STUB_DIR/queue_fail"
bash -c "source '$MQ_LIB'; merge_queue_numbers test/repo main '$GH'" >/dev/null; rc=$?
if [[ $rc -eq 1 ]]; then
    ok "failing gh reports unknown (exit 1)"
else
    fail "expected exit 1 on lookup failure; got $rc"
fi

# ── 2. lib/pr_rebase.sh ─────────────────────────────────────────────────────
echo "-- 2. pr_rebase.sh (shepherd --now path + strict path)"
run_rebase() {  # $@ = pr_rebase.sh args
    CHUMP_PR_REBASE_GH="$GH" CHUMP_PR_REBASE_CACHE_DIR="$TMP/bp-cache" \
        bash "$REBASE_LIB" "$@" 2>&1
}

reset_stub; echo 4242 > "$STUB_DIR/queue"
out="$(run_rebase --now 4242 test/repo)"; rc=$?
if [[ $rc -eq 0 ]] && [[ ! -s "$STUB_DIR/calls" ]] && echo "$out" | grep -q "merge-queue-skip"; then
    ok "--now: queued PR #4242 -> no update-branch, merge-queue-skip reported"
else
    fail "--now: queued PR was rebased or not reported (rc=$rc out='$out' calls=$(cat "$STUB_DIR/calls" 2>/dev/null))"
fi

reset_stub; echo 4242 > "$STUB_DIR/queue"
out="$(run_rebase --now 5000 test/repo)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "update-branch 5000" "$STUB_DIR/calls" 2>/dev/null; then
    ok "--now: unqueued PR #5000 (while #4242 is queued) -> update-branch called"
else
    fail "--now: unqueued PR was not rebased (rc=$rc out='$out')"
fi

reset_stub; touch "$STUB_DIR/queue_fail"
out="$(run_rebase --now 5000 test/repo)"; rc=$?
if [[ $rc -eq 0 ]] && [[ ! -s "$STUB_DIR/calls" ]] && echo "$out" | grep -q "unknown"; then
    ok "--now: queue lookup failure -> fail closed, no update-branch"
else
    fail "--now: lookup failure did not fail closed (rc=$rc out='$out')"
fi

reset_stub; echo 4242 > "$STUB_DIR/queue"; rm -rf "$TMP/bp-cache"
out="$(run_rebase 4242 test/repo main)"; rc=$?
if [[ $rc -eq 0 ]] && [[ ! -s "$STUB_DIR/calls" ]] && echo "$out" | grep -q "merge-queue-skip"; then
    ok "strict path: queued PR #4242 -> no update-branch even with strict=true"
else
    fail "strict path: queued PR was rebased (rc=$rc out='$out')"
fi

reset_stub; rm -rf "$TMP/bp-cache"
out="$(run_rebase 5000 test/repo main)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "update-branch 5000" "$STUB_DIR/calls" 2>/dev/null; then
    ok "strict path: unqueued PR with strict=true -> update-branch called (pre-queue behaviour kept)"
else
    fail "strict path: unqueued PR not rebased (rc=$rc out='$out')"
fi

# ── 3. armed-pr-rebaser.sh against a local git fixture ──────────────────────
echo "-- 3. armed-pr-rebaser.sh"
build_fixture() {  # $1 = dir
    local d="$1" seed="$1/seed"
    git init -q --bare -b main "$d/origin.git"
    git init -q -b main "$seed"
    git -C "$seed" config user.email t@example.com
    git -C "$seed" config user.name Test
    echo root > "$seed/README.md"
    git -C "$seed" add README.md && git -C "$seed" commit -q -m init
    git -C "$seed" remote add origin "$d/origin.git"
    git -C "$seed" push -q origin main
    git -C "$seed" checkout -q -b pr-branch
    echo fix > "$seed/fix.txt"
    git -C "$seed" add fix.txt && git -C "$seed" commit -q -m "fix: change"
    git -C "$seed" push -q origin pr-branch
    git -C "$seed" checkout -q main
    echo advance >> "$seed/README.md"
    git -C "$seed" add README.md && git -C "$seed" commit -q -m "advance main"
    git -C "$seed" push -q origin main
    git clone -q "$d/origin.git" "$d/root"
    git -C "$d/root" config user.email t@example.com
    git -C "$d/root" config user.name Test
    mkdir -p "$d/root/.chump-locks"
}
PR_JSON='[{"number": 4242, "mergeStateStatus": "DIRTY", "autoMergeRequest": {"mergeMethod": "SQUASH"},
           "headRefName": "pr-branch", "labels": [], "statusCheckRollup": []}]'

run_rebaser() {  # $1 = fixture dir
    PATH="$TMP/bin:$PATH" CHUMP_REPO_ROOT="$1/root" CHUMP_PR_REPO="test/repo" \
        CHUMP_MERGE_PIPELINE_LOCK_FILE="$1/mpl.lock" bash "$REBASER" 2>&1
}
branch_tip() { git -C "$1/origin.git" rev-parse refs/heads/pr-branch; }

# 3a. queued -> untouched
F="$TMP/fx-queued"; mkdir -p "$F"; build_fixture "$F"
reset_stub; echo 4242 > "$STUB_DIR/queue"; printf '%s\n' "$PR_JSON" > "$STUB_DIR/pr_list"
before="$(branch_tip "$F")"; out="$(run_rebaser "$F")"; after="$(branch_tip "$F")"
if [[ "$before" == "$after" ]] && echo "$out" | grep -q "#4242: merge-queue-skip"; then
    ok "rebaser: queued armed DIRTY PR #4242 -> branch untouched on origin"
else
    fail "rebaser: queued PR was force-pushed or not reported (before=$before after=$after out='$out')"
fi

# 3b. not queued -> rebased + pushed (control: proves 3a's skip is the guard, not a broken fixture)
F="$TMP/fx-free"; mkdir -p "$F"; build_fixture "$F"
reset_stub; echo '[]' > "$STUB_DIR/queue"; printf '%s\n' "$PR_JSON" > "$STUB_DIR/pr_list"
before="$(branch_tip "$F")"; out="$(run_rebaser "$F")"; after="$(branch_tip "$F")"
if [[ "$before" != "$after" ]] && echo "$out" | grep -q "rebased clean + pushed"; then
    ok "rebaser: unqueued armed DIRTY PR -> rebased + pushed (control)"
else
    fail "rebaser: control case did not rebase (before=$before after=$after out='$out')"
fi

# 3c. lookup failure -> cycle skipped
F="$TMP/fx-fail"; mkdir -p "$F"; build_fixture "$F"
reset_stub; touch "$STUB_DIR/queue_fail"; printf '%s\n' "$PR_JSON" > "$STUB_DIR/pr_list"
before="$(branch_tip "$F")"; out="$(run_rebaser "$F")"; after="$(branch_tip "$F")"
if [[ "$before" == "$after" ]] && echo "$out" | grep -q "queue state unknown"; then
    ok "rebaser: queue lookup failure -> fail closed, branch untouched"
else
    fail "rebaser: lookup failure did not fail closed (before=$before after=$after out='$out')"
fi

# ── 4. shepherd source contract ─────────────────────────────────────────────
echo "-- 4. pr-shepherd-daemon.sh"
if grep -q '"rebase_skipped" "merge_queue"' "$SHEPHERD" && grep -q 'merge-queue-skip' "$SHEPHERD"; then
    ok "shepherd classifies merge-queue-skip as rebase_skipped/merge_queue"
else
    fail "shepherd lost the merge-queue-skip classification"
fi
if grep -q 'lib/pr_rebase.sh" --now' "$SHEPHERD"; then
    ok "shepherd still rebases through lib/pr_rebase.sh --now (guarded path)"
else
    fail "shepherd no longer rebases via lib/pr_rebase.sh --now — guard bypassed"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    printf '  - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
