#!/usr/bin/env bash
# test-ambient-kind-schema.sh — INFRA-1889 regression test for the
# ambient-emit "kind" registry gate.
#
# Covers:
#   1. A registered kind (session_start) passes through to ambient.jsonl.
#   2. A free-text-sentence kind (the curator-opus-handoff incident shape)
#      is quarantined to ambient-rejected.jsonl, NOT ambient.jsonl, and a
#      kind=ambient_kind_rejected replacement event fires with bad_kind
#      intact.
#   3. An unregistered-but-slug-shaped kind still passes through (doesn't
#      block new emitters ahead of their registry entry).
#   4. CHUMP_AMBIENT_KIND_LAX=1 restores accept-anything and emits
#      kind=ambient_schema_lax once per session.
#
# Run from repo root: bash scripts/ci/test-ambient-kind-schema.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

EMIT="$REPO_ROOT/scripts/dev/ambient-emit.sh"
LOG="$SANDBOX/ambient.jsonl"
REJECTED="$SANDBOX/ambient-rejected.jsonl"

emit() {
    CHUMP_AMBIENT_LOG="$LOG" \
    CHUMP_AMBIENT_REJECTED_LOG="$REJECTED" \
    CHUMP_AMBIENT_SCHEMA_CHECK=0 \
    CHUMP_AMBIENT_NATS=0 \
    CHUMP_SESSION_ID="${TEST_SESSION_ID:-test-kind-schema}" \
        "$EMIT" "$@"
}

# ── 1. Registered kind passes through ──────────────────────────────────────
: > "$LOG"; : > "$REJECTED"
TEST_SESSION_ID="s1" emit session_start >/dev/null 2>&1
if grep -q '"kind":"session_start"' "$LOG" 2>/dev/null; then
    pass "registered kind (session_start) written to ambient.jsonl"
else
    fail "registered kind (session_start) NOT written to ambient.jsonl"
fi
if [[ -s "$REJECTED" ]]; then
    fail "registered kind unexpectedly wrote to ambient-rejected.jsonl"
else
    pass "registered kind did not touch ambient-rejected.jsonl"
fi

# ── 2. Free-text sentence kind is quarantined ──────────────────────────────
: > "$LOG"; : > "$REJECTED"
SENTENCE="handed off session to next agent because context ran low"
TEST_SESSION_ID="s2" emit "$SENTENCE" >/dev/null 2>&1

if grep -qF "\"kind\":\"$SENTENCE\"" "$LOG" 2>/dev/null; then
    fail "free-text sentence kind leaked into ambient.jsonl"
else
    pass "free-text sentence kind did NOT land in ambient.jsonl"
fi
if grep -qF "\"kind\":\"$SENTENCE\"" "$REJECTED" 2>/dev/null; then
    pass "free-text sentence kind quarantined to ambient-rejected.jsonl"
else
    fail "free-text sentence kind missing from ambient-rejected.jsonl"
fi
if grep -q '"kind":"ambient_kind_rejected"' "$LOG" 2>/dev/null \
        && grep -qF "\"bad_kind\":\"$SENTENCE\"" "$LOG" 2>/dev/null; then
    pass "kind=ambient_kind_rejected replacement fired with bad_kind intact"
else
    fail "kind=ambient_kind_rejected replacement missing or bad_kind not intact"
fi

# ── 3. Unregistered-but-slug-shaped kind still passes through ─────────────
: > "$LOG"; : > "$REJECTED"
TEST_SESSION_ID="s3" emit brand_new_unregistered_kind >/dev/null 2>&1
if grep -q '"kind":"brand_new_unregistered_kind"' "$LOG" 2>/dev/null; then
    pass "unregistered-but-slug-shaped kind passes through"
else
    fail "unregistered-but-slug-shaped kind was incorrectly quarantined"
fi
if [[ -s "$REJECTED" ]]; then
    fail "unregistered-but-slug-shaped kind unexpectedly quarantined"
else
    pass "unregistered-but-slug-shaped kind did not touch ambient-rejected.jsonl"
fi

# ── 4. CHUMP_AMBIENT_KIND_LAX=1 bypass ─────────────────────────────────────
: > "$LOG"; : > "$REJECTED"
rm -f "/tmp/chump-ambient-lax-alerted-s4"
CHUMP_AMBIENT_LOG="$LOG" CHUMP_AMBIENT_REJECTED_LOG="$REJECTED" \
    CHUMP_AMBIENT_SCHEMA_CHECK=0 CHUMP_AMBIENT_NATS=0 CHUMP_SESSION_ID="s4" \
    CHUMP_AMBIENT_KIND_LAX=1 "$EMIT" "$SENTENCE" >/dev/null 2>&1

if grep -qF "\"kind\":\"$SENTENCE\"" "$LOG" 2>/dev/null; then
    pass "CHUMP_AMBIENT_KIND_LAX=1 restores accept-anything behavior"
else
    fail "CHUMP_AMBIENT_KIND_LAX=1 should have written the free-text kind"
fi
if [[ -s "$REJECTED" ]]; then
    fail "CHUMP_AMBIENT_KIND_LAX=1 should not quarantine anything"
else
    pass "CHUMP_AMBIENT_KIND_LAX=1 did not quarantine"
fi
if grep -q '"kind":"ambient_schema_lax"' "$LOG" 2>/dev/null; then
    pass "kind=ambient_schema_lax fired once under bypass"
else
    fail "kind=ambient_schema_lax did not fire under bypass"
fi
rm -f "/tmp/chump-ambient-lax-alerted-s4"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
