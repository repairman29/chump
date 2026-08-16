#!/usr/bin/env bash
# test-bypass-var-cull-audit.sh — INFRA-3625
#
# Proves scripts/ops/bypass-var-cull-audit.sh's headroom math and candidate
# detection against a synthetic fixture tree (via
# CHUMP_DEBT_VAR_CULL_ROOT_OVERRIDE) — not the live repo, which legitimately
# drifts over time.
#
# This test FAILS without INFRA-3625's change: before that change, the audit
# script did not exist at all.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUDIT="$REPO_ROOT/scripts/ops/bypass-var-cull-audit.sh"
[[ -f "$AUDIT" ]] || { echo "FAIL: $AUDIT not found"; exit 1; }

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mk_fixture() {
    # $1 = fixture dir, $2 = ceiling number
    local dir="$1" ceiling="$2"
    mkdir -p "$dir/scripts/ci" "$dir/src" "$dir/crates"
    printf '%s\n' "$ceiling" > "$dir/scripts/ci/bypass-var-ceiling.txt"
    # A live var: read via env::var in a Rust file → not a cull candidate.
    cat > "$dir/src/live.rs" <<'EOF'
fn f() {
    let _ = std::env::var("CHUMP_LIVE_BYPASS");
}
EOF
    # A dead var: named once, in a doc-only text file, never read anywhere.
    printf 'CHUMP_DEAD_SKIP\n' > "$dir/scripts/ci/env-vars-internal.txt"
}

# ── Case 1: healthy headroom → exit 0, no candidates flagged as urgent ──────
FIX1="$TMP/fixture1"
mk_fixture "$FIX1" 5
out1="$(CHUMP_DEBT_VAR_CULL_ROOT_OVERRIDE="$FIX1" bash "$AUDIT" 2>&1)"; rc1=$?
if [[ "$rc1" -eq 0 ]]; then ok "healthy headroom (ceiling=5, count=2) exits 0"; else bad "expected exit 0, got $rc1 — output: $out1"; fi
if echo "$out1" | grep -q "headroom=3"; then ok "headroom computed as ceiling(5) - count(2) = 3"; else bad "headroom not computed correctly — output: $out1"; fi

# ── Case 2: zero headroom (pinned at ceiling) → exit 1, WARN ────────────────
FIX2="$TMP/fixture2"
mk_fixture "$FIX2" 2
out2="$(CHUMP_DEBT_VAR_CULL_ROOT_OVERRIDE="$FIX2" bash "$AUDIT" 2>&1)"; rc2=$?
if [[ "$rc2" -eq 1 ]]; then ok "zero headroom (ceiling=2, count=2) exits 1"; else bad "expected exit 1, got $rc2 — output: $out2"; fi
if echo "$out2" | grep -qi "WARN"; then ok "zero headroom prints a WARN"; else bad "no WARN printed — output: $out2"; fi

# ── Case 3: dead var (single-file, no read-site) is surfaced as a candidate ─
FIX3="$TMP/fixture3"
mk_fixture "$FIX3" 5
out3="$(CHUMP_DEBT_VAR_CULL_ROOT_OVERRIDE="$FIX3" bash "$AUDIT" 2>&1)"
if echo "$out3" | grep -q "CHUMP_DEAD_SKIP"; then ok "dead single-file, no-read-site var surfaced as a cull candidate"; else bad "CHUMP_DEAD_SKIP not surfaced — output: $out3"; fi
if echo "$out3" | grep -q "CHUMP_LIVE_BYPASS"; then bad "live env::var()-read var incorrectly flagged as a candidate"; else ok "live var (has a real read-site) correctly excluded from candidates"; fi

echo ""
echo "bypass-var-cull-audit self-test: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
