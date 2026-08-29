#!/usr/bin/env bash
# scripts/ci/test-pr-cycle-slo.sh — INFRA-1417
#
# Fabricates a synthetic github_cache.db with merged PRs at known
# created_at -> merged_at deltas and asserts pr-cycle-slo.sh computes the
# correct median/p90 and emits the right ambient events (including the
# breach alert when p90 exceeds the threshold).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dev/pr-cycle-slo.sh"

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1417 pr-cycle-slo test ==="
echo

if [[ ! -x "$SCRIPT" ]]; then
    fail "script not found or not executable: $SCRIPT"
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DB="$TMP/github_cache.db"
AMBIENT="$TMP/ambient.jsonl"

# ── Fixture: 6 merged PRs, deltas = 10, 30, 60, 90, 200, 300 minutes ────────
# sorted: 10 30 60 90 200 300 -> median=(60+90)/2=75, p90 (nearest-rank,
# idx=round(0.9*5)=5 -> value 300)... but we want a case with a controllable
# breach, so use a set whose p90 index lands on 200 to test both threshold
# arms across two runs (breach + no-breach via --threshold-min).
python3 - "$DB" <<'PY'
import sqlite3
import json
import sys
import datetime

db = sys.argv[1]
conn = sqlite3.connect(db)
conn.executescript("""
CREATE TABLE pr_state (
    number INTEGER PRIMARY KEY, head_ref TEXT, head_sha TEXT, base_ref TEXT, base_sha TEXT,
    mergeable_state TEXT, auto_merge_enabled INTEGER NOT NULL DEFAULT 0, draft INTEGER NOT NULL DEFAULT 0,
    merged_at TEXT, title TEXT, user_login TEXT, updated_at_api TEXT NOT NULL, fetched_at_local TEXT NOT NULL,
    raw_payload_json TEXT
);
""")

now = datetime.datetime.now(datetime.timezone.utc)
merged = now - datetime.timedelta(hours=1)
deltas = [10, 30, 60, 90, 200, 300]
rows = []
for i, mins in enumerate(deltas):
    created = merged - datetime.timedelta(minutes=mins)
    payload = json.dumps({"created_at": created.strftime("%Y-%m-%dT%H:%M:%SZ")})
    rows.append((
        i + 1,
        merged.strftime("%Y-%m-%dT%H:%M:%SZ"),
        payload,
        now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    ))

# One old merged PR outside the 7-day window — must be excluded.
old_merged = now - datetime.timedelta(days=30)
old_created = old_merged - datetime.timedelta(minutes=5)
rows.append((
    99,
    old_merged.strftime("%Y-%m-%dT%H:%M:%SZ"),
    json.dumps({"created_at": old_created.strftime("%Y-%m-%dT%H:%M:%SZ")}),
    now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    now.strftime("%Y-%m-%dT%H:%M:%SZ"),
))

# One PR with no merged_at (still open) — must be excluded.
rows.append((100, None, json.dumps({"created_at": now.strftime("%Y-%m-%dT%H:%M:%SZ")}),
             now.strftime("%Y-%m-%dT%H:%M:%SZ"), now.strftime("%Y-%m-%dT%H:%M:%SZ")))

conn.executemany(
    "INSERT INTO pr_state (number, merged_at, raw_payload_json, updated_at_api, fetched_at_local) "
    "VALUES (?,?,?,?,?)",
    rows,
)
conn.commit()
PY

# ── 1. Default run: sample_size excludes stale + open PRs, includes 6 in-window ──
OUT="$(CHUMP_CACHE_DB="$DB" CHUMP_AMBIENT_OVERRIDE="$AMBIENT" "$SCRIPT" --json --window-days 7)"
SAMPLE_SIZE="$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sample_size"])')"
if [[ "$SAMPLE_SIZE" == "6" ]]; then
    ok "sample_size excludes out-of-window (99) and unmerged (100) PRs -> 6"
else
    fail "expected sample_size=6, got $SAMPLE_SIZE"
fi

MEDIAN="$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["median_min"])')"
if [[ "$MEDIAN" == "75.0" ]]; then
    ok "median_min computed correctly: 75.0"
else
    fail "expected median_min=75.0, got $MEDIAN"
fi

P90="$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["p90_min"])')"
if [[ "$P90" == "300.0" ]]; then
    ok "p90_min computed correctly (nearest-rank): 300.0"
else
    fail "expected p90_min=300.0, got $P90"
fi

# ── 2. Ambient emission: pr_cycle_slo event with the same values ───────────
SLO_LINE="$(grep '"kind": "pr_cycle_slo"' "$AMBIENT" || true)"
if [[ -n "$SLO_LINE" ]]; then
    ok "kind=pr_cycle_slo emitted to ambient.jsonl"
else
    fail "no kind=pr_cycle_slo event found in ambient.jsonl"
fi

# ── 3. Breach: p90=300 > default threshold 120 -> pr_cycle_slo_breach fires ──
BREACH_LINE="$(grep '"kind": "pr_cycle_slo_breach"' "$AMBIENT" || true)"
if [[ -n "$BREACH_LINE" ]]; then
    ok "kind=pr_cycle_slo_breach fired when p90 > 120min threshold"
else
    fail "expected kind=pr_cycle_slo_breach in ambient.jsonl, got none"
fi

# ── 4. No breach when threshold is raised above p90 ─────────────────────────
AMBIENT2="$TMP/ambient2.jsonl"
CHUMP_CACHE_DB="$DB" CHUMP_AMBIENT_OVERRIDE="$AMBIENT2" "$SCRIPT" --json --window-days 7 --threshold-min 400 >/dev/null
if grep -q '"kind": "pr_cycle_slo_breach"' "$AMBIENT2" 2>/dev/null; then
    fail "breach fired even though p90 (300) < threshold (400)"
else
    ok "no breach emitted when p90 is under the threshold"
fi

# ── 5. Empty DB / no merged PRs -> sample_size=0, no crash ─────────────────
EMPTY_DB="$TMP/empty_cache.db"
python3 -c "
import sqlite3
conn = sqlite3.connect('$EMPTY_DB')
conn.executescript('''
CREATE TABLE pr_state (
    number INTEGER PRIMARY KEY, merged_at TEXT, raw_payload_json TEXT,
    updated_at_api TEXT NOT NULL, fetched_at_local TEXT NOT NULL
);
''')
conn.commit()
"
AMBIENT3="$TMP/ambient3.jsonl"
EMPTY_OUT="$(CHUMP_CACHE_DB="$EMPTY_DB" CHUMP_AMBIENT_OVERRIDE="$AMBIENT3" "$SCRIPT" --json --window-days 7)"
EMPTY_SIZE="$(echo "$EMPTY_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sample_size"])')"
if [[ "$EMPTY_SIZE" == "0" ]]; then
    ok "empty cache -> sample_size=0, no crash"
else
    fail "expected sample_size=0 for empty cache, got $EMPTY_SIZE"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
