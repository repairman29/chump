#!/usr/bin/env bash
# test-waste-tally-tokens.sh — INFRA-641
#
# Static-validates the --tokens flag on chump waste-tally:
#  (a) tokens_burned field on WasteEntry
#  (b) total_tokens_burned field on WasteReport
#  (c) render_text_tokens method on WasteReport
#  (d) --tokens flag wired in main.rs waste-tally handler
#  (e) tokens_burned in render_json output
#  (f) infra641_ unit tests defined
#  (g) format_tokens helper present

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-641 waste-tally --tokens test ==="
echo

# (a) tokens_burned field on WasteEntry
if grep -qE 'pub tokens_burned: u64' "$REPO_ROOT/src/waste_tally.rs"; then
    ok "tokens_burned field on WasteEntry"
else
    fail "tokens_burned field missing on WasteEntry"
fi

# (b) total_tokens_burned field on WasteReport
if grep -qE 'pub total_tokens_burned: u64' "$REPO_ROOT/src/waste_tally.rs"; then
    ok "total_tokens_burned field on WasteReport"
else
    fail "total_tokens_burned field missing on WasteReport"
fi

# (c) render_text_tokens method
if grep -qE 'pub fn render_text_tokens' "$REPO_ROOT/src/waste_tally.rs"; then
    ok "render_text_tokens method present"
else
    fail "render_text_tokens method missing"
fi

# (d) --tokens flag wired in main.rs
if grep -q 'want_tokens' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "--tokens flag wired in main.rs"
else
    fail "--tokens not wired in main.rs"
fi

if grep -q 'render_text_tokens' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "render_text_tokens called from main.rs"
else
    fail "render_text_tokens not called from main.rs"
fi

# (e) tokens_burned in render_json
if grep -q 'tokens_burned' "$REPO_ROOT/src/waste_tally.rs" && \
   grep -A5 'fn render_json' "$REPO_ROOT/src/waste_tally.rs" | grep -q 'tokens_burned'; then
    ok "tokens_burned included in render_json"
else
    # broader check: tokens_burned appears in the render_json block
    if grep -q '"tokens_burned"' "$REPO_ROOT/src/waste_tally.rs"; then
        ok "tokens_burned key in render_json output string"
    else
        fail "tokens_burned not found in render_json"
    fi
fi

# (f) infra641_ unit tests
test_count=$(grep -cE 'fn infra641_' "$REPO_ROOT/src/waste_tally.rs" 2>/dev/null || echo 0)
if [[ "$test_count" -ge 3 ]]; then
    ok "infra641_ unit tests defined ($test_count fns)"
else
    fail "expected >=3 infra641_ unit tests, found $test_count"
fi

# (g) format_tokens helper
if grep -qE 'fn format_tokens' "$REPO_ROOT/src/waste_tally.rs"; then
    ok "format_tokens helper present"
else
    fail "format_tokens helper missing"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
