#!/usr/bin/env bash
# scripts/ci/test-feedback-event.sh — INFRA-1271

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BROADCAST="$REPO_ROOT/scripts/coord/broadcast.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Sandbox repo to control LOCK_DIR.
mkdir -p "$TMP/repo/scripts/coord"
cp "$BROADCAST" "$TMP/repo/scripts/coord/broadcast.sh"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" -c user.email=t@t -c user.name=t add -A
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q -m s

LOCK_DIR="$TMP/repo/.chump-locks"
FB="$LOCK_DIR/feedback.jsonl"
AMBIENT="$LOCK_DIR/ambient.jsonl"

emit() {
    (cd "$TMP/repo" && CHUMP_SESSION_ID=sess-A bash scripts/coord/broadcast.sh "$@" >/dev/null)
}

# ── Test 1: defect kind ───────────────────────────────────────────────────
emit FEEDBACK defect INFRA-1254 "inbox-first wins even in interactive ops mode" || fail "defect emit failed"
[ -f "$FB" ] || fail "feedback.jsonl not written"
last=$(tail -1 "$FB")
echo "$last" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d.get('event')=='FEEDBACK' and d.get('kind')=='defect' and d.get('subject')=='INFRA-1254', d; print('ok')" >/dev/null \
    || fail "defect schema wrong: $last"
ok "FEEDBACK defect lands in feedback.jsonl with correct fields"

# Verify ambient.jsonl also has it (JSON has spaces after colons)
grep -q '"event": "FEEDBACK"' "$AMBIENT" \
    || fail "FEEDBACK must also appear in ambient.jsonl for audit"
grep -q '"kind": "defect"' "$AMBIENT" \
    || fail "FEEDBACK kind missing from ambient.jsonl"
ok "FEEDBACK also lands in ambient.jsonl (audit trail)"

# ── Test 2: proposal kind ─────────────────────────────────────────────────
emit FEEDBACK proposal "auto-merge-policy" "Should require 2 reviewers for P0 changes"
last=$(tail -1 "$FB")
echo "$last" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d.get('kind')=='proposal' and 'reviewers' in d.get('rationale',''), d; print('ok')" >/dev/null \
    || fail "proposal schema wrong"
ok "FEEDBACK proposal recorded"

# ── Test 3: preference with +1 vote ───────────────────────────────────────
emit FEEDBACK preference "inbox-first-picker" "matches my workflow" "+1"
last=$(tail -1 "$FB")
echo "$last" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d.get('kind')=='preference' and d.get('vote')=='+1', d; print('ok')" >/dev/null \
    || fail "preference vote not recorded"
ok "FEEDBACK preference with +1 vote recorded"

# ── Test 4: preference with -1 vote ───────────────────────────────────────
emit FEEDBACK preference "inbox-first-picker" "wrong for operator session" "-1"
last=$(tail -1 "$FB")
echo "$last" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d.get('vote')=='-1', d; print('ok')" >/dev/null \
    || fail "-1 vote not recorded"
ok "FEEDBACK preference with -1 vote recorded"

# ── Test 5: retro kind ────────────────────────────────────────────────────
emit FEEDBACK retro INFRA-1271 "Subshell expansion bit me again; should add to gotchas"
last=$(tail -1 "$FB")
echo "$last" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d.get('kind')=='retro' and d.get('subject')=='INFRA-1271', d; print('ok')" >/dev/null \
    || fail "retro schema wrong"
ok "FEEDBACK retro recorded"

# ── Test 6: invalid kind rejected ─────────────────────────────────────────
if (cd "$TMP/repo" && bash scripts/coord/broadcast.sh FEEDBACK bogus "subj" "x" 2>/dev/null); then
    fail "invalid kind should be rejected"
fi
ok "invalid FEEDBACK kind rejected"

# ── Test 7: missing subject rejected ──────────────────────────────────────
if (cd "$TMP/repo" && bash scripts/coord/broadcast.sh FEEDBACK defect 2>/dev/null); then
    fail "missing subject should be rejected"
fi
ok "FEEDBACK with no subject rejected"

# ── Test 8: corr_id defaults to subject ───────────────────────────────────
emit FEEDBACK defect INFRA-9999 "test"
last=$(tail -1 "$FB")
echo "$last" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d.get('corr_id')=='INFRA-9999', d; print('ok')" >/dev/null \
    || fail "corr_id should default to subject (gap-id)"
ok "corr_id defaults to subject (lifecycle interop)"

echo
echo "All INFRA-1271 FEEDBACK event tests passed."
