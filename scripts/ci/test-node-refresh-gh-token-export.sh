#!/usr/bin/env bash
# scripts/ci/test-node-refresh-gh-token-export.sh — RESILIENT-1040
#
# Proves node-refresh-chump.sh exports GH_TOKEN from ~/.chump/providers.env
# before any gh call, so a fresh node (gh installed but never `gh auth
# login`-ed) still gets a real artifact pull instead of silently falling
# through to a cold local cargo build every cycle.
#
# Fails without RESILIENT-1040: pre-fix node-refresh-chump.sh never reads
# providers.env, so a stub `gh` that requires GH_TOKEN to succeed sees an
# empty env and the green-main lookup returns "" — the script logs the
# "no green-main sha found" fallback instead of resolving the green sha via
# the stub.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/ops/node-refresh-chump.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -x "$SCRIPT" ] || fail "missing or not executable"
bash -n "$SCRIPT" || fail "syntax error"
ok "bash -n passes"

grep -q 'CHUMP_PROVIDERS_ENV' "$SCRIPT" || fail "script does not reference CHUMP_PROVIDERS_ENV"
ok "script references CHUMP_PROVIDERS_ENV"

# ── Fixture: bare origin + mirror clone with a single (green) commit ────────
ORIGIN="$TMP/origin.git"
MIRROR="$TMP/mirror"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$MIRROR"
git -C "$MIRROR" config user.email test@example.com
git -C "$MIRROR" config user.name "Test"
echo "v1" > "$MIRROR/f.txt"
git -C "$MIRROR" add f.txt
git -C "$MIRROR" commit -q -m "green commit"
git -C "$MIRROR" push -q origin HEAD:main
GREEN_SHA="$(git -C "$MIRROR" rev-parse HEAD)"

# ── providers.env fixture: the fleet's canonical secret store ───────────────
PROVIDERS_ENV="$TMP/providers.env"
cat > "$PROVIDERS_ENV" <<'EOF'
HCLOUD_TOKEN=unrelated-secret
GH_TOKEN=stub-token-from-providers-env
DISCORD_TOKEN=unrelated-secret-2
EOF

# ── Stub `gh`: only succeeds when GH_TOKEN is set in its environment ────────
# This is the crux of the test: an unauthed gh (no GH_TOKEN) must behave
# exactly like the real world — silent empty output, not a loud error —
# because that's the actual failure mode RESILIENT-1040 diagnosed (gh
# "unavailable" from the script's point of view, not a visible crash).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "api" ]; then
    if printf '%s' "\$*" | grep -q "rate_limit"; then
        echo "5000 5000 9999999999"
        exit 0
    fi
    if [ -z "\${GH_TOKEN:-}" ]; then
        # Unauthed gh: prints nothing to stdout (mirrors real gh behavior
        # closely enough for this test — the caller sees empty output).
        exit 0
    fi
    if printf '%s' "\$*" | grep -q "runs?branch=main"; then
        echo "$GREEN_SHA"
        exit 0
    fi
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"

run_refresh() {
    CHUMP_NODE_REPO="$MIRROR" \
    CHUMP_NODE_BIN="$TMP/installed-chump" \
    CHUMP_PROVIDERS_ENV="$PROVIDERS_ENV" \
    NODE_AMBIENT="$TMP/ambient.jsonl" \
    CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs" \
    PATH="$TMP/bin:$PATH" \
    GH_TOKEN="" GITHUB_TOKEN="" \
    timeout 20 bash "$SCRIPT" >"$TMP/run.log" 2>&1
}

run_refresh
LATEST_LOG="$(ls -t "$TMP"/logs/refresh-*.log 2>/dev/null | head -1)"
[ -n "$LATEST_LOG" ] || fail "no refresh log written"

grep -q "green-main = " "$LATEST_LOG" && grep -q "no green-main sha found" "$LATEST_LOG" \
    && fail "unexpected: green-main resolved AND fallback logged simultaneously"

if grep -q "no green-main sha found" "$LATEST_LOG"; then
    fail "GH_TOKEN was not exported from providers.env — gh call went unauthed and green-main lookup fell back to raw HEAD (this is the RESILIENT-1040 bug reproduced)"
fi
ok "GH_TOKEN from providers.env reached the gh call — green-main resolved via the stub instead of falling back"

grep -q "green-main = ${GREEN_SHA:0:12}" "$LATEST_LOG" || fail "green-main sha did not match the fixture's green commit"
ok "resolved green-main sha matches the fixture commit"

# ── Sanity: an operator/systemd-provided GH_TOKEN is never overridden ───────
rm -rf "$TMP/logs"
CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_BIN="$TMP/installed-chump2" \
CHUMP_PROVIDERS_ENV="$PROVIDERS_ENV" \
NODE_AMBIENT="$TMP/ambient2.jsonl" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs" \
PATH="$TMP/bin:$PATH" \
GH_TOKEN="operator-provided-token" \
timeout 20 bash "$SCRIPT" >"$TMP/run2.log" 2>&1
LATEST_LOG2="$(ls -t "$TMP"/logs/refresh-*.log 2>/dev/null | head -1)"
[ -n "$LATEST_LOG2" ] || fail "no refresh log written (run 2)"
grep -q "no green-main sha found" "$LATEST_LOG2" && fail "operator-provided GH_TOKEN was lost (fell back to raw HEAD)"
ok "pre-existing GH_TOKEN in the environment is honored, not overridden by providers.env"

echo ""
echo "=== all tests passed ==="
