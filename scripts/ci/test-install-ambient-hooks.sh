#!/usr/bin/env bash
# test-install-ambient-hooks.sh — FLEET-023 regression tests for the
# install-ambient-hooks.sh installer.
#
# Cold Water Issue #9 found that fresh remote sandboxes never invoke
# the installer, so `~/.claude/settings.json` lacks the ambient hooks
# and `tail .chump-locks/ambient.jsonl` keeps showing only the two
# session_start events from the Cold Water session itself. FLEET-023
# wires the installer into the CLAUDE.md MANDATORY pre-flight; this
# test guards the bypass + idempotence properties so the pre-flight
# is safe to invoke unconditionally.
#
# Verifies:
#   (1) CHUMP_AMBIENT_INSTALL_SKIP=1 → exit 0, settings.json untouched.
#   (2) Fresh sandbox install → settings.json gets _chump_tag=fleet-019-ambient
#       SessionStart / PreToolUse / PostToolUse / Stop entries.
#   (3) Re-running with no changes → exit 0 + "no changes needed" on stderr.
#   (4) Existing unrelated hooks are preserved.
#   (5) --uninstall removes only our entries (other hooks survive).
#
# Run from repo root: bash scripts/ci/test-install-ambient-hooks.sh

set -euo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL="$REPO_ROOT/scripts/setup/install-ambient-hooks.sh"
[[ -x "$INSTALL" ]] || { echo "FATAL: $INSTALL not executable"; exit 2; }
command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== install-ambient-hooks.sh tests ==="

# ── 1. CHUMP_AMBIENT_INSTALL_SKIP=1 → no-op ──────────────────────────────────
echo "--- Test 1: CHUMP_AMBIENT_INSTALL_SKIP=1 short-circuits ---"
TARGET1="$TMP/skip.json"
echo '{"hooks":{"SessionStart":[{"label":"unrelated"}]}}' > "$TARGET1"
PRE_HASH=$(shasum "$TARGET1" | awk '{print $1}')
if CHUMP_AMBIENT_INSTALL_SKIP=1 "$INSTALL" --user-settings-path "$TARGET1" >/dev/null 2>&1; then
    POST_HASH=$(shasum "$TARGET1" | awk '{print $1}')
    if [[ "$PRE_HASH" == "$POST_HASH" ]]; then
        ok "settings.json unchanged with CHUMP_AMBIENT_INSTALL_SKIP=1"
    else
        fail "CHUMP_AMBIENT_INSTALL_SKIP=1 still mutated settings.json"
    fi
else
    fail "CHUMP_AMBIENT_INSTALL_SKIP=1 should exit 0, did not"
fi

# ── 2. Fresh install → all four hook types written ───────────────────────────
echo "--- Test 2: fresh install writes SessionStart/PreToolUse/PostToolUse/Stop ---"
TARGET2="$TMP/fresh.json"
"$INSTALL" --user-settings-path "$TARGET2" >/dev/null 2>&1 \
    || fail "fresh install exited non-zero"
for evt in SessionStart PreToolUse PostToolUse Stop; do
    if jq -e --arg e "$evt" '.hooks[$e] // [] | map(select(._chump_tag=="fleet-019-ambient")) | length > 0' \
         "$TARGET2" >/dev/null 2>&1; then
        ok "hook installed for $evt"
    else
        fail "hook missing for $evt"
    fi
done

# ── 3. Re-run is idempotent ──────────────────────────────────────────────────
echo "--- Test 3: re-run is a no-op (idempotent) ---"
PRE2=$(shasum "$TARGET2" | awk '{print $1}')
out=$("$INSTALL" --user-settings-path "$TARGET2" 2>&1 || true)
POST2=$(shasum "$TARGET2" | awk '{print $1}')
if [[ "$PRE2" == "$POST2" ]]; then
    ok "second install is byte-identical"
else
    fail "second install mutated the file"
fi
if grep -q "no changes needed" <<<"$out"; then
    ok "stderr says 'no changes needed' on re-run"
else
    fail "re-run should announce 'no changes needed' (got: $out)"
fi

# ── 4. Unrelated hooks survive install ───────────────────────────────────────
echo "--- Test 4: unrelated hooks preserved across install ---"
TARGET4="$TMP/coexist.json"
cat > "$TARGET4" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      { "label": "user-custom-hook", "hooks": [{"type":"command","command":"echo hi"}] }
    ]
  },
  "permissions": { "allow": ["Read"] }
}
EOF
"$INSTALL" --user-settings-path "$TARGET4" >/dev/null 2>&1 \
    || fail "install over existing settings exited non-zero"
if jq -e '.hooks.SessionStart | map(select(.label=="user-custom-hook")) | length == 1' \
     "$TARGET4" >/dev/null 2>&1; then
    ok "user's custom SessionStart hook preserved"
else
    fail "user's custom hook was clobbered"
fi
if jq -e '.permissions.allow == ["Read"]' "$TARGET4" >/dev/null 2>&1; then
    ok "non-hooks fields preserved"
else
    fail "non-hooks fields were modified"
fi

# ── 5. --uninstall removes only our entries ──────────────────────────────────
echo "--- Test 5: --uninstall is selective ---"
"$INSTALL" --user-settings-path "$TARGET4" --uninstall >/dev/null 2>&1 \
    || fail "--uninstall exited non-zero"
if jq -e '.hooks.SessionStart | map(select(._chump_tag=="fleet-019-ambient")) | length == 0' \
     "$TARGET4" >/dev/null 2>&1; then
    ok "our hooks removed"
else
    fail "uninstall did not remove our hooks"
fi
if jq -e '.hooks.SessionStart | map(select(.label=="user-custom-hook")) | length == 1' \
     "$TARGET4" >/dev/null 2>&1; then
    ok "user's custom hook still present after uninstall"
else
    fail "uninstall clobbered user's custom hook"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    printf '  - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
