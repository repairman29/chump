#!/usr/bin/env bash
# scripts/ci/test-outcome-verify-heal-cold-start.sh — organ oneshot wedge fix (2026-10-10)
#
# outcome-verify-heal-consumer.sh with NO cursor (first run / state wiped) used
# to scan the whole ambient log and spawn 2 python3 processes per line. On
# cuphead a ~10 MB log took ~1 line/sec: the oneshot ran 20+ min (24 min CPU),
# was killed before it ever wrote the cursor, and restarted from line 1 every
# time. It must pre-filter, so a cold start over a big irrelevant log stays
# bounded, and a rotated (shorter) log must reset the cursor, not skip events.
#
# Depth: happy-path + one edge (rotation) + a perf bound. Independent of the
# paging assertions in test-outcome-verify-heal-consumer.sh (gap-set stubbed;
# paging is not exercised here).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONSUMER="$REPO_ROOT/scripts/coord/outcome-verify-heal-consumer.sh"
fail() { echo "  FAIL $*" >&2; exit 1; }
pass() { echo "  ok   $*"; }
echo "=== test-outcome-verify-heal-cold-start.sh ==="

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
AMB="$TMP/ambient.jsonl"; STATE="$TMP/state"; CALLS="$TMP/gap-calls.log"; BIN="$TMP/fake-chump"
printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nexit 0\n' "$CALLS" > "$BIN"; chmod +x "$BIN"

# 1. cold start, 30k irrelevant lines + 1 real event at the end
awk 'BEGIN{for(i=0;i<30000;i++) printf "{\"ts\":\"2026-10-10T00:00:00Z\",\"kind\":\"pr_lander_beat\",\"n\":%d}\n", i}' > "$AMB"
echo '{"ts":"2026-10-10T00:00:01Z","kind":"outcome_probe_failed","gap":"INFRA-8888","note":"big log"}' >> "$AMB"
t0=$(date +%s)
REPO_ROOT="$REPO_ROOT" CHUMP_OUTCOME_VERIFY_STATE_DIR="$STATE" CHUMP_OUTCOME_VERIFY_GAP_BIN="$BIN" \
  timeout 120 bash "$CONSUMER" --ambient-log "$AMB" > "$TMP/out1.log" 2>&1 \
  || fail "cold start over a 30k-line log failed or exceeded 120s: $(tail -3 "$TMP/out1.log")"
elapsed=$(( $(date +%s) - t0 ))
(( elapsed < 60 )) || fail "cold start over 30k lines took ${elapsed}s (expected < 60s)"
grep -q '^gap set INFRA-8888 ' "$CALLS" || fail "event at the end of a big log was missed"
pass "cold start over 30k lines finished in ${elapsed}s and still held the real event"

# 2. rotation: new log is far shorter than the saved cursor
printf '%s\n' '{"ts":"2026-10-10T01:00:00Z","kind":"outcome_probe_failed","gap":"INFRA-7777","note":"after rotation"}' > "$AMB"
REPO_ROOT="$REPO_ROOT" CHUMP_OUTCOME_VERIFY_STATE_DIR="$STATE" CHUMP_OUTCOME_VERIFY_GAP_BIN="$BIN" \
  bash "$CONSUMER" --ambient-log "$AMB" > "$TMP/out2.log" 2>&1 || fail "post-rotation run failed"
grep -q '^gap set INFRA-7777 ' "$CALLS" || fail "event in a rotated (shorter) log skipped: cursor stayed beyond EOF"
pass "rotated log (cursor > line count) resets the cursor instead of skipping events"
echo "=== all heal-consumer cold-start tests passed ==="
