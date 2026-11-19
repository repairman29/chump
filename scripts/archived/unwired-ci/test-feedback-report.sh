#!/usr/bin/env bash
# scripts/ci/test-feedback-report.sh — CREDIBLE-063

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/coord/feedback-report.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -x "$SCRIPT" ] || fail "missing"

FB="$TMP/feedback.jsonl"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit() {
    local kind="$1" subj="$2" sess="$3" rationale="$4" vote="${5:-0}"
    python3 -c "
import json, sys
print(json.dumps({
    'event':'FEEDBACK','kind':sys.argv[1],'session':sys.argv[2],
    'ts':sys.argv[3],'subject':sys.argv[4],'rationale':sys.argv[5],
    'vote':sys.argv[6],'corr_id':sys.argv[4]
}))
" "$kind" "$sess" "$(now)" "$subj" "$rationale" "$vote" >> "$FB"
}

emit defect     INFRA-1254 sess-A "wrong default"
emit defect     INFRA-1254 sess-B "agrees with A"
emit proposal   "auto-merge-policy" sess-A "P0 needs 2 reviewers"
emit preference "inbox-first-picker" sess-A "good"  "+1"
emit preference "inbox-first-picker" sess-B "good"  "+1"
emit preference "inbox-first-picker" sess-C "wrong for ops" "-1"
emit retro      INFRA-1271 sess-A "subshell bit me"
emit retro      CREDIBLE-063 sess-B "shell vs rust kpi split"

# ── Test 1: human-readable run ────────────────────────────────────────────
out=$(CHUMP_LOCK_DIR="$TMP" bash "$SCRIPT" 2>&1)
echo "$out" | grep -q "total events: 8" \
    || fail "expected 'total events: 8', got: $out"
echo "$out" | grep -q "defect" || fail "by_kind missing 'defect'"
echo "$out" | grep -q "preference" || fail "by_kind missing 'preference'"
echo "$out" | grep -q "INFRA-1254" || fail "top-3 missing INFRA-1254"
echo "$out" | grep -q "inbox-first-picker" || fail "preference subject missing"
echo "$out" | grep -q "net=+1" || fail "preference net tally not computed"
ok "human report has total, by_kind, top-3, preference votes"

# ── Test 2: JSON mode ─────────────────────────────────────────────────────
json_out=$(CHUMP_LOCK_DIR="$TMP" bash "$SCRIPT" --json 2>&1)
echo "$json_out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['total'] == 8, d['total']
assert d['by_kind']['defect'] == 2, d['by_kind']
assert d['by_kind']['preference'] == 3, d['by_kind']
assert d['by_domain']['INFRA'] >= 3, d['by_domain']
# top_subjects sorted by count
assert d['top_subjects'][0]['count'] >= d['top_subjects'][-1]['count']
# inbox-first-picker should have +2 -1 net=+1
pv = d['preference_votes']['inbox-first-picker']
assert pv['plus_one'] == 2 and pv['minus_one'] == 1 and pv['net'] == 1, pv
" || fail "JSON shape invalid"
ok "JSON mode: total, by_kind, by_domain, top_subjects, preference_votes all correct"

# ── Test 3: --window respects time bound (events older than 1h excluded) ──
# Inject an "old" entry
python3 -c "
import json
e = {'event':'FEEDBACK','kind':'defect','session':'sess-old','ts':'2020-01-01T00:00:00Z','subject':'OLD-1','rationale':'x','vote':'0','corr_id':'OLD-1'}
print(json.dumps(e))
" >> "$FB"
out=$(CHUMP_LOCK_DIR="$TMP" bash "$SCRIPT" --window 1h --json 2>&1)
echo "$out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert 'OLD-1' not in {t['subject'] for t in d['top_subjects']}, d
assert d['by_domain'].get('OLD', 0) == 0, d
" || fail "--window 1h should exclude old entry"
ok "--window 1h excludes events older than 1h"

# ── Test 4: empty feedback.jsonl → safe zero-output ───────────────────────
: > "$FB"
out=$(CHUMP_LOCK_DIR="$TMP" bash "$SCRIPT" --json 2>&1)
echo "$out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d['total']==0, d" \
    || fail "empty feedback → total=0 expected: $out"
ok "empty feedback.jsonl → total=0 (no error)"

# ── Test 5: missing feedback.jsonl → graceful exit ────────────────────────
rm -f "$FB"
out=$(CHUMP_LOCK_DIR="$TMP" bash "$SCRIPT" --json 2>&1)
echo "$out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d['total']==0, d" \
    || fail "missing feedback → total=0 expected, got: $out"
ok "missing feedback.jsonl → graceful zero output"

echo
echo "All CREDIBLE-063 feedback-report tests passed."
