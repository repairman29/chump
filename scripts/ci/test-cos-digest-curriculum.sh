#!/usr/bin/env bash
# test-cos-digest-curriculum.sh — INFRA-1616
# Seeds synthetic `chump_skills` rows into an isolated DB and verifies
# `chump cos digest` renders a Curriculum section (text + JSON) with all five
# required subsections in the correct shape: top-by-yield, moved, new,
# decaying, anomalies. Also checks per-subsection env-var hide toggles.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP_BIN="${CHUMP_BIN:-${REPO_ROOT}/target/debug/chump}"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -x "$CHUMP_BIN" ]] || {
    echo "chump binary not found at $CHUMP_BIN — build first with: cargo build"
    exit 0
}
command -v sqlite3 >/dev/null 2>&1 || {
    echo "sqlite3 not on PATH — skipping DB-seeded assertions"
    exit 0
}

WORK=$(mktemp -d -t chump-cos-digest-test-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.chump-locks"

export CHUMP_REPO="$WORK"
export CHUMP_MEMORY_DB_PATH="$WORK/memory.db"

# Trigger schema creation (chump_skills table) via a harmless read-only call.
"$CHUMP_BIN" cos digest --json >/dev/null 2>&1 || true
[[ -f "$WORK/memory.db" ]] || fail "expected memory.db to be created at $WORK/memory.db"

now_epoch=$(date -u +%s)
iso() { date -u -d "@$1" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -u -r "$1" +"%Y-%m-%d %H:%M:%S"; }

recent_ts=$(iso "$now_epoch")
old_ts=$(iso $((now_epoch - 20 * 86400)))       # 20 days ago — decaying
new_ts=$(iso $((now_epoch - 1 * 86400)))         # 1 day ago — new (unused)

sqlite3 "$WORK/memory.db" <<SQL
INSERT INTO chump_skills (name, description, version, category, tags_json, use_count, success_count, failure_count, created_at, updated_at, last_used_at)
VALUES
  ('top-skill', 'reliable, frequently used', 1, 'test', '[]', 30, 29, 1, '$old_ts', '$recent_ts', '$recent_ts'),
  ('decaying-skill', 'unused for weeks', 1, 'test', '[]', 5, 4, 1, '$old_ts', '$old_ts', '$old_ts'),
  ('broken-skill', 'heavily used but unreliable', 1, 'test', '[]', 12, 2, 10, '$old_ts', '$recent_ts', '$recent_ts'),
  ('proposed-skill', 'freshly proposed, never run', 1, 'test', '[]', 0, 0, 0, '$new_ts', '$new_ts', NULL);
SQL

# Seed a week-old snapshot for top-skill with a low Wilson midpoint so this
# week's (high-reliability) figure registers as "moved".
week_ago_ts_epoch=$((now_epoch - 8 * 86400))
week_ago_iso=$(date -u -d "@$week_ago_ts_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r "$week_ago_ts_epoch" +"%Y-%m-%dT%H:%M:%SZ")
printf '{"ts":"%s","kind":"cos_digest_skill_snapshot","name":"top-skill","wilson_mid":0.20}\n' "$week_ago_iso" >> "$WORK/.chump-locks/ambient.jsonl"

# ── Test 1: text digest renders Mission Yield then Curriculum, in order ─────
text_out=$("$CHUMP_BIN" cos digest --week 2>&1) || fail "cos digest exited non-zero: $text_out"
my_idx=$(echo "$text_out" | grep -n "^## Mission Yield" | head -1 | cut -d: -f1)
cur_idx=$(echo "$text_out" | grep -n "^## Curriculum" | head -1 | cut -d: -f1)
[[ -n "$my_idx" ]] || fail "missing '## Mission Yield' section"
[[ -n "$cur_idx" ]] || fail "missing '## Curriculum' section"
[[ "$cur_idx" -gt "$my_idx" ]] || fail "Curriculum section must render after Mission Yield"
pass "Curriculum renders after Mission Yield"

for sub in "### Top by yield-weight" "### Moved" "### New" "### Decaying" "### Anomalies"; do
    echo "$text_out" | grep -qF "$sub" || fail "missing subsection: $sub"
done
pass "all 5 Curriculum subsections present"

echo "$text_out" | grep -q "top-skill" || fail "expected top-skill in Top-by-yield table"
pass "Top-by-yield table contains seeded skill"

echo "$text_out" | grep -A3 "^### Moved" | grep -q "top-skill" || fail "expected top-skill in Moved section"
pass "Moved section detects Wilson-CI shift > 0.15"

echo "$text_out" | grep -A3 "^### New" | grep -q "proposed-skill" || fail "expected proposed-skill in New section"
pass "New section contains never-run recently-created skill"

echo "$text_out" | grep -A3 "^### Decaying" | grep -q "decaying-skill" || fail "expected decaying-skill in Decaying section"
pass "Decaying section contains 14d+-unused skill"

echo "$text_out" | grep -A3 "^### Anomalies" | grep -q "broken-skill" || fail "expected broken-skill in Anomalies section"
pass "Anomalies section contains high-n low-reliability skill"

# ── Test 2: JSON shape ───────────────────────────────────────────────────────
json_out=$("$CHUMP_BIN" cos digest --week --json 2>&1) || fail "cos digest --json exited non-zero"
echo "$json_out" | python3 -c "
import sys, json
data = json.load(sys.stdin)
c = data['curriculum']
for key in ('top', 'moved', 'new', 'decaying', 'anomalies'):
    assert key in c, f'missing curriculum.{key}'
    assert isinstance(c[key], list), f'curriculum.{key} is not a list'
names_top = {r['name'] for r in c['top']}
assert 'top-skill' in names_top, 'top-skill missing from curriculum.top'
names_decaying = {r['name'] for r in c['decaying']}
assert 'decaying-skill' in names_decaying, 'decaying-skill missing from curriculum.decaying'
names_anom = {r['name'] for r in c['anomalies']}
assert 'broken-skill' in names_anom, 'broken-skill missing from curriculum.anomalies'
" || fail "curriculum JSON schema mismatch"
pass "cos digest --json curriculum shape correct"

# ── Test 3: per-subsection hide toggle ──────────────────────────────────────
hidden_out=$(CHUMP_COS_HIDE_CURRICULUM_ANOMALIES=1 "$CHUMP_BIN" cos digest --week 2>&1) || fail "cos digest with hide toggle exited non-zero"
if echo "$hidden_out" | grep -qF "### Anomalies"; then
    fail "CHUMP_COS_HIDE_CURRICULUM_ANOMALIES=1 did not suppress the Anomalies subsection"
fi
echo "$hidden_out" | grep -qF "### Top by yield-weight" || fail "hiding anomalies should not hide other subsections"
pass "CHUMP_COS_HIDE_CURRICULUM_ANOMALIES=1 suppresses only that subsection"

# ── Test 4: --emit writes snapshot events ───────────────────────────────────
before=$(wc -l < "$WORK/.chump-locks/ambient.jsonl")
"$CHUMP_BIN" cos digest --week --emit >/dev/null 2>&1 || fail "cos digest --emit exited non-zero"
after=$(wc -l < "$WORK/.chump-locks/ambient.jsonl")
[[ "$after" -gt "$before" ]] || fail "--emit did not append snapshot events to ambient.jsonl"
grep -q "cos_digest_skill_snapshot" "$WORK/.chump-locks/ambient.jsonl" || fail "no cos_digest_skill_snapshot events found"
pass "--emit appends per-skill snapshot events"

echo ""
echo "All cos digest Curriculum tests passed."
