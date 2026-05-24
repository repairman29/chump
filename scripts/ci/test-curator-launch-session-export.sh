#!/usr/bin/env bash
# scripts/ci/test-curator-launch-session-export.sh — INFRA-1880
#
# Smoke test for the curator-launch wrapper. Verifies:
#   1. Script exists, executable, parses, INFRA-1880 attribution
#   2. No-args → exit 2 with usage
#   3. Unknown role → exit 2 with "unknown role"
#   4. Valid role → exports CHUMP_SESSION_ID=curator-opus-<role>-<date>
#   5. CHUMP_SESSION_ID_AUTO=0 → skips auto-export
#   6. Missing claude CLI → exit 1 with informative error
#   7. Extra args pass through to claude (mocked)

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$REPO/scripts/coord/curator-launch.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$TARGET" ]] || fail "$TARGET missing"
[[ -x "$TARGET" ]] || fail "$TARGET not executable"
bash -n "$TARGET" || fail "syntax error"
ok "script exists, executable, parses"

grep -q 'INFRA-1880' "$TARGET" || fail "no INFRA-1880 attribution"
ok "INFRA-1880 attribution present"

grep -q 'CHUMP_SESSION_ID_AUTO' "$TARGET" || fail "no bypass env"
ok "bypass env CHUMP_SESSION_ID_AUTO present"

grep -q 'curator-opus-' "$TARGET" || fail "no curator-opus session-id pattern"
ok "exports curator-opus-<role>-<date> pattern"

# ── (2) No-args → usage + exit 2 ───────────────────────────────────────────
set +e
out_noargs=$(bash "$TARGET" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "no-args expected exit 2, got $rc"
echo "$out_noargs" | grep -q "usage:" || fail "no-args missing usage message"
ok "no-args → exit 2 with usage"

# ── (3) Unknown role → exit 2 ──────────────────────────────────────────────
set +e
out_bogus=$(bash "$TARGET" bogus-role 2>&1)
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "unknown role expected exit 2, got $rc"
echo "$out_bogus" | grep -q "unknown role" || fail "unknown role missing error message"
ok "unknown role → exit 2 with 'unknown role' error"

# ── (4) Valid role → exports session-id (mock claude to inspect env) ───────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mock-bin"
cat > "$TMP/mock-bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "CLAUDE_INVOKED args=$# CHUMP_SESSION_ID=${CHUMP_SESSION_ID:-<unset>}"
echo "ARGS:$@"
exit 0
MOCK
chmod +x "$TMP/mock-bin/claude"

TODAY="$(date +%Y-%m-%d)"
out_target=$(PATH="$TMP/mock-bin:$PATH" bash "$TARGET" target 2>&1)
if echo "$out_target" | grep -q "CHUMP_SESSION_ID=curator-opus-target-${TODAY}"; then
    ok "valid role 'target' → exports CHUMP_SESSION_ID=curator-opus-target-${TODAY}"
else
    fail "target role did not export expected session-id; got: $out_target"
fi

# ── (5) CHUMP_SESSION_ID_AUTO=0 → skips export ─────────────────────────────
out_bypass=$(PATH="$TMP/mock-bin:$PATH" CHUMP_SESSION_ID_AUTO=0 \
    CHUMP_SESSION_ID="custom-session-xyz" \
    bash "$TARGET" handoff 2>&1)
if echo "$out_bypass" | grep -q "not auto-exporting"; then
    ok "CHUMP_SESSION_ID_AUTO=0 → respects existing CHUMP_SESSION_ID"
else
    fail "bypass test failed; got: $out_bypass"
fi
if echo "$out_bypass" | grep -q "CHUMP_SESSION_ID=custom-session-xyz"; then
    ok "bypass preserves operator-set CHUMP_SESSION_ID"
else
    fail "bypass did not preserve CHUMP_SESSION_ID; got: $out_bypass"
fi

# ── (6) Missing claude → exit 1 ────────────────────────────────────────────
set +e
out_noclaude=$(PATH="/usr/bin:/bin" bash "$TARGET" target 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "missing claude expected exit 1, got $rc"
echo "$out_noclaude" | grep -q "claude CLI not found" || fail "missing claude error message wrong"
ok "missing claude CLI → exit 1 with informative error"

# ── (7) Extra args pass through to claude ──────────────────────────────────
out_args=$(PATH="$TMP/mock-bin:$PATH" bash "$TARGET" decompose -- -p "test prompt" 2>&1)
if echo "$out_args" | grep -q "ARGS:-p test prompt"; then
    ok "extra args after -- pass through to claude (-p 'test prompt')"
else
    fail "args pass-through broken; got: $out_args"
fi

echo ""
echo "ALL INFRA-1880 curator-launch assertions passed."
