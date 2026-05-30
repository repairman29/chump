#!/usr/bin/env bash
# test-sibling-status.sh — META-154: smoke test for `chump sibling-status`.
#
# Stubs up 5 synthetic claim-*.json + 5 synthetic ambient event patterns
# in a tmp .chump-locks/, runs the binary against that root, asserts each
# lease is classified per AC #3 (progressing/in-flight/heartbeat-only/
# stalled/silent/expired).

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
BIN="${CHUMP_BIN:-chump}"

if ! command -v "$BIN" >/dev/null 2>&1; then
    echo "FAIL: '$BIN' not on PATH" >&2
    exit 1
fi

_pass=0
_fail=0
_ok()  { echo "  ✓ $*"; _pass=$((_pass + 1)); }
_bad() { echo "  ✗ FAIL: $*" >&2; _fail=$((_fail + 1)); }

# ── Tmp fixture ────────────────────────────────────────────────────────────
FIX="$(mktemp -d)"
LOCKS="$FIX/.chump-locks"
AMB="$LOCKS/ambient.jsonl"
mkdir -p "$LOCKS"
touch "$AMB"

NOW_EPOCH="$(date -u +%s)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
T_5MIN="$(date -u -r $((NOW_EPOCH - 300)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$((NOW_EPOCH - 300)) +%Y-%m-%dT%H:%M:%SZ)"
T_45MIN="$(date -u -r $((NOW_EPOCH - 2700)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$((NOW_EPOCH - 2700)) +%Y-%m-%dT%H:%M:%SZ)"
T_3H="$(date -u -r $((NOW_EPOCH - 10800)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$((NOW_EPOCH - 10800)) +%Y-%m-%dT%H:%M:%SZ)"
T_PAST="$(date -u -r $((NOW_EPOCH - 86400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$((NOW_EPOCH - 86400)) +%Y-%m-%dT%H:%M:%SZ)"

# Lease 1: in-flight — file_edit within 5 min, no recent commit
cat > "$LOCKS/claim-test-001-fixture.json" <<EOF
{"session_id":"sess-inflight","gap_id":"FIX-001","taken_at":"$T_45MIN","expires_at":"$(date -u -r $((NOW_EPOCH + 14400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$((NOW_EPOCH + 14400)) +%Y-%m-%dT%H:%M:%SZ)","paths":[]}
EOF
printf '{"ts":"%s","kind":"file_edit","session":"sess-inflight","path":"foo.rs"}\n' "$T_5MIN" >> "$AMB"

# Lease 2: heartbeat-only — heartbeat within 5 min, no edit/broadcast
cat > "$LOCKS/claim-test-002-fixture.json" <<EOF
{"session_id":"sess-beat","gap_id":"FIX-002","taken_at":"$T_45MIN","expires_at":"$(date -u -r $((NOW_EPOCH + 14400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$((NOW_EPOCH + 14400)) +%Y-%m-%dT%H:%M:%SZ)","paths":[]}
EOF
printf '{"ts":"%s","kind":"ci_audit_heartbeat","session":"sess-beat","role":"ci-audit"}\n' "$T_5MIN" >> "$AMB"

# Lease 3: stalled — age > 2h, no recent activity
cat > "$LOCKS/claim-test-003-fixture.json" <<EOF
{"session_id":"sess-stalled","gap_id":"FIX-003","taken_at":"$T_3H","expires_at":"$(date -u -r $((NOW_EPOCH + 14400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$((NOW_EPOCH + 14400)) +%Y-%m-%dT%H:%M:%SZ)","paths":[]}
EOF
# No matching ambient — stalled

# Lease 4: silent — no heartbeat in last hour
cat > "$LOCKS/claim-test-004-fixture.json" <<EOF
{"session_id":"sess-silent","gap_id":"FIX-004","taken_at":"$T_45MIN","expires_at":"$(date -u -r $((NOW_EPOCH + 14400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$((NOW_EPOCH + 14400)) +%Y-%m-%dT%H:%M:%SZ)","paths":[]}
EOF
printf '{"ts":"%s","kind":"shepherd_heartbeat","session":"sess-silent","role":"shepherd"}\n' "$T_PAST" >> "$AMB"

# Lease 5: expired — expires_at in the past
cat > "$LOCKS/claim-test-005-fixture.json" <<EOF
{"session_id":"sess-expired","gap_id":"FIX-005","taken_at":"$T_PAST","expires_at":"$T_PAST","paths":[]}
EOF

# ── Run ──────────────────────────────────────────────────────────────────
cd "$FIX"
OUT="$("$BIN" sibling-status --json 2>&1)"
RC=$?

if (( RC == 0 )); then
    _ok "sibling-status exits 0"
else
    _bad "sibling-status exit $RC (expected 0). Output: $OUT"
fi

# Classification assertions — JSON inspection via grep (no jq dep)
if echo "$OUT" | grep -q '"gap_id":"FIX-001"' && echo "$OUT" | grep -q '"classification":"in-flight"'; then
    _ok "FIX-001 classified as in-flight"
else
    _bad "FIX-001 not classified as in-flight. Output: $OUT"
fi

if echo "$OUT" | grep -q '"gap_id":"FIX-002"' && echo "$OUT" | grep -q '"classification":"heartbeat-only"'; then
    _ok "FIX-002 classified as heartbeat-only"
else
    _bad "FIX-002 not classified as heartbeat-only. Output: $OUT"
fi

if echo "$OUT" | grep -q '"gap_id":"FIX-003"' && echo "$OUT" | grep -q '"classification":"stalled"'; then
    _ok "FIX-003 classified as stalled"
else
    _bad "FIX-003 not classified as stalled. Output: $OUT"
fi

if echo "$OUT" | grep -q '"gap_id":"FIX-004"' && echo "$OUT" | grep -q '"classification":"silent"'; then
    _ok "FIX-004 classified as silent"
else
    _bad "FIX-004 not classified as silent. Output: $OUT"
fi

if echo "$OUT" | grep -q '"gap_id":"FIX-005"' && echo "$OUT" | grep -q '"expired":true'; then
    _ok "FIX-005 classified as expired"
else
    _bad "FIX-005 not expired. Output: $OUT"
fi

# Emit-event assertion
if grep -q '"kind":"sibling_status_polled"' "$AMB" 2>/dev/null; then
    _ok "sibling-status emitted kind=sibling_status_polled to ambient"
else
    _bad "sibling-status did not emit kind=sibling_status_polled"
fi

# Human-table mode runs without error
TABLE="$("$BIN" sibling-status 2>&1)"
if [[ -n "$TABLE" ]]; then
    _ok "sibling-status default (table) mode emits output"
else
    _bad "sibling-status default mode emitted no output"
fi

# ── Cleanup + summary ──────────────────────────────────────────────────────
rm -rf "$FIX"
echo
echo "Results: ${_pass} passed, ${_fail} failed"
if (( _fail > 0 )); then exit 1; fi
echo "✓ All META-154 sibling-status tests passed"
