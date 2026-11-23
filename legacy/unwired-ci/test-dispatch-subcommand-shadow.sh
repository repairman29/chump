#!/usr/bin/env bash
# INFRA-392 regression test — `chump dispatch <subcommand>` must NOT be
# treated as `chump dispatch <gap-id>`. Before the fix, args[2]="route"
# (etc.) hit the gap-id branch and went through gap-preflight + bot-merge,
# claiming a phantom gap named "route" / "scoreboard" / "simulate".
#
# We don't try to actually run the subcommands here (route reads state.db,
# scoreboard queries reflections, simulate samples) — we just check that
# the binary's argument parser does NOT exit 2 with the dispatch usage
# line, which is what the gap-id branch prints when its preconditions fail.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
[ -x "$BIN" ] || BIN="${HOME}/.cargo/bin/chump"
[ -x "$BIN" ] || { echo "no chump binary found (built or installed)"; exit 0; }

# The dispatch-as-gap-id usage line — if any of these subcommands prints
# this, the shadow regression has returned.
DISPATCH_USAGE='Usage: chump dispatch <GAP-ID>'

for sub in route scoreboard simulate; do
  out="$("$BIN" dispatch "$sub" 2>&1 || true)"
  if echo "$out" | grep -qF "$DISPATCH_USAGE"; then
    fail "chump dispatch $sub was shadowed by gap-id handler"
  else
    pass "chump dispatch $sub bypasses gap-id handler"
  fi
done

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
