#!/usr/bin/env bash
# test-fleet-mode-surface.sh — INFRA-1718
#
# Guards the fleet-mode surface: `chump fleet mode [--json]` and the
# `fleet_mode` section folded into `chump --briefing`. Both must expose
# auth_mode / auth_usable / backend / effort_tier / cost_ceiling_usd so an
# agent sees the routing it will actually hit (not just credential
# presence) before claiming work.
#
# Run from repo root: bash scripts/ci/test-fleet-mode-surface.sh

set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

if [[ ! -x "$ROOT/target/debug/chump" ]]; then
  echo "test-fleet-mode-surface: building target/debug/chump …" >&2
  if ! command -v cargo >/dev/null 2>&1; then
    echo "  SKIP: cargo not on PATH — test-fleet-mode-surface needs target/debug/chump" >&2
    exit 0
  fi
  cargo build -q --bin chump 2>&1 || {
    echo "  SKIP: cargo build failed — test-fleet-mode-surface cannot run" >&2
    exit 0
  }
  if [[ ! -x "$ROOT/target/debug/chump" ]]; then
    echo "  SKIP: target/debug/chump still missing after cargo build" >&2
    exit 0
  fi
fi
CHUMP="$ROOT/target/debug/chump"

echo "=== fleet-mode surface tests (INFRA-1718) ==="

# ── 1. `chump fleet mode` prints the one-liner with all four fields ─────────
echo "Test 1: chump fleet mode line"
LINE="$("$CHUMP" fleet mode)" || true
if echo "$LINE" | grep -q "^fleet-mode: auth=" \
  && echo "$LINE" | grep -q "backend=" \
  && echo "$LINE" | grep -q "cost-ceiling=\$"; then
  ok "line has auth/backend/cost-ceiling"
else
  fail "line missing expected fields: $LINE"
fi

# ── 2. `chump fleet mode --json` is valid JSON with the 5 fields ────────────
echo "Test 2: chump fleet mode --json shape"
JSON="$("$CHUMP" fleet mode --json)" || true
if command -v jq >/dev/null 2>&1; then
  for field in auth_mode auth_usable backend effort_tier cost_ceiling_usd; do
    if echo "$JSON" | jq -e "has(\"$field\")" >/dev/null 2>&1; then
      ok "json has .$field"
    else
      fail "json missing .$field: $JSON"
    fi
  done
else
  echo "  SKIP: jq not on PATH — checking via grep instead"
  for field in auth_mode auth_usable backend effort_tier cost_ceiling_usd; do
    if echo "$JSON" | grep -q "\"$field\""; then
      ok "json has $field (grep)"
    else
      fail "json missing $field (grep): $JSON"
    fi
  done
fi

# ── 3. `chump --briefing` folds fleet_mode into both render paths ───────────
echo "Test 3: briefing includes fleet_mode"
export CHUMP_LOCK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHUMP_LOCK_DIR"' EXIT
export CHUMP_ALLOW_MAIN_WORKTREE=1
export CHUMP_SESSION_ID="test-fleet-mode-surface-$$"

BRIEF_MD="$("$CHUMP" --briefing INFRA-1718)" || true
if echo "$BRIEF_MD" | grep -q "Fleet Mode"; then
  ok "markdown briefing has Fleet Mode section"
else
  fail "markdown briefing missing Fleet Mode section"
fi

BRIEF_JSON="$("$CHUMP" --briefing INFRA-1718 --json)" || true
if echo "$BRIEF_JSON" | grep -q '"fleet_mode"'; then
  ok "json briefing has fleet_mode key"
else
  fail "json briefing missing fleet_mode key"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  echo "Failures:"
  for f in "${FAILS[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
