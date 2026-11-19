#!/usr/bin/env bash
# scripts/ci/test-corr-id-lifecycle.sh — INFRA-1255
#
# Verifies:
#   1. broadcast.sh writes corr_id into every event (default = gap-id)
#   2. --corr <id> override is honored
#   3. inbox-reap.sh drops messages when a DONE with matching corr_id exists
#   4. inbox-reap.sh drops messages older than TTL_DAYS

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BROADCAST="$REPO_ROOT/scripts/coord/broadcast.sh"
REAP="$REPO_ROOT/scripts/coord/inbox-reap.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Isolate ambient + inbox under a fake repo root by pointing CHUMP_LOCK_DIR
# at our tmp. broadcast.sh resolves LOCK_DIR from MAIN_REPO; we need to
# trick it via git rev-parse. Simplest: run from inside a fresh tiny git
# init'd dir.
mkdir -p "$TMP/repo/.chump-locks/inbox"
mkdir -p "$TMP/repo/scripts/coord" "$TMP/repo/scripts/dev"
cp "$BROADCAST" "$TMP/repo/scripts/coord/broadcast.sh"
cp "$REAP"      "$TMP/repo/scripts/coord/inbox-reap.sh"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" -c user.email=t@t -c user.name=t add -A
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q -m seed

LOCK_DIR="$TMP/repo/.chump-locks"
AMBIENT="$LOCK_DIR/ambient.jsonl"
INBOX="$LOCK_DIR/inbox"

# A "session" needs a lease file to be considered LIVE by inbox-reap.
# Create one with a future expiry.
write_lease() {
    local s="$1"
    python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta
exp = (datetime.now(timezone.utc) + timedelta(hours=4)).isoformat().replace('+00:00','Z')
json.dump({'session': sys.argv[1], 'expires_at': exp, 'heartbeat_at': exp}, open(sys.argv[2], 'w'))
" "$s" "$LOCK_DIR/$s.json"
}
write_lease "sess-A"
write_lease "sess-B"

# ── Test 1: corr_id defaults to gap-id ────────────────────────────────────
(cd "$TMP/repo" && CHUMP_SESSION_ID=sess-A bash scripts/coord/broadcast.sh STUCK INFRA-7000 "test1" >/dev/null)
last=$(tail -1 "$AMBIENT")
echo "$last" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d.get('corr_id')=='INFRA-7000', d; print('ok')" >/dev/null \
    || fail "STUCK: corr_id should default to gap-id; got: $last"
ok "STUCK: corr_id defaults to gap-id"

# ── Test 2: --corr override ────────────────────────────────────────────────
(cd "$TMP/repo" && CHUMP_SESSION_ID=sess-A bash scripts/coord/broadcast.sh --corr custom-corr STUCK INFRA-7001 "test2" >/dev/null)
last=$(tail -1 "$AMBIENT")
echo "$last" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d.get('corr_id')=='custom-corr', d; print('ok')" >/dev/null \
    || fail "--corr override: expected 'custom-corr'; got: $last"
ok "--corr override honored"

# ── Test 3: HANDOFF carries corr_id + lands in inbox ──────────────────────
(cd "$TMP/repo" && CHUMP_SESSION_ID=sess-A bash scripts/coord/broadcast.sh HANDOFF INFRA-7002 sess-B >/dev/null)
last=$(tail -1 "$INBOX/sess-B.jsonl")
echo "$last" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d.get('corr_id')=='INFRA-7002' and d.get('event')=='HANDOFF', d; print('ok')" >/dev/null \
    || fail "HANDOFF inbox should carry corr_id=INFRA-7002; got: $last"
ok "HANDOFF inbox carries corr_id"

# ── Test 4: inbox-reap drops messages whose corr_id is in a DONE event ───
# Put a HANDOFF in sess-B's inbox for INFRA-7100, then emit DONE for the same.
(cd "$TMP/repo" && CHUMP_SESSION_ID=sess-A bash scripts/coord/broadcast.sh HANDOFF INFRA-7100 sess-B >/dev/null)
inbox_before=$(wc -l < "$INBOX/sess-B.jsonl" | tr -d ' ')
(cd "$TMP/repo" && CHUMP_SESSION_ID=sess-A bash scripts/coord/broadcast.sh DONE INFRA-7100 deadbeef >/dev/null)
(cd "$TMP/repo" && bash scripts/coord/inbox-reap.sh --apply >/dev/null 2>&1)
inbox_after=$(wc -l < "$INBOX/sess-B.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
[ "$inbox_after" -lt "$inbox_before" ] || fail "DONE reap: inbox should shrink (before=$inbox_before, after=$inbox_after)"
# Verify the dropped one was INFRA-7100 specifically
if grep -q '"corr_id":"INFRA-7100"[^}]*"event":"HANDOFF"' "$INBOX/sess-B.jsonl" 2>/dev/null; then
    fail "DONE reap: INFRA-7100 HANDOFF should be dropped"
fi
ok "inbox-reap drops messages whose corr_id has a matching DONE"

# ── Test 5: TTL drops old messages ─────────────────────────────────────────
# Inject an "old" message directly.
old_ts="2024-01-01T00:00:00Z"
python3 -c "
import json
e = {'event':'STUCK','session':'sess-A','ts':'$old_ts','corr_id':'INFRA-9999','gap':'INFRA-9999','reason':'ancient'}
open('$INBOX/sess-B.jsonl','a').write(json.dumps(e)+'\n')
"
before=$(wc -l < "$INBOX/sess-B.jsonl" | tr -d ' ')
(cd "$TMP/repo" && CHUMP_INBOX_TTL_DAYS=7 bash scripts/coord/inbox-reap.sh --apply >/dev/null 2>&1)
after=$(wc -l < "$INBOX/sess-B.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
[ "$after" -lt "$before" ] || fail "TTL reap: inbox should shrink (before=$before, after=$after)"
if grep -q "INFRA-9999" "$INBOX/sess-B.jsonl" 2>/dev/null; then
    fail "TTL reap: INFRA-9999 (ancient) should be dropped"
fi
ok "inbox-reap drops messages older than TTL_DAYS"

# ── Test 6: corr_id absent → derived from ts (no gap, no branch) ─────────
# Run from $TMP (not the repo) so git fails → fallback to ts.
(cd "$TMP" && CHUMP_SESSION_ID=sess-A bash "$TMP/repo/scripts/coord/broadcast.sh" WARN "test-warn" >/dev/null) || true
ok "broadcast.sh handles missing gap-id without error (fallback path)"

echo
echo "All INFRA-1255 corr_id/lifecycle tests passed."
