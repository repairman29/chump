#!/usr/bin/env bash
# scripts/ci/test-chump-commit-completes.sh — RESILIENT-065
#
# Regression guard: scripts/coord/chump-commit.sh must COMPLETE the commit (reach
# `git commit`) on the common path — staging a code file (.rs/.sh/.py) that adds
# no new CHUMP_* env var. The bug: under `set -euo pipefail`, the INFRA-1853
# env-var scan `_new_envvars=$(... | grep -oE CHUMP_... | ...)` exits 1 on
# grep-no-match (the common case), and the bare assignment trips set -e, silently
# aborting BEFORE `git commit` — files staged, HEAD unchanged, zero error output.
#
# This test proves (a) the failure mechanism is real, (b) the `|| true` guard
# fixes it, (c) the structural fixes are present, and (d) the EXIT trap turns any
# future pre-commit abort LOUD instead of silent.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
S=scripts/coord/chump-commit.sh
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

echo "=== test-chump-commit-completes.sh (RESILIENT-065) ==="

# ── 0. parses ────────────────────────────────────────────────────────────────
bash -n "$S" 2>/dev/null && p "chump-commit.sh parses (bash -n)" || f "SYNTAX ERROR"

# ── 1. MECHANISM: reproduce the bug, then prove the guard fixes it ────────────
# Without `|| true`: set -e + pipefail + grep-no-match must abort before REACHED.
if bash -c 'set -euo pipefail; x=$(echo "no env here" | grep -oE "\bCHUMP_[A-Z]+\b" | sort -u); echo REACHED' 2>/dev/null | grep -q REACHED; then
  f "mechanism unproven: bare assignment did NOT abort (set -e/pipefail not behaving as diagnosed)"
else
  p "bug mechanism reproduced: unguarded var=\$(...|grep no-match) aborts under set -e"
fi
# With `|| true` (the fix): must reach REACHED.
if bash -c 'set -euo pipefail; x=$(echo "no env here" | grep -oE "\bCHUMP_[A-Z]+\b" | sort -u) || true; echo REACHED' 2>/dev/null | grep -q REACHED; then
  p "fix proven: '\'') || true'\'' guard lets execution continue past the no-match assignment"
else
  f "fix INEFFECTIVE: guarded assignment still aborted"
fi

# ── 2. STRUCTURAL: the four fixes are present in the real script ──────────────
grep -qE "timeout .*cargo fmt --all" "$S" \
  && p "cargo fmt --all is timeout-bounded (no indefinite lock-contention hang)" || f "cargo fmt not timeout-bounded"
grep -qE '\) \|\| true' "$S" \
  && p "INFRA-1853 _new_envvars assignment is no-match-guarded (|| true)" || f "env-var assignment not guarded"
{ grep -q "trap _chump_commit_exit_trap EXIT" "$S" && grep -q "_chump_commit_exit_trap()" "$S"; } \
  && p "EXIT trap present (pre-commit abort becomes loud, not silent)" || f "no EXIT trap"
grep -q "_commit_started=1" "$S" \
  && p "commit-reached marker present (trap silenced on the success path)" || f "no _commit_started marker"

# ── 3. ORDERING: trap armed AFTER the intentional gate-refusals, BEFORE commit ─
trap_ln=$(grep -n "trap _chump_commit_exit_trap EXIT" "$S" | head -1 | cut -d: -f1)
commit_ln=$(grep -n '^git commit' "$S" | head -1 | cut -d: -f1)
last_refusal_ln=$(grep -nE '^\s*exit [12]\b' "$S" | tail -1 | cut -d: -f1)
if [ -n "$trap_ln" ] && [ -n "$commit_ln" ] && [ -n "$last_refusal_ln" ]; then
  if [ "$trap_ln" -gt "$last_refusal_ln" ] && [ "$trap_ln" -lt "$commit_ln" ]; then
    p "trap armed after gate-refusals ($last_refusal_ln) and before git commit ($commit_ln) — won't mis-fire on intentional refusals"
  else
    f "trap placement wrong (trap=$trap_ln refusal=$last_refusal_ln commit=$commit_ln)"
  fi
fi

# ── 4. TRAP BEHAVIOR: loud on pre-commit abort, silent once commit is reached ─
TRAP='trap '"'"'_rc=$?; if [[ "${_commit_started:-0}" != "1" && "$_rc" -ne 0 ]]; then echo "ABORTED-BEFORE-COMMIT" >&2; fi'"'"' EXIT'
# (a) aborts before commit → loud
out=$(bash -c "set -euo pipefail; _commit_started=0; $TRAP; false; _commit_started=1" 2>&1 || true)
echo "$out" | grep -q "ABORTED-BEFORE-COMMIT" \
  && p "trap fires LOUD when script aborts before commit" || f "trap silent on pre-commit abort"
# (b) reaches commit marker → silent
out=$(bash -c "set -euo pipefail; _commit_started=0; $TRAP; _commit_started=1; true" 2>&1 || true)
echo "$out" | grep -q "ABORTED-BEFORE-COMMIT" \
  && f "trap mis-fired on the success path" || p "trap stays silent once commit marker is set"

echo ""
echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
