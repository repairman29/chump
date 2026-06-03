#!/usr/bin/env bash
# scripts/ci/test-pre-push-preflight-hook.sh — INFRA-1671 regression test.
#
# Asserts the Guard 0a (chump preflight) block in scripts/git-hooks/pre-push:
#   1. invokes `chump preflight` when the binary is available and push has Rust/scripts diff
#   2. skips silently when `chump` binary is unavailable
#   3. skips when push has no Rust/scripts content
#   4. INFRA-2422: CHUMP_PREFLIGHT_SKIP is deleted — no bypass env accepted
#
# Structural checks against the hook file itself — does NOT actually
# install the hook in a sandbox repo (that's brittle and slow for CI).
# The structural assertion is enough: if Guard 0a is wired correctly in
# the hook source, it will fire correctly when installed.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

echo "=== INFRA-1671 pre-push preflight guard ==="

[[ -f "$HOOK" ]] || { echo "[FAIL] $HOOK not found"; exit 1; }

# 1. Guard 0a block exists
if grep -q "^# Guard 0a: chump preflight (INFRA-1671)" "$HOOK"; then
    ok "Guard 0a block header present"
else
    fail "Guard 0a block header missing — was the guard inserted?"
fi

# 2. Invokes the binary
if grep -qE 'chump preflight' "$HOOK"; then
    ok "hook calls 'chump preflight'"
else
    fail "hook does not call 'chump preflight'"
fi

# 3. INFRA-2422: CHUMP_PREFLIGHT_SKIP must NOT appear as a bypass in the hook
if grep -q 'CHUMP_PREFLIGHT_SKIP:-0' "$HOOK"; then
    fail "CHUMP_PREFLIGHT_SKIP bypass still present — should be deleted (INFRA-2422)"
else
    ok "CHUMP_PREFLIGHT_SKIP bypass absent (deleted per INFRA-2422)"
fi

# 4. Has the 'command -v chump' fallback (binary not installed)
if grep -q 'command -v chump' "$HOOK"; then
    ok "binary-availability fallback present"
else
    fail "binary-availability fallback missing — would break early bootstrap"
fi

# 4b. Has the 'chump preflight --help' capability check
# (old binaries without the preflight subcommand must not block pushes)
if grep -q 'chump preflight --help' "$HOOK"; then
    ok "preflight-capability check present (old binaries skip gracefully)"
else
    fail "preflight-capability check missing — old binaries would block all pushes"
fi

# 5. Has the push-delta gating (only run on Rust/scripts pushes)
if grep -qE 'preflight_has_targets' "$HOOK"; then
    ok "push-delta gating present (skips doc-only pushes)"
else
    fail "push-delta gating missing — would run preflight on doc-only pushes"
fi

# 6. Exits non-zero on failure (BLOCKED keyword + exit 1)
guard_block=$(awk '/^# Guard 0a:/,/^# Guard 0:/' "$HOOK")
if echo "$guard_block" | grep -q 'BLOCKED: chump preflight failed'; then
    ok "blocks push with diagnostic on preflight failure"
else
    fail "missing 'BLOCKED' diagnostic on preflight failure"
fi
if echo "$guard_block" | grep -q 'exit 1'; then
    ok "exits 1 on preflight failure"
else
    fail "missing exit 1 on preflight failure"
fi

# 7. INFRA-2422: failure message references auto-skip (not deleted bypass)
if echo "$guard_block" | grep -q "INFRA-2422"; then
    ok "failure message references INFRA-2422 auto-skip (no bypass env)"
else
    fail "failure message should reference INFRA-2422 auto-skip"
fi

# 8. Order: Guard 0a appears BEFORE Guard 0 (cargo fmt) in the file
line_0a=$(grep -n '^# Guard 0a:' "$HOOK" | head -1 | cut -d: -f1)
line_0=$(grep -n '^# Guard 0: cargo fmt' "$HOOK" | head -1 | cut -d: -f1)
if [[ -n "$line_0a" && -n "$line_0" ]] && (( line_0a < line_0 )); then
    ok "Guard 0a runs BEFORE Guard 0 (cargo fmt) — line $line_0a < $line_0"
else
    fail "Guard 0a should run before Guard 0 (cargo fmt); 0a=$line_0a, 0=$line_0"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
