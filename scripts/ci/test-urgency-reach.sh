#!/usr/bin/env bash
# scripts/ci/test-urgency-reach.sh — INFRA-1299

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BROADCAST="$REPO_ROOT/scripts/coord/broadcast.sh"
CLASSIFIER="$REPO_ROOT/scripts/coord/reach-classifier.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -x "$CLASSIFIER" ] || fail "missing classifier"

# Sandbox repo for broadcast.sh
mkdir -p "$TMP/repo/scripts/coord"
cp "$BROADCAST" "$TMP/repo/scripts/coord/broadcast.sh"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" -c user.email=t@t -c user.name=t add -A
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q -m s

AMBIENT="$TMP/repo/.chump-locks/ambient.jsonl"

# ── Test 1: broadcast.sh with --urgency now sets the field ─────────────
(cd "$TMP/repo" && bash scripts/coord/broadcast.sh --urgency now STUCK INFRA-9001 "test" >/dev/null 2>&1)
last=$(tail -1 "$AMBIENT")
echo "$last" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d['urgency']=='now', d" \
    || fail "STUCK --urgency now did not set field: $last"
ok "--urgency now sets urgency field"

# ── Test 2: --urgency rejects bad value ────────────────────────────────
if (cd "$TMP/repo" && bash scripts/coord/broadcast.sh --urgency yesterday STUCK X "x" 2>/dev/null); then
    fail "bad --urgency should be rejected"
fi
ok "invalid --urgency value rejected"

# ── Test 3: no --urgency → empty string in event (classifier derives default) ──
: > "$AMBIENT"
(cd "$TMP/repo" && bash scripts/coord/broadcast.sh STUCK INFRA-9002 "t" >/dev/null 2>&1)
last=$(tail -1 "$AMBIENT")
echo "$last" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d.get('urgency','') == '', d" \
    || fail "no --urgency should leave empty: $last"
ok "no --urgency → empty (classifier defaults)"

# ── Test 4: reach-classifier: urgency=now → [inbox, toast, push] ───────
out=$(echo '{"event":"STUCK","urgency":"now"}' | "$CLASSIFIER")
echo "$out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['urgency']=='now', d
assert d['channels']==['inbox','toast','push'], d
" || fail "urgency=now wrong channels: $out"
ok "classifier: urgency=now → [inbox, toast, push]"

# ── Test 5: urgency=hours → [inbox, toast] ─────────────────────────────
out=$(echo '{"event":"STUCK","urgency":"hours"}' | "$CLASSIFIER")
echo "$out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['channels']==['inbox','toast'], d
" || fail "urgency=hours wrong: $out"
ok "classifier: urgency=hours → [inbox, toast]"

# ── Test 6: urgency=digest → [inbox, digest] ───────────────────────────
out=$(echo '{"event":"FEEDBACK","kind":"retro","urgency":"digest"}' | "$CLASSIFIER")
echo "$out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['channels']==['inbox','digest'], d
" || fail "urgency=digest wrong: $out"
ok "classifier: urgency=digest → [inbox, digest]"

# ── Test 7: no urgency, event=ALERT → defaults to now ──────────────────
out=$(echo '{"event":"ALERT","kind":"fleet_wedge"}' | "$CLASSIFIER")
echo "$out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['urgency']=='now', d
" || fail "ALERT default urgency wrong: $out"
ok "default: ALERT → urgency=now"

# ── Test 8: no urgency, FEEDBACK retro → defaults to digest ────────────
out=$(echo '{"event":"FEEDBACK","kind":"retro"}' | "$CLASSIFIER")
echo "$out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['urgency']=='digest', d
" || fail "FEEDBACK retro default wrong: $out"
ok "default: FEEDBACK retro → urgency=digest"

# ── Test 9: invalid urgency value falls back to hours ──────────────────
out=$(echo '{"event":"STUCK","urgency":"yesterday"}' | "$CLASSIFIER")
echo "$out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['urgency']=='hours', d
" || fail "invalid urgency should fall back to hours: $out"
ok "invalid urgency → fallback hours"

echo
echo "All INFRA-1299 urgency + reach-classifier tests passed."
