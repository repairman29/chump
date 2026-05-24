#!/usr/bin/env bash
# test-opus-digest-forecast.sh — META-092 smoke test
#
# Asserts the forecast script:
#   - exits 0
#   - --json mode produces JSON with required forecast fields
#   - default mode output starts with "STATUS TICK:" and contains "FORECAST:"
#   - includes at least 2 forecast lines

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

SCRIPT="scripts/coord/opus-digest-forecast.sh"
[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

# Test 1: default mode prefix + contents
OUT=$(CHUMP_SESSION_ID="test-session" bash "$SCRIPT" 2>/dev/null || echo "")
if [[ ! "$OUT" =~ ^STATUS\ TICK: ]]; then
    echo "FAIL: default mode output does not start with 'STATUS TICK:'"
    echo "      got: $OUT" | head -2
    exit 1
fi
echo "  ok: default mode starts with STATUS TICK:"

if [[ ! "$OUT" =~ FORECAST: ]]; then
    echo "FAIL: default mode missing FORECAST: marker"
    exit 1
fi
echo "  ok: default mode contains FORECAST:"

# Count forecast lines (each separated by ' | ')
LINE_COUNT=$(echo "$OUT" | tr '|' '\n' | wc -l | tr -d ' ')
if [[ "$LINE_COUNT" -lt 3 ]]; then
    echo "FAIL: fewer than 2 forecast lines (saw $((LINE_COUNT-1)))"
    exit 1
fi
echo "  ok: at least 2 forecast lines emitted (${LINE_COUNT} pipe-separated segments)"

# Test 2: --json mode has structured fields
JSON_OUT=$(CHUMP_SESSION_ID="test-session" bash "$SCRIPT" --json 2>/dev/null || echo "")
if ! echo "$JSON_OUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert 'forecast_lines' in d and len(d['forecast_lines']) >= 2; assert 'pickable_n' in d; assert 'fleet_rate_per_hr' in d; print('ok')" 2>/dev/null; then
    echo "FAIL: --json mode missing required fields (forecast_lines/pickable_n/fleet_rate_per_hr) or fewer than 2 lines"
    exit 1
fi
echo "  ok: --json has forecast_lines + pickable_n + fleet_rate_per_hr"

# Test 3: bypass returns descriptive-only
BYPASS_OUT=$(CHUMP_OPUS_DIGEST_FORECAST=0 bash "$SCRIPT" 2>/dev/null)
if [[ ! "$BYPASS_OUT" =~ descriptive-only ]]; then
    echo "FAIL: bypass mode did not return descriptive-only marker"
    exit 1
fi
echo "  ok: bypass mode returns descriptive-only"

echo "test-opus-digest-forecast: PASS"
