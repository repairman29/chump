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

# Test 5 (INFRA-2254): running twice in a row with identical inputs suppresses second broadcast
TMP_DEDUP_DIR=$(mktemp -d)
mkdir -p "$TMP_DEDUP_DIR/scripts/coord" "$TMP_DEDUP_DIR/.chump-locks"
git -C "$TMP_DEDUP_DIR" init -q
cp "$SCRIPT" "$TMP_DEDUP_DIR/scripts/coord/opus-shepherd-triage.sh"
chmod +x "$TMP_DEDUP_DIR/scripts/coord/opus-shepherd-triage.sh"
cat > "$TMP_DEDUP_DIR/scripts/coord/broadcast.sh" <<'EOF'
#!/usr/bin/env bash
echo "called" >> "$(dirname "$0")/../../broadcast-calls.log"
exit 0
EOF
chmod +x "$TMP_DEDUP_DIR/scripts/coord/broadcast.sh"

(cd "$TMP_DEDUP_DIR" && CHUMP_SESSION_ID="test-dedup" CHUMP_SHEPHERD_WARN_COOLDOWN_M=120 bash scripts/coord/opus-shepherd-triage.sh >/dev/null 2>&1)
(cd "$TMP_DEDUP_DIR" && CHUMP_SESSION_ID="test-dedup" CHUMP_SHEPHERD_WARN_COOLDOWN_M=120 bash scripts/coord/opus-shepherd-triage.sh >/dev/null 2>&1)

CALL_COUNT=$(wc -l < "$TMP_DEDUP_DIR/broadcast-calls.log" | tr -d '[:space:]')
if [[ "$CALL_COUNT" != "1" ]]; then
    echo "FAIL: expected broadcast.sh to be called once across 2 identical runs, got $CALL_COUNT"
    rm -rf "$TMP_DEDUP_DIR"
    exit 1
fi
if [[ ! -f "$TMP_DEDUP_DIR/.chump-locks/shepherd-triage-last-warn.sentinel" ]]; then
    echo "FAIL: .chump-locks/shepherd-triage-last-warn.sentinel not created"
    rm -rf "$TMP_DEDUP_DIR"
    exit 1
fi
if ! grep -q '"kind":"shepherd_warn_suppressed"' "$TMP_DEDUP_DIR/.chump-locks/ambient.jsonl"; then
    echo "FAIL: second run did not emit kind=shepherd_warn_suppressed"
    rm -rf "$TMP_DEDUP_DIR"
    exit 1
fi
rm -rf "$TMP_DEDUP_DIR"
echo "  ok: INFRA-2254 duplicate WARN suppressed within cooldown and emits shepherd_warn_suppressed"

echo "test-opus-shepherd-triage: PASS"
