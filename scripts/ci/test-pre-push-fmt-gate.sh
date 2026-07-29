#!/usr/bin/env bash
# test-pre-push-fmt-gate.sh — INFRA-3512 / COTG-2.6
#
# Validates the cargo fmt gate (Guard 0b-fmt) in scripts/git-hooks/pre-push:
#  1. The Guard 0b-fmt block is present in pre-push.
#  2. The CHUMP_FMT_GATE bypass variable is wired.
#  3. The gate AUTO-APPLIES the fix (not just --check) so drift is repaired.
#  4. Mechanism: `cargo fmt --all -- --check` detects a drift and `cargo fmt --all`
#     fixes it (the gate's detect + remedy), when cargo is available.
#
# Why this gate exists: the pre-COMMIT hook auto-fmts, but --no-verify commits bypass
# it, so fmt drift still reached CI and blocked a 5-deep stack (2026-07-29). fmt is
# deterministic + auto-fixable; it must never reach CI.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"
PASS=0; FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-3512 cargo fmt gate test ==="
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing"; exit 1; }

grep -q "Guard 0b-fmt" "$HOOK" \
  && ok "Guard 0b-fmt block present in pre-push" \
  || fail "Guard 0b-fmt block missing from pre-push"

grep -q "CHUMP_FMT_GATE" "$HOOK" \
  && ok "CHUMP_FMT_GATE bypass variable wired" \
  || fail "CHUMP_FMT_GATE bypass variable missing"

grep -qE "cargo fmt --all -- --check" "$HOOK" \
  && ok "gate runs 'cargo fmt --all -- --check'" \
  || fail "gate does not run the fmt check"

# It must AUTO-APPLY (a bare --check that only blocks would recreate the manual toil).
grep -qE "cargo fmt --all >" "$HOOK" \
  && ok "gate auto-applies the fix (not check-only)" \
  || fail "gate does not auto-apply the fix"

# 4. Mechanism (only when cargo is available).
if command -v cargo >/dev/null 2>&1; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/probe.rs" <<'RS'
fn main(){let x=1;let y=2;let _=x+y;}
RS
  if ! rustfmt --check "$TMP/probe.rs" >/dev/null 2>&1; then
    ok "rustfmt detects a drifted file (gate would block)"
  else
    fail "rustfmt did not detect the drift"
  fi
  rustfmt "$TMP/probe.rs" >/dev/null 2>&1
  if rustfmt --check "$TMP/probe.rs" >/dev/null 2>&1; then
    ok "rustfmt auto-apply repairs the drift (gate's remedy)"
  else
    fail "rustfmt auto-apply did not repair the drift"
  fi
else
  echo "  SKIP: cargo/rustfmt not available — structural checks only"
fi

echo "=== fmt-gate: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
