#!/usr/bin/env bash
# scripts/ci/test-pwa-stuck-items.sh — PRODUCT-080
#
# CI test for the PWA stuck-items alerter.
#
# Strategy:
#   1. Create a synthetic ambient.jsonl with one event of each stuck kind.
#   2. Start chump --web on a random port with the synthetic ambient.
#   3. Poll GET /api/stuck — assert all stuck kinds surface.
#   4. Stub rescue scripts with mocks that just echo and exit 0.
#   5. POST /api/stuck/rescue/{id} for each kind — assert ok=true.
#   6. Verify ambient.jsonl grew operator_rescue_invoked + rescue_result events.
#
# Exits 0 on all-pass, 1 on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Helpers ────────────────────────────────────────────────────────────────────

pass() { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[34m…\033[0m %s\n' "$*"; }

# ── Temp workspace ─────────────────────────────────────────────────────────────

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

AMBIENT_DIR="${TMPDIR_TEST}/.chump-locks"
mkdir -p "$AMBIENT_DIR"
AMBIENT_FILE="${AMBIENT_DIR}/ambient.jsonl"

# ── 1. Synthesise ambient events ───────────────────────────────────────────────

NOW_EPOCH="$(date -u +%s 2>/dev/null || python3 -c 'import time; print(int(time.time()))')"

# pr_stuck: must be > 4 hours old (14402 seconds ago)
PR_STUCK_TS="$(date -u -r $((NOW_EPOCH - 14402)) '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || python3 -c "import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(seconds=14402)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"

# Other stuck events — 1 hour old
HOUR_AGO_TS="$(date -u -r $((NOW_EPOCH - 3600)) '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || python3 -c "import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"

cat > "$AMBIENT_FILE" <<EOF
{"ts":"${PR_STUCK_TS}","kind":"pr_stuck","pr":"42","branch":"fix/something"}
{"ts":"${HOUR_AGO_TS}","kind":"silent_agent","session":"fleet-worker-3"}
{"ts":"${HOUR_AGO_TS}","kind":"lease_expired_server","gap":"INFRA-999"}
{"ts":"${HOUR_AGO_TS}","kind":"fat_worktree","path":"/tmp/chump-foo"}
{"ts":"${HOUR_AGO_TS}","kind":"disk_critical","free_gb":"1.2"}
{"ts":"${HOUR_AGO_TS}","kind":"reaper_silent","last_run_secs":"7200"}
{"ts":"${HOUR_AGO_TS}","kind":"fleet_wedge","workers":"3"}
{"ts":"${HOUR_AGO_TS}","kind":"fleet_wedge_resolved"}
EOF

pass "Synthetic ambient.jsonl written with all 7 stuck kinds"

# ── 2. Mock rescue scripts ─────────────────────────────────────────────────────

MOCK_SCRIPTS_DIR="${TMPDIR_TEST}/scripts/coord"
mkdir -p "$MOCK_SCRIPTS_DIR"

for script_name in pr-rescue.sh worktree-prune.sh stale-lease-reaper.sh ghost-gap-reaper.sh; do
  cat > "${MOCK_SCRIPTS_DIR}/${script_name}" <<'MOCK'
#!/usr/bin/env bash
echo "mock-rescue: $0 $*"
exit 0
MOCK
  chmod +x "${MOCK_SCRIPTS_DIR}/${script_name}"
done

pass "Mock rescue scripts created"

# ── 3. Build and start the web server ─────────────────────────────────────────

# Find a free port
FREE_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')"

info "Building chump binary (may take a moment)…"
if ! cargo build --bin chump --quiet 2>&1 | tail -5; then
  fail "cargo build failed"
fi

# Start server in background.
export CHUMP_AMBIENT_LOG="$AMBIENT_FILE"
export CHUMP_REPO="$REPO_ROOT"
export CHUMP_WEB_PORT="$FREE_PORT"
export CHUMP_WEB_TOKEN=""        # no auth for test
export CHUMP_SCRIPTS_COORD_DIR="${MOCK_SCRIPTS_DIR}"  # point to mocks

# Override scripts/coord path by prepending mock dir to PATH search; the Rust
# code uses repo_root.join("scripts/coord/...") directly, so we need a different
# approach: symlink the coord dir into TMPDIR_TEST/scripts/coord and set CHUMP_REPO
# to TMPDIR_TEST for rescue-script lookups only. We'll patch via env var used in
# the handler if available, or just copy scripts into the expected location.
MOCK_REPO="${TMPDIR_TEST}/repo"
mkdir -p "${MOCK_REPO}/scripts/coord"
for f in "${MOCK_SCRIPTS_DIR}"/*.sh; do
  cp "$f" "${MOCK_REPO}/scripts/coord/"
done

export CHUMP_REPO="${MOCK_REPO}"

"${REPO_ROOT}/target/debug/chump" --web --port "$FREE_PORT" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMPDIR_TEST"' EXIT

# Wait for server to be ready.
BASE_URL="http://127.0.0.1:${FREE_PORT}"
for i in $(seq 1 30); do
  if curl -sf "${BASE_URL}/api/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
if ! curl -sf "${BASE_URL}/api/health" >/dev/null 2>&1; then
  fail "Server did not start in time on port ${FREE_PORT}"
fi
pass "Web server started on port ${FREE_PORT}"

# ── 4. GET /api/stuck — assert all kinds surface ───────────────────────────────

STUCK_RESPONSE="$(curl -sf "${BASE_URL}/api/stuck" \
  -H "x-csrf-token: test" 2>/dev/null)"

if [ -z "$STUCK_RESPONSE" ]; then
  fail "GET /api/stuck returned empty response"
fi

ITEM_COUNT="$(echo "$STUCK_RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['count'])")"
if [ "$ITEM_COUNT" -lt 7 ]; then
  fail "Expected >= 7 stuck items, got ${ITEM_COUNT}. Response: ${STUCK_RESPONSE}"
fi
pass "GET /api/stuck returned ${ITEM_COUNT} items (>= 7 expected)"

# Assert each expected kind surfaces.
for kind in pr_stuck silent_agent lease_expired_server fat_worktree disk_critical reaper_silent fleet_wedge; do
  if ! echo "$STUCK_RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
kinds = [it['kind'] for it in d['items']]
assert '${kind}' in kinds, f'kind ${kind} not found in {kinds}'
"; then
    fail "Kind '${kind}' not found in /api/stuck response"
  fi
  pass "Kind '${kind}' surfaces in stuck list"
done

# Assert severity fields present.
if ! echo "$STUCK_RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for it in d['items']:
  assert it.get('severity') in ('HIGH','MED','LOW'), f'bad severity: {it}'
  assert isinstance(it.get('age_secs'), int), f'missing age_secs: {it}'
  assert it.get('rescue_action'), f'missing rescue_action: {it}'
"; then
  fail "Severity/age/rescue_action fields invalid"
fi
pass "All items have valid severity, age_secs, rescue_action fields"

# Assert pr_stuck has PR number.
if ! echo "$STUCK_RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
pr_items = [it for it in d['items'] if it['kind'] == 'pr_stuck']
assert pr_items, 'no pr_stuck items'
assert pr_items[0].get('pr') == '42', f'pr mismatch: {pr_items[0]}'
"; then
  fail "pr_stuck item missing PR number"
fi
pass "pr_stuck item has correct PR number"

# Assert empty_state is null (we have items).
if ! echo "$STUCK_RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('empty_state') is None, f'expected null empty_state, got: {d[\"empty_state\"]}'
"; then
  fail "empty_state should be null when items present"
fi
pass "empty_state is null when items present"

# ── 5. Test empty-state with no events ────────────────────────────────────────

# Truncate ambient to only a fleet_wedge_resolved event.
cat > "$AMBIENT_FILE" <<EOF
{"ts":"${HOUR_AGO_TS}","kind":"fleet_wedge_resolved"}
EOF

EMPTY_RESPONSE="$(curl -sf "${BASE_URL}/api/stuck" -H "x-csrf-token: test" 2>/dev/null)"
if ! echo "$EMPTY_RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['count'] == 0, f'expected 0 items, got {d[\"count\"]}'
msg = d.get('empty_state') or ''
assert 'Nothing stuck' in msg, f'bad empty_state: {msg}'
assert 'ago' in msg, f'expected resolved-time in message: {msg}'
"; then
  fail "Empty state not correct: ${EMPTY_RESPONSE}"
fi
pass "Empty state shows 'Nothing stuck. Last wedge resolved Nh ago.'"

# Restore full ambient.
cat > "$AMBIENT_FILE" <<EOF
{"ts":"${PR_STUCK_TS}","kind":"pr_stuck","pr":"42","branch":"fix/something"}
{"ts":"${HOUR_AGO_TS}","kind":"silent_agent","session":"fleet-worker-3"}
{"ts":"${HOUR_AGO_TS}","kind":"lease_expired_server","gap":"INFRA-999"}
{"ts":"${HOUR_AGO_TS}","kind":"fat_worktree","path":"/tmp/chump-foo"}
{"ts":"${HOUR_AGO_TS}","kind":"disk_critical","free_gb":"1.2"}
{"ts":"${HOUR_AGO_TS}","kind":"reaper_silent","last_run_secs":"7200"}
{"ts":"${HOUR_AGO_TS}","kind":"fleet_wedge","workers":"3"}
{"ts":"${HOUR_AGO_TS}","kind":"fleet_wedge_resolved"}
EOF

# ── 6. POST /api/stuck/rescue/{id} — invoke rescue for each kind ───────────────

STUCK_ITEMS="$(curl -sf "${BASE_URL}/api/stuck" -H "x-csrf-token: test" 2>/dev/null)"
ITEM_IDS="$(echo "$STUCK_ITEMS" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for it in d['items']:
    print(it['id'] + '|' + it['kind'])
")"

while IFS='|' read -r item_id item_kind; do
  RESCUE_BODY="{\"kind\":\"${item_kind}\"}"
  if [ "$item_kind" = "pr_stuck" ]; then
    RESCUE_BODY="{\"kind\":\"${item_kind}\",\"pr\":\"42\"}"
  fi

  RESCUE_RESP="$(curl -sf -X POST "${BASE_URL}/api/stuck/rescue/${item_id}" \
    -H "Content-Type: application/json" \
    -H "x-csrf-token: test" \
    -d "$RESCUE_BODY" 2>/dev/null)"

  if ! echo "$RESCUE_RESP" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d.get('ok') == True, f'rescue failed: {d}'
assert d.get('rescue_id'), 'missing rescue_id'
"; then
    fail "Rescue failed for kind=${item_kind}: ${RESCUE_RESP}"
  fi
  pass "Rescue OK for kind=${item_kind}"
done <<< "$ITEM_IDS"

# ── 7. Verify ambient events were emitted ─────────────────────────────────────

AMBIENT_CONTENT="$(cat "$AMBIENT_FILE")"
RESCUE_INVOKED_COUNT="$(echo "$AMBIENT_CONTENT" | grep -c '"kind":"operator_rescue_invoked"' || true)"
RESCUE_RESULT_COUNT="$(echo "$AMBIENT_CONTENT" | grep -c '"kind":"rescue_result"' || true)"

if [ "$RESCUE_INVOKED_COUNT" -lt 1 ]; then
  fail "Expected >= 1 operator_rescue_invoked events in ambient.jsonl, got ${RESCUE_INVOKED_COUNT}"
fi
pass "operator_rescue_invoked events emitted: ${RESCUE_INVOKED_COUNT}"

if [ "$RESCUE_RESULT_COUNT" -lt 1 ]; then
  fail "Expected >= 1 rescue_result events in ambient.jsonl, got ${RESCUE_RESULT_COUNT}"
fi
pass "rescue_result events emitted: ${RESCUE_RESULT_COUNT}"

# ── 8. CSRF gate test ─────────────────────────────────────────────────────────

# First item from the list.
FIRST_ITEM="$(echo "$ITEM_IDS" | head -1)"
FIRST_ID="${FIRST_ITEM%|*}"
FIRST_KIND="${FIRST_ITEM#*|}"

HTTP_STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "${BASE_URL}/api/stuck/rescue/${FIRST_ID}" \
  -H "Content-Type: application/json" \
  -d "{\"kind\":\"${FIRST_KIND}\"}" 2>/dev/null)"

if [ "$HTTP_STATUS" != "403" ]; then
  fail "Expected 403 without CSRF token, got ${HTTP_STATUS}"
fi
pass "CSRF gate blocks rescue without x-csrf-token (HTTP 403)"

# ── Done ───────────────────────────────────────────────────────────────────────

printf '\n\033[32m✓ All test-pwa-stuck-items checks passed.\033[0m\n'
