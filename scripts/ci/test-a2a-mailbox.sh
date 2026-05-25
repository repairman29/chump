#!/usr/bin/env bash
# scripts/ci/test-a2a-mailbox.sh — INFRA-1115
#
# Verifies the a2a mailbox primitive end-to-end:
#   1. broadcast.sh --to <recipient> writes to inbox + ambient
#   2. broadcast.sh without --to writes to ambient ONLY (backward-compat)
#   3. broadcast.sh HANDOFF still accepts positional recipient
#   4. broadcast.sh --to <glob> expands against live sessions
#   5. chump-inbox.sh read advances cursor; subsequent read returns nothing
#   6. chump-inbox.sh read --no-advance leaves cursor untouched
#   7. chump-inbox.sh read --filter kind=INTENT filters correctly
#   8. inbox-reap.sh --apply archives dead-session inbox + emits inbox_archived
#   9. concurrent broadcast.sh --to <same-recipient> race: no torn writes
#  10. EVENT_REGISTRY.yaml registers inbox_advance + inbox_archived

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP="$(mktemp -d)"

# W-013 immunization (RESILIENT-024): unset workflow-injected env so this
# tests own $TMP fixtures are not hijacked by CI workflow CHUMP_LOCK_DIR.
unset CHUMP_REPO CHUMP_LOCK_DIR
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

# Sandbox: minimal git repo so broadcast.sh's git rev-parse works.
cd "$TMP"
git init --quiet
git config user.email test@example.com
git config user.name Test
mkdir -p scripts/coord scripts/dev .chump-locks
cp "$REPO_ROOT/scripts/coord/broadcast.sh" scripts/coord/broadcast.sh
cp "$REPO_ROOT/scripts/coord/chump-inbox.sh" scripts/coord/chump-inbox.sh
cp "$REPO_ROOT/scripts/coord/inbox-reap.sh" scripts/coord/inbox-reap.sh
chmod +x scripts/coord/*.sh

LOCK="$TMP/.chump-locks"
INBOX="$LOCK/inbox"
AMBIENT="$LOCK/ambient.jsonl"

# ── Test 1: --to recipient writes to inbox + ambient ────────────────────────
rm -f "$AMBIENT"; rm -rf "$INBOX"
CHUMP_SESSION_ID=sender-A scripts/coord/broadcast.sh --to recv-B WARN "hello B" >/dev/null 2>&1
if grep -q '"reason": "hello B"' "$INBOX/recv-B.jsonl" 2>/dev/null \
   && grep -q '"reason": "hello B"' "$AMBIENT" 2>/dev/null; then
    ok "broadcast --to recv-B WARN: inbox AND ambient written"
else
    fail "test 1 — inbox=$(cat "$INBOX/recv-B.jsonl" 2>/dev/null | head -1) ambient=$(grep 'hello B' "$AMBIENT" 2>/dev/null | head -1)"
fi

# ── Test 2: no --to → ambient-only (backward-compat) ────────────────────────
rm -f "$AMBIENT"; rm -rf "$INBOX"
CHUMP_SESSION_ID=sender-A scripts/coord/broadcast.sh WARN "untargeted message" >/dev/null 2>&1
if grep -q '"reason": "untargeted message"' "$AMBIENT" 2>/dev/null \
   && [[ ! -d "$INBOX" || -z "$(ls -A "$INBOX" 2>/dev/null)" ]]; then
    ok "broadcast without --to: ambient-only, no inbox written (back-compat)"
else
    fail "test 2 — inbox dir contents: $(ls -A "$INBOX" 2>/dev/null)"
fi

# ── Test 3: HANDOFF positional recipient still works ────────────────────────
rm -f "$AMBIENT"; rm -rf "$INBOX"
CHUMP_SESSION_ID=sender-A scripts/coord/broadcast.sh HANDOFF gap-X recv-C >/dev/null 2>&1
if grep -q '"to": "recv-C"' "$INBOX/recv-C.jsonl" 2>/dev/null; then
    ok "HANDOFF gap recv-C: positional recipient lands in inbox (back-compat)"
else
    fail "test 3 — inbox: $(cat "$INBOX/recv-C.jsonl" 2>/dev/null | head -1)"
fi

# ── Test 4: --to <glob> expands to live sessions ────────────────────────────
rm -f "$AMBIENT"; rm -rf "$INBOX"
# Create fake lease files so the glob resolves to two sessions.
cat > "$LOCK/fleet-worker-1.json" <<EOF
{"session_id":"fleet-worker-1","expires_at":"2099-01-01T00:00:00Z"}
EOF
cat > "$LOCK/fleet-worker-2.json" <<EOF
{"session_id":"fleet-worker-2","expires_at":"2099-01-01T00:00:00Z"}
EOF
cat > "$LOCK/other-7.json" <<EOF
{"session_id":"other-7","expires_at":"2099-01-01T00:00:00Z"}
EOF
CHUMP_SESSION_ID=sender-A scripts/coord/broadcast.sh --to 'fleet-worker-*' WARN "fleetwide" >/dev/null 2>&1
if grep -q 'fleetwide' "$INBOX/fleet-worker-1.jsonl" 2>/dev/null \
   && grep -q 'fleetwide' "$INBOX/fleet-worker-2.jsonl" 2>/dev/null \
   && [[ ! -f "$INBOX/other-7.jsonl" ]]; then
    ok "glob --to 'fleet-worker-*': expanded to 2 matching sessions, not other-7"
else
    fail "test 4 — fw1=$(ls "$INBOX/fleet-worker-1.jsonl" 2>/dev/null) fw2=$(ls "$INBOX/fleet-worker-2.jsonl" 2>/dev/null) other7=$(ls "$INBOX/other-7.jsonl" 2>/dev/null)"
fi

# ── Test 5: chump-inbox.sh read advances cursor ─────────────────────────────
rm -f "$AMBIENT"; rm -rf "$INBOX"
CHUMP_SESSION_ID=sender-A scripts/coord/broadcast.sh --to recv-D WARN "first" >/dev/null 2>&1
CHUMP_SESSION_ID=sender-A scripts/coord/broadcast.sh --to recv-D WARN "second" >/dev/null 2>&1
out1=$(CHUMP_SESSION_ID=recv-D scripts/coord/chump-inbox.sh read 2>&1 | grep -c 'reason' || true)
out2=$(CHUMP_SESSION_ID=recv-D scripts/coord/chump-inbox.sh read 2>&1 | grep -c 'reason' || true)
if [[ "$out1" -eq 2 && "$out2" -eq 0 ]]; then
    ok "chump-inbox.sh read: first call returns 2 msgs, second returns 0 (cursor advanced)"
else
    fail "test 5 — first=$out1 second=$out2"
fi

# ── Test 6: --no-advance leaves cursor untouched ────────────────────────────
rm -f "$AMBIENT"; rm -rf "$INBOX"
CHUMP_SESSION_ID=sender-A scripts/coord/broadcast.sh --to recv-E WARN "peek" >/dev/null 2>&1
out_a=$(CHUMP_SESSION_ID=recv-E scripts/coord/chump-inbox.sh read --no-advance 2>&1 | grep -c 'peek' || true)
out_b=$(CHUMP_SESSION_ID=recv-E scripts/coord/chump-inbox.sh read --no-advance 2>&1 | grep -c 'peek' || true)
if [[ "$out_a" -eq 1 && "$out_b" -eq 1 ]]; then
    ok "chump-inbox.sh read --no-advance: same message visible on repeat read"
else
    fail "test 6 — a=$out_a b=$out_b"
fi

# ── Test 7: --filter kind=INTENT filters correctly ──────────────────────────
rm -f "$AMBIENT"; rm -rf "$INBOX"
CHUMP_SESSION_ID=sender-A scripts/coord/broadcast.sh --to recv-F INTENT gap-Y >/dev/null 2>&1
CHUMP_SESSION_ID=sender-A scripts/coord/broadcast.sh --to recv-F WARN "ignored"  >/dev/null 2>&1
intent_count=$(CHUMP_SESSION_ID=recv-F scripts/coord/chump-inbox.sh read --filter kind=INTENT --no-advance 2>&1 | grep -c 'INTENT' || true)
warn_count=$(CHUMP_SESSION_ID=recv-F scripts/coord/chump-inbox.sh read --filter kind=INTENT --no-advance 2>&1 | grep -c 'ignored' || true)
if [[ "$intent_count" -eq 1 && "$warn_count" -eq 0 ]]; then
    ok "chump-inbox.sh --filter kind=INTENT: returns only INTENT events"
else
    fail "test 7 — intent=$intent_count warn=$warn_count"
fi

# ── Test 8: inbox-reap archives dead-session inbox ──────────────────────────
rm -f "$AMBIENT"; rm -rf "$INBOX" "$LOCK/inbox-archive"
# Dead session = lease expired well in the past + grace exceeded.
cat > "$LOCK/dead-Z.json" <<EOF
{"session_id":"dead-Z","expires_at":"2020-01-01T00:00:00Z"}
EOF
CHUMP_SESSION_ID=sender-A scripts/coord/broadcast.sh --to dead-Z WARN "left-behind" >/dev/null 2>&1
[[ -f "$INBOX/dead-Z.jsonl" ]] || fail "test 8 setup: inbox not created"
CHUMP_INBOX_REAP_GRACE_S=0 scripts/coord/inbox-reap.sh --apply >/dev/null 2>&1 || true
archived_file=$(ls "$LOCK/inbox-archive/dead-Z/"*.jsonl.gz 2>/dev/null | head -1)
if [[ -f "$archived_file" ]] \
   && [[ ! -f "$INBOX/dead-Z.jsonl" ]] \
   && grep -q '"kind":"inbox_archived"' "$AMBIENT"; then
    ok "inbox-reap --apply: dead-session inbox archived + inbox_archived event emitted"
else
    fail "test 8 — archive=$archived_file inbox_left=$(ls "$INBOX/dead-Z.jsonl" 2>/dev/null) event=$(grep inbox_archived "$AMBIENT" 2>/dev/null | head -1)"
fi

# ── Test 9: concurrent --to <same-recipient> race (no torn writes) ──────────
rm -f "$AMBIENT"; rm -rf "$INBOX"
for i in $(seq 1 20); do
    (CHUMP_SESSION_ID=sender-A scripts/coord/broadcast.sh --to recv-RACE WARN "msg-$i" >/dev/null 2>&1) &
done
wait
line_count=$(wc -l < "$INBOX/recv-RACE.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
parse_failures=$(python3 -c "
import json
ok=0; bad=0
for line in open('$INBOX/recv-RACE.jsonl'):
    line=line.strip()
    if not line: continue
    try: json.loads(line); ok+=1
    except Exception: bad+=1
print(bad)
" 2>&1)
if [[ "$line_count" -eq 20 && "$parse_failures" -eq 0 ]]; then
    ok "concurrent 20-way append: all 20 messages, no torn JSON"
else
    fail "test 9 — lines=$line_count bad_parses=$parse_failures"
fi

# ── Test 10: EVENT_REGISTRY.yaml registers new kinds ───────────────────────
if grep -q '^  - kind: inbox_advance$' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
   && grep -q '^  - kind: inbox_archived$' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"; then
    ok "EVENT_REGISTRY.yaml registers inbox_advance + inbox_archived"
else
    fail "test 10 — inbox_advance: $(grep -c 'kind: inbox_advance' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml") inbox_archived: $(grep -c 'kind: inbox_archived' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml")"
fi

echo
echo "===== INFRA-1115 results: $PASS pass, $FAIL fail ====="
[[ $FAIL -eq 0 ]]
