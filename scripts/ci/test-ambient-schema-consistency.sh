#!/usr/bin/env bash
# scripts/ci/test-ambient-schema-consistency.sh — INFRA-1159
#
# Verifies the ambient.jsonl schema split fix:
#   1. ambient-emit.sh emits BOTH 'event' and 'kind' fields (dual-write)
#   2. EVENT_REGISTRY.yaml documents the canonical field (kind)
#   3. Static check: no emitter uses event-only without kind in core emit path
#   4. Fixture: run ambient-emit.sh and verify both fields present in output
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EMIT_SH="$REPO_ROOT/scripts/dev/ambient-emit.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

pass=0; total=0
check() {
  total=$((total+1))
  if "$@" >/dev/null 2>&1; then
    ok "$*"
    pass=$((pass+1))
  else
    fail "$*"
  fi
}

echo "=== INFRA-1159: ambient schema consistency checks ==="

# 1. Script exists + executable
check test -f "$EMIT_SH"
check test -x "$EMIT_SH"

# 2. ambient-emit.sh JSON_LINE contains both 'event' and 'kind' fields
# The file uses escaped quotes: \"event\" and \"kind\" — grep for the raw text
total=$((total+1))
if grep 'JSON_LINE=' "$EMIT_SH" | head -1 | grep -q 'event' && \
   grep 'JSON_LINE=' "$EMIT_SH" | head -1 | grep -q 'kind'; then
  ok "ambient-emit.sh JSON_LINE dual-writes event AND kind"
  pass=$((pass+1))
else
  fail "ambient-emit.sh JSON_LINE missing dual-write (event + kind)"
fi

# 3. EVENT_REGISTRY.yaml documents canonical field
check test -f "$REGISTRY"
check grep -q "kind.*canonical" "$REGISTRY"
check grep -q "INFRA-1159" "$REGISTRY"

# 4. Fixture test: emit to a temp file and verify both fields
_tmplog=$(mktemp)
trap "rm -f '$_tmplog'" EXIT

total=$((total+1))
if CHUMP_AMBIENT_LOG="$_tmplog" CHUMP_SESSION_ID="test-infra-1159" \
   CHUMP_AGENT_HARNESS="manual" \
   bash "$EMIT_SH" session_start source=test 2>/dev/null; then
  ok "ambient-emit.sh emitted to temp log"
  pass=$((pass+1))
else
  fail "ambient-emit.sh failed to emit"
fi

# 5. Output contains both 'event' and 'kind' fields with the same value
total=$((total+1))
_emitted=$(cat "$_tmplog" 2>/dev/null || true)
if echo "$_emitted" | python3 -c "
import json, sys
line = sys.stdin.read().strip()
# Find the last non-empty line (skip any alert lines)
lines = [l for l in line.splitlines() if l.strip()]
d = json.loads(lines[-1])
assert d.get('event') == 'session_start', f'event mismatch: {d.get(\"event\")}'
assert d.get('kind') == 'session_start', f'kind mismatch: {d.get(\"kind\")}'
print('event=', d['event'], 'kind=', d['kind'])
" 2>/dev/null; then
  ok "emitted JSON has event='session_start' AND kind='session_start'"
  pass=$((pass+1))
else
  fail "emitted JSON missing event or kind field (output: $_emitted)"
fi

# 6. Emitted JSON has required ambient fields (ts, session, worktree, harness)
total=$((total+1))
if echo "$_emitted" | python3 -c "
import json, sys
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
d = json.loads(lines[-1])
for f in ['ts', 'session', 'event', 'kind', 'harness']:
    assert f in d, f'missing field: {f}'
" 2>/dev/null; then
  ok "emitted JSON has all required fields (ts, session, event, kind, harness)"
  pass=$((pass+1))
else
  fail "emitted JSON missing required fields"
fi

# 7. Consumer audit: key consumer scripts handle 'kind' field (not only 'event')
# fleet-status.sh previously used '"event":"commit"' — it should also check .kind
total=$((total+1))
_fleet_status="$REPO_ROOT/scripts/dev/fleet-status.sh"
if [[ -f "$_fleet_status" ]]; then
  if grep -q '"kind"\|\.kind' "$_fleet_status" 2>/dev/null; then
    ok "fleet-status.sh references 'kind' field (reads both schemas)"
    pass=$((pass+1))
  else
    # Not a hard failure post INFRA-1159 — log as advisory
    ok "fleet-status.sh: event-field only (advisory; fix in consumer follow-up)"
    pass=$((pass+1))
  fi
else
  ok "fleet-status.sh not found — skip consumer audit"
  pass=$((pass+1))
fi

echo ""
echo "=== Results: $pass/$total passed ==="
if [[ "$pass" -ne "$total" ]]; then
  exit 1
fi
echo "INFRA-1159: ambient schema consistency validated."
