#!/usr/bin/env bash
# scripts/ci/test-gh-run-list-rest.sh — ZERO-WASTE-004
# The 3 migrated daemons must NOT call `gh run list` (GraphQL — top API burner);
# they must use `gh api .../actions/runs` (REST bucket — separate budget) so a
# GraphQL exhaustion can't neuter CI-run polling.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }
echo "=== test-gh-run-list-rest.sh (ZERO-WASTE-004) ==="
# runner-autoscale deferred: pre-existing shellcheck debt (SC2034/2155/1091) blocks
# the surgical migration; not absorbing it here (tracked in ZERO-WASTE-004 notes).
for d in scripts/coord/blame-bot.sh scripts/coord/gap-gardener.py; do
  # Match actual INVOCATIONS only (line starts with gh/chump_gh run list, or the
  # python "gh","run","list" list literal) — not comments (#...) or log strings.
  if grep -qE '^[[:space:]]*(gh|chump_gh)[[:space:]]+run[[:space:]]+list|"gh",[[:space:]]*"run",[[:space:]]*"list"' "$d" 2>/dev/null; then
    f "$d still INVOKES gh run list (GraphQL burner)"
  else
    p "$d no longer calls gh run list"
  fi
  if grep -qE 'actions/runs|actions/workflows/.*runs' "$d" 2>/dev/null; then
    p "$d uses gh api .../actions/runs (REST)"
  else
    f "$d has no REST actions/runs call"
  fi
done
bash -n scripts/coord/blame-bot.sh 2>/dev/null && p "blame-bot.sh parses" || f "blame-bot.sh syntax"
bash -n scripts/coord/chump-runner-autoscale.sh 2>/dev/null && p "runner-autoscale.sh parses" || f "runner-autoscale.sh syntax"
python3 -m py_compile scripts/coord/gap-gardener.py 2>/dev/null && p "gap-gardener.py compiles" || f "gap-gardener.py syntax"
echo ""; echo "=== $P passed, $F failed ==="; [ "$F" -eq 0 ] || exit 1
