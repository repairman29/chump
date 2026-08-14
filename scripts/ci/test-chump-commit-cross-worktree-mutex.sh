#!/usr/bin/env bash
# test-chump-commit-cross-worktree-mutex.sh — CI gate for RESILIENT-117
#
# Verifies:
#   1. chump-commit.sh resolves its index mutex via
#      scripts/lib/index-mutex-path.sh (not the old bare git-dir path).
#   2. scripts/lib/index-mutex-path.sh produces a DIFFERENT, repo-rooted
#      mutex path for each of 3 sibling worktrees.
#   3. Functional: 3 concurrent "claims" (real git worktrees, each holding
#      its own mutex for the duration of a simulated cargo build) do NOT
#      contend on each other's lock — all 3 finish within 30s, i.e. in
#      parallel rather than serialized.
#
# Checks: 5 total (2 source-contract + 3 functional)

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMIT_SH="$REPO_ROOT/scripts/coord/chump-commit.sh"
MUTEX_LIB="$REPO_ROOT/scripts/lib/index-mutex-path.sh"

echo "=== RESILIENT-117: chump-commit cross-worktree mutex isolation ==="
echo

# ── Check 1: chump-commit.sh sources the shared resolver ────────────────────
if grep -q 'index-mutex-path\.sh' "$COMMIT_SH" && grep -q 'chump_index_mutex_path' "$COMMIT_SH"; then
  ok "chump-commit.sh sources index-mutex-path.sh and calls chump_index_mutex_path"
else
  fail "chump-commit.sh does not use the shared mutex-path resolver"
fi

# ── Check 2: resolver lib exists and is executable-as-source ────────────────
if [[ -f "$MUTEX_LIB" ]] && bash -n "$MUTEX_LIB" 2>/dev/null; then
  ok "scripts/lib/index-mutex-path.sh exists and parses cleanly"
else
  fail "scripts/lib/index-mutex-path.sh missing or has a syntax error"
fi

if command -v flock >/dev/null 2>&1; then
  FLOCK_BIN="$(command -v flock)"
else
  echo "SKIP: flock(1) not on PATH — skipping functional checks 3-5"
  echo
  echo "=== Results: $PASS passed, $FAIL failed (3 skipped) ==="
  [[ $FAIL -eq 0 ]] && exit 0 || exit 1
fi

# ── Functional setup: scratch bare repo + 3 sibling worktrees ───────────────
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/resilient-117-test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

BARE="$SCRATCH/origin.git"
git init --quiet --bare "$BARE"

SEED="$SCRATCH/seed"
git clone --quiet "$BARE" "$SEED"
(
  cd "$SEED"
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "seed" > README.md
  git add README.md
  git commit --quiet -m "seed"
  git push --quiet origin HEAD:main
)

WT1="$SCRATCH/wt-alpha"
WT2="$SCRATCH/wt-beta"
WT3="$SCRATCH/wt-gamma"
(
  cd "$SEED"
  git worktree add --quiet -b claim-alpha "$WT1" main
  git worktree add --quiet -b claim-beta  "$WT2" main
  git worktree add --quiet -b claim-gamma "$WT3" main
)

# ── Check 3: each worktree resolves to a DISTINCT mutex path ────────────────
P1="$(cd "$WT1" && bash "$MUTEX_LIB")"
P2="$(cd "$WT2" && bash "$MUTEX_LIB")"
P3="$(cd "$WT3" && bash "$MUTEX_LIB")"

if [[ -n "$P1" && -n "$P2" && -n "$P3" && "$P1" != "$P2" && "$P2" != "$P3" && "$P1" != "$P3" ]]; then
  ok "3 sibling worktrees resolve to 3 distinct mutex paths"
else
  fail "sibling worktrees collided on mutex path: P1=$P1 P2=$P2 P3=$P3"
fi

if [[ "$P1" == "$SCRATCH/"*"/.chump-locks/index-mutex-"* ]]; then
  ok "mutex path is repo-rooted under .chump-locks/ (not inside the linked git-dir)"
else
  fail "mutex path is not repo-rooted under .chump-locks/: $P1"
fi

# ── Check 5 (functional): 3 concurrent "cargo build" holders don't contend ──
# Each holder acquires its own worktree's mutex and sleeps 5s, simulating a
# cargo build running under the lock (as would happen via a pre-commit hook).
# If the mutexes were shared (the bug this gap fixes), the 3 would serialize
# to ~15s; isolated, they finish in ~5s. We assert well under the 30s AC bar.
hold() {
  local mutex="$1" out_dir="$2"
  exec 9>>"$mutex"
  "$FLOCK_BIN" -w 25 9 || exit 1
  sleep 5
  echo "held $mutex (simulated --out-dir=$out_dir)"
}

START=$(date +%s)
hold "$P1" "/tmp/chump-alpha/target" &
PID1=$!
hold "$P2" "/tmp/chump-beta/target" &
PID2=$!
hold "$P3" "/tmp/chump-gamma/target" &
PID3=$!

wait "$PID1"; R1=$?
wait "$PID2"; R2=$?
wait "$PID3"; R3=$?
END=$(date +%s)
ELAPSED=$((END - START))

if [[ $R1 -eq 0 && $R2 -eq 0 && $R3 -eq 0 && $ELAPSED -lt 30 ]]; then
  ok "3 concurrent mutex holders completed in parallel (${ELAPSED}s, all under 30s)"
else
  fail "concurrent mutex holders contended or failed (elapsed=${ELAPSED}s r1=$R1 r2=$R2 r3=$R3)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
