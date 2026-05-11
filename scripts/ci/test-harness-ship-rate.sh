#!/usr/bin/env bash
# test-harness-ship-rate.sh — CREDIBLE-037: verify harness attribution in
# ambient events and --by-harness flag in model-ship-rate.sh.
#
# Creates a synthetic ambient.jsonl with events tagged across 3 harness
# values, then asserts model-ship-rate.sh --by-harness groups them correctly.
#
# Usage:
#   scripts/ci/test-harness-ship-rate.sh

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); FAILS+=("$*"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIP_RATE="$REPO_ROOT/scripts/dispatch/model-ship-rate.sh"

tmpdir="$(mktemp -d /tmp/test-harness-ship-rate-XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

# Build a synthetic ambient.jsonl with ship_grade events across 3 harnesses.
AMBIENT="$tmpdir/ambient.jsonl"
TS_OLD="2026-05-01T00:00:00Z"
TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# OpenCode BigPickle: 2 events, 1 passed clippy, 1 added test
printf '{"ts":"%s","session":"s1","harness":"opencode-bigpickle","kind":"ship_grade","model":"sonnet","clippy_ok":true,"test_added":true}\n' "$TS_NOW" >> "$AMBIENT"
printf '{"ts":"%s","session":"s2","harness":"opencode-bigpickle","kind":"ship_grade","model":"haiku","clippy_ok":false,"test_added":true}\n' "$TS_NOW" >> "$AMBIENT"

# Fleet Dispatcher: 2 events, both passed clippy, none added tests
printf '{"ts":"%s","session":"s3","harness":"fleet-dispatcher","kind":"ship_grade","model":"sonnet","clippy_ok":true,"test_added":false}\n' "$TS_NOW" >> "$AMBIENT"
printf '{"ts":"%s","session":"s4","harness":"fleet-dispatcher","kind":"ship_grade","model":"opus","clippy_ok":true,"test_added":false}\n' "$TS_NOW" >> "$AMBIENT"

# Claude Code IDE: 1 event
printf '{"ts":"%s","session":"s5","harness":"claude-code-ide","kind":"ship_grade","model":"sonnet","clippy_ok":false,"test_added":false}\n' "$TS_NOW" >> "$AMBIENT"

# Old event outside window (should be ignored)
printf '{"ts":"%s","session":"s6","harness":"legacy","kind":"ship_grade","model":"sonnet","clippy_ok":true,"test_added":true}\n' "$TS_OLD" >> "$AMBIENT"

echo "=== CREDIBLE-037 harness attribution tests ==="
echo "REPO_ROOT=$REPO_ROOT"
echo

# ── Test 1: --by-harness groups correctly (text output) ───────────────────
echo "--- Test 1: --by-harness text output ---"
output=$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SHIP_RATE" --by-harness 2>&1 || true)

# Check all 3 harnesses appear.
for harness in opencode-bigpickle fleet-dispatcher claude-code-ide; do
    if echo "$output" | grep -q "$harness"; then
        ok "Test 1: harness '$harness' appears in --by-harness output"
    else
        fail "Test 1: harness '$harness' missing from --by-harness output"
    fi
done

# Check graded counts.
if echo "$output" | grep -q "opencode-bigpickle.*2"; then
    ok "Test 1: opencode-bigpickle shows graded=2"
else
    fail "Test 1: opencode-bigpickle graded count wrong"
fi
if echo "$output" | grep -q "fleet-dispatcher.*2"; then
    ok "Test 1: fleet-dispatcher shows graded=2"
else
    fail "Test 1: fleet-dispatcher graded count wrong"
fi
if echo "$output" | grep -q "claude-code-ide.*1"; then
    ok "Test 1: claude-code-ide shows graded=1"
else
    fail "Test 1: claude-code-ide graded count wrong"
fi

# ── Test 2: --by-harness --json output ────────────────────────────────────
echo "--- Test 2: --by-harness JSON output ---"
json_out=$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SHIP_RATE" --by-harness --json 2>&1 || true)

if echo "$json_out" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
harnesses = data.get('harnesses', [])
assert len(harnesses) == 3, f'expected 3 harnesses, got {len(harnesses)}'
by_name = {h['harness']: h for h in harnesses}
assert by_name['opencode-bigpickle']['graded'] == 2
assert by_name['fleet-dispatcher']['graded'] == 2
assert by_name['claude-code-ide']['graded'] == 1
print('JSON OK')
" 2>&1; then
    ok "Test 2: JSON output parses correctly with 3 harnesses"
else
    fail "Test 2: JSON output validation failed"
fi

# ── Test 3: --by-harness with legacy events ──────────────────────────────
echo "--- Test 3: --by-harness with legacy (no harness field) ---"
ts_recent="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","session":"s-legacy","kind":"ship_grade","model":"sonnet","clippy_ok":true,"test_added":true}\n' "$ts_recent" >> "$AMBIENT"

legacy_out=$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SHIP_RATE" --by-harness 2>&1 || true)
if echo "$legacy_out" | grep -q "unknown"; then
    ok "Test 3: legacy events (no harness) grouped under 'unknown'"
else
    fail "Test 3: legacy events should appear under 'unknown'"
fi

# ── Test 4: normal --by-model still works ─────────────────────────────────
echo "--- Test 4: --by-model (default) still works ---"
model_out=$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SHIP_RATE" 2>&1 || true)
if echo "$model_out" | grep -q "sonnet\|haiku\|opus"; then
    ok "Test 4: --by-model output shows models"
else
    fail "Test 4: --by-model output broken"
fi

echo
echo "=== results: $PASS pass, $FAIL fail ==="
if [[ $FAIL -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
