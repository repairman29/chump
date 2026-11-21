#!/usr/bin/env bash
# scripts/ci/test-operator-rules.sh — INFRA-1300

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/coord/operator-rules.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -x "$SCRIPT" ] || fail "missing"

RULES_FILE="$TMP/rules.yaml"
export CHUMP_OPERATOR_RULES_FILE="$RULES_FILE"

# ── Test 1: list on a fresh repo seeds the default rules ─────────────────
out=$("$SCRIPT" list)
echo "$out" | grep -q "STUCK" || fail "default rules should include STUCK; got: $out"
echo "$out" | grep -q "fleet_wedge" || fail "default rules should include fleet_wedge ALERT"
ok "default rules seeded on first invocation"

# ── Test 2: add a rule ────────────────────────────────────────────────────
"$SCRIPT" add silent event=FEEDBACK kind=retro >/dev/null
out=$("$SCRIPT" list)
echo "$out" | grep -q "silent when event=FEEDBACK and kind=retro" \
    || fail "added rule should appear in list: $out"
ok "add appends a rule"

# ── Test 3: test against a matching event → returns matched_rule_index ──
match=$("$SCRIPT" test '{"event":"FEEDBACK","kind":"retro","subject":"sub"}')
echo "$match" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['action'] == 'silent', d
assert d['matched_rule_index'] is not None
" || fail "FEEDBACK retro should match silent rule: $match"
ok "test: matching event → silent action"

# ── Test 4: test against non-matching event → default notify ──────────────
match=$("$SCRIPT" test '{"event":"DONE","subject":"INFRA-1"}')
echo "$match" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['action'] == 'notify', d
assert d['matched_rule_index'] is None
" || fail "DONE should not match: $match"
ok "test: non-matching event → default notify"

# ── Test 5: subject_pattern glob match ────────────────────────────────────
"$SCRIPT" add force_now event=FEEDBACK subject_pattern="PRODUCT-1*" >/dev/null
match=$("$SCRIPT" test '{"event":"FEEDBACK","kind":"proposal","subject":"PRODUCT-100"}')
echo "$match" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['action'] == 'force_now', d
" || fail "subject_pattern glob PRODUCT-1* should match PRODUCT-100: $match"
ok "subject_pattern glob honored"

# ── Test 6: subject_pattern non-match ────────────────────────────────────
match=$("$SCRIPT" test '{"event":"FEEDBACK","kind":"proposal","subject":"INFRA-999"}')
echo "$match" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
# Should NOT hit PRODUCT-1* rule; would hit defect-FEEDBACK rule if kind matched.
# kind=proposal does not match defect rule. Should land on notify (default).
assert d['action'] in ('notify',), d
" || fail "INFRA-999 should not hit PRODUCT-1*: $match"
ok "subject_pattern non-match falls through"

# ── Test 7: min_urgency gates the rule ────────────────────────────────────
"$SCRIPT" add silent event=STUCK min_urgency=digest >/dev/null
# event with urgency=hours: min_urgency=digest is satisfied (hours > digest)
match=$("$SCRIPT" test '{"event":"STUCK","urgency":"hours","subject":"X"}')
# But the EARLIER rule (event=STUCK -> notify) is first; first match wins.
echo "$match" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['action'] == 'notify', d
" || fail "first STUCK rule (notify) should win: $match"
ok "first match wins (rule order respected)"

# ── Test 8: remove deletes by index ──────────────────────────────────────
before=$("$SCRIPT" list | wc -l | tr -d ' ')
"$SCRIPT" remove 0 >/dev/null
after=$("$SCRIPT" list | wc -l | tr -d ' ')
[ "$after" -lt "$before" ] || fail "remove should shrink list: before=$before after=$after"
ok "remove deletes by index"

# ── Test 9: remove out-of-range errors ────────────────────────────────────
if "$SCRIPT" remove 999 >/dev/null 2>&1; then
    fail "remove 999 should error"
fi
ok "remove out-of-range rejected"

echo
echo "All INFRA-1300 operator-rules tests passed."
