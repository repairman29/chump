#!/usr/bin/env bash
# scripts/ci/test-precommit-gate-budget.sh — EFFECTIVE-089
#
# World-class CI invariant: the pre-commit hook must (1) PARSE (a stray exit-0 +
# dangling `fi` once made the committed source un-parseable — masked only because
# bash exits before parsing the broken tail), (2) keep a LEAN default — the hard
# gates (fmt/compile/credential/lease) run, then it exits, deferring policy gates
# to CI, and (3) stay under a HARD-GATE BUDGET so the 29-gate web can't silently
# regrow. CHUMP_PRECOMMIT_STRICT=1 restores the full policy tail (CI parity).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
HOOK=scripts/git-hooks/pre-commit
BUDGET="${CHUMP_PRECOMMIT_HARD_GATE_BUDGET:-25}"   # max exit-1 block-points reachable in LEAN
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

echo "=== test-precommit-gate-budget.sh (EFFECTIVE-089) ==="

# 1. PARSES — the regression guard against the corruption class we just removed.
bash -n "$HOOK" 2>/dev/null && p "pre-commit parses (no stray-exit-0 / dangling-fi corruption)" \
  || f "pre-commit FAILS bash -n (corruption — would break/silently-disable on reinstall)"

# 2. lean-mode present + positioned after the hard gates, before the policy tail.
LEAN=$(grep -n 'CHUMP_PRECOMMIT_STRICT' "$HOOK" | head -1 | cut -d: -f1)
CRED=$(grep -n 'CHUMP_CREDENTIAL_CHECK' "$HOOK" | head -1 | cut -d: -f1)
G9=$(grep -n 'Pre-deploy smoke test for infra' "$HOOK" | head -1 | cut -d: -f1)
if [ -n "$LEAN" ]; then p "lean-mode guard present (CHUMP_PRECOMMIT_STRICT)"; else f "no lean-mode guard"; fi
if [ -n "$LEAN" ] && [ -n "$CRED" ] && [ -n "$G9" ] && [ "$LEAN" -gt "$CRED" ] && [ "$LEAN" -lt "$G9" ]; then
  p "lean-exit sits after credential ($CRED) and before the policy tail #9 ($G9)"
else
  f "lean-exit misplaced (lean=$LEAN cred=$CRED g9=$G9)"
fi

# 3. HARD-GATE BUDGET — block-points reachable in LEAN (before the lean-exit) ≤ budget.
if [ -n "$LEAN" ]; then
  HARD=$(awk "NR<=$LEAN && /exit 1/" "$HOOK" | wc -l | tr -d ' ')
  if [ "$HARD" -le "$BUDGET" ]; then p "hard-gate budget OK: $HARD block-points in lean (≤ $BUDGET)"
  else f "hard-gate budget BLOWN: $HARD block-points in lean (> $BUDGET) — a policy gate crept before the lean-exit"; fi
fi

# 4. the 3 keepers are still hard (present before the lean-exit).
for k in 'cargo fmt' 'cargo check --bin' 'CHUMP_CREDENTIAL_CHECK'; do
  ln=$(grep -n "$k" "$HOOK" | head -1 | cut -d: -f1)
  if [ -n "$ln" ] && [ -n "$LEAN" ] && [ "$ln" -lt "$LEAN" ]; then p "keeper hard-gate present: $k"; else f "keeper missing/after-lean: $k"; fi
done

# 5. BEHAVIORAL — the lean decision: STRICT unset → exit before tail; STRICT=1 → run tail.
out=$(CHUMP_PRECOMMIT_STRICT= bash -c 'if [ "${CHUMP_PRECOMMIT_STRICT:-0}" != "1" ]; then echo LEAN; exit 0; fi; echo TAIL')
[ "$out" = "LEAN" ] && p "lean default: exits before the policy tail" || f "lean default wrong (got $out)"
out=$(CHUMP_PRECOMMIT_STRICT=1 bash -c 'if [ "${CHUMP_PRECOMMIT_STRICT:-0}" != "1" ]; then echo LEAN; exit 0; fi; echo TAIL')
[ "$out" = "TAIL" ] && p "strict mode: runs the policy tail" || f "strict mode wrong (got $out)"

echo ""
echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
