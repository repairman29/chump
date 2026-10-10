#!/usr/bin/env bash
# test-auto-adopt.sh — unit + integration coverage for MISSION-125
# scripts/ops/auto-adopt.sh (auto-discovery & auto-adopt module, MISSION-105
# slice).
#
# DEPTH: unit (pure JSON-field extraction helpers) + stubbed integration
# (full process_events() run against a synthetic ambient.jsonl, with a fake
# "fetcher" binary so no real network/package-manager call happens).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHUMP_AUTOADOPT_LIB_ONLY=1 source "$HERE/ops/auto-adopt.sh"

fail=0
check() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf 'ok   — %s (=%s)\n' "$desc" "$got"
  else
    printf 'FAIL — %s: got [%s] want [%s]\n' "$desc" "$got" "$want"; fail=1
  fi
}

echo "=== MISSION-125: extract_field / extract_tools pure-function coverage ==="
LINE1='{"ts":"2026-10-10T00:00:00Z","kind":"discover","capability":"foo-linter","required_tools":["foo-lint","foo-fmt"]}'
check "extract_field kind"       "$(extract_field "$LINE1" kind)"       "discover"
check "extract_field capability" "$(extract_field "$LINE1" capability)" "foo-linter"
check "extract_tools"            "$(extract_tools "$LINE1" | xargs)"    "foo-lint foo-fmt"

LINE2='{"ts":"2026-10-10T00:00:01Z","kind":"discover","capability":"bar-checker","required_tools":[]}'
check "extract_tools empty array" "$(extract_tools "$LINE2" | xargs)" ""

LINE3='{"ts":"2026-10-10T00:00:02Z","kind":"other_event","capability":"should-not-adopt"}'
check "extract_field kind (non-discover)" "$(extract_field "$LINE3" kind)" "other_event"

if [ "$fail" -ne 0 ]; then echo "auto-adopt pure functions: FAILURES"; exit 1; fi
echo "auto-adopt pure functions: all cases pass"

echo ""
echo "=== MISSION-125: process_events() integration (AC1-4) ==="
INT_TMP="$(mktemp -d)"
trap 'rm -rf "$INT_TMP"' EXIT

export CHUMP_STATE_DIR="$INT_TMP/state"
export CHUMP_AMBIENT_LOG="$INT_TMP/ambient.jsonl"
export CHUMP_AUTOADOPT_REGISTRY="$INT_TMP/state/auto-adopt-capabilities.jsonl"
export CHUMP_AUTOADOPT_CURSOR="$INT_TMP/state/auto-adopt-cursor"

FAKE_BIN="$INT_TMP/bin"; mkdir -p "$FAKE_BIN"
FETCH_LOG="$INT_TMP/fetch.log"; : > "$FETCH_LOG"
cat > "$FAKE_BIN/fake-fetcher" <<EOS
#!/usr/bin/env bash
echo "\$1" >> "$FETCH_LOG"
exit 0
EOS
chmod +x "$FAKE_BIN/fake-fetcher"
export CHUMP_AUTOADOPT_FETCHER="$FAKE_BIN/fake-fetcher"
export PATH="$FAKE_BIN:$PATH"

mkdir -p "$(dirname "$CHUMP_AMBIENT_LOG")"
cat > "$CHUMP_AMBIENT_LOG" <<'EOS'
{"ts":"2026-10-10T00:00:00Z","kind":"discover","capability":"frobnicator","required_tools":["frobnicate-cli"]}
{"ts":"2026-10-10T00:00:01Z","kind":"queue_config_drift","unrelated":"true"}
EOS

LOG_OUT="$(CHUMP_AUTOADOPT_LIB_ONLY= bash "$HERE/ops/auto-adopt.sh" 2>&1)"

if echo "$LOG_OUT" | grep -q "auto-consume adopted frobnicator"; then
  echo "ok   — AC4: log line emitted"
else
  echo "FAIL — AC4: expected 'auto-consume adopted frobnicator' in output, got: $LOG_OUT"; fail=1
fi

if grep -q "frobnicate-cli" "$FETCH_LOG"; then
  echo "ok   — AC2: missing tool fetched via fetcher"
else
  echo "FAIL — AC2: frobnicate-cli was not fetched"; fail=1
fi

if grep -q '"capability":"frobnicator"' "$CHUMP_AUTOADOPT_REGISTRY" 2>/dev/null; then
  echo "ok   — AC3: capability recorded in node runtime registry"
else
  echo "FAIL — AC3: frobnicator missing from $CHUMP_AUTOADOPT_REGISTRY"; fail=1
fi

if grep -q '"kind":"capability_auto_adopted"' "$CHUMP_AMBIENT_LOG" && grep -q '"capability":"frobnicator"' "$CHUMP_AMBIENT_LOG"; then
  echo "ok   — AC4: ambient capability_auto_adopted event emitted"
else
  echo "FAIL — AC4: no capability_auto_adopted ambient event for frobnicator"; fail=1
fi

# Re-run: idempotency — same capability must not be re-adopted or re-fetched.
bash "$HERE/ops/auto-adopt.sh" >/dev/null 2>&1
FETCH_COUNT="$(grep -c "frobnicate-cli" "$FETCH_LOG" 2>/dev/null || echo 0)"
check "AC3: idempotent re-run does not re-fetch" "$FETCH_COUNT" "1"

# New discover event appended later must still be picked up (cursor advances,
# doesn't replay old events, but does see new ones).
cat >> "$CHUMP_AMBIENT_LOG" <<'EOS'
{"ts":"2026-10-10T00:00:02Z","kind":"discover","capability":"widgetizer","required_tools":[]}
EOS
LOG_OUT2="$(bash "$HERE/ops/auto-adopt.sh" 2>&1)"
if echo "$LOG_OUT2" | grep -q "auto-consume adopted widgetizer"; then
  echo "ok   — AC1: later discover event picked up on next tick (cursor advance)"
else
  echo "FAIL — AC1: widgetizer not adopted on second tick, got: $LOG_OUT2"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "auto-adopt integration: FAILURES"; exit 1; fi
echo "auto-adopt integration: all cases pass"
