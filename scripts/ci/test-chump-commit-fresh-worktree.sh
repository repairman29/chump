#!/usr/bin/env bash
# INFRA-3389: chump-commit.sh must resolve the known-prefixes db via MAIN_REPO and
# must not silently abort when the worktree-local .chump/state.db is empty.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
S=scripts/coord/chump-commit.sh
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

grep -q '_state_db="${MAIN_REPO:-$REPO_ROOT}/.chump/state.db"' "$S" \
  && p "known-prefixes db resolves via MAIN_REPO" || f "state_db not MAIN_REPO-based"

# Mechanism: empty (0-byte) db + failing sqlite3 query must not abort under set -euo pipefail.
if command -v sqlite3 >/dev/null 2>&1; then
  T="$(mktemp -d)"; : > "$T/state.db"
  out=$(bash -c 'set -euo pipefail; k=$( (sqlite3 "$1" "SELECT id FROM gaps;" 2>/dev/null | tr "\n" "|") || true); echo REACHED' _ "$T/state.db" 2>&1)
  [[ "$out" == *REACHED* ]] && p "empty state.db lookup does not abort" || f "empty state.db aborted: $out"
  rm -rf "$T"
fi
echo "pass=$P fail=$F"; [[ $F -eq 0 ]]
