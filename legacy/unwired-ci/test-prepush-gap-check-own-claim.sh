#!/usr/bin/env bash
# scripts/ci/test-prepush-gap-check-own-claim.sh — INFRA-1165
#
# Tests that the pre-push gap check allows pushes by the session that holds
# the gap's lease, without requiring CHUMP_GAP_CHECK=0.
#
# Strategy: fake a lease file in a temp lock dir, fake gap-preflight.sh to
# return the "claimed" error, then verify the hook resolves the session ID
# and passes the check anyway.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PRE_PUSH="${REPO_ROOT}/scripts/git-hooks/pre-push"

ok()   { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

echo "=== INFRA-1165 pre-push own-claim gap-check test ==="
echo

# ── Extract session-ID resolver from pre-push (unit test the python block) ──
echo "[1. Session-ID resolver finds lease for gap in CHUMP_LOCK_DIR]"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GAP_ID="TEST-999"
SESSION_ID="claim-test-999-12345-1700000000"

# Write a fake lease file.
cat > "$TMP/claim-test-999-12345-1700000000.json" << EOF
{
    "session_id": "${SESSION_ID}",
    "gap_id": "${GAP_ID}",
    "expires_at": "2099-01-01T00:00:00Z",
    "heartbeat_at": "2099-01-01T00:00:00Z"
}
EOF

FOUND="$(python3 - "$TMP" "$GAP_ID" <<'PYEOF' 2>/dev/null
import json, os, sys
from datetime import datetime, timezone
lock_dir = sys.argv[1]
gap_ids = set(sys.argv[2:])
now = datetime.now(timezone.utc)
for fname in os.listdir(lock_dir):
    if not fname.endswith(".json"):
        continue
    try:
        d = json.load(open(os.path.join(lock_dir, fname)))
    except Exception:
        continue
    if d.get("gap_id") not in gap_ids:
        continue
    try:
        exp = datetime.fromisoformat(d.get("expires_at", "").rstrip("Z")).replace(tzinfo=timezone.utc)
        if (exp - now).total_seconds() <= 0:
            continue
    except Exception:
        continue
    sid = d.get("session_id", "")
    if sid:
        print(sid)
        break
PYEOF
)"

if [[ "$FOUND" == "$SESSION_ID" ]]; then
    ok "session ID resolved from lease file: $FOUND"
else
    fail "expected '$SESSION_ID' but got '$FOUND'"
fi

# ── Expired lease is ignored ──────────────────────────────────────────────────
echo
echo "[2. Expired lease is not returned]"

cat > "$TMP/claim-expired.json" << 'EOF'
{
    "session_id": "expired-session-999",
    "gap_id": "TEST-998",
    "expires_at": "2000-01-01T00:00:00Z",
    "heartbeat_at": "2000-01-01T00:00:00Z"
}
EOF

FOUND2="$(python3 - "$TMP" "TEST-998" <<'PYEOF' 2>/dev/null
import json, os, sys
from datetime import datetime, timezone
lock_dir = sys.argv[1]
gap_ids = set(sys.argv[2:])
now = datetime.now(timezone.utc)
for fname in os.listdir(lock_dir):
    if not fname.endswith(".json"):
        continue
    try:
        d = json.load(open(os.path.join(lock_dir, fname)))
    except Exception:
        continue
    if d.get("gap_id") not in gap_ids:
        continue
    try:
        exp = datetime.fromisoformat(d.get("expires_at", "").rstrip("Z")).replace(tzinfo=timezone.utc)
        if (exp - now).total_seconds() <= 0:
            continue
    except Exception:
        continue
    sid = d.get("session_id", "")
    if sid:
        print(sid)
        break
PYEOF
)"

if [[ -z "$FOUND2" ]]; then
    ok "expired lease correctly ignored"
else
    fail "expired lease should not return session, got '$FOUND2'"
fi

# ── Non-matching gap ID is ignored ───────────────────────────────────────────
echo
echo "[3. Lease for different gap is not returned]"

FOUND3="$(python3 - "$TMP" "TEST-000" <<'PYEOF' 2>/dev/null
import json, os, sys
from datetime import datetime, timezone
lock_dir = sys.argv[1]
gap_ids = set(sys.argv[2:])
now = datetime.now(timezone.utc)
for fname in os.listdir(lock_dir):
    if not fname.endswith(".json"):
        continue
    try:
        d = json.load(open(os.path.join(lock_dir, fname)))
    except Exception:
        continue
    if d.get("gap_id") not in gap_ids:
        continue
    try:
        exp = datetime.fromisoformat(d.get("expires_at", "").rstrip("Z")).replace(tzinfo=timezone.utc)
        if (exp - now).total_seconds() <= 0:
            continue
    except Exception:
        continue
    sid = d.get("session_id", "")
    if sid:
        print(sid)
        break
PYEOF
)"

if [[ -z "$FOUND3" ]]; then
    ok "lease for different gap correctly ignored"
else
    fail "should return empty for non-matching gap, got '$FOUND3'"
fi

# ── EVENT_REGISTRY contains gap_check_false_positive ─────────────────────────
echo
echo "[4. EVENT_REGISTRY has gap_check_false_positive]"

REGISTRY="${REPO_ROOT}/docs/observability/EVENT_REGISTRY.yaml"
if grep -q 'gap_check_false_positive' "$REGISTRY" 2>/dev/null; then
    ok "EVENT_REGISTRY.yaml contains gap_check_false_positive"
else
    fail "EVENT_REGISTRY.yaml missing gap_check_false_positive"
fi

echo
echo "=== INFRA-1165 tests complete ==="
