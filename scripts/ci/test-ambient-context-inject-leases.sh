#!/usr/bin/env bash
# test-ambient-context-inject-leases.sh — INFRA-1664
#
# Regression test for the SessionStart/PreToolUse ambient digest false-positive:
# before INFRA-1664, the lease enumerator globbed every .chump-locks/*.json,
# which counted META-065 curator-filed idempotence markers (44 of them, often
# referencing INFRA-1149) as "active sibling leases". The fix restricts the
# glob to claim-*.json (the real lease file convention from `chump claim`).
#
# Verifies:
#   (1) With 0 claim-*.json but many curator-filed-*.json files present, the
#       digest reports zero leases (no "Active sibling leases" block, and the
#       header shows "active leases: 0").
#   (2) With 3 synthetic claim-*.json files (real leases), the digest reports
#       exactly the 3 with their gap_id + session + expires fields.

set -euo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INJECT="$REPO_ROOT/scripts/coord/ambient-context-inject.sh"
[[ -x "$INJECT" ]] || { echo "FATAL: $INJECT not executable"; exit 2; }

TMP="$(mktemp -d)"

# W-013 immunization (RESILIENT-024): unset workflow-injected env so this
# tests own $TMP fixtures are not hijacked by CI workflow CHUMP_LOCK_DIR.
unset CHUMP_REPO CHUMP_LOCK_DIR
trap 'rm -rf "$TMP"' EXIT

# Extract the digest Python block from ambient-context-inject.sh so the test
# runs the exact code path without spinning up a fake git repo / shelling out.
DIGEST_PY="$TMP/digest.py"
awk '/^cat > "\$_DIGEST_PY" << '\''PY'\''$/,/^PY$/' "$INJECT" \
    | sed '1d;$d' > "$DIGEST_PY"

if [[ ! -s "$DIGEST_PY" ]]; then
    echo "FATAL: could not extract embedded digest Python from $INJECT"
    exit 2
fi

LOCK_DIR="$TMP/locks"
mkdir -p "$LOCK_DIR"
AMBIENT_LOG="$LOCK_DIR/ambient.jsonl"
: > "$AMBIENT_LOG"  # empty stream — we don't need events for these tests

run_digest() {
    AMBIENT_LOG="$AMBIENT_LOG" \
    LOCK_DIR="$LOCK_DIR" \
    SESSION_ID="test-session" \
    HOOK_EVENT="SessionStart" \
    N="30" \
    REPO_ROOT="$TMP" \
    ROADMAP_INJECT_FILE="" \
    INBOX_INJECT_FILE="" \
    python3 "$DIGEST_PY"
}

extract_context() {
    # Pull additionalContext out of the wrapped hook JSON.
    python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["hookSpecificOutput"]["additionalContext"])
'
}

echo "=== ambient-context-inject lease enumeration (INFRA-1664) ==="

# ── 1. Curator markers must not register as leases ───────────────────────────
echo "--- Test 1: 44 curator-filed-*.json + 0 claim-*.json → 0 active leases ---"
for i in $(seq 1 44); do
    cat > "$LOCK_DIR/curator-filed-INFRA-1149-$i.json" <<EOF
{
  "gap_id": "INFRA-1149",
  "filed_by": "curator-daemon",
  "session_id": "curator-$i",
  "ts": "2026-05-22T00:00:00Z"
}
EOF
done

OUT="$(run_digest | extract_context || true)"
if grep -q "active leases: 0" <<<"$OUT"; then
    ok "header reports 0 active leases despite 44 curator markers"
else
    fail "header should show 'active leases: 0'; got:"
    sed 's/^/    /' <<<"$OUT" | head -5
fi

if ! grep -q "Active sibling leases" <<<"$OUT"; then
    ok "no 'Active sibling leases' block emitted (zero-state)"
else
    fail "'Active sibling leases' block leaked through with 0 real leases"
fi

if ! grep -q "INFRA-1149" <<<"$OUT"; then
    ok "INFRA-1149 (curator marker content) not surfaced as a lease"
else
    fail "INFRA-1149 leaked into digest from curator markers"
fi

# ── 2. Real claim-*.json leases are enumerated ───────────────────────────────
echo "--- Test 2: 3 claim-*.json files → digest lists all 3 ---"
for gap in FOO-100 BAR-200 BAZ-300; do
    pid=$RANDOM
    ts=$(date +%s)
    lower=$(printf '%s' "$gap" | tr '[:upper:]' '[:lower:]')
    f="$LOCK_DIR/claim-${lower}-${pid}-${ts}.json"
    cat > "$f" <<EOF
{
  "gap_id": "$gap",
  "session_id": "claim-${lower}-${pid}-${ts}",
  "expires_at": "2026-05-23T00:00:00Z",
  "paths": ["src/${lower}.rs"]
}
EOF
done

OUT="$(run_digest | extract_context || true)"
if grep -q "active leases: 3" <<<"$OUT"; then
    ok "header reports 3 active leases"
else
    fail "header should show 'active leases: 3'; got:"
    sed 's/^/    /' <<<"$OUT" | head -5
fi

for gap in FOO-100 BAR-200 BAZ-300; do
    if grep -q "$gap" <<<"$OUT"; then
        ok "lease $gap surfaced in digest"
    else
        fail "lease $gap missing from digest"
    fi
done

if grep -q "expires=2026-05-23T00:00:00Z" <<<"$OUT"; then
    ok "expires field rendered for each lease"
else
    fail "expires field missing from digest"
fi

# ── Report ───────────────────────────────────────────────────────────────────
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    printf '  - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
