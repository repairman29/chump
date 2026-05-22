#!/usr/bin/env bash
# test-registry-pattern8.sh — INFRA-1659 (CREDIBLE)
#
# Verify that scripts/ci/test-event-registry-coverage.sh Pattern 8
# detects EMIT_KIND "kind_name" (uppercase shell helper) emit sites.
#
# Background: conflict-resolver-agent (INFRA-1488) shipped with an
# uppercase EMIT_KIND helper; the scanner only had Pattern 4 for the
# lowercase _emit form, so all 8 of its registered kinds appeared as
# register-without-emit orphans. INFRA-1659 adds Pattern 8 — this
# test pins it.
#
# Strategy: create a tiny synthetic shell file under a real PROD_PATHS
# prefix (scripts/ops/) inside a sandbox repo, populate the registry
# with a fixture kind, run the scanner, and assert that the fixture
# kind is detected (emerges from the emitted set, NOT from the
# register-without-emit orphan list).

set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/ci/test-event-registry-coverage.sh"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Build a minimal repo skeleton so the scanner's PROD_PATHS resolve.
mkdir -p "$SANDBOX/scripts/ops"
mkdir -p "$SANDBOX/docs/observability"
mkdir -p "$SANDBOX/scripts/ci"

# Synthetic shell file with an uppercase EMIT_KIND emit site.
cat > "$SANDBOX/scripts/ops/synthetic-pattern8.sh" <<'EOF'
#!/usr/bin/env bash
# Synthetic emit site exercising the uppercase helper variant.
EMIT_KIND() { printf '{"kind":"%s","ts":"%s"}\n' "$1" "$(date -u +%s)"; }
EMIT_KIND "pattern8_fixture_kind"
EOF
chmod +x "$SANDBOX/scripts/ops/synthetic-pattern8.sh"

# Registry containing exactly the one fixture kind — if Pattern 8
# detects the emit, the scanner should report 0 orphans and exit 0.
# If Pattern 8 is missing/broken, the fixture kind shows up as an
# orphan (register-without-emit) but won't FAIL since strict-emit
# only fails on emit-without-register. So we have to read the audit
# output and grep for the expected counts.
cat > "$SANDBOX/docs/observability/EVENT_REGISTRY.yaml" <<'EOF'
# Synthetic registry for INFRA-1659 Pattern 8 regression test.
kinds:
  - kind: pattern8_fixture_kind
    description: "synthetic fixture for INFRA-1659"
    effect_metric: self
EOF

# Empty allowlist.
: > "$SANDBOX/scripts/ci/event-registry-reserved.txt"

# Copy the script under test into the sandbox so its `cd $REPO_ROOT`
# (computed from SCRIPT_DIR) lands inside the sandbox.
cp "$SCRIPT_UNDER_TEST" "$SANDBOX/scripts/ci/test-event-registry-coverage.sh"
chmod +x "$SANDBOX/scripts/ci/test-event-registry-coverage.sh"

# ── Run the scanner against the sandbox ──
OUTPUT_FILE="$SANDBOX/scanner.out"
set +e
CHUMP_REGISTRY_GATE_MODE=report \
    bash "$SANDBOX/scripts/ci/test-event-registry-coverage.sh" \
    > "$OUTPUT_FILE" 2>&1
RC=$?
set -e

echo "── scanner output ──"
cat "$OUTPUT_FILE"
echo "── (exit=$RC) ──"

# Assertion 1: scanner exited 0 in report mode.
if [[ "$RC" -eq 0 ]]; then
    pass "scanner exits 0 in report mode"
else
    fail "scanner exited $RC (expected 0 in report mode)"
fi

# Assertion 2: emitted count >= 1 (the fixture kind was detected).
if grep -qE 'emitted=[1-9][0-9]*' "$OUTPUT_FILE"; then
    pass "emitted count >= 1 (Pattern 8 fired)"
else
    fail "emitted count is 0 — Pattern 8 did not detect EMIT_KIND \"pattern8_fixture_kind\""
fi

# Assertion 3: fixture kind is NOT in the orphan (register-without-emit) list.
if grep -qE '^  ORPHAN: pattern8_fixture_kind$' "$OUTPUT_FILE"; then
    fail "pattern8_fixture_kind appears as ORPHAN — Pattern 8 regex did not match"
else
    pass "pattern8_fixture_kind not in orphan list — Pattern 8 matched correctly"
fi

# Assertion 4: register-without-emit count is 0.
if grep -qE 'register-without-emit \(orphans\): 0' "$OUTPUT_FILE"; then
    pass "register-without-emit count is 0"
else
    fail "register-without-emit count is non-zero — Pattern 8 likely missed the fixture"
fi

echo ""
echo "── results ──"
echo "PASS: $PASS"
echo "FAIL: $FAIL"

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
