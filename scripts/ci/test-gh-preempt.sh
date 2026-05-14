#!/usr/bin/env bash
# scripts/ci/test-gh-preempt.sh — INFRA-1080
#
# Verifies the chump_gh pre-emptive backoff:
#   1. Critical calls (default) are NEVER preempted, even at low graphql
#   2. Background calls below threshold sleep + emit gh_preempted
#   3. Background calls above threshold proceed immediately
#   4. CHUMP_GH_NO_PREEMPT=1 bypasses
#   5. CHUMP_GH_BACKOFF_THRESHOLD override is honored
#   6. EVENT_REGISTRY.yaml registers gh_preempted

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/github.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Fake gh — `api rate_limit ...` returns "core graphql resets_at"
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" == "rate_limit" ]]; then
    echo "${FAKE_CORE:-4500} ${FAKE_GQL:-3000} ${FAKE_RESET:-0}"
    exit 0
fi
exit 0
EOF
chmod +x "$TMP/fakebin/gh"
export PATH="$TMP/fakebin:$PATH"
export CHUMP_GH_NO_PATH_INJECT=1
export CHUMP_AMBIENT_OVERRIDE="$TMP/ambient.jsonl"
export CHUMP_GH_SCRIPT="test-harness"

# shellcheck disable=SC1090
source "$LIB"

FUTURE_RESET="$(( $(date +%s) + 3600 ))"

# ── Test 1: critical call at low graphql — does NOT preempt ────────────────
rm -f "$CHUMP_AMBIENT_OVERRIDE"
START=$(date +%s)
FAKE_GQL=100 FAKE_RESET="$FUTURE_RESET" \
    CHUMP_GH_CALL_CRITICALITY=critical \
    _chump_gh_preempt_if_low "test-harness" "pr merge"
ELAPSED=$(( $(date +%s) - START ))
[[ "$ELAPSED" -lt 2 ]] || fail "critical call shouldn't sleep, but elapsed=${ELAPSED}s"
if [[ -f "$CHUMP_AMBIENT_OVERRIDE" ]]; then
    ! grep -q '"kind":"gh_preempted"' "$CHUMP_AMBIENT_OVERRIDE" \
        || fail "critical call emitted gh_preempted: $(cat "$CHUMP_AMBIENT_OVERRIDE")"
fi
ok "critical call at 2% graphql: NOT preempted, elapsed=${ELAPSED}s"

# ── Test 2: background call at low graphql — preempts ──────────────────────
# Stub gh so the SLEEP is short by setting near-now reset.
NEAR_RESET="$(( $(date +%s) + 2 ))"   # 2 seconds out
rm -f "$CHUMP_AMBIENT_OVERRIDE"
FAKE_GQL=100 FAKE_RESET="$NEAR_RESET" \
    CHUMP_GH_CALL_CRITICALITY=background \
    _chump_gh_preempt_if_low "test-harness" "pr list"
[[ -s "$CHUMP_AMBIENT_OVERRIDE" ]] || fail "background-low call should have emitted gh_preempted"
LINE=$(grep '"kind":"gh_preempted"' "$CHUMP_AMBIENT_OVERRIDE")
for f in '"kind":"gh_preempted"' '"script":"test-harness"' '"api":"pr list"' '"waited_s":' '"remaining_percent_before":' ; do
    grep -q "$f" <<<"$LINE" || fail "gh_preempted line missing $f: $LINE"
done
ok "background call at 2% graphql: preempts + emits gh_preempted with required fields"

# ── Test 3: background above threshold — proceeds immediately ──────────────
rm -f "$CHUMP_AMBIENT_OVERRIDE"
START=$(date +%s)
FAKE_GQL=4000 FAKE_RESET="$FUTURE_RESET" \
    CHUMP_GH_CALL_CRITICALITY=background \
    _chump_gh_preempt_if_low "test-harness" "pr list"
ELAPSED=$(( $(date +%s) - START ))
[[ "$ELAPSED" -lt 2 ]] || fail "background at 80% graphql shouldn't sleep, elapsed=${ELAPSED}s"
if [[ -f "$CHUMP_AMBIENT_OVERRIDE" ]]; then
    ! grep -q '"kind":"gh_preempted"' "$CHUMP_AMBIENT_OVERRIDE" \
        || fail "background at 80% shouldn't emit: $(cat "$CHUMP_AMBIENT_OVERRIDE")"
fi
ok "background call at 80% graphql: NOT preempted, elapsed=${ELAPSED}s"

# ── Test 4: CHUMP_GH_NO_PREEMPT=1 bypasses entirely ────────────────────────
rm -f "$CHUMP_AMBIENT_OVERRIDE"
START=$(date +%s)
FAKE_GQL=50 FAKE_RESET="$NEAR_RESET" \
    CHUMP_GH_CALL_CRITICALITY=background \
    CHUMP_GH_NO_PREEMPT=1 \
    _chump_gh_preempt_if_low "test-harness" "pr list"
ELAPSED=$(( $(date +%s) - START ))
[[ "$ELAPSED" -lt 2 ]] || fail "NO_PREEMPT bypass slept, elapsed=${ELAPSED}s"
ok "CHUMP_GH_NO_PREEMPT=1 bypasses entirely"

# ── Test 5: CHUMP_GH_BACKOFF_THRESHOLD raise — proceeds even at 5% ─────────
# Default threshold 10%. Set to 1% so 5% is "above threshold".
rm -f "$CHUMP_AMBIENT_OVERRIDE"
START=$(date +%s)
FAKE_GQL=250 FAKE_RESET="$NEAR_RESET" \
    CHUMP_GH_CALL_CRITICALITY=background \
    CHUMP_GH_BACKOFF_THRESHOLD=1 \
    _chump_gh_preempt_if_low "test-harness" "pr list"
ELAPSED=$(( $(date +%s) - START ))
[[ "$ELAPSED" -lt 2 ]] || fail "threshold=1, gql=5% should not preempt"
ok "CHUMP_GH_BACKOFF_THRESHOLD=1 + 5% remaining: no preempt"

# ── Test 6: EVENT_REGISTRY registers gh_preempted ──────────────────────────
grep -q 'kind: gh_preempted' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
    || fail "EVENT_REGISTRY missing gh_preempted"
ok "EVENT_REGISTRY registers gh_preempted"

echo
echo "All INFRA-1080 gh-preempt tests passed."
