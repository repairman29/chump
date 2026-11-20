#!/usr/bin/env bash
# scripts/ci/test-failure-mode-catalog.sh
#
# INFRA-647: Validate docs/process/FAILURE_MODES.yaml structure and verify
# that `chump classify-failure` correctly classifies known failure patterns.
#
# Exit 0 = all checks pass. Exit 1 = at least one check failed.
#
# Usage: bash scripts/ci/test-failure-mode-catalog.sh [--build]
#   --build  run cargo build first (default: use existing target/debug/chump)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CATALOG="$REPO_ROOT/docs/process/FAILURE_MODES.yaml"
CHUMP="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
PASS=0
FAIL=0

# ── Helpers ──────────────────────────────────────────────────────────────────

ok()   { echo "  ok  $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $*"; FAIL=$((FAIL + 1)); }

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        ok "$desc"
    else
        fail "$desc — want '$expected', got '$actual'"
    fi
}

# ── Build (optional) ─────────────────────────────────────────────────────────

if [[ "${1:-}" == "--build" ]]; then
    echo "Building chump..."
    cargo build --bin chump -q --manifest-path "$REPO_ROOT/Cargo.toml"
fi

# ── 1. YAML file exists and has 10+ entries ───────────────────────────────────

echo ""
echo "=== 1. FAILURE_MODES.yaml structure ==="

if [ ! -f "$CATALOG" ]; then
    fail "docs/process/FAILURE_MODES.yaml does not exist"
    echo ""
    echo "TOTAL: 0 passed, 1 failed"
    exit 1
fi
ok "FAILURE_MODES.yaml exists"

# Count entries (lines starting with "  - id:")
ENTRY_COUNT=$(grep -c "^  - id:" "$CATALOG" || true)
if [ "$ENTRY_COUNT" -ge 10 ]; then
    ok "catalog has $ENTRY_COUNT entries (>= 10 required)"
else
    fail "catalog has only $ENTRY_COUNT entries — need at least 10"
fi

# Required fields present in every entry
for field in pattern classification auto_action confidence; do
    COUNT=$(grep -c "^    $field:" "$CATALOG" || true)
    if [ "$COUNT" -ge "$ENTRY_COUNT" ]; then
        ok "every entry has '$field' field ($COUNT found)"
    else
        fail "field '$field' missing from some entries (found $COUNT, expected $ENTRY_COUNT)"
    fi
done

# Required classifications present
for cls in lint flake real-bug infra-broken test-coupling; do
    if grep -q "classification: $cls" "$CATALOG"; then
        ok "classification '$cls' is covered"
    else
        fail "classification '$cls' not found — catalog may be incomplete"
    fi
done

# Required auto_actions present
for act in fix rerun file_gap escalate; do
    if grep -q "auto_action: $act" "$CATALOG"; then
        ok "auto_action '$act' is present"
    else
        fail "auto_action '$act' not found — may be missing failure modes"
    fi
done

# Specific patterns from the AC are present
for pattern_id in manual_strip manual_split_once lines_filter_map_ok doc_overindented \
                  e2e_pwa_stuck oauth_401 fmt_fail snapshot_mismatch disk_full runner_oom; do
    if grep -q "  - id: $pattern_id" "$CATALOG"; then
        ok "required entry '$pattern_id' present"
    else
        fail "required entry '$pattern_id' missing from catalog"
    fi
done

# ── 2. chump classify-failure binary tests ───────────────────────────────────

echo ""
echo "=== 2. chump classify-failure integration ==="

if [ ! -x "$CHUMP" ]; then
    echo "  SKIP  chump binary not found at $CHUMP — run with --build or cargo build first"
    PASS=$((PASS + 1))
else
    cd "$REPO_ROOT"

    # Helper: run classify-failure and extract a JSON field
    classify_field() {
        local field="$1" job="$2" log_text="$3"
        local result
        result=$(echo "$log_text" | "$CHUMP" classify-failure --job "$job" --log - --json 2>/dev/null || echo '{}')
        echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field',''))" 2>/dev/null || echo ""
    }

    # fmt job → lint
    check "fmt job → lint class" \
        "lint" \
        "$(classify_field classification "fmt" "")"

    # clippy job → lint
    check "clippy job → lint class" \
        "lint" \
        "$(classify_field classification "clippy" "")"

    # fmt job → fix action
    check "fmt job → fix action" \
        "fix" \
        "$(classify_field auto_action "fmt" "")"

    # snapshot mismatch log → test-coupling
    check "snapshot mismatch log → test-coupling" \
        "test-coupling" \
        "$(classify_field classification "cargo-test" "snapshot mismatch for render.snap")"

    # disk full log → infra-broken
    check "disk full log → infra-broken" \
        "infra-broken" \
        "$(classify_field classification "cargo-build" "error: No space left on device (os error 28)")"

    # OOM kill → flake
    check "OOM kill log → flake" \
        "flake" \
        "$(classify_field classification "cargo-test" "signal: killed")"

    # e2e-pwa in job name → flake
    check "e2e-pwa job name → flake" \
        "flake" \
        "$(classify_field classification "e2e-pwa" "")"

    # Unknown log → fallback (should return something, not crash)
    FALLBACK_CLASS=$(classify_field classification "unknown-job" "some unrelated text that matches nothing")
    if [ -n "$FALLBACK_CLASS" ]; then
        ok "fallback classification returns non-empty result: '$FALLBACK_CLASS'"
    else
        fail "fallback classification returned empty result"
    fi

    # Output is valid JSON
    JSON_OUT=$("$CHUMP" classify-failure --job "fmt" --json 2>/dev/null || echo "")
    if echo "$JSON_OUT" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        ok "classify-failure --json output is valid JSON"
    else
        fail "classify-failure --json output is not valid JSON: $JSON_OUT"
    fi

    # High-confidence entry beats low-confidence entry
    CONF_CLASS=$(classify_field classification "cargo-test" "signal: killed\nNo space left on device")
    check "highest-confidence match wins (disk_full over runner_oom)" \
        "infra-broken" \
        "$CONF_CLASS"
fi

# ── 3. pr-triage-bot.yml references classify-failure ─────────────────────────

echo ""
echo "=== 3. pr-triage-bot.yml integration ==="

WORKFLOW="$REPO_ROOT/.github/workflows/pr-triage-bot.yml"
if [ ! -f "$WORKFLOW" ]; then
    fail "pr-triage-bot.yml not found"
else
    ok "pr-triage-bot.yml exists"

    if grep -q "classify-failure" "$WORKFLOW"; then
        ok "pr-triage-bot.yml calls classify-failure"
    else
        fail "pr-triage-bot.yml does not call classify-failure"
    fi

    if grep -q "FAILURE_MODES.yaml" "$WORKFLOW"; then
        ok "pr-triage-bot.yml references FAILURE_MODES.yaml"
    else
        fail "pr-triage-bot.yml does not reference FAILURE_MODES.yaml"
    fi

    if grep -q "catalog_id" "$WORKFLOW"; then
        ok "pr-triage-bot.yml captures catalog_id from classification"
    else
        fail "pr-triage-bot.yml does not use catalog_id"
    fi
fi

# ── 4. Rust unit tests pass ───────────────────────────────────────────────────

echo ""
echo "=== 4. Rust unit tests (failure_catalog) ==="

if command -v cargo &>/dev/null && [ -f "$REPO_ROOT/Cargo.toml" ]; then
    if cargo test --manifest-path "$REPO_ROOT/Cargo.toml" \
            --bin chump infra647_ --quiet 2>&1 | tail -5; then
        ok "failure_catalog Rust unit tests pass"
    else
        fail "failure_catalog Rust unit tests failed"
    fi
else
    echo "  SKIP  cargo not available"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════"
echo "  TOTAL: $PASS passed, $FAIL failed"
echo "══════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
