#!/usr/bin/env bash
# INFRA-7946: unit test for scripts/coord/lib/lock.sh — the coord-lane
# entrypoint over the shared lock primitive (INFRA-6130/INFRA-1966 slice).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../coord/lib/lock.sh
source "$REPO_ROOT/scripts/coord/lib/lock.sh"

TMP_LOCK_DIR="$(mktemp -d)"
CHUMP_LOCK_DIR="$TMP_LOCK_DIR"
trap 'rm -rf "$TMP_LOCK_DIR"' EXIT

PASS=0
FAIL=0

_ok() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
_bad() { echo "FAIL: $1"; FAIL=$(( FAIL + 1 )); }

# 1. Basic acquire succeeds when the lock is free.
if acquire_lock "coord-basic" 5; then
  _ok "acquire_lock succeeds when lock is free"
else
  _bad "acquire_lock failed on a free lock"
fi

# 2. Double-acquire failure: a non-blocking (timeout=0) acquire on an
#    already-held lock must fail immediately, not hang or succeed.
start=$(date +%s)
if acquire_lock "coord-basic" 0; then
  _bad "non-blocking acquire_lock succeeded while lock was already held"
  release_lock "coord-basic"
else
  elapsed=$(( $(date +%s) - start ))
  if [[ "$elapsed" -le 2 ]]; then
    _ok "non-blocking acquire_lock correctly failed fast (${elapsed}s) on a held lock"
  else
    _bad "non-blocking acquire_lock took too long (${elapsed}s) — not actually non-blocking"
  fi
fi

# 3. Release cycle: after release, the lock dir is gone and a fresh
#    acquire succeeds again.
release_lock "coord-basic"
if [[ ! -d "$(_lock_path coord-basic)" ]]; then
  _ok "release_lock removes the lock dir"
else
  _bad "release_lock left the lock dir behind"
fi
if acquire_lock "coord-basic" 2; then
  _ok "acquire_lock succeeds again after release"
  release_lock "coord-basic"
else
  _bad "acquire_lock failed to reacquire a released lock"
fi

echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
