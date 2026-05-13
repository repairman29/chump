#!/usr/bin/env bash
# scripts/ci/test-graphql-exhausted-signal.sh — INFRA-1040
#
# Verifies the graphql_exhausted signal on top of the INFRA-999 chump_gh wrapper:
#   1. With graphql_remaining > threshold, no event fires.
#   2. With graphql_remaining = 0, exactly one event fires on the first call.
#   3. Subsequent calls in the same reset window are debounced (flag file).
#   4. Event has all required fields per EVENT_REGISTRY.
#   5. CHUMP_GH_EXHAUSTED_THRESHOLD env override raises the trigger threshold.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/github.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

AMB="$TMP/ambient.jsonl"
LOCK_DIR="$TMP"                    # _chump_gh_maybe_emit_exhausted reads .graphql-exhausted-since from dirname(ambient)
FUTURE_RESET="$(( $(date +%s) + 3600 ))"   # 1h from now

# Fake `gh` on PATH. Reads the desired core / graphql / resets values from
# env vars set per-call so each test case can dial them independently.
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
# Honor only `gh api rate_limit --jq ...` (the chump_gh helper) + everything else exits 0.
if [[ "${1:-}" == "api" && "${2:-}" == "rate_limit" ]]; then
    echo "${FAKE_CORE:-4500} ${FAKE_GQL:-3000} ${FAKE_RESET:-0}"
    exit 0
fi
exit 0
EOF
chmod +x "$TMP/fakebin/gh"
# Disable the PATH-injected gh-shim in the lib so it falls through to our fake.
export CHUMP_GH_NO_PATH_INJECT=1
export PATH="$TMP/fakebin:$PATH"
export CHUMP_AMBIENT_OVERRIDE="$AMB"

# shellcheck disable=SC1090
source "$LIB"

# ── Test 1: above threshold → no event ───────────────────────────────────────
rm -f "$AMB" "$TMP/.graphql-exhausted-since"
FAKE_CORE=4500 FAKE_GQL=3000 FAKE_RESET="$FUTURE_RESET" \
    chump_gh_record "pr view" 50 0 "test-harness"
grep -q '"kind":"graphql_exhausted"' "$AMB" \
    && fail "exhausted event fired with remaining=3000 (above threshold): $(cat "$AMB")"
ok "remaining=3000 (above threshold 100): no exhausted event"

# ── Test 2: at zero → event fires exactly once ───────────────────────────────
rm -f "$AMB" "$TMP/.graphql-exhausted-since"
FAKE_CORE=4500 FAKE_GQL=0 FAKE_RESET="$FUTURE_RESET" \
    chump_gh_record "pr view" 50 1 "test-harness"
n=$(grep -c '"kind":"graphql_exhausted"' "$AMB" 2>/dev/null || echo 0)
[[ "$n" -eq 1 ]] || fail "expected 1 exhausted event, got $n: $(cat "$AMB")"
ok "remaining=0: exactly one graphql_exhausted event fires"

# ── Test 3: required fields ──────────────────────────────────────────────────
line="$(grep '"kind":"graphql_exhausted"' "$AMB")"
for f in '"ts":' '"kind":"graphql_exhausted"' '"threshold_seen":0' '"resets_at":"' '"source":"' ; do
    grep -q "$f" <<<"$line" || fail "exhausted line missing $f: $line"
done
# resets_at should be an ISO-8601 timestamp (10-char date prefix)
echo "$line" | grep -qE '"resets_at":"[0-9]{4}-[0-9]{2}-[0-9]{2}T' \
    || fail "resets_at not ISO-formatted: $line"
ok "exhausted event has all required fields + ISO-formatted resets_at"

# ── Test 4: debounce — second call in same window emits no event ─────────────
FAKE_CORE=4500 FAKE_GQL=0 FAKE_RESET="$FUTURE_RESET" \
    chump_gh_record "pr merge" 50 1 "test-harness"
FAKE_CORE=4500 FAKE_GQL=0 FAKE_RESET="$FUTURE_RESET" \
    chump_gh_record "pr list" 50 1 "test-harness"
n=$(grep -c '"kind":"graphql_exhausted"' "$AMB")
[[ "$n" -eq 1 ]] || fail "expected debounce: still 1 exhausted event after 3 total calls, got $n"
ok "subsequent calls in same reset window are debounced (still 1 event total)"

# ── Test 5: new reset window — flag has past resets_at → event fires again ──
# Simulate clock advancing past the reset by writing a past epoch to the flag.
rm -f "$AMB"
echo "$(( $(date +%s) - 60 ))" >"$TMP/.graphql-exhausted-since"
FAKE_CORE=4500 FAKE_GQL=0 FAKE_RESET="$FUTURE_RESET" \
    chump_gh_record "pr view" 50 1 "test-harness"
n=$(grep -c '"kind":"graphql_exhausted"' "$AMB" 2>/dev/null || echo 0)
[[ "$n" -eq 1 ]] || fail "expected new event after window expiry, got $n: $(cat "$AMB")"
ok "new reset window (past flag): event fires again"

# ── Test 6: CHUMP_GH_EXHAUSTED_THRESHOLD raises trigger threshold ───────────
rm -f "$AMB" "$TMP/.graphql-exhausted-since"
FAKE_CORE=4500 FAKE_GQL=500 FAKE_RESET="$FUTURE_RESET" \
    CHUMP_GH_EXHAUSTED_THRESHOLD=1000 \
    chump_gh_record "pr view" 50 0 "test-harness"
grep -q '"kind":"graphql_exhausted"' "$AMB" \
    || fail "with threshold=1000 and remaining=500, event should fire: $(cat "$AMB")"
ok "CHUMP_GH_EXHAUSTED_THRESHOLD=1000 catches remaining=500"

# ── Test 7: EVENT_REGISTRY registers graphql_exhausted ──────────────────────
grep -q "kind: graphql_exhausted" "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
    || fail "graphql_exhausted not registered in EVENT_REGISTRY.yaml"
ok "EVENT_REGISTRY.yaml registers graphql_exhausted"

echo
echo "All INFRA-1040 graphql_exhausted tests passed."
