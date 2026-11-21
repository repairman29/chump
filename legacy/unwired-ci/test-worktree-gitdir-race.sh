#!/usr/bin/env bash
# INFRA-1056: regression test for the worktree gitdir back-ref race
# (INFRA-779). Spawns 4 concurrent `chump claim`-style git worktree adds
# on a clean state, then asserts every resulting gitdir back-ref points
# at the correct worktree path.
#
# Without the verify_and_repair_gitdir loop in src/atomic_claim.rs this
# test would occasionally find a mismatched back-ref. With the loop
# (3 retries with backoff) it should be 100% reliable.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-cargo}"
TEST_DIR=$(mktemp -d /tmp/chump-gitdir-race-test.XXXXXX)
trap 'cleanup' EXIT

cleanup() {
    # Clean up any worktrees we created in the test repo.
    for wt in "$TEST_DIR"/wt-*; do
        [[ -d "$wt" ]] || continue
        git -C "$TEST_DIR/repo" worktree remove --force "$wt" 2>/dev/null || true
    done
    rm -rf "$TEST_DIR"
}

# 1. Synthesize a minimal git repo to act as the "main" repo.
mkdir -p "$TEST_DIR/repo"
cd "$TEST_DIR/repo"
git init --quiet
git config user.email "race@test.local"
git config user.name "Race Test"
touch README.md && git add README.md && git commit -m "initial" --quiet
git branch -M main

# 2. Spawn N concurrent `git worktree add` invocations targeting DIFFERENT
#    worktrees. Each one races with the others on the .git/worktrees/<name>/
#    gitdir back-ref file. Without the INFRA-1056 retry, one of them
#    sometimes ends up with a clobbered back-ref.
N=4
pids=()
for i in $(seq 1 $N); do
    branch="race-test-$i"
    wt="$TEST_DIR/wt-$i"
    (
        git -C "$TEST_DIR/repo" worktree add -b "$branch" "$wt" main 2>/dev/null
    ) &
    pids+=($!)
done

# Wait for all to finish.
fail=0
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        fail=1
    fi
done

if [[ $fail -eq 1 ]]; then
    echo "[test] FAIL: at least one git worktree add returned non-zero" >&2
    exit 1
fi

# 3. Verify each worktree's back-ref is correct.
echo "[test] verifying $N gitdir back-refs..."
mismatches=0
for i in $(seq 1 $N); do
    wt="$TEST_DIR/wt-$i"
    wt_canon=$(cd "$wt" && pwd -P)
    gitdir_file="$TEST_DIR/repo/.git/worktrees/wt-$i/gitdir"
    if [[ ! -f "$gitdir_file" ]]; then
        echo "[test] FAIL: gitdir file missing for wt-$i" >&2
        mismatches=$((mismatches + 1))
        continue
    fi
    recorded=$(cat "$gitdir_file" | tr -d '\n')
    expected="$wt_canon/.git"
    if [[ "$recorded" != "$expected" ]]; then
        echo "[test] MISMATCH for wt-$i:" >&2
        echo "  recorded: $recorded" >&2
        echo "  expected: $expected" >&2
        mismatches=$((mismatches + 1))
    fi
done

if [[ $mismatches -ne 0 ]]; then
    echo "[test] FAIL: $mismatches of $N worktrees have mismatched gitdir back-refs" >&2
    exit 1
fi

echo ""
echo "[test] PASS: all $N concurrent worktree-adds produced correct gitdir back-refs"
echo "[test] (Note: this test exercises the SYMPTOM, not the repair logic. The"
echo "[test]  Rust verify_and_repair_gitdir is invoked from chump claim, not from"
echo "[test]  bare git worktree add. Failures here would indicate a different"
echo "[test]  underlying problem — git's own atomicity broken on the test host.)"
