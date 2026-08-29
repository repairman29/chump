#!/usr/bin/env bash
# test-pr-cycle-slo.sh — INFRA-1417
#
# Fabricates an isolated github_cache.db with synthetic merged PRs and
# asserts scripts/dev/pr-cycle-slo.sh computes median/p90 correctly and
# emits kind=pr_cycle_slo (+ kind=pr_cycle_slo_breach when p90 exceeds
# threshold) to ambient.jsonl.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d -t test-infra-1417.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/.chump" "$TMP/.chump-locks"
CACHE_DB="$TMP/.chump/github_cache.db"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"

# ── Test 1: normal sample — median/p90 computed, no breach ────────────────
python3 - "$CACHE_DB" <<'PY'
import sqlite3, sys, json
from datetime import datetime, timezone, timedelta

conn = sqlite3.connect(sys.argv[1])
conn.executescript("""
CREATE TABLE pr_state (
    number INTEGER PRIMARY KEY,
    merged_at TEXT, updated_at_api TEXT NOT NULL,
    fetched_at_local TEXT NOT NULL, raw_payload_json TEXT
);
""")
now = datetime.now(timezone.utc)
# 5 PRs, cycle times 30/50/70/90/110 min -> median=70, p90(nearest-rank)=110
minutes = [30, 50, 70, 90, 110]
for i, m in enumerate(minutes):
    created = now - timedelta(days=1)
    merged = created + timedelta(minutes=m)
    payload = json.dumps({"created_at": created.strftime("%Y-%m-%dT%H:%M:%SZ")})
    conn.execute(
        "INSERT INTO pr_state (number, merged_at, updated_at_api, fetched_at_local, raw_payload_json) VALUES (?,?,?,?,?)",
        (300 + i, merged.strftime("%Y-%m-%dT%H:%M:%SZ"), now.strftime("%Y-%m-%dT%H:%M:%SZ"),
         now.strftime("%Y-%m-%dT%H:%M:%SZ"), payload),
    )
# one PR outside the 7-day window — must be excluded
old_created = now - timedelta(days=30)
old_merged = old_created + timedelta(minutes=5)
conn.execute(
    "INSERT INTO pr_state (number, merged_at, updated_at_api, fetched_at_local, raw_payload_json) VALUES (?,?,?,?,?)",
    (399, old_merged.strftime("%Y-%m-%dT%H:%M:%SZ"), now.strftime("%Y-%m-%dT%H:%M:%SZ"),
     now.strftime("%Y-%m-%dT%H:%M:%SZ"), json.dumps({"created_at": old_created.strftime("%Y-%m-%dT%H:%M:%SZ")})),
)
# one still-open PR (merged_at NULL) — must be excluded
conn.execute(
    "INSERT INTO pr_state (number, merged_at, updated_at_api, fetched_at_local, raw_payload_json) VALUES (?,?,?,?,?)",
    (400, None, now.strftime("%Y-%m-%dT%H:%M:%SZ"), now.strftime("%Y-%m-%dT%H:%M:%SZ"),
     json.dumps({"created_at": now.strftime("%Y-%m-%dT%H:%M:%SZ")})),
)
conn.commit()
PY

OUT="$(CHUMP_CACHE_DB="$CACHE_DB" CHUMP_AMBIENT_LOG="$AMBIENT" bash "$REPO_ROOT/scripts/dev/pr-cycle-slo.sh" --json)"

MEDIAN="$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pr_cycle_slo"]["median_min"])')"
P90="$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pr_cycle_slo"]["p90_min"])')"
SAMPLE="$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pr_cycle_slo"]["sample_size"])')"

[[ "$SAMPLE" == "5" ]] && ok "sample_size excludes out-of-window + still-open PRs (=5)" || fail "sample_size expected 5, got $SAMPLE"
[[ "$MEDIAN" == "70.0" ]] && ok "median_min == 70.0" || fail "median_min expected 70.0, got $MEDIAN"
[[ "$P90" == "110.0" ]] && ok "p90_min == 110.0" || fail "p90_min expected 110.0, got $P90"

grep -q '"kind": *"pr_cycle_slo"' "$AMBIENT" && ok "kind=pr_cycle_slo emitted to ambient.jsonl" \
    || fail "kind=pr_cycle_slo missing from ambient.jsonl"
grep -q '"kind": *"pr_cycle_slo_breach"' "$AMBIENT" && fail "unexpected kind=pr_cycle_slo_breach for sub-threshold p90" \
    || ok "no breach event emitted (p90=110 < default 120min threshold)"

# ── Test 2: breach — p90 above threshold fires pr_cycle_slo_breach ────────
CACHE_DB2="$TMP/.chump/github_cache_breach.db"
AMBIENT2="$TMP/.chump-locks/ambient_breach.jsonl"
python3 - "$CACHE_DB2" <<'PY'
import sqlite3, sys, json
from datetime import datetime, timezone, timedelta

conn = sqlite3.connect(sys.argv[1])
conn.executescript("""
CREATE TABLE pr_state (
    number INTEGER PRIMARY KEY,
    merged_at TEXT, updated_at_api TEXT NOT NULL,
    fetched_at_local TEXT NOT NULL, raw_payload_json TEXT
);
""")
now = datetime.now(timezone.utc)
for i, m in enumerate([200, 210, 220]):
    created = now - timedelta(days=1)
    merged = created + timedelta(minutes=m)
    payload = json.dumps({"created_at": created.strftime("%Y-%m-%dT%H:%M:%SZ")})
    conn.execute(
        "INSERT INTO pr_state (number, merged_at, updated_at_api, fetched_at_local, raw_payload_json) VALUES (?,?,?,?,?)",
        (500 + i, merged.strftime("%Y-%m-%dT%H:%M:%SZ"), now.strftime("%Y-%m-%dT%H:%M:%SZ"),
         now.strftime("%Y-%m-%dT%H:%M:%SZ"), payload),
    )
conn.commit()
PY

CHUMP_CACHE_DB="$CACHE_DB2" CHUMP_AMBIENT_LOG="$AMBIENT2" bash "$REPO_ROOT/scripts/dev/pr-cycle-slo.sh" --json > /dev/null

grep -q '"kind": *"pr_cycle_slo_breach"' "$AMBIENT2" && ok "kind=pr_cycle_slo_breach fires when p90 > 120min" \
    || fail "kind=pr_cycle_slo_breach missing for breaching sample"

# ── Test 3: empty cache — script exits 0, emits nothing ───────────────────
CACHE_DB3="$TMP/.chump/github_cache_empty.db"
AMBIENT3="$TMP/.chump-locks/ambient_empty.jsonl"
python3 -c "
import sqlite3
conn = sqlite3.connect('$CACHE_DB3')
conn.executescript('''
CREATE TABLE pr_state (
    number INTEGER PRIMARY KEY,
    merged_at TEXT, updated_at_api TEXT NOT NULL,
    fetched_at_local TEXT NOT NULL, raw_payload_json TEXT
);
''')
conn.commit()
"
CHUMP_CACHE_DB="$CACHE_DB3" CHUMP_AMBIENT_LOG="$AMBIENT3" bash "$REPO_ROOT/scripts/dev/pr-cycle-slo.sh" --json > /dev/null \
    && ok "empty cache: script exits 0" || fail "empty cache: script exited non-zero"
[[ -f "$AMBIENT3" ]] && grep -q '"sample_size": 0' "$AMBIENT3" && ok "empty cache: sample_size=0 event still emitted" \
    || fail "empty cache: expected a sample_size=0 event"

echo
echo "── Results: $PASS passed, $FAIL failed ──"
[[ "$FAIL" -eq 0 ]]
