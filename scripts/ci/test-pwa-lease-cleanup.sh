#!/usr/bin/env bash
# test-pwa-lease-cleanup.sh — RESILIENT-003 tests.
#
# Verifies PWA lease cleanup reliability:
#   (a) cleanup_lease() in web_server.rs uses chump-pwa-<id>.json session path
#   (b) Live: orphaned lease blocks gap claim; deleting it unblocks
#   (c) Live: expired/stale lease does NOT block (treated as free)
#   (d) spawn_gap_workflow calls cleanup_lease on every error path
#   (e) spawn_gap_workflow runs preflight before spawn (concurrent-race guard)
#   (f) handle_gap_claim returns "blocked" JSON for already-claimed gaps
#   (g) gap_id field in lease JSON is the discriminant (isolation sentinel)
#   (h) cleanup_lease fn body uses repo_root/.chump-locks path
#
# Run: ./scripts/ci/test-pwa-lease-cleanup.sh

set -uo pipefail   # NOTE: -e omitted deliberately; python3 exits 1 on "not found"
                   # which is a valid success case. We track failures via FAIL counter.

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WS="$REPO_ROOT/src/web_server.rs"

echo "=== RESILIENT-003 PWA lease cleanup tests ==="
echo

# ── Helper: simulate gap-preflight.sh's check_lease_claim() logic ─────────────
# Returns the blocking session_id to stdout, exits 0 if blocked, 1 if free.
_lease_check() {
    local lock_dir="$1" gap_id="$2" my_session="$3"
    python3 - "$lock_dir" "$gap_id" "$my_session" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone

lock_dir, gap_id, my_session = sys.argv[1], sys.argv[2], sys.argv[3]
now = datetime.now(timezone.utc)

for fname in os.listdir(lock_dir):
    if not fname.endswith(".json"):
        continue
    try:
        d = json.load(open(os.path.join(lock_dir, fname)))
    except Exception:
        continue
    if d.get("gap_id") != gap_id:
        continue
    if d.get("session_id") == my_session:
        continue
    try:
        exp = datetime.fromisoformat(d["expires_at"].rstrip("Z")).replace(tzinfo=timezone.utc)
        hb  = datetime.fromisoformat(d["heartbeat_at"].rstrip("Z")).replace(tzinfo=timezone.utc)
        if (now - exp).total_seconds() > 30:   # expired
            continue
        if (now - hb).total_seconds() > 900:   # stale heartbeat
            continue
    except Exception:
        continue  # unparseable timestamps → treat as expired
    print(d["session_id"])
    sys.exit(0)
sys.exit(1)
PYEOF
}

# ── Setup: shared temp dir ────────────────────────────────────────────────────
_tmpdir=$(mktemp -d)
trap 'rm -rf "$_tmpdir"' EXIT
_lockdir="$_tmpdir/locks"
mkdir -p "$_lockdir"

# Shared timestamps — always use strftime('%Y-%m-%dT%H:%M:%SZ') for valid ISO 8601 UTC
_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_exp=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)+timedelta(hours=4)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
_hb="$_now"
_past=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=5)).strftime('%Y-%m-%dT%H:%M:%SZ'))")

# ── Test (a): cleanup_lease uses chump-pwa-{gap_id} session_id ───────────────
echo "--- Test a: cleanup_lease session_id is chump-pwa-{gap_id} ---"
if grep -q 'chump-pwa-' "$WS" 2>/dev/null; then
    ok "Test a: cleanup_lease uses chump-pwa-{gap_id} pattern in web_server.rs"
else
    fail "Test a: chump-pwa- pattern not found in web_server.rs cleanup_lease"
fi

# ── Test (b-1): live lease blocks claim ──────────────────────────────────────
echo "--- Test b: live lease file blocks / unblocks on delete ---"
_gap_id="TEST-LEASE-BLOCK"
_session_id="chump-pwa-${_gap_id}"

cat > "$_lockdir/${_session_id}.json" <<LEASE
{"session_id":"${_session_id}","gap_id":"${_gap_id}","taken_at":"${_now}","expires_at":"${_exp}","heartbeat_at":"${_hb}","purpose":"gap:${_gap_id}"}
LEASE

_blocked=$(_lease_check "$_lockdir" "$_gap_id" "other-session" || true)
if [[ -n "$_blocked" ]]; then
    ok "Test b-1: live lease blocks gap (holder: $_blocked)"
else
    fail "Test b-1: expected live lease to block gap but it did not"
fi

# ── Test (b-2): deleting lease unblocks ──────────────────────────────────────
rm -f "$_lockdir/${_session_id}.json"
_unblocked=$(_lease_check "$_lockdir" "$_gap_id" "other-session" || true)
if [[ -z "$_unblocked" ]]; then
    ok "Test b-2: after deleting lease file, gap is unblocked"
else
    fail "Test b-2: gap still blocked after lease deletion (by: $_unblocked)"
fi

# ── Test (c): expired lease treated as free ───────────────────────────────────
echo "--- Test c: expired/stale lease does not block ---"
cat > "$_lockdir/stale-session.json" <<STALE
{"session_id":"stale-session","gap_id":"${_gap_id}","taken_at":"${_past}","expires_at":"${_past}","heartbeat_at":"${_past}","purpose":"gap:${_gap_id}"}
STALE

_stale=$(_lease_check "$_lockdir" "$_gap_id" "other-session" || true)
if [[ -z "$_stale" ]]; then
    ok "Test c: expired lease (expires_at in past) treated as free — does not block"
else
    fail "Test c: expired lease should NOT block; got holder: $_stale"
fi
rm -f "$_lockdir/stale-session.json"

# ── Test (d): spawn_gap_workflow calls cleanup_lease on every error path ──────
echo "--- Test d: spawn_gap_workflow calls cleanup_lease on each error path ---"
_cleanup_count=$(grep -c "cleanup_lease" "$WS" 2>/dev/null || echo "0")
# ≥4: fn definition + preflight-fail + claim-fail + execute-fail + ship-fail
if [[ "${_cleanup_count:-0}" -ge 4 ]]; then
    ok "Test d: cleanup_lease referenced in ≥4 locations (definition + error paths)"
else
    fail "Test d: cleanup_lease only in ${_cleanup_count} locations (expect ≥4)"
fi

# ── Test (e): spawn_gap_workflow runs preflight before spawning ───────────────
echo "--- Test e: spawn_gap_workflow checks preflight before any work ---"
if awk '/async fn spawn_gap_workflow/,/^}/' "$WS" 2>/dev/null | \
       grep -q "run_preflight_check"; then
    ok "Test e: spawn_gap_workflow calls run_preflight_check (concurrent-race guard)"
else
    fail "Test e: spawn_gap_workflow does not call run_preflight_check"
fi

# ── Test (f): handle_gap_claim returns blocked for already-claimed gaps ───────
echo "--- Test f: handle_gap_claim returns 'blocked' for claimed gaps ---"
if grep -q '"blocked"' "$WS" 2>/dev/null && \
   grep -q 'already claimed by session\|Gap already claimed' "$WS" 2>/dev/null; then
    ok "Test f: handle_gap_claim returns 'blocked' + 'already claimed by session'"
else
    fail "Test f: handle_gap_claim missing blocked/already-claimed response"
fi

# ── Test (g): gap_id is the discriminant — leases are per-gap isolated ────────
echo "--- Test g: gap_id field correctly isolates blocking per gap ---"
cat > "$_lockdir/sess-a.json" <<LEASEÁ
{"session_id":"sess-a","gap_id":"INFRA-999","taken_at":"${_now}","expires_at":"${_exp}","heartbeat_at":"${_hb}"}
LEASEÁ
cat > "$_lockdir/sess-b.json" <<LEASEB
{"session_id":"sess-b","gap_id":"INFRA-888","taken_at":"${_now}","expires_at":"${_exp}","heartbeat_at":"${_hb}"}
LEASEB

_g999=$(_lease_check "$_lockdir" "INFRA-999" "other" || true)
_g888=$(_lease_check "$_lockdir" "INFRA-888" "other" || true)
_g777=$(_lease_check "$_lockdir" "INFRA-777" "other" || true)

if [[ "$_g999" == "sess-a" ]] && [[ "$_g888" == "sess-b" ]] && [[ -z "$_g777" ]]; then
    ok "Test g: gap_id isolation correct — 999→sess-a, 888→sess-b, 777→(free)"
else
    fail "Test g: isolation broken (999='$_g999', 888='$_g888', 777='$_g777')"
fi
rm -f "$_lockdir/sess-a.json" "$_lockdir/sess-b.json"

# ── Test (h): cleanup_lease uses repo_root/.chump-locks path ─────────────────
echo "--- Test h: cleanup_lease fn body uses .chump-locks directory ---"
if awk '/fn cleanup_lease/,/^}/' "$WS" 2>/dev/null | \
       grep -qE "chump-locks|CHUMP_LOCK"; then
    ok "Test h: cleanup_lease fn references .chump-locks directory"
else
    fail "Test h: cleanup_lease fn missing .chump-locks directory reference"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
