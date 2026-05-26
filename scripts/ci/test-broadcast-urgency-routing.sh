#!/usr/bin/env bash
# scripts/ci/test-broadcast-urgency-routing.sh — INFRA-2015
#
# Smoke test: verify broadcast.sh --urgency INFO|WARN|CRIT|EMERGENCY
# takes the correct routing path for each tier.
#
# Routes tested:
#   INFO      → ambient.jsonl only; NO urgent_broadcast marker, NO URGENT-INBOX entry
#   WARN      → ambient.jsonl + kind=urgent_broadcast marker in ambient; NO URGENT-INBOX entry
#   CRIT      → ambient.jsonl + kind=urgent_broadcast marker + URGENT-INBOX.jsonl entry
#   EMERGENCY → same as CRIT (inbox-injector.sh absent in CI is graceful — no exit 1)
#
# Also verifies:
#   - Legacy now|hours|digest values still accepted (map to INFO, no crash)
#   - Default (no --urgency) behaves as INFO
#   - urgency field is written into the event JSON

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BROADCAST="$REPO_ROOT/scripts/coord/broadcast.sh"
[[ -x "$BROADCAST" ]] || { echo "[FAIL] broadcast.sh not executable at $BROADCAST" >&2; exit 1; }

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stand up a minimal git sandbox so broadcast.sh's git calls succeed.
SANDBOX="$TMP/repo"
mkdir -p "$SANDBOX/.chump-locks/inbox"
git -C "$TMP" init -q "$SANDBOX"
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

AMBIENT="$SANDBOX/.chump-locks/ambient.jsonl"
URGENT_INBOX="$SANDBOX/.chump-locks/URGENT-INBOX.jsonl"

run_broadcast() {
    # Run broadcast.sh inside the sandbox, suppressing NATS/emit-script paths.
    (
        cd "$SANDBOX"
        CHUMP_SESSION_ID="test-$$" \
        CHUMP_REPO="$SANDBOX" \
        CHUMP_INBOX_URGENT_DISABLE=1 \
            "$BROADCAST" "$@"
    ) 2>/dev/null
}

# ── Test 1: INFO (default, no --urgency) ─────────────────────────────────────
run_broadcast WARN "test info default"
[[ -f "$AMBIENT" ]] || fail "INFO default: ambient.jsonl not created"
grep -qE '"urgency"[[:space:]]*:[[:space:]]*"INFO"' "$AMBIENT" || fail "INFO default: urgency field not INFO in ambient"
if [[ -f "$URGENT_INBOX" ]]; then
    fail "INFO default: URGENT-INBOX.jsonl should NOT exist"
fi
# No urgent_broadcast secondary marker for INFO
if grep -qE '"kind"[[:space:]]*:[[:space:]]*"urgent_broadcast"' "$AMBIENT" 2>/dev/null; then
    fail "INFO default: unexpected urgent_broadcast marker in ambient"
fi
ok "INFO (default) → ambient only, no URGENT-INBOX, no urgent_broadcast marker"

# Reset ambient for clean per-test assertions
rm -f "$AMBIENT" "$URGENT_INBOX"

# ── Test 2: --urgency INFO explicit ──────────────────────────────────────────
run_broadcast --urgency INFO WARN "test info explicit"
grep -qE '"urgency"[[:space:]]*:[[:space:]]*"INFO"' "$AMBIENT" || fail "INFO explicit: urgency field not INFO"
[[ ! -f "$URGENT_INBOX" ]] || fail "INFO explicit: URGENT-INBOX.jsonl should NOT exist"
if grep -qE '"kind"[[:space:]]*:[[:space:]]*"urgent_broadcast"' "$AMBIENT" 2>/dev/null; then
    fail "INFO explicit: unexpected urgent_broadcast marker"
fi
ok "--urgency INFO explicit → ambient only, no side-effects"

rm -f "$AMBIENT" "$URGENT_INBOX"

# ── Test 3: --urgency WARN ────────────────────────────────────────────────────
run_broadcast --urgency WARN WARN "test warn tier"
grep -q '"urgency": "WARN"' "$AMBIENT" || fail "WARN: urgency field not WARN in primary event"
# Must have secondary urgent_broadcast marker (key may appear with or without spaces after colon)
grep -qE '"kind"[[:space:]]*:[[:space:]]*"urgent_broadcast"' "$AMBIENT" || fail "WARN: missing urgent_broadcast marker in ambient"
grep -qE '"urgency"[[:space:]]*:[[:space:]]*"WARN"' "$AMBIENT" || fail "WARN: urgent_broadcast marker missing urgency=WARN"
[[ ! -f "$URGENT_INBOX" ]] || fail "WARN: URGENT-INBOX.jsonl should NOT exist for WARN tier"
ok "--urgency WARN → ambient + urgent_broadcast marker, no URGENT-INBOX"

rm -f "$AMBIENT" "$URGENT_INBOX"

# ── Test 4: --urgency CRIT ────────────────────────────────────────────────────
run_broadcast --urgency CRIT STUCK "INFRA-9999" "crit test reason"
grep -qE '"urgency"[[:space:]]*:[[:space:]]*"CRIT"' "$AMBIENT" || fail "CRIT: urgency field not CRIT in primary event"
grep -qE '"kind"[[:space:]]*:[[:space:]]*"urgent_broadcast"' "$AMBIENT" || fail "CRIT: missing urgent_broadcast marker"
[[ -f "$URGENT_INBOX" ]] || fail "CRIT: URGENT-INBOX.jsonl must exist"
grep -qE '"urgency"[[:space:]]*:[[:space:]]*"CRIT"' "$URGENT_INBOX" || fail "CRIT: URGENT-INBOX entry missing urgency=CRIT"
grep -qE '"body"' "$URGENT_INBOX" || fail "CRIT: URGENT-INBOX entry missing body field"
ok "--urgency CRIT → ambient + urgent_broadcast + URGENT-INBOX.jsonl entry"

rm -f "$AMBIENT" "$URGENT_INBOX"

# ── Test 5: --urgency EMERGENCY ───────────────────────────────────────────────
# inbox-injector.sh absent in CI sandbox → graceful (no exit 1 from route_by_urgency).
run_broadcast --urgency EMERGENCY ALERT "kind=ci_test" "emergency test message"
grep -qE '"urgency"[[:space:]]*:[[:space:]]*"EMERGENCY"' "$AMBIENT" || fail "EMERGENCY: urgency field not EMERGENCY in primary event"
grep -qE '"kind"[[:space:]]*:[[:space:]]*"urgent_broadcast"' "$AMBIENT" || fail "EMERGENCY: missing urgent_broadcast marker"
[[ -f "$URGENT_INBOX" ]] || fail "EMERGENCY: URGENT-INBOX.jsonl must exist"
grep -qE '"urgency"[[:space:]]*:[[:space:]]*"EMERGENCY"' "$URGENT_INBOX" || fail "EMERGENCY: URGENT-INBOX entry missing urgency=EMERGENCY"
ok "--urgency EMERGENCY → ambient + urgent_broadcast + URGENT-INBOX.jsonl (injector gracefully absent)"

rm -f "$AMBIENT" "$URGENT_INBOX"

# ── Test 6: legacy urgency values (backwards compat) ─────────────────────────
for legacy in now hours digest; do
    run_broadcast --urgency "$legacy" WARN "legacy compat $legacy"
    # Must not crash and must write INFO to ambient (mapped from legacy)
    grep -qE '"urgency"[[:space:]]*:[[:space:]]*"INFO"' "$AMBIENT" || fail "legacy $legacy: expected urgency=INFO in ambient after alias mapping"
    [[ ! -f "$URGENT_INBOX" ]] || fail "legacy $legacy: URGENT-INBOX should NOT exist"
    rm -f "$AMBIENT" "$URGENT_INBOX"
    ok "legacy --urgency $legacy → accepted, maps to INFO, no side-effects"
done

# ── Test 7: invalid urgency value → exit 1 ───────────────────────────────────
if (cd "$SANDBOX" && CHUMP_SESSION_ID="test-$$" "$BROADCAST" --urgency BOGUS WARN "x" 2>/dev/null); then
    fail "invalid urgency BOGUS should have exited non-zero"
fi
ok "invalid --urgency BOGUS → exits non-zero"

# ── Test 8: urgency field present on all event types ─────────────────────────
for event_call in \
    "DONE INFRA-9999 abc123" \
    "INTENT INFRA-9999" \
    "FEEDBACK proposal test-subject rationale-text" \
; do
    rm -f "$AMBIENT"
    # shellcheck disable=SC2086
    run_broadcast --urgency WARN $event_call
    grep -qE '"urgency"[[:space:]]*:[[:space:]]*"WARN"' "$AMBIENT" || fail "urgency field missing from event: $event_call"
    rm -f "$AMBIENT" "$URGENT_INBOX"
done
ok "urgency field present in DONE / INTENT / FEEDBACK events"

echo
echo "All INFRA-2015 --urgency routing tests passed."
