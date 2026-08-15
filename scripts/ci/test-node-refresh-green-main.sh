#!/usr/bin/env bash
# scripts/ci/test-node-refresh-green-main.sh — RESILIENT-327
#
# Proves node-refresh-chump.sh advances the live node to the last-GREEN main
# pointer, not raw origin/main HEAD: with a green sha older than HEAD injected
# via CHUMP_NODE_REFRESH_TEST_GREEN_SHA, the mirror checkout must land on the
# green commit, and a fake "bad" commit ahead of it must NEVER reach the live
# node's working tree. Also proves the explicit (non-silent) fallback to raw
# HEAD when no green sha can be found.
#
# Fails without RESILIENT-327: pre-change node-refresh-chump.sh always does
# `git reset --hard origin/main`, so test 1 below would leave the mirror at
# the "bad" commit instead of the pinned green one.

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

# ── Fixture: bare origin + mirror clone with a GREEN commit then a BAD one ──
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

echo "v2-bad" > "$MIRROR/f.txt"
git -C "$MIRROR" commit -q -am "bad commit (red main, would fail CI)"
git -C "$MIRROR" push -q origin HEAD:main
BAD_SHA="$(git -C "$MIRROR" rev-parse HEAD)"

# Reset the mirror's local main back so the script's own `git fetch` +
# `git reset --hard` is exercised against a real remote-ahead-of-local state.
git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"

# ── Fake cargo: stub PATH so no real build runs (fast + hermetic) ──────────
mkdir -p "$TMP/bin" "$MIRROR/target/release"
cat > "$TMP/bin/cargo" <<'EOF'
#!/usr/bin/env bash
# Fake `cargo build --release --bin chump`: writes a stub binary that reports
# the CURRENT HEAD sha via `chump --version`, mirroring the real binary's
# "(<sha> built ...)" format closely enough for the refresh script's grep.
mkdir -p target/release
sha="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
cat > target/release/chump <<INNER
#!/usr/bin/env bash
echo "chump 0.0.0-test (\$sha built now)"
INNER
sed -i "s/\\\$sha/$sha/" target/release/chump
chmod +x target/release/chump
exit 0
EOF
chmod +x "$TMP/bin/cargo"

AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"

# ── Test 1: green sha older than HEAD → mirror lands on green, not bad ─────
CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_BIN="$TMP/installed-chump" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs" \
CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$GREEN_SHA" \
HOME="$TMP/fakehome" \
PATH="$TMP/bin:$PATH" \
    bash "$SCRIPT" > "$TMP/out1.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "green-pin run exited $rc: $(cat "$TMP/out1.log")"

LANDED_SHA="$(git -C "$MIRROR" rev-parse HEAD)"
[ "$LANDED_SHA" = "$GREEN_SHA" ] \
    || fail "mirror landed on $LANDED_SHA, expected green sha $GREEN_SHA (bad sha was $BAD_SHA)"
ok "node-refresh pins the mirror to green-main, not the bad HEAD ahead of it"

grep -q "PIN: raw HEAD" "$TMP/out1.log" \
    || fail "expected a loud PIN log line noting raw HEAD is ahead of green-main"
grep -q '"kind":"node_refresh_green_pin_behind_head"' "$AMBIENT" \
    || fail "expected node_refresh_green_pin_behind_head emitted: $(cat "$AMBIENT")"
ok "divergence between raw HEAD and the green pin is logged loudly, not silently"

# ── Test 2: no green sha available → explicit, non-silent fallback to HEAD ─
git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"
CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_BIN="$TMP/installed-chump2" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs2" \
HOME="$TMP/fakehome" \
PATH="$TMP/bin:$PATH" \
    bash "$SCRIPT" > "$TMP/out2.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fallback run exited $rc: $(cat "$TMP/out2.log")"

LANDED_SHA2="$(git -C "$MIRROR" rev-parse HEAD)"
[ "$LANDED_SHA2" = "$BAD_SHA" ] \
    || fail "fallback (no gh) run should land on raw HEAD ($BAD_SHA), got $LANDED_SHA2"
grep -q '"kind":"node_refresh_green_lookup_failed"' "$AMBIENT" \
    || fail "expected node_refresh_green_lookup_failed emitted on fallback: $(cat "$AMBIENT")"
ok "with no green sha resolvable, falls back to raw HEAD and emits it loudly (non-silent)"

exit 0
