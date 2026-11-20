#!/usr/bin/env bash
# scripts/ci/test-oracle-refresh.sh — META-088
#
# Smoke test for the Oracle refresh daemon. Mocks `claude -p` so the test
# is hermetic. Verifies:
#   1. Script exists, executable, parses, INFRA attribution
#   2. Bypass env short-circuits
#   3. Missing THE_PATH.md → graceful no-op
#   4. Mock claude returning unchanged content → no-op + emit oracle_refresh_noop
#   5. Mock claude returning new content → THE_PATH.md updated + emit oracle_refresh_drift
#   6. Wall-clock budget enforced via timeout

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$REPO/scripts/coord/oracle-refresh.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$TARGET" ]] || fail "$TARGET missing"
[[ -x "$TARGET" ]] || fail "$TARGET not executable"
bash -n "$TARGET" || fail "syntax error"
ok "script exists, executable, parses"

# ── Structural ─────────────────────────────────────────────────────────────
grep -q 'CHUMP_ORACLE_DISABLED' "$TARGET" || fail "no bypass env"
ok "bypass env CHUMP_ORACLE_DISABLED present"

grep -q 'CHUMP_ORACLE_TOKEN_BUDGET' "$TARGET" || fail "no token budget env"
ok "token budget env present"

grep -q 'CHUMP_ORACLE_WALL_BUDGET_S' "$TARGET" || fail "no wall budget env"
ok "wall budget env present"

grep -q 'oracle_refresh_drift' "$TARGET" || fail "no oracle_refresh_drift kind"
ok "emits kind=oracle_refresh_drift on change"

grep -q 'oracle_refresh_noop' "$TARGET" || fail "no oracle_refresh_noop kind"
ok "emits kind=oracle_refresh_noop on idempotent no-op"

grep -q 'META-088' "$TARGET" || fail "no META-088 attribution"
ok "META-088 attribution present"

# ── Synthetic harness ──────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SYN="$TMP/syn-repo"
mkdir -p "$SYN/scripts/coord" "$SYN/docs/process" "$SYN/.chump-locks"
(cd "$SYN" && git init -q)

cp "$TARGET" "$SYN/scripts/coord/oracle-refresh.sh"

ORIGINAL_PATH_CONTENT="# THE_PATH.md (test fixture)

## Track 1: Firewall — original content with enough text to clear the 200-character minimum threshold
This line keeps the fixture body above the script's empty-output guard so the
content-hash idempotency check has real bytes to compare on identical-run no-op.

## Track 2: Self-improvement
Filler text — pads the fixture body to comfortable size for hash dedup testing."
printf '%s\n' "$ORIGINAL_PATH_CONTENT" > "$SYN/docs/process/THE_PATH.md"

AMBIENT="$SYN/.chump-locks/ambient.jsonl"
touch "$AMBIENT"

# ── (2) Bypass env short-circuits ──────────────────────────────────────────
out_bypass=$(cd "$SYN" && CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_ORACLE_DISABLED=1 bash scripts/coord/oracle-refresh.sh 2>&1)
if [[ -z "$out_bypass" ]]; then
    ok "CHUMP_ORACLE_DISABLED=1 short-circuits silently"
else
    fail "bypass did not short-circuit; got: $out_bypass"
fi

# ── Mock claude CLI ────────────────────────────────────────────────────────
mkdir -p "$TMP/mock-bin"

# Mock #1: claude returns IDENTICAL content (idempotent no-op test).
# Must match $ORIGINAL_PATH_CONTENT byte-for-byte so the hash-based dedup fires.
cat > "$TMP/mock-bin/claude" <<MOCK
#!/usr/bin/env bash
# accept any combination of -p / --bare / etc; just emit the fixture
cat <<'CONTENT'
# THE_PATH.md (test fixture)

## Track 1: Firewall — original content with enough text to clear the 200-character minimum threshold
This line keeps the fixture body above the script's empty-output guard so the
content-hash idempotency check has real bytes to compare on identical-run no-op.

## Track 2: Self-improvement
Filler text — pads the fixture body to comfortable size for hash dedup testing.
CONTENT
exit 0
MOCK
chmod +x "$TMP/mock-bin/claude"

# Also need to mock chump (for gap list) + gh (for pr list) + git -- but
# the script's fail-soft design tolerates missing tools. Run it.
out_noop=$(cd "$SYN" && PATH="$TMP/mock-bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash scripts/coord/oracle-refresh.sh 2>&1 || true)

if echo "$out_noop" | grep -q "no change\|no-op\|same content"; then
    ok "idempotent: identical content → no-op"
else
    fail "idempotent test failed; got: $out_noop"
fi

# ── (5) Mock claude returns NEW content → drift ────────────────────────────
cat > "$TMP/mock-bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat <<'CONTENT'
# THE_PATH.md (refreshed by Oracle)

## Track 1: Firewall — NEW ranked program after refresh
This content is different from the original fixture above the script's 200-char
empty-output guard so the drift path triggers. Additional filler lines keep the
body well beyond the threshold so the hash comparison produces a real diff.

## Track 2: Self-improvement — refreshed
More refreshed track entries to ensure the diff is substantial and the hash
genuinely changes between the original and the refreshed body.
CONTENT
exit 0
MOCK
chmod +x "$TMP/mock-bin/claude"

out_drift=$(cd "$SYN" && PATH="$TMP/mock-bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash scripts/coord/oracle-refresh.sh 2>&1 || true)

if echo "$out_drift" | grep -q "THE_PATH.md updated"; then
    ok "new content → THE_PATH.md updated"
else
    fail "drift test failed; got: $out_drift"
fi

if grep -q '"kind":"oracle_refresh_drift"' "$AMBIENT"; then
    ok "ambient emits kind=oracle_refresh_drift on change"
else
    fail "drift event not emitted; ambient=$(cat $AMBIENT)"
fi

if grep -q "NEW ranked program after refresh" "$SYN/docs/process/THE_PATH.md"; then
    ok "THE_PATH.md content matches refreshed body"
else
    fail "THE_PATH.md content not updated; got: $(cat $SYN/docs/process/THE_PATH.md)"
fi

# ── (3) Missing THE_PATH.md → graceful no-op ───────────────────────────────
rm "$SYN/docs/process/THE_PATH.md"
out_missing=$(cd "$SYN" && PATH="$TMP/mock-bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash scripts/coord/oracle-refresh.sh 2>&1 || true)
if echo "$out_missing" | grep -q "no docs/process/THE_PATH.md"; then
    ok "missing THE_PATH.md → graceful no-op"
else
    fail "missing-file handling broken; got: $out_missing"
fi

# ── (6) Wall-clock budget → mock that hangs ────────────────────────────────
cat > "$TMP/mock-bin/claude" <<'MOCK'
#!/usr/bin/env bash
sleep 60
MOCK
chmod +x "$TMP/mock-bin/claude"

printf '%s\n' "$ORIGINAL_PATH_CONTENT" > "$SYN/docs/process/THE_PATH.md"
start=$(date +%s)
(cd "$SYN" && PATH="$TMP/mock-bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_ORACLE_WALL_BUDGET_S=3 \
    bash scripts/coord/oracle-refresh.sh >/dev/null 2>&1 || true)
elapsed=$(($(date +%s) - start))
if [[ "$elapsed" -lt 10 ]]; then
    ok "wall budget enforced (CHUMP_ORACLE_WALL_BUDGET_S=3 cut hang to ${elapsed}s)"
else
    fail "wall budget did not enforce; took ${elapsed}s for 3s budget"
fi

echo ""
echo "ALL META-088 oracle-refresh assertions passed."
