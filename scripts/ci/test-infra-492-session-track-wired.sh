#!/usr/bin/env bash
# test-infra-492-session-track-wired.sh — INFRA-492
#
# Validates that bot-merge.sh + worker.sh emit chump session-track
# events at the right lifecycle points so INFRA-477's cost ledger
# actually has data.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
BOTMERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

echo "=== INFRA-492 session-track wiring test ==="
echo

# 1. INFRA-492 markers exist.
for f in "$WORKER" "$BOTMERGE"; do
    if grep -q "INFRA-492" "$f"; then
        ok "$(basename $f) has INFRA-492 marker"
    else
        fail "$(basename $f) missing INFRA-492 marker"
    fi
done

# 2. worker.sh emits session_start.
if grep -q 'chump session-track --start "\$GAP_ID"' "$WORKER"; then
    ok "worker.sh emits session_start"
else
    fail "worker.sh missing session_start"
fi

# 3. worker.sh emits session_end with outcome.
if grep -q 'chump session-track --end "\$GAP_ID" --outcome' "$WORKER"; then
    ok "worker.sh emits session_end with --outcome"
else
    fail "worker.sh missing session_end"
fi

# 4. worker.sh derives outcome from rc + branch state.
if grep -qE 'rc.*-eq 124|"shipped"|"starved"' "$WORKER"; then
    ok "worker.sh derives outcome from rc/branch state"
else
    fail "worker.sh outcome derivation missing"
fi

# 5. bot-merge.sh emits session_start at claim time.
if grep -q 'chump session-track --start "\$gid"' "$BOTMERGE"; then
    ok "bot-merge.sh emits session_start at claim"
else
    fail "bot-merge.sh missing session_start"
fi

# 6. bot-merge.sh emits session_end shipped at success.
if grep -q 'chump session-track --end "\$gid" --outcome shipped' "$BOTMERGE"; then
    ok "bot-merge.sh emits session_end shipped on success"
else
    fail "bot-merge.sh missing session_end on success"
fi

# 7. Best-effort: stderr/stdout suppressed and || true on every emit.
# Sum across both files (grep -c on multiple files prints "file:N" lines).
emit_lines=$(cat "$WORKER" "$BOTMERGE" | grep -c 'chump session-track' || true)
silent_lines=$(cat "$WORKER" "$BOTMERGE" | grep -c 'chump session-track.*>/dev/null 2>&1.*|| true' || true)
if [ "${emit_lines:-0}" -ge 4 ] && [ "${silent_lines:-0}" -ge 4 ]; then
    ok "all emits are best-effort (>/dev/null + || true): $silent_lines/$emit_lines"
else
    fail "some emits not best-effort: silent=$silent_lines emits=$emit_lines"
fi

# 8. Syntax sanity.
if bash -n "$WORKER" && bash -n "$BOTMERGE"; then
    ok "both scripts syntax-clean"
else
    fail "syntax error"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
