#!/usr/bin/env bash
# test-preflight-ci-parity-smoke.sh — INFRA-2084 AC7
#
# Synthesizes a brand-new CI gate (an always-failing script referenced from a
# fixture ci.yml) that has NO mirror, NO Tier-D entry, and NO allowlist
# entry, and asserts test-preflight-ci-parity.sh CATCHES it (delta > 0,
# exit 1). Then resolves the gate two ways — (a) allowlisting it, and
# (b) mirroring it in a fixture preflight.rs — and asserts each resolution
# makes test-preflight-ci-parity.sh report 0 delta (exit 0).
#
# This is the "smoke test that assert[s] chump preflight catches it" and
# "assert[s] preflight-ci-parity-audit reports 0 delta" required by
# INFRA-2084 AC7. It exercises the real parity script (via env-var fixture
# overrides added alongside this test) rather than reimplementing its logic.
#
# Exit: 0 = all assertions pass; 1 = any assertion fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PARITY_SCRIPT="$REPO_ROOT/scripts/ci/test-preflight-ci-parity.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_TEST="$(mktemp -d -t test-pf-ci-parity-smoke.XXXXXX)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

WORKFLOWS_DIR="$TMPDIR_TEST/workflows"
mkdir -p "$WORKFLOWS_DIR"

PREFLIGHT_SRC="$TMPDIR_TEST/preflight.rs"
GATES_INVENTORY="$TMPDIR_TEST/CI_GATES_INVENTORY.md"
EXCEPTIONS_FILE="$TMPDIR_TEST/preflight-ci-parity-exceptions.txt"

SYNTH_GATE_SCRIPT="scripts/ci/test-synth-always-fail-INFRA-2084.sh"

cat > "$WORKFLOWS_DIR/ci.yml" <<EOF
name: ci
on: [push]
jobs:
  fast-checks:
    runs-on: ubuntu-latest
    steps:
      - name: synthetic always-failing gate (INFRA-2084 smoke)
        run: bash $SYNTH_GATE_SCRIPT
EOF

cat > "$PREFLIGHT_SRC" <<'EOF'
// fixture preflight.rs — no mirrors yet
EOF

cat > "$GATES_INVENTORY" <<'EOF'
# fixture CI_GATES_INVENTORY.md

## Tier D

| Gate | Reason |
|---|---|
EOF

: > "$EXCEPTIONS_FILE"

run_parity() {
    CHUMP_PARITY_WORKFLOWS_DIR="$WORKFLOWS_DIR" \
        CHUMP_PARITY_PREFLIGHT_SRC="$PREFLIGHT_SRC" \
        CHUMP_PARITY_GATES_INVENTORY="$GATES_INVENTORY" \
        CHUMP_PARITY_EXCEPTIONS_FILE="$EXCEPTIONS_FILE" \
        CHUMP_AMBIENT_LOG="$TMPDIR_TEST/ambient.jsonl" \
        bash "$PARITY_SCRIPT"
}

# ── 1. Unresolved synthetic gate: parity script must catch it ────────────────
if run_parity >"$TMPDIR_TEST/out1.log" 2>&1; then
    bad "unmirrored synthetic gate should have made parity script exit non-zero"
else
    ok "unmirrored synthetic gate makes parity script fail (caught)"
fi

if grep -q "$SYNTH_GATE_SCRIPT" "$TMPDIR_TEST/out1.log"; then
    ok "parity script output names the unmirrored synthetic gate script"
else
    bad "parity script output did not name the unmirrored gate script"
fi

# ── 2a. Resolve via allowlist → expect 0 delta (exit 0) ──────────────────────
echo "$SYNTH_GATE_SCRIPT       # reason: INFRA-2084 smoke fixture" > "$EXCEPTIONS_FILE"

if run_parity >"$TMPDIR_TEST/out2.log" 2>&1; then
    ok "allowlisting the synthetic gate resolves parity to 0 delta"
else
    bad "parity script still failing after allowlisting the synthetic gate"
    cat "$TMPDIR_TEST/out2.log"
fi

# reset exceptions file for the next resolution path
: > "$EXCEPTIONS_FILE"

# ── 2b. Resolve via preflight mirror → expect 0 delta (exit 0) ───────────────
cat > "$PREFLIGHT_SRC" <<EOF
// fixture preflight.rs — mirrors the synthetic gate
const MIRRORED: &str = "$SYNTH_GATE_SCRIPT";
EOF

if run_parity >"$TMPDIR_TEST/out3.log" 2>&1; then
    ok "mirroring the synthetic gate in preflight.rs resolves parity to 0 delta"
else
    bad "parity script still failing after mirroring the synthetic gate"
    cat "$TMPDIR_TEST/out3.log"
fi

echo
echo "test-preflight-ci-parity-smoke: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
