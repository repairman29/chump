#!/usr/bin/env bash
# scripts/ci/test-fleet-lane-recommend.sh — META-152 CI gate
#
# AC #8: exercises synthetic state (dark target, idle ci-audit, busy shepherd)
# and asserts target ranks highest.
#
# Usage: bash scripts/ci/test-fleet-lane-recommend.sh [--verbose]
# Exit 0 on pass, non-zero on any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

log() { [[ "$VERBOSE" -eq 1 ]] && echo "[test-fleet-lane-recommend] $*" >&2 || true; }
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Locate the chump binary
# ---------------------------------------------------------------------------
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if [[ -x "$REPO_ROOT/target/release/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/release/chump"
    elif command -v chump &>/dev/null; then
        CHUMP_BIN="chump"
    else
        fail "chump binary not found. Build with: cargo build --release --bin chump"
    fi
fi
log "Using binary: $CHUMP_BIN"

# ---------------------------------------------------------------------------
# Build a synthetic state dir (temp)
# ---------------------------------------------------------------------------
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

AMBIENT_LOG="$TMPDIR_TEST/ambient.jsonl"
DB_DIR="$TMPDIR_TEST"

# ------------------------------------------------------------------
# Helper: emit a fake ambient event with a given ts, kind, source
# ------------------------------------------------------------------
NOW_UNIX="$(date +%s 2>/dev/null || python3 -c 'import time; print(int(time.time()))')"
FOUR_H_AGO=$(( NOW_UNIX - 4 * 3600 + 60 ))   # barely inside window
DAY_AGO=$(( NOW_UNIX - 23 * 3600 ))

emit() {
    # emit <ts_unix> <kind> <source>
    local ts="$1" kind="$2" source="$3"
    # Convert unix ts to rough ISO8601
    local iso
    iso="$(python3 -c "import datetime; print(datetime.datetime.utcfromtimestamp($ts).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null \
          || date -u -r "$ts" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
          || echo "${ts}Z")"
    printf '{"ts":"%s","kind":"%s","source":"%s","event":"%s"}\n' \
        "$iso" "$kind" "$source" "$kind" >> "$AMBIENT_LOG"
}

# ----- Synthetic scenario (AC #8) -----
#
# target:      DARK — no events at all (score dominated by darkness=1.0)
# ci-audit:    alive-but-idle — heartbeats present, 0 action events
# shepherd:    busy — heartbeats + action events (least urgent)

# ci-audit: 2 heartbeats in last 4h, 0 actions
emit "$FOUR_H_AGO"          "curator_tick"        "ci-audit"
emit "$(( FOUR_H_AGO + 60))" "curator_tick"       "ci-audit"

# shepherd: heartbeats + shipped actions — busy
emit "$FOUR_H_AGO"            "curator_tick"       "shepherd"
emit "$(( FOUR_H_AGO + 30 ))" "sub_agent_dispatched" "shepherd"
emit "$(( FOUR_H_AGO + 60 ))" "gap_shipped"        "shepherd"
emit "$DAY_AGO"               "gap_shipped"        "shepherd"
emit "$(( DAY_AGO + 3600 ))"  "gap_shipped"        "shepherd"

log "Synthetic ambient written to $AMBIENT_LOG"
log "Events written: $(wc -l < "$AMBIENT_LOG")"

# ------------------------------------------------------------------
# Build a tiny SQLite state.db so GapStore::open() can succeed.
# We inject two open gaps tagged for 'target' and one for 'shepherd'.
# ------------------------------------------------------------------
DB_PATH="$DB_DIR/.chump/state.db"
mkdir -p "$DB_DIR/.chump"

# Use the chump binary to reserve gaps into a fresh DB — but if that's
# too heavy for CI, seed via sqlite3 directly.
if command -v sqlite3 &>/dev/null; then
    sqlite3 "$DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS gaps (
    id TEXT PRIMARY KEY,
    domain TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT 'P1',
    effort TEXT NOT NULL DEFAULT 'm',
    status TEXT NOT NULL DEFAULT 'open',
    acceptance_criteria TEXT NOT NULL DEFAULT '',
    depends_on TEXT NOT NULL DEFAULT '[]',
    notes TEXT NOT NULL DEFAULT '',
    source_doc TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL DEFAULT 0,
    closed_at INTEGER,
    opened_date TEXT NOT NULL DEFAULT '',
    closed_date TEXT NOT NULL DEFAULT '',
    closed_pr INTEGER,
    skills_required TEXT NOT NULL DEFAULT '',
    preferred_backend TEXT NOT NULL DEFAULT '',
    preferred_machine TEXT NOT NULL DEFAULT '',
    estimated_minutes TEXT NOT NULL DEFAULT '',
    required_model TEXT NOT NULL DEFAULT ''
);
INSERT INTO gaps (id, domain, title, status, skills_required, created_at)
    VALUES ('TARGET-001', 'META', 'target lane gap 1', 'open', 'target', 0);
INSERT INTO gaps (id, domain, title, status, skills_required, created_at)
    VALUES ('TARGET-002', 'META', 'target lane gap 2', 'open', 'target', 0);
INSERT INTO gaps (id, domain, title, status, skills_required, created_at)
    VALUES ('SHEPHERD-001', 'META', 'shepherd lane gap', 'open', 'shepherd', 0);
SQL
    log "SQLite DB seeded at $DB_PATH"
else
    log "sqlite3 not found — gap depth scoring will use 0 (cold fallback OK)"
    mkdir -p "$DB_DIR/.chump"
fi

# ------------------------------------------------------------------
# Run lane-recommend against the synthetic state
# ------------------------------------------------------------------
export CHUMP_AMBIENT_LOG="$AMBIENT_LOG"
export CHUMP_REPO="$DB_DIR"

log "Running: $CHUMP_BIN fleet lane-recommend --json"
OUTPUT="$("$CHUMP_BIN" fleet lane-recommend --json 2>/dev/null)"
log "Output: $OUTPUT"

# ------------------------------------------------------------------
# Assertions
# ------------------------------------------------------------------

# 1. Output is valid JSON array
if ! echo "$OUTPUT" | python3 -m json.tool > /dev/null 2>&1; then
    fail "lane-recommend --json did not produce valid JSON. Got: $OUTPUT"
fi
pass "output is valid JSON"

# 2. 'target' ranks first (highest score) — AC #8
TOP_LANE="$(echo "$OUTPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data:
    print(data[0]['lane'])
")"
if [[ "$TOP_LANE" != "target" ]]; then
    fail "expected top lane = 'target', got '$TOP_LANE'. Full output: $OUTPUT"
fi
pass "top lane is 'target' (dark lane ranks above idle/busy)"

# 3. 'shepherd' ranks last or near-last (it's busy)
SHEPHERD_RANK="$(echo "$OUTPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for i, row in enumerate(data):
    if row['lane'] == 'shepherd':
        print(i)
        break
")"
TOTAL_LANES="$(echo "$OUTPUT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
# shepherd should be in the bottom half
BOTTOM_HALF=$(( TOTAL_LANES / 2 ))
if [[ "$SHEPHERD_RANK" -lt "$BOTTOM_HALF" ]]; then
    fail "expected 'shepherd' to be in bottom half (rank $SHEPHERD_RANK < $BOTTOM_HALF). Output: $OUTPUT"
fi
pass "shepherd ranks in bottom half (rank $SHEPHERD_RANK of $TOTAL_LANES)"

# 4. ci-audit ranks below target (idle < dark)
CI_AUDIT_RANK="$(echo "$OUTPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for i, row in enumerate(data):
    if row['lane'] == 'ci-audit':
        print(i)
        break
")"
if [[ "$CI_AUDIT_RANK" -le "0" ]]; then
    fail "expected ci-audit to rank below target (rank 0), got rank $CI_AUDIT_RANK"
fi
pass "ci-audit ranks below target (alive-but-idle < dark)"

# 5. All known lanes appear in output (AC #1, AC #3)
LANE_COUNT="$(echo "$OUTPUT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
if [[ "$LANE_COUNT" -lt "10" ]]; then
    fail "expected at least 10 lanes in output, got $LANE_COUNT"
fi
pass "all $LANE_COUNT lanes present in output"

# 6. Human table mode works (AC #1)
TABLE_OUTPUT="$("$CHUMP_BIN" fleet lane-recommend 2>/dev/null || true)"
if ! echo "$TABLE_OUTPUT" | grep -q "LANE"; then
    fail "human table output missing LANE header. Got: $TABLE_OUTPUT"
fi
if ! echo "$TABLE_OUTPUT" | grep -q "RECOMMEND"; then
    fail "human table output missing RECOMMEND marker. Got: $TABLE_OUTPUT"
fi
pass "human table output is formatted correctly"

# 7. --explain flag adds per-input breakdown (AC #7)
EXPLAIN_OUTPUT="$("$CHUMP_BIN" fleet lane-recommend --json --explain 2>/dev/null)"
HAS_INPUTS="$(echo "$EXPLAIN_OUTPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('yes' if data and 'inputs' in data[0] else 'no')
")"
if [[ "$HAS_INPUTS" != "yes" ]]; then
    fail "--explain did not add 'inputs' breakdown to JSON output"
fi
pass "--explain adds per-input breakdown (AC #7)"

# 8. lane_recommended event was emitted to ambient (AC #6)
if ! grep -q '"kind":"lane_recommended"' "$AMBIENT_LOG" 2>/dev/null; then
    fail "kind=lane_recommended not found in ambient.jsonl after run"
fi
pass "kind=lane_recommended emitted to ambient (AC #6)"

# 9. Emitted event contains top_lane field
LR_EVENT="$(grep '"kind":"lane_recommended"' "$AMBIENT_LOG" | tail -1)"
if ! echo "$LR_EVENT" | python3 -c "
import json, sys
ev = json.loads(sys.stdin.read())
assert 'top_lane' in ev, f'missing top_lane in {ev}'
assert 'score' in ev, f'missing score in {ev}'
assert 'runner_up' in ev, f'missing runner_up in {ev}'
assert 'reason' in ev, f'missing reason in {ev}'
" 2>&1; then
    fail "lane_recommended event missing required fields. Event: $LR_EVENT"
fi
pass "lane_recommended event has required fields (top_lane, score, runner_up, reason)"

# 10. cold-start mode (< 10 events) falls back to roadmap-pillar ranking
COLD_AMBIENT="$TMPDIR_TEST/cold-ambient.jsonl"
# Write only 3 events — triggers cold-start
emit "$FOUR_H_AGO" "curator_tick" "ci-audit" > /dev/null
head -3 "$AMBIENT_LOG" > "$COLD_AMBIENT"

CHUMP_AMBIENT_LOG="$COLD_AMBIENT" "$CHUMP_BIN" fleet lane-recommend --json 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
top = data[0]['lane'] if data else ''
# In cold-start, the top lane aligns with EFFECTIVE pillar (default bottleneck).
# We don't assert a specific lane but verify the output is valid JSON.
assert isinstance(data, list) and len(data) > 0, 'empty output in cold-start mode'
print(f'cold-start top={top}')
" 2>&1 | { read line; log "Cold-start result: $line"; }
pass "cold-start mode (< 10 events) produces valid output (AC #4)"

echo ""
echo "All tests passed for scripts/ci/test-fleet-lane-recommend.sh (META-152)"
