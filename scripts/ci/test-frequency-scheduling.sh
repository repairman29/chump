#!/usr/bin/env bash
# test-frequency-scheduling.sh — INFRA-841
#
# Validates the frequency-aware scheduling config and helpers:
#   1. scripts/coord/system-gap-frequencies.yaml exists and lists known tasks.
#   2. No two short-cycle tasks (<= 600s) share an interval_s.
#   3. system-gap-tick.sh emits a well-formed kind=system_gap_tick event.
#   4. opus-curator.sh and emergency-fast-path.sh both source the tick helper.

set -euo pipefail

# Resolve repo root from this script's location to avoid INFRA-779
# (git rev-parse --show-toplevel returns wrong path in linked worktrees on macOS).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

YAML="scripts/coord/system-gap-frequencies.yaml"
TICK="scripts/coord/system-gap-tick.sh"
CURATOR="scripts/coord/opus-curator.sh"
EMERGENCY="scripts/coord/emergency-fast-path.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

# 1) Config + helper exist
[[ -f "$YAML" ]] || fail "missing $YAML"
[[ -r "$TICK" ]] || fail "missing $TICK"
ok "config + helper present"

# 2) YAML lists the two known tasks
grep -q '^  opus-curator:'        "$YAML" || fail "opus-curator missing from $YAML"
grep -q '^  emergency-fast-path:' "$YAML" || fail "emergency-fast-path missing from $YAML"
ok "known tasks declared"

# 3) Short-cycle tasks (<= 600s) have distinct intervals (skew enforcement).
# Portable parse (no gawk-only match-with-array).
short_intervals=$(grep -E '^[[:space:]]+interval_s:[[:space:]]+[0-9]+' "$YAML" \
  | sed -E 's/.*interval_s:[[:space:]]+([0-9]+).*/\1/' \
  | awk '$1 <= 600 { print $1 }')
dup_count=$(echo "$short_intervals" | sort | uniq -d | grep -c . || true)
if [[ "$dup_count" -ne 0 ]]; then
  fail "short-cycle tasks (<=600s) share interval_s — would collide on the minute mark"
fi
ok "short-cycle skew enforced (no duplicate intervals among <=600s tasks)"

# 4) opus-curator.sh and emergency-fast-path.sh source the tick helper
grep -q 'system-gap-tick.sh' "$CURATOR"   || fail "$CURATOR does not source system-gap-tick.sh"
grep -q 'system-gap-tick.sh' "$EMERGENCY" || fail "$EMERGENCY does not source system-gap-tick.sh"
ok "scheduled scripts source the tick helper"

# 5) tick helper emits a well-formed event for a known task
TMP_AMB="$(mktemp)"
trap 'rm -f "$TMP_AMB"' EXIT
CHUMP_AMBIENT_LOG="$TMP_AMB" CHUMP_FREQ_YAML="$YAML" \
  bash "$TICK" emit opus-curator >/dev/null 2>&1 || fail "tick helper failed for opus-curator"
[[ -s "$TMP_AMB" ]] || fail "tick helper produced no output"
grep -q '"kind":"system_gap_tick"'        "$TMP_AMB" || fail "missing kind=system_gap_tick"
grep -q '"task":"opus-curator"'           "$TMP_AMB" || fail "missing task field"
grep -q '"interval_s":600'                "$TMP_AMB" || fail "interval_s not resolved from yaml (expected 600)"
grep -q '"run_id":'                       "$TMP_AMB" || fail "missing run_id"
ok "tick event well-formed (kind, task, interval_s, run_id)"

# 6) Unknown task emits without interval_s but does not error
: > "$TMP_AMB"
CHUMP_AMBIENT_LOG="$TMP_AMB" CHUMP_FREQ_YAML="$YAML" \
  bash "$TICK" emit unknown-task >/dev/null 2>&1 || fail "tick helper failed for unknown task"
grep -q '"task":"unknown-task"' "$TMP_AMB" || fail "unknown-task tick missing"
ok "unknown task tolerated (degraded gracefully)"

# 7) CHUMP_TICK_DISABLE=1 suppresses emission
: > "$TMP_AMB"
CHUMP_AMBIENT_LOG="$TMP_AMB" CHUMP_FREQ_YAML="$YAML" CHUMP_TICK_DISABLE=1 \
  bash "$TICK" emit opus-curator >/dev/null 2>&1 || true
[[ ! -s "$TMP_AMB" ]] || fail "CHUMP_TICK_DISABLE did not suppress emission"
ok "CHUMP_TICK_DISABLE suppresses emission"

echo
echo "=== test-frequency-scheduling.sh PASSED ==="
