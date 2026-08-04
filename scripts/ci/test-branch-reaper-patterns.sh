#!/usr/bin/env bash
# test-branch-reaper-patterns.sh — ZERO-WASTE-037
#
# Guards the fix to scripts/ops/stale-branch-reaper.sh's default BRANCH_PATTERNS.
# The wired daily reaper went blind because its default (claude/* worktree-*) was
# frozen at the old branch naming; the fleet now pushes chump/* and wip/* (644 of
# 674 accumulated refs), so the reaper matched only ~5 branches and reaped 0.
#
# DEPTH: regression-guard + glob-semantics unit.
#   - Covered: the live default is extracted from the script (not hardcoded here),
#     asserted to cover the fleet's dominant namespaces, and proven via real shell
#     glob-matching to SEE sample chump/* + wip/* names that the OLD default missed.
#   - GAP (not covered): does not exercise the reaper end-to-end (that shells git +
#     gh + the cache and mutates the remote), and does NOT cover the remaining
#     ZERO-WASTE-037 defects — the closed-PR `--limit 500` lookup that misses old
#     branches, the 457 PR-less wip/* that need a non-PR safety model, and the
#     /tmp disk-pressure early-exit. Those stay open on the gap.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../ops/stale-branch-reaper.sh"
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; else echo "  FAIL: $1 — expected [$2] got [$3]"; fail=1; fi; }

# Extract the default BRANCH_PATTERNS value the script falls back to (the ${VAR:-...} body).
DEFAULT_PATTERNS=$(grep -E '^BRANCH_PATTERNS=' "$SCRIPT" | sed -E 's/^BRANCH_PATTERNS="\$\{BRANCH_PATTERNS:-(.*)\}"$/\1/')
OLD_DEFAULT="claude/* worktree-*"

echo "test-branch-reaper-patterns (ZERO-WASTE-037):"
echo "  extracted default: $DEFAULT_PATTERNS"

# 1. The default must actually differ from the stale one that caused the blindness.
if [[ "$DEFAULT_PATTERNS" == "$OLD_DEFAULT" ]]; then
    echo "  FAIL: default is still the stale '$OLD_DEFAULT' — reaper stays blind"; fail=1
else
    echo "  ok: default is no longer the stale claude/* worktree-*"
fi

# matches() — does ref-name $1 match ANY glob in pattern-list $2 (real shell globbing)?
matches() { local name="$1" pat; for pat in $2; do case "$name" in $pat) return 0;; esac; done; return 1; }

# 2. The live default SEES the fleet's dominant namespaces (the 644 it was missing).
for name in chump/credible-191-claim wip/some-abandoned-work chore/file-x claude/legacy; do
    if matches "$name" "$DEFAULT_PATTERNS"; then echo "  ok: default matches $name"; else echo "  FAIL: default misses $name"; fail=1; fi
done

# 3. Proof of the bug: the OLD default was blind to exactly those chump/* + wip/* refs.
check "old default blind to chump/*" "no" "$(matches 'chump/x-claim' "$OLD_DEFAULT" && echo yes || echo no)"
check "old default blind to wip/*"   "no" "$(matches 'wip/y'        "$OLD_DEFAULT" && echo yes || echo no)"

# 4. Sanity: the protected trunk is not a work-namespace match (it is also guarded
#    separately by the reaper's protected-branch list; this just confirms no over-match).
check "default does not match bare main" "no" "$(matches 'main' "$DEFAULT_PATTERNS" && echo yes || echo no)"

if [[ $fail -eq 0 ]]; then echo "PASS"; else echo "FAILED"; exit 1; fi
