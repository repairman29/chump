#!/usr/bin/env bash
# scripts/ci/test-gh-self-throttle.sh — INFRA-1079
#
# Verifies the chump_gh self-throttle:
#   1. Below the limit, the throttle returns immediately
#   2. At the limit, _chump_gh_throttle_wait sleeps + emits gh_self_throttled
#   3. CHUMP_GH_NO_THROTTLE=1 bypasses entirely
#   4. Per-script override CHUMP_GH_THROTTLE_<SCRIPT>=N raises limit
#   5. EVENT_REGISTRY.yaml registers gh_self_throttled
#
# Uses a PATH-shim fake gh so no network calls.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/github.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Fake gh (no-op for the calls + canned rate_limit)
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "api" && "${2:-}" == "rate_limit" ]] && { echo "4000 4000 0"; exit 0; }
exit 0
EOF
chmod +x "$TMP/fakebin/gh"
export PATH="$TMP/fakebin:$PATH"
export CHUMP_GH_NO_PATH_INJECT=1
export CHUMP_AMBIENT_OVERRIDE="$TMP/ambient.jsonl"
export CHUMP_GH_SCRIPT="test-harness"

# shellcheck disable=SC1090
source "$LIB"

LOCK_DIR="$(dirname "$CHUMP_AMBIENT_OVERRIDE")"

# ── Test 1: under-limit calls fire immediately, no event ────────────────────
rm -f "$CHUMP_AMBIENT_OVERRIDE" "$LOCK_DIR/.gh-throttle-window" "$LOCK_DIR/.gh-throttle.lock"
for i in 1 2 3 4 5; do _chump_gh_throttle_wait "test-harness"; done
# Verify by ABSENCE of throttle event (timing varies with python3 startup).
if [[ -f "$CHUMP_AMBIENT_OVERRIDE" ]]; then
    ! grep -q '"kind":"gh_self_throttled"' "$CHUMP_AMBIENT_OVERRIDE" \
        || fail "should not throw throttle with 5 calls (default limit 60): $(cat "$CHUMP_AMBIENT_OVERRIDE")"
fi
# Verify window file has at least 5 entries (3 may have been pruned, but
# python3 timing should keep them all within 60s).
ENTRIES=$(python3 -c "import json; print(len(json.load(open('$LOCK_DIR/.gh-throttle-window'))))" 2>/dev/null)
[[ "$ENTRIES" -ge 5 ]] || fail "window file should have >=5 entries, got $ENTRIES"
ok "5 calls under default 60/min limit: no throttle, window=${ENTRIES} entries"

# ── Test 2: at the limit, throttle fires + emits event ──────────────────────
rm -f "$CHUMP_AMBIENT_OVERRIDE"
# Pre-fill window with 3 timestamps; limit=3 → next call must wait.
NOW=$(python3 -c "import time;print(time.time())")
python3 -c "import json; json.dump([${NOW}, ${NOW}, ${NOW}], open('$LOCK_DIR/.gh-throttle-window','w'))"
# Run in background with timeout so we don't burn 30s.
CHUMP_GH_MAX_CALLS_PER_MIN=3 timeout 3 bash -c "
source '$LIB'
CHUMP_AMBIENT_OVERRIDE='$CHUMP_AMBIENT_OVERRIDE' _chump_gh_throttle_wait test-harness
" >/dev/null 2>&1 || true
sleep 0.3
[[ -f "$CHUMP_AMBIENT_OVERRIDE" ]] || fail "no ambient.jsonl at $CHUMP_AMBIENT_OVERRIDE"
grep -q '"kind":"gh_self_throttled"' "$CHUMP_AMBIENT_OVERRIDE" \
    || fail "expected gh_self_throttled with limit=3 window=3: $(cat "$CHUMP_AMBIENT_OVERRIDE")"
grep -q '"script":"test-harness"' "$CHUMP_AMBIENT_OVERRIDE" \
    || fail "script field missing: $(cat "$CHUMP_AMBIENT_OVERRIDE")"
ok "limit=3 with 3-entry window: throttle fires + emits gh_self_throttled"

# ── Test 3: CHUMP_GH_NO_THROTTLE=1 bypasses ─────────────────────────────────
rm -f "$CHUMP_AMBIENT_OVERRIDE"
python3 -c "import json,time; n=time.time(); json.dump([n,n,n,n,n,n,n,n,n,n], open('$LOCK_DIR/.gh-throttle-window','w'))"
START=$(date +%s)
CHUMP_GH_NO_THROTTLE=1 CHUMP_GH_MAX_CALLS_PER_MIN=3 _chump_gh_throttle_wait "test-harness"
ELAPSED=$(( $(date +%s) - START ))
[[ "$ELAPSED" -lt 2 ]] || fail "NO_THROTTLE bypass took ${ELAPSED}s, expected immediate"
if [[ -f "$CHUMP_AMBIENT_OVERRIDE" ]]; then
    ! grep -q gh_self_throttled "$CHUMP_AMBIENT_OVERRIDE" \
        || fail "CHUMP_GH_NO_THROTTLE=1 should NOT emit throttle"
fi
ok "CHUMP_GH_NO_THROTTLE=1 bypasses entirely"

# ── Test 4: per-script override raises limit ────────────────────────────────
rm -f "$CHUMP_AMBIENT_OVERRIDE"
python3 -c "import json,time; n=time.time(); json.dump([n,n,n,n,n], open('$LOCK_DIR/.gh-throttle-window','w'))"
START=$(date +%s)
# Default 3 < 5 → would throttle. Override script-specific to 100 → no throttle.
CHUMP_GH_MAX_CALLS_PER_MIN=3 CHUMP_GH_THROTTLE_TEST_HARNESS=100 _chump_gh_throttle_wait "test-harness"
ELAPSED=$(( $(date +%s) - START ))
[[ "$ELAPSED" -lt 2 ]] || fail "per-script override didn't raise limit (${ELAPSED}s)"
ok "CHUMP_GH_THROTTLE_<SCRIPT>=N override raises script-specific limit"

# ── Test 5: EVENT_REGISTRY registers gh_self_throttled ──────────────────────
grep -q 'kind: gh_self_throttled' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
    || fail "EVENT_REGISTRY missing gh_self_throttled"
ok "EVENT_REGISTRY registers gh_self_throttled"

echo
echo "All INFRA-1079 gh-self-throttle tests passed."
