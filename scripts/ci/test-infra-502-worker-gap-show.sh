#!/usr/bin/env bash
# test-infra-502-worker-gap-show.sh — INFRA-502
#
# Validates that worker.sh's inline-briefing path uses 'chump gap show'
# as the canonical gap-content source (post-INFRA-498 docs/gaps/*.yaml
# is deleted; legacy YAML paths are fallback only).

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

echo "=== INFRA-502 worker gap-content via chump gap show ==="
echo

# 1. INFRA-502 marker present.
if grep -q "INFRA-502" "$WORKER"; then
    ok "worker.sh contains INFRA-502 marker"
else
    fail "worker.sh missing INFRA-502 marker"
fi

# 2. Inline briefing tries 'chump gap show' first.
if grep -qE 'chump_show_out.*chump gap show' "$WORKER"; then
    ok "inline briefing tries 'chump gap show' first"
else
    fail "inline briefing does not call 'chump gap show'"
fi

# 3. Legacy YAML paths preserved as fallback (back-compat).
if grep -qE 'gap_yaml_path=.*docs/gaps/' "$WORKER"; then
    ok "legacy docs/gaps/ YAML fallback preserved"
else
    fail "legacy YAML fallback removed"
fi

# 4. P0-fallback priority lookup also via chump gap show.
if grep -qE 'chump gap show.*\$GAP_ID' "$WORKER"; then
    # Already covered by check 2; this is the same string. Verify
    # the P0-fallback section specifically calls show.
    p0_block=$(awk '/INFRA-267: P0 fallback/,/INFRA-267: P0 fallback succeeded/' "$WORKER")
    if echo "$p0_block" | grep -q "chump gap show"; then
        ok "P0-fallback priority lookup uses chump gap show"
    else
        fail "P0-fallback priority lookup still relies on YAML only"
    fi
else
    fail "no chump gap show invocation found"
fi

# 5. Prompt instruction text updated (no longer says 'hand-edit docs/gaps/*.yaml').
if ! grep -q "Never hand-edit docs/gaps" "$WORKER"; then
    ok "prompt instruction no longer references docs/gaps/*.yaml"
else
    fail "prompt instruction still mentions docs/gaps/*.yaml hand-edits"
fi

# 6. Diagnostic message says chump gap show, not the old 'read docs/gaps/...'.
if grep -q "run 'chump gap show" "$WORKER"; then
    ok "diagnostic message points at chump gap show"
else
    fail "diagnostic message not updated"
fi

# 7. Syntax.
if bash -n "$WORKER"; then
    ok "worker.sh syntax-clean"
else
    fail "syntax error"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
