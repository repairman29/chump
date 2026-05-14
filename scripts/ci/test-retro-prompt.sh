#!/usr/bin/env bash
# scripts/ci/test-retro-prompt.sh — INFRA-1273
#
# Verifies the post-ship retro prompt:
#   1. After successful auto-close, bot-merge.sh prints a stable retro-prompt line
#   2. CHUMP_NO_RETRO_PROMPT=1 suppresses the prompt
#   3. The prompt is structured so harnesses can match it (prefix is stable)

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── Test 1: source presence (string check) ────────────────────────────────
grep -q "retro-prompt:INFRA-1273" "$BOT_MERGE" \
    || fail "retro-prompt marker missing from bot-merge.sh"
ok "bot-merge.sh contains [retro-prompt:INFRA-1273] marker"

grep -q "broadcast.sh FEEDBACK retro" "$BOT_MERGE" \
    || fail "FEEDBACK retro hint missing"
ok "prompt points at broadcast.sh FEEDBACK retro"

grep -q "CHUMP_NO_RETRO_PROMPT" "$BOT_MERGE" \
    || fail "CHUMP_NO_RETRO_PROMPT bypass missing"
ok "CHUMP_NO_RETRO_PROMPT bypass present"

# ── Test 2: extract the prompt block + verify the bypass guard wraps it ──
block=$(awk '/INFRA-1273: post-ship retro prompt/,/INFRA-192: forward-chain notifier/' "$BOT_MERGE")
[ -n "$block" ] || fail "INFRA-1273 block not extractable"

echo "$block" | grep -q 'CHUMP_NO_RETRO_PROMPT:-0' \
    || fail "bypass guard wrong env-var form"
ok "bypass guard reads CHUMP_NO_RETRO_PROMPT correctly"

# ── Test 3: run the prompt logic directly (inline driver, no autoclose ctx) ─
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Inline the same logic as the bot-merge.sh INFRA-1273 block. This is a
# code mirror — if it drifts, Tests 1+2 catch the bot-merge.sh side; this
# test catches the *runtime semantics* (suppression env var, gap-id output).
cat > "$TMP/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -uo pipefail
_gid="INFRA-1234"
if [[ "${CHUMP_NO_RETRO_PROMPT:-0}" != "1" ]]; then
    printf '[retro-prompt:INFRA-1273] Anything that did not fit while shipping %s? Log it:\n' "$_gid"
    printf '  scripts/coord/broadcast.sh FEEDBACK retro %s "<one-liner>"\n' "$_gid"
    printf '  (kinds: defect | proposal | preference[+1/-1] | retro)\n'
fi
DRIVER
chmod +x "$TMP/driver.sh"

out=$(bash "$TMP/driver.sh" 2>&1)
echo "$out" | grep -q "\[retro-prompt:INFRA-1273\] Anything that did not fit" \
    || fail "default mode: prompt missing: $out"
echo "$out" | grep -q "broadcast.sh FEEDBACK retro INFRA-1234" \
    || fail "prompt should cite the gap-id: $out"
ok "default: prompt fires with citation"

out2=$(CHUMP_NO_RETRO_PROMPT=1 bash "$TMP/driver.sh" 2>&1)
if echo "$out2" | grep -q "retro-prompt:INFRA-1273"; then
    fail "CHUMP_NO_RETRO_PROMPT=1 should suppress prompt, got: $out2"
fi
ok "CHUMP_NO_RETRO_PROMPT=1 suppresses prompt"

echo
echo "All INFRA-1273 retro-prompt tests passed."
