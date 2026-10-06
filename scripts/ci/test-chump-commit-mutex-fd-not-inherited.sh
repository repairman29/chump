#!/usr/bin/env bash
# scripts/ci/test-chump-commit-mutex-fd-not-inherited.sh — RESILIENT-117
#
# Regression guard: the chump-commit index mutex (FD 200, flock) must not leak
# into child processes. A daemon (sccache, rustc server) spawned from a git hook
# that inherits FD 200 keeps the lock held after chump-commit exits.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
S=scripts/coord/chump-commit.sh
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }
echo "=== test-chump-commit-mutex-fd-not-inherited.sh (RESILIENT-117) ==="

# 1. STRUCTURAL: the real script closes FD 200 for git commit and cargo fmt.
grep -qE '^git commit "\$\{GIT_ARGS\[@\]\}" 200>&-' "$S" \
  && p "git commit runs with FD 200 closed" || f "git commit still inherits FD 200"
grep -qE 'cargo fmt --all 200>&-' "$S" \
  && p "cargo fmt runs with FD 200 closed" || f "cargo fmt still inherits FD 200"

# 2. BEHAVIOR: a lingering child that inherited FD 200 blocks the lock; one that
#    had it closed does not.
FLOCK=$(command -v flock || true)
if [ -z "$FLOCK" ]; then
  echo "[SKIP] flock(1) not available — behavioral checks skipped"
else
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  M="$T/mutex"
  try_lock() { "$FLOCK" -n "$M" true; }

  # leaky: child keeps FD 200 after the parent exits
  ( exec 200>>"$M"; "$FLOCK" -n 200 || exit 1; sleep 3 & ) ; sleep 0.3
  try_lock && f "control broken: leaked FD did not hold the lock" \
           || p "control: child inheriting FD 200 keeps the mutex held"
  sleep 3.2

  # fixed: child launched with 200>&- must not hold the lock
  ( exec 200>>"$M"; "$FLOCK" -n 200 || exit 1; sleep 3 200>&- & ) ; sleep 0.3
  try_lock && p "child with FD 200 closed does not hold the mutex after parent exits" \
           || f "mutex still held by child despite 200>&-"
  sleep 3.2
fi

echo ""
echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
