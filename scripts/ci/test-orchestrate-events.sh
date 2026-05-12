#!/usr/bin/env bash
# test-orchestrate-events.sh — INFRA-796
#
# Smoke-tests `chump orchestrate` ambient event emission in stub mode.
# Verifies kind=orchestrate_intent appears in ambient.jsonl after a stub
# session and that all required AC fields are present.
#
# Tests:
#  1. chump binary supports the orchestrate subcommand (--help exit 0)
#  2. stub session emits kind=orchestrate_intent to ambient.jsonl
#  3. event contains all required fields: intent, status, tool_count,
#     est_input_tokens, est_output_tokens, elapsed_ms, failure_class
#  4. status field is "success" or "failure" (not an arbitrary string)
#  5. tool_count is a non-negative integer
#  6. second intent also produces an event (loop, not single-shot)
#  7. EVENT_REGISTRY.yaml documents orchestrate_intent

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHUMP="${CHUMP_BIN:-chump}"

echo "=== INFRA-796 orchestrate event smoke test ==="
echo

# ── 1. chump binary supports orchestrate ─────────────────────────────────────
echo "[1. chump supports orchestrate subcommand]"
if "$CHUMP" orchestrate --help >/dev/null 2>&1 || \
   "$CHUMP" help 2>/dev/null | grep -q "orchestrate"; then
    ok "chump orchestrate subcommand available"
else
    # Accept: orchestrate is in the help listing even if --help exits non-zero
    if "$CHUMP" 2>&1 | grep -q "orchestrate"; then
        ok "chump orchestrate in help output"
    else
        fail "chump orchestrate not found in binary (check CHUMP_BIN)"
        exit 1
    fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AMB="$TMP/ambient.jsonl"

# ── 2. stub session emits orchestrate_intent ──────────────────────────────────
echo
echo "[2. stub session emits kind=orchestrate_intent]"
printf 'show me the fleet status\nexit\n' | \
    CHUMP_ORCHESTRATE_STUB=1 \
    CHUMP_AMBIENT_IN_PROMPT="$AMB" \
    "$CHUMP" orchestrate >/dev/null 2>&1 || true

if grep -q '"kind":"orchestrate_intent"' "$AMB" 2>/dev/null; then
    ok "kind=orchestrate_intent found in ambient.jsonl"
else
    fail "kind=orchestrate_intent not found in ambient.jsonl (content: $(cat "$AMB" 2>/dev/null || echo '(empty)'))"
fi

# ── 3. event contains all required fields ─────────────────────────────────────
echo
echo "[3. event has intent, status, tool_count, est_input_tokens, est_output_tokens, elapsed_ms, failure_class]"
if python3 -c "
import json, sys

events = []
try:
    with open('$AMB') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                if ev.get('kind') == 'orchestrate_intent':
                    events.append(ev)
            except Exception:
                pass
except FileNotFoundError:
    sys.exit(1)

assert len(events) > 0, f'no orchestrate_intent events found'
e = events[0]
required = ['intent', 'status', 'tool_count', 'est_input_tokens', 'est_output_tokens', 'elapsed_ms', 'failure_class']
for field in required:
    assert field in e, f'missing field: {field} (event: {e})'
print(f'  fields ok: {list(e.keys())}')
" 2>/dev/null; then
    ok "all required fields present in orchestrate_intent event"
else
    fail "missing required fields (ambient: $(cat "$AMB" 2>/dev/null | head -3))"
fi

# ── 4. status is "success" or "failure" ───────────────────────────────────────
echo
echo "[4. status field is 'success' or 'failure']"
if python3 -c "
import json
with open('$AMB') as f:
    events = [json.loads(l) for l in f if l.strip() and 'orchestrate_intent' in l]
assert events, 'no events'
e = events[0]
assert e.get('status') in ('success', 'failure'), f'unexpected status: {e.get(\"status\")}'
" 2>/dev/null; then
    ok "status is 'success' or 'failure'"
else
    fail "status field unexpected (ambient: $(grep orchestrate_intent "$AMB" 2>/dev/null | head -1))"
fi

# ── 5. tool_count is a non-negative integer ───────────────────────────────────
echo
echo "[5. tool_count is a non-negative integer]"
if python3 -c "
import json
with open('$AMB') as f:
    events = [json.loads(l) for l in f if l.strip() and 'orchestrate_intent' in l]
assert events, 'no events'
e = events[0]
tc_raw = e.get('tool_count', '')
tc = int(tc_raw)
assert tc >= 0, f'tool_count negative: {tc}'
" 2>/dev/null; then
    ok "tool_count is a non-negative integer"
else
    fail "tool_count not a valid integer (event: $(grep orchestrate_intent "$AMB" 2>/dev/null | head -1))"
fi

# ── 6. second intent also produces an event (loop emits per iteration) ────────
echo
echo "[6. loop emits one event per intent iteration]"
AMB2="$TMP/ambient2.jsonl"
printf 'list open gaps\nshow mission grade\nexit\n' | \
    CHUMP_ORCHESTRATE_STUB=1 \
    CHUMP_AMBIENT_IN_PROMPT="$AMB2" \
    "$CHUMP" orchestrate >/dev/null 2>&1 || true

EVENT_COUNT=$(grep -c '"kind":"orchestrate_intent"' "$AMB2" 2>/dev/null || echo 0)
if [[ "$EVENT_COUNT" -ge 2 ]]; then
    ok "loop emits one event per intent ($EVENT_COUNT events for 2 intents)"
else
    fail "expected >=2 orchestrate_intent events, got $EVENT_COUNT"
fi

# ── 7. EVENT_REGISTRY documents orchestrate_intent ────────────────────────────
echo
echo "[7. EVENT_REGISTRY.yaml documents orchestrate_intent]"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if [[ -f "$REGISTRY" ]] && grep -q "orchestrate_intent" "$REGISTRY"; then
    ok "orchestrate_intent registered in EVENT_REGISTRY.yaml"
else
    fail "orchestrate_intent not found in EVENT_REGISTRY.yaml"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
