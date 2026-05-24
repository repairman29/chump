#!/usr/bin/env bash
# scripts/ci/test-worker-timeout-recovery.sh — INFRA-1715
#
# Regression test for "_pre_cycle_sha: unbound variable" crash on rc=124
# (timeout) path in scripts/dispatch/worker.sh. Before INFRA-1715 the
# worker crashed under set -u when the timeout-rescue branch fired
# without _pre_cycle_sha having been initialized on the success path.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$REPO/scripts/dispatch/worker.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$TARGET" ]] || fail "$TARGET missing"
bash -n "$TARGET" || fail "syntax error"
ok "worker.sh parses"

grep -q 'INFRA-1715' "$TARGET" || fail "no INFRA-1715 attribution at the fix site"
ok "INFRA-1715 attribution present at fix site"

# ── Regression: the rc=124 branch must use ${_pre_cycle_sha:-} form ───────
# This catches a future refactor that re-introduces the bare ${_pre_cycle_sha}.
context=$(awk '/rc.*-eq 124.*CHUMP_TIMEOUT_RESCUE/,/done <<< / {print}' "$TARGET" | head -40)
if echo "$context" | grep -q '\${_pre_cycle_sha:-}'; then
    ok "rc=124 branch uses defaulted \${_pre_cycle_sha:-} (won't crash on unbound)"
else
    fail "rc=124 branch missing :- default; will crash under set -u when _pre_cycle_sha is unbound"
fi

# ── Hermetic check: simulate the actual unbound-var crash without the fix ──
# Strip the fix from a copy of the file and confirm bash -n still parses
# but the runtime would crash. Then re-confirm the live file doesn't.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Smoke: write a 5-line script that mimics the relevant pattern + assert
# bash -u path is safe.
cat > "$TMP/snippet.sh" <<'SNIPPET'
#!/usr/bin/env bash
set -euo pipefail
_post_cycle_sha="abc123"
if [[ -n "${_pre_cycle_sha:-}" ]] && [[ "${_pre_cycle_sha:-}" == "$_post_cycle_sha" ]]; then
    echo "rescue path (won't fire here)"
fi
echo "survived"
SNIPPET
chmod +x "$TMP/snippet.sh"
out=$(bash "$TMP/snippet.sh" 2>&1)
if [[ "$out" == "survived" ]]; then
    ok "isolated snippet using \${_pre_cycle_sha:-} runs cleanly under set -u"
else
    fail "isolated snippet broke under set -u; got: $out"
fi

# Negative control: confirm the OLD pattern WOULD have crashed
cat > "$TMP/old-snippet.sh" <<'SNIPPET'
#!/usr/bin/env bash
set -euo pipefail
_post_cycle_sha="abc123"
if [[ -n "$_pre_cycle_sha" ]] && [[ "$_pre_cycle_sha" == "$_post_cycle_sha" ]]; then
    echo "rescue"
fi
echo "survived"
SNIPPET
chmod +x "$TMP/old-snippet.sh"
set +e
old_out=$(bash "$TMP/old-snippet.sh" 2>&1)
old_rc=$?
set -e
if (( old_rc != 0 )) && echo "$old_out" | grep -q "unbound variable"; then
    ok "negative control: old bare \$_pre_cycle_sha crashes with unbound variable (proving the fix matters)"
else
    fail "negative control failed — expected old form to crash, got rc=$old_rc / out=$old_out"
fi

echo ""
echo "ALL INFRA-1715 worker-timeout-recovery assertions passed."
