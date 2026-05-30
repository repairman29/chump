#!/usr/bin/env bash
# scripts/ci/test-disk-critical-reactor.sh — INFRA-2304
#
# Smoke test for the disk_critical reactor wiring:
#   1. Synthesize a disk_critical event in a temp ambient.jsonl
#   2. Assert reactor's --once mode invokes the reaper with a tier-up flag
#   3. Assert idempotence inside the 60s debounce window
#   4. Assert operator-recall DISK_CRITICAL detection fires when free% < threshold

set -euo pipefail

REPO_ROOT="${CHUMP_REPO:-/Users/jeffadkins/Projects/Chump}"
REACTOR="$REPO_ROOT/scripts/coord/disk-critical-reactor.sh"
RECALL="$REPO_ROOT/scripts/dispatch/operator-recall.sh"

TMP_DIR="$(mktemp -d -t chump-test-reactor.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

TMP_AMBIENT="$TMP_DIR/ambient.jsonl"
TMP_LAST="$TMP_DIR/disk-critical-reactor.last"
TMP_REAPER="$TMP_DIR/fake-reaper.sh"
TMP_RECALL="$TMP_DIR/fake-recall.sh"
TMP_REAPER_LOG="$TMP_DIR/reaper-invocations.log"
TMP_RECALL_LOG="$TMP_DIR/recall-invocations.log"

pass() { printf '  ✓ %s\n' "$*"; }
fail() { printf '  ✗ %s\n' "$*" >&2; exit 1; }

cat > "$TMP_REAPER" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$TMP_REAPER_LOG"
exit 0
EOF
chmod +x "$TMP_REAPER"

cat > "$TMP_RECALL" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$TMP_RECALL_LOG"
exit 0
EOF
chmod +x "$TMP_RECALL"

# Run the reactor's --once mode against our temp ambient + temp reaper + temp recall.
# We point REPO_ROOT-derived paths at TMP_DIR by symlinking.
TMP_REPO="$TMP_DIR/repo"
mkdir -p "$TMP_REPO/.chump-locks" "$TMP_REPO/scripts/coord" "$TMP_REPO/scripts/dispatch"
cp "$TMP_AMBIENT" "$TMP_REPO/.chump-locks/ambient.jsonl" 2>/dev/null || touch "$TMP_REPO/.chump-locks/ambient.jsonl"
cp "$TMP_REAPER" "$TMP_REPO/scripts/coord/disk-pressure-reaper.sh"
cp "$TMP_RECALL" "$TMP_REPO/scripts/dispatch/operator-recall.sh"

echo "→ test 1: --once mode fires reaper on disk_critical line"
disk_critical_line='{"ts":"2026-05-30T17:00:00Z","kind":"disk_critical","reaper":"test","free_pct":3}'
CHUMP_REPO="$TMP_REPO" \
  CHUMP_AMBIENT_LOG="$TMP_REPO/.chump-locks/ambient.jsonl" \
  CHUMP_DISK_REACTOR_DEBOUNCE_SECS=0 \
  "$REACTOR" --once "$disk_critical_line" >/dev/null 2>&1 || true

if [[ -s "$TMP_REAPER_LOG" ]]; then
  if grep -q -- '--tier' "$TMP_REAPER_LOG"; then
    pass "reaper invoked with --tier flag (got: $(cat "$TMP_REAPER_LOG"))"
  else
    fail "reaper invoked but missing --tier flag (got: $(cat "$TMP_REAPER_LOG"))"
  fi
else
  fail "reaper was not invoked on disk_critical line"
fi

echo "→ test 2: --once mode no-ops on non-disk_critical line"
> "$TMP_REAPER_LOG"
benign_line='{"ts":"2026-05-30T17:00:00Z","kind":"sub_agent_dispatched"}'
CHUMP_REPO="$TMP_REPO" \
  CHUMP_AMBIENT_LOG="$TMP_REPO/.chump-locks/ambient.jsonl" \
  CHUMP_DISK_REACTOR_DEBOUNCE_SECS=0 \
  "$REACTOR" --once "$benign_line" >/dev/null 2>&1 || true

if [[ ! -s "$TMP_REAPER_LOG" ]]; then
  pass "reaper not invoked on non-disk_critical event"
else
  fail "reaper invoked on non-disk_critical event (got: $(cat "$TMP_REAPER_LOG"))"
fi

echo "→ test 3: debounce window suppresses re-fire"
> "$TMP_REAPER_LOG"
# Reset reactor's per-process debounce state (carryover from tests 1-2)
rm -f "$TMP_REPO/.chump-locks/disk-critical-reactor.last"
# First fire with 60s debounce
CHUMP_REPO="$TMP_REPO" \
  CHUMP_AMBIENT_LOG="$TMP_REPO/.chump-locks/ambient.jsonl" \
  CHUMP_DISK_REACTOR_DEBOUNCE_SECS=60 \
  "$REACTOR" --once "$disk_critical_line" >/dev/null 2>&1 || true
first_count=$(wc -l < "$TMP_REAPER_LOG" | tr -d ' ')
# Immediate re-fire — should be suppressed by debounce
CHUMP_REPO="$TMP_REPO" \
  CHUMP_AMBIENT_LOG="$TMP_REPO/.chump-locks/ambient.jsonl" \
  CHUMP_DISK_REACTOR_DEBOUNCE_SECS=60 \
  "$REACTOR" --once "$disk_critical_line" >/dev/null 2>&1 || true
second_count=$(wc -l < "$TMP_REAPER_LOG" | tr -d ' ')

if (( first_count == 1 && second_count == 1 )); then
  pass "debounce held (first=$first_count second=$second_count, debounce=60s)"
else
  fail "debounce did not hold (first=$first_count second=$second_count, debounce=60s)"
fi

echo "→ test 4: operator-recall DISK_CRITICAL halt-class detects recent disk_critical"
# Synthesize a recent disk_critical in temp ambient, run --check-only with low threshold
now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"disk_critical","reaper":"test","free_pct":3}\n' "$now_ts" \
  >> "$TMP_REPO/.chump-locks/ambient.jsonl"

# Force the halt-class to trip by setting the pct threshold above current free%.
# Read current free% and pass threshold = current+10 so the check fires regardless of host.
cur_pct=$(df -P /System/Volumes/Data 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print 100-$5}' || echo 50)
test_threshold=$((cur_pct + 10))

recall_out="$TMP_DIR/recall.out"
CHUMP_AMBIENT_LOG="$TMP_REPO/.chump-locks/ambient.jsonl" \
  CHUMP_DISK_CRITICAL_WINDOW_SECS=600 \
  CHUMP_DISK_CRITICAL_PCT="$test_threshold" \
  "$RECALL" --check-only >"$recall_out" 2>&1 || true

if grep -q "HALT condition=DISK_CRITICAL" "$recall_out"; then
  pass "operator-recall fired DISK_CRITICAL halt-class as expected"
else
  echo "  --- recall output: ---" >&2
  cat "$recall_out" >&2 || true
  echo "  --- ambient content: ---" >&2
  cat "$TMP_REPO/.chump-locks/ambient.jsonl" >&2 || true
  fail "operator-recall did NOT fire DISK_CRITICAL halt-class (threshold=$test_threshold% cur=$cur_pct%)"
fi

echo
echo "✓ all disk-critical-reactor tests passed"
