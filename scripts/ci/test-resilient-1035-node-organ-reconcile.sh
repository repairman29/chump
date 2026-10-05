#!/usr/bin/env bash
# scripts/ci/test-resilient-1035-node-organ-reconcile.sh — RESILIENT-1035
#
# Proves the "last hop" fix: node-refresh-chump.sh (the per-node auto-deploy
# organ) actually re-converges the node's ROLE-scoped organs after every
# refresh cycle, not just the `chump` binary.
#
# VERIFIED root cause (mugman, RESILIENT-1035): a merge could land an organ
# change (e.g. RESILIENT-1016's muscle worker.sh self-clean reconcile) and
# the node's binary would refresh right on schedule while the organ change
# NEVER reached the running node — chump-node-install.sh (the only thing that
# materializes/restarts role organs) was never invoked by the refresh timer.
# "Merged" reached the binary but not the organs — dead on arrival either way.
#
# This test stubs scripts/setup/chump-node-install.sh inside the mirror repo
# node-refresh-chump.sh operates on, and proves the organ-refresh script
# invokes it with --reconcile-organs-only on:
#   1. the "binary already current" skip path (organs can drift even when
#      the binary doesn't — this path must still converge them)
#   2. the local-build refresh path (binary changed)
# and that CHUMP_NODE_ROLE selects which --role is reconciled.
#
# Fails without RESILIENT-1035: pre-change node-refresh-chump.sh never
# references chump-node-install.sh at all — the stub's call-log stays empty
# on both paths.

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

# ── Fixture: bare origin + mirror clone carrying a stub chump-node-install.sh
ORIGIN="$TMP/origin.git"
MIRROR="$TMP/mirror"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$MIRROR"
git -C "$MIRROR" config user.email test@example.com
git -C "$MIRROR" config user.name "Test"

mkdir -p "$MIRROR/scripts/setup"
CALL_LOG="$TMP/install-calls.log"
# Stub records every invocation's argv + CHUMP_NODE_REPO env so the test can
# assert both the flag and the role selection without running a real install.
cat > "$MIRROR/scripts/setup/chump-node-install.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "argv=\$* repo=\${CHUMP_NODE_REPO:-unset}" >> "$CALL_LOG"
exit 0
EOF
chmod +x "$MIRROR/scripts/setup/chump-node-install.sh"

echo "v1" > "$MIRROR/f.txt"
git -C "$MIRROR" add f.txt scripts/setup/chump-node-install.sh
git -C "$MIRROR" commit -q -m "green commit"
git -C "$MIRROR" push -q origin HEAD:main
GREEN_SHA="$(git -C "$MIRROR" rev-parse HEAD)"

# ── Fake cargo: writes a stub binary reporting the CURRENT HEAD sha ─────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/cargo" <<'EOF'
#!/usr/bin/env bash
mkdir -p target/release
sha="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
printf '#!/usr/bin/env bash\necho "chump 0.0.0-test (%s built now)"\n' "$sha" > target/release/chump
chmod +x target/release/chump
exit 0
EOF
chmod +x "$TMP/bin/cargo"

# Fake gh: always misses, so artifact-pull falls through to the local cargo
# build deterministically without touching the network or real gh auth.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/bin/gh"

FAKEHOME="$TMP/fakehome"
mkdir -p "$FAKEHOME/.cargo/bin"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"

COMMON_ENV=(
    CHUMP_NODE_REPO="$MIRROR"
    NODE_AMBIENT="$AMBIENT"
    CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs"
    CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$GREEN_SHA"
    HOME="$FAKEHOME"
    PATH="$TMP/bin:/usr/bin:/bin"
)

# ── Test 1: local-build refresh path (binary changes) reconciles organs ────
env "${COMMON_ENV[@]}" bash "$SCRIPT" > "$TMP/out1.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "run 1 exited $rc: $(cat "$TMP/out1.log")"
[ -s "$CALL_LOG" ] || fail "chump-node-install.sh was NEVER invoked after a binary refresh (RESILIENT-1035 regression)"
grep -q -- '--reconcile-organs-only' "$CALL_LOG" || fail "invocation missing --reconcile-organs-only: $(cat "$CALL_LOG")"
grep -q -- '--role muscle' "$CALL_LOG" || fail "invocation missing default --role muscle: $(cat "$CALL_LOG")"
grep -q "repo=$MIRROR" "$CALL_LOG" || fail "invocation missing CHUMP_NODE_REPO=$MIRROR pass-through: $(cat "$CALL_LOG")"
ok "local-build refresh path reconciles role organs via chump-node-install.sh --reconcile-organs-only"

# ── Test 2: CHUMP_NODE_ROLE overrides which role is reconciled ──────────────
: > "$CALL_LOG"
git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"
rm -f "$FAKEHOME/.cargo/bin/chump"
env "${COMMON_ENV[@]}" CHUMP_NODE_ROLE=brain bash "$SCRIPT" > "$TMP/out1b.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "run 1b exited $rc: $(cat "$TMP/out1b.log")"
grep -q -- '--role brain' "$CALL_LOG" || fail "CHUMP_NODE_ROLE=brain did not propagate to --role: $(cat "$CALL_LOG")"
ok "CHUMP_NODE_ROLE overrides the reconciled role (brain)"

# ── Test 3: 'binary already current' skip path STILL reconciles organs ─────
# Organs can drift independently of the binary sha (the muscle worker.sh case
# this gap was filed against) — the skip-fast-path must not skip organs too.
: > "$CALL_LOG"
env "${COMMON_ENV[@]}" bash "$SCRIPT" > "$TMP/out2.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "run 2 (skip path) exited $rc: $(cat "$TMP/out2.log")"
grep -q "SKIP: binary already current" "$TMP/out2.log" || fail "expected run 2 to hit the already-current skip path: $(cat "$TMP/out2.log")"
[ -s "$CALL_LOG" ] || fail "'binary already current' skip path never reconciled organs (RESILIENT-1035 regression)"
grep -q -- '--reconcile-organs-only' "$CALL_LOG" || fail "skip-path invocation missing --reconcile-organs-only: $(cat "$CALL_LOG")"
ok "'binary already current' skip path also reconciles role organs"

exit 0
