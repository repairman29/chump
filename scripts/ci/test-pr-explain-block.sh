#!/usr/bin/env bash
# scripts/ci/test-pr-explain-block.sh — INFRA-1416
#
# Verifies `chump pr explain-block <PR>` produces coherent explanations across
# 3 stubbed scenarios:
#   1. PR with all green checks → "READY" overall_action
#   2. PR with single cargo_fmt_drift failure (local) → "cargo fmt && ..." action
#   3. PR with audit_check failure that's ALSO failing on 3 sibling PRs → "fleet-wide" action
#
# Uses CHUMP_PR_EXPLAIN_FIXTURE env var to feed pre-canned pr_view.json +
# pr_list.json — avoids real `gh` calls so the test works offline + in CI.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

echo "=== INFRA-1416 pr explain-block tests ==="

# ── Source contract checks ────────────────────────────────────────────────────
if grep -q "pub fn run_explain" "$REPO_ROOT/src/pr_explain_block.rs" 2>/dev/null; then
    ok "src/pr_explain_block.rs exports run_explain"
else
    fail "src/pr_explain_block.rs missing run_explain"
fi

if grep -q "pr_explain_block::run_explain" "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "src/main.rs wires pr_explain_block::run_explain"
else
    fail "src/main.rs missing pr_explain_block wiring"
fi

# ── Resolve binary ────────────────────────────────────────────────────────────
if [[ -f "$SCRIPT_DIR/lib/discover-chump-bin.sh" ]]; then
    # shellcheck source=lib/discover-chump-bin.sh disable=SC1091
    source "$SCRIPT_DIR/lib/discover-chump-bin.sh" 2>/dev/null || true
fi
if [[ -z "${CHUMP_BIN:-}" || ! -x "${CHUMP_BIN:-}" ]]; then
    CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    [[ ! -x "$CHUMP_BIN" ]] && CHUMP_BIN="$REPO_ROOT/target/release/chump"
fi

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "  SKIP: chump binary not found — run cargo build first"
    echo "=== Summary: $PASS passed, $FAIL failed (binary skipped) ==="
    exit 0
fi

# ── Scenario 1: all-green PR → READY ──────────────────────────────────────────
TMP="$(mktemp -d -t pr-explain.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/s1"
cat > "$TMP/s1/pr_view.json" <<'EOF'
{"number":9001,"title":"feat(TEST): all-green PR","headRefName":"test/all-green","statusCheckRollup":[{"name":"build","conclusion":"SUCCESS","status":"COMPLETED"},{"name":"test","conclusion":"SUCCESS","status":"COMPLETED"}]}
EOF
cat > "$TMP/s1/pr_list.json" <<'EOF'
[]
EOF

OUT1="$(CHUMP_PR_EXPLAIN_FIXTURE="$TMP/s1" "$CHUMP_BIN" pr explain-block 9001 2>&1)"
if echo "$OUT1" | grep -q "READY"; then
    ok "scenario 1 (all-green) → READY"
else
    fail "scenario 1 expected READY, got: $(echo "$OUT1" | tr '\n' ' ' | head -c 200)"
fi

# ── Scenario 2: cargo_fmt_drift local → "cargo fmt &&" action ─────────────────
mkdir -p "$TMP/s2"
cat > "$TMP/s2/pr_view.json" <<'EOF'
{"number":9002,"title":"feat(TEST): fmt drift","headRefName":"test/fmt-drift","statusCheckRollup":[{"name":"rustfmt","conclusion":"FAILURE","status":"COMPLETED"}]}
EOF
cat > "$TMP/s2/pr_list.json" <<'EOF'
[]
EOF

OUT2="$(CHUMP_PR_EXPLAIN_FIXTURE="$TMP/s2" "$CHUMP_BIN" pr explain-block 9002 2>&1)"
if echo "$OUT2" | grep -q "cargo_fmt_drift" && echo "$OUT2" | grep -q "cargo fmt"; then
    ok "scenario 2 (fmt drift) → cargo_fmt_drift class + cargo fmt action"
else
    fail "scenario 2 expected cargo_fmt_drift + cargo fmt, got: $(echo "$OUT2" | tr '\n' ' ' | head -c 300)"
fi

# ── Scenario 3: audit failure also failing on 3 siblings → fleet-wide ─────────
mkdir -p "$TMP/s3"
cat > "$TMP/s3/pr_view.json" <<'EOF'
{"number":9003,"title":"feat(TEST): audit fail","headRefName":"test/audit","statusCheckRollup":[{"name":"audit","conclusion":"FAILURE","status":"COMPLETED"}]}
EOF
cat > "$TMP/s3/pr_list.json" <<'EOF'
[{"number":9004,"statusCheckRollup":[{"name":"audit","conclusion":"FAILURE","status":"COMPLETED"}]},{"number":9005,"statusCheckRollup":[{"name":"audit","conclusion":"FAILURE","status":"COMPLETED"}]},{"number":9006,"statusCheckRollup":[{"name":"audit","conclusion":"FAILURE","status":"COMPLETED"}]}]
EOF

OUT3="$(CHUMP_PR_EXPLAIN_FIXTURE="$TMP/s3" "$CHUMP_BIN" pr explain-block 9003 2>&1)"
if echo "$OUT3" | grep -qi "fleet-wide"; then
    ok "scenario 3 (3 siblings same failure) → fleet-wide"
else
    fail "scenario 3 expected fleet-wide, got: $(echo "$OUT3" | tr '\n' ' ' | head -c 300)"
fi

# ── Scenario 4: --json variant emits valid JSON ───────────────────────────────
OUT4="$(CHUMP_PR_EXPLAIN_FIXTURE="$TMP/s2" "$CHUMP_BIN" pr explain-block 9002 --json 2>&1)"
if echo "$OUT4" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d['pr_number']==9002; assert d['failing_checks'][0]['failure_class']=='cargo_fmt_drift'; print('ok')" >/dev/null 2>&1; then
    ok "scenario 4 (--json) emits parseable JSON with expected shape"
else
    fail "scenario 4 --json output invalid: $(echo "$OUT4" | head -c 300)"
fi

# ── Scenario 5: usage error on missing arg ────────────────────────────────────
# Note: pipefail + chump's exit-2 would fail the `if` even when grep matches —
# capture into a var so the exit-2 doesn't poison the pipeline.
USAGE_OUT="$("$CHUMP_BIN" pr explain-block 2>&1 || true)"
if echo "$USAGE_OUT" | grep -q "Usage:"; then
    ok "scenario 5 (no arg) prints usage"
else
    fail "scenario 5 expected usage message"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
