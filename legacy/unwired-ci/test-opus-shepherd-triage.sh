#!/usr/bin/env bash
# test-opus-shepherd-triage.sh — META-091 smoke test
#
# Asserts the triage script:
#   - exits 0
#   - emits kind=opus_shepherd_triage AND kind=opus_shepherd_plan to ambient
#   - --json mode produces valid JSON with the 5 required sections

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

SCRIPT="scripts/coord/opus-shepherd-triage.sh"
[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

# Run in a tempdir so we don't pollute the real ambient
TMP_AMBIENT=$(mktemp -d)/ambient.jsonl
touch "$TMP_AMBIENT"

# Test 1: --json mode returns valid JSON with required keys
JSON_OUT=$(CHUMP_AMBIENT_LOG="$TMP_AMBIENT" CHUMP_SESSION_ID="test-session" \
    bash "$SCRIPT" --no-broadcast --json 2>/dev/null | python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))" 2>/dev/null || echo "")
if [[ -z "$JSON_OUT" ]]; then
    echo "FAIL: --json mode did not produce parseable JSON"
    exit 1
fi
for key in ts session ghosts event_kinds_24h back_off_30m leases pickable_top plan; do
    if ! echo "$JSON_OUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if '$key' in d else 1)"; then
        echo "FAIL: --json missing key '$key'"
        exit 1
    fi
done
echo "  ok: --json produces all 7 required keys"

# Test 2: structured kind=opus_shepherd_triage emitted to ambient
if ! grep -q '"kind":"opus_shepherd_triage"' "$TMP_AMBIENT"; then
    echo "FAIL: kind=opus_shepherd_triage event not emitted"
    exit 1
fi
echo "  ok: kind=opus_shepherd_triage emitted"

# Test 3: kind=opus_shepherd_plan emitted (separate filterable channel)
if ! grep -q '"kind":"opus_shepherd_plan"' "$TMP_AMBIENT"; then
    echo "FAIL: kind=opus_shepherd_plan event not emitted"
    exit 1
fi
echo "  ok: kind=opus_shepherd_plan emitted"

# Test 4: bypass env var skips emit
TMP2=$(mktemp -d)/ambient.jsonl
touch "$TMP2"
CHUMP_AMBIENT_LOG="$TMP2" CHUMP_OPUS_SHEPHERD_TRIAGE=0 \
    bash "$SCRIPT" --no-broadcast >/dev/null 2>&1
if ! grep -q '"kind":"opus_shepherd_triage_skipped"' "$TMP2"; then
    echo "FAIL: bypass mode did not emit opus_shepherd_triage_skipped"
    exit 1
fi
echo "  ok: bypass emits opus_shepherd_triage_skipped"

echo "test-opus-shepherd-triage: PASS"
