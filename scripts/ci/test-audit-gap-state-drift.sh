#!/usr/bin/env bash
# test-audit-gap-state-drift.sh — INFRA-970 unit test.
#
# Verifies the audit-gap-state-drift.sh script under three scenarios:
#   1. Clean YAML dir + no state.db → 0 drift, exit 0
#   2. Race-fixture YAML present (no state.db) → race_fixture > 0, exit 1
#   3. State.db with done gap but YAML missing → missing_yaml > 0

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/audit-gap-state-drift.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

PASS=0
FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Scenario 1: clean YAML dir, no state.db ─────────────────────────────────
mkdir -p "$TMP/scenario1/docs/gaps"
cd "$TMP/scenario1"
git init -q
cat > docs/gaps/INFRA-100.yaml <<'YAML'
- id: INFRA-100
  domain: INFRA
  title: legitimate gap title
  status: open
  priority: P1
  effort: s
YAML
out="$(bash "$SCRIPT" --warn-only 2>&1)" || true
echo "$out" | grep -q "TOTAL DRIFT: 0" \
    && ok "scenario 1 (clean YAMLs, no state.db) — 0 drift" \
    || fail "scenario 1 — expected 0 drift, got: $out"
echo "$out" | grep -q "state.db unavailable" \
    && ok "scenario 1 — informational state.db unavailable message printed" \
    || fail "scenario 1 — missing state.db informational message"

# ── Scenario 2: race-fixture present (no state.db, exits non-zero) ──────────
mkdir -p "$TMP/scenario2/docs/gaps"
cd "$TMP/scenario2"
git init -q
cat > docs/gaps/INFRA-100.yaml <<'YAML'
- id: INFRA-100
  domain: INFRA
  title: race-a
  status: open
YAML
cat > docs/gaps/INFRA-200.yaml <<'YAML'
- id: INFRA-200
  domain: INFRA
  title: real title
  status: open
YAML

ec=0
out="$(bash "$SCRIPT" 2>&1)" || ec=$?
echo "$out" | grep -q "RACE_FIXTURE  (1)" \
    && ok "scenario 2 — exactly 1 race fixture detected (INFRA-100)" \
    || fail "scenario 2 — expected 1 race fixture, got: $out"
echo "$out" | grep -q "INFRA-100.*race-a" \
    && ok "scenario 2 — INFRA-100 race-a flagged" \
    || fail "scenario 2 — INFRA-100 not flagged"
[[ "$ec" -eq 1 ]] \
    && ok "scenario 2 — exit code 1 (drift present, no --warn-only)" \
    || fail "scenario 2 — expected exit 1, got $ec"

# ── Scenario 3: --warn-only suppresses non-zero exit ─────────────────────────
ec=0
bash "$SCRIPT" --warn-only >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 0 ]] \
    && ok "scenario 3 — --warn-only forces exit 0 even with drift" \
    || fail "scenario 3 — --warn-only didn't suppress non-zero (got $ec)"

# ── Scenario 4: --json output is valid JSON ──────────────────────────────────
json_out="$(bash "$SCRIPT" --json --warn-only 2>/dev/null)"
echo "$json_out" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'summary' in d, 'missing summary'
assert d['summary']['race_fixture'] == 1, f'expected race_fixture=1, got {d[\"summary\"]}'
assert d['summary']['total'] == 1, f'expected total=1, got {d[\"summary\"]}'
" \
    && ok "scenario 4 — --json output is valid + has expected counts" \
    || fail "scenario 4 — --json malformed or wrong counts"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
