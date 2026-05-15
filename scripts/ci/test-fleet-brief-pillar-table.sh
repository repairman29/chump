#!/usr/bin/env bash
# test-fleet-brief-pillar-table.sh — CREDIBLE-034
#
# Tests that fleet-brief.sh appends a 4-row pillar pickable table:
#   1. "Pillar pickable" header present in fleet-brief output
#   2. zero-count pillar shows "0 (!)" breach marker
#   3. ZERO-WASTE row appears in the table

set -uo pipefail

PASS=0; FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
FLEET_BRIEF="$REPO_ROOT/scripts/dispatch/fleet-brief.sh"

if [[ ! -x "$FLEET_BRIEF" ]]; then
    echo "SKIP: fleet-brief.sh not found or not executable"
    exit 0
fi

echo "=== CREDIBLE-034 fleet-brief pillar table tests ==="
echo

# Run fleet-brief with a stub chump that emits no open gaps (0 pickable for all pillars).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub chump binary: returns empty gap list for 'gap list' and minimal output for other cmds.
STUB_CHUMP="$TMP/chump"
cat > "$STUB_CHUMP" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"gap list"* ]]; then
    echo "--- 0 shown / 0 total open ---"
elif [[ "$*" == *"gap show"* ]]; then
    echo "  title: stub gap"
elif [[ "$*" == *"waste-tally"* ]]; then
    echo "0 waste events"
else
    echo ""
fi
STUB
chmod +x "$STUB_CHUMP"

# Run fleet-brief with the stub chump and a fake git log (empty).
# Stub out 'git log' to avoid needing a real git range.
STUB_GIT="$TMP/git"
cat > "$STUB_GIT" <<'STUB'
#!/usr/bin/env bash
echo ""
STUB
chmod +x "$STUB_GIT"

BRIEF_OUT=$(
    CHUMP_BIN="$STUB_CHUMP" \
    PATH="$TMP:$PATH" \
    bash "$FLEET_BRIEF" 2>/dev/null || true
)

# ── 1. Pillar table header present ────────────────────────────────────────
echo "[1. Pillar pickable header present]"
if echo "$BRIEF_OUT" | grep -q "Pillar pickable"; then
    ok "fleet-brief includes 'Pillar pickable' section"
else
    fail "fleet-brief missing 'Pillar pickable' header"
fi

# ── 2. Zero-count pillar shows breach marker ───────────────────────────────
echo
echo "[2. Zero-count pillar shows '0 (!)' breach marker]"
if echo "$BRIEF_OUT" | grep -q "0 (!)"; then
    ok "zero pickable count marked as '0 (!)'"
else
    fail "no '0 (!)' breach marker found — zero counts should be flagged"
fi

# ── 3. ZERO-WASTE row present ─────────────────────────────────────────────
echo
echo "[3. ZERO-WASTE row appears in pillar table]"
if echo "$BRIEF_OUT" | grep -q "ZERO-WASTE"; then
    ok "ZERO-WASTE pillar row present in table"
else
    fail "ZERO-WASTE row missing from pillar table"
fi

# ── 4. INFRA-1355: brief survives chump's empty-state.db auto-import path ─
# Reproduction case: fresh worktree → state.db missing → first `chump gap list`
# auto-imports + tells caller to re-run. Brief would see empty output and
# report Pillars=0/0/0/0 even with hundreds of pickable gaps.
echo
echo "[4. INFRA-1355: brief retries when first chump gap list says 're-run']"
STUB_AUTOIMPORT="$TMP/chump-autoimport"
cat > "$STUB_AUTOIMPORT" <<STUB
#!/usr/bin/env bash
# 1st call to \`gap list\` returns the auto-import notice; subsequent calls
# return real pickable rows. Uses a flag file at a fixed path because each
# chump invocation inside \$(...) is a separate subshell with a fresh \$\$.
flag="$TMP/chump-autoimport-flag"
if [[ "\$*" == *"gap list"* ]]; then
    if [[ ! -f "\$flag" ]]; then
        : > "\$flag"
        echo "[gap-list] state.db is empty — auto-importing from docs/gaps/ (INFRA-821)"
        echo "[gap-list] imported 400 gap(s) — re-run to list"
        exit 0
    fi
    echo "[open] CREDIBLE-099 — CREDIBLE: stub gap (P1/s)"
    echo "[open] EFFECTIVE-099 — EFFECTIVE: stub gap (P1/s)"
    echo "[open] RESILIENT-099 — RESILIENT: stub gap (P1/s)"
    echo "[open] ZERO-WASTE-099 — ZERO-WASTE: stub gap (P1/s)"
elif [[ "\$*" == *"gap show"* ]]; then
    echo "  title: stub"
elif [[ "\$*" == *"waste-tally"* ]]; then
    echo "0 waste events"
else
    echo ""
fi
STUB
chmod +x "$STUB_AUTOIMPORT"

BRIEF_OUT_AUTOIMPORT=$(
    CHUMP_BIN="$STUB_AUTOIMPORT" \
    PATH="$TMP:$PATH" \
    TMPDIR="$TMP" \
    bash "$FLEET_BRIEF" 2>/dev/null || true
)
# Each pillar should now show 1 (the stub row), not 0
if echo "$BRIEF_OUT_AUTOIMPORT" | grep -E "EFFECTIVE\s+1" > /dev/null \
   && echo "$BRIEF_OUT_AUTOIMPORT" | grep -E "CREDIBLE\s+1"  > /dev/null \
   && echo "$BRIEF_OUT_AUTOIMPORT" | grep -E "RESILIENT\s+1" > /dev/null \
   && echo "$BRIEF_OUT_AUTOIMPORT" | grep -E "ZERO-WASTE\s+1" > /dev/null; then
    ok "brief retries past auto-import notice and reports the real pillar counts"
else
    fail "brief reports 0/0/0/0 when first chump gap list returns auto-import notice"
    echo "--- brief output ---"
    echo "$BRIEF_OUT_AUTOIMPORT" | grep -A6 "Pillar pickable" || true
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
