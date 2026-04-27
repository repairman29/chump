#!/usr/bin/env bash
# test-ambient-glance.sh — INFRA-083 unit tests for chump-ambient-glance.sh.
#
# Verifies:
#   (1) No ambient stream → silent exit 0.
#   (2) Sibling INTENT for same gap within 120s → --check-overlap exits 2.
#   (3) Sibling file_edit on a claimed path within 120s → exits 2.
#   (4) Self events are filtered out (current session is not a "sibling").
#   (5) Events older than --since-secs are dropped.
#   (6) CHUMP_AMBIENT_GLANCE=0 short-circuits to exit 0.

set -euo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GLANCE="$REPO_ROOT/scripts/dev/chump-ambient-glance.sh"
[[ -x "$GLANCE" ]] || { echo "FATAL: $GLANCE not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks"

NOW_ISO() { date -u +%Y-%m-%dT%H:%M:%SZ; }
AGO_ISO() {
    local secs="$1"
    date -u -v-"${secs}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "-${secs} seconds" +%Y-%m-%dT%H:%M:%SZ
}

echo "=== chump-ambient-glance.sh tests ==="

# ── 1. No stream → exit 0 ────────────────────────────────────────────────────
echo "--- Test 1: no ambient stream → exit 0 ---"
if CHUMP_LOCK_DIR="$TMP/.chump-locks" "$GLANCE" --gap FOO-1 --check-overlap >/dev/null 2>&1; then
    ok "missing ambient.jsonl returns 0"
else
    fail "missing ambient.jsonl should return 0"
fi

# ── 2. Sibling INTENT same gap, recent → exit 2 ──────────────────────────────
echo "--- Test 2: recent sibling INTENT triggers --check-overlap ---"
cat >"$TMP/.chump-locks/ambient.jsonl" <<EOF
{"event":"INTENT","session":"sibling-1","ts":"$(AGO_ISO 30)","gap":"FOO-1","files":""}
EOF
if CHUMP_LOCK_DIR="$TMP/.chump-locks" CHUMP_SESSION_ID=me \
   "$GLANCE" --gap FOO-1 --check-overlap >/dev/null 2>&1; then
    fail "sibling INTENT should trigger exit 2"
else
    rc=$?
    if [[ $rc -eq 2 ]]; then ok "exit 2 on sibling INTENT"
    else fail "expected exit 2, got $rc"; fi
fi

# ── 3. Sibling file_edit on claimed path, recent → exit 2 ────────────────────
echo "--- Test 3: recent sibling file_edit on claimed path ---"
cat >"$TMP/.chump-locks/ambient.jsonl" <<EOF
{"event":"file_edit","session":"sibling-2","ts":"$(AGO_ISO 30)","path":"/abs/path/to/src/foo.rs"}
EOF
if CHUMP_LOCK_DIR="$TMP/.chump-locks" CHUMP_SESSION_ID=me \
   "$GLANCE" --paths src/foo.rs --check-overlap >/dev/null 2>&1; then
    fail "sibling file_edit should trigger exit 2"
else
    rc=$?
    [[ $rc -eq 2 ]] && ok "exit 2 on sibling file_edit" || fail "expected exit 2, got $rc"
fi

# ── 4. Self events filtered ──────────────────────────────────────────────────
echo "--- Test 4: own session events are filtered out ---"
cat >"$TMP/.chump-locks/ambient.jsonl" <<EOF
{"event":"INTENT","session":"me","ts":"$(AGO_ISO 30)","gap":"FOO-1","files":""}
EOF
if CHUMP_LOCK_DIR="$TMP/.chump-locks" CHUMP_SESSION_ID=me \
   "$GLANCE" --gap FOO-1 --check-overlap >/dev/null 2>&1; then
    ok "self INTENT ignored"
else
    fail "own-session INTENT should be filtered"
fi

# ── 5. Old events outside window ─────────────────────────────────────────────
echo "--- Test 5: events older than --since-secs are dropped ---"
cat >"$TMP/.chump-locks/ambient.jsonl" <<EOF
{"event":"INTENT","session":"sibling-3","ts":"$(AGO_ISO 1000)","gap":"FOO-1","files":""}
EOF
if CHUMP_LOCK_DIR="$TMP/.chump-locks" CHUMP_SESSION_ID=me \
   "$GLANCE" --gap FOO-1 --since-secs 300 --check-overlap >/dev/null 2>&1; then
    ok "old INTENT outside window dropped"
else
    fail "old INTENT should not trigger overlap"
fi

# ── 6. Bypass env var ────────────────────────────────────────────────────────
echo "--- Test 6: CHUMP_AMBIENT_GLANCE=0 short-circuits ---"
cat >"$TMP/.chump-locks/ambient.jsonl" <<EOF
{"event":"INTENT","session":"sibling-4","ts":"$(NOW_ISO)","gap":"FOO-1","files":""}
EOF
if CHUMP_AMBIENT_GLANCE=0 CHUMP_LOCK_DIR="$TMP/.chump-locks" CHUMP_SESSION_ID=me \
   "$GLANCE" --gap FOO-1 --check-overlap >/dev/null 2>&1; then
    ok "bypass works"
else
    fail "CHUMP_AMBIENT_GLANCE=0 should always return 0"
fi

echo
echo "=== results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || { for f in "${FAILS[@]}"; do echo "  - $f"; done; exit 1; }
exit 0
