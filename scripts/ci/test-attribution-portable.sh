#!/usr/bin/env bash
# test-attribution-portable.sh — CREDIBLE-045: verify generic agent attribution
#
# Confirms that model-ship-rate.sh and waste-tally (via ambient.jsonl) correctly
# group ship_grade events by any agent/harness identifier — not just Anthropic-
# flavored ones.
#
# Fixtures: 5 different harnesses:
#   claude          — Claude Code / Anthropic CLI
#   opencode        — opencode standard harness
#   aider           — aider-chat CLI
#   repairman       — repairman automated fixer
#   manual          — operator running scripts manually
#
# AC3 of CREDIBLE-045.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIP_RATE="$REPO_ROOT/scripts/dispatch/model-ship-rate.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-attribution-portable.XXXXXX)"
AMBIENT="$TMP/ambient.jsonl"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Fixture: 5 harnesses, varied clippy/test_added results ────────────────────
cat > "$AMBIENT" <<EOF
{"event":"ship_grade","kind":"ship_grade","ts":"$NOW","gap_id":"CRED-001","model":"claude-sonnet","harness":"claude","clippy_ok":true,"test_added":true}
{"event":"ship_grade","kind":"ship_grade","ts":"$NOW","gap_id":"CRED-002","model":"claude-haiku","harness":"claude","clippy_ok":true,"test_added":false}
{"event":"ship_grade","kind":"ship_grade","ts":"$NOW","gap_id":"CRED-003","model":"opencode-base","harness":"opencode","clippy_ok":false,"test_added":true}
{"event":"ship_grade","kind":"ship_grade","ts":"$NOW","gap_id":"CRED-004","model":"aider-gpt4o","harness":"aider","clippy_ok":true,"test_added":true}
{"event":"ship_grade","kind":"ship_grade","ts":"$NOW","gap_id":"CRED-005","model":"aider-sonnet","harness":"aider","clippy_ok":false,"test_added":false}
{"event":"ship_grade","kind":"ship_grade","ts":"$NOW","gap_id":"CRED-006","model":"repairman-v1","harness":"repairman","clippy_ok":true,"test_added":true}
{"event":"ship_grade","kind":"ship_grade","ts":"$NOW","gap_id":"CRED-007","model":"unknown","harness":"manual","clippy_ok":false,"test_added":false}
{"event":"ship_grade","kind":"ship_grade","ts":"$NOW","gap_id":"CRED-008","model":"opencode-bigpickle","harness":"opencode-bigpickle","clippy_ok":true,"test_added":true}
{"event":"INTENT","ts":"$NOW","gap":"OTHER-001","model":"claude-sonnet"}
EOF

# ── Test 1: --by-harness text output includes all 5 harnesses ─────────────────
out="$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SHIP_RATE" --by-harness --window 1h 2>&1)"
for harness in claude opencode aider repairman manual; do
    echo "$out" | grep -q "$harness" \
        || fail "Test 1: --by-harness output missing harness '$harness'"
done
pass "Test 1: --by-harness output includes all 5 harnesses (claude, opencode, aider, repairman, manual)"

# ── Test 2: --by-model text output includes all 5 distinct model identifiers ───
out_model="$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SHIP_RATE" --window 1h 2>&1)"
for model in claude-sonnet opencode-base aider-gpt4o repairman-v1; do
    echo "$out_model" | grep -q "$model" \
        || fail "Test 2: --by-model output missing model '$model'"
done
pass "Test 2: --by-model output includes non-Claude model identifiers correctly"

# ── Test 3: JSON --by-harness has correct counts per harness ──────────────────
json_harness="$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SHIP_RATE" --by-harness --window 1h --json 2>&1)"
python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
rows = {r['harness']: r for r in d['harnesses']}
assert 'claude'          in rows, 'claude harness missing from JSON'
assert 'opencode'        in rows, 'opencode harness missing from JSON'
assert 'aider'           in rows, 'aider harness missing from JSON'
assert 'repairman'       in rows, 'repairman harness missing from JSON'
assert 'manual'          in rows, 'manual harness missing from JSON'
assert 'opencode-bigpickle' in rows, 'opencode-bigpickle harness missing from JSON'
assert rows['claude']['graded']    == 2, f'claude graded={rows[\"claude\"][\"graded\"]} want 2'
assert rows['aider']['graded']     == 2, f'aider graded={rows[\"aider\"][\"graded\"]} want 2'
assert rows['repairman']['graded'] == 1, f'repairman graded={rows[\"repairman\"][\"graded\"]} want 1'
assert rows['manual']['graded']    == 1, f'manual graded={rows[\"manual\"][\"graded\"]} want 1'
print('json_ok')
" <<< "$json_harness" | grep -q "json_ok" \
    || fail "Test 3: JSON --by-harness counts incorrect"
pass "Test 3: JSON --by-harness has correct counts (claude=2, aider=2, repairman=1, manual=1)"

# ── Test 4: clippy/test_added percentages correct for aider (50% each) ────────
python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
rows = {r['harness']: r for r in d['harnesses']}
a = rows['aider']
assert a['clippy_ok_pct'] == 50, f'aider clippy_ok_pct={a[\"clippy_ok_pct\"]} want 50'
assert a['test_added_pct'] == 50, f'aider test_added_pct={a[\"test_added_pct\"]} want 50'
print('pct_ok')
" <<< "$json_harness" | grep -q "pct_ok" \
    || fail "Test 4: aider clippy/test percentages wrong (want 50% each)"
pass "Test 4: aider clippy_ok_pct=50% and test_added_pct=50% correct"

# ── Test 5: unknown/missing model field defaults to 'unknown' bucket ───────────
json_model="$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SHIP_RATE" --window 1h --json 2>&1)"
python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
models = {r['model']: r for r in d['models']}
# 'manual' harness has model='unknown'
assert 'unknown' in models, f'unknown model bucket missing; got {list(models)}'
print('unknown_ok')
" <<< "$json_model" | grep -q "unknown_ok" \
    || fail "Test 5: missing/null model field not bucketed to 'unknown'"
pass "Test 5: missing model field correctly bucketed to 'unknown'"

# ── Test 6: INTENT events are NOT counted as ship_grade ───────────────────────
python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
total = sum(r['graded'] for r in d['harnesses'])
assert total == 8, f'total ship_grade events={total} want 8 (INTENT should be excluded)'
print('intent_excluded')
" <<< "$json_harness" | grep -q "intent_excluded" \
    || fail "Test 6: INTENT events incorrectly counted as ship_grade"
pass "Test 6: INTENT events excluded from ship_grade tallies"

# ── Test 7: no Anthropic-specific filtering — all harnesses equal citizens ─────
# The real test: output must not silently drop non-Claude harnesses.
# Run again with ONLY non-Claude fixtures.
AMBIENT2="$TMP/ambient2.jsonl"
cat > "$AMBIENT2" <<EOF
{"event":"ship_grade","kind":"ship_grade","ts":"$NOW","gap_id":"X-001","model":"aider-gpt4o","harness":"aider","clippy_ok":true,"test_added":true}
{"event":"ship_grade","kind":"ship_grade","ts":"$NOW","gap_id":"X-002","model":"repairman-v1","harness":"repairman","clippy_ok":true,"test_added":false}
{"event":"ship_grade","kind":"ship_grade","ts":"$NOW","gap_id":"X-003","model":"llama-3.1-ollama","harness":"ollama","clippy_ok":false,"test_added":false}
EOF
json2="$(CHUMP_AMBIENT_LOG="$AMBIENT2" bash "$SHIP_RATE" --by-harness --window 1h --json 2>&1)"
python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
rows = {r['harness']: r for r in d['harnesses']}
assert 'aider'    in rows, 'aider missing from non-Claude-only run'
assert 'repairman' in rows, 'repairman missing from non-Claude-only run'
assert 'ollama'   in rows, 'ollama missing from non-Claude-only run'
assert 'claude' not in rows, 'claude should not appear in non-Claude-only fixture'
print('non_claude_ok')
" <<< "$json2" | grep -q "non_claude_ok" \
    || fail "Test 7: non-Claude harnesses not correctly reported in non-Claude-only run"
pass "Test 7: non-Claude harnesses (aider, repairman, ollama) report correctly without Claude events"

echo ""
echo "All CREDIBLE-045 portable-attribution checks passed (7/7)."
