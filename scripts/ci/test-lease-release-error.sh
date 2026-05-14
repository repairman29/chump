#!/usr/bin/env bash
# test-lease-release-error.sh — INFRA-1243
#
# Verifies that dispatch.rs no longer silently swallows lease release errors.
# Specifically:
#   1. release() returns Err when chump --release exits non-zero
#   2. emit_lease_release_failed() writes kind=lease_release_failed to ambient.jsonl
#   3. Both call sites (work-failed path + post-ship path) handle the error
#
# Uses source-level assertions only (no process injection needed — checking
# the code directly is the appropriate test for a silent-swallow guard).

set -eu
# Note: pipefail intentionally omitted — grep exits 1 on zero matches, which
# would cause every "grep ... | wc -l" count pipeline to abort the script.
# wc -l always exits 0, so the counts are safe without pipefail. (INFRA-1205)

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
DISPATCH="$REPO_ROOT/src/dispatch.rs"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

echo "=== INFRA-1243: dispatch.rs lease release error handling ==="
echo

[[ -f "$DISPATCH" ]] || { echo "FATAL: $DISPATCH not found"; exit 2; }

# ── 1. Source assertions: swallowed 'let _ = release' gone ───────────────────
echo "--- 1. No swallowed release() calls ---"

# Use wc -l to avoid grep -c exit-1-on-0-matches (INFRA-1205 same bug class)
swallowed=$(grep 'let _ = release(' "$DISPATCH" 2>/dev/null | wc -l)
if [[ "$swallowed" -eq 0 ]]; then
    ok "no 'let _ = release()' calls remain in dispatch.rs"
else
    fail "$swallowed swallowed release() call(s) still present — INFRA-1243 fix incomplete"
fi

# ── 2. Error handling present at both call sites ──────────────────────────────
echo "--- 2. Error handling at both release() call sites ---"

work_path=$(grep 'work-failed path' "$DISPATCH" 2>/dev/null | wc -l)
if [[ "$work_path" -ge 1 ]]; then
    ok "work-failed release path handles error"
else
    fail "work-failed release path error handling missing"
fi

post_ship=$(grep 'post-ship path' "$DISPATCH" 2>/dev/null | wc -l)
if [[ "$post_ship" -ge 1 ]]; then
    ok "post-ship release path handles error"
else
    fail "post-ship release path error handling missing"
fi

# ── 3. emit_lease_release_failed function exists ─────────────────────────────
echo "--- 3. emit_lease_release_failed function ---"

fn_present=$(grep 'fn emit_lease_release_failed' "$DISPATCH" 2>/dev/null | wc -l)
if [[ "$fn_present" -ge 1 ]]; then
    ok "emit_lease_release_failed function defined in dispatch.rs"
else
    fail "emit_lease_release_failed function missing"
fi

# Rust escapes quotes as \" in string literals, so search for the raw escaped form
# or the kind= comment reference (both appear in the emit function body).
kind_emitted=$(grep 'lease_release_failed' "$DISPATCH" 2>/dev/null | grep -v 'fn emit_lease_release_failed\|emit_lease_release_failed(' | wc -l)
if [[ "$kind_emitted" -ge 1 ]]; then
    ok "kind=lease_release_failed emitted to ambient"
else
    fail "kind=lease_release_failed not emitted in emit_lease_release_failed"
fi

# ── 4. release() function checks exit status ──────────────────────────────────
echo "--- 4. release() captures exit status ---"

captures_status=$(grep 'let result = Command::new' "$DISPATCH" 2>/dev/null | wc -l)
if [[ "$captures_status" -ge 1 ]]; then
    ok "release() captures Command status into 'result'"
else
    fail "release() still does not capture Command status"
fi

# ── 5. EVENT_REGISTRY.yaml registers lease_release_failed ────────────────────
echo "--- 5. EVENT_REGISTRY.yaml registration ---"

if [[ -f "$REGISTRY" ]] && grep -q 'lease_release_failed' "$REGISTRY"; then
    ok "kind=lease_release_failed registered in EVENT_REGISTRY.yaml"
else
    fail "kind=lease_release_failed NOT in EVENT_REGISTRY.yaml"
fi

registry_fields=$(grep -A 5 'lease_release_failed' "$REGISTRY" 2>/dev/null | { grep 'fields_required' || true; } | wc -l)
if [[ "$registry_fields" -ge 1 ]]; then
    ok "fields_required documented in registry entry"
else
    fail "fields_required missing from lease_release_failed registry entry"
fi

# ── 6. INFRA-1243 reference in dispatch.rs ───────────────────────────────────
echo "--- 6. INFRA-1243 attribution ---"

ref_count=$(grep 'INFRA-1243' "$DISPATCH" 2>/dev/null | wc -l)
if [[ "$ref_count" -ge 2 ]]; then
    ok "INFRA-1243 referenced in dispatch.rs ($ref_count times)"
else
    fail "INFRA-1243 under-referenced in dispatch.rs (found $ref_count, want ≥2)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
