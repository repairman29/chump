#!/usr/bin/env bash
# INFRA-2353 (META-269 sub-4): integration test for the queue-stagnation
# alarm (scripts/coord/queue-stagnation-monitor.sh).
#
# Validates the stagnation-detection logic with a synthetic state.db +
# synthetic ambient.jsonl:
#
#   Scenario A: 15 open gaps (> default threshold=10), 24h-idle queue
#       (no gap_claimed events in ambient.jsonl)
#       -> must emit kind=queue_stagnant AND forward to operator-recall.sh,
#          which must emit kind=operator_recall condition=QUEUE_STARVE.
#
#   Scenario B: 15 open gaps + a recent gap_claimed event
#       -> must NOT emit kind=queue_stagnant (healthy — queue is moving).
#
#   Scenario C: 5 open gaps (<= threshold), no gap_claimed events
#       -> must NOT emit kind=queue_stagnant (queue too small to alarm on).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MONITOR="$REPO_ROOT/scripts/coord/queue-stagnation-monitor.sh"
RECALL="$REPO_ROOT/scripts/dispatch/operator-recall.sh"

if [ ! -x "$MONITOR" ]; then
  echo "FAIL: monitor not executable: $MONITOR" >&2
  exit 1
fi
if [ ! -x "$RECALL" ]; then
  echo "FAIL: operator-recall.sh not executable: $RECALL" >&2
  exit 1
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "SKIP: sqlite3 not available" >&2
  exit 0
fi

TMPDIR=$(mktemp -d -t queue-stagnation-test-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

errors=0

make_state_db() {
  # $1=db_path $2=open_gap_count
  local db="$1" n="$2"
  sqlite3 "$db" "CREATE TABLE gaps (id TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'open');"
  local i=1
  while [ "$i" -le "$n" ]; do
    sqlite3 "$db" "INSERT INTO gaps (id, status) VALUES ('INFRA-STUB-${i}', 'open');"
    i=$((i + 1))
  done
}

# ── Scenario A: large stagnant queue ────────────────────────────────────────
mkdir -p "$TMPDIR/A"
DB_A="$TMPDIR/A/state.db"
AMB_A="$TMPDIR/A/ambient.jsonl"
make_state_db "$DB_A" 15
cat > "$AMB_A" <<'EOF'
{"ts":"2024-01-01T00:00:00Z","kind":"gap_shipped","gap_id":"INFRA-1"}
EOF

OUT_A=$(CHUMP_QUEUE_STAGNATION_STATE_DB="$DB_A" \
  CHUMP_QUEUE_STAGNATION_AMBIENT_PATH="$AMB_A" \
  CHUMP_QUEUE_STAGNATION_WINDOW_SECS=86400 \
  CHUMP_QUEUE_STAGNATION_MIN_PICKABLE=10 \
  bash "$MONITOR" 2>&1) || true

if grep -q '"kind":"queue_stagnant"' "$AMB_A" \
  && grep -q '"pickable_count":15' "$AMB_A"; then
  echo "PASS scenario A: 15 pickable + 0 claims in 24h -> queue_stagnant emitted"
else
  echo "FAIL scenario A: expected queue_stagnant with pickable_count=15; got:" >&2
  cat "$AMB_A" >&2
  echo "stderr:" >&2
  echo "$OUT_A" >&2
  errors=$((errors + 1))
fi

if grep -q '"kind":"operator_recall"' "$AMB_A" \
  && grep -q '"condition":"QUEUE_STARVE"' "$AMB_A"; then
  echo "PASS scenario A: forwarded to operator-recall.sh -> operator_recall condition=QUEUE_STARVE"
else
  echo "FAIL scenario A: expected operator_recall condition=QUEUE_STARVE forward; got:" >&2
  cat "$AMB_A" >&2
  errors=$((errors + 1))
fi

# ── Scenario B: healthy (recent claim) ──────────────────────────────────────
mkdir -p "$TMPDIR/B"
DB_B="$TMPDIR/B/state.db"
AMB_B="$TMPDIR/B/ambient.jsonl"
make_state_db "$DB_B" 15
RECENT_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$AMB_B" <<EOF
{"ts":"$RECENT_TS","kind":"gap_claimed","gap_id":"INFRA-9999"}
EOF

OUT_B=$(CHUMP_QUEUE_STAGNATION_STATE_DB="$DB_B" \
  CHUMP_QUEUE_STAGNATION_AMBIENT_PATH="$AMB_B" \
  CHUMP_QUEUE_STAGNATION_WINDOW_SECS=86400 \
  CHUMP_QUEUE_STAGNATION_MIN_PICKABLE=10 \
  bash "$MONITOR" 2>&1) || true

if grep -q '"kind":"queue_stagnant"' "$AMB_B"; then
  echo "FAIL scenario B: recent gap_claimed present but queue_stagnant fired:" >&2
  cat "$AMB_B" >&2
  errors=$((errors + 1))
else
  echo "PASS scenario B: recent claim -> no false positive"
fi

# ── Scenario C: small queue, no claims ──────────────────────────────────────
mkdir -p "$TMPDIR/C"
DB_C="$TMPDIR/C/state.db"
AMB_C="$TMPDIR/C/ambient.jsonl"
make_state_db "$DB_C" 5
echo "{}" > "$AMB_C"

OUT_C=$(CHUMP_QUEUE_STAGNATION_STATE_DB="$DB_C" \
  CHUMP_QUEUE_STAGNATION_AMBIENT_PATH="$AMB_C" \
  CHUMP_QUEUE_STAGNATION_WINDOW_SECS=86400 \
  CHUMP_QUEUE_STAGNATION_MIN_PICKABLE=10 \
  bash "$MONITOR" 2>&1) || true

if grep -q '"kind":"queue_stagnant"' "$AMB_C"; then
  echo "FAIL scenario C: queue below threshold but queue_stagnant fired:" >&2
  cat "$AMB_C" >&2
  errors=$((errors + 1))
else
  echo "PASS scenario C: below-threshold queue -> no alarm"
fi

if [ "$errors" -gt 0 ]; then
  echo "test-queue-stagnation-monitor: $errors scenario(s) failed" >&2
  exit 1
fi

echo "test-queue-stagnation-monitor: PASS — all 3 scenarios validated"
