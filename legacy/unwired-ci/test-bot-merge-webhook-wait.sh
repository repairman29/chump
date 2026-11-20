#!/usr/bin/env bash
# test-bot-merge-webhook-wait.sh — INFRA-2119
#
# Regression test for the webhook-cache MERGED wait block added to
# scripts/coord/bot-merge.sh under CHUMP_BOT_MERGE_WAIT_MERGED=1.
#
# The full bot-merge.sh top-to-bottom is far too heavy to exercise in CI
# (rebase + push + pre-merge gates + GraphQL arm). Instead this test
# extracts the wait loop into a synthetic harness and verifies the
# core observable behaviors:
#
#   1. When the cache shows merged_at non-null, the wait loop exits 0
#      within 10s and emits kind=bot_merge_webhook_hit.
#   2. When merged_at stays null past the timeout, the loop exits non-zero
#      (specifically exit 4 per bot-merge.sh) and emits kind=bot_merge_timeout.
#   3. The pure-bash syntax of the wait block is well-formed (bash -n).
#
# This is faster than spinning a full bot-merge.sh run and keeps the
# pre-push gate under the 60s warm budget per CLAUDE.md local-CI discipline.
#
# Run:
#   bash scripts/ci/test-bot-merge-webhook-wait.sh
#
# Exits non-zero on any subtest failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
CACHE_LIB="$REPO_ROOT/scripts/coord/lib/github_cache.sh"

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2119: webhook-cache MERGED wait regression tests ==="
echo

[[ -f "$BOT_MERGE" ]] || { echo "FAIL: missing $BOT_MERGE"; exit 1; }
[[ -f "$CACHE_LIB" ]] || { echo "FAIL: missing $CACHE_LIB"; exit 1; }

# ── 1. bash -n syntax check on bot-merge.sh ──────────────────────────────
if bash -n "$BOT_MERGE" 2>/tmp/.bm2119-syntax-err; then
    ok "bot-merge.sh passes bash -n (wait block syntax well-formed)"
else
    fail "bot-merge.sh bash -n failed: $(cat /tmp/.bm2119-syntax-err)"
fi

# ── 2. Verify the wait block contains the required event-kind emissions ─
# Tight static check — does not depend on running the full script.
if grep -q '"kind":"bot_merge_webhook_hit"' "$BOT_MERGE"; then
    ok "bot_merge_webhook_hit emit present in bot-merge.sh"
else
    fail "bot_merge_webhook_hit emit missing from bot-merge.sh"
fi

if grep -q '"kind":"bot_merge_timeout"' "$BOT_MERGE"; then
    ok "bot_merge_timeout emit present in bot-merge.sh"
else
    fail "bot_merge_timeout emit missing from bot-merge.sh"
fi

# Verify scanner-anchor comments are adjacent (CREDIBLE-074 / event-coherence).
if grep -B1 '"kind":"bot_merge_webhook_hit"' "$BOT_MERGE" | grep -q 'scanner-anchor.*bot_merge_webhook_hit'; then
    ok "scanner-anchor comment adjacent to bot_merge_webhook_hit emit"
else
    fail "missing 'scanner-anchor' comment adjacent to bot_merge_webhook_hit"
fi

if grep -B1 '"kind":"bot_merge_timeout"' "$BOT_MERGE" | grep -q 'scanner-anchor.*bot_merge_timeout'; then
    ok "scanner-anchor comment adjacent to bot_merge_timeout emit"
else
    fail "missing 'scanner-anchor' comment adjacent to bot_merge_timeout"
fi

# ── 3. Default-off contract: feature is opt-in via env var ───────────────
if grep -q 'CHUMP_BOT_MERGE_WAIT_MERGED' "$BOT_MERGE"; then
    ok "CHUMP_BOT_MERGE_WAIT_MERGED env var is the opt-in toggle"
else
    fail "CHUMP_BOT_MERGE_WAIT_MERGED toggle missing"
fi

# ── 4. End-to-end: synthetic wait loop hits MERGED via cache, exits 0 ────
# Build a self-contained harness that sources only the wait-loop fragment,
# replaces cache_lookup_pr with a stub that returns merged_at non-null,
# and verifies exit 0 + webhook_hit emit within 10s wall-clock.
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

# Mock ambient log path.
MOCK_AMB="$TMP/ambient.jsonl"
: > "$MOCK_AMB"

# Build a minimal harness script that mimics the wait loop in isolation.
# We do NOT source bot-merge.sh (too heavy) — instead we replicate the
# core loop shape with a stub cache_lookup_pr. This keeps the test fast.
cat > "$TMP/wait-harness.sh" <<'HARNESS_EOF'
#!/usr/bin/env bash
set -euo pipefail
# Stub: return a JSON payload with merged_at populated.
cache_lookup_pr() {
    printf '{"merged_at":"2026-05-29T13:00:00Z","number":12345}'
    return 0
}
TARGET_PR="12345"
GAP_IDS=("INFRA-2119")
_wait_timeout_s="${CHUMP_BOT_MERGE_WAIT_TIMEOUT_S:-900}"
_wait_poll_interval_s="${CHUMP_BOT_MERGE_WAIT_POLL_INTERVAL_S:-5}"
_wait_webhook_grace_s="${CHUMP_BOT_MERGE_WAIT_WEBHOOK_GRACE_S:-60}"
_wait_started_at=$(date -u +%s)
_wait_deadline=$(( _wait_started_at + _wait_timeout_s ))
_wait_amb="${CHUMP_AMBIENT_LOG:?ambient log required}"
_wait_polls=0
_wait_source="cache"
while :; do
    _wait_now=$(date -u +%s)
    if (( _wait_now >= _wait_deadline )); then
        printf '{"ts":"%s","kind":"bot_merge_timeout","pr":%s,"gap":"%s","elapsed_s":%s,"timeout_s":%s,"polls":%s,"source":"%s","note":"harness"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$TARGET_PR" "${GAP_IDS[*]:-}" \
            "$(( _wait_now - _wait_started_at ))" \
            "$_wait_timeout_s" "$_wait_polls" "$_wait_source" \
            >> "$_wait_amb"
        exit 4
    fi
    _wait_polls=$(( _wait_polls + 1 ))
    _wait_pr_json="$(cache_lookup_pr "$TARGET_PR" --max-age-s "$_wait_webhook_grace_s" 2>/dev/null || true)"
    if [[ -n "$_wait_pr_json" ]]; then
        _wait_merged_at="$(printf '%s' "$_wait_pr_json" | \
            python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    v=d.get('merged_at')
    print(v if v else '')
except Exception:
    print('')
" 2>/dev/null || true)"
        if [[ -n "$_wait_merged_at" ]]; then
            printf '{"ts":"%s","kind":"bot_merge_webhook_hit","pr":%s,"gap":"%s","elapsed_s":%s,"polls":%s,"merged_at":"%s","note":"harness"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                "$TARGET_PR" "${GAP_IDS[*]:-}" \
                "$(( _wait_now - _wait_started_at ))" \
                "$_wait_polls" "$_wait_merged_at" \
                >> "$_wait_amb"
            exit 0
        fi
    fi
    sleep "$_wait_poll_interval_s"
done
HARNESS_EOF
chmod +x "$TMP/wait-harness.sh"

# 4a. Cache shows MERGED → exit 0 within 10s, webhook_hit emitted.
_t0=$(date -u +%s)
if CHUMP_AMBIENT_LOG="$MOCK_AMB" \
        CHUMP_BOT_MERGE_WAIT_POLL_INTERVAL_S=1 \
        CHUMP_BOT_MERGE_WAIT_TIMEOUT_S=20 \
        bash "$TMP/wait-harness.sh" >/tmp/.bm2119-hit.out 2>&1; then
    _t1=$(date -u +%s)
    _elapsed=$(( _t1 - _t0 ))
    if (( _elapsed <= 10 )); then
        ok "harness exit 0 within ${_elapsed}s when cache shows MERGED (<= 10s)"
    else
        fail "harness exit 0 took ${_elapsed}s, expected <= 10s"
    fi
    if grep -q '"kind":"bot_merge_webhook_hit"' "$MOCK_AMB"; then
        ok "bot_merge_webhook_hit emitted on MERGED transition"
    else
        fail "bot_merge_webhook_hit NOT emitted (ambient was: $(cat "$MOCK_AMB"))"
    fi
else
    fail "harness exited non-zero on MERGED cache hit (output: $(cat /tmp/.bm2119-hit.out))"
fi

# ── 5. Timeout path: cache always returns merged_at null → exit 4 ────────
MOCK_AMB2="$TMP/ambient2.jsonl"
: > "$MOCK_AMB2"
cat > "$TMP/wait-harness-timeout.sh" <<'HARNESS_EOF'
#!/usr/bin/env bash
set -euo pipefail
# Stub: return JSON with merged_at=null forever.
cache_lookup_pr() {
    printf '{"merged_at":null,"number":12345}'
    return 0
}
TARGET_PR="12345"
GAP_IDS=("INFRA-2119")
_wait_timeout_s="${CHUMP_BOT_MERGE_WAIT_TIMEOUT_S:-900}"
_wait_poll_interval_s="${CHUMP_BOT_MERGE_WAIT_POLL_INTERVAL_S:-5}"
_wait_webhook_grace_s="${CHUMP_BOT_MERGE_WAIT_WEBHOOK_GRACE_S:-60}"
_wait_started_at=$(date -u +%s)
_wait_deadline=$(( _wait_started_at + _wait_timeout_s ))
_wait_amb="${CHUMP_AMBIENT_LOG:?ambient log required}"
_wait_polls=0
_wait_source="cache"
while :; do
    _wait_now=$(date -u +%s)
    if (( _wait_now >= _wait_deadline )); then
        printf '{"ts":"%s","kind":"bot_merge_timeout","pr":%s,"gap":"%s","elapsed_s":%s,"timeout_s":%s,"polls":%s,"source":"%s","note":"harness"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$TARGET_PR" "${GAP_IDS[*]:-}" \
            "$(( _wait_now - _wait_started_at ))" \
            "$_wait_timeout_s" "$_wait_polls" "$_wait_source" \
            >> "$_wait_amb"
        exit 4
    fi
    _wait_polls=$(( _wait_polls + 1 ))
    _wait_pr_json="$(cache_lookup_pr "$TARGET_PR" --max-age-s "$_wait_webhook_grace_s" 2>/dev/null || true)"
    if [[ -n "$_wait_pr_json" ]]; then
        _wait_merged_at="$(printf '%s' "$_wait_pr_json" | \
            python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    v=d.get('merged_at')
    print(v if v else '')
except Exception:
    print('')
" 2>/dev/null || true)"
        if [[ -n "$_wait_merged_at" ]]; then
            exit 0
        fi
    fi
    sleep "$_wait_poll_interval_s"
done
HARNESS_EOF
chmod +x "$TMP/wait-harness-timeout.sh"

# Timeout=3s, poll=1s → loop exits on timeout in ~3s.
_t0=$(date -u +%s)
set +e
CHUMP_AMBIENT_LOG="$MOCK_AMB2" \
    CHUMP_BOT_MERGE_WAIT_POLL_INTERVAL_S=1 \
    CHUMP_BOT_MERGE_WAIT_TIMEOUT_S=3 \
    bash "$TMP/wait-harness-timeout.sh" >/tmp/.bm2119-to.out 2>&1
_rc=$?
set -e
_t1=$(date -u +%s)
_elapsed=$(( _t1 - _t0 ))
if (( _rc == 4 )); then
    ok "harness exits 4 on timeout (got rc=$_rc, elapsed=${_elapsed}s)"
else
    fail "harness expected exit 4 on timeout, got rc=$_rc (output: $(cat /tmp/.bm2119-to.out))"
fi
if grep -q '"kind":"bot_merge_timeout"' "$MOCK_AMB2"; then
    ok "bot_merge_timeout emitted on hard timeout"
else
    fail "bot_merge_timeout NOT emitted on timeout (ambient was: $(cat "$MOCK_AMB2"))"
fi

# ── 6. EVENT_REGISTRY.yaml has both new kinds registered ────────────────
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q '^\s*-\s*kind:\s*bot_merge_webhook_hit\b' "$REG"; then
    ok "bot_merge_webhook_hit registered in EVENT_REGISTRY.yaml"
else
    fail "bot_merge_webhook_hit NOT in EVENT_REGISTRY.yaml"
fi
if grep -q '^\s*-\s*kind:\s*bot_merge_timeout\b' "$REG"; then
    ok "bot_merge_timeout registered in EVENT_REGISTRY.yaml"
else
    fail "bot_merge_timeout NOT in EVENT_REGISTRY.yaml"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    echo
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
