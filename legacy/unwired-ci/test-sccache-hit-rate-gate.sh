#!/usr/bin/env bash
# scripts/ci/test-sccache-hit-rate-gate.sh — CREDIBLE-085 smoke test
#
# Verifies check-sccache-hit-rate.sh:
#   - exits 1 on synthetic 0% hit rate
#   - exits 0 on synthetic 50% hit rate
#   - emits kind=sccache_hit_rate_low on fail
#   - exits 0 when CHUMP_SCCACHE_HIT_RATE_CHECK=0 (bypass)
#   - exits 3 on malformed stats (no 'Cache hits rate' line)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/scripts/ci/check-sccache-hit-rate.sh"

# RESILIENT-090/093: scrub GIT_DIR/GIT_WORK_TREE inherited from pre-push.
# shellcheck source=../lib/scrub-git-env.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/scrub-git-env.sh"

[[ -x "$GATE" ]] || { echo "[FAIL] gate script not executable: $GATE"; exit 1; }

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== CREDIBLE-085: sccache hit-rate gate smoke test ==="

# ── Fixture: synthetic 0% stats ───────────────────────────────────────────
cat > "$TMP/stats-0pct.txt" <<'EOF'
Compile requests                    1000
Compile requests executed           1000
Cache hits                             0
Cache misses                        1000
Cache hits rate                     0.00 %
Cache hits rate (Rust)              0.00 %
EOF

# ── Fixture: synthetic 50% stats ──────────────────────────────────────────
cat > "$TMP/stats-50pct.txt" <<'EOF'
Compile requests                    1000
Compile requests executed           1000
Cache hits                           500
Cache misses                         500
Cache hits rate                    50.00 %
Cache hits rate (Rust)             50.00 %
EOF

# ── Fixture: malformed stats ──────────────────────────────────────────────
cat > "$TMP/stats-malformed.txt" <<'EOF'
sccache: error: failed to connect to bucket
EOF

AMBIENT="$TMP/ambient.jsonl"
: > "$AMBIENT"

# ── Test 1: 0% hit rate WARN-ONLY by default → exit 0 + emit event ────────
echo "── Test 1: 0% hit rate emits event in warn-only mode (default) ──"
RC=0
STATS_FROM_FILE="$TMP/stats-0pct.txt" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    GITHUB_SHA="testsha123" \
    GITHUB_JOB="cargo-test" \
    bash "$GATE" >/dev/null 2>&1 || RC=$?
if [[ "$RC" -eq 0 ]]; then
    ok "Test 1: warn-only default exits 0 on 0% hit rate (event still emitted)"
else
    fail "Test 1: expected exit 0 in warn-only mode, got $RC"
fi

if grep -q '"kind":"sccache_hit_rate_low"' "$AMBIENT" 2>/dev/null; then
    ok "Test 1: sccache_hit_rate_low event emitted to ambient"
else
    fail "Test 1: sccache_hit_rate_low event NOT emitted"
fi

if grep -q '"measured_pct":"0' "$AMBIENT" 2>/dev/null; then
    ok "Test 1: measured_pct=0 captured in event"
else
    fail "Test 1: measured_pct field missing or wrong"
fi

# ── Test 2: 50% hit rate → exit 0 ─────────────────────────────────────────
echo "── Test 2: 50% hit rate passes the gate ──"
RC=0
STATS_FROM_FILE="$TMP/stats-50pct.txt" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$GATE" >/dev/null 2>&1 || RC=$?
if [[ "$RC" -eq 0 ]]; then
    ok "Test 2: gate exits 0 on 50% hit rate"
else
    fail "Test 2: expected exit 0, got $RC"
fi

# ── Test 3: bypass via CHUMP_SCCACHE_HIT_RATE_CHECK=0 ─────────────────────
echo "── Test 3: bypass env var skips the gate ──"
: > "$AMBIENT"
RC=0
STATS_FROM_FILE="$TMP/stats-0pct.txt" \
    CHUMP_SCCACHE_HIT_RATE_CHECK=0 \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$GATE" >/dev/null 2>&1 || RC=$?
if [[ "$RC" -eq 0 ]]; then
    ok "Test 3: bypass exits 0 even with 0% stats"
else
    fail "Test 3: bypass expected exit 0, got $RC"
fi

if grep -q '"kind":"sccache_hit_rate_check_bypassed"' "$AMBIENT" 2>/dev/null; then
    ok "Test 3: bypass audit event emitted"
else
    fail "Test 3: bypass audit event NOT emitted"
fi

# ── Test 4: malformed stats → exit 3 (parser error) ───────────────────────
echo "── Test 4: malformed stats returns parser-error rc=3 ──"
RC=0
STATS_FROM_FILE="$TMP/stats-malformed.txt" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$GATE" >/dev/null 2>&1 || RC=$?
if [[ "$RC" -eq 3 ]]; then
    ok "Test 4: gate exits 3 on parser failure"
else
    fail "Test 4: expected exit 3, got $RC"
fi

# ── Test 5: custom threshold + ENFORCE ────────────────────────────────────
echo "── Test 5: 50% < 60% threshold with ENFORCE=1 fails ──"
RC=0
STATS_FROM_FILE="$TMP/stats-50pct.txt" \
    CHUMP_SCCACHE_HIT_RATE_MIN=60 \
    CHUMP_SCCACHE_HIT_RATE_ENFORCE=1 \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$GATE" >/dev/null 2>&1 || RC=$?
if [[ "$RC" -eq 1 ]]; then
    ok "Test 5: ENFORCE=1 + 50% < 60% threshold fails the gate"
else
    fail "Test 5: expected exit 1 with ENFORCE=1, got $RC"
fi

# ── Test 6: ENFORCE=1 + low rate still emits event AND fails ──────────────
echo "── Test 6: ENFORCE=1 fails build on 0% rate (and emits event) ──"
: > "$AMBIENT"
RC=0
STATS_FROM_FILE="$TMP/stats-0pct.txt" \
    CHUMP_SCCACHE_HIT_RATE_ENFORCE=1 \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$GATE" >/dev/null 2>&1 || RC=$?
if [[ "$RC" -eq 1 ]]; then
    ok "Test 6: ENFORCE=1 + 0% rate exits 1"
else
    fail "Test 6: expected exit 1 with ENFORCE=1, got $RC"
fi
if grep -q '"enforced":"1"' "$AMBIENT" 2>/dev/null; then
    ok "Test 6: event carries enforced=1"
else
    fail "Test 6: event missing enforced=1 field"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
